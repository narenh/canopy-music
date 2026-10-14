import Foundation
import Testing
@testable import CanopyMusicCore

/// Logs every command it's sent, and how many of its calls ever ran at once. Plays can be held,
/// and (as Apple's player, which is polled) a skip to the staged song can go unreported until
/// the next `poll()`.
@MainActor
final class CommandLogEngine: PlaybackEngine {
    let canReplaceStaged = true
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: QueueTrack?
    var staged: QueueTrack?
    /// In order: "play b", "stage c", "skip", "resume", "pause", "restart", "seek".
    var commands: [String] = []
    private var running = 0
    private(set) var mostAtOnce = 0
    var holdPlays = false
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    var reportsOnPoll = false
    private var unreported = false

    private func begin(_ command: String) {
        commands.append(command)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
    }

    func play(_ track: QueueTrack) async throws {
        begin("play \(track.id)")
        defer { running -= 1 }
        if holdPlays { await withCheckedContinuation { held = $0 } } else { await Task.yield() }
        // A new queue in the player: a skip not yet reported never will be.
        playing = track; staged = nil; isPlaying = true; currentTime = 0; unreported = false
    }
    func stage(_ track: QueueTrack?) async throws {
        begin("stage \(track?.id ?? "nil")")
        defer { running -= 1 }
        await Task.yield()
        staged = track
    }
    func resume() async throws {
        begin("resume")
        defer { running -= 1 }
        isPlaying = true
    }
    func pause() { commands.append("pause"); isPlaying = false }
    func skipToStaged() async throws {
        begin("skip")
        defer { running -= 1 }
        guard let next = staged else { throw CancellationError() }
        await Task.yield()
        playing = next; staged = nil; currentTime = 0
        if reportsOnPoll { unreported = true } else { onEvent?(.advancedToStaged) }
    }
    func poll() {
        guard unreported else { return }
        unreported = false
        onEvent?(.advancedToStaged)
    }
    func restartCurrent() { commands.append("restart"); currentTime = 0 }
    func seek(to time: TimeInterval) { commands.append("seek"); currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    func release() {
        held?.resume()
        held = nil
    }
}

/// Rapid skips and previouses: each tap moves the queue at once, and the player gets only the
/// song the taps settle on, one command at a time.
@MainActor
@Suite struct RapidSkipTests {
    /// Playing "a" with "b" staged, and nothing logged yet.
    func playingSession(_ engine: CommandLogEngine) async throws -> PartySession {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d", "e", "f", "g", "h"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(engine.staged?.id == "b")
        engine.commands = []
        return session
    }

    func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Taps a little apart, inside the settle time, as a quick thumb does. Each moves the queue
    /// (and what phones and displays are sent) at once.
    func taps(_ session: PartySession, _ forward: [Bool], expecting ids: [String]) async throws -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for (forward, id) in zip(forward, ids) {
            tasks.append(Task { forward ? await session.skip() : await session.previous() })
            try await Task.sleep(for: .milliseconds(60))
            #expect(session.state.current?.track.id == id)
            #expect(session.snapshot().current?.track.id == id)
        }
        return tasks
    }

