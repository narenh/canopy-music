import Foundation

/// Search and playlists for one music service.
public protocol MusicCatalog: Sendable {
    func searchSongs(_ term: String) async throws -> [QueueTrack]
    func libraryPlaylists() async throws -> [PlaylistSummary]
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary]
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack]
    /// How the latest `tracks(in:)` for `playlist` went, including the songs it left out because
    /// they can't be played. nil when there's nothing to report.
    func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport?
    /// Where `savePlaylist` saves, shown before saving: "Saves to your Apple Music library". nil
    /// when this service can't save playlists.
    var playlistDestination: String? { get }
    /// Creates a playlist with `tracks`, in order, in the signed-in account.
    func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws
    /// Finds animated album artwork for Now Playing (see `MotionArtwork`). nil for services
    /// without it.
    var motionArtwork: MotionArtworkLookup? { get }
}

public extension MusicCatalog {
    var motionArtwork: MotionArtworkLookup? { nil }
    func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? { nil }
    var playlistDestination: String? { nil }
    func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        throw PartySaveError.unsupported
    }
}

public enum PlaybackEvent: Sendable, Equatable {
    /// The player moved on to the item that was staged.
    case advancedToStaged
    /// The player ran out of things to play.
    case reachedEnd
    /// Play/pause state changed.
    case statusChanged
}

/// An engine call that didn't answer within `PartySession.engineCallTimeout`: the player (Apple's
/// runs out of process) stopped responding. The session counts the call as failed and moves on.
public enum PlaybackEngineError: Error, LocalizedError, Equatable {
    case timedOut(operation: String)

    public var errorDescription: String? { "The player didn't respond." }
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
