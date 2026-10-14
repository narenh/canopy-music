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
    /// The last `setCrossfade`: whether it's on, and its length.
    var crossfade: (enabled: Bool, duration: TimeInterval?)?
    func setCrossfade(enabled: Bool, duration: TimeInterval?) { crossfade = (enabled, duration) }

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

    /// An Apple TV stays awake only while music plays, and not then either with the setting on.
    @Test func aTVKeepsItsScreenAwakeOnlyWhilePlaying() {
        #expect(PartySession.tvKeepsScreenAwake(isPlaying: true, screensaverWhilePlaying: false))
        #expect(!PartySession.tvKeepsScreenAwake(isPlaying: false, screensaverWhilePlaying: false))
        #expect(!PartySession.tvKeepsScreenAwake(isPlaying: true, screensaverWhilePlaying: true))
        #expect(!PartySession.tvKeepsScreenAwake(isPlaying: false, screensaverWhilePlaying: true))
    }

    /// "Screensaver while playing" is an Apple TV hub setting, off by default, sent to displays.
    @Test func screensaverWhilePlayingIsATVSetting() async throws {
        let tv = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        tv.configureHub(kind: .tv, zoneName: "Den", serviceName: "Demo")
        #expect(tv.snapshot().screensaverWhilePlaying == false)
        tv.applyHostSettings(zoneName: nil, phonesCanReorder: nil, displaysCanControl: nil, screensaverWhilePlaying: true)
        #expect(tv.screensaverWhilePlaying)
        let sent = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(tv.snapshot()))
        #expect(sent.screensaverWhilePlaying == true)

        let ipad = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        ipad.configureHub(kind: .ipad, zoneName: "Kitchen", serviceName: "Demo")
        ipad.applyHostSettings(zoneName: nil, phonesCanReorder: nil, displaysCanControl: nil, screensaverWhilePlaying: true)
        #expect(!ipad.screensaverWhilePlaying)
        #expect(ipad.snapshot().screensaverWhilePlaying == nil)
    }

    /// The party page's Crossfade button: hosts see the hub's crossfade, and turning it on from
    /// there keeps the hub's length; an engine swapped in gets it too.
    @Test func crossfadeIsForHostsAndFollowsTheEngine() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: engine)
        session.configureHub(kind: .ipad, zoneName: "Kitchen", serviceName: "Demo")
        session.hostKey = "secret"
        #expect(session.snapshot(hostKey: "secret").crossfade == nil)
        final class Count { var value = 0 }
        let changes = Count()
        session.onSettingsChanged = { changes.value += 1 }

        session.setCrossfade(enabled: false, duration: 6)
        #expect(session.snapshot(hostKey: "secret").crossfade == false)
        session.applyHostSettings(zoneName: nil, phonesCanReorder: nil, displaysCanControl: nil, crossfade: true)
        #expect(session.crossfade == true)
        #expect(engine.crossfade?.enabled == true && engine.crossfade?.duration == 6)
        #expect(changes.value == 1)
        let sent = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(session.snapshot(hostKey: "secret")))
        #expect(sent.crossfade == true)
        // Guests' snapshots don't carry it.
        #expect(session.snapshot().crossfade == nil)
        #expect(session.snapshot(hostKey: "wrong").crossfade == nil)
        // Other settings leave it alone.
        session.applyHostSettings(zoneName: "Den", phonesCanReorder: nil, displaysCanControl: nil)
        #expect(session.crossfade == true)

        let next = FakeEngine()
        #expect(session.replaceService(catalog: StubCatalog(ids: ["a"]), engine: next, serviceName: "Demo"))
        #expect(next.crossfade?.enabled == true && next.crossfade?.duration == 6)
    }

    /// A hub that never set crossfade leaves a swapped-in engine's own (Sonos's) alone.
    @Test func anEngineSwappedInKeepsItsCrossfadeIfTheHubNeverSetOne() {
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        let next = FakeEngine()
        #expect(session.replaceService(catalog: StubCatalog(ids: ["a"]), engine: next, serviceName: "Demo"))
        #expect(next.crossfade == nil)
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

    /// Before anything has played (setup, the start screen) a new playlist starts over, requests
    /// and all. Once the music has started it keeps the party going (`PlaylistChangeTests`).
    @Test func loadingANewPlaylistBeforePlayingClears() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
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

    /// A hub coming back after a crash has its queue but stays paused until someone presses play.
    @Test func aRestoredQueueStaysPaused() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await first.load(playlist: base)
        try await first.play()
        try await Task.sleep(for: .milliseconds(800))
        let engine = FakeEngine()
        let restored = PartySession(catalog: StubCatalog(ids: []), engine: engine, storeURL: url)
        await settle()
        #expect(restored.state.current?.track.id == "a")
        #expect(!restored.isPlaying)
        #expect(engine.playing == nil)
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

    /// A display removes only the requests it added (the hub keeps its client ID on them, as a
    /// phone's): not a guest's, another display's or a playlist song.
    @Test func aDisplayRemovesOnlyItsOwnRequests() async throws {
        let hub = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        try await hub.load(playlist: base)
        try await hub.play()
        guard case .added(let mine, _) = hub.add(track("x"), by: Requester(name: "Kitchen iPad", clientID: "kitchen", origin: .ipad), id: UUID()),
              case .added(let theirs, _) = hub.add(track("y"), by: guest),
              case .added(let den, _) = hub.add(track("z"), by: Requester(name: "Den iPad", clientID: "den", origin: .ipad), id: UUID())
        else { Issue.record("not added"); return }
        let remote = RecordingRemote(clientID: "kitchen")
        let display = PartySession(remote: remote)
        display.apply(hub.snapshot())
        let playlistItem = try #require(display.state.upNext.first { !$0.isRequest })

        #expect(display.isOwnRequest(mine))
        for item in [theirs, den, playlistItem] {
            #expect(!display.isOwnRequest(item))
            #expect(!display.remove(item.id))
        }
        #expect(!hub.isOwnRequest(mine)) // a hub's own UI has its own rules
        #expect(display.remove(mine.id))
        #expect(!display.state.upNext.contains { $0.id == mine.id })
        await settle()
        #expect(remote.sent == [.remove(mine.id)])

        // The hub takes it from that display's ID only.
        #expect(!hub.remove(mine.id, asClient: "den"))
        #expect(hub.remove(mine.id, asClient: "kitchen"))
    }

    /// A display's own new request carries its client ID before the hub's copy arrives.
    @Test func aDisplaysOwnAddIsItsToRemove() async throws {
        let remote = RecordingRemote(clientID: "kitchen")
        let display = PartySession(remote: remote)
        guard case .added(let item, _) = display.add(track("x"), by: Requester(origin: .ipad)) else { Issue.record("not added"); return }
        #expect(item.requester?.clientID == "kitchen")
        #expect(display.isOwnRequest(item))
        #expect(display.remove(item.id))
        await settle()
        #expect(remote.sent == [.add(track("x"), itemID: item.id), .remove(item.id)])
    }

    /// The locked next song stays, for a display (it doesn't ask) and on the hub, as for phones.
    @Test func aDisplayCantRemoveTheLockedNextSong() async throws {
        struct TimedCatalog: MusicCatalog {
            func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
            func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
            func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
            func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
                ["a", "b", "c"].map { QueueTrack(id: $0, title: $0, artist: "Artist", duration: 10) }
            }
        }
        // Late staging locks the next song within a second, the song being nearly over.
        let hub = PartySession(catalog: TimedCatalog(), engine: FakeEngine(canReplaceStaged: false))
        try await hub.load(playlist: base)
        try await hub.play()
        let kitchen = Requester(name: "Kitchen iPad", clientID: "kitchen", origin: .ipad)
        guard case .added(let mine, _) = hub.add(track("x"), by: kitchen, id: UUID()) else { Issue.record("not added"); return }
        let deadline = Date().addingTimeInterval(5)
        while hub.state.lockedNextID != mine.id, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(hub.state.lockedNextID == mine.id)

        let remote = RecordingRemote(clientID: "kitchen")
        let display = PartySession(remote: remote)
        display.apply(hub.snapshot())
        #expect(display.isOwnRequest(mine))
        #expect(!display.remove(mine.id))
        await settle()
        #expect(remote.sent.isEmpty)
        #expect(!hub.remove(mine.id, asClient: "kitchen"))
        #expect(hub.state.upNext.contains { $0.id == mine.id })
    }

    /// Snapshots from older hubs, and the hub's own requests, carry no client ID: they decode,
    /// and a display can't remove them.
    @Test func requestsWithoutAClientIDStillDecode() throws {
        let id = UUID()
        let json = """
        {"version": 3, "upNext": [{"id": "\(id.uuidString)", "autoPlaced": true, "addedAt": 0,
          "track": {"id": "x", "title": "X", "artist": "A", "album": "", "isExplicit": false},
          "requester": {"name": "Kitchen iPad", "origin": "ipad"}}],
         "playback": {"isPlaying": false, "position": 0, "capturedAt": 0}, "canReorder": true}
        """
        let snapshot = try JSONDecoder().decode(PartySnapshot.self, from: Data(json.utf8))
        let item = try #require(snapshot.upNext.first)
        #expect(item.requester?.clientID == nil)
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(snapshot)
        #expect(!display.isOwnRequest(item))
        #expect(!display.remove(id))
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

    /// Paused, a skip moves the queue on and leaves the player on the song before: the new song
    /// is at 0:00 (Now Playing and snapshots), and previous goes back rather than restarting.
    @Test func aSkipWhilePausedStartsTheNewSongAtZero() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.currentTime = 10
        session.pause()
        await session.skip()
        #expect(session.state.current?.track.id == "b")
        #expect(engine.currentTime == 10)
        #expect(session.position == 0)
        #expect(session.snapshot().playback.position == 0)
        await session.previous()
        #expect(session.state.current?.track.id == "a")
        #expect(session.position == 0)
        // Playing loads the song, from the start; the engine's time is the song's again.
        engine.currentTime = 0
        try await session.play()
        engine.currentTime = 2
        #expect(engine.playing?.id == "a")
        #expect(session.position == 2)
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

/// A hub's new session (End then a new zone, a service change, a relaunch) counts versions from
/// 0 again; its snapshots carry a new epoch so pages and displays that stay open take them.
@MainActor
@Suite struct SessionEpochTests {
    @Test func eachSessionHasItsOwnEpoch() async throws {
        let first = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        let second = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        #expect(first.epoch != second.epoch)
        #expect(first.snapshot().epoch == first.epoch)
        let sent = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(first.snapshot()))
        #expect(sent.epoch == first.epoch)
    }

    @Test func aDisplayTakesALowerVersionFromANewSession() async throws {
        let hub = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d"]), engine: FakeEngine())
        try await hub.load(playlist: base)
        try await hub.play()
        hub.add(track("x"), by: guest)
        await hub.skip()
        await settle()
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(hub.snapshot())
        #expect(display.state.current != nil)
        #expect(display.state.current?.id == hub.state.current?.id)
        #expect(display.state.version == hub.state.version)
        #expect(hub.state.version > 1)

        // The hub started over (End, then a new zone; or a relaunch): version 1, new epoch.
        let next = PartySession(catalog: StubCatalog(ids: ["z"]), engine: FakeEngine())
        try await next.load(playlist: base)
        let fresh = next.snapshot()
        #expect(fresh.version < display.state.version)
        display.apply(fresh)
        #expect(display.state.upNext.map(\.track.id) == ["z"])
        #expect(display.state.current == nil)
        #expect(display.state.version == fresh.version)
    }

    @Test func lowerVersionsFromTheSameSessionAreStillSkipped() async throws {
        let hub = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: FakeEngine())
        try await hub.load(playlist: base)
        try await hub.play()
        let older = hub.snapshot()
        await hub.skip()
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(hub.snapshot())
        #expect(display.state.current?.track.id == "b")
        display.apply(older) // late over the socket
        #expect(display.state.current?.track.id == "b")
        // An optimistic local edit bumps the display's version; the hub's older snapshot is skipped
        // too, until the hub's copy of the edit arrives.
        display.add(track("x"), by: Requester(origin: .ipad))
        display.apply(hub.snapshot())
        #expect(display.state.upNext.contains { $0.track.id == "x" })
        hub.add(track("x"), by: Requester(origin: .ipad))
        display.apply(hub.snapshot())
        #expect(display.state.version == hub.state.version)
    }

    /// Snapshots from older hubs carry no epoch: compared by version alone, as before.
    @Test func snapshotsWithoutAnEpochCompareByVersion() async throws {
        let hub = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: FakeEngine())
        try await hub.load(playlist: base)
        try await hub.play()
        var older = hub.snapshot()
        older.epoch = nil
        await hub.skip()
        var newer = hub.snapshot()
        newer.epoch = nil
        let display = PartySession(remote: RecordingRemote(clientID: "kitchen"))
        display.apply(newer)
        display.apply(older)
        #expect(display.state.current?.track.id == "b")
        // And one that decodes without the field at all.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(newer)) as? [String: Any])
        json["epoch"] = nil
        let decoded = try JSONDecoder().decode(PartySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.epoch == nil)
    }
}

