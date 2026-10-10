import CanopyCore
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

    private let player = ApplicationMusicPlayer.shared
    private let cache: SongCache
    private var stagedTrackID: String?
    private var currentEntryID: String?
    private var pausedByUs = false
    private var reportedEnd = false
    /// Guards against reading the brief `.stopped` right after `play` as the end of the queue.
    private var sawPlaying = false
    private var isReplacingQueue = false
    private var lastStatus: MusicPlayer.PlaybackStatus?
    private var poller: Task<Void, Never>?

    init(cache: SongCache) {
        self.cache = cache
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self?.poll()
            }
        }
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }
    var currentTime: TimeInterval { player.playbackTime }

    func play(_ track: CanopyCore.Track) async throws {
        let song = try await cache.song(for: track.id)
        stagedTrackID = nil
        reportedEnd = false
        pausedByUs = false
        sawPlaying = false
        // `poll` runs while we await below; it must not mistake our own queue swap for the
        // player landing on an unexpected entry (that fed back into another `play`, forever).
        isReplacingQueue = true
        defer {
            currentEntryID = player.queue.currentEntry?.id
            isReplacingQueue = false
        }
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.play()
    }

    /// Inserts the new next track right after the current one. It never removes the previously
    /// staged entry: editing `queue.entries` makes the player rebuild its queue, which causes an
    /// audible dropout. Stale entries sit behind the new one and are never reached, because a new
    /// track is always staged first. If the player does land on one, `poll` reports it.
    func stage(_ track: CanopyCore.Track?) async throws {
        log("stage \(track?.title ?? "nil") status=\(player.state.playbackStatus) entries=\(player.queue.entries.count)")
        defer { log("staged; status=\(player.state.playbackStatus) entries=\(player.queue.entries.count)") }
        stagedTrackID = nil
        guard let track else { return }
        let song = try await cache.song(for: track.id)
        try await player.queue.insert(song, position: .afterCurrentEntry)
        stagedTrackID = track.id
    }

    func resume() async throws {
        pausedByUs = false
        try await player.play()
    }

    func pause() {
        pausedByUs = true
        player.pause()
    }

    func skipToStaged() async throws {
        guard stagedTrackID != nil else { throw CancellationError() }
        try await player.skipToNextEntry()
    }

    func restartCurrent() {
        player.restartCurrentEntry()
    }

    func seek(to time: TimeInterval) {
        player.playbackTime = time
    }

    func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        player.transition = enabled ? .crossfade(duration: duration) : .none
    }

    private func poll() {
        guard !isReplacingQueue else { return }
        let entry = player.queue.currentEntry
        if entry?.id != currentEntryID {
            let previous = currentEntryID
            currentEntryID = entry?.id
            if let staged = stagedTrackID, entry?.item?.id.rawValue == staged {
                stagedTrackID = nil
                reportedEnd = false
                onEvent?(.advancedToStaged)
            } else if previous != nil, entry != nil, !reportedEnd {
                // Landed on something Canopy didn't stage (a stale entry, or the system's
                // "previous" command). Hand control back to the queue.
                log("unexpected entry \(entry?.title ?? "?")")
                reportedEnd = true
                onEvent?(.reachedEnd)
            }
        }

        let status = player.state.playbackStatus
        if status == .playing { sawPlaying = true }
        if status != lastStatus {
            log("status \(String(describing: lastStatus)) -> \(status) t=\(Int(player.playbackTime))")
            lastStatus = status
            onEvent?(.statusChanged)
        }

        // The player stops (or pauses on its own at the end of the last entry) when nothing was staged.
        if sawPlaying, !reportedEnd, stagedTrackID == nil, !pausedByUs, currentEntryID != nil, status == .stopped || status == .paused,
           let duration = entry?.item.flatMap(Self.duration(of:)), player.playbackTime == 0 || player.playbackTime >= duration - 1.5 {
            reportedEnd = true
            log("reachedEnd")
            onEvent?(.reachedEnd)
        }
    }

    #if DEBUG
    private func log(_ message: String) { print("[engine] \(message)") }
    #else
    private func log(_ message: String) {}
    #endif

    private static func duration(of item: MusicPlayer.Queue.Entry.Item) -> TimeInterval? {
        if case .song(let song) = item { return song.duration }
        return nil
    }
}
