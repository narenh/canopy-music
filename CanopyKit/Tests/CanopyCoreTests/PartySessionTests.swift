import Foundation
import Testing
@testable import CanopyCore

@MainActor
final class FakeEngine: PlaybackEngine {
    let canReplaceStaged: Bool
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: Track?
    var staged: Track?

    init(canReplaceStaged: Bool = true) { self.canReplaceStaged = canReplaceStaged }

    func play(_ track: Track) async throws { playing = track; staged = nil; isPlaying = true }
    func stage(_ track: Track?) async throws { staged = track }
    func resume() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    func skipToStaged() async throws { finishTrack() }
    func setCrossfade(_ enabled: Bool) {}

    func finishTrack() {
        if let staged { playing = staged; self.staged = nil; onEvent?(.advancedToStaged) }
        else { playing = nil; onEvent?(.reachedEnd) }
    }
}

struct StubCatalog: MusicCatalog {
    var ids: [String]
    func searchSongs(_ term: String) async throws -> [Track] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [Track] { ids.map(track) }
}

let base = PlaylistSummary(id: "p", name: "Base", kind: .library)

/// Lets queued `Task { await syncStaging() }` work run.
@MainActor func settle() async { for _ in 0..<20 { await Task.yield() } }

@MainActor
@Suite struct PartySessionTests {
    @Test func startPlaysAndStagesNext() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.start(playlist: base, shuffle: false)
        await settle()
        #expect(engine.playing?.id == "a")
        #expect(engine.staged?.id == "b")
    }

    @Test func requestReplacesStagedTrack() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.start(playlist: base, shuffle: false)
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
        try await session.start(playlist: base, shuffle: false)
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
        try await session.start(playlist: base, shuffle: false)
        guard case .added(let item, _) = session.add(track("x"), by: guest) else { Issue.record("not added"); return }
        #expect(!session.remove(item.id, asClient: "someone-else"))
        let playlistItem = session.state.upNext.first { !$0.isRequest }!
        #expect(!session.remove(playlistItem.id, asClient: "phone-1"))
        #expect(session.remove(item.id, asClient: "phone-1"))
    }

    @Test func reachingTheEndRestartsFromQueue() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.start(playlist: base, shuffle: false)
        await settle()
        engine.staged = nil // simulate a failed stage
        engine.finishTrack()
        await settle()
        #expect(engine.playing?.id == "b")
    }

    @Test func persistsAndRestores() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await session.start(playlist: base, shuffle: false)
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
        try await session.start(playlist: base, shuffle: false)
        let next = await iterator.next()
        #expect(next != nil)
        #expect(next!.version > first!.version)
    }
}
