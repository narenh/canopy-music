import Foundation
import Testing
@testable import CanopyMusicCore

/// A Spotify-like player for follow mode: one account-wide player with its own queue, which can
/// be added to but not edited, and which other apps can change. It reports what it plays the way
/// `SpotifyEngine` does, through `FollowRules`.
@MainActor
final class FakeSpotifyEngine: FollowingPlaybackEngine {
    let canReplaceStaged = false
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    /// What the player is on.
    var playing: QueueTrack?
    var playerTrackID: String? { playing?.id }
    var playerDuration: TimeInterval? { playing?.duration }
    /// The player's own queue.
    var queue: [QueueTrack] = []

    // The engine's own bookkeeping, as `SpotifyEngine` keeps it.
    private(set) var ours: String?
    private(set) var stagedURI: String?
    private var reportedForeign: String?

    // What the session asked for.
    private(set) var plays: [String] = []
    private(set) var stages: [String?] = []
    private(set) var queueReads = 0
    private(set) var playerSkips = 0
    /// How many of the next stage calls fail.
    var failStages = 0
    /// Whether a stage call that succeeds lands in the queue (false: it says OK, but doesn't).
    var stagesLand = true

    func play(_ track: QueueTrack) async throws {
        plays.append(track.id)
        ours = track.id
        stagedURI = nil
        reportedForeign = nil
        playing = track
        currentTime = 0
        isPlaying = true
    }

    func stage(_ track: QueueTrack?) async throws {
        stages.append(track?.id)
        stagedURI = track?.id
        guard let track else { return }
        if failStages > 0 {
            failStages -= 1
            throw URLError(.badServerResponse)
        }
        if stagesLand { queue.append(track) }
    }

    func fetchPlayerQueue() async throws -> [QueueTrack] {
        queueReads += 1
        return queue
    }

    func skipInPlayer() async throws {
        playerSkips += 1
        moveOn()
    }

    /// What a restored session said it expects the player to be on (`attach`).
    private(set) var attachedTo: String?
    func attach(expecting trackID: String?) {
        attachedTo = trackID
        if ours == nil { ours = trackID }
    }

    func resume() async throws { isPlaying = true }
    func pause() { isPlaying = false }
    func skipToStaged() async throws { moveOn() }
    func restartCurrent() { currentTime = 0 }
    func seek(to time: TimeInterval) { currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    /// The player goes on to the next thing in its queue (the song ended, or someone skipped).
    func moveOn() {
        guard !queue.isEmpty else { return }
        playing = queue.removeFirst()
        currentTime = 0
        poll()
    }

    /// Someone else on the account plays `track` (another zone, the Spotify app).
    func otherAppPlays(_ track: QueueTrack) {
        playing = track
        currentTime = 0
        isPlaying = true
        poll()
    }

    /// One poll, read through `FollowRules` as `SpotifyEngine` does.
    func poll() {
        let observation = FollowRules.Observation(trackID: playing?.id, isPlaying: isPlaying, position: currentTime, duration: playing?.duration)
        let context = FollowRules.Context(ours: ours, staged: stagedURI, reportedForeign: reportedForeign)
        switch FollowRules.step(observation, context) {
        case .advancedToStaged:
            ours = playing?.id
            stagedURI = nil
            reportedForeign = nil
            onEvent?(.advancedToStaged)
        case .foreign:
            reportedForeign = playing?.id
            onEvent?(.externalTrack(playing))
        case .backToOurs:
            reportedForeign = nil
            onEvent?(.externalTrack(nil))
        case .reachedEnd:
            onEvent?(.reachedEnd)
        case .nothing, .retryPlay:
            break
        }
    }
}

/// Songs 100 s long, so staging timing can be posed by setting the player's position.
struct LongSongsCatalog: MusicCatalog {
    var ids: [String]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { ids.map(longSong) }
}

func longSong(_ id: String) -> QueueTrack { QueueTrack(id: id, title: id, artist: "Artist", duration: 100) }

@MainActor
@Suite struct FollowModeTests {
    func makeSession(_ engine: FakeSpotifyEngine, ids: [String] = ["a", "b", "c", "d"]) async throws -> PartySession {
        let session = PartySession(catalog: LongSongsCatalog(ids: ids), engine: engine)
        var timing = FollowTiming()
        timing.retryDelays = [0.01, 0.01]
        timing.tick = 0.01
        session.followTiming = timing
        session.configureHub(kind: .ipad, zoneName: "Den", serviceName: "Spotify")
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        return session
    }

