import Foundation
import Testing
@testable import CanopyMusicCore

/// A playlist with nothing to play is refused before anything changes: no half-started party
/// before Start, and a live party plays on with the playlist it had.
@MainActor
@Suite struct EmptyPlaylistTests {
    let catalog = PlaylistsCatalog(playlists: ["p": ["a", "b", "c"], "empty": []])
    let empty = PlaylistSummary(id: "empty", name: "Empty", kind: .library)

    @Test func anEmptyPlaylistLoadsNothingBeforeStart() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        await #expect(throws: PlaylistLoadError.noSongs(playlist: "Empty")) {
            try await session.load(playlist: empty)
        }
        #expect(session.state.playlistName == nil)
        #expect(session.state.current == nil)
        #expect(session.state.upNext.isEmpty)
        #expect(!session.isPlaying)
        #expect(engine.playing == nil)
        // The pickers now show it as empty.
        #expect(await PlaylistSongCounts.shared.count(of: empty, in: catalog) == 0)

        // Another playlist then starts as usual.
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "a")
    }

    @Test func aLivePartyKeepsItsPlaylist() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: catalog, engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        let upNext = titles(session.state.upNext)

        await #expect(throws: PlaylistLoadError.self) { try await session.load(playlist: empty) }
        await settle()
        #expect(engine.isPlaying)
        #expect(session.state.playlistName == "Base")
        #expect(session.state.current?.track.id == "a")
        #expect(titles(session.state.upNext) == upNext)
    }

    /// Every song left out (uploads not on the service): refused the same way, saying why.
    @Test func aPlaylistOfUnplayableSongsIsRefused() async throws {
        struct Unplayable: MusicCatalog {
            func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
            func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
            func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
            func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [] }
            func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
                var report = PlaylistLoadReport(playlistID: playlist.id)
                report.skipped = ["x", "y"].map(track)
                return report
            }
        }
        let session = PartySession(catalog: Unplayable(), engine: FakeEngine())
        let memos = PlaylistSummary(id: "memos", name: "Memos", kind: .library)
        await #expect(throws: PlaylistLoadError.noPlayableSongs(playlist: "Memos")) {
            try await session.load(playlist: memos)
        }
        #expect(session.state.playlistName == nil)
        #expect(session.skippedOnLoad.isEmpty)
    }

    @Test func messagesNameThePlaylist() {
        #expect(PlaylistLoadError.noSongs(playlist: "Road trip").errorDescription == "“Road trip” has no songs. Choose another playlist.")
        #expect(PlaylistSummary.countText(0) == "No songs")
        #expect(PlaylistSummary.countText(1) == "1 song")
        #expect(PlaylistSummary.countText(24) == "24 songs")
    }
}

/// Counts for lists that don't include them: fetched a few at once, remembered for a while.
@Suite struct PlaylistSongCountsTests {
    actor Tally {
        var running = 0, most = 0, calls = 0
        func start() { running += 1; calls += 1; most = max(most, running) }
        func end() { running -= 1 }
    }

    struct CountingCatalog: MusicCatalog {
        let tally: Tally
        func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
        func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
        func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
        func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [] }
        func songCount(of playlist: PlaylistSummary) async throws -> Int? {
            await tally.start()
            try await Task.sleep(for: .milliseconds(20))
            await tally.end()
            return Int(playlist.id)
        }
    }

    @Test func countsRunAFewAtATimeAndAreRemembered() async {
        let tally = Tally()
        let catalog = CountingCatalog(tally: tally)
        let counts = PlaylistSongCounts(limit: 3)
        let playlists = (0..<12).map { PlaylistSummary(id: "\($0)", name: "", kind: .library) }
        let found = await withTaskGroup(of: Int?.self) { group in
            for playlist in playlists { group.addTask { await counts.count(of: playlist, in: catalog) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(found.compactMap { $0 }) == Set(0..<12))
        #expect(await tally.most == 3)
        #expect(await counts.count(of: playlists[5], in: catalog) == 5)
        #expect(await tally.calls == 12)
    }

    /// A listed count needs no request; a count recorded by a load beats it.
    @Test func listedAndRecordedCounts() async {
        let tally = Tally()
        let counts = PlaylistSongCounts()
        var listed = PlaylistSummary(id: "l", name: "", kind: .library)
        listed.songCount = 7
        #expect(await counts.count(of: listed, in: CountingCatalog(tally: tally)) == 7)
        await counts.record(0, for: "l")
        #expect(await counts.count(of: listed, in: CountingCatalog(tally: tally)) == 0)
        #expect(await tally.calls == 0)
    }

    @Test func oldCountsAreFetchedAgain() async {
        final class Clock: @unchecked Sendable { var now = Date() }
        let clock = Clock()
        let tally = Tally()
        let counts = PlaylistSongCounts(lifetime: 60, now: { clock.now })
        let playlist = PlaylistSummary(id: "4", name: "", kind: .library)
        _ = await counts.count(of: playlist, in: CountingCatalog(tally: tally))
        clock.now += 61
        _ = await counts.count(of: playlist, in: CountingCatalog(tally: tally))
        #expect(await tally.calls == 2)
    }
}
