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
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        try await player.play()
        currentEntryID = player.queue.currentEntry?.id
    }

    func stage(_ track: CanopyCore.Track?) async throws {
        log("stage \(track?.title ?? "nil") status=\(player.state.playbackStatus) entries=\(player.queue.entries.count)")
        defer { log("staged; status=\(player.state.playbackStatus) entries=\(player.queue.entries.count)") }
        // Drop anything after the current entry, then insert the new next track.
        if !Self.insertOnly, let current = player.queue.currentEntry,
           let index = player.queue.entries.firstIndex(where: { $0.id == current.id }),
           index + 1 < player.queue.entries.endIndex {
            player.queue.entries.removeSubrange((index + 1)...)
        }
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

    func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        player.transition = enabled ? .crossfade(duration: duration) : .none
    }

    private func poll() {
        let entry = player.queue.currentEntry
        if entry?.id != currentEntryID {
            currentEntryID = entry?.id
            if let staged = stagedTrackID, entry?.item?.id.rawValue == staged {
                stagedTrackID = nil
                reportedEnd = false
                onEvent?(.advancedToStaged)
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
    static let insertOnly = ProcessInfo.processInfo.arguments.contains("-stageInsertOnly")
    private func log(_ message: String) { print("[engine] \(message)") }
    #else
    static let insertOnly = false
    private func log(_ message: String) {}
    #endif

    private static func duration(of item: MusicPlayer.Queue.Entry.Item) -> TimeInterval? {
        if case .song(let song) = item { return song.duration }
        return nil
    }
}