    func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A while for the ticker to have done anything it was going to.
    func pause() async { try? await Task.sleep(for: .milliseconds(150)) }

    // MARK: Ours or foreign

    /// Another app plays something: it's shown, but Canopy's queue doesn't move and nothing is played over it.
    @Test func aForeignTrackDoesNotAdvanceOrPlay() async throws {
        let engine = FakeSpotifyEngine()
        let session = try await makeSession(engine)
        let a = try #require(session.state.current)
        let upNext = session.state.upNext.map(\.id)

        engine.otherAppPlays(longSong("f"))
        await settle()
        #expect(session.state.current?.id == a.id)
        #expect(session.state.upNext.map(\.id) == upNext)
        #expect(session.externalCurrent?.track.id == "f")
        #expect(session.externalCurrent?.requester == nil)
        #expect(session.nowPlaying?.track.id == "f")
        #expect(engine.plays == ["a"])
        #expect(session.snapshot().externalCurrent?.track.id == "f")
        #expect(session.snapshot().current?.id == a.id)

        // Nearly over, the foreign track doesn't get Canopy's next song staged (not our song).
        engine.currentTime = 95
        await pause()
        #expect(engine.stages.isEmpty)
        #expect(session.state.lockedNextID == nil)

        // Back to our song: it's ours again.
        engine.playing = longSong("a")
        engine.poll()
        await settle()
        #expect(session.externalCurrent == nil)
        #expect(session.nowPlaying?.id == a.id)
    }

