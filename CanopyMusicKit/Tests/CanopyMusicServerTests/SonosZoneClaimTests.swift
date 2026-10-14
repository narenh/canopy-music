@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// Two Canopy Music zones on one Sonos household: each hub says which rooms its zone plays on
/// (`GET /api/zone`, `sonos`), the other's lists say "In use by …" instead of ticking them,
/// "Use" takes them over, and the zone that loses them stops there without fighting back. On
/// the simulated household, with an "iPad" hub playing Apple Music and a "TV" hub being set up.
@MainActor
@Suite(.serialized) struct SonosZoneClaimTests {
    static let bedroom = "RINCON_BEAM", move = "RINCON_MOVE", kitchen = "RINCON_ONE"
    static let hosts = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]

    let sim = SonosSimulator(rooms: [
        .init(id: bedroom, name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
        .init(id: move, name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
        .init(id: kitchen, name: "Kitchen", model: "One", host: "10.0.0.3", volume: 20),
    ])

    /// The iPad's zone, as another hub sees it on the network.
    static let iPadZone = ZoneListing(id: "Living Room iPad", name: "Living Room iPad", kind: .ipad, address: "10.0.0.50:8080")

    /// A controller on the simulated household once it has been read. `claims`: what other
    /// zones answer at `GET /api/zone` (as the iPad's zone, `iPadZone`).
    func makeController(service: SonosMusicService, defaults: UserDefaults? = nil,
                        claims: (@MainActor () -> SonosZoneClaim?)? = nil) async -> SonosOutputController {
        let household = SonosHousehold(transport: sim, fixedHosts: Self.hosts)
        let exchange = SonosClaimExchange(timeout: .seconds(1)) { _ in
            let claim = await MainActor.run { claims?() }
            return (try JSONEncoder().encode(ZoneCheck(hub: nil, spotify: nil, sonos: claim)), 200)
        }
        let controller = SonosOutputController(household: household, defaults: defaults ?? Self.freshDefaults(), claimExchange: exchange)
        controller.service = service
        if claims != nil { controller.peers = { [Self.iPadZone] } }
        household.onRefresh = { [weak controller] in controller?.householdRefreshed() }
        household.start()
        for _ in 0..<200 where household.players.count < 3 || household.isRefreshing {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.readRooms()
        return controller
    }

    static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SonosZoneClaimTests-\(UUID().uuidString)")!
    }

    /// The iPad's zone: Apple Music, playing in `rooms` (Bedroom leading).
    func iPadPlaying(_ rooms: [String] = [bedroom, move]) async throws -> (SonosOutputController, PartySession) {
        let controller = await makeController(service: .appleMusic)
        controller.select(rooms: rooms)
        let engine = try #require(controller.makeEngine())
        engine.pollInterval = (.milliseconds(50), .milliseconds(50))
        let session = PartySession(catalog: SonosFakeCatalog(), engine: engine)
        session.configureHub(kind: .ipad, id: "ipad-hub", zoneName: "Living Room iPad", serviceName: "Apple Music")
        controller.connect(session)
        session.sonosHandler = controller
        let playlist = try #require(try await SonosFakeCatalog().libraryPlaylists().first)
        try await session.load(playlist: playlist)
        try await session.play()
        #expect(await waitFor { sim.state(of: rooms[0]) == .playing })
        return (controller, session)
    }

    /// The TV, setting up a Spotify zone: told of the iPad's zone, its engine rebuilt as the TV
    /// does (`replaceService` under one session).
    func tvSettingUp(_ iPad: SonosOutputController, defaults: UserDefaults? = nil) async throws -> (SonosOutputController, PartySession) {
        let tv = await makeController(service: .spotify, defaults: defaults, claims: { iPad.sonosClaim() })
        let session = PartySession(catalog: SonosFakeCatalog(service: .spotify), engine: tv.makeEngine() ?? DemoPlaybackEngine())
        session.configureHub(kind: .tv, id: "tv-hub", zoneName: "Den", serviceName: "Spotify")
        tv.canChangeOutput = { session.isWaitingForSetup }
        tv.isSettingUp = { session.isWaitingForSetup }
        tv.onOutputChanged = { [weak tv] in
            guard let tv else { return }
            let engine: any PlaybackEngine = tv.makeEngine() ?? DemoPlaybackEngine()
            (engine as? SonosEngine)?.pollInterval = (.milliseconds(50), .milliseconds(50))
            let old = session.engine
            guard session.replaceService(catalog: SonosFakeCatalog(service: .spotify), engine: engine, serviceName: "Spotify") else { return }
            old.shutDown()
            tv.connect(session)
        }
        (session.engine as? SonosEngine)?.pollInterval = (.milliseconds(50), .milliseconds(50))
        tv.connect(session)
        session.sonosHandler = tv
        // A new zone: the kept choice is checked against the other zones now.
        tv.beginSetup()
        await tv.readRooms()
        return (tv, session)
    }

    /// The TV presses "Start the music".
    func start(_ session: PartySession) async throws {
        let playlist = try #require(try await SonosFakeCatalog(service: .spotify).libraryPlaylists().first)
        try await session.load(playlist: playlist)
        try await session.play()
    }

    func waitFor(_ condition: @MainActor () -> Bool, timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func room(_ setup: SonosSetup?, _ id: String) -> SonosSetup.Room? {
        setup?.rooms.first { $0.id == id }
    }

    // MARK: Publishing

    @Test func aHubSaysWhichRoomsItsZonePlaysOn() async throws {
        let port: UInt16 = 18881
        let (iPad, session) = try await iPadPlaying()
        defer { session.shutdown() }
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        defer { task.cancel(); Task { await server.stop() } }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/zone"))
        var (data, _) = try await URLSession.shared.data(from: url)
        var check = try JSONDecoder().decode(ZoneCheck.self, from: data)
        #expect(check.hub == "ipad-hub")
        #expect(check.sonos == SonosZoneClaim(zone: "Living Room iPad", service: "Apple Music", household: "Sonos_Simulated",
                                              rooms: [Self.bedroom, Self.move]))

        // Another hub reads it the same way, through the exchange.
        let zone = ZoneListing(id: "x", name: "Announced Name", kind: .ipad, address: "127.0.0.1:\(port)", hubID: "ipad-hub")
        let answers = await SonosClaimExchange().ask([zone])
        #expect(answers.count == 1 && answers.first?.claim?.rooms == [Self.bedroom, Self.move])
        // An announcement whose address another hub answers at now says nothing.
        let stale = ZoneListing(id: "y", name: "Gone", kind: .ipad, address: "127.0.0.1:\(port)", hubID: "another-hub")
        #expect(await SonosClaimExchange().ask([stale]).isEmpty)

        // Off Sonos: nothing claimed.
        iPad.leave()
        session.sonosHandler = nil
        (data, _) = try await URLSession.shared.data(from: url)
        check = try JSONDecoder().decode(ZoneCheck.self, from: data)
        #expect(check.sonos == nil)
        #expect(check.hub == "ipad-hub")
    }

    // MARK: Seeing them

    @Test func roomsAnotherZonePlaysOnReadInUse() async throws {
        let (iPad, session) = try await iPadPlaying()
        defer { session.shutdown() }
        let tv = await makeController(service: .spotify, claims: { iPad.sonosClaim() })
        let setup = try #require(tv.setup())
        for id in [Self.bedroom, Self.move] {
            let row = try #require(room(setup, id))
            #expect(row.status == "In use by Living Room iPad (Apple Music)")
            #expect(row.state == "inUse")
            #expect(!row.ticked && !row.canTick)
            #expect(row.inUse == SonosSetup.InUse(zone: "Living Room iPad", service: "Apple Music", together: [Self.bedroom, Self.move]))
        }
        // The free room ticks as before.
        #expect(room(setup, Self.kitchen)?.state == "idle" && room(setup, Self.kitchen)?.canTick == true)
        // Not ticked by a tap: "Use" asks first.
        tv.canChangeOutput = { true }
        #expect(!tv.setSonosRoom(Self.move, on: true))
        #expect(tv.output == nil)

        // The iPad's own lists don't say its rooms are in use (even told of itself).
        iPad.standingClaims = [try #require(iPad.sonosClaim())]
        #expect(room(iPad.setup(), Self.bedroom)?.status == "Playing Canopy Music")
        #expect(room(iPad.setup(), Self.bedroom)?.inUse == nil)
    }

    @Test func anotherHubsSongsWithNoClaimReadAsBusy() async throws {
        let (_, session) = try await iPadPlaying()
        defer { session.shutdown() }
        // Nobody says they play there (an older hub, or one that doesn't answer).
        let tv = await makeController(service: .spotify)
        let setup = try #require(tv.setup())
        #expect(room(setup, Self.bedroom)?.state == "busy")
        #expect(room(setup, Self.bedroom)?.status.hasPrefix("Playing ") == true)
        #expect(room(setup, Self.bedroom)?.inUse == nil)
    }

    @Test func aClaimTheLiveLayoutDoesntBearOutDoesntCount() async throws {
        let tv = await makeController(service: .spotify)
        // A zone says it plays on Bedroom + Move, but Move has since been put in Kitchen's group
        // (the Sonos app): Kitchen isn't that zone's, so Move isn't either now.
        sim.group([Self.kitchen, Self.move])
        await tv.household.refreshNow()
        tv.standingClaims = [SonosZoneClaim(zone: "Upstairs", service: "Spotify", rooms: [Self.bedroom, Self.move])]
        #expect(tv.claim(on: Self.bedroom)?.zone == "Upstairs")
        #expect(tv.claim(on: Self.move) == nil)
        #expect(tv.takenTogether(with: Self.bedroom) == [Self.bedroom])
        // Another household's claim doesn't count here.
        tv.standingClaims = [SonosZoneClaim(zone: "Next Door", service: "Spotify", household: "Sonos_Elsewhere", rooms: [Self.bedroom])]
        #expect(tv.claim(on: Self.bedroom) == nil)
    }

    // MARK: The bug: rooms kept from before, now another zone's

    /// Seen on real devices: the iPad's Apple Music zone played on Bedroom + Move; on the TV, a
    /// new Spotify zone's setup page showed both ticked (the TV's choice kept from an earlier
    /// zone, `sonosOutput`), and getting to a Spotify device meant unticking them one by one.
    @Test func roomsAnotherZoneHasAreNeverPreChosen() async throws {
        let (iPad, session) = try await iPadPlaying()
        defer { session.shutdown() }
        let defaults = Self.freshDefaults()
        let kept = SonosOutput(target: SonosTarget(coordinator: .init(id: Self.bedroom, name: "Bedroom", host: "10.0.0.1"),
                                                   joining: [.init(id: Self.move, name: "Move", host: "10.0.0.2")]))
        defaults.set(try JSONEncoder().encode(kept), forKey: SonosOutputController.outputKey)
        let (tv, tvSession) = try await tvSettingUp(iPad, defaults: defaults)
        let setup = try #require(tv.setup())
        #expect(setup.chosen.isEmpty)
        #expect(setup.rooms.allSatisfy { !$0.ticked })
        #expect(room(setup, Self.bedroom)?.state == "inUse" && room(setup, Self.move)?.state == "inUse")
        // So the TV's own output is where the music plays (a Spotify device), with nothing to untick.
        #expect(tv.output == nil)
        #expect(!(tvSession.engine is SonosEngine))
        // The iPad's zone wasn't touched.
        #expect(sim.state(of: Self.bedroom) == .playing)
        #expect(iPad.engine?.hasLostControl == false)

        // A kept choice with a free room keeps that one.
        let mixed = SonosOutput(target: SonosTarget(coordinator: .init(id: Self.kitchen, name: "Kitchen", host: "10.0.0.3"),
                                                    joining: [.init(id: Self.move, name: "Move", host: "10.0.0.2")]))
        let other = Self.freshDefaults()
        other.set(try JSONEncoder().encode(mixed), forKey: SonosOutputController.outputKey)
        let (tv2, _) = try await tvSettingUp(iPad, defaults: other)
        #expect(tv2.output?.roomIDs == [Self.kitchen])
    }

    /// The segmented switch on the setup page: Sonos ⇄ the Spotify device (or This Apple TV).
    /// Switching away is one call that lets go of the rooms; switching back shows the rooms with
    /// none chosen (the page's own state), and ticking keeps the account chosen before.
    @Test func switchingAwayFromSonosIsOneStep() async throws {
        let port: UInt16 = 18882
        sim.accounts = [(SonosMusicService.spotify.serviceID, 4), (SonosMusicService.spotify.serviceID, 7)]
        let tv = await makeController(service: .spotify)
        let session = PartySession(catalog: SonosFakeCatalog(service: .spotify), engine: DemoPlaybackEngine())
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Spotify")
        session.hostKey = "secret"
        session.sonosHandler = tv
        tv.canChangeOutput = { session.isWaitingForSetup }
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        defer { task.cancel(); Task { await server.stop() } }

        #expect(tv.setSonosRoom(Self.bedroom, on: true))
        #expect(tv.setSonosRoom(Self.move, on: true))
        let second = try #require(tv.accounts.last)
        #expect(tv.chooseSonosAccount(second.id))
        // Spotify device: one call, both rooms let go.
        #expect(try await post(port, "/api/host/sonos/off", ["key": "secret"]) == 204)
        #expect(tv.output == nil)
        #expect(tv.setup()?.chosen.isEmpty == true)
        #expect(tv.setup()?.rooms.allSatisfy { !$0.ticked } == true)
        // Back to Sonos and a tick: the account chosen before still plays.
        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.kitchen, "on": true]) == 204)
        #expect(tv.output?.roomIDs == [Self.kitchen])
        #expect(tv.account?.id == second.id)
        // Once the zone runs, the switch can't move it (today's rules).
        session.add(DemoCatalog.track(3), by: Requester(origin: .phone))
        #expect(!session.isWaitingForSetup)
        #expect(try await post(port, "/api/host/sonos/off", ["key": "secret"]) == 409)
        #expect(tv.output?.roomIDs == [Self.kitchen])
    }

    // MARK: Taking over

    @Test func useTakesTheRoomsAndTheFirstPlayGroupsThem() async throws {
        let port: UInt16 = 18883
        let (iPad, iPadSession) = try await iPadPlaying()
        defer { iPadSession.shutdown() }
        let (tv, tvSession) = try await tvSettingUp(iPad)
        defer { tvSession.shutdown() }
        tvSession.hostKey = "secret"
        let (server, task) = try #require(await PartyServer.start(session: tvSession, ports: [port]))
        defer { task.cancel(); Task { await server.stop() } }

        // Kitchen ticked first, then "Use Both Rooms".
        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.kitchen, "on": true]) == 204)
        #expect(try await post(port, "/api/host/sonos/use", ["key": "nope", "ids": [Self.bedroom, Self.move]]) == 403)
        #expect(try await post(port, "/api/host/sonos/use", ["key": "secret"]) == 400)
        #expect(try await post(port, "/api/host/sonos/use", ["key": "secret", "ids": [Self.bedroom, Self.move]]) == 204)
        #expect(tv.output?.roomIDs == [Self.kitchen, Self.bedroom, Self.move])
        #expect(tv.takenOver == [Self.bedroom, Self.move])
        // Still the iPad's until the music starts here: ticked, and saying whose they are.
        await tv.readRooms()
        let setup = try #require(tv.setup())
        #expect(room(setup, Self.bedroom)?.ticked == true && room(setup, Self.bedroom)?.state == "inUse")
        #expect(setup.ready)
        // Nothing sent yet: the iPad plays on.
        #expect(sim.state(of: Self.bedroom) == .playing)
        #expect(sim.topology.contains([Self.bedroom, Self.move]))

        // Start: the grouping plan takes them (Bedroom already leads Move, so it leads; Kitchen joins).
        try await start(tvSession)
        #expect(await waitFor { sim.topology.contains { Set($0) == [Self.bedroom, Self.move, Self.kitchen] } })
        #expect(sim.queue(of: Self.bedroom).first?.contains("spotify") == true)
        #expect(await waitFor { iPad.engine?.hasLostControl == true })
        // The rooms are the TV's now: its lists say so, and the iPad no longer claims them.
        await tv.readRooms()
        #expect(room(tv.setup(), Self.bedroom)?.status == "Playing Canopy Music")
        #expect(iPad.sonosClaim() == nil)
        #expect(tv.sonosClaim()?.rooms.sorted() == [Self.bedroom, Self.kitchen, Self.move].sorted())
    }

    @Test func justOneRoomOfAGroupLeavesTheOtherPlaying() async throws {
        let (iPad, iPadSession) = try await iPadPlaying()
        defer { iPadSession.shutdown() }
        let (tv, tvSession) = try await tvSettingUp(iPad)
        defer { tvSession.shutdown() }
        // "Just Move" (a member of Bedroom's group).
        #expect(tv.useSonosRooms([Self.move]))
        #expect(tv.output?.roomIDs == [Self.move])
        try await start(tvSession)
        #expect(await waitFor { sim.topology.contains([Self.move]) && sim.topology.contains([Self.bedroom]) })
        #expect(sim.queue(of: Self.move).first?.contains("spotify") == true)
        // Bedroom plays the iPad's zone on; its engine still has it.
        #expect(sim.state(of: Self.bedroom) == .playing)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(iPad.engine?.hasLostControl == false)
        #expect(iPadSession.isPlaying)
    }

    // MARK: The zone that lost them

    @Test func theZoneThatLostItsRoomsDoesntFightBack() async throws {
        let (iPad, iPadSession) = try await iPadPlaying()
        defer { iPadSession.shutdown() }
        let iPadEngine = try #require(iPad.engine)
        let (tv, tvSession) = try await tvSettingUp(iPad)
        defer { tvSession.shutdown() }
        #expect(tv.useSonosRooms([Self.bedroom, Self.move]))
        try await start(tvSession)
        let tvSong = try #require(sim.queue(of: Self.bedroom).first)
        #expect(tvSong.contains("spotify"))

        // The iPad sees another source: paused, not playing its next song over the TV's.
        #expect(await waitFor { iPadEngine.hasLostControl && !iPadSession.isPlaying })
        let iPadCurrent = iPadSession.state.current?.track.id
        // The TV's zone moves on through its queue (further down it than the iPad's song was):
        // still not the iPad's to take back.
        sim.finishTrack(in: Self.bedroom)
        try? await Task.sleep(for: .milliseconds(400))
        // A guest adds a song on the iPad: it isn't put in the TV's queue.
        let catalog = SonosFakeCatalog()
        let other = try #require(try await catalog.libraryPlaylists().last)
        let extra = try #require(try await catalog.tracks(in: other).last)
        _ = iPadSession.add(extra, by: Requester(origin: .phone))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!sim.queue(of: Self.bedroom).contains { $0.contains("song%3a\(extra.id)") })
        #expect(sim.queue(of: Self.bedroom).allSatisfy { $0.contains("spotify") })
        #expect(iPadSession.state.current?.track.id == iPadCurrent)
        #expect(!iPadSession.isPlaying)
        #expect(tvSession.isPlaying)
        // Ticking a room on the lost group sends nothing to the TV's group.
        let before = sim.changes.count
        iPad.remove(Self.move)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(sim.changes.count == before)
        #expect(sim.topology.contains { Set($0) == [Self.bedroom, Self.move] })
        // Its lists say whose the rooms are now, and it claims nothing.
        iPad.standingClaims = [try #require(tv.sonosClaim())]
        #expect(room(iPad.setup(), Self.bedroom)?.state == "inUse")
        #expect(iPad.sonosClaim() == nil)
        // Only Play on the iPad takes them back, as from any other source.
        try await iPadSession.play()
        #expect(await waitFor { sim.queue(of: Self.bedroom).first?.contains("sid=204") == true })
    }
}