/// An Apple TV's Apple Music access reaches hosts' pages only, and live.
@MainActor
@Suite struct MusicAccessTests {
    @Test func onlyHostsSeeIt() {
        let tv = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        tv.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        tv.hostKey = "secret"
        tv.musicAccess = .denied
        #expect(tv.snapshot().musicAccess == nil)
        #expect(tv.snapshot(hostKey: "wrong").musicAccess == nil)
        #expect(tv.snapshot(hostKey: "").musicAccess == nil)
        #expect(tv.snapshot(hostKey: "secret").musicAccess == .denied)
    }

    @Test func hostListenersHearChangesAndGuestsDont() async {
        let tv = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        tv.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        tv.hostKey = "secret"
        tv.musicAccess = .notDetermined
        var host = tv.snapshots(hostKey: "secret").makeAsyncIterator()
        var guest = tv.snapshots().makeAsyncIterator()
        #expect(await host.next()?.musicAccess == .notDetermined)
        #expect(await guest.next()?.musicAccess == nil)
        tv.musicAccess = .ok
        #expect(await host.next()?.musicAccess == .ok)
        #expect(await guest.next()?.musicAccess == nil)
        // A revoked key stops getting it, without reconnecting.
        tv.hostKey = "new"
        tv.musicAccess = .error
        #expect(await host.next()?.musicAccess == nil)
    }

