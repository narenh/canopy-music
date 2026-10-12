import Foundation
import Testing
@testable import CanopyMusicCore

/// Remembers what it was asked to save.
final class SavingCatalog: MusicCatalog, @unchecked Sendable {
    var ids: [String]
    var saved: [(name: String, description: String, tracks: [QueueTrack])] = []
    var error: Error?
    init(ids: [String]) { self.ids = ids }
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { ids.map(track) }
    var playlistDestination: String? { "Saves to a test library" }
    func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        if let error { throw error }
        saved.append((name, description, tracks))
    }
}

private func phone(_ name: String?, _ id: String = UUID().uuidString) -> Requester {
    Requester(name: name, clientID: id, origin: .phone)
}

private func item(_ id: String, by requester: Requester? = nil) -> QueueItem {
    QueueItem(track: track(id), requester: requester)
}

@Suite struct PartyLogTests {
    @Test func keepsPlayOrderAndCountsEachItemOnce() {
        var log = PartyLog()
        let a = item("a"), b = item("b", by: guest)
        log.record(a, at: Date(timeIntervalSince1970: 100))
        log.record(b, at: Date(timeIntervalSince1970: 200))
        log.record(a, at: Date(timeIntervalSince1970: 300)) // went back to it
        #expect(log.songs.map(\.track.id) == ["a", "b"])
        #expect(log.startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func isNotCappedLikeHistory() {
        var log = PartyLog()
        for i in 0..<(QueueState.historyLimit + 50) { log.record(item("s\(i)")) }
        #expect(log.songs.count == QueueState.historyLimit + 50)
    }

    @Test func onlyRequestsLeavesOutTheBasePlaylist() {
        var log = PartyLog()
        log.record(item("a"))
        log.record(item("x", by: guest))
        log.record(item("b"))
        log.record(item("y", by: Requester(origin: .ipad)))
        #expect(log.tracks(onlyRequests: true).map(\.id) == ["x", "y"])
        #expect(log.tracks(onlyRequests: false).map(\.id) == ["a", "x", "b", "y"])
    }

    @Test func aSongThatPlayedTwiceIsSavedOnce() {
        var log = PartyLog()
        log.record(item("a"))
        log.record(item("b"))
        log.record(item("a", by: guest)) // requested again later
        #expect(log.tracks(onlyRequests: false).map(\.id) == ["a", "b"])
        #expect(log.tracks(onlyRequests: true).map(\.id) == ["a"])
    }

    @Test func creditsNamedPhonesMostSongsFirst() {
        var log = PartyLog()
        log.record(item("1", by: phone("Phil")))
        log.record(item("2", by: phone("Sam")))
        log.record(item("3", by: phone("sam")))
        #expect(log.credit(onlyRequests: true) == "Queued by Sam and Phil")
        #expect(log.playlistDescription(onlyRequests: true) == "Queued by Sam and Phil · Canopy Music")
    }

    @Test func creditsThreeByNameAndMoreAsOthers() {
        var log = PartyLog()
        for name in ["Sam", "Phil", "Ana"] { log.record(item(name, by: phone(name))) }
        #expect(log.credit(onlyRequests: true) == "Queued by Sam, Phil and Ana")
        for name in ["Jo", "Lee", "Kai", "Max", "Ivy"] { log.record(item(name, by: phone(name))) }
        log.record(item("Sam again", by: phone("Sam")))
        log.record(item("Phil again", by: phone("Phil")))
        #expect(log.credit(onlyRequests: true) == "Queued by Sam, Phil and 6 others")
    }

    /// Only people: not the hub, not displays ("Kitchen iPad"), not phones without a name.
    @Test func creditsOnlyNamedPeople() {
        var log = PartyLog()
        log.record(item("a", by: Requester(origin: .ipad)))
        log.record(item("b", by: Requester(name: "Kitchen iPad", clientID: "display", origin: .ipad)))
        log.record(item("c", by: phone(nil)))
        log.record(item("d", by: phone("Guest")))
        log.record(item("e", by: phone("  ")))
        #expect(log.credit(onlyRequests: true) == nil)
        #expect(log.playlistDescription(onlyRequests: true) == "Canopy Music")
        log.record(item("f", by: phone("Sam")))
        #expect(log.playlistDescription(onlyRequests: false) == "Queued by Sam · Canopy Music")
    }

