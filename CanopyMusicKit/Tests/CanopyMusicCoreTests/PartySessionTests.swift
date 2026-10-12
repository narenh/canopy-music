import Foundation
import Testing
@testable import CanopyMusicCore

@MainActor
final class FakeEngine: PlaybackEngine {
    let canReplaceStaged: Bool
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: QueueTrack?
    var staged: QueueTrack?

    init(canReplaceStaged: Bool = true) { self.canReplaceStaged = canReplaceStaged }

    /// Thrown by the next `play`, then cleared.
    var playError: Error?

    func play(_ track: QueueTrack) async throws {
        if let playError { self.playError = nil; throw playError }
        playing = track; staged = nil; isPlaying = true
    }
    func stage(_ track: QueueTrack?) async throws { staged = track }
    func resume() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    func skipToStaged() async throws { finishTrack() }
    func restartCurrent() { currentTime = 0 }
    func seek(to time: TimeInterval) { currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    func finishTrack() {
        if let staged { playing = staged; self.staged = nil; onEvent?(.advancedToStaged) }
        else { playing = nil; onEvent?(.reachedEnd) }
    }
}

struct StubCatalog: MusicCatalog {
    var ids: [String]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { ids.map(track) }
}

let base = PlaylistSummary(id: "p", name: "Base", kind: .library)

/// Lets queued `Task { await syncStaging() }` work run.
@MainActor func settle() async { for _ in 0..<200 { await Task.yield() } }

@MainActor
@Suite struct PartySessionTests {
    @Test func reorderSettingReachesPhones() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        #expect(session.snapshot().canReorder)
        session.phonesCanReorder = false
        #expect(!session.snapshot().canReorder)
    }

    @Test func loadingAPlaylistDoesNotPlay() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        await settle()
        #expect(session.state.current == nil)
        #expect(session.state.upNext.first?.track.id == "a")
        #expect(engine.playing == nil)
        #expect(engine.staged == nil)
    }

    @Test func loadingANewPlaylistStopsAndClears() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        try await session.load(playlist: PlaylistSummary(id: "q", name: "Other", kind: .library))
        #expect(!engine.isPlaying)
        #expect(session.state.current == nil)
        #expect(!session.state.upNext.contains { $0.isRequest })
        #expect(session.state.playlistName == "Other")
    }

    @Test func playAfterRestoreLoadsCurrentSong() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await first.load(playlist: base)
        try await Task.sleep(for: .milliseconds(800))
        let engine = FakeEngine()
        let restored = PartySession(catalog: StubCatalog(ids: []), engine: engine, storeURL: url)
        try await restored.play()
        await settle()
        #expect(engine.playing?.id == "a")
        #expect(engine.staged?.id == "b")
    }

    @Test func startPlaysAndStagesNext() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "a")
        #expect(engine.staged?.id == "b")
    }

    @Test func requestReplacesStagedTrack() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        await settle()
        #expect(engine.staged?.id == "x")
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "x")
        #expect(engine.staged?.id == "b")
    }

    @Test func advancesToWhatWasActuallyStaged() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        // Player already committed to "b"; a reorder lands before staging catches up.
        let c = session.state.upNext[1].id
        session.move(c, to: 0)
        engine.finishTrack() // plays "b" before the restage runs
        await settle()
        #expect(session.state.current?.track.id == "b")
        #expect(session.state.upNext.first?.track.id == "c")
    }

    @Test func phonesCanOnlyRemoveTheirOwnRequests() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.play()
        guard case .added(let item, _) = session.add(track("x"), by: guest) else { Issue.record("not added"); return }
        #expect(!session.remove(item.id, asClient: "someone-else"))
        let playlistItem = session.state.upNext.first { !$0.isRequest }!
        #expect(!session.remove(playlistItem.id, asClient: "phone-1"))
        #expect(session.remove(item.id, asClient: "phone-1"))
    }

    @Test func reachingTheEndRestartsFromQueue() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.staged = nil // simulate a failed stage
        engine.finishTrack()
        await settle()
        #expect(engine.playing?.id == "b")
    }

    @Test func previousRestartsLateInSongOtherwiseGoesBack() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.finishTrack() // now "b"
        await settle()
        engine.currentTime = 30
        await session.previous()
        #expect(session.state.current?.track.id == "b") // restarted, not gone back
        #expect(engine.currentTime == 0)
        await session.previous()
        #expect(session.state.current?.track.id == "a")
        #expect(engine.playing?.id == "a")
        #expect(session.state.upNext.first?.track.id == "b")
    }

    @Test func rapidBackBackNextStaysConsistent() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.finishTrack() // b
        await settle()
        engine.finishTrack() // c
        await settle()
        #expect(session.state.current?.track.id == "c")
        // Fire all three without waiting, like quick taps.
        async let back1: Void = session.previous()
        async let back2: Void = session.previous()
        async let next: Void = session.skip()
        _ = await (back1, back2, next)
        await settle()
        #expect(session.state.current?.track.id == "b")
        #expect(engine.playing?.id == "b")
        #expect(engine.staged?.id == session.state.upNext.first?.track.id)
    }

    @Test func persistsAndRestores() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        try await Task.sleep(for: .milliseconds(800))
        let restored = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(restored.state.current?.track.id == "a")
        #expect(restored.state.upNext.first?.track.id == "x")
    }

    @Test func snapshotStreamEmitsOnChange() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        var iterator = session.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.current == nil)
        try await session.load(playlist: base)
        try await session.play()
        let next = await iterator.next()
        #expect(next != nil)
        #expect(next!.version > first!.version)
    }

    /// A renamed zone's new `.local` address reaches pages right away, so they can follow it.
    @Test func newAddressIsSent() async throws {
        let session = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine())
        session.guestAddress = "upstairs.local"
        var iterator = session.snapshots().makeAsyncIterator()
        #expect(await iterator.next()?.address == "upstairs.local")
        session.guestAddress = "living-room.local"
        #expect(await iterator.next()?.address == "living-room.local")
    }
}

