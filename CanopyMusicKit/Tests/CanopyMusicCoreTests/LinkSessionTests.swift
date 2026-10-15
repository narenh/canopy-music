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
    private(set) var resolveCalls: [(url: String, zone: String, normalize: Bool)] = []
    private(set) var trackCalls = 0
    private(set) var deletedZones: [String] = []

    /// A pending track for `link`, then `steps` (say, 30%, 80%, ready).
    func add(_ link: String, id: String, title: String = "Song", steps: [CmdlpTrack]) {
        tracks[link] = Self.track(id, title: title, status: .pending)
        self.steps[id] = steps
    }

    static func track(_ id: String, title: String = "Song", zone: String = "zone-1", status: LinkTrack.Status, percent: Double? = nil,
                      eta: Double? = nil, error: String? = nil) -> CmdlpTrack {
        CmdlpTrack(id: id, zone: zone, status: status, title: title, artist: "Artist", duration: 200, artwork: "https://art.example/\(id).jpg",
                   service: "YouTube", stage: status == .pending ? "downloading" : nil,
                   progress: percent == nil && eta == nil ? nil : .init(percent: percent, eta: eta),
                   audioUrl: "https://cmdlp.example/audio/\(id).m4a?sig=secret-\(id)", error: error)
    }

    func resolve(_ url: String, zone: String, normalize: Bool) async throws -> CmdlpTrack {
        resolveCalls.append((url, zone, normalize))
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

/// Links on the hub: looked up for a phone; added, prepared while they download (only the phones
/// that added them see how it's going), and queued as the guest's request only once they're
/// ready; failures told only to those phones; preparations kept across a relaunch; the zone's
/// downloads deleted when it ends.
@MainActor
@Suite struct LinkSessionTests {
    let guest = Requester(name: "Sam", clientID: "phone-1", origin: .phone)
    let other = Requester(name: "Kim", clientID: "phone-2", origin: .phone)
    static let youtube = "https://www.youtube.com/watch?v=abc"
    static let soundcloud = "https://soundcloud.com/forss/flickermood"

    func session(_ service: FakeLinkService, engine: FakeEngine = FakeEngine(), ids: [String] = ["a", "b", "c"],
                 storeURL: URL? = nil) async throws -> PartySession {
        engine.playsLinks = true
        let session = PartySession(catalog: StubCatalog(ids: ids), engine: engine, storeURL: storeURL)
        session.landingDelay = 0.05
        session.linkPollInterval = .milliseconds(10)
        session.linkZone = "zone-1"
        session.linkService = service
        try await session.load(playlist: base)
        return session
    }

    /// A guest pastes the YouTube link and adds it.
    @discardableResult
    func addLink(_ session: PartySession, by requester: Requester? = nil, link: String = LinkSessionTests.youtube) async throws -> LinkAddResult {
        let result = try await session.addLink(try #require(try await session.resolveLink(link)), by: requester ?? guest)
        await settle()
        return result
    }

    func linkItem(_ session: PartySession) -> QueueItem? { session.state.upNext.first { $0.track.link != nil } }

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
        #expect(service.resolveCalls.map(\.normalize) == [true])
    }

    /// "Normalize audio" off: lookups ask for the link as it is. A lookup kept from before the
    /// change isn't joined, since cmdlp makes that a track of its own.
    @Test func lookupsCarryTheHubsNormalizeSetting() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        let session = try await session(service)
        #expect(session.linkNormalize)
        _ = try await session.resolveLink(Self.youtube)
        _ = try await session.resolveLink(Self.youtube)
        session.linkNormalize = false
        _ = try await session.resolveLink(Self.youtube)
        _ = try await session.resolveLink(Self.youtube)
        #expect(service.resolveCalls.map(\.normalize) == [true, false])
        #expect(service.resolveCalls.map(\.url) == [Self.youtube, Self.youtube])
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

    // MARK: Preparing

    /// Added while it downloads: it isn't in Up Next (nor any snapshot) until it's ready, only
    /// the phone that added it sees "Preparing… N%", and then it's queued as that guest's
    /// request, with the hub's audio address (never the phone's).
    @Test func aLinkJoinsUpNextOnlyOnceReady() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [
            FakeLinkService.track("L1", status: .pending, percent: 30),
            FakeLinkService.track("L1", status: .pending, percent: 80),
            FakeLinkService.track("L1", status: .ready),
        ])
        let session = try await session(service)
        // Each check made here, one at a time.
        session.linkPollInterval = .seconds(3600)
        var picked = try #require(try await session.resolveLink(Self.youtube))
        picked.link?.audioURL = URL(string: "https://evil.example/x.m4a")
        let itemID = UUID()
        let added = try await session.addLink(picked, by: guest, id: itemID)
        #expect(added == .preparing(LinkProgress(id: "link:L1", title: "Song", percent: 30, takesLong: false)))
        #expect(linkItem(session) == nil)
        #expect(session.snapshot().current?.track.link == nil)
        #expect(!String(decoding: try JSONEncoder().encode(session.snapshot()), as: UTF8.self).contains("link:L1"))

        #expect(await session.pollLink("L1"))
        #expect(session.linkProgress(for: "phone-1").preparing.map(\.percent) == [80])
        // Nobody else sees it.
        #expect(session.linkProgress(for: "phone-2") == LinkProgressReply(preparing: [], failed: []))
        #expect(linkItem(session) == nil)

        // Ready: queued, and nothing more to ask.
        #expect(await !session.pollLink("L1"))
        let item = try #require(linkItem(session))
        #expect(item.id == itemID)
        #expect(item.requester == guest)
        #expect(item.track.artworkURL?.absoluteString == "https://art.example/L1.jpg")
        #expect(item.track.link?.isPlayable == true)
        #expect(item.track.link?.audioURL?.absoluteString == "https://cmdlp.example/audio/L1.m4a?sig=secret-L1")
        #expect(session.linkProgress(for: "phone-1") == LinkProgressReply(preparing: [], failed: []))
    }

    /// cmdlp already has it (a link pasted before): queued at once, with nothing to prepare.
    @Test func anAlreadyDownloadedLinkQueuesAtOnce() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        guard case .queued(.added(let item, let index)) = try await addLink(session) else {
            Issue.record("not queued")
            return
        }
        #expect(index == 0)
        #expect(item.requester == guest)
        #expect(linkItem(session)?.id == item.id)
        #expect(session.linkPreparations.isEmpty)
        #expect(session.linkPolls.isEmpty)
    }

    /// The same link added again while it's being prepared (the same address or another for the
    /// same song: cmdlp gives both one id), by this guest or another: one preparation, which the
    /// second phone follows too, queued once, as the first guest's request.
    @Test func theSameLinkTwiceIsPreparedOnce() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        service.tracks["https://youtu.be/abc"] = service.tracks[Self.youtube]
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        guard case .preparing = try await addLink(session) else { Issue.record("not preparing"); return }
        guard case .preparing(let second) = try await addLink(session, by: other, link: "https://youtu.be/abc") else {
            Issue.record("not preparing for the second phone")
            return
        }
        guard case .preparing = try await addLink(session) else { Issue.record("not preparing again"); return }
        #expect(second.id == "link:L1")
        #expect(session.linkPreparations.count == 1)
        #expect(session.linkPolls.count == 1)
        #expect(session.linkPreparations["L1"]?.clients == ["phone-1", "phone-2"])
        #expect(session.linkProgress(for: "phone-2").preparing.map(\.id) == ["link:L1"])

        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        #expect(await !session.pollLink("L1"))
        #expect(session.state.upNext.filter { $0.track.link != nil }.map(\.requester) == [guest])
        // Added once it's queued: it's already there.
        guard case .queued(.alreadyQueued) = try await addLink(session, by: other) else { Issue.record("queued twice"); return }
    }

    /// Picked after the hub relaunched (it has no record of the lookup): cmdlp still has it.
    @Test func aPickTheHubDoesntKnowIsFetched() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        let picked = FakeLinkService.track("L1", status: .pending).queueTrack.forGuests
        guard case .queued(.added) = try await session.addLink(picked, by: guest) else { Issue.record("not queued"); return }
        #expect(linkItem(session)?.track.link?.audioURL != nil)
        // Not another zone's download.
        service.steps["L2"] = [FakeLinkService.track("L2", zone: "other-zone", status: .ready)]
        await #expect(throws: LinkRefusal.unavailable) {
            try await session.addLink(FakeLinkService.track("L2", status: .ready).queueTrack.forGuests, by: guest)
        }
    }

    /// A download that fails never touches Up Next or anyone else's screen: each phone that
    /// added it is told once, in plain words (cmdlp's reason stays in the log).
    @Test func aFailedPreparationIsToldOnlyToItsPhones() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Gone", steps: [
            FakeLinkService.track("L1", title: "Gone", status: .pending, percent: 20),
            FakeLinkService.track("L1", title: "Gone", status: .failed, error: "ERROR: [youtube] abc: Video unavailable"),
        ])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        let upNext = session.state.upNext
        try await addLink(session)
        try await addLink(session, by: other)
        #expect(await !session.pollLink("L1"))
        #expect(session.state.upNext == upNext)
        #expect(session.playerIssue == nil)
        let failure = LinkFailure(id: "link:L1", text: "Couldn’t add “Gone”")
        #expect(session.linkProgress(for: "phone-1") == LinkProgressReply(preparing: [], failed: [failure]))
        // Once.
        #expect(session.linkProgress(for: "phone-1").failed.isEmpty)
        #expect(session.linkProgress(for: "phone-2").failed == [failure])
        #expect(session.linkProgress(for: "phone-3").failed.isEmpty)
    }

    /// cmdlp lost it (its zone swept, say): as a failure.
    @Test func aDownloadCmdlpLostFails() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Lost", steps: [])
        let session = try await session(service)
        try await addLink(session)
        service.trackError = CmdlpError(status: 404, reason: "not_found")
        await eventually { session.linkPreparations.isEmpty }
        #expect(linkItem(session) == nil)
        #expect(session.linkProgress(for: "phone-1").failed.map(\.text) == ["Couldn’t add “Lost”"])
    }

    /// cmdlp not answering for a moment isn't a failure: it's asked again.
    @Test func cmdlpNotAnsweringIsntAFailure() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [
            FakeLinkService.track("L1", status: .pending, percent: 10),
            FakeLinkService.track("L1", status: .ready),
        ])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        try await addLink(session)
        service.trackError = URLError(.timedOut)
        #expect(await session.pollLink("L1"))
        #expect(session.linkPreparations["L1"] != nil)
        service.trackError = nil
        #expect(await !session.pollLink("L1"))
        #expect(linkItem(session)?.track.link?.isPlayable == true)
    }

    /// "Your song will queue automatically…" once it's expected to take more than 15 seconds:
    /// yt-dlp's ETA says so here.
    @Test func aSlowPreparationSaysSo() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 5, eta: 40)])
        service.add(Self.soundcloud, id: "L2", steps: [FakeLinkService.track("L2", status: .pending, percent: 50, eta: 3)])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        guard case .preparing(let slow) = try await addLink(session),
              case .preparing(let quick) = try await addLink(session, link: Self.soundcloud) else {
            Issue.record("not preparing")
            return
        }
        #expect(slow.takesLong)
        #expect(slow.percent == 5)
        #expect(!quick.takesLong)
        // It stays said, whatever the ETA says next.
        service.steps["L1"] = [FakeLinkService.track("L1", status: .pending, percent: 90, eta: 1)]
        #expect(await session.pollLink("L1"))
        #expect(session.linkProgress(for: "phone-1").preparing.first { $0.id == "link:L1" }?.takesLong == true)
    }

    /// The phone's "Preparing… N%" is cmdlp's overall figure, never going back and at most 99
    /// until the link is queued.
    @Test func thePreparingFigureOnlyGoesUp() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 60)])
        let session = try await session(service)
        session.linkPollInterval = .seconds(3600)
        guard case .preparing(let added) = try await addLink(session) else { Issue.record("not preparing"); return }
        #expect(added.percent == 60)
        func percent() -> Int? { session.linkProgress(for: "phone-1").preparing.first?.percent }
        for (next, shown) in [(45.0, 60), (82, 82), (100, 99)] as [(Double, Int)] {
            service.steps["L1"] = [FakeLinkService.track("L1", status: .pending, percent: next)]
            #expect(await session.pollLink("L1"))
            #expect(percent() == shown)
        }
        service.steps["L1"] = [FakeLinkService.track("L1", status: .pending)]
        #expect(await session.pollLink("L1"))
        #expect(percent() == 99)
    }

    /// Ready after the zone moved to a player that can't play links: not queued, and the guest
    /// is told.
    @Test func readyWhereLinksCantPlayIsAFailure() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Late", steps: [FakeLinkService.track("L1", title: "Late", status: .pending, percent: 10)])
        let engine = FakeEngine()
        let session = try await session(service, engine: engine)
        session.linkPollInterval = .seconds(3600)
        try await addLink(session)
        engine.playsLinks = false
        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        #expect(await !session.pollLink("L1"))
        #expect(linkItem(session) == nil)
        #expect(session.linkProgress(for: "phone-1").failed.map(\.text) == ["Couldn’t add “Late”"])
    }

    // MARK: Relaunch

    /// The hub relaunched while links were being prepared (cmdlp's downloads carried on): the
    /// new session picks them up, queues each as its guest's request once ready, and still tells
    /// a phone about a failure it hadn't heard of.
    @Test func preparationsSurviveARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "link-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "queue.json")
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", title: "Keeps", steps: [FakeLinkService.track("L1", status: .pending, percent: 10)])
        service.add(Self.soundcloud, id: "L2", title: "Breaks", steps: [FakeLinkService.track("L2", title: "Breaks", status: .pending, percent: 10)])
        let first = try await session(service, storeURL: store)
        first.linkPollInterval = .seconds(3600)
        try await addLink(first)
        try await addLink(first, by: other, link: Self.soundcloud)
        service.steps["L2"] = [FakeLinkService.track("L2", status: .failed, error: "ERROR: gone")]
        #expect(await !first.pollLink("L2"))
        first.shutdown()

        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        let engine = FakeEngine()
        engine.playsLinks = true
        let relaunched = PartySession(catalog: StubCatalog(ids: ["a", "b", "c"]), engine: engine, storeURL: store)
        relaunched.linkPollInterval = .milliseconds(10)
        relaunched.linkZone = "zone-1"
        #expect(relaunched.linkPreparations["L1"]?.requester == guest)
        relaunched.linkService = service
        await eventually { linkItem(relaunched) != nil }
        #expect(linkItem(relaunched)?.requester == guest)
        #expect(relaunched.linkProgress(for: "phone-2").failed.map(\.text) == ["Couldn’t add “Breaks”"])

        // Ending the zone forgets them, file and all.
        relaunched.end()
        #expect(!FileManager.default.fileExists(atPath: PartySession.linkPreparationsURL(beside: store).path()))
    }

    // MARK: Zone end

    @Test func endingTheZoneDeletesItsDownloads() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [])
        let session = try await session(service)
        try await addLink(session)
        session.end()
        #expect(session.linkPreparations.isEmpty)
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
        try await addLink(session)
        await eventually { engine.staged?.id == "link:L1" }
        #expect(engine.staged?.id == "link:L1")
        #expect(engine.staged?.link?.audioURL != nil)
        engine.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "link:L1")
        #expect(engine.playing?.link?.isPlayable == true)
    }

    /// Snapshots (phones, displays, hosts) never carry a link's signed audio address.
    @Test func snapshotsNeverCarryTheAudioAddress() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .ready)])
        let session = try await session(service)
        session.hostKey = "host"
        try await session.play()
        try await addLink(session)
        #expect(linkItem(session)?.track.link?.audioURL != nil)
        for snapshot in [session.snapshot(), session.snapshot(includingWifi: true), session.snapshot(hostKey: "host")] {
            let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            #expect(text.contains("link:L1"))
            #expect(!text.contains("secret-L1"))
            #expect(!text.contains("/audio/"))
        }
    }

    /// On Sonos the same: prepared, then queued, and staged into the group's queue as its audio.
    @Test func onSonosItQueuesWhenReadyToo() async throws {
        let service = FakeLinkService()
        service.add(Self.youtube, id: "L1", steps: [FakeLinkService.track("L1", status: .pending, percent: 40)])
        let fake = FakeSonos()
        let engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        let session = PartySession(catalog: SonosLinkCatalog(ids: ["a", "b"]), engine: engine)
        session.linkPollInterval = .seconds(3600)
        session.linkZone = "zone-1"
        session.linkService = service
        try await session.load(playlist: base)
        try await session.play()
        await eventually { fake.queue.count == 2 }
        #expect(fake.queue == [sonosURI("a"), sonosURI("b")])
        guard case .preparing = try await addLink(session) else { Issue.record("not preparing"); return }
        #expect(fake.queue == [sonosURI("a"), sonosURI("b")])
        service.steps["L1"] = [FakeLinkService.track("L1", status: .ready)]
        #expect(await !session.pollLink("L1"))
        await eventually { fake.queue.contains("https://cmdlp.example/audio/L1.m4a?sig=secret-L1") }
        #expect(fake.queue == [sonosURI("a"), "https://cmdlp.example/audio/L1.m4a?sig=secret-L1"])
        #expect(session.state.upNext.first?.requester == guest)
    }
}

/// A playlist of Spotify songs, for a session on Sonos.
struct SonosLinkCatalog: MusicCatalog {
    var ids: [String]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { ids.map(spotifyTrack) }
}