    @Test func aHostsPageAsksForACheck() {
        let tv = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        var asked = 0
        tv.onMusicAccessCheck = { asked += 1 }
        tv.checkMusicAccess()
        #expect(asked == 1)
    }
}

/// Ending a zone clears the session and its saved queue, so the next zone starts empty.
@MainActor
@Suite struct EndZoneTests {
    @Test func endStopsAndClearsEverything() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.add(track("x"), by: guest)
        await session.skip()
        #expect(!session.state.history.isEmpty)
        let before = session.state.version

        session.end()

        #expect(!engine.isPlaying)
        #expect(!session.isPlaying)
        #expect(session.state.current == nil)
        #expect(session.state.upNext.isEmpty)
        #expect(session.state.history.isEmpty)
        #expect(session.state.playlistName == nil)
        #expect(session.state.upcomingPage(offset: 0, limit: 10).total == 0)
        #expect(!session.hasParty)
        // Pages that stay open drop snapshots older than the last one they saw.
        #expect(session.state.version > before)
    }

    @Test func endDeletesTheSavedQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await session.load(playlist: base)
        try await session.play()
        try await Task.sleep(for: .milliseconds(800))
        #expect(FileManager.default.fileExists(atPath: url.path))

        session.end()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let next = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(next.state.current == nil)
        #expect(next.state.upNext.isEmpty)
        #expect(next.state.history.isEmpty)
    }

    @Test func aSaveStillPendingDoesNotBringTheQueueBack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine(), storeURL: url)
        try await session.load(playlist: base) // schedules a save in 0.5 s
        session.end()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func listenersSeeTheEmptyQueue() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        try await session.load(playlist: base)
        var updates = session.snapshots().makeAsyncIterator()
        #expect(await updates.next()?.upNext.isEmpty == false)
        session.end()
        let last = await updates.next()
        #expect(last?.upNext.isEmpty == true)
        #expect(last?.current == nil)
        #expect(last?.playlistName == nil)
    }

    @Test func endKeepsTheZoneSettings() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        session.configureHub(kind: .ipad, id: "hub", zoneName: "Den", serviceName: "Demo")
        session.phonesCanQueue = false
        session.phonesCanReorder = false
        session.displaysCanControl = false
        session.wifi = WifiDetails(ssid: "Guest", password: "pw")
        session.hostKey = "key"
        try await session.load(playlist: base)
        session.end()
        #expect(session.zoneName == "Den")
        #expect(!session.phonesCanQueue)
        #expect(!session.phonesCanReorder)
        #expect(!session.displaysCanControl)
        #expect(session.wifi.ssid == "Guest")
        #expect(session.isHost(key: "key"))
    }

    @Test func theNextZoneStartsFromAnEmptyQueue() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        session.end()
        try await session.load(playlist: base)
        try await session.play()
        #expect(engine.playing?.id == "a")
        #expect(session.state.history.isEmpty)
    }
}