    /// Our staged song arrives (after a foreign one queued ahead of it): Canopy moves on as usual.
    @Test func reachingOurStagedSongAdvances() async throws {
        let engine = FakeSpotifyEngine()
        engine.queue = [longSong("f")] // someone queued this on Spotify before
        let session = try await makeSession(engine)
        let b = try #require(session.state.upNext.first)
        await waitUntil { !session.foreignUpcoming.isEmpty }
        #expect(session.foreignUpcoming.map(\.track.id) == ["f"])

        engine.currentTime = 85 // 15 s left
        await waitUntil { engine.queue.contains { $0.id == "b" } && engine.queueReads >= 2 }
        await settle()
        #expect(session.state.lockedNextID == b.id)
        #expect(engine.stages == ["b"])
        // Spotify will play f, then b: f stays above b, and b is listed once (as ours).
        #expect(session.foreignUpcoming.map(\.track.id) == ["f"])
        #expect(session.snapshot().foreignUpcoming?.map(\.track.id) == ["f"])
        #expect(!session.state.upNext.dropFirst().contains { $0.track.id == "b" })

        engine.moveOn() // f
        await settle()
        #expect(session.state.current?.track.id == "a")
        #expect(session.externalCurrent?.track.id == "f")
        #expect(session.foreignUpcoming.isEmpty)
        #expect(engine.plays == ["a"])

        engine.moveOn() // b
        await settle()
        #expect(session.state.current?.id == b.id)
        #expect(session.externalCurrent == nil)
        #expect(session.state.lockedNextID == nil)
        #expect(engine.plays == ["a"])
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "f", "b"])
    }

    // MARK: Staging

    /// A stage that fails is retried, and confirmed in the player's queue.
    @Test func aFailedStageIsRetried() async throws {
        let engine = FakeSpotifyEngine()
        engine.failStages = 2
        let session = try await makeSession(engine)
        engine.currentTime = 85
        await waitUntil { engine.queue.contains { $0.id == "b" } }
        await settle()
        #expect(engine.stages == ["b", "b", "b"])
        #expect(session.playerIssue == nil)
        #expect(session.state.lockedNextID == session.state.upNext.first?.id)
    }

    /// Staging fails: retried, then at 10 s the song below is tried instead, then it stops and says so.
    @Test func stagingFallsBackThenGivesUp() async throws {
        let engine = FakeSpotifyEngine()
        engine.failStages = 100
        let session = try await makeSession(engine)
        let b = try #require(session.state.upNext.first)
        let c = try #require(session.state.upNext.dropFirst().first)

        engine.currentTime = 85
        await waitUntil { engine.stages.count == 3 }
        await pause()
        // Three tries at b, and nothing more until 10 s before the end.
        #expect(engine.stages == ["b", "b", "b"])
        #expect(session.state.lockedNextID == b.id)
        let readsBefore = engine.queueReads

        engine.currentTime = 91 // 9 s left: b isn't in the queue, so c goes first, locked
        await waitUntil { engine.stages.count == 6 }
        #expect(engine.queueReads == readsBefore + 1)
        #expect(session.state.upNext.prefix(2).map(\.id) == [c.id, b.id])
        #expect(session.state.lockedNextID == c.id)
        #expect(Array(engine.stages.suffix(3)) == ["c", "c", "c"])
        await pause()
        #expect(session.playerIssue == nil)

        engine.currentTime = 96 // 4 s left: c isn't there either
        await waitUntil { session.playerIssue != nil }
        await settle()
        #expect(session.playerIssue == "Couldn't queue the next song on Spotify")
        #expect(session.snapshot().playerIssue == session.playerIssue)
        #expect(session.state.lockedNextID == nil)
        #expect(session.state.upNext.prefix(2).map(\.id) == [c.id, b.id]) // b is tried at the next transition
        #expect(engine.stages.last == .some(nil)) // the engine stops expecting either
        let stages = engine.stages.count
        await pause()
        #expect(engine.stages.count == stages) // stops trying

        // Spotify plays what it likes (autoplay): followed, not overruled.
        engine.otherAppPlays(longSong("radio"))
        await settle()
        #expect(session.externalCurrent?.track.id == "radio")
        #expect(session.state.current?.track.id == "a")
        #expect(engine.plays == ["a"])
    }

    /// The fallback song lands: confirmed, no issue.
    @Test func theFallbackSongCanLand() async throws {
        let engine = FakeSpotifyEngine()
        engine.failStages = 3
        let session = try await makeSession(engine)
        engine.currentTime = 91 // already under 10 s: b's tries fail, its check fails, c goes
        await waitUntil { engine.queue.contains { $0.id == "c" } }
        await settle()
        #expect(engine.stages == ["b", "b", "b", "c"])
        #expect(session.state.upNext.first?.track.id == "c")
        #expect(session.state.lockedNextID == session.state.upNext.first?.id)
        #expect(session.playerIssue == nil)
    }

    /// A stage the player said OK to but that never shows in its queue counts as failed by 10 s.
    @Test func anUnconfirmedStageFallsBack() async throws {
        let engine = FakeSpotifyEngine()
        engine.stagesLand = false
        let session = try await makeSession(engine)
        engine.currentTime = 85
        await waitUntil { engine.stages.count == 1 }
        await pause()
        #expect(engine.stages == ["b"]) // it said OK: no retry
        engine.currentTime = 91
        await waitUntil { engine.stages.count == 2 }
        #expect(engine.stages == ["b", "c"])
        engine.currentTime = 96
        await waitUntil { session.playerIssue != nil }
        #expect(session.playerIssue != nil)
    }

    /// The bug from review: right after a song change the player's position can still be the old
    /// song's. The lock waits for the player to be on our current song, by its own length.
    @Test func noLockAtTheStartOfATrack() async throws {
        let engine = FakeSpotifyEngine()
        let session = try await makeSession(engine)
        // The player's last-seen track is still another one, near its end.
        engine.playing = longSong("previous")
        engine.currentTime = 95
        await pause()
        #expect(session.state.lockedNextID == nil)
        #expect(engine.stages.isEmpty)

        // Our song, from the start: nothing yet.
        engine.playing = longSong("a")
        engine.currentTime = 0
        await pause()
        #expect(session.state.lockedNextID == nil)

        // Timed by the player's length, not the session's idea of it.
        engine.playing = QueueTrack(id: "a", title: "a", artist: "Artist", duration: 300)
        engine.currentTime = 95
        await pause()
        #expect(session.state.lockedNextID == nil)
        engine.currentTime = 285
        await waitUntil { session.state.lockedNextID != nil }
        #expect(session.state.lockedNextID == session.state.upNext.first?.id)
    }

    /// Our staged song disappears from the player's queue (cleared, a new context): staged again.
    @Test func aStagedSongThatDisappearsIsStagedAgain() async throws {
        let engine = FakeSpotifyEngine()
        let session = try await makeSession(engine)
        engine.currentTime = 85
        await waitUntil { engine.queue.contains { $0.id == "b" } && engine.queueReads >= 2 }
        await settle()
        #expect(engine.stages == ["b"])

        engine.queue = [] // someone cleared it
        engine.otherAppPlays(longSong("album-1")) // and started an album
        await waitUntil { engine.stages.count == 2 }
        #expect(engine.stages == ["b", "b"])
        #expect(session.state.upNext.first?.track.id == "b")
        #expect(session.state.lockedNextID == session.state.upNext.first?.id)
    }

    /// Skip goes to what Up next shows first: the player's own queue, when it has some.
    @Test func skipGoesToThePlayersQueueFirst() async throws {
        let engine = FakeSpotifyEngine()
        engine.queue = [longSong("f")]
        let session = try await makeSession(engine)
        await waitUntil { !session.foreignUpcoming.isEmpty }
        await session.skip()
        await settle()
        #expect(engine.playerSkips == 1)
        #expect(session.externalCurrent?.track.id == "f")
        #expect(session.state.current?.track.id == "a")

        // Nothing of the player's left: skip moves Canopy's queue on and takes the player back.
        await session.skip()
        await settle()
        #expect(engine.playerSkips == 1)
        #expect(session.state.current?.track.id == "b")
        #expect(engine.plays == ["a", "b"])
        #expect(session.externalCurrent == nil)
    }

    // MARK: Party log

    @Test func foreignTracksAreLoggedWithoutARequester() async throws {
        let engine = FakeSpotifyEngine()
        let session = try await makeSession(engine)
        session.add(longSong("x"), by: guest)
        engine.otherAppPlays(longSong("f"))
        await settle()
        let foreign = try #require(session.partyLog.songs.first { $0.track.id == "f" })
        #expect(foreign.requester == nil)
        #expect(session.partyLog.tracks(onlyRequests: false, waiting: session.state.upNext).map(\.id).contains("f"))
        #expect(!session.partyLog.tracks(onlyRequests: true, waiting: session.state.upNext).map(\.id).contains("f"))
        #expect(session.partySaveInfo.allCount == 3) // a, f and the waiting request x
        #expect(session.partySaveInfo.requestCount == 1)
    }

    // MARK: Apple Music and demo stay as they were

    @Test func otherEnginesNeverFollow() async throws {
        let engine = FakeEngine(canReplaceStaged: false)
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        engine.onEvent?(.externalTrack(track("f")))
        await settle()
        #expect(session.externalCurrent == nil)
        #expect(session.snapshot().externalCurrent == nil)
        #expect(session.snapshot().foreignUpcoming == nil)
    }
}

