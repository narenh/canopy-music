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
    /// Set for the hub account's own copy of a song in its iCloud Music Library: its library id
    /// ("i.…"). Its artwork comes through the hub (`LibraryArtwork`), and its title and artist are
    /// the library's. `id` stays the song's catalog id when it has one (a matched or added copy),
    /// so it plays as the catalog song and counts as the same song as the catalog's; a song only
    /// in the library (an upload with no catalog entry, `isLibraryOnly`) has its library id as
    /// `id` too, and players fetch it from the library. nil for catalog songs. Optional in JSON:
    /// older saved queues and peers leave it out.
    public var libraryID: String?

    /// Only in the hub account's library: no catalog id, so it plays from the library.
    public var isLibraryOnly: Bool { libraryID != nil && libraryID == id }

    public init(
        id: String, title: String, artist: String, album: String = "",
        duration: TimeInterval? = nil, artworkURL: URL? = nil, thumbnailURL: URL? = nil,
        colors: ArtworkColors? = nil, isExplicit: Bool = false, albumID: String? = nil,
        libraryID: String? = nil
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
        self.libraryID = libraryID
    }

    /// A song only in the hub account's library: `id` and `libraryID` are its library id, and its
    /// artwork is the hub's relay (`LibraryArtwork.url`), relative, so each page and display loads
    /// it from the hub it got the song from.
    public static func libraryOnly(
        libraryID: String, title: String, artist: String, album: String = "",
        duration: TimeInterval? = nil, colors: ArtworkColors? = nil, isExplicit: Bool = false
    ) -> QueueTrack {
        QueueTrack(
            id: libraryID, title: title, artist: artist, album: album, duration: duration,
            artworkURL: LibraryArtwork.url(libraryID: libraryID, size: LibraryArtwork.largeSize),
            thumbnailURL: LibraryArtwork.url(libraryID: libraryID, size: LibraryArtwork.thumbnailSize),
            colors: colors, isExplicit: isExplicit, libraryID: libraryID
        )
    }

    /// This catalog song as the hub account's library copy `libraryID` (matched or added): still
    /// the catalog song (`id`, length, colors, album), with the library's title, artist and album
    /// where it has them, and its art through the hub.
    public func libraryCopy(libraryID: String, title: String?, artist: String?, album: String?) -> QueueTrack {
        var track = self
        track.libraryID = libraryID
        if let title, !title.isEmpty { track.title = title }
        if let artist, !artist.isEmpty { track.artist = artist }
        if let album, !album.isEmpty { track.album = album }
        track.artworkURL = LibraryArtwork.url(libraryID: libraryID, size: LibraryArtwork.largeSize)
        track.thumbnailURL = LibraryArtwork.url(libraryID: libraryID, size: LibraryArtwork.thumbnailSize)
        return track
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, artworkURL, thumbnailURL, colors, isExplicit, albumID, libraryID
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
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
    }
}

/// Artwork for the hub account's library songs (`QueueTrack.libraryID`). Their own art has no
/// public image URL: only the hub can load it (through MusicKit), so it serves it at
/// `/api/artwork/<library id>?size=<px>`. Tracks carry that path relative: the web page loads it
/// from the hub that served the page, a display resolves it against its hub's address
/// (`resolvingArtwork(against:)`), and the hub's own views against its own server.
public enum LibraryArtwork {
    public static let pathPrefix = "/api/artwork/"
    /// Now Playing's size and a row's, as catalog songs' `artworkURL` and `thumbnailURL`.
    public static let largeSize = 1200
    public static let thumbnailSize = 160

    public static func url(libraryID: String, size: Int) -> URL? {
        URL(string: "\(pathPrefix)\(libraryID)?size=\(size)")
    }

    /// An Apple Music library id as the library gives it: "i." and letters and digits. Nothing
    /// else goes into a relay path or a Sonos URI.
    public static func isLibraryID(_ id: String) -> Bool {
        guard id.hasPrefix("i."), id.count <= 64 else { return false }
        let rest = id.dropFirst(2)
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

public extension QueueTrack {
    /// With relative artwork (a hub's relay, `LibraryArtwork`) made absolute against `base`, the
    /// hub's address. Absolute URLs (catalog art) are left as they are.
    func resolvingArtwork(against base: URL) -> QueueTrack {
        var track = self
        track.artworkURL = artworkURL.map { Self.resolve($0, against: base) }
        track.thumbnailURL = thumbnailURL.map { Self.resolve($0, against: base) }
        return track
    }

    private static func resolve(_ url: URL, against base: URL) -> URL {
        guard url.scheme == nil else { return url }
        return URL(string: url.relativeString, relativeTo: base)?.absoluteURL ?? url
    }
}

public extension QueueItem {
    func resolvingArtwork(against base: URL) -> QueueItem {
        var item = self
        item.track = track.resolvingArtwork(against: base)
        return item
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
