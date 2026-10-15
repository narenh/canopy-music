import Testing
@testable import CanopyMusicCore

@Suite struct LibraryAlbumSearchTests {
    let sf = LibraryAlbumSearch.Album(id: "l.sf", name: "Spring Awakening (Tour, SF)", artist: "Spring Awakening Tour Cast")
    let soundboard = LibraryAlbumSearch.Album(id: "l.sb", name: "Spring Awakening (Tour, soundboard)", artist: "Spring Awakening Tour Cast")
    let broadway = LibraryAlbumSearch.Album(id: "l.bw", name: "Spring Awakening (Original Broadway Cast Recording)", artist: "Duncan Sheik")
    let hobbit = LibraryAlbumSearch.Album(id: "l.hb", name: "The Hobbit", artist: "Glenn Yarbrough")
    let other = LibraryAlbumSearch.Album(id: "l.ot", name: "Baby the Rain Must Fall", artist: "Glenn Yarbrough")

    @Test func wordsInTheTitleNameTheAlbum() {
        let albums = [broadway, sf, soundboard]
        #expect(LibraryAlbumSearch.albumsToExpand(albums, for: "spring awakening tour") == [sf, soundboard])
        // Half-typed, and in any case.
        #expect(LibraryAlbumSearch.albumsToExpand(albums, for: "Spring awak tou") == [sf, soundboard])
        #expect(LibraryAlbumSearch.albumsToExpand(albums, for: "awakening broadway") == [broadway])
    }

    @Test func artistWordsCountOnlyWithATitleWord() {
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "glenn yarbrough hobbit") == [hobbit])
        // The artist alone opens no album: the song search finds the artist's songs.
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "glenn yarbrough").isEmpty)
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "").isEmpty)
    }

    @Test func aFewAlbumsAndSongsAtMost() {
        let many = (0..<5).map { LibraryAlbumSearch.Album(id: "l.\($0)", name: "Live \($0)", artist: "Band") }
        let expanded = LibraryAlbumSearch.albumsToExpand(many, for: "live")
        #expect(expanded.map(\.id) == ["l.0", "l.1"])
        let songs = Dictionary(uniqueKeysWithValues: many.map { album in (album.id, (0..<20).map { "\(album.id)-\($0)" }) })
        let added = LibraryAlbumSearch.songs(of: expanded, from: songs)
        #expect(added.count == LibraryAlbumSearch.maxSongs)
        #expect(added.prefix(20) == songs["l.0"]![...])
        #expect(added.last == "l.1-9")
    }

    /// Album songs rank with the matches, after an exact title.
    @Test func rankedWithTheOtherMatches() {
        let albumSong = QueueTrack(id: "i.a", title: "Mama Who Bore Me", artist: "Spring Awakening Tour Cast", album: "Spring Awakening (Tour, SF)", libraryID: "i.a")
        let junk = QueueTrack(id: "c1", title: "Awakening", artist: "Someone", album: "Spring")
        let exact = QueueTrack(id: "c2", title: "Spring Awakening Tour", artist: "Someone Else")
        let ranked = SearchRanking.rank([junk, albumSong, exact], for: "spring awakening tour", library: ["i.a"])
        #expect(ranked.map(\.id) == ["c2", "i.a", "c1"])
    }
}
