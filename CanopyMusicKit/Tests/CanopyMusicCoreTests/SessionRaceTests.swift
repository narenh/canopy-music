import Foundation
import Testing
@testable import CanopyMusicCore

/// An engine whose next `play` waits for the test to let it finish, so something else can
/// happen while the player is starting a song.
@MainActor
final class GatedEngine: PlaybackEngine {
    let canReplaceStaged = true
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: QueueTrack?
    var staged: QueueTrack?
    var holdNextPlay = false
    /// The held play, waiting.
    private(set) var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }

    func play(_ track: QueueTrack) async throws {
        if holdNextPlay {
            holdNextPlay = false
            await withCheckedContinuation { held = $0 }
        }
        playing = track; staged = nil; isPlaying = true
    }
    func stage(_ track: QueueTrack?) async throws { staged = track }
    func resume() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    /// As the real engines: nothing staged means the skip fails and the session plays the next
    /// song itself.
    func skipToStaged() async throws {
        guard let staged else { throw CancellationError() }
        playing = staged; self.staged = nil; onEvent?(.advancedToStaged)
    }
    func restartCurrent() { currentTime = 0 }
    func seek(to time: TimeInterval) { currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    /// Lets the held play finish (the song starts).
    func release() {
        held?.resume()
        held = nil
    }
}

/// End, Load, Pause and Seek used to act at once while a song change was still in flight on the
/// chain; the change then landed on a session that had moved on.
@MainActor
@Suite struct SessionRaceTests {
    func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// End during a song change: the music doesn't start in the ended zone, the song isn't
    /// logged, nothing is saved back, and the zone isn't marked started.
    @Test func endDuringAPlayNeitherResumesNorSaves() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine, storeURL: url)
        var starts = 0
        session.onSongStarted = { starts += 1 }
        try await session.load(playlist: base)
        engine.holdNextPlay = true
        let play = Task { try? await session.play() }
        await waitUntil { engine.isHolding }

        session.end()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        engine.release()
        _ = await play.value
        await settle()

        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(session.state.current == nil)
        #expect(session.state.log.isEmpty)
        #expect(starts == 0)
        #expect(engine.staged == nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A new playlist loaded during a song change: the old song doesn't play on under the new
    /// (empty) Now Playing, and isn't logged.
    @Test func loadDuringAPlayDoesNotLogTheOldSong() async throws {
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        engine.holdNextPlay = true
        let play = Task { try? await session.play() }
        await waitUntil { engine.isHolding }

        try await session.load(playlist: PlaylistSummary(id: "q", name: "Other", kind: .library))
        engine.release()
        _ = await play.value
        await settle()

        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(session.state.current == nil)
        #expect(session.state.playlistName == "Other")
        #expect(session.state.log.isEmpty)
        #expect(engine.staged == nil)
        // The new playlist plays as usual afterwards.
        try await session.play()
        await settle()
        #expect(engine.playing?.id == "a")
        #expect(session.state.log.songs.count == 1)
    }

    /// Pause right after Skip: the skip's play lands after the pause, and used to undo it.
    @Test func pauseAfterSkipStaysPaused() async throws {
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.staged = nil // nothing staged: the skip starts the next song itself
        engine.holdNextPlay = true
        let skip = Task { await session.skip() }
        await waitUntil { engine.isHolding }

        session.pause()
        #expect(!session.isPlaying)
        engine.release()
        await skip.value
        await settle()

        #expect(session.state.current?.track.id == "b")
        #expect(engine.playing?.id == "b")
        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(session.snapshot().playback.isPlaying == false)
        // The song did start, so it's logged; play carries on from it.
        #expect(session.state.log.songs.count == 2)
        try await session.play()
        #expect(engine.isPlaying)
    }

    /// Pause then Play during a song change: the later press wins.
    @Test func playAfterPauseDuringASkipWins() async throws {
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.staged = nil
        engine.holdNextPlay = true
        let skip = Task { await session.skip() }
        await waitUntil { engine.isHolding }

        session.pause()
        let play = Task { try? await session.play() }
        engine.release()
        await skip.value
        _ = await play.value
        await settle()

        #expect(session.state.current?.track.id == "b")
        #expect(engine.isPlaying)
        #expect(session.isPlaying)
    }

    /// A seek during a song change is dropped: it would land on the song going away.
    @Test func seekDuringASongChangeIsDropped() async throws {
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.currentTime = 10
        session.seek(to: 30)
        #expect(engine.currentTime == 30)
        engine.staged = nil
        engine.holdNextPlay = true
        let skip = Task { await session.skip() }
        await waitUntil { engine.isHolding }
        session.seek(to: 50)
        #expect(engine.currentTime == 30)
        engine.release()
        await skip.value
        await settle()
        session.seek(to: 5)
        #expect(engine.currentTime == 5)
    }

    /// The app dropping a session: a chained play that lands afterwards changes nothing, the
    /// music stops, and a pending save is written rather than lost.
    @Test func shutdownStopsTheSessionAndKeepsItsSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = GatedEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine, storeURL: url)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(engine.isPlaying)
        engine.staged = nil
        engine.holdNextPlay = true
        let skip = Task { await session.skip() } // schedules a save, and a play that waits
        await waitUntil { engine.isHolding }

        session.shutdown()
        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(QueueState.saved(at: url)?.current?.track.id == "b") // written at once
        engine.release()
        await skip.value
        await settle()
        #expect(!engine.isPlaying)
        #expect(engine.staged == nil)
        #expect(session.state.log.songs.count == 1) // "b" started in a session that was over
        // The old engine's events no longer reach it.
        engine.onEvent?(.reachedEnd)
        #expect(session.state.current?.track.id == "b")
    }
}
