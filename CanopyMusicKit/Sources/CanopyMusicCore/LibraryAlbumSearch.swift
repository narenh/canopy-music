import Foundation

/// A host's search finds the library's songs by album title too. Apple Music's library song search
/// matches song titles and artists, not album titles ("spring awakening tour" finds nothing of
/// "Spring Awakening (Tour, SF)"), so the search asks for library albums as well and adds the songs
/// of the few albums the typed words name. Ranking then puts them with the other matches
/// (`SearchRanking`: every word starts a word of the title, artist or album).
public enum LibraryAlbumSearch {
    public struct Album: Sendable, Equatable {
        public var id: String
        public var name: String
        public var artist: String

        public init(id: String, name: String, artist: String) {
            self.id = id
            self.name = name
            self.artist = artist
        }
    }

    /// Albums expanded a search, and songs added from them in all: a search runs as a host types.
    public static let maxAlbums = 2
    public static let maxSongs = 30

    /// The albums whose songs a search for `term` should add, in the order given (the service's):
    /// every typed word starts a word of the album's title or artist, and at least one starts a
    /// word of its title, so an artist's name alone ("glenn yarbrough") doesn't open every album
    /// of theirs; the song search finds those. `maxAlbums` at most.
    public static func albumsToExpand(_ albums: [Album], for term: String) -> [Album] {
        let query = SearchRanking.words(term)
        guard !query.isEmpty else { return [] }
        let matching = albums.filter { album in
            let title = SearchRanking.words(album.name)
            let haystack = title + SearchRanking.words(album.artist)
            return query.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
                && query.contains { word in title.contains { $0.hasPrefix(word) } }
        }
        return Array(matching.prefix(maxAlbums))
    }

    /// The albums' songs (`songs[album.id]`, each album's in its order), album by album in
    /// `albums`' order, `maxSongs` in all.
    public static func songs<Song>(of albums: [Album], from songs: [String: [Song]]) -> [Song] {
        Array(albums.flatMap { songs[$0.id] ?? [] }.prefix(maxSongs))
    }
}
