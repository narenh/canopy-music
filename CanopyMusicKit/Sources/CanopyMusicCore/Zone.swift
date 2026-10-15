import Foundation

/// What a hub is: an iPad running the party, or an Apple TV. A Mac (the iPad app, "Designed for
/// iPad") is `ipad` here, since older peers can't decode a new case; it says which Mac it is in
/// the separate, optional `device` field beside it (`MacKind`).
public enum HubKind: String, Codable, Sendable {
    case ipad, tv
}

/// The kind of Mac a hub or display runs on. On the wire (the Bonjour TXT record's `device`,
/// snapshots' `hubDevice`, the display hello's `device`) as the raw value; absent for iPads and
/// Apple TVs, and ignored by peers from before it.
public enum MacKind: String, CaseIterable, Sendable {
    case macBookAir = "MacBookAir", macBookPro = "MacBookPro", iMac = "iMac", macMini = "Macmini",
         macStudio = "MacStudio", macPro = "MacPro", mac = "Mac"

    /// What it's called in copy: "MacBook Air", "iMac", "Mac mini", …, or "Mac".
    public var noun: String {
        switch self {
        case .macBookAir: "MacBook Air"
        case .macBookPro: "MacBook Pro"
        case .iMac: "iMac"
        case .macMini: "Mac mini"
        case .macStudio: "Mac Studio"
        case .macPro: "Mac Pro"
        case .mac: "Mac"
        }
    }

    /// From the wire: nil when the field is absent or empty (an iPad or TV); a kind this build
    /// doesn't know (a newer peer's) counts as some Mac.
    public init?(wire value: String?) {
        guard let value, !value.isEmpty else { return nil }
        self = MacKind(rawValue: value) ?? .mac
    }
}

/// The SF Symbol for a hub or display, one rule for every zone row, badge and connected list:
/// prefer the symbol without a generation suffix; failing that, the latest generation; failing
/// that, a generic computer. Symbol names differ by OS version, so `isAvailable` says whether a
/// name exists on this one (the apps pass `UIImage(systemName:)`).
public enum DeviceSymbol {
    /// The names to try, best first. The last always exists.
    public static func candidates(kind: HubKind, device: String?) -> [String] {
        guard kind == .ipad, let mac = MacKind(wire: device) else {
            return [kind == .tv ? "tv" : "ipad.landscape"]
        }
        return switch mac {
        case .macBookAir, .macBookPro: ["macbook", "macbook.gen2", "macbook.gen1", "laptopcomputer"]
        case .iMac: ["desktopcomputer"]
        case .macMini: ["macmini", "desktopcomputer"]
        case .macStudio: ["macstudio", "desktopcomputer"]
        case .macPro: ["macpro", "macpro.gen3", "macpro.gen2", "macpro.gen1", "desktopcomputer"]
        case .mac: ["desktopcomputer"]
        }
    }

    public static func name(kind: HubKind, device: String?, isAvailable: (String) -> Bool) -> String {
        let names = candidates(kind: kind, device: device)
        return names.first(where: isAvailable) ?? names[names.count - 1]
    }
}

#if canImport(UIKit)
import UIKit

extension DeviceSymbol {
    @MainActor private static var cache: [String: String] = [:]

    /// The symbol that exists on this OS, looked up once per kind of device.
    @MainActor public static func name(kind: HubKind, device: String?) -> String {
        let key = "\(kind.rawValue)/\(device ?? "")"
        if let found = cache[key] { return found }
        let found = name(kind: kind, device: device) { UIImage(systemName: $0) != nil }
        cache[key] = found
        return found
    }
}
#endif

/// A Canopy device showing another device's zone (see docs/multi-device.md).
public struct ZoneDisplay: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: HubKind
    /// Which Mac, for an `ipad`-kind display running on one (`MacKind`); nil otherwise.
    public var device: String?
    public var lastSeen: Date

    public init(id: String, name: String, kind: HubKind, device: String? = nil, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.device = device
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

// A display loads the hub's relayed library artwork (`LibraryArtwork`) from that hub: what it
// takes from the hub has the relative paths made absolute against the hub's address.

public extension UpcomingPage {
    func resolvingArtwork(against base: URL) -> UpcomingPage {
        var page = self
        page.rows = rows.map { row in
            var row = row
            row.thumbnailURL = QueueTrack(id: row.trackID, title: "", artist: "", thumbnailURL: row.thumbnailURL)
                .resolvingArtwork(against: base).thumbnailURL
            return row
        }
        return page
    }
}

public extension PartySnapshot {
    func resolvingArtwork(against base: URL) -> PartySnapshot {
        var snapshot = self
        snapshot.current = current?.resolvingArtwork(against: base)
        snapshot.upNext = upNext.map { $0.resolvingArtwork(against: base) }
        snapshot.history = history?.map { $0.resolvingArtwork(against: base) }
        snapshot.externalCurrent = externalCurrent?.resolvingArtwork(against: base)
        snapshot.foreignUpcoming = foreignUpcoming?.map { $0.resolvingArtwork(against: base) }
        return snapshot
    }
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
