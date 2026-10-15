import CanopyMusicCore
import Combine
import Foundation
@preconcurrency import MusicKit

/// Drives `ApplicationMusicPlayer` with exactly one current entry and at most one staged entry.
/// Detection is by polling: the player's queue object gets replaced on `play`, which makes
/// subscriptions to it unreliable.
@MainActor
final class AppleMusicEngine: PlaybackEngine {
    let canReplaceStaged = true
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    /// Created on first use: touching `ApplicationMusicPlayer` can trigger the Apple Music
    /// permission prompt, which shouldn't appear before someone has chosen Apple Music.
    private var _player: ApplicationMusicPlayer?
    private var player: ApplicationMusicPlayer {
        if let _player { return _player }
        let player = ApplicationMusicPlayer.shared
        #if !os(tvOS) // tvOS has no crossfade
        player.transition = transition
        #endif
        _player = player
        startPolling()
        return player
    }
    #if !os(tvOS)
    private var transition: MusicPlayer.Transition = .none
    #endif
    private var pacing = PollPacing.appleMusic(crossfade: false)
    /// The current entry's length as of the last poll, for pacing.
    private var cachedDuration: TimeInterval?
    private var lastCommandAt = Date.distantPast
    /// The session dropped this engine: no more polls.
    private var isShutDown = false
    private let cache: SongCache
    private var stagedTrackID: String?
    private var currentEntryID: String?
    private var pausedByUs = false
    private var reportedEnd = false
    /// Guards against reading the brief `.stopped` right after `play` as the end of the queue.
    private var sawPlaying = false
    private var isReplacingQueue = false
    /// Set by a `play` that failed or was given up on (`PartySession.engineCallTimeout`): the
    /// player's connection may have dropped, and reading it then blocks the main thread
    /// (`AppleMusicCatalog`, tvOS). Polling waits for the next `play` that works.
    private var pollingPaused = false
    private var lastStatus: MusicPlayer.PlaybackStatus?
    private var poller: Task<Void, Never>?

    // Songs only in the library, on tvOS. There, a catalog song that came with a library track
    // couldn't start a fresh player: its first update referred to the user's library, which the
    // app can't open, so the player's connection dropped and the synchronous reads in `poll`
    // blocked the main thread (`AppleMusicCatalog` plays those from the catalog instead). A song
    // only in the library has no catalog version, so while one plays or is staged the player is
    // read on another thread (`PlayerReading.takeOffMain`), one read at a time, and a read that
    // doesn't come back stops the reads (the music shows paused) rather than freeze the TV. Its
    // start counts only once a read finds it playing, within `libraryStartDeadline`; otherwise
    // `play` throws, and the session moves on past it. Not yet tried on a real Apple TV.
    #if os(tvOS)
    private static let readsLibrarySongsOffMain = true
    #else
    private static let readsLibrarySongsOffMain = false
    #endif
    static let readDeadline: TimeInterval = 5
    static let libraryStartDeadline: TimeInterval = 8
    private var currentIsLibraryOnly = false
    private var stagedIsLibraryOnly = false
    private var readsOffMain: Bool { Self.readsLibrarySongsOffMain && (currentIsLibraryOnly || stagedIsLibraryOnly) }
    /// A read on another thread is out; its answer counts only for the `play` it was made for.
    private var isReading = false
    private var readGeneration = 0

    // Playback state as of the last poll. Reading `ApplicationMusicPlayer` goes to an
    // out-of-process service; the UI asks for the time every frame (lyrics takeover), so it
    // gets a value interpolated from these instead of hitting the service each time.
    private var cachedPlaying = false
    private var cachedTime: TimeInterval = 0
    private var cachedAt = Date()

    init(cache: SongCache) {
        self.cache = cache
    }

