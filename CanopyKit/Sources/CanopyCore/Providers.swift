import Foundation

/// Search and playlists for one music service.
public protocol MusicCatalog: Sendable {
    func searchSongs(_ term: String) async throws -> [QueueTrack]
    func libraryPlaylists() async throws -> [PlaylistSummary]
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary]
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack]
}

public enum PlaybackEvent: Sendable, Equatable {
    /// The player moved on to the item that was staged.
    case advancedToStaged
    /// The player ran out of things to play.
    case reachedEnd
    /// Play/pause state changed.
    case statusChanged
}

/// Plays one current track plus at most one staged "next" track.
/// `PartySession` owns the real queue and decides what gets staged.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// True when a staged track can be swapped out. False means stage late and lock it.
    var canReplaceStaged: Bool { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var onEvent: (@MainActor (PlaybackEvent) -> Void)? { get set }

    /// Replaces everything and starts playing `track` immediately.
    func play(_ track: QueueTrack) async throws
    /// Sets the single item after the current one. `nil` clears it.
    func stage(_ track: QueueTrack?) async throws
    func resume() async throws
    func pause()
    /// Jumps to the staged item.
    func skipToStaged() async throws
    /// Seeks back to the start of the current track.
    func restartCurrent()
    func seek(to time: TimeInterval)
    /// `duration` nil means the system's default crossfade length.
    func setCrossfade(enabled: Bool, duration: TimeInterval?)
}