    @Test func aBurstOfSkipsPlaysOnlyTheLastSong() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        let tasks = try await taps(session, Array(repeating: true, count: 5), expecting: ["b", "c", "d", "e", "f"])
        #expect(engine.commands.isEmpty) // nothing until the taps settle
        #expect(engine.playing?.id == "a" && engine.isPlaying) // the old song plays on meanwhile
        #expect(session.position == 0)
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands == ["play f", "stage g"])
        #expect(engine.playing?.id == "f")
        #expect(session.state.current?.track.id == "f")
        #expect(session.isPlaying)
    }

    /// A lone skip still goes to the song the player has ready (gapless), once.
    @Test func aLoneSkipGoesToTheStagedSong() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        await session.skip()
        await settle()
        #expect(engine.commands == ["skip", "stage c"])
        #expect(engine.playing?.id == "b")
        #expect(session.state.current?.track.id == "b")
        #expect(session.state.upNext.first?.track.id == "c")
        #expect(session.state.log.songs.map(\.track.id) == ["a", "b"])
    }

    /// The music stopping on an iPad: a second skip before the player's poll reported the first
    /// skipped it again, past the one song it had staged. Now the player is sent one song.
    @Test func quickSkipsNeverSkipThePlayerTwice() async throws {
        let engine = CommandLogEngine()
        engine.reportsOnPoll = true
        let session = try await playingSession(engine)
        let tasks = try await taps(session, [true, true], expecting: ["b", "c"])
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands == ["play c", "stage d"])

        // A lone skip lands on the staged song; another tap before the poll reports it is a
        // new burst, and gets a play, not a second skip.
        engine.commands = []
        await session.skip()
        #expect(engine.playing?.id == "d")
        await session.skip()
        engine.poll()
        await settle()
        #expect(engine.commands == ["skip", "play e", "stage f"])
        #expect(session.state.current?.track.id == "e")
        #expect(engine.playing?.id == "e")
        #expect(engine.staged?.id == "f")
    }

    /// One command at a time: taps that settle while a play is still running wait for it, and
    /// only the newest song goes after it.
    @Test func aBurstDuringAPlayWaitsAndEndsOnTheNewestSong() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        engine.holdPlays = true
        let first = try await taps(session, [true, true], expecting: ["b", "c"])
        await waitUntil { engine.isHolding }
        #expect(engine.commands == ["play c"])

        let tasks = try await taps(session, [true, true, true], expecting: ["d", "e", "f"])
        try await Task.sleep(for: .milliseconds(500)) // settled, but the play of "c" is still running
        #expect(engine.commands == ["play c"])
        engine.holdPlays = false
        engine.release()
        for task in first + tasks { await task.value }
        await settle()
        #expect(engine.commands == ["play c", "play f", "stage g"])
        #expect(engine.mostAtOnce == 1)
        #expect(engine.playing?.id == "f")
        #expect(session.state.current?.track.id == "f")
        #expect(session.state.log.songs.map(\.track.id) == ["a", "c", "f"])
    }

    /// A tap while the burst's play is running is a new burst: it ends on its own newest song.
    @Test func aSkipDuringTheLandingEndsOnTheNewestSong() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        engine.holdPlays = true
        let tasks = try await taps(session, [true, true], expecting: ["b", "c"])
        await waitUntil { engine.isHolding }
        let late = Task { await session.skip() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.state.current?.track.id == "d")
        engine.holdPlays = false
        engine.release()
        for task in tasks { await task.value }
        await late.value
        await settle()
        #expect(engine.commands == ["play c", "play d", "stage e"])
        #expect(engine.mostAtOnce == 1)
        #expect(engine.playing?.id == "d")
    }

    @Test func previousInABurstCounts() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        let tasks = try await taps(session, [true, true, true, false, true, false, false],
                                   expecting: ["b", "c", "d", "c", "d", "c", "b"])
        for task in tasks { await task.value }
        await settle()
        // "b" is the song the player had ready.
        #expect(engine.commands == ["skip", "stage c"])
        #expect(engine.playing?.id == "b")
        #expect(session.state.current?.track.id == "b")
        #expect(session.state.upNext.prefix(2).map(\.track.id) == ["c", "d"])

        engine.commands = []
        let more = try await taps(session, [true, true, true, false], expecting: ["c", "d", "e", "d"])
        for task in more { await task.value }
        await settle()
        #expect(engine.commands == ["play d", "stage e"])
        #expect(engine.playing?.id == "d")
    }

    /// Back to the song that was playing: it starts over, as any song landed on does.
    @Test func aBurstBackToTheSameSongStartsItOver() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        engine.currentTime = 40
        let tasks = try await taps(session, [true, false], expecting: ["b", "a"])
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands == ["play a", "stage b"])
        #expect(session.position == 0)
    }

    /// Paused, a burst moves the queue and leaves the player alone: the new song is at 0:00
    /// until Play loads it.
    @Test func aPausedBurstLeavesThePlayerAlone() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        engine.currentTime = 10
        session.pause()
        engine.commands = []
        let tasks = try await taps(session, [true, true, true, false, true], expecting: ["b", "c", "d", "c", "d"])
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands.isEmpty)
        #expect(engine.playing?.id == "a")
        #expect(engine.currentTime == 10)
        #expect(!session.isPlaying)
        #expect(session.position == 0)
        #expect(session.snapshot().playback.position == 0)
        #expect(session.snapshot().playback.isPlaying == false)
        try await session.play()
        await settle()
        #expect(engine.commands == ["play d", "stage e"])
    }

    /// Pause while the taps settle: they land paused. Play then: they land playing.
    @Test func pauseOrPlayDuringABurstDecidesHowItLands() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        let tasks = try await taps(session, [true, true], expecting: ["b", "c"])
        session.pause()
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands == ["pause"])
        #expect(engine.playing?.id == "a")

        engine.commands = []
        let more = try await taps(session, [true, true], expecting: ["d", "e"])
        try await session.play()
        for task in more { await task.value }
        await settle()
        #expect(engine.commands == ["play e", "stage f"])
        #expect(session.isPlaying)
    }

    /// Spotify too: one play, for the last song, and the followed player is on it.
    @Test func aBurstOnSpotifyPlaysOnlyTheLastSong() async throws {
        let engine = FakeSpotifyEngine()
        let session = PartySession(catalog: LongSongsCatalog(ids: ["a", "b", "c", "d", "e"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        let tasks = try await taps(session, [true, true, true], expecting: ["b", "c", "d"])
        #expect(engine.plays == ["a"])
        for task in tasks { await task.value }
        await settle()
        #expect(engine.plays == ["a", "d"])
        #expect(engine.playerSkips == 0)
        #expect(session.nowPlaying?.track.id == "d")
    }

    /// The old song ending while the taps settle neither moves the queue again nor stops the
    /// music: the landing plays the song landed on.
    @Test func theOldSongEndingDuringABurstChangesNothing() async throws {
        let engine = CommandLogEngine()
        let session = try await playingSession(engine)
        let tasks = try await taps(session, [true, true], expecting: ["b", "c"])
        // "a" ends into the staged "b", which the queue has already left.
        engine.playing = engine.staged
        engine.staged = nil
        engine.onEvent?(.advancedToStaged)
        #expect(session.state.current?.track.id == "c")
        for task in tasks { await task.value }
        await settle()
        #expect(engine.commands == ["play c", "stage d"])
        #expect(session.state.current?.track.id == "c")
        #expect(session.state.upNext.first?.track.id == "d")
    }
}