/// `FollowRules`: how one read of the player is taken.
@Suite struct FollowRulesTests {
    typealias Rules = FollowRules
    let playing = { (id: String?) in FollowRules.Observation(trackID: id, isPlaying: id != nil, position: 30, duration: 200) }

    @Test func ourSongIsNothingToReport() {
        #expect(Rules.step(playing("a"), .init(ours: "a")) == .nothing)
    }

    @Test func anUnfamiliarTrackIsForeignEvenRightAfterAPlay() {
        #expect(Rules.step(playing("f"), .init(ours: "a")) == .foreign)
        // Right after our play request too: someone else's choice, never re-asserted over.
        #expect(Rules.step(playing("f"), .init(ours: "a", previous: "z", sincePlayRequest: 2)) == .foreign)
        // Reported once.
        #expect(Rules.step(playing("f"), .init(ours: "a", reportedForeign: "f")) == .nothing)
    }

    @Test func retriesOnlyWhenIdleOrStillOnThePreviousTrack() {
        #expect(Rules.step(nil, .init(ours: "a", sincePlayRequest: 2)) == .retryPlay) // no device / no state
        #expect(Rules.step(.init(trackID: "z", isPlaying: false), .init(ours: "a", sincePlayRequest: 2)) == .retryPlay) // paused
        #expect(Rules.step(playing("z"), .init(ours: "a", previous: "z", sincePlayRequest: 2)) == .retryPlay) // still on ours from before
        #expect(Rules.step(playing("z"), .init(ours: "a", previous: "z", sincePlayRequest: 2, retriedPlay: true)) == .nothing) // once
        #expect(Rules.step(nil, .init(ours: "a", sincePlayRequest: 12)) == .nothing) // too late to be our request
    }

