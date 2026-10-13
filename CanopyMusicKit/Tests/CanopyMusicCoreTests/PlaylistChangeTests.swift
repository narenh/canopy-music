import Foundation
import Testing
@testable import CanopyMusicCore

/// A catalog with a different song list for each playlist ID.
struct PlaylistsCatalog: MusicCatalog {
    var playlists: [String: [String]]
    /// 100 s songs (`longSong`), so follow mode's staging can be timed; otherwise `track`.
    var long = false
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        (playlists[playlist.id] ?? []).map(long ? longSong : track)
    }
}

let other = PlaylistSummary(id: "q", name: "Other", kind: .library)

/// Picking a new base playlist while music plays (docs/multi-device.md): the song playing goes
/// on, guests' requests stay at the top of Up next, and the new playlist follows them. Before
/// anything has played, a load starts over and nothing plays until `play()`.
@MainActor
@Suite struct PlaylistChangeTests {
    let catalog = PlaylistsCatalog(playlists: ["p": ["a", "b", "c"], "q": ["m", "n", "o"]])

    @Test func aLiveChangeKeepsTheSongAndRequests() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        session.add(track("y"), by: guest)
        await settle()
        let a = try #require(session.state.current)

        try await session.load(playlist: other)
        await settle()

        #expect(engine.isPlaying)
        #expect(session.isPlaying)
        #expect(engine.playing?.id == "a")
        #expect(session.state.current?.id == a.id)
        #expect(titles(session.state.upNext) == ["x", "y", "m", "n", "o"])
        #expect(session.state.upNext.map(\.isRequest) == [true, true, false, false, false])
        #expect(session.state.playlistName == "Other")
        #expect(session.partyLog.songs.map(\.track.id) == ["a"])

