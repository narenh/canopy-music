@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// The Sonos output both hubs share (`SonosOutputController`): choosing rooms and an account,
/// rooms joining and leaving while the music plays, volumes, and what a host's phone is told,
/// on the simulated household. Then the host-only routes and snapshot field the phone uses.
@MainActor
@Suite(.serialized) struct SonosOutputControllerTests {
    static let bedroom = "RINCON_BEAM", move = "RINCON_MOVE", kitchen = "RINCON_ONE"

    let sim: SonosSimulator = {
        let sim = SonosSimulator(rooms: [
            .init(id: bedroom, name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
            .init(id: move, name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
            .init(id: kitchen, name: "Kitchen", model: "One", host: "10.0.0.3", volume: 20, reachable: false),
        ])
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3aabc?sid=12&flags=8232&sn=4", title: "Ribs", artist: "Lorde"), in: move)
        return sim
    }()
    let defaults = UserDefaults(suiteName: "SonosOutputControllerTests-\(UUID().uuidString)")!

    final class Counter { var count = 0 }

    /// A controller on the simulated household once it has been read, for Apple Music.
    func makeController(service: SonosMusicService? = .appleMusic) async -> SonosOutputController {
        let household = SonosHousehold(transport: sim, fixedHosts: ["10.0.0.1", "10.0.0.2", "10.0.0.3"])
        let controller = SonosOutputController(household: household, defaults: defaults)
        controller.service = service
        household.onRefresh = { [weak controller] in controller?.householdRefreshed() }
        household.start()
        for _ in 0..<200 where household.players.count < 3 || household.isRefreshing {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.readRooms()
        return controller
    }

    /// A session playing through the controller's rooms (made-up songs Sonos can carry).
    func playingSession(_ controller: SonosOutputController) async throws -> PartySession {
        let engine = try #require(controller.makeEngine())
        engine.pollInterval = (.milliseconds(50), .milliseconds(50))
        let session = PartySession(catalog: SonosFakeCatalog(), engine: engine)
        controller.connect(session)
        let playlist = try #require(try await SonosFakeCatalog().libraryPlaylists().first)
        try await session.load(playlist: playlist)
        try await session.play()
        return session
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

    // MARK: Choosing

    @Test func choosingRoomsPicksAnAccountAndIsKept() async throws {
        let controller = await makeController()
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }
        controller.select(rooms: [Self.bedroom, Self.move])
        #expect(controller.output?.roomIDs == [Self.bedroom, Self.move])
        #expect(controller.output?.target.name == "Bedroom + Move")
        // The household's Apple Music account (favourites: sn 3).
        #expect(controller.account?.serialNumber == 3)
        #expect(rebuilds.count == 1)
        let engine = try #require(controller.makeEngine())
        #expect(engine.target.rooms.map(\.id) == [Self.bedroom, Self.move])
        #expect(engine.reference.service == .appleMusic && engine.reference.accountSerial == 3)
        // Choosing sends nothing to the speakers.
        #expect(sim.changes.isEmpty)

        // A relaunch: the same rooms and account, before discovery has run.
        let again = SonosOutputController(household: SonosHousehold(transport: sim, fixedHosts: []), defaults: defaults)
        again.service = .appleMusic
        #expect(again.output == controller.output)
        #expect(again.playback == controller.playback)
    }

    @Test func aSimulatedHouseholdKeepsNothing() async {
        let household = SonosHousehold(transport: sim, fixedHosts: ["10.0.0.1"])
        let controller = SonosOutputController(household: household, defaults: nil)
        controller.service = .spotify
        controller.use(SonosOutput(target: SonosTarget(coordinator: .init(id: Self.bedroom, name: "Bedroom", host: "10.0.0.1"))),
                       account: SonosAccount(serviceID: 12, serialNumber: 4), for: .spotify)
        #expect(controller.usesSonos)
        #expect(SonosOutputController(household: household, defaults: nil).output == nil)
    }

    @Test func setupSaysWhatTheIPadSays() async throws {
        let controller = await makeController()
        var setup = try #require(controller.setup())
        #expect(setup.service == "Apple Music")
        #expect(setup.searched)
        #expect(setup.rooms.map(\.name) == ["Bedroom", "Kitchen", "Move"])
        #expect(room(setup, Self.bedroom)?.status == "Beam")
        #expect(room(setup, Self.bedroom)?.state == "idle")
        #expect(room(setup, Self.bedroom)?.volume == 30)
        #expect(room(setup, Self.move)?.status == "Playing Ribs – Lorde")
        #expect(room(setup, Self.move)?.state == "busy")
        #expect(room(setup, Self.kitchen)?.status == "Not responding")
        #expect(room(setup, Self.kitchen)?.canTick == false)
        #expect(room(setup, Self.kitchen)?.volume == nil)
        #expect(setup.hasAccount)
        #expect(setup.chosen.isEmpty && !setup.ready && !setup.active)

        controller.select(rooms: [Self.bedroom])
        setup = try #require(controller.setup())
        #expect(setup.chosen == [Self.bedroom])
        #expect(setup.chosenName == "Bedroom")
        #expect(room(setup, Self.bedroom)?.ticked == true)
        // Ticked before the music has started: its model still.
        #expect(room(setup, Self.bedroom)?.status == "Beam")
        #expect(setup.ready)
        #expect(setup.accounts.count == 1)
        #expect(setup.accounts.first?.label.hasPrefix("Account 1") == true)

        // No service Sonos can stream (no service yet, or the demo): nothing to show.
        controller.service = nil
        #expect(controller.setup() == nil)
    }

    /// A real household played a linked service's songs with any serial: with no account seen,
    /// one is assumed (serial 1), so the rooms can be chosen and play straight away.
    @Test func withNoAccountSeenTheRoomsPlayFromAnAssumedOne() async throws {
        sim.accounts = []
        let controller = await makeController()
        controller.canChangeOutput = { true }
        #expect(controller.accounts.isEmpty)
        var setup = try #require(controller.setup())
        #expect(setup.hasAccount)
        // Nothing to choose between: no "Whose account plays".
        #expect(setup.accounts.isEmpty)
        #expect(controller.setSonosRoom(Self.bedroom, on: true))
        #expect(controller.account?.serialNumber == SonosOutputController.assumedSerial)
        #expect(controller.playback?.reference.accountSerial == 1)
        setup = try #require(controller.setup())
        #expect(setup.ready)
        // The assumed account isn't kept as the choice: an account seen later takes over.
        #expect(defaults.data(forKey: SonosOutputController.accountsKey).flatMap { try? JSONDecoder().decode([String: SonosAccount].self, from: $0) }?.isEmpty != false)

        let session = try await playingSession(controller)
        #expect(await waitFor { sim.state(of: Self.bedroom) == .playing })
        #expect(sim.queue(of: Self.bedroom).first?.contains("sid=204&flags=8224&sn=1") == true)
        // Playing isn't a refusal: the account stays.
        #expect(controller.setup()?.hasAccount == true)
        session.shutdown()
    }

    @Test func severalAccountsAreOfferedAndChoosingOneRebuilds() async throws {
        sim.accounts = [(SonosMusicService.spotify.serviceID, 4), (SonosMusicService.spotify.serviceID, 7)]
        let controller = await makeController(service: .spotify)
        controller.canChangeOutput = { true }
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }
        #expect(controller.setSonosRoom(Self.bedroom, on: true))
        var setup = try #require(controller.setup())
        #expect(setup.accounts.count == 2)
        let second = try #require(setup.accounts.first { $0.id != setup.accountID })
        #expect(controller.chooseSonosAccount(second.id))
        setup = try #require(controller.setup())
        #expect(setup.accountID == second.id)
        #expect(controller.playback?.reference.accountSerial == Int(second.id.split(separator: ":").last ?? ""))
        #expect(rebuilds.count == 2)
        #expect(!controller.chooseSonosAccount("12:99"))
        // Not once the zone is running.
        controller.canChangeOutput = { false }
        #expect(!controller.chooseSonosAccount(setup.accounts[0].id))
    }

    @Test func beforeTheMusicStartsTickingOnlyChangesTheChoice() async throws {
        let controller = await makeController()
        controller.canChangeOutput = { true }
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }
        #expect(controller.setSonosRoom(Self.bedroom, on: true))
        // The session is rebuilt with a Sonos engine (as the apps do), not played yet.
        let session = PartySession(catalog: SonosFakeCatalog(), engine: try #require(controller.makeEngine()))
        controller.connect(session)
        #expect(controller.setSonosRoom(Self.move, on: true))
        #expect(controller.output?.roomIDs == [Self.bedroom, Self.move])
        #expect(controller.engine?.target.rooms.map(\.id) == [Self.bedroom, Self.move])
        // Not a room that doesn't answer, nor one already ticked.
        #expect(!controller.setSonosRoom(Self.kitchen, on: true))
        #expect(!controller.setSonosRoom(Self.move, on: true))
        #expect(controller.setSonosRoom(Self.bedroom, on: false))
        #expect(controller.output?.roomIDs == [Self.move])
        // The last room: back to the hub's own output.
        #expect(controller.setSonosRoom(Self.move, on: false))
        #expect(controller.output == nil)
        #expect(rebuilds.count == 2)
        #expect(sim.changes.isEmpty)
        // Ticking again, then This Apple TV.
        #expect(controller.setSonosRoom(Self.bedroom, on: true))
        #expect(controller.leaveSonos())
        #expect(controller.output == nil)
        controller.canChangeOutput = { false }
        #expect(!controller.setSonosRoom(Self.bedroom, on: true))
        #expect(!controller.leaveSonos())
    }

    // MARK: While it plays

    @Test func roomsJoinAndLeaveWhileItPlays() async throws {
        let controller = await makeController()
        controller.select(rooms: [Self.bedroom])
        let session = try await playingSession(controller)
        #expect(controller.isLive)
        #expect(sim.state(of: Self.bedroom) == .playing)
        let changes = Counter()
        controller.onChange = { changes.count += 1 }

        // Move joins without the song restarting.
        let before = sim.requests.count
        #expect(controller.setSonosRoom(Self.move, on: true))
        #expect(await waitFor { controller.joining.isEmpty && controller.output?.roomIDs == [Self.bedroom, Self.move] })
        #expect(sim.topology.contains([Self.bedroom, Self.move]))
        #expect(!sim.requests[before...].contains { $0.action == "Play" || $0.action == "RemoveAllTracksFromQueue" })
        #expect(changes.count > 0)
        var setup = try #require(controller.setup())
        #expect(setup.live && setup.active)
        #expect(room(setup, Self.move)?.status == "Playing Canopy Music")
        #expect(room(setup, Self.bedroom)?.state == "ours")

        // Bedroom (leading) leaves: Move plays on, the output follows.
        #expect(controller.setSonosRoom(Self.bedroom, on: false))
        #expect(await waitFor { controller.output?.roomIDs == [Self.move] })
        #expect(await waitFor { sim.state(of: Self.move) == .playing && sim.state(of: Self.bedroom) != .playing })
        // The last room stays while the music plays.
        #expect(!controller.setSonosRoom(Self.move, on: false))
        #expect(controller.output?.roomIDs == [Self.move])
        setup = try #require(controller.setup())
        #expect(setup.chosen == [Self.move])
        session.shutdown()
    }

    @Test func volumes() async throws {
        let controller = await makeController()
        controller.select(rooms: [Self.bedroom, Self.move])
        let session = try await playingSession(controller)
        controller.setSonosVolume(55, room: Self.bedroom)
        // Shown at once, before the speakers answer.
        #expect(room(controller.setup(), Self.bedroom)?.volume == 55)
        #expect(await waitFor { sim.room(Self.bedroom)?.volume == 55 })
        controller.setSonosVolume(140, room: Self.move)
        #expect(await waitFor { sim.room(Self.move)?.volume == 100 })

        // The group keeps the rooms' balance: 30 and 60 (average 45) to 90 is 60 and 120 → 100.
        controller.setSonosVolume(30, room: Self.bedroom)
        controller.setSonosVolume(60, room: Self.move)
        #expect(await waitFor { sim.room(Self.bedroom)?.volume == 30 && sim.room(Self.move)?.volume == 60 })
        controller.beginSonosGroupVolume()
        #expect(await waitFor { sim.requests.contains { $0.action == "SnapshotGroupVolume" } })
        controller.setSonosVolume(90, room: nil)
        #expect(await waitFor { sim.room(Self.bedroom)?.volume == 60 && sim.room(Self.move)?.volume == 100 })
        let group = sim.requests.filter { $0.action == "SetGroupVolume" }
        #expect(group.allSatisfy { $0.host == "10.0.0.1" })
        session.shutdown()
    }

    // MARK: Discovery

    @Test func anAccountFoundLaterRebuildsTheSession() async throws {
        sim.accounts = []
        let controller = await makeController()
        controller.select(rooms: [Self.bedroom])
        // The assumed account plays until one is seen.
        #expect(controller.playback?.reference.accountSerial == 1)
        let session = PartySession(catalog: SonosFakeCatalog(), engine: try #require(controller.makeEngine()))
        controller.connect(session)
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }
        sim.accounts = [(SonosMusicService.appleMusic.serviceID, 3)]
        await controller.household.refreshNow()
        #expect(controller.playback?.reference.accountSerial == 3)
        #expect(rebuilds.count == 1)
    }

    /// Seen on a real iPad: no Apple Music account found, so the rooms couldn't be ticked; the
    /// host played an Apple Music song from the Sonos app, the rows showed it, but the rooms
    /// stayed unselectable until a relaunch (accounts were read only by a full refresh).
    @Test func anAccountSeenPlayingMakesTheRoomsSelectableWithoutARelaunch() async throws {
        sim.accounts = []
        let controller = await makeController()
        controller.canChangeOutput = { true }
        controller.select(rooms: [Self.bedroom])
        // The assumed account meanwhile.
        #expect(controller.accounts.isEmpty)
        #expect(controller.account?.serialNumber == 1)
        let session = PartySession(catalog: SonosFakeCatalog(), engine: try #require(controller.makeEngine()))
        controller.connect(session)
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }

        // Played from the Sonos app, on Move: an Apple Music song (account 5).
        sim.play(.init(uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=5", title: "Ribs", artist: "Lorde"), in: Self.move)
        await controller.readRooms()
        let setup = try #require(controller.setup())
        #expect(room(setup, Self.move)?.status == "Playing Ribs – Lorde")
        #expect(setup.hasAccount)
        #expect(controller.account?.serialNumber == 5)
        // The chosen room now plays from it: the session is rebuilt with a Sonos engine.
        #expect(controller.usesSonos)
        #expect(rebuilds.count == 1)
        #expect(controller.setSonosRoom(Self.move, on: true))
        // A reading with nothing new doesn't read the household again.
        let before = sim.requests.filter { $0.action == "Browse" }.count
        await controller.readRooms()
        #expect(sim.requests.filter { $0.action == "Browse" }.count == before)
        #expect(sim.changes.isEmpty)
    }

    // MARK: The phone

    @Test func snapshotsCarryTheRoomsForHostsOnly() async throws {
        let controller = await makeController()
        let session = PartySession(catalog: SonosFakeCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        session.hostKey = "secret"
        session.sonosSetup = controller.setup()
        #expect(session.snapshot().sonos == nil)
        #expect(session.snapshot(hostKey: "wrong").sonos == nil)
        #expect(session.snapshot(hostKey: "secret").sonos?.rooms.count == 3)

        var host = session.snapshots(hostKey: "secret").makeAsyncIterator()
        var guest = session.snapshots().makeAsyncIterator()
        #expect(await host.next()?.sonos?.chosen.isEmpty == true)
        #expect(await guest.next()?.sonos == nil)
        controller.select(rooms: [Self.bedroom])
        session.sonosSetup = controller.setup()
        #expect(await host.next()?.sonos?.chosen == [Self.bedroom])
        #expect(await guest.next()?.sonos == nil)
    }

    func post(_ port: UInt16, _ path: String, _ body: [String: Any]) async throws -> Int {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func theRoutesAreForHostsOnly() async throws {
        let port: UInt16 = 18861
        let controller = await makeController()
        controller.canChangeOutput = { true }
        let session = PartySession(catalog: SonosFakeCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        session.hostKey = "secret"
        session.sonosHandler = controller
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        defer { task.cancel(); Task { await server.stop() } }

        let routes: [(String, [String: Any])] = [
            ("/api/host/sonos/room", ["id": Self.bedroom, "on": true]), ("/api/host/sonos/off", [:]),
            ("/api/host/sonos/account", ["id": "204:3"]), ("/api/host/sonos/volume", ["id": Self.bedroom, "volume": 40]),
            ("/api/host/sonos/read", [:]),
        ]
        for (path, body) in routes {
            #expect(try await post(port, path, body.merging(["key": "nope"]) { $1 }) == 403, "\(path)")
        }
        #expect(controller.output == nil)
        #expect(sim.changes.isEmpty)

        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.bedroom, "on": true]) == 204)
        #expect(controller.output?.roomIDs == [Self.bedroom])
        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.kitchen, "on": true]) == 409)
        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.bedroom]) == 400)
        #expect(try await post(port, "/api/host/sonos/account", ["key": "secret", "id": "204:3"]) == 204)
        #expect(try await post(port, "/api/host/sonos/account", ["key": "secret", "id": "204:9"]) == 409)
        #expect(try await post(port, "/api/host/sonos/volume", ["key": "secret", "id": Self.move, "volume": 12]) == 204)
        #expect(await waitFor { sim.room(Self.move)?.volume == 12 })
        #expect(try await post(port, "/api/host/sonos/volume", ["key": "secret"]) == 400)
        #expect(try await post(port, "/api/host/sonos/read", ["key": "secret"]) == 204)
        #expect(try await post(port, "/api/host/sonos/off", ["key": "secret"]) == 204)
        #expect(controller.output == nil)
        // Past setup, the music stays on its output.
        controller.canChangeOutput = { false }
        #expect(try await post(port, "/api/host/sonos/room", ["key": "secret", "id": Self.bedroom, "on": true]) == 409)
        #expect(try await post(port, "/api/host/sonos/off", ["key": "secret"]) == 409)

        // A hub without Sonos.
        session.sonosHandler = nil
        #expect(try await post(port, "/api/host/sonos/read", ["key": "secret"]) == 501)

        // Guests' state never has it.
        session.sonosSetup = controller.setup()
        let (data, _) = try await URLSession.shared.data(from: try #require(URL(string: "http://127.0.0.1:\(port)/api/state")))
        let state = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["sonos"] == nil)
        #expect(state["zoneName"] as? String == "Den")
    }
}
