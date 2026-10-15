@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// Linked accounts a hub has seen, kept per Sonos household (`SonosAccountMemory`); shared
/// between hubs (`GET /api/sonos/accounts`, `SonosAccountExchange`); and forgotten when Sonos
/// refuses to play from them (`SonosEngine.onAccountRejected`). On the simulated household.
@MainActor
@Suite(.serialized) struct SonosAccountMemoryTests {
    static let bedroom = "RINCON_BEAM", move = "RINCON_MOVE"
    static let hosts = ["10.0.0.1", "10.0.0.2"]
    static let spotifySong = "x-sonos-spotify:spotify%3atrack%3aabc?sid=12&flags=8232&sn=4"

    /// Favourites hold nothing from a service (as on the real household: only Sonos Radio); Move
    /// plays a Spotify song from account 4 from the Sonos app.
    let sim: SonosSimulator = {
        let sim = SonosSimulator(rooms: [
            .init(id: bedroom, name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
            .init(id: move, name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
        ])
        sim.accounts = []
        sim.play(.init(uri: spotifySong, title: "Ribs", artist: "Lorde"), in: move)
        return sim
    }()
    let defaults = UserDefaults(suiteName: "SonosAccountMemoryTests-\(UUID().uuidString)")!

    final class Counter: @unchecked Sendable { var count = 0 }

    /// A hub's controller on the simulated household once it has been read (`hosts`: its rooms;
    /// none is a relaunch before discovery).
    func makeController(service: SonosMusicService = .spotify, defaults: UserDefaults? = nil, hosts: [String] = hosts,
                        exchange: SonosAccountExchange = SonosAccountExchange()) async -> SonosOutputController {
        let household = SonosHousehold(transport: sim, fixedHosts: hosts)
        let controller = SonosOutputController(household: household, defaults: defaults ?? self.defaults, exchange: exchange)
        controller.service = service
        controller.readingFreshness = 0
        household.onRefresh = { [weak controller] in controller?.householdRefreshed() }
        guard !hosts.isEmpty else { return controller }
        household.start()
        for _ in 0..<200 where household.players.count < hosts.count || household.isRefreshing || household.householdID == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return controller
    }

    func waitFor(_ condition: @MainActor () -> Bool, timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Move moves on to something that shows no account (the Sonos app's radio, say).
    func moveOn() {
        sim.play(.init(uri: "x-sonosapi-radio:sonos%3a123?sid=303&flags=8300", title: "Radio"), in: Self.move)
    }

    // MARK: Kept

    @Test func anAccountSeenOnceStaysAfterTheQueueChangesAndARelaunch() async throws {
        let controller = await makeController()
        #expect(controller.household.householdID == "Sonos_Simulated")
        #expect(controller.accounts.map(\.id) == ["12:4"])
        #expect(controller.account?.serialNumber == 4)

        // What showed it is gone: discovery no longer finds it, the hub still knows it.
        moveOn()
        await controller.household.refreshNow()
        #expect(!controller.household.accounts.contains { $0.serviceID == 12 })
        #expect(controller.accounts.map(\.id) == ["12:4"])
        #expect(controller.account?.serialNumber == 4)
        let known = try #require(controller.memory.households["Sonos_Simulated"]?.first)
        #expect(known.account.seenIn == "Move" && known.account.example == "Ribs" && known.learnedFrom == nil)

        // A relaunch, before discovery has run: the household last read.
        let early = await makeController(hosts: [])
        #expect(early.household.householdID == nil)
        #expect(early.accounts.map(\.id) == ["12:4"])
        // And once it has: the same household.
        let again = await makeController()
        #expect(again.accounts.map(\.id) == ["12:4"])
        #expect(again.playback == nil) // No rooms chosen: nothing plays, but the account is known.
        again.select(rooms: [Self.bedroom])
        #expect(again.playback?.reference.accountSerial == 4)
    }

    @Test func accountsAreKeptPerHousehold() async throws {
        let controller = await makeController()
        #expect(controller.accounts.map(\.id) == ["12:4"])
        moveOn()

        // The same hub in another home: nothing known there, the assumed account plays.
        sim.householdID = "Sonos_Elsewhere"
        let away = await makeController()
        #expect(away.household.householdID == "Sonos_Elsewhere")
        #expect(away.accounts.isEmpty)
        #expect(away.account?.serialNumber == SonosOutputController.assumedSerial)
        #expect(away.memory.households["Sonos_Elsewhere"] == nil)
        #expect(away.memory.lastHousehold == "Sonos_Elsewhere")
        #expect(away.sonosAccounts(household: "Sonos_Simulated").map(\.serialNumber) == [4])

        // Back home.
        sim.householdID = "Sonos_Simulated"
        let home = await makeController()
        #expect(home.accounts.map(\.id) == ["12:4"])
    }

    @Test func aSimulatedHouseholdKeepsAccountsOnlyInMemory() async throws {
        let household = SonosHousehold(transport: sim, fixedHosts: Self.hosts)
        let controller = SonosOutputController(household: household, defaults: nil)
        controller.service = .spotify
        household.onRefresh = { [weak controller] in controller?.householdRefreshed() }
        household.start()
        #expect(await waitFor { controller.accounts.map(\.id) == ["12:4"] })
        #expect(controller.memory.households["Sonos_Simulated"]?.count == 1)
        #expect(defaults.data(forKey: SonosOutputController.knownAccountsKey) == nil)
    }

    // MARK: Refused

    /// Real household: a service that isn't linked was refused with 800 by the coordinator
    /// itself (and Play then 701). The engine's 800 is otherwise "not the coordinator", which it
    /// follows: here the live layout says the room leads, so it's the account's refusal.
    @Test func aRefusedAccountIsForgotten() async throws {
        let controller = await makeController()
        moveOn()
        await controller.household.refreshNow()
        #expect(controller.accounts.map(\.id) == ["12:4"])
        controller.select(rooms: [Self.bedroom])
        let engine = try #require(controller.makeEngine())
        engine.pollInterval = (.milliseconds(50), .milliseconds(50))
        let session = PartySession(catalog: SonosFakeCatalog(service: .spotify), engine: engine)
        controller.connect(session)
        let rebuilds = Counter()
        controller.onOutputChanged = { rebuilds.count += 1 }
        let playlist = try #require(try await SonosFakeCatalog(service: .spotify).libraryPlaylists().first)
        try await session.load(playlist: playlist)

        sim.unlinkedServices = [SonosMusicService.spotify.serviceID]
        let before = sim.requests.count
        await #expect(throws: SonosError.self) { try await session.play() }
        #expect(await waitFor { controller.accounts.isEmpty })
        // Not followed as a regrouping, nor tried again: one add, and the layout read twice
        // (grouping at the first play, then confirming the room leads).
        let sent = sim.requests[before...]
        #expect(sent.filter { $0.action == "AddURIToQueue" }.count == 1)
        #expect(sent.filter { $0.action == "GetZoneGroupState" }.count == 2)
        #expect(engine.target.coordinator.id == Self.bedroom)
        #expect(!sim.requests[before...].contains { $0.action == "Play" })

        // Forgotten: here, in what's kept, and as the choice; no account is assumed for it now.
        #expect(controller.isUnlinked(.spotify))
        #expect(controller.account == nil)
        let setup = try #require(controller.setup())
        #expect(!setup.hasAccount)
        #expect(controller.memory.households["Sonos_Simulated"]?.isEmpty == true)
        #expect(await waitFor { rebuilds.count == 1 })
        #expect(!controller.usesSonos)
        let relaunched = await makeController()
        #expect(relaunched.accounts.isEmpty)
        session.shutdown()
    }

    /// No account seen, the assumed one plays: if Sonos refuses the service, the note shows and
    /// nothing can be ticked; once the account is seen playing, the rooms come back.
    @Test func aRefusedAssumedAccountShowsTheNote() async throws {
        moveOn()
        sim.unlinkedServices = [SonosMusicService.appleMusic.serviceID]
        let controller = await makeController(service: .appleMusic)
        controller.canChangeOutput = { true }
        #expect(controller.setup()?.hasAccount == true)
        #expect(controller.setSonosRoom(Self.bedroom, on: true))
        let engine = try #require(controller.makeEngine())
        #expect(engine.reference.accountSerial == SonosOutputController.assumedSerial)
        let session = PartySession(catalog: SonosFakeCatalog(), engine: engine)
        controller.connect(session)
        let playlist = try #require(try await SonosFakeCatalog().libraryPlaylists().first)
        try await session.load(playlist: playlist)
        await #expect(throws: SonosError.self) { try await session.play() }

        #expect(await waitFor { controller.setup()?.hasAccount == false })
        #expect(controller.isUnlinked(.appleMusic))
        #expect(!controller.setSonosRoom(Self.move, on: true))
        // Linked after all, and a song from it played in the Sonos app: found, usable again.
        sim.unlinkedServices = []
        sim.play(.init(uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=2", title: "Ribs"), in: Self.move)
        await controller.readRooms()
        #expect(controller.setup()?.hasAccount == true)
        #expect(controller.account?.serialNumber == 2)
        session.shutdown()
    }

    @Test func grouping800IsNotARefusal() {
        let refused = SonosError.upnp(action: "AddURIToQueue", code: 800)
        #expect(SonosEngine.isAccountRefusal(refused, .coordinator))
        #expect(!SonosEngine.isAccountRefusal(refused, .regrouped))
        #expect(!SonosEngine.isAccountRefusal(refused, .unknown))
        #expect(SonosEngine.isAccountRefusal(SonosError.upnp(action: "Play", code: 701), .unknown))
        #expect(!SonosEngine.isAccountRefusal(SonosError.unreachable, .unknown))
    }

    // MARK: Shared

    func get(_ port: UInt16, _ path: String) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(from: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// A hub's zone serving its controller's accounts.
    func serve(_ controller: SonosOutputController, port: UInt16) async throws -> (PartySession, PartyServer, Task<Void, Error>) {
        let session = PartySession(catalog: SonosFakeCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Spotify")
        session.sonosHandler = controller
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        return (session, server, task)
    }

    @Test func theRouteGivesOnlyThatHouseholdsAccounts() async throws {
        let port: UInt16 = 18871
        let controller = await makeController()
        moveOn()
        sim.householdID = "Sonos_Elsewhere"
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3axyz?sid=12&flags=8232&sn=7", title: "Team"), in: Self.move)
        await controller.household.refreshNow()
        #expect(controller.memory.households.keys.sorted() == ["Sonos_Elsewhere", "Sonos_Simulated"])
        let (session, server, task) = try await serve(controller, port: port)
        defer { task.cancel(); Task { await server.stop() } }

        var (status, data) = try await get(port, "/api/sonos/accounts?household=Sonos_Simulated")
        #expect(status == 200)
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(list.count == 1)
        // Only the service, the serial and a label: no token, no room.
        #expect(Set(list[0].keys) == ["serviceID", "serialNumber", "label"])
        #expect(list[0]["serialNumber"] as? Int == 4 && list[0]["label"] as? String == "Ribs")
        (status, data) = try await get(port, "/api/sonos/accounts?household=Sonos_Elsewhere")
        #expect(try JSONDecoder().decode([SonosSharedAccount].self, from: data).map(\.serialNumber) == [7])
        (status, data) = try await get(port, "/api/sonos/accounts?household=Sonos_Nobody")
        let none = try JSONDecoder().decode([SonosSharedAccount].self, from: data)
        #expect(status == 200 && none.isEmpty)
        (status, _) = try await get(port, "/api/sonos/accounts")
        #expect(status == 400)
        session.sonosHandler = nil
        (status, _) = try await get(port, "/api/sonos/accounts?household=Sonos_Simulated")
        #expect(status == 501)
    }

    /// Hub B saw account 7 (several Spotify accounts in the household make the serial matter);
    /// hub A, new, has seen none, and the service was refused there (its assumed account): it
    /// asks B over the route while it lists the rooms, remembers what B says, and the rooms
    /// play from 7.
    @Test func anAccountLearnedFromAnotherHubMakesTheRoomsSelectable() async throws {
        let port: UInt16 = 18872
        let hubB = await makeController(defaults: UserDefaults(suiteName: "SonosAccountMemoryTests-B-\(UUID().uuidString)")!)
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3axyz?sid=12&flags=8232&sn=7", title: "Team"), in: Self.move)
        await hubB.household.refreshNow()
        moveOn()
        let (_, server, task) = try await serve(hubB, port: port)
        defer { task.cancel(); Task { await server.stop() } }

        let hubA = await makeController(defaults: UserDefaults(suiteName: "SonosAccountMemoryTests-A-\(UUID().uuidString)")!)
        hubA.canChangeOutput = { true }
        #expect(hubA.accounts.isEmpty)
        hubA.accountRejected(SonosTrackReference(service: .spotify, accountSerial: SonosOutputController.assumedSerial))
        #expect(hubA.setup()?.hasAccount == false)
        #expect(!hubA.setSonosRoom(Self.bedroom, on: true))

        hubA.peers = { [ZoneListing(id: "Den", name: "Den", kind: .tv, address: "127.0.0.1:\(port)", hubID: "hub-b")] }
        await hubA.readRooms()
        #expect(await waitFor { !hubA.accounts.isEmpty })
        #expect(hubA.accounts.map(\.id) == ["12:4", "12:7"])
        #expect(hubA.memory.households["Sonos_Simulated"]?.allSatisfy { $0.learnedFrom == "Den" } == true)
        #expect(hubA.setup()?.hasAccount == true)
        #expect(hubA.setSonosRoom(Self.bedroom, on: true))
        #expect(hubA.chooseSonosAccount("12:7"))
        #expect(hubA.playback?.reference.accountSerial == 7)
        // Seen here later, it counts as this hub's own sighting.
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3axyz?sid=12&flags=8232&sn=7", title: "Team"), in: Self.move)
        await hubA.household.refreshNow()
        #expect(hubA.memory.households["Sonos_Simulated"]?.first { $0.account.serialNumber == 7 }?.learnedFrom == nil)
    }

    @Test func otherHubsAreAskedOnlyWhenSomethingIsMissingAndNotTooOften() async throws {
        let calls = Counter()
        let exchange = SonosAccountExchange(timeout: .milliseconds(300)) { url in
            calls.count += 1
            if url.host == "192.0.2.9" { try await Task.sleep(for: .seconds(5)) } // Never answers in time.
            if url.host == "192.0.2.8" { throw URLError(.cannotConnectToHost) }
            return (Data(#"[{"serviceID":204,"serialNumber":6,"label":"Ribs"}]"#.utf8), 200)
        }
        moveOn()
        let controller = await makeController(service: .appleMusic, exchange: exchange)
        let zones = [
            ZoneListing(id: "A", name: "Kitchen", kind: .ipad, address: "192.0.2.7", hubID: "a"),
            ZoneListing(id: "B", name: "Gone", kind: .ipad, address: "192.0.2.8", hubID: "b"),
            ZoneListing(id: "C", name: "Slow", kind: .tv, address: "192.0.2.9", hubID: "c"),
        ]
        controller.peers = { zones }
        let start = Date()
        await controller.askPeersIfMissing()
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(calls.count == 3)
        #expect(controller.accounts.map(\.id) == ["204:6"])
        // Known now: nobody is asked.
        controller.peers = { zones + [ZoneListing(id: "D", name: "New", kind: .tv, address: "192.0.2.10", hubID: "d")] }
        await controller.askPeersIfMissing()
        #expect(calls.count == 3)

        // Missing (Spotify), the same zones: asked once, not again within the interval.
        controller.service = .spotify
        controller.peers = { Array(zones.dropFirst()) }
        await controller.askPeersIfMissing()
        #expect(calls.count == 5)
        await controller.askPeersIfMissing()
        #expect(calls.count == 5)
        await controller.askPeersIfMissing(now: Date().addingTimeInterval(SonosOutputController.askInterval + 1))
        #expect(calls.count == 7)
        #expect(controller.accounts.isEmpty)
    }
}