@MainActor
@Suite struct PlaybackSyncTests {
    /// The player's time moved with no event (a late seek, buffering): listeners get it resent.
    @Test func driftIsResent() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        engine.currentTime = 10
        var snapshots = session.snapshots().makeAsyncIterator()
        let first = try #require(await snapshots.next())
        #expect(abs(first.playback.position - 10) < 0.01)
        // FakeEngine's time doesn't advance by itself, so a playing listener's estimate runs
        // ahead; jump it further to make the drift unambiguous.
        engine.currentTime = 95
        let next = try #require(await snapshots.next())
        #expect(abs(next.playback.position - 95) < 0.01)
    }
}

@MainActor
@Suite struct PlayFailureTests {
    /// A failed play leaves nothing loaded, so nothing is staged onto the broken player.
    @Test func failedPlayStagesNothing() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        engine.playError = URLError(.cannotConnectToHost)
        await #expect(throws: (any Error).self) { try await session.play() }
        await settle()
        #expect(engine.staged == nil)
        // Pressing play again works and stages as usual.
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "a")
        #expect(engine.staged?.id == "b")
    }
}

@MainActor
@Suite struct UpcomingListTests {
    /// Pages load as asked, and when a song plays the next one moves from the list to the live
    /// queue without showing twice.
    @Test func pagesAndFollowsTheQueue() async throws {
        let count = QueueState.playlistWindow + 120
        let session = PartySession(catalog: StubCatalog(ids: (0..<count).map { "t\($0)" }), engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.play()
        let list = UpcomingList()
        await list.loadMore(from: session)
        #expect(list.rows.count == UpcomingList.pageSize)
        #expect(list.total == count - 1 - QueueState.playlistWindow)
        await list.loadMore(from: session)
        await list.loadMore(from: session)
        #expect(list.rows.count == list.total)
        #expect(!list.hasMore)

        let next = try #require(list.rows.first?.trackID)
        await session.skip()
        #expect(session.state.upNext.last?.track.id == next)
        list.queueChanged(in: session, settle: .zero)
        #expect(list.rows.first?.trackID != next) // gone at once
        try await Task.sleep(for: .milliseconds(200))
        #expect(list.rows.count == list.total)
        #expect(Set(list.rows.map(\.trackID)).isDisjoint(with: session.state.upNext.map(\.track.id)))
    }
}

/// A catalog that leaves some songs out of a playlist, as Apple Music does with uploads.
struct SkippingCatalog: MusicCatalog {
    var skipped: [String: [QueueTrack]]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        if playlist.id == "broken" { throw URLError(.notConnectedToInternet) }
        return ["a", "b"].map(track)
    }
    func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
        guard let tracks = skipped[playlist.id] else { return nil }
        var report = PlaylistLoadReport(playlistID: playlist.id)
        report.skipped = tracks
        return report
    }
}

