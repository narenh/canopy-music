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
    case play, pause, next, previous
    case seek(TimeInterval)
}

/// The connection a display's mirrored `PartySession` talks through.
@MainActor
public protocol ZoneRemote: AnyObject, Sendable {
    func send(_ command: ZoneCommand) async throws
    func search(_ term: String) async throws -> [QueueTrack]
}

/// Search for a display goes to the hub, so every result is playable there.
struct RemoteCatalog: MusicCatalog {
    let search: @Sendable (String) async throws -> [QueueTrack]

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
