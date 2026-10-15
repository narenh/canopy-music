import Testing
@testable import CanopyMusicCore

@Suite struct LibraryAlbumSearchTests {
    // The user's library, as the API lists "spring awakening" (the full phrase finds no album).
    let plain = LibraryAlbumSearch.Album(id: "l.plain", name: "Spring Awakening", artist: "Duncan Sheik")
    let demos = LibraryAlbumSearch.Album(id: "l.demos", name: "Spring Awakening (Demos)", artist: "Duncan Sheik")
    let sf = LibraryAlbumSearch.Album(id: "l.sf", name: "Spring Awakening (Tour, SF)", artist: "Spring Awakening Tour Cast")
    let soundboard = LibraryAlbumSearch.Album(id: "l.sb", name: "Spring Awakening (Tour, soundboard)", artist: "Spring Awakening Tour Cast")
    let hobbit = LibraryAlbumSearch.Album(id: "l.hb", name: "The Hobbit (Original Motion Picture Soundtrack)", artist: "Glenn Yarbrough")
    let other = LibraryAlbumSearch.Album(id: "l.ot", name: "Baby the Rain Must Fall", artist: "Glenn Yarbrough")

    @Test func theTourAlbumsWinForTour() {
        let listed = [plain, demos, sf, soundboard]
        #expect(LibraryAlbumSearch.albumsToExpand(listed, for: "spring awakening tour") == [sf, soundboard])
        // Half-typed, in any case, with the brackets and commas the titles have.
        #expect(LibraryAlbumSearch.albumsToExpand(listed, for: "Spring awak tou") == [sf, soundboard])
        #expect(LibraryAlbumSearch.albumsToExpand(listed, for: "awakening sf") == [sf])
        #expect(LibraryAlbumSearch.albumsToExpand(listed, for: "spring awakening demos") == [demos])
        // Two words that all four have: the first three, in the service's order.
        #expect(LibraryAlbumSearch.albumsToExpand(listed, for: "spring awakening") == [plain, demos, sf])
    }

    @Test func titleWordsBeforeArtistWords() {
        let tourCast = LibraryAlbumSearch.Album(id: "l.tc", name: "Spring Songs", artist: "Awakening Tour Cast")
        // Both have every word; the one with more of them in its title first.
        #expect(LibraryAlbumSearch.albumsToExpand([tourCast, sf], for: "spring awakening tour") == [sf, tourCast])
    }

    @Test func hobbitAndGlenn() {
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "hobbit glenn") == [hobbit])
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "glenn yarbrough hobbit") == [hobbit])
        // The artist alone opens no album: the song search finds the artist's songs.
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "glenn yarbrough").isEmpty)
        #expect(LibraryAlbumSearch.albumsToExpand([other, hobbit], for: "").isEmpty)
    }

    /// What's asked as well: the words without the last, the same while the last is typed.
    @Test func broaderTerms() {
        #expect(LibraryAlbumSearch.broaderTerm(for: "spring awakening tour") == "spring awakening")
        #expect(LibraryAlbumSearch.broaderTerm(for: "Spring Awakening t") == "spring awakening")
        #expect(LibraryAlbumSearch.broaderTerm(for: "hobbit glenn") == "hobbit")
        #expect(LibraryAlbumSearch.broaderTerm(for: "hobbit") == nil)
    }

    /// Songs the broader search finds are kept when every typed word is in their title, artist
    /// or album.
    @Test func songsMatchAcrossTitleArtistAndAlbum() {
        #expect(LibraryAlbumSearch.matches(title: "Chip the Glasses", artist: "Glenn Yarbrough",
                                           album: "The Hobbit (Original Motion Picture Soundtrack)", term: "hobbit glenn"))
        #expect(LibraryAlbumSearch.matches(title: "Mama Who Bore Me", artist: "Spring Awakening Tour Cast",
                                           album: "Spring Awakening (Tour, SF)", term: "spring awakening tour"))
        #expect(!LibraryAlbumSearch.matches(title: "Mama Who Bore Me", artist: "Duncan Sheik",
                                            album: "Spring Awakening (Demos)", term: "spring awakening tour"))
    }

    @Test func aFewAlbumsAndSongsAtMost() {
        let many = (0..<5).map { LibraryAlbumSearch.Album(id: "l.\($0)", name: "Live \($0)", artist: "Band") }
        let expanded = LibraryAlbumSearch.albumsToExpand(many, for: "live")
        #expect(expanded.map(\.id) == ["l.0", "l.1", "l.2"])
        let songs = Dictionary(uniqueKeysWithValues: many.map { album in (album.id, (0..<20).map { "\(album.id)-\($0)" }) })
        let added = LibraryAlbumSearch.songs(of: expanded, from: songs)
        #expect(added.count == LibraryAlbumSearch.maxSongs)
        #expect(added.prefix(20) == songs["l.0"]![...])
        #expect(added.last == "l.1-19")
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