/// Hosts are told when a playlist loads without some of its songs.
@MainActor
@Suite struct SkippedOnLoadTests {
    let five = (1...5).map { QueueTrack(id: "u\($0)", title: "Upload \($0)", artist: "Someone") }
    var catalog: SkippingCatalog { SkippingCatalog(skipped: ["p": five, "q": []]) }

    @Test func loadKeepsTheSkippedSongsAndSnapshotsCountThem() async throws {
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        #expect(session.snapshot().skippedOnLoad == nil)
        try await session.load(playlist: base)
        #expect(session.skippedOnLoad == five)
        let snapshot = session.snapshot()
        #expect(snapshot.skippedOnLoad == 5)
        #expect(snapshot.skippedTitles == ["Upload 1", "Upload 2", "Upload 3"])
    }

    @Test func listenersHearAboutIt() async throws {
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        var updates = session.snapshots().makeAsyncIterator()
        _ = await updates.next()
        try await session.load(playlist: base)
        #expect(await updates.next()?.skippedOnLoad == 5)
    }

    @Test func nextPlaylistClearsIt() async throws {
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        try await session.load(playlist: base)
        try await session.load(playlist: PlaylistSummary(id: "q", name: "Other", kind: .library))
        #expect(session.skippedOnLoad.isEmpty)
        #expect(session.snapshot().skippedOnLoad == nil)
        #expect(session.snapshot().skippedTitles == nil)
        // A playlist with no report at all (e.g. a catalog playlist) too.
        try await session.load(playlist: base)
        try await session.load(playlist: PlaylistSummary(id: "c", name: "Catalog", kind: .catalog))
        #expect(session.skippedOnLoad.isEmpty)
    }

    @Test func aFailedLoadKeepsTheCurrentPlaylistsNote() async throws {
        let session = PartySession(catalog: catalog, engine: FakeEngine())
        try await session.load(playlist: base)
        await #expect(throws: URLError.self) {
            try await session.load(playlist: PlaylistSummary(id: "broken", name: "Broken", kind: .library))
        }
        #expect(session.state.playlistName == "Base")
        #expect(session.snapshot().skippedOnLoad == 5)
    }

    @Test func snapshotsWithoutItStillDecode() throws {
        var snapshot = PartySession(catalog: catalog, engine: FakeEngine()).snapshot()
        snapshot.skippedOnLoad = 2
        snapshot.skippedTitles = ["x", "y"]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["skippedOnLoad"] as? Int == 2)
        json["skippedOnLoad"] = nil
        json["skippedTitles"] = nil
        let decoded = try JSONDecoder().decode(PartySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.skippedOnLoad == nil)
    }

    @Test func demoRoadTripSkipsSongs() async throws {
        let demo = DemoCatalog()
        let roadTrip = try #require(try await demo.libraryPlaylists().first { $0.id == "demo-skips" })
        let session = PartySession(catalog: demo, engine: FakeEngine())
        try await session.load(playlist: roadTrip)
        #expect(session.skippedOnLoad.count == 4)
        #expect(!session.state.upNext.isEmpty)
    }
}