    /// Paused since the play request (the music moved to another output, say): a retry would
    /// start the old output again under the new one.
    @Test func neverRetriesOncePaused() {
        #expect(Rules.step(nil, .init(ours: "a", sincePlayRequest: 2, pausedByUs: true)) == .nothing)
        #expect(Rules.step(.init(trackID: "z", isPlaying: false), .init(ours: "a", sincePlayRequest: 2, pausedByUs: true)) == .nothing)
        #expect(Rules.step(playing("z"), .init(ours: "a", previous: "z", sincePlayRequest: 2, pausedByUs: true)) == .nothing)
    }

    @Test func ourStagedSongAdvances() {
        #expect(Rules.step(playing("b"), .init(ours: "a", staged: "b")) == .advancedToStaged)
        // After foreign tracks too.
        #expect(Rules.step(playing("b"), .init(ours: "a", staged: "b", reportedForeign: "f")) == .advancedToStaged)
    }

    @Test func backToOursAfterAForeignTrack() {
        #expect(Rules.step(playing("a"), .init(ours: "a", reportedForeign: "f")) == .backToOurs)
    }

    @Test func reachedEndOnlyWhenOurSongStoppedAtItsEnd() {
        let stopped = Rules.Observation(trackID: "a", isPlaying: false, position: 199, duration: 200)
        #expect(Rules.step(stopped, .init(ours: "a")) == .reachedEnd)
        #expect(Rules.step(stopped, .init(ours: "a", pausedByUs: true)) == .nothing)
        #expect(Rules.step(stopped, .init(ours: "a", staged: "b")) == .nothing)
        #expect(Rules.step(.init(trackID: "a", isPlaying: false, position: 80, duration: 200), .init(ours: "a")) == .nothing) // paused midway
        // A foreign track that stopped isn't ours to move on from.
        #expect(Rules.step(.init(trackID: "f", isPlaying: false, position: 199, duration: 200), .init(ours: "a", reportedForeign: "f")) == .nothing)
    }

    @Test func foreignItemsDeduplicateAgainstOurStagedSong() {
        let q = { (ids: [String]) in ids.map(longSong) }
        let ids = { (r: (items: [QueueTrack], stagedQueued: Bool)) in r.items.map(\.id) }
        // Ours listed once, as ours; foreign ahead of it stay ahead; after it, not shown.
        let r1 = Rules.foreignUpcoming(in: q(["f1", "b", "f2", "b"]), staged: "b")
        #expect(ids(r1) == ["f1"])
        #expect(r1.stagedQueued)
        #expect(ids(Rules.foreignUpcoming(in: q(["b", "f1"]), staged: "b")) == [])
        // Not in the queue (yet): everything is ahead of it.
        let r2 = Rules.foreignUpcoming(in: q(["f1", "f2"]), staged: "b")
        #expect(ids(r2) == ["f1", "f2"])
        #expect(!r2.stagedQueued)
        #expect(ids(Rules.foreignUpcoming(in: q(["f1"]), staged: nil)) == ["f1"])
        #expect(Rules.foreignUpcoming(in: q((0..<40).map { "f\($0)" }), staged: nil).items.count == Rules.foreignLimit)
    }

