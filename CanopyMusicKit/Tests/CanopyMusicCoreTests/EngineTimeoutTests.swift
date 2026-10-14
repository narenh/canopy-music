import Foundation
import Testing
@testable import CanopyMusicCore

/// An engine whose `play` or `stage` can hang, as Apple's out-of-process player does when it
/// stops answering. It ignores cancellation, as the real call may; `release()` lets it fail.
@MainActor
final class HangingEngine: PlaybackEngine {
    let canReplaceStaged = true
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: QueueTrack?
    var staged: QueueTrack?
    var hangNextPlay = false
    var hangNextStage = false
    /// A call is hanging now.
    private(set) var stuck = false

    func play(_ track: QueueTrack) async throws {
        if hangNextPlay {
            hangNextPlay = false
            try await hang()
        }
        playing = track; staged = nil; isPlaying = true
    }
    func stage(_ track: QueueTrack?) async throws {
        if hangNextStage {
            hangNextStage = false
            try await hang()
        }
        staged = track
    }
    func resume() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    func skipToStaged() async throws {
        if let staged { playing = staged; self.staged = nil; onEvent?(.advancedToStaged) }
        else { playing = nil; onEvent?(.reachedEnd) }
    }
    func restartCurrent() { currentTime = 0 }
    func seek(to time: TimeInterval) { currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    /// Ends the hanging call with an error (the connection finally failed).
    func release() { stuck = false }

    private func hang() async throws {
        stuck = true
        while stuck {
            // Not `Task.sleep`: that returns at once when cancelled, and this must not.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        throw URLError(.cannotConnectToHost)
    }
}

/// One engine call that never answers no longer wedges playback control for the session.
@MainActor
@Suite struct EngineTimeoutTests {
    func makeSession(_ engine: HangingEngine, timeout: TimeInterval = 0.3) async throws -> PartySession {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        session.engineCallTimeout = timeout
        try await session.load(playlist: base)
        return session
    }

    func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A play that never returns fails after the deadline, and the next commands run.
    @Test func aStuckPlayTimesOutAndTheNextCommandRuns() async throws {
        let engine = HangingEngine()
        defer { engine.release() }
        let session = try await makeSession(engine)
        engine.hangNextPlay = true
        let started = Date()
        await #expect(throws: PlaybackEngineError.timedOut(operation: "play")) { try await session.play() }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(!session.isPlaying)
        await settle()
        #expect(engine.staged == nil) // nothing staged behind a song that never started
        #expect(!session.isSyncing)

        // Not queued behind the stuck call: skip moves on, play starts the player afresh.
        await session.skip()
        #expect(session.state.current?.track.id == "b")
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "b")
        #expect(engine.staged?.id == "c")
        #expect(session.isPlaying)
    }

    /// A skip sent while a play hangs runs once the play's deadline passes, not never.
    @Test func aSkipBehindAStuckPlayRunsAfterTheDeadline() async throws {
        let engine = HangingEngine()
        defer { engine.release() }
        let session = try await makeSession(engine)
        engine.hangNextPlay = true
        let play = Task { try? await session.play() }
        await waitUntil { engine.stuck }
        let started = Date()
        await session.skip()
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(session.state.current?.track.id == "b")
        _ = await play.value
        await settle()
        #expect(!session.isSyncing)
    }

    /// Staging that hangs ends with the deadline too: `isSyncing` clears and the next change stages.
    @Test func aStuckStageClearsSyncing() async throws {
        let engine = HangingEngine()
        defer { engine.release() }
        let session = try await makeSession(engine)
        engine.hangNextStage = true
        try await session.play()
        await waitUntil { engine.stuck }
        #expect(session.isSyncing)
        await waitUntil { !session.isSyncing }
        #expect(!session.isSyncing)
        // A sync that was waiting on the stuck one retried once it was given up on.
        #expect(engine.staged?.id == "b")
        session.add(track("x"), by: guest)
        await settle()
        #expect(engine.staged?.id == "x")
    }

    /// A caller cancelled while it waits behind a stuck call (an HTTP handler past its timeout)
    /// returns at once; its command still runs in its turn.
    @Test func aCancelledCallerStopsWaitingWhileTheChainRunsOn() async throws {
        let engine = HangingEngine()
        defer { engine.release() }
        let session = try await makeSession(engine, timeout: 10)
        engine.hangNextPlay = true
        let play = Task { try? await session.play() }
        await waitUntil { engine.stuck }
        let skip = Task { await session.skip() }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        skip.cancel()
        await skip.value
        #expect(Date().timeIntervalSince(started) < 1)
        // The queue moved at once; the player follows once the stuck play is done.
        #expect(session.state.current?.track.id == "b")
        engine.release()
        _ = await play.value
        await settle()
        #expect(session.state.current?.track.id == "b")
    }
}
