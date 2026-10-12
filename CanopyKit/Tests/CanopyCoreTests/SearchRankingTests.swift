import Testing
@testable import CanopyCore

@Suite struct SearchRankingTests {
    let popular = QueueTrack(id: "1", title: "Big Hearts & Downfalls (Fast)", artist: "DJKUU305", album: "Big Hearts & Downfalls")
    let nearMiss = QueueTrack(id: "2", title: "Downfall (feat. Young Dolph)", artist: "Lil Durk", album: "Signed to the Streets 3")
    let albumTrack = QueueTrack(id: "3", title: "Shady Grove", artist: "Lance Rhicard", album: "Big Heart Down")
    let exact = QueueTrack(id: "4", title: "Big Heart Down", artist: "Lance Rhicard", album: "Big Heart Down")

    @Test func exactTitleThenLibraryThenOtherMatchesThenTheRest() {
        let ranked = SearchRanking.rank([popular, nearMiss, albumTrack, exact], for: "Big heart down", library: ["3", "4"])
        #expect(ranked.map(\.id) == ["4", "3", "1", "2"])
    }

    @Test func halfTypedLastWordStillMatches() {
        let beacons = QueueTrack(id: "b", title: "The Lighting of the Beacons", artist: "Howard Shore", album: "The Return of the King")
        let junk = QueueTrack(id: "j", title: "All the Small Things", artist: "blink-182", album: "Enema of the State")
        #expect(SearchRanking.rank([junk, beacons], for: "lighting of the beac").map(\.id) == ["b", "j"])
    }

    @Test func ignoresCaseAccentsAndApostrophes() {
        #expect(SearchRanking.words("Beyoncé's  Single-Ladies") == ["beyonces", "single", "ladies"])
        let track = QueueTrack(id: "x", title: "Halo", artist: "Beyoncé", album: "I Am... Sasha Fierce")
        let other = QueueTrack(id: "y", title: "Sorry", artist: "Justin Bieber", album: "Purpose")
        #expect(SearchRanking.rank([other, track], for: "beyonc").map(\.id) == ["x", "y"])
    }

    @Test func keepsOrderWithinATier() {
        let a = QueueTrack(id: "a", title: "Mean", artist: "Taylor Swift")
        let b = QueueTrack(id: "b", title: "Mine", artist: "Taylor Swift")
        #expect(SearchRanking.rank([a, b], for: "taylor sw").map(\.id) == ["a", "b"])
    }
}
