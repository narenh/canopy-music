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
public struct QueueTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var thumbnailURL: URL?
    public var colors: ArtworkColors?
    public var isExplicit: Bool
    /// The Apple Music catalog album the song is on, when known (catalog songs). Lets motion
    /// artwork ask for that exact album rather than searching by name. Optional in JSON: saved
    /// queues and snapshots from before it decode without it, and older peers ignore it.
    public var albumID: String?

    public init(
        id: String, title: String, artist: String, album: String = "",
        duration: TimeInterval? = nil, artworkURL: URL? = nil, thumbnailURL: URL? = nil,
        colors: ArtworkColors? = nil, isExplicit: Bool = false, albumID: String? = nil
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
        self.albumID = albumID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, artworkURL, thumbnailURL, colors, isExplicit, albumID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        colors = try container.decodeIfPresent(ArtworkColors.self, forKey: .colors)
        isExplicit = try container.decode(Bool.self, forKey: .isExplicit)
        albumID = try container.decodeIfPresent(String.self, forKey: .albumID)
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
    public var track: QueueTrack
    /// `nil` means the item came from the base playlist.
    public var requester: Requester?
    /// True until someone drags the item. Auto-placed requests anchor where new requests land.
    public var autoPlaced: Bool
    public var addedAt: Date

    public var isRequest: Bool { requester != nil }

    public init(id: UUID = UUID(), track: QueueTrack, requester: Requester?, autoPlaced: Bool = true, addedAt: Date = Date()) {
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
    /// How many songs the service lists in it, when the playlist list says (Spotify); nil when
    /// it doesn't (Apple Music library playlists count one at a time, `PlaylistSongCounts`).
    public var songCount: Int?
    public var kind: Kind

    public init(id: String, name: String, subtitle: String? = nil, artworkURL: URL? = nil, songCount: Int? = nil, kind: Kind) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.songCount = songCount
        self.kind = kind
    }

    /// "24 songs", "1 song", or "No songs" for a picker row.
    public static func countText(_ count: Int) -> String {
        switch count {
        case 0: "No songs"
        case 1: "1 song"
        default: "\(count.formatted()) songs"
        }
    }
}

/// Loading a playlist that has nothing to play: it's empty (or emptied since it was listed), or
/// none of its songs can play here. Thrown before anything changes, so the party is as it was.
public enum PlaylistLoadError: LocalizedError, Equatable {
    case noSongs(playlist: String)
    case noPlayableSongs(playlist: String)

    /// The first sentence, for an alert's title.
    public var headline: String {
        switch self {
        case .noSongs(let name): "“\(name)” has no songs."
        case .noPlayableSongs(let name): "None of the songs in “\(name)” can play here."
        }
    }

    public var errorDescription: String? { "\(headline) Choose another playlist." }
}