extension SonosZoneClaimTests {
    /// The other zone's first play, read between its steps (a real player takes tens of
    /// milliseconds a command, the engine reads about once a second): its song is queued, the
    /// transport stopped, before its Play. That once read as our queue running out, and the
    /// session played its next song over the other zone's.
    @Test func readMidTakeoverItStillDoesntFightBack() async throws {
        let (iPad, iPadSession) = try await iPadPlaying()
        defer { iPadSession.shutdown() }
        let engine = try #require(iPad.engine)
        let current = iPadSession.state.current?.track.id
        // Playing, with its next song staged behind.
        #expect(await waitFor { engine.isPlaying && sim.queue(of: Self.bedroom).count == 2 })
        let other = SonosClient(transport: sim, host: "10.0.0.1")
        try await other.clearQueue()
        let theirs = SonosTrackReference(service: .spotify, accountSerial: 4)
        let track = QueueTrack(id: "spotify:track:2000000077", title: "Theirs", artist: "Someone", album: "", duration: 200)
        _ = try await other.addToQueue(uri: try theirs.uri(for: track.id), metadata: try theirs.metadata(for: track), position: 0, asNext: false)
        try await other.setTransportURI(SonosURI.queue(of: Self.bedroom))
        #expect(sim.state(of: Self.bedroom) == .stopped)
        #expect(await waitFor { engine.hasLostControl })
        try? await Task.sleep(for: .milliseconds(300))
        // Its queue is left as the other zone made it, and the iPad stays on its song, paused.
        #expect(sim.queue(of: Self.bedroom).count == 1 && sim.queue(of: Self.bedroom)[0].contains("2000000077"), "\(sim.queue(of: Self.bedroom))")
        #expect(iPadSession.state.current?.track.id == current)
        #expect(!iPadSession.isPlaying)
    }
}

