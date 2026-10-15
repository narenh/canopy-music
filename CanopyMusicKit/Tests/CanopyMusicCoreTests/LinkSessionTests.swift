import Foundation
import Testing
@testable import CanopyMusicCore

/// canopy-cmdlp, as the session uses it, without a network: each link's track, and what its
/// download says each time it's asked (`steps`, the last repeated).
@MainActor
final class FakeLinkService: LinkService {
    var tracks: [String: CmdlpTrack] = [:]
    /// What each `track(id:)` answers next, in turn, per id; the last stays.
    var steps: [String: [CmdlpTrack]] = [:]
    /// Refusals by link.
    var refusals: [String: CmdlpError] = [:]
    /// Lookups wait this long first.
    var lookupDelay: Duration = .zero
    /// `track(id:)` answers this instead (cmdlp unreachable, or a 404).
    var trackError: (any Error)?
    private(set) var resolveCalls: [(url: String, zone: String)] = []
    private(set) var trackCalls = 0
    private(set) var deletedZones: [String] = []

    /// A pending track for `link`, then `steps` (say, 30%, 80%, ready).
    func add(_ link: String, id: String, title: String = "Song", steps: [CmdlpTrack]) {
        tracks[link] = Self.track(id, title: title, status: .pending)
        self.steps[id] = steps
    }

    static func track(_ id: String, title: String = "Song", zone: String = "zone-1", status: LinkTrack.Status, percent: Double? = nil,
                      error: String? = nil) -> CmdlpTrack {
        CmdlpTrack(id: id, zone: zone, status: status, title: title, artist: "Artist", duration: 200, artwork: "https://art.example/\(id).jpg",
                   service: "YouTube", stage: status == .pending ? "downloading" : nil, progress: percent.map { .init(percent: $0) },
                   audioUrl: "https://cmdlp.example/audio/\(id).m4a?sig=secret-\(id)", error: error)
    }

    func resolve(_ url: String, zone: String) async throws -> CmdlpTrack {
        resolveCalls.append((url, zone))
        if lookupDelay > .zero { try await Task.sleep(for: lookupDelay) }
        if let refusal = refusals[url] { throw refusal }
        guard let track = tracks[url] else { throw CmdlpError(status: 422, reason: "unsupported_link", message: "Not one of the five sites.") }
        return track
    }

    func track(id: String) async throws -> CmdlpTrack {
        trackCalls += 1
        if let trackError { throw trackError }
        guard var queue = steps[id], let next = queue.first else {
            guard let track = tracks.values.first(where: { $0.id == id }) else { throw CmdlpError(status: 404, reason: "not_found") }
            return track
        }
        if queue.count > 1 { queue.removeFirst() }
        steps[id] = queue
        return next
    }

    func deleteZone(_ zone: String) async throws {
        deletedZones.append(zone)
    }
}

/// Links on the hub: looked up for a phone, queued, watched while they download, failed ones
/// dropped with a notice, the zone's downloads deleted when it ends, and the rule for a link
/// still downloading at its turn (`DownloadingLinkPlan`).
@MainActor
@Suite struct LinkSessionTests {
    let guest = Requester(name: "Sam", clientID: "phone-1", origin: .phone)
    static let youtube = "https://www.youtube.com/watch?v=abc"
    static let soundcloud = "https://soundcloud.com/forss/flickermood"

    func session(_ service: FakeLinkService, engine: FakeEngine = FakeEngine(), ids: [String] = ["a", "b", "c"]) async throws -> PartySession {
        engine.playsLinks = true
        let session = PartySession(catalog: StubCatalog(ids: ids), engine: engine)
        session.landingDelay = 0.05
        session.linkPollInterval = .milliseconds(10)
        session.linkWaitAtTurn = 0.3
        session.linkZone = "zone-1"
        session.linkService = service
        try await session.load(playlist: base)
        return session
    }

    /// A guest pastes the YouTube link and adds it; the session restages behind it.
    func queueLink(_ session: PartySession) async throws {
        _ = try await session.addLink(try #require(try await session.resolveLink(Self.youtube)), by: guest)
        await settle()
    }

    /// Waits (up to 3 s) until `condition` holds, the polls and the session's own work running
    /// meanwhile. The checks after it say whether it did.
    func eventually(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            await settle()
        }
    }