        // The new playlist takes over once the requests have played.
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "x")
        #expect(session.state.history.first?.id == a.id)
    }

    /// An engine that can swap its staged song (Apple Music) gets the new next song.
    @Test func aReplaceableStagedSongIsRestaged() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(engine.staged?.id == "b")

        try await session.load(playlist: other)
        await settle()
        #expect(engine.staged?.id == "m")
        #expect(engine.playing?.id == "a")

        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "m")
        #expect(engine.staged?.id == "n")
    }

    /// A paused party keeps its song too, still paused: Play goes on with it.
    @Test func aPausedChangeKeepsTheSongPaused() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.pause()
        try await session.load(playlist: other)
        await settle()
        #expect(!engine.isPlaying)
        #expect(session.state.current?.track.id == "a")
        #expect(titles(session.state.upNext) == ["m", "n", "o"])
        try await session.play()
        #expect(engine.isPlaying)
        #expect(engine.playing?.id == "a")
    }

    @Test func aLiveChangeCanShuffle() async throws {
        let ids = (0..<20).map { "t\($0)" }
        let catalog = PlaylistsCatalog(playlists: ["p": ["a", "b"], "q": ids])
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        try await session.load(playlist: other, shuffled: true)
        await settle()
        #expect(session.state.current?.track.id == "a")
        #expect(engine.isPlaying)
        #expect(session.state.upNext.first?.track.id == "x")
        #expect(Set(session.state.upNext.dropFirst().map(\.track.id)) == Set(ids))
        #expect(Set(session.state.playlist.map(\.id)) == Set(ids))
    }

    /// Before anything has played, a load starts over, and nothing plays until `play()`.
    @Test func aLoadBeforePlayingPlaysNothing() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.load(playlist: other)
        await settle()
        #expect(session.state.current == nil)
        #expect(titles(session.state.upNext) == ["m", "n", "o"])
        #expect(engine.playing == nil)
        #expect(engine.staged == nil)
        try await session.play()
        #expect(engine.playing?.id == "m")
    }

    /// A Start that failed played nothing: the next load still starts over.
    @Test func aLoadAfterAFailedStartStartsOver() async throws {
        let engine = FakeEngine()
        engine.playError = URLError(.notConnectedToInternet)
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        await #expect(throws: (any Error).self) { try await session.play() }
        try await session.load(playlist: other)
        await settle()
        #expect(session.state.current == nil)
        #expect(titles(session.state.upNext) == ["m", "n", "o"])
        #expect(engine.playing == nil)
    }

    /// After End the zone starts over: a load is a fresh start again.
    @Test func aLoadAfterEndStartsOver() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.end()
        try await session.load(playlist: other)
        await settle()
        #expect(session.state.current == nil)
        #expect(titles(session.state.upNext) == ["m", "n", "o"])
    }

    /// A zone back after a relaunch (its song paused, not loaded in the player) is under way: a
    /// new playlist keeps its song and requests.
    @Test func aRestoredZoneKeepsItsSong() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PartySession(catalog: catalog, engine: FakeEngine(), storeURL: url)
        try await first.load(playlist: base)
        try await first.play()
        first.add(track("x"), by: guest)
        try await Task.sleep(for: .milliseconds(800))

        let engine = FakeEngine()
        let restored = PartySession(catalog: catalog, engine: engine, storeURL: url)
        try await restored.load(playlist: other)
        await settle()
        #expect(restored.state.current?.track.id == "a")
        #expect(titles(restored.state.upNext) == ["x", "m", "n", "o"])
        try await restored.play()
        #expect(engine.playing?.id == "a")
    }

    // MARK: Follow mode (Spotify)

    /// The next song already handed to Spotify can't be taken back: it stays first, locked, and
    /// the requests and the new playlist follow it. Nothing is played or staged again.
    @Test func aLockedStagedSongStaysFirst() async throws {
        let engine = FakeSpotifyEngine()
        let catalog = PlaylistsCatalog(playlists: ["p": ["a", "b", "c"], "q": ["m", "n"]], long: true)
        let session = PartySession(catalog: catalog, engine: engine)
        var timing = FollowTiming()
        timing.retryDelays = [0.01, 0.01]
        timing.tick = 0.01
        session.followTiming = timing
        session.configureHub(kind: .ipad, zoneName: "Den", serviceName: "Spotify")
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        let b = try #require(session.state.upNext.first)

        engine.currentTime = 85 // 15 s left: b is locked and queued on Spotify
        await waitUntil { engine.queue.contains { $0.id == "b" } && engine.queueReads >= 2 }
        await settle()
        #expect(session.state.lockedNextID == b.id)
        session.add(longSong("x"), by: guest)

        try await session.load(playlist: other)
        await settle()
        #expect(engine.isPlaying)
        #expect(engine.plays == ["a"])
        #expect(engine.stages == ["b"])
        #expect(session.state.current?.track.id == "a")
        #expect(session.state.lockedNextID == b.id)
        #expect(titles(session.state.upNext) == ["b", "x", "m", "n"])

        // Spotify plays b; then the request, then the new playlist.
        engine.moveOn()
        await settle()
        #expect(session.state.current?.id == b.id)
        #expect(titles(session.state.upNext) == ["x", "m", "n"])
        engine.currentTime = 85
        await waitUntil { engine.queue.contains { $0.id == "x" } }
        #expect(engine.stages == ["b", "x"])
    }

    /// Not yet near the end: nothing is locked, so the new playlist's song is the one staged later.
    @Test func anUnlockedFollowZoneStagesTheNewNextSong() async throws {
        let engine = FakeSpotifyEngine()
        let catalog = PlaylistsCatalog(playlists: ["p": ["a", "b", "c"], "q": ["m", "n"]], long: true)
        let session = PartySession(catalog: catalog, engine: engine)
        var timing = FollowTiming()
        timing.retryDelays = [0.01, 0.01]
        timing.tick = 0.01
        session.followTiming = timing
        session.configureHub(kind: .ipad, zoneName: "Den", serviceName: "Spotify")
        try await session.load(playlist: base)
        try await session.play()
        await settle()

        try await session.load(playlist: other)
        await settle()
        #expect(engine.isPlaying)
        #expect(session.state.current?.track.id == "a")
        #expect(titles(session.state.upNext) == ["m", "n"])
        engine.currentTime = 85
        await waitUntil { engine.queue.contains { $0.id == "m" } }
        #expect(engine.stages == ["m"])
    }

    func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