    @Test func suggestsThePartysStartDate() {
        var log = PartyLog()
        let utc = TimeZone(identifier: "UTC")!
        log.record(item("a"), at: Date(timeIntervalSince1970: 1_791_849_600)) // 2026-10-13 00:00 UTC
        #expect(log.suggestedName(timeZone: utc) == "2026-10-13 ")
        #expect(log.suggestedName(timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-10-12 ")
    }
}

@MainActor
@Suite struct PartyLogSessionTests {
    @Test func logsSongsAsTheyStartPlaying() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        #expect(session.partyLog.isEmpty) // loaded, not played
        try await session.play()
        await settle()
        engine.finishTrack() // b starts
        await settle()
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "b"])
    }

    @Test func aSongSkippedWhilePausedDoesNotCount() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.pause()
        await session.skip() // b becomes current without playing
        await session.skip() // c
        try await session.play()
        await settle()
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "c"])
    }

    @Test func aSongThatFailedToPlayDoesNotCount() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        engine.playError = URLError(.notConnectedToInternet)
        _ = try? await session.play()
        #expect(session.partyLog.isEmpty)
    }

    @Test func goingBackDoesNotLogItAgain() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.finishTrack()
        await settle()
        await session.previous() // back to a, playing
        await settle()
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "b"])
    }

    @Test func survivesARelaunchAndEndClearsIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await first.load(playlist: base)
        try await first.play()
        try await Task.sleep(for: .milliseconds(800))

        let restored = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(restored.partyLog.songs.map(\.track.id) == ["a"])
        restored.end()
        #expect(restored.partyLog.isEmpty)
        let next = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(next.partyLog.isEmpty)
    }

    @Test func aNewBasePlaylistKeepsTheLog() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.play()
        try await session.load(playlist: PlaylistSummary(id: "q", name: "Other", kind: .library))
        #expect(session.partyLog.songs.map(\.track.id) == ["a"])
    }

    @Test func savesRequestsInOrderWithTheCredit() async throws {
        let catalog = SavingCatalog(ids: ["a", "b", "c"])
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        session.add(track("x"), by: guest)
        try await session.play() // x (requests go first)
        await settle()
        engine.finishTrack() // a
        await settle()
        #expect(session.partySaveInfo.allCount == 2)
        #expect(session.partySaveInfo.requestCount == 1)
        #expect(session.partySaveInfo.destination == "Saves to a test library")

        let count = try await session.savePartyPlaylist(name: " 2026-10-12 Sam's birthday ", onlyRequests: true)
        #expect(count == 1)
        #expect(catalog.saved.first?.name == "2026-10-12 Sam's birthday")
        #expect(catalog.saved.first?.description == "Queued by Sam · Canopy Music")
        #expect(catalog.saved.first?.tracks.map(\.id) == ["x"])
        try await session.savePartyPlaylist(name: "All", onlyRequests: false)
        #expect(catalog.saved.last?.tracks.map(\.id) == ["x", "a"])
        // Saving doesn't end anything.
        #expect(session.partyLog.songs.count == 2)
    }

    @Test func nothingToSave() async throws {
        let catalog = SavingCatalog(ids: ["a"])
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.play()
        await #expect(throws: PartySaveError.nothingToSave(onlyRequests: true)) {
            try await session.savePartyPlaylist(name: "x", onlyRequests: true)
        }
        #expect(catalog.saved.isEmpty)
    }

    /// "Scan to host" / "Continue on your phone", and no announcement, until a TV zone's host picks music.
    @Test func aTVZoneWaitsForItsHostToPickTheMusic() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        #expect(!session.isWaitingForSetup) // not a hub yet
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Demo")
        #expect(session.isWaitingForSetup)
        try await session.load(playlist: base)
        #expect(!session.isWaitingForSetup)

        let ipad = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine())
        ipad.configureHub(kind: .ipad, zoneName: "Kitchen", serviceName: "Demo")
        #expect(!ipad.isWaitingForSetup)
    }

    @Test func aBlankNameGetsTheDate() async throws {
        let catalog = SavingCatalog(ids: ["a"])
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.play()
        try await session.savePartyPlaylist(name: "  ", onlyRequests: false)
        #expect(catalog.saved.first?.name == session.partyLog.suggestedName().trimmingCharacters(in: .whitespaces))
    }
}
