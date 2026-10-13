import Foundation

/// What a hub is: an iPad running the party, or an Apple TV.
public enum HubKind: String, Codable, Sendable {
    case ipad, tv
}

/// A Canopy device showing another device's zone (see docs/multi-device.md).
public struct ZoneDisplay: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: HubKind
    public var lastSeen: Date

    public init(id: String, name: String, kind: HubKind, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastSeen = lastSeen
    }
}

/// Things a display can ask its hub to do. The hub decides whether it's allowed.
public enum ZoneCommand: Sendable, Equatable {
    case add(QueueTrack, itemID: UUID)
    case move(UUID, after: UUID?)
    /// Only a request this display added (the hub checks, as it does for phones).
    case remove(UUID)
    case play, pause, next, previous
    case seek(TimeInterval)
}

/// The connection a display's mirrored `PartySession` talks through.
@MainActor
public protocol ZoneRemote: AnyObject, Sendable {
    /// This display's ID with its hub (its device ID). The hub records it on the display's
    /// requests, like a phone's client ID, so the display can remove them again.
    var clientID: String { get }
    func send(_ command: ZoneCommand) async throws
    func search(_ term: String) async throws -> [QueueTrack]
    /// The hub's base playlist past its live Up Next (`GET /api/upcoming`).
    func upcoming(offset: Int, limit: Int) async throws -> UpcomingPage
}

/// A page of the base playlist's songs after the live Up Next, to show (read-only) below it.
/// Not part of snapshots: fetched as people scroll.
public struct UpcomingPage: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        /// Stable while the song waits: its cycle and place in the playlist.
        public var id: String
        public var trackID: String
        public var title: String
        public var artist: String
        public var thumbnailURL: URL?
    }

    public var playlistName: String?
    /// Songs left in this cycle after the live Up Next (all pages).
    public var total: Int
    public var offset: Int
    public var rows: [Row]
    /// The queue version this page was taken at.
    public var version: Int

    public static let empty = UpcomingPage(playlistName: nil, total: 0, offset: 0, rows: [], version: 0)
}

/// Search for a display goes to the hub, so every result is playable there.
struct RemoteCatalog: MusicCatalog {
    let search: @Sendable (String) async throws -> [QueueTrack]
    /// Displays look motion artwork up themselves, from the track in the hub's snapshot. Only the
    /// third-party service is asked (`videoURL(for:)`), so the Apple Music fetch is never used.
    let motionArtwork: MotionArtworkLookup? = MotionArtworkLookup(
        fetch: { _ in throw CancellationError() },
        storefront: { Locale.current.region?.identifier.lowercased() }
    )

    func searchSongs(_ term: String) async throws -> [QueueTrack] { try await search(term) }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [] }
}

/// A display plays nothing; it reports the hub's playback from the latest snapshot.
@MainActor
final class MirrorEngine: PlaybackEngine {
    let canReplaceStaged = true
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playback = PlaybackSnapshot(isPlaying: false, position: 0, capturedAt: Date())

    var isPlaying: Bool { playback.isPlaying }
    var currentTime: TimeInterval {
        playback.isPlaying ? playback.position + Date().timeIntervalSince(playback.capturedAt) : playback.position
    }

    func play(_ track: QueueTrack) async throws {}
    func stage(_ track: QueueTrack?) async throws {}
    func resume() async throws {}
    func pause() {}
    func skipToStaged() async throws {}
    func restartCurrent() {}
    func seek(to time: TimeInterval) {}
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}
}
