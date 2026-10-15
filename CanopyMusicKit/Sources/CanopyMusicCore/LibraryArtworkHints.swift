import Foundation

/// What's known of a library song's art from the service's listing of it (`LibraryArtworkHints`).
public struct LibraryArtworkHint: Sendable, Equatable {
    /// The song's own art: an image URL with `{w}` and `{h}` where its size goes.
    public var template: String?
    /// For a song without art of its own: another song's on the same library album.
    public var albumTemplate: String?
    /// The library album it's on (`LibraryArtworkHints.albumKey`): its songs share one image, so
    /// the relay downloads it once for all of them.
    public var album: String?

    public init(template: String? = nil, albumTemplate: String? = nil, album: String? = nil) {
        self.template = template
        self.albumTemplate = albumTemplate
        self.album = album
    }

    /// `template` at `size` pixels square, as MusicKit fills Apple Music's templates: `{w}` and
    /// `{h}`, and `{c}` (crop, "bb") and `{f}` (format, "jpg") where it has them. Left in, those
    /// two make the server send the original upload, megabytes of it, whatever the size asked.
    public static func url(_ template: String, size: Int) -> URL? {
        URL(string: template.replacingOccurrences(of: "{w}", with: "\(size)").replacingOccurrences(of: "{h}", with: "\(size)")
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: "jpg"))
    }
}

/// The art of library songs as the service listed them (a library playlist's tracks, a search),
/// so the hub's relay (`/api/artwork/…`) downloads each image straight away rather than asking the
/// service for the song again: Apple Music's library songs come with their artwork's URL template.
/// A song without art of its own gets one of its album's (another song of the same album, `albumKey`,
/// that has some). Kept across launches in Caches, so a restored queue's art needs no lookups
/// either; the `maxSongs` most recently listed.
public actor LibraryArtworkHints {
    /// A song as listed: its library id, its art's template (nil when it has none), and its album:
    /// the library album's id where the listing has it, and its title and the song's artist.
    public struct Listing: Sendable, Equatable {
        public var libraryID: String
        public var template: String?
        public var album: String
        public var artist: String
        public var albumID: String?

        public init(libraryID: String, template: String?, album: String, artist: String, albumID: String? = nil) {
            self.libraryID = libraryID
            self.template = template
            self.album = album
            self.artist = artist
            self.albumID = albumID
        }
    }

    private struct Entry: Codable {
        var template: String?
        var album: String?
        var listed: Date
    }

    public static let maxSongs = 5000

    public static let shared = LibraryArtworkHints(url: URL.cachesDirectory.appending(path: "library-artwork-hints.json"))

    private let url: URL?
    private let now: @Sendable () -> Date
    private var songs: [String: Entry]
    /// An album's art (`albumKey`): the first of its songs listed with some.
    private var albums: [String: String] = [:]
    private var changed = false

    /// `url` nil keeps everything in memory only.
    public init(url: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
        songs = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        albums = Self.albums(of: songs)
    }

    private static func albums(of songs: [String: Entry]) -> [String: String] {
        var albums: [String: String] = [:]
        for entry in songs.values {
            if let album = entry.album, let template = entry.template, albums[album] == nil { albums[album] = template }
        }
        return albums
    }

    /// The songs of one library album: by its id when the listing has it ("id:l.…"), since an
    /// album's songs needn't credit the same artist (a cast recording, a soundtrack's guests: one
    /// download per artist, on the iPad); else the same album title and artist, ignoring case,
    /// accents and punctuation. nil without either.
    public static func albumKey(album: String, artist: String, albumID: String? = nil) -> String? {
        if let albumID, !albumID.isEmpty { return "id:" + albumID }
        let title = SearchRanking.words(album)
        guard !title.isEmpty else { return nil }
        return title.joined(separator: " ") + "|" + SearchRanking.words(artist).joined(separator: " ")
    }

    public func record(_ listings: [Listing]) {
        for listing in listings {
            let old = songs[listing.libraryID]
            var album = Self.albumKey(album: listing.album, artist: listing.artist, albumID: listing.albumID)
            // A search lists songs without their album's id: keep the one a playlist listed.
            if listing.albumID == nil, let known = old?.album, known.hasPrefix("id:") { album = known }
            if old?.template != listing.template || old?.album != album { changed = true }
            songs[listing.libraryID] = Entry(template: listing.template, album: album, listed: now())
            if let album, let template = listing.template, albums[album] == nil { albums[album] = template }
        }
        guard songs.count > Self.maxSongs else { return }
        let keep = songs.sorted { $0.value.listed > $1.value.listed }.prefix(Self.maxSongs)
        songs = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        albums = Self.albums(of: songs)
        changed = true
    }

    /// nil for a song never listed.
    public func hint(for libraryID: String) -> LibraryArtworkHint? {
        guard let entry = songs[libraryID] else { return nil }
        if let template = entry.template { return LibraryArtworkHint(template: template, album: entry.album) }
        return LibraryArtworkHint(albumTemplate: entry.album.flatMap { albums[$0] }, album: entry.album)
    }

    /// Writes to disk if anything changed since the last save (call once after a batch).
    public func save() {
        guard changed, let url else { return }
        changed = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(songs).write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[artwork] couldn't save \(url.lastPathComponent): \(error)")
            #endif
        }
    }
}
