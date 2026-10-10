import Foundation

/// Colors pulled from album artwork, as `#RRGGBB` hex strings.
public struct ArtworkColors: Codable, Hashable, Sendable {
    public var background: String
    public var primary: String
    public var secondary: String

    public init(background: String, primary: String, secondary: String) {
        self.background = background
        self.primary = primary
        self.secondary = secondary
    }
}

/// A provider-agnostic song. Nothing outside the provider layer should touch MusicKit types.
public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var thumbnailURL: URL?
    public var colors: ArtworkColors?
    public var isExplicit: Bool

    public init(
        id: String, title: String, artist: String, album: String = "",
        duration: TimeInterval? = nil, artworkURL: URL? = nil, thumbnailURL: URL? = nil,
        colors: ArtworkColors? = nil, isExplicit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.thumbnailURL = thumbnailURL
        self.colors = colors
        self.isExplicit = isExplicit
    }
}

public enum Origin: String, Codable, Sendable {
    case ipad, phone
}

public struct Requester: Codable, Hashable, Sendable {
    public var name: String?
    /// Stable per-phone id, used to let a phone remove its own requests.
    public var clientID: String?
    public var origin: Origin

    public init(name: String? = nil, clientID: String? = nil, origin: Origin) {
        self.name = name
        self.clientID = clientID
        self.origin = origin
    }
}

public struct QueueItem: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var track: Track
    /// `nil` means the item came from the base playlist.
    public var requester: Requester?
    /// True until someone drags the item. Auto-placed requests anchor where new requests land.
    public var autoPlaced: Bool
    public var addedAt: Date

    public var isRequest: Bool { requester != nil }

    public init(id: UUID = UUID(), track: Track, requester: Requester?, autoPlaced: Bool = true, addedAt: Date = Date()) {
        self.id = id
        self.track = track
        self.requester = requester
        self.autoPlaced = autoPlaced
        self.addedAt = addedAt
    }
}

public struct PlaylistSummary: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case library, catalog }

    public var id: String
    public var name: String
    public var subtitle: String?
    public var artworkURL: URL?
    public var kind: Kind

    public init(id: String, name: String, subtitle: String? = nil, artworkURL: URL? = nil, kind: Kind) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.kind = kind
    }
}