    /// After a relaunch, Spotify is still playing the restored song: the session watches it, shows
    /// it playing, and Play after a pause resumes it rather than starting it over.
    @MainActor @Test func aRelaunchFollowsWhatSpotifyIsStillPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-follow-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PartySession(catalog: LongSongsCatalog(ids: ["a", "b", "c"]), engine: FakeSpotifyEngine(), storeURL: url)
        try await first.load(playlist: base)
        try await first.play()
        try await Task.sleep(for: .milliseconds(800))
        first.shutdown()

        let engine = FakeSpotifyEngine()
        engine.playing = longSong("a")
        engine.isPlaying = true
        engine.currentTime = 42
        let restored = PartySession(catalog: LongSongsCatalog(ids: []), engine: engine, storeURL: url)
        #expect(engine.attachedTo == "a")
        #expect(!restored.isPlaying)
        // Spotify's first reading after the relaunch.
        engine.onEvent?(.statusChanged)
        let playingAfterReading = restored.isPlaying
        let position = engine.currentTime
        #expect(playingAfterReading)
        #expect(position == 42)
        await restored.pause()
        try await restored.play()
        let plays = engine.plays
        let resumed = engine.isPlaying
        #expect(plays.isEmpty)
        #expect(resumed)
    }

    /// Seen on a real account with repeat on: after its queue, Spotify lists the song Canopy just
    /// played (its one-song context) ten times. Those aren't anyone's requests.
    @Test func ourOwnSongsReplayedAfterTheQueueArentForeign() {
        let q = { (ids: [String]) in ids.map(longSong) }
        let ids = { (r: (items: [QueueTrack], stagedQueued: Bool)) in r.items.map(\.id) }
        let replay = Array(repeating: "prologue", count: 10)
        #expect(ids(Rules.foreignUpcoming(in: q(replay), staged: nil, ours: ["prologue", "shire"])) == [])
        // Someone's real request ahead of the replay still shows; the replay doesn't.
        #expect(ids(Rules.foreignUpcoming(in: q(["f1"] + replay), staged: nil, ours: ["prologue"])) == ["f1"])
        // Back-to-back duplicates of a foreign song show once.
        #expect(ids(Rules.foreignUpcoming(in: q(["f1", "f1", "f2"]), staged: nil)) == ["f1", "f2"])
    }
}

/// The follow-mode snapshot fields are optional: older peers ignore them, older hubs omit them.
@MainActor
@Suite struct FollowSnapshotTests {
    @Test func roundTripsWithTheNewFields() async throws {
        let engine = FakeSpotifyEngine()
        engine.queue = [longSong("f1"), longSong("f2")]
        let session = PartySession(catalog: LongSongsCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        engine.otherAppPlays(longSong("x"))
        let deadline = Date().addingTimeInterval(2)
        while session.foreignUpcoming.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let snapshot = session.snapshot()
        #expect(snapshot.externalCurrent?.track.id == "x")
        #expect(snapshot.foreignUpcoming?.map(\.track.id) == ["f1", "f2"])
        let decoded = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.externalCurrent?.id == snapshot.externalCurrent?.id)
        #expect(decoded.externalCurrent?.track == snapshot.externalCurrent?.track)
        #expect(decoded.externalCurrent?.requester == nil)
        #expect(decoded.foreignUpcoming?.map(\.id) == snapshot.foreignUpcoming?.map(\.id))
        #expect(decoded.foreignUpcoming?.map(\.track) == snapshot.foreignUpcoming?.map(\.track))
        #expect(decoded.playerIssue == nil)

        // A display shows the same.
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(decoded)
        #expect(display.nowPlaying?.track.id == "x")
        #expect(display.state.current?.track.id == "a")
        #expect(display.foreignUpcoming.map(\.track.id) == ["f1", "f2"])
    }

    @Test func decodesWithoutTheNewFields() throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.snapshot())) as? [String: Any])
        #expect(json["externalCurrent"] == nil)
        #expect(json["foreignUpcoming"] == nil)
        #expect(json["playerIssue"] == nil)
        json["externalCurrent"] = nil
        let decoded = try JSONDecoder().decode(PartySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.externalCurrent == nil)
        #expect(decoded.foreignUpcoming == nil)
        #expect(decoded.playerIssue == nil)
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(decoded)
        #expect(display.externalCurrent == nil)
        #expect(display.foreignUpcoming.isEmpty)
    }
}
