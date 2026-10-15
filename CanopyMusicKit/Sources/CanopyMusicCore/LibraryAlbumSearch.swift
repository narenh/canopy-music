import Foundation

/// A host's search finds the library's songs by album title too. Apple Music's library search
/// matches a phrase only within one field: songs by title or artist, albums by title, so
/// "spring awakening tour" finds nothing of "Spring Awakening (Tour, SF)" (no album title has all
/// three words, as the API reads them) and "hobbit glenn" finds nothing of Glenn Yarbrough's "The
/// Hobbit". So the search also asks with fewer words (`broaderTerm`), keeps what has every typed
/// word somewhere in its title, artist or album (`matches`), and adds the songs of the albums the
/// words name best (`albumsToExpand`). Ranking then puts them with the other matches
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
    public static let maxAlbums = 3
    public static let maxSongs = 40

    /// What to ask the service as well, for results `term` misses as a phrase: its words without
    /// the last ("spring awakening" for "spring awakening tour", "hobbit" for "hobbit glenn"). It
    /// stays the same while the last word is typed, so it's asked once for all those keystrokes.
    /// nil for one word.
    public static func broaderTerm(for term: String) -> String? {
        let words = SearchRanking.words(term)
        guard words.count > 1 else { return nil }
        return words.dropLast().joined(separator: " ")
    }

    /// Every typed word starts a word of the title, artist or album.
    public static func matches(title: String, artist: String, album: String, term: String) -> Bool {
        let query = SearchRanking.words(term)
        let haystack = SearchRanking.words("\(title) \(artist) \(album)")
        return !query.isEmpty && query.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
    }

    /// The albums whose songs a search for `term` should add: every typed word starts a word of
    /// the album's title or artist, and at least one starts a word of its title, so an artist's
    /// name alone ("glenn yarbrough") doesn't open every album of theirs (the song search finds
    /// those). Those with the most typed words in the title first ("spring awakening tour": both
    /// Tour albums before "Spring Awakening (Demos)", which hasn't "tour" at all), else in the
    /// order given (the service's); `maxAlbums` at most.
    public static func albumsToExpand(_ albums: [Album], for term: String) -> [Album] {
        let query = SearchRanking.words(term)
        guard !query.isEmpty else { return [] }
        let scored = albums.compactMap { album -> (album: Album, inTitle: Int)? in
            let title = SearchRanking.words(album.name)
            let haystack = title + SearchRanking.words(album.artist)
            guard query.allSatisfy({ word in haystack.contains { $0.hasPrefix(word) } }) else { return nil }
            let inTitle = query.filter { word in title.contains { $0.hasPrefix(word) } }.count
            return inTitle > 0 ? (album, inTitle) : nil
        }
        let ranked = scored.enumerated().sorted { ($1.element.inTitle, $0.offset) < ($0.element.inTitle, $1.offset) }
        return ranked.prefix(maxAlbums).map(\.element.album)
    }

    /// The albums' songs (`songs[album.id]`, each album's in its order), album by album in
    /// `albums`' order, `maxSongs` in all.
    public static func songs<Song>(of albums: [Album], from songs: [String: [Song]]) -> [Song] {
        Array(albums.flatMap { songs[$0.id] ?? [] }.prefix(maxSongs))
    }
}