    /// Starts the poll loop, or starts it over so the next read comes at the pace from now (a
    /// command was just sent; the loop may be in a long paused-state wait).
    private func startPolling() {
        guard !isShutDown else { return }
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                // Ends with the engine: a replaced engine's loop used to wake for ever.
                guard let interval = self?.nextPollInterval() else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    private func nextPollInterval() -> Duration {
        let remaining = cachedDuration.map { $0 - currentTime }
        return pacing.interval(playing: cachedPlaying && !pollingPaused, remaining: remaining,
                               sinceCommand: Date().timeIntervalSince(lastCommandAt))
    }

    /// A command went to the player: read it soon, as before.
    private func noteCommand() {
        lastCommandAt = Date()
        if _player != nil { startPolling() }
    }

    func shutDown() {
        isShutDown = true
        poller?.cancel()
        poller = nil
    }

    var isPlaying: Bool { cachedPlaying }
    var currentTime: TimeInterval {
        cachedPlaying ? cachedTime + Date().timeIntervalSince(cachedAt) : cachedTime
    }

    private func cache(playing: Bool, time: TimeInterval) {
        cachedPlaying = playing
        cachedTime = time
        cachedAt = Date()
    }

    func play(_ track: QueueTrack) async throws {
        let song = try await cache.song(for: track)
        stagedTrackID = nil
        reportedEnd = false
        pausedByUs = false
        sawPlaying = false
        // A read still out was of the song before.
        readGeneration += 1
        isReading = false
        currentIsLibraryOnly = track.isLibraryOnly
        stagedIsLibraryOnly = false
        // `poll` runs while we await below; it must not mistake our own queue swap for the
        // player landing on an unexpected entry (that fed back into another `play`, forever).
        isReplacingQueue = true
        let start = ContinuousClock.now
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        log("play \(track.title)\(track.isLibraryOnly ? " (library only)" : ""): queue set")
        do {
            try await player.play()
            log("play(): returned after \((ContinuousClock.now - start).inMilliseconds)")
            currentEntryID = readsOffMain ? try await startedEntry(of: track) : player.queue.currentEntry?.id
        } catch {
            log("play(): threw after \((ContinuousClock.now - start).inMilliseconds): \(error)")
            // Don't read the player back after a failure (nor if the session gave up waiting and
            // this lands later): its connection may have dropped, and a synchronous read then
            // blocks the main thread. Polling stays off until a play works.
            pollingPaused = true
            isReplacingQueue = false
            throw error
        }
        isReplacingQueue = false
        pollingPaused = false
        cache(playing: true, time: 0)
        cachedDuration = song.duration
        noteCommand()
    }

    /// A song only in the library, on tvOS: its entry once a read on another thread finds the
    /// player playing, within `libraryStartDeadline` of now. Past it (the player not answering,
    /// or never playing) it didn't start: `AppleMusicError.libraryPlaybackStalled`.
    private func startedEntry(of track: QueueTrack) async throws -> String? {
        let start = ContinuousClock.now
        let deadline = Date().addingTimeInterval(Self.libraryStartDeadline)
        var last: PlayerReading?
        while deadline.timeIntervalSinceNow > 0 {
            guard let reading = await PlayerReading.takeOffMain(within: min(Self.readDeadline, deadline.timeIntervalSinceNow)) else {
                log("library song \(track.title): no answer from the player after \((ContinuousClock.now - start).inMilliseconds)")
                throw AppleMusicError.libraryPlaybackStalled
            }
            if reading.status == .playing {
                log("library song \(track.title): playing after \((ContinuousClock.now - start).inMilliseconds), t=\(reading.time) (read off the main thread)")
                return reading.entryID
            }
            last = reading
            try await Task.sleep(for: .milliseconds(250))
        }
        log("library song \(track.title): not playing after \((ContinuousClock.now - start).inMilliseconds) (status \(last.map { "\($0.status)" } ?? "?"))")
        throw AppleMusicError.libraryPlaybackStalled
    }

    /// Inserts the new next track right after the current one. It never removes the previously
    /// staged entry: editing `queue.entries` makes the player rebuild its queue, which causes an
    /// audible dropout. Stale entries sit behind the new one and are never reached, because a new
    /// track is always staged first. If the player does land on one, `poll` reports it.
    func stage(_ track: QueueTrack?) async throws {
        log("stage \(track?.title ?? "nil")\(playerDetails)")
        defer { log("staged;\(playerDetails)") }
        stagedTrackID = nil
        stagedIsLibraryOnly = track?.isLibraryOnly ?? false
        guard let track else { return }
        // A song only in the library is fetched from it by its library id, which is its id here
        // too, so the player's entry for it (`poll`) matches as a catalog song's does.
        let song = try await cache.song(for: track)
        try await player.queue.insert(song, position: .afterCurrentEntry)
        stagedTrackID = track.id
    }

    func resume() async throws {
        pausedByUs = false
        try await player.play()
        cache(playing: true, time: cachedTime)
        noteCommand()
    }

    func pause() {
        pausedByUs = true
        cache(playing: false, time: currentTime)
        // Never create the player just to pause it (that can prompt for Apple Music access).
        _player?.pause()
        noteCommand()
    }

    func skipToStaged() async throws {
        guard stagedTrackID != nil else { throw CancellationError() }
        try await player.skipToNextEntry()
        noteCommand()
    }

    func restartCurrent() {
        cache(playing: cachedPlaying, time: 0)
        _player?.restartCurrentEntry()
        noteCommand()
    }

    func seek(to time: TimeInterval) {
        cache(playing: cachedPlaying, time: time)
        _player?.playbackTime = time
        noteCommand()
    }

    func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        #if !os(tvOS)
        transition = enabled ? .crossfade(duration: duration) : .none
        _player?.transition = transition
        // The player moves on early by the crossfade's length: the fast reads start earlier too.
        pacing = .appleMusic(crossfade: enabled, crossfadeLength: duration)
        #endif
    }

