import AVFoundation
import CanopyMusicCore
import Foundation

/// Plays link tracks (`QueueTrack.link`): canopy-cmdlp's .m4a at its signed address, in an
/// AVQueuePlayer, as the link side of a `LinkHandoffEngine`. A link after a link is lined up in
/// the same player, so it follows without a gap; one after an Apple Music song is loaded ahead
/// (`prepare`) and starts the moment that song ends.
///
/// The hub's audio session is the app's (`.playback`, long-form, on the iPad and Mac; `.ambient`
/// on the TV): AVPlayer plays in either as it is. Handing back to Apple Music lets the session go
/// first (`handOff`), which avoided an interruption of Apple Music's start on a real iPad.
@MainActor
final class LinkPlayerEngine: HandoffSide {
    let canReplaceStaged = true
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    /// Debug output: each start, and how long it took to be heard. nil is silent.
    var log: (@MainActor (String) -> Void)?

    private struct Entry {
        let track: QueueTrack
        let item: AVPlayerItem
        let made: ContinuousClock.Instant
        var id: ObjectIdentifier { ObjectIdentifier(item) }
    }

    private let player = AVQueuePlayer()
    private var current: Entry?
    /// The next link, lined up behind the current one.
    private var staged: Entry?
    /// Loaded ahead while Apple Music plays: the player's only item, paused.
    private var prepared: Entry?
    private var reportedEnd = false
    /// This player has had the audio since the last handoff, so the next one lets it go.
    private var holdsAudio = false
    private var lastPlaying = false
    /// When `play` was called, until the player is heard (`timeControlStatus` playing).
    private var playCalledAt: ContinuousClock.Instant?
    private var isShutDown = false
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [any NSObjectProtocol] = []

