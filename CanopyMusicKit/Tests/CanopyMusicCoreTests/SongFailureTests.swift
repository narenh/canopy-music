import Foundation
import Testing
@testable import CanopyMusicCore

/// A song the player won't play (unavailable, refused) is skipped, and the party plays on;
/// a run of them stops the music with an issue rather than skip forever.
@MainActor
@Suite struct SongFailureTests {
    func playingSession(_ engine: FakeEngine, ids: [String] = ["a", "b", "c", "d"]) async throws -> PartySession {
        let session = PartySession(catalog: StubCatalog(ids: ids), engine: engine)
        session.landingDelay = 0.05
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        return session
    }

    @Test func aSongThatWontPlayIsSkippedWhenTheOneBeforeEnds() async throws {
        let engine = FakeEngine()
        engine.unplayable = ["b"]
        let session = try await playingSession(engine)
        #expect(engine.staged == nil) // it couldn't be staged either
        engine.finishTrack()
        await settle()
        #expect(engine.playAttempts == ["a", "b", "c"])
        #expect(engine.playing?.id == "c")
        #expect(session.isPlaying)
        #expect(session.state.current?.track.id == "c")
        #expect(session.state.history.map(\.track.id) == ["b", "a"])
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "c"])
        #expect(session.playerIssue == "Skipped “b”, which couldn't play")
        #expect(session.snapshot().playerIssue == session.playerIssue)

        // The notice stays while "c" plays, and goes when the next song starts.
        #expect(engine.staged?.id == "d")
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "d")
        #expect(session.playerIssue == nil)
    }

    /// A skip (its landing, once the taps settle) onto a song that won't play goes on to the next.
    @Test func aSkipOntoASongThatWontPlayMovesOn() async throws {
        let engine = FakeEngine()
        engine.unplayable = ["b", "c"]
        let session = try await playingSession(engine, ids: ["a", "b", "c", "d", "e"])
        await session.skip()
        await settle()
        #expect(engine.playAttempts == ["a", "b", "c", "d"])
        #expect(engine.playing?.id == "d")
        #expect(session.state.current?.track.id == "d")
        #expect(engine.staged?.id == "e")
        #expect(session.playerIssue == "Skipped 2 songs that couldn't play")
    }

    /// Every song failing (the service is down): a few are tried, then the music stops, the host
    /// is told, and nothing more is tried until someone presses Play.
    @Test func aRunOfFailuresStopsWithAnIssue() async throws {
        let engine = FakeEngine()
        engine.unplayable = ["b", "c", "d", "e", "f"]
        let session = try await playingSession(engine, ids: ["a", "b", "c", "d", "e", "f"])
        engine.finishTrack()
        await settle()
        #expect(engine.playAttempts == ["a", "b", "c", "d"])
        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(session.state.current?.track.id == "d")
        #expect(session.playerIssue == "Stopped after 3 songs in a row couldn't play")
        try await Task.sleep(for: .milliseconds(100))
        await settle()
        #expect(engine.playAttempts.count == 4)

        // Play tries the song again, and the host pressing it hears why it didn't start.
        await #expect(throws: (any Error).self) { try await session.play() }
        #expect(session.state.current?.track.id == "d")
        engine.unplayable = []
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "d")
        #expect(session.isPlaying)
        #expect(session.playerIssue == nil)
    }

    /// A song that plays in between starts the count of failures over.
    @Test func failuresCountOnlyInARow() async throws {
        let engine = FakeEngine()
        engine.unplayable = ["b", "c", "e", "f"]
        let session = try await playingSession(engine, ids: ["a", "b", "c", "d", "e", "f", "g"])
        engine.finishTrack()
        await settle()
        #expect(engine.playing?.id == "d")
        engine.finishTrack()
        await settle()
        #expect(engine.playing?.id == "g")
        #expect(session.isPlaying)
        #expect(session.playerIssue == "Skipped 2 songs that couldn't play")
    }

    /// A tap while the player is refusing a song: the newest tap wins, and the failure doesn't
    /// move the queue on past it.
    @Test func aSkipDuringAFailingPlayLandsWhereTheTapsSaid() async throws {
        let engine = CommandLogEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d", "e", "f"]), engine: engine)
        session.landingDelay = 0.05
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.holdPlays = true
        engine.failHeldPlay = true
        var tasks = [Task { await session.skip() }]
        try await Task.sleep(for: .milliseconds(10))
        tasks.append(Task { await session.skip() })
        let deadline = Date().addingTimeInterval(3)
        while !engine.isHolding, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.state.current?.track.id == "c")
        // While "c" is being refused, two more taps.
        tasks.append(Task { await session.skip() })
        try await Task.sleep(for: .milliseconds(10))
        tasks.append(Task { await session.skip() })
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.state.current?.track.id == "e")
        engine.holdPlays = false
        engine.release()
        for task in tasks { await task.value }
        await settle()
        #expect(session.state.current?.track.id == "e")
        #expect(engine.playing?.id == "e")
        #expect(engine.commands.filter { $0.hasPrefix("play") } == ["play a", "play c", "play e"])
    }
}
