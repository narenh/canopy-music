import Foundation
import Testing
@testable import CanopyMusicCore

@Suite struct CatalogMatchingTests {
    // As the library describes an iTunes Match copy (no catalog id).
    let prologue = QueueTrack(
        id: "i.abc", title: "Prologue: One Ring To Rule Them All", artist: "Howard Shore",
        album: "The Lord of the Rings: The Fellowship of the Ring (Original Motion Picture Soundtrack)", duration: 22
    )

    func candidate(
        _ id: String = "1369922084", title: String? = nil, artist: String? = nil, album: String? = nil,
        duration: TimeInterval? = 22.4
    ) -> QueueTrack {
        QueueTrack(id: id, title: title ?? prologue.title, artist: artist ?? prologue.artist,
                   album: album ?? prologue.album, duration: duration)
    }

    @Test func normalizesCaseAccentsPunctuationAndSpacing() {
        #expect(CatalogMatching.normalized("Prologue:  One Ring To Rule Them All") == "prologue one ring to rule them all")
        #expect(CatalogMatching.normalized("Beyoncé") == CatalogMatching.normalized("BEYONCE"))
        #expect(CatalogMatching.normalized("Don’t Stop Me Now") == CatalogMatching.normalized("Don't Stop Me Now"))
        #expect(CatalogMatching.normalized("Simon & Garfunkel") == CatalogMatching.normalized("Simon and Garfunkel"))
        #expect(CatalogMatching.normalized("Sigur Rós – ( ) Untitled #1") == "sigur ros untitled 1")
        #expect(CatalogMatching.normalized("...") == "...")
    }

    @Test func acceptsTheSameRecording() {
        #expect(CatalogMatching.accepts(candidate(title: "Prologue: One Ring to Rule Them All"), for: prologue))
        #expect(CatalogMatching.accepts(candidate(duration: nil), for: prologue))
    }

    @Test func acceptsAccentAndCaseDifferences() {
        let wanted = QueueTrack(id: "i.x", title: "Hoppípolla", artist: "Sigur Rós", album: "Takk...", duration: 268)
        let found = QueueTrack(id: "1", title: "Hoppipolla", artist: "Sigur Ros", album: "Takk…", duration: 269.5)
        #expect(CatalogMatching.accepts(found, for: wanted))
    }

    @Test func rejectsOtherEditions() {
        #expect(!CatalogMatching.accepts(candidate(title: "Prologue: One Ring To Rule Them All (Live)"), for: prologue))
        #expect(!CatalogMatching.accepts(candidate(title: "Prologue: One Ring To Rule Them All - Remastered"), for: prologue))
        #expect(!CatalogMatching.accepts(candidate(album: "The Lord of the Rings: The Complete Recordings"), for: prologue))
        #expect(!CatalogMatching.accepts(candidate(album: prologue.album + " [Remastered]"), for: prologue))
    }

    @Test func rejectsOtherArtists() {
        #expect(!CatalogMatching.accepts(candidate(artist: "City of Prague Philharmonic Orchestra"), for: prologue))
    }

    @Test func rejectsDifferentLengths() {
        #expect(!CatalogMatching.accepts(candidate(duration: 26), for: prologue))
        #expect(CatalogMatching.accepts(candidate(duration: 25), for: prologue))
    }

    @Test func picksTheClosestLengthThenTheEarliest() {
        let far = candidate("far", duration: 24.5)
        let close = candidate("close", duration: 22.1)
        let live = candidate("live", title: prologue.title + " (Live)", duration: 22)
        #expect(CatalogMatching.bestMatch(among: [live, far, close], for: prologue)?.id == "close")
        #expect(CatalogMatching.bestMatch(among: [candidate("a"), candidate("b")], for: prologue)?.id == "a")
        #expect(CatalogMatching.bestMatch(among: [live], for: prologue) == nil)
        #expect(CatalogMatching.bestMatch(among: [], for: prologue) == nil)
    }
}

@Suite struct CatalogMatchMemoryTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "catalog-matches-\(UUID().uuidString)/matches.json")
    }

    @Test func remembersMatchesAcrossInstances() async {
        let url = tempURL()
        let memory = CatalogMatchMemory(url: url)
        #expect(await memory.recall("i.a") == .unknown)
        await memory.remember("123", for: "i.a")
        await memory.save()
        let reloaded = CatalogMatchMemory(url: url)
        #expect(await reloaded.recall("i.a") == .match("123"))
        await reloaded.forget("i.a")
        #expect(await reloaded.recall("i.a") == .unknown)
    }

    @Test func missesExpireAfterADay() async {
        let clock = Clock()
        let url = tempURL()
        let memory = CatalogMatchMemory(url: url, now: { clock.now })
        await memory.remember(nil, for: "i.b")
        #expect(await memory.recall("i.b") == .recentMiss)
        await memory.save()
        #expect(await CatalogMatchMemory(url: url, now: { clock.now }).recall("i.b") == .recentMiss)
        clock.now += CatalogMatchMemory.missLifetime + 1
        #expect(await memory.recall("i.b") == .unknown)
    }

    @Test func aMatchReplacesAMiss() async {
        let memory = CatalogMatchMemory(url: nil)
        await memory.remember(nil, for: "i.c")
        await memory.remember("9", for: "i.c")
        #expect(await memory.recall("i.c") == .match("9"))
    }
}