    init() {
        player.actionAtItemEnd = .advance
        observations = [
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.timeControlChanged() }
            },
        ]
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                let item = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.itemEnded(item) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                let item = (note.object as AnyObject?).map(ObjectIdentifier.init)
                let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription
                MainActor.assumeIsolated { self?.itemFailed(item, error: error) }
            },
        ]
    }

    var isPlaying: Bool { current != nil && player.rate != 0 }

    var currentTime: TimeInterval {
        guard current != nil else { return 0 }
        let time = player.currentTime().seconds
        return time.isFinite ? max(0, time) : 0
    }

    // MARK: PlaybackEngine

    /// Starts `track`, from its prepared item when it has one, and returns once it's ready to
    /// play (or throws if its audio can't be loaded).
    func play(_ track: QueueTrack) async throws {
        guard let url = track.link?.isPlayable == true ? track.link?.audioURL : nil else { throw LinkPlaybackError.notReady }
        let called = ContinuousClock.now
        let entry: Entry
        let wasPrepared: Bool
        current = nil
        staged = nil
        if let prepared, prepared.track.id == track.id, prepared.item.status != .failed, player.items().first === prepared.item {
            entry = prepared
            wasPrepared = true
        } else {
            player.removeAllItems()
            entry = Entry(track: track, item: AVPlayerItem(url: url), made: .now)
            player.insert(entry.item, after: nil)
            wasPrepared = false
        }
        prepared = nil
        current = entry
        reportedEnd = false
        holdsAudio = true
        playCalledAt = called
        player.play()
        try await waitUntilReady(entry)
        log?("play \(track.title)\(wasPrepared ? " (prepared)" : ""): ready \((ContinuousClock.now - called).inMilliseconds) after the call")
        noteStatus()
    }

    /// Lines the next link up behind the current one (an AVQueuePlayer moves on by itself).
    func stage(_ track: QueueTrack?) async throws {
        if let staged, player.currentItem !== staged.item {
            player.remove(staged.item)
        }
        staged = nil
        guard let track, current != nil else { return }
        guard let url = track.link?.isPlayable == true ? track.link?.audioURL : nil else { throw LinkPlaybackError.notReady }
        let entry = Entry(track: track, item: AVPlayerItem(url: url), made: .now)
        guard player.canInsert(entry.item, after: player.currentItem) else { throw CancellationError() }
        player.insert(entry.item, after: player.currentItem)
        staged = entry
        log?("staged \(track.title)")
    }

    func resume() async throws {
        guard current != nil else { throw LinkPlaybackError.notReady }
        holdsAudio = true
        player.play()
        noteStatus()
    }

    func pause() {
        player.pause()
        noteStatus()
    }

    func skipToStaged() async throws {
        guard staged != nil else { throw CancellationError() }
        player.advanceToNextItem()
    }

    func restartCurrent() { seek(to: 0) }

    func seek(to time: TimeInterval) {
        guard current != nil else { return }
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
    }

    /// No crossfade between links (nor across a handoff).
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    func shutDown() {
        isShutDown = true
        player.pause()
        player.removeAllItems()
        current = nil
        staged = nil
        prepared = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
    }

    // MARK: HandoffSide

    /// Loads `track` while Apple Music plays: the player's only item, paused, so `play` of it
    /// starts as soon as Apple Music's song ends.
    func prepare(_ track: QueueTrack?) async throws {
        guard let track else {
            if prepared != nil, current == nil { player.removeAllItems() }
            prepared = nil
            return
        }
        guard current == nil, prepared?.track.id != track.id else { return }
        guard let url = track.link?.isPlayable == true ? track.link?.audioURL : nil else { throw LinkPlaybackError.notReady }
        player.pause()
        player.removeAllItems()
        let entry = Entry(track: track, item: AVPlayerItem(url: url), made: .now)
        player.insert(entry.item, after: nil)
        prepared = entry
        Task { [weak self] in
            guard let self, (try? await self.waitUntilReady(entry)) != nil else { return }
            self.log?("prepared \(track.title): ready in \((ContinuousClock.now - entry.made).inMilliseconds)")
        }
    }

    /// Apple Music takes over: the player stops and lets go of its items, then of the audio
    /// session, which Apple Music's player then starts in afresh.
    func handOff() {
        player.pause()
        player.removeAllItems()
        current = nil
        staged = nil
        prepared = nil
        playCalledAt = nil
        noteStatus()
        guard holdsAudio else { return }
        holdsAudio = false
        #if os(iOS) || os(tvOS)
        let started = ContinuousClock.now
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            log?("let the audio session go in \((ContinuousClock.now - started).inMilliseconds)")
        } catch {
            // Still busy (a link left mid-song): Apple Music's player takes it over anyway.
            log?("couldn't let the audio session go: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: Watching the player

    /// Until the item is ready to play, or failed (thrown), for at most `timeout`.
    private func waitUntilReady(_ entry: Entry, timeout: TimeInterval = 15) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            switch entry.item.status {
            case .readyToPlay:
                return
            case .failed:
                if current?.id == entry.id {
                    current = nil
                    player.removeAllItems()
                }
                throw entry.item.error ?? LinkPlaybackError.notReady
            default:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw LinkPlaybackError.notReady
    }

    private func currentItemChanged() {
        guard !isShutDown, let staged, player.currentItem === staged.item else { return }
        current = staged
        self.staged = nil
        reportedEnd = false
        log?("moved on to \(staged.track.title)")
        onEvent?(.advancedToStaged)
    }

    private func itemEnded(_ item: ObjectIdentifier?) {
        guard !isShutDown, let current, item == current.id else { return }
        // A link lined up behind it: the player moves on (`currentItemChanged`), unless its item
        // couldn't load, when the queue just ran out.
        if let staged, staged.item.status != .failed { return }
        if let staged { player.remove(staged.item) }
        staged = nil
        reportEnd("ended")
    }

    private func itemFailed(_ item: ObjectIdentifier?, error: String?) {
        guard !isShutDown else { return }
        if let staged, item == staged.id {
            player.remove(staged.item)
            self.staged = nil
            log?("the next link failed to load: \(error ?? "no error")")
            return
        }
        guard let current, item == current.id else { return }
        // Mid-song: the session moves on to the next song, as at an end.
        player.removeAllItems()
        staged = nil
        reportEnd("failed: \(error ?? "no error")")
    }

    private func reportEnd(_ why: String) {
        guard !reportedEnd else { return }
        reportedEnd = true
        current = nil
        log?("reached the end (\(why))")
        noteStatus()
        onEvent?(.reachedEnd)
    }

    private func timeControlChanged() {
        if player.timeControlStatus == .playing, let called = playCalledAt {
            playCalledAt = nil
            log?("heard \((ContinuousClock.now - called).inMilliseconds) after play")
        }
        noteStatus()
    }

    private func noteStatus() {
        let playing = isPlaying
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        onEvent?(.statusChanged)
    }
}