    private func poll() {
        guard !isReplacingQueue, !pollingPaused else { return }
        guard readsOffMain else {
            handle(PlayerReading.take())
            return
        }
        guard !isReading else { return }
        isReading = true
        let generation = readGeneration
        Task {
            let reading = await PlayerReading.takeOffMain(within: Self.readDeadline)
            guard generation == readGeneration else { return }
            isReading = false
            guard let reading else {
                playerStoppedAnswering()
                return
            }
            guard !isReplacingQueue, !pollingPaused else { return }
            handle(reading)
        }
    }

    /// A read on another thread didn't come back in `readDeadline`: the player's connection has
    /// likely dropped. No more reads until a play works; the music shows paused.
    private func playerStoppedAnswering() {
        log("the player gave no answer in \(Int(Self.readDeadline)) s; not reading it until a play works")
        pollingPaused = true
        cache(playing: false, time: currentTime)
        onEvent?(.statusChanged)
    }

    private func handle(_ reading: PlayerReading) {
        let status = reading.status
        let time = reading.time
        // Before any event: the session snapshots the time as it handles them.
        cache(playing: status == .playing, time: time)
        let duration = reading.duration
        cachedDuration = duration
        if reading.entryID != currentEntryID {
            let previous = currentEntryID
            currentEntryID = reading.entryID
            if let staged = stagedTrackID, reading.itemID == staged {
                stagedTrackID = nil
                reportedEnd = false
                currentIsLibraryOnly = stagedIsLibraryOnly
                stagedIsLibraryOnly = false
                onEvent?(.advancedToStaged)
            } else if previous != nil, reading.entryID != nil, !reportedEnd {
                // Landed on something Canopy didn't stage (a stale entry, or the system's
                // "previous" command). Hand control back to the queue.
                log("unexpected entry \(reading.title ?? "?")")
                reportedEnd = true
                onEvent?(.reachedEnd)
            }
        }

        if status == .playing { sawPlaying = true }
        if status != lastStatus {
            log("status \(String(describing: lastStatus)) -> \(status) t=\(Int(time))")
            lastStatus = status
            onEvent?(.statusChanged)
        }

        // The player stops (or pauses on its own at the end of the last entry) when nothing was staged.
        if sawPlaying, !reportedEnd, stagedTrackID == nil, !pausedByUs, currentEntryID != nil, status == .stopped || status == .paused,
           let duration, time == 0 || time >= duration - 1.5 {
            reportedEnd = true
            log("reachedEnd")
            onEvent?(.reachedEnd)
        }
    }

    /// An autoclosure: release builds don't build the message, nor do the player reads in it.
    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[engine] \(message())")
        #endif
    }

    /// For the log: the player's status and queue length, unless it's being read off the main
    /// thread (`readsOffMain`): then nothing is read here.
    private var playerDetails: String {
        readsOffMain ? " (player read off the main thread)" : " status=\(player.state.playbackStatus) entries=\(player.queue.entries.count)"
    }
}

extension Duration {
    /// "412 ms", for debug logs.
    var inMilliseconds: String { "\(Int(self / .milliseconds(1))) ms" }
}

/// One read of `ApplicationMusicPlayer`: what `AppleMusicEngine.poll` acts on. Each property
/// read goes to Apple's out-of-process player, synchronously.
struct PlayerReading: Sendable {
    var entryID: String?
    /// The entry's song id (a catalog id, or a library id for a song only in the library).
    var itemID: String?
    var title: String?
    var status: MusicPlayer.PlaybackStatus
    var time: TimeInterval
    var duration: TimeInterval?

    /// On the calling thread.
    nonisolated static func take() -> PlayerReading {
        let player = ApplicationMusicPlayer.shared
        let entry = player.queue.currentEntry
        var duration: TimeInterval?
        if case .song(let song) = entry?.item { duration = song.duration }
        return PlayerReading(entryID: entry?.id, itemID: entry?.item?.id.rawValue, title: entry?.title,
                             status: player.state.playbackStatus, time: player.playbackTime, duration: duration)
    }

    /// Reads one at a time, in order, on their own thread: one that never returns holds up only
    /// the reads behind it.
    private static let queue = DispatchQueue(label: "com.canopysf.CanopyMusic.player-reads", qos: .userInitiated)

    /// `take` on `queue`, or nil if it hasn't come back within `seconds` (it's left to finish, or
    /// not, by itself).
    nonisolated static func takeOffMain(within seconds: TimeInterval) async -> PlayerReading? {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            queue.async { answer.give(take()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { answer.give(nil) }
        }
    }

    /// Whichever of a read and its deadline comes first.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<PlayerReading?, Never>?

        init(_ waiter: CheckedContinuation<PlayerReading?, Never>) {
            self.waiter = waiter
        }

        func give(_ reading: PlayerReading?) {
            let waiter = lock.withLock {
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(returning: reading)
        }
    }
}