/// What "Use" asks (the iPad's dialog; the page's sheet says the same).
struct SonosTakeoverPromptTests {
    @Test func twoRooms() {
        let prompt = SonosTakeoverPrompt(room: "Move", together: ["Bedroom", "Move"], zone: "Living Room iPad")
        #expect(prompt.title == "Use Bedroom and Move?")
        #expect(prompt.message == "They're playing Living Room iPad's zone. Its music stops there and plays here instead.")
        #expect(prompt.all == "Use Both Rooms")
        #expect(prompt.just == "Just Move")
    }

    @Test func oneRoomAndThree() {
        let one = SonosTakeoverPrompt(room: "Kitchen", together: ["Kitchen"], zone: "Den")
        #expect(one.title == "Use Kitchen?")
        #expect(one.message.hasPrefix("It's playing Den's zone."))
        #expect(one.all == nil && one.just == "Use Kitchen")
        let three = SonosTakeoverPrompt(room: "Move", together: ["Bedroom", "Kitchen", "Move"], zone: "Den")
        // The Oxford comma, whatever the locale.
        #expect(three.title == "Use Bedroom, Kitchen, and Move?")
        #expect(three.all == "Use All 3 Rooms")
    }
}

/// The rules on their own: a song the engine never queued is someone else's.
struct SonosForeignQueueRulesTests {
    typealias O = SonosPlaybackRules.Observation
    typealias C = SonosPlaybackRules.Context
    let a = "1000000001", b = "1000000002"

    @Test func aSongNeverQueuedIsAnotherSource() {
        let c = C(currentID: a, currentNumber: 1, stagedID: b, stagedNumber: 2, sawPlaying: true, queued: [a, b])
        // Another zone's queue, further down than ours was: not "further on in ours".
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: "spotify:track:theirs", state: .playing), c) == .lostControl)
        // Stopped on it (queued, not yet playing): not the end of ours either.
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: "spotify:track:theirs", state: .stopped), c) == .lostControl)
        // Ours still: as before.
        let gone = C(currentID: b, currentNumber: 2, sawPlaying: true, queued: [a, b])
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .stopped), gone) == .reachedEnd)
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: a, state: .playing), C(currentID: b, currentNumber: 2, sawPlaying: true, queued: [a, b])) == .reachedEnd)
    }
}

extension SonosZoneClaimTests {
    func post(_ port: UInt16, _ path: String, _ body: [String: Any]) async throws -> Int {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
