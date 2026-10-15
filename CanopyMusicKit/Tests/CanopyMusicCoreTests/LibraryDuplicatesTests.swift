import Foundation
import Testing
@testable import CanopyMusicCore

/// A host's search of the library and the catalog together shows each song once
/// (`LibraryDuplicates`), and the queue treats a library copy as its catalog song.
@Suite struct LibraryDuplicatesTests {
    let catalog = QueueTrack(id: "1440857781", title: "The Shire", artist: "Howard Shore", album: "The Fellowship of the Ring",
                             artworkURL: URL(string: "https://is1-ssl.mzstatic.com/shire.jpg"))

    func copy(_ libraryID: String, appleMusic: Bool, artwork: Bool, title: String? = nil) -> LibraryDuplicates.Result {
        .library(.init(track: catalog.libraryCopy(libraryID: libraryID, title: title, artist: nil, album: "The Complete Recordings"),
                       isAppleMusicCopy: appleMusic, hasArtwork: artwork))
    }

    @Test func aLibraryCopyIsItsCatalogSong() {
        let mine = catalog.libraryCopy(libraryID: "i.Matched1", title: "The Shire (Concerning Hobbits)", artist: nil, album: "")
        #expect(mine.id == catalog.id)
        #expect(mine.libraryID == "i.Matched1")
        #expect(!mine.isLibraryOnly)
        #expect(mine.title == "The Shire (Concerning Hobbits)")
        #expect(mine.artist == "Howard Shore")
        #expect(mine.album == "The Fellowship of the Ring")
        // The host's own art, through the hub.
        #expect(mine.thumbnailURL?.relativeString == "/api/artwork/i.Matched1?size=160")
        let upload = QueueTrack.libraryOnly(libraryID: "i.Upload1", title: "Demo", artist: "Me")
        #expect(upload.isLibraryOnly)
    }

    /// The library copy and the catalog result for it are one song: the library's, where the
    /// first of them was.
    @Test func libraryCopyBeatsTheCatalogs() {
        let other = QueueTrack(id: "1440857790", title: "Other", artist: "Artist")
        let results = LibraryDuplicates.collapse([.catalog(other), .catalog(catalog), copy("i.Mine1", appleMusic: true, artwork: false)])
        #expect(results.map(\.id) == ["1440857790", "1440857781"])
        #expect(results[1].libraryID == "i.Mine1")
        // Either way round.
        let reversed = LibraryDuplicates.collapse([copy("i.Mine1", appleMusic: true, artwork: false), .catalog(catalog)])
        #expect(reversed.map(\.libraryID) == ["i.Mine1"])
    }

    /// An album in the library twice (the matched copy and the Apple Music one added later): the
    /// matched copy, whichever has art.
    @Test func matchedCopyBeatsTheAddedOne() {
        let results = LibraryDuplicates.collapse([
            copy("i.Added1", appleMusic: true, artwork: true),
            .catalog(catalog),
            copy("i.Matched1", appleMusic: false, artwork: false),
        ])
        #expect(results.count == 1)
        #expect(results.first?.libraryID == "i.Matched1")
    }

    /// Two copies it can't tell apart: the one with the library's own art, else the first.
    @Test func thenTheOneWithArtwork() {
        let byArt = LibraryDuplicates.collapse([copy("i.Plain1", appleMusic: true, artwork: false), copy("i.Art1", appleMusic: true, artwork: true)])
        #expect(byArt.map(\.libraryID) == ["i.Art1"])
        let first = LibraryDuplicates.collapse([copy("i.First1", appleMusic: false, artwork: true), copy("i.Second1", appleMusic: false, artwork: true)])
        #expect(first.map(\.libraryID) == ["i.First1"])
    }

    /// A song only in the library has no catalog id: it never stands in for anything else, even
    /// one with the same title.
    @Test func libraryOnlySongsStayApart() {
        let upload = LibraryDuplicates.Result.library(.init(
            track: .libraryOnly(libraryID: "i.Upload1", title: "The Shire", artist: "Howard Shore"), isAppleMusicCopy: false, hasArtwork: true))
        let again = LibraryDuplicates.Result.library(.init(
            track: .libraryOnly(libraryID: "i.Upload1", title: "The Shire", artist: "Howard Shore"), isAppleMusicCopy: false, hasArtwork: false))
        let otherUpload = LibraryDuplicates.Result.library(.init(
            track: .libraryOnly(libraryID: "i.Upload2", title: "The Shire", artist: "Howard Shore"), isAppleMusicCopy: false, hasArtwork: true))
        let results = LibraryDuplicates.collapse([.catalog(catalog), upload, otherUpload, again])
        #expect(results.map(\.id) == ["1440857781", "i.Upload1", "i.Upload2"])
        #expect(results[0].libraryID == nil)
    }

    /// The queue: a library copy and its catalog song are already queued as each other.
    @Test func alreadyQueuedAcrossLibraryAndCatalog() {
        var state = QueueState()
        state.load(playlist: [track("a"), track("b")], name: "Base")
        state.advance()
        let mine = catalog.libraryCopy(libraryID: "i.Mine1", title: nil, artist: nil, album: nil)
        guard case .added = state.addRequest(mine, by: guest) else { Issue.record("not added"); return }
        guard case .alreadyQueued = state.addRequest(catalog, by: Requester(name: "Kim", clientID: "phone-2", origin: .phone)) else {
            Issue.record("the catalog song queued as another song")
            return
        }
        // And the other way round.
        var other = QueueState()
        other.load(playlist: [track("a"), track("b")], name: "Base")
        other.advance()
        _ = other.addRequest(catalog, by: guest)
        guard case .alreadyQueued = other.addRequest(mine, by: Requester(name: "Kim", clientID: "phone-2", origin: .phone)) else {
            Issue.record("the library copy queued as another song")
            return
        }
    }
}