    /// Lets the polls run a few times.
    func poll(_ times: Int = 3) async {
        for _ in 0..<times {
            try? await Task.sleep(for: .milliseconds(15))
            await settle()
        }
    }

    // MARK: Off

    @Test func linksAreOffUntilTheHubHasCmdlp() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        #expect(!session.linksEnabled)
        #expect(session.snapshot().links == nil)
        await #expect(throws: LinkRefusal.unavailable) { try await session.resolveLink(Self.youtube) }
        session.linkZone = "zone-1"
        #expect(session.snapshot().links == nil)
        session.linkService = FakeLinkService()
        #expect(session.snapshot().links == true)
        session.linkService = nil
        #expect(session.snapshot().links == nil)
    }

    /// Spotify Connect can't play a link: the phone that pasted one is told so.
    @Test func aZoneThatCantPlayLinksSaysSo() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: engine)
        session.linkZone = "zone-1"
        session.linkService = service
        #expect(session.snapshot().links == true)
        await #expect(throws: LinkRefusal.notHere) { try await session.resolveLink(Self.youtube) }
        await #expect(throws: LinkRefusal.notHere) {
            try await session.addLink(FakeLinkService.track("L1", status: .ready).queueTrack.forGuests, by: guest)
        }
        #expect(service.resolveCalls.isEmpty)
        #expect(LinkRefusal.notHere.message == "Links can't play in this zone.")
    }

    // MARK: Looking up

    @Test func aPastedLinkIsLookedUpForThePhone() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Never Gonna", steps: [])
        let session = try await session(service)
        let found = try #require(try await session.resolveLink("  \(Self.youtube) "))
        #expect(found.id == "link:L1")
        #expect(found.title == "Never Gonna")
        #expect(found.link?.audioURL == nil)
        #expect(service.resolveCalls.map(\.zone) == ["zone-1"])
        #expect(service.resolveCalls.map(\.url) == [Self.youtube])
    }

    @Test func cmdlpsRefusalReachesThePhone() async throws {
        let service = FakeLinkService()
        service.refusals[Self.youtube] = CmdlpError(status: 422, reason: "playlist", message: "That's a playlist, not one track.")
        let session = try await session(service)
        await #expect(throws: LinkRefusal("That's a playlist, not one track.")) { try await session.resolveLink(Self.youtube) }
        // Not kept: asked again, cmdlp is asked again.
        _ = try? await session.resolveLink(Self.youtube)
        #expect(service.resolveCalls.count == 2)
    }

    /// A lookup that takes a while (YouTube's can take 20 s): the phone hears "not yet", asks
    /// again, and joins the same lookup.
    @Test func aSlowLookupIsJoinedNotRepeated() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        service.lookupDelay = .milliseconds(200)
        let session = try await session(service)
        #expect(try await session.resolveLink(Self.youtube, waitingAtMost: 0.02) == nil)
        #expect(try await session.resolveLink(Self.youtube, waitingAtMost: 0.02) == nil)
        let found = try await session.resolveLink(Self.youtube, waitingAtMost: 2)
        #expect(found?.id == "link:L1")
        #expect(service.resolveCalls.count == 1)
    }

    // MARK: Queueing and downloading

    /// Picked from the results: queued at once with its art, its progress shown as it downloads,
    /// and the hub (never a phone) holding its audio's address.
    @Test func aQueuedLinkShowsItsDownload() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [
            FakeLinkService.track("L1", status: .pending, percent: 30),
            FakeLinkService.track("L1", status: .pending, percent: 80),
            FakeLinkService.track("L1", status: .ready),
        ])
        let session = try await session(service)
        // Each check made here, one at a time.
        session.linkPollInterval = .seconds(3600)
        let found = try #require(try await session.resolveLink(Self.youtube))
        // The phone's copy has no audio address, and a made-up one is ignored.
        var picked = found
        picked.link?.audioURL = URL(string: "https://evil.example/x.m4a")
        guard case .added(let item, let index) = try await session.addLink(picked, by: guest) else {
            Issue.record("not added")
            return
        }
        #expect(index == 0)
        #expect(item.track.artworkURL?.absoluteString == "https://art.example/L1.jpg")
        #expect(item.track.link?.audioURL?.absoluteString == "https://cmdlp.example/audio/L1.m4a?sig=secret-L1")
        #expect(item.track.link?.status == .pending)
        func row() -> QueueTrack? { session.state.upNext.first { $0.track.link != nil }?.track }
        #expect(await session.pollLink("L1"))
        #expect(row()?.rowSubtitle == "Downloading 30% · Artist")
        #expect(session.snapshot().upNext.first?.track.link?.percent == 30)
        #expect(await session.pollLink("L1"))
        #expect(row()?.rowSubtitle == "Downloading 80% · Artist")
        // Ready: nothing more to ask.
        #expect(await !session.pollLink("L1"))
        #expect(row()?.rowSubtitle == "Artist")
        #expect(row()?.link?.isPlayable == true)
    }

    /// Snapshots (phones, displays, hosts) never carry a link's signed audio address.
    @Test func snapshotsNeverCarryTheAudioAddress() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        session.hostKey = "host"
        try await session.play()
        try await queueLink(session)
        await poll(3)
        #expect(session.state.upNext.first?.track.link?.audioURL != nil)
        for snapshot in [session.snapshot(), session.snapshot(includingWifi: true), session.snapshot(hostKey: "host")] {
            let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            #expect(text.contains("link:L1"))
            #expect(!text.contains("secret-L1"))
            #expect(!text.contains("/audio/"))
        }
    }

    @Test func theSameLinkTwiceIsQueuedOnce() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        service.tracks["https://youtu.be/abc"] = service.tracks[Self.youtube]
        let session = try await session(service)
        let first = try #require(try await session.resolveLink(Self.youtube))
        let second = try #require(try await session.resolveLink("https://youtu.be/abc"))
        #expect(first.id == second.id)
        guard case .added = try await session.addLink(first, by: guest) else { Issue.record("not added"); return }
        guard case .alreadyQueued = try await session.addLink(second, by: Requester(name: "Kim", clientID: "phone-2", origin: .phone)) else {
            Issue.record("queued twice")
            return
        }
    }

    /// Picked after the hub relaunched (it has no record of the lookup): cmdlp still has it.
    @Test func aPickTheHubDoesntKnowIsFetched() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        let picked = FakeLinkService.track("L1", status: .pending).queueTrack.forGuests
        _ = try await session.addLink(picked, by: guest)
        #expect(session.state.upNext.first?.track.link?.audioURL != nil)
        // Not another zone's download.
        service.steps["L2"] = [FakeLinkService.track("L2", zone: "other-zone", status: .ready)]
        await #expect(throws: LinkRefusal.unavailable) {
            try await session.addLink(FakeLinkService.track("L2", status: .ready).queueTrack.forGuests, by: guest)
        }
    }

    /// A download that fails leaves the queue at once, and everyone's told why.
    @Test func aFailedDownloadLeavesWithANotice() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Gone", steps: [
            FakeLinkService.track("L1", status: .pending, percent: 20),
            FakeLinkService.track("L1", status: .failed, error: "ERROR: [youtube] abc: Video unavailable"),
        ])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        try await queueLink(session)
        #expect(await session.pollLink("L1"))
        #expect(session.state.upNext.contains { $0.track.link != nil })
        #expect(await !session.pollLink("L1"))
        #expect(!session.state.upNext.contains { $0.track.link != nil })
        #expect(session.playerIssue == "“Gone” couldn't download: Video unavailable")
        #expect(session.snapshot().notice?.text == "“Gone” couldn't download: Video unavailable")
    }

    /// cmdlp lost it (its zone swept, say): as a failure.
    @Test func aDownloadCmdlpLostLeaves() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        let session = try await session(service)
        try await queueLink(session)
        service.trackError = CmdlpError(status: 404, reason: "not_found")
        await eventually { !session.state.upNext.contains { $0.track.link != nil } }
        #expect(!session.state.upNext.contains { $0.track.link != nil })
        #expect(session.playerIssue?.hasSuffix("couldn't download: Its download is gone.") == true)
    }

    /// cmdlp not answering for a moment isn't a failure: it's asked again.
    @Test func cmdlpNotAnsweringIsntAFailure() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        try await queueLink(session)
        service.trackError = URLError(.timedOut)
        #expect(await session.pollLink("L1"))
        #expect(session.state.upNext.first?.track.link?.status == .pending)
        service.trackError = nil
        #expect(await !session.pollLink("L1"))
        #expect(session.state.upNext.first?.track.link?.isPlayable == true)
    }

    // MARK: Zone end

    @Test func endingTheZoneDeletesItsDownloads() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        let session = try await session(service)
        try await queueLink(session)
        session.end()
        await eventually { !service.deletedZones.isEmpty }
        #expect(service.deletedZones == ["zone-1"])
        let calls = service.trackCalls
        await poll(3)
        #expect(service.trackCalls == calls)
        // A session dropped for another (a new output) leaves the zone's downloads alone.
        let other = try await self.session(service)
        other.shutdown()
        await poll(1)
        #expect(service.deletedZones == ["zone-1"])
    }

    // MARK: Playing

    @Test func aReadyLinkPlaysWithItsAudio() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let engine = FakeEngine()
        let session = try await session(service, engine: engine)
        try await session.play()
        try await queueLink(session)
        await eventually { engine.staged?.id == "link:L1" }
        #expect(engine.staged?.id == "link:L1")
        #expect(engine.staged?.link?.audioURL != nil)
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "link:L1")
        #expect(engine.playing?.link?.isPlayable == true)
    }

    /// Still downloading at its turn, the first time: after a short wait, the next song plays
    /// and the link goes right after it.
    @Test func aLinkStillDownloadingAtItsTurnLetsTheNextSongGoFirst() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 5)])
        let engine = FakeEngine()
        let session = try await session(service, engine: engine)
        try await session.play()
        try await queueLink(session)
        engine.finishTrack()
        await eventually { engine.playing?.id == "b" }
        #expect(session.state.current?.track.id == "b")
        #expect(engine.playing?.id == "b")
        #expect(session.state.upNext.first?.track.id == "link:L1")
        #expect(session.state.history.map(\.track.id) == ["a"])
        #expect(session.playerIssue == nil)

        // Ready by the time "b" ends: it plays.
        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        await eventually { engine.staged?.id == "link:L1" }
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "link:L1")
        #expect(engine.playing?.id == "link:L1")
    }

    /// Put back once already, and still downloading at its turn again: it's skipped.
    @Test func aLinkPutBackOnceIsSkippedTheSecondTime() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 5)])
        let engine = FakeEngine()
        let session = try await session(service, engine: engine)
        try await session.play()
        try await queueLink(session)
        engine.finishTrack()
        await eventually { engine.playing?.id == "b" }
        #expect(session.state.current?.track.id == "b")
        engine.finishTrack()
        await eventually { engine.playing?.id == "c" }
        #expect(session.state.current?.track.id == "c")
        #expect(engine.playing?.id == "c")
        #expect(!session.state.upNext.contains { $0.track.link != nil })
        #expect(session.playerIssue == "Skipped “Song”, which couldn't play")
    }

    /// Nothing else to play: the music waits on it, and starts it as soon as it's ready.
    @Test func withNothingElseItWaitsForTheDownload() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 5)])
        let engine = FakeEngine()
        engine.playsLinks = true
        let session = PartySession(catalog: StubCatalog(ids: []), engine: engine)
        session.linkPollInterval = .milliseconds(10)
        session.linkWaitAtTurn = 0.2
        session.linkZone = "zone-1"
        session.linkService = service
        try await queueLink(session)
        try await session.play()
        await settle()
        #expect(session.state.current?.track.id == "link:L1")
        #expect(engine.playing == nil)
        #expect(!session.isPlaying)
        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        await eventually { engine.playing?.id == "link:L1" }
        #expect(engine.playing?.id == "link:L1")
        #expect(session.isPlaying)
    }

    /// The link waited for fails: it goes, and doesn't count as played.
    @Test func aLinkWaitedForThatFailsGivesWay() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 5)])
        let engine = FakeEngine()
        engine.playsLinks = true
        let session = PartySession(catalog: StubCatalog(ids: []), engine: engine)
        session.linkPollInterval = .milliseconds(10)
        session.linkWaitAtTurn = 0.2
        session.linkZone = "zone-1"
        session.linkService = service
        try await queueLink(session)
        try await session.play()
        await settle()
        session.add(track("x"), by: guest)
        service.steps["L1"] = [FakeLinkService.track("L1", status: .failed, error: "Removed")]
        await eventually { engine.playing?.id == "x" }
        #expect(session.state.current?.track.id == "x")
        #expect(engine.playing?.id == "x")
        #expect(session.state.history.isEmpty)
        #expect(session.partyLog.songs.map(\.track.id) == ["x"])
    }
}
