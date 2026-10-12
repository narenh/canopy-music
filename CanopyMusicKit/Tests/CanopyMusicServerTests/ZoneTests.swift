@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// A real hub server and a display mirroring it over HTTP + WebSocket on localhost.
@MainActor
@Suite(.serialized)
struct ZoneTests {
    func makeHub(port: UInt16) async throws -> (PartySession, PartyServer, Task<Void, Error>) {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.configureHub(kind: .tv, id: "tv-1", zoneName: "Living Room", serviceName: "Demo")
        let playlist = try #require(try await DemoCatalog().libraryPlaylists().first)
        try await hub.load(playlist: playlist)
        try await hub.play()
        let started = await PartyServer.start(session: hub, ports: [port])
        let (server, task) = try #require(started)
        return (hub, server, task)
    }

    func waitFor(_ condition: @MainActor () -> Bool, timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func displayMirrorsAndEdits() async throws {
        let (hub, server, task) = try await makeHub(port: 18771)
        defer { task.cancel(); Task { await server.stop() } }
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18771")!, clientID: "kitchen", name: "Kitchen iPad", kind: .ipad)
        let display = PartySession(remote: connection)
        connection.start(session: display)
        defer { connection.stop() }

        #expect(await waitFor { display.state.current?.id == hub.state.current?.id && display.state.current != nil })
        #expect(display.zoneName == "Living Room")
        #expect(display.hubKind == .tv)
        #expect(display.hubID == "tv-1") // pages keep host keys per hub by this
        #expect(display.state.upNext.map(\.id) == hub.state.upNext.map(\.id))

        // Adding on the display shows at once and lands on the hub with the same ID.
        let track = DemoCatalog.track(20)
        guard case .added(let item, _) = display.add(track, by: Requester(origin: .ipad)) else {
            Issue.record("not added"); return
        }
        #expect(await waitFor { hub.state.upNext.contains { $0.id == item.id } })
        #expect(hub.state.upNext.first { $0.id == item.id }?.requester?.name == "Kitchen iPad")

        // The hub sees the display check in.
        #expect(await waitFor { hub.displays.contains { $0.id == "kitchen" } })

        // Playback controls follow the hub setting.
        await display.skip()
        let afterSkip = hub.state.current?.id
        #expect(await waitFor { display.state.current?.id == afterSkip })
        hub.displaysCanControl = false
        #expect(await waitFor { display.displaysCanControl == false })
        let current = hub.state.current?.id
        await display.skip()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(hub.state.current?.id == current)

        // Displays can't delete.
        #expect(display.remove(item.id) == false)
    }

    @Test func refusedMoveIsUndone() async throws {
        let (hub, server, task) = try await makeHub(port: 18772)
        defer { task.cancel(); Task { await server.stop() } }
        hub.phonesCanReorder = false
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18772")!, clientID: "tv", name: "Living Room TV", kind: .tv)
        let display = PartySession(remote: connection)
        connection.start(session: display)
        defer { connection.stop() }
        #expect(await waitFor { display.state.upNext.count > 3 })
        let order = display.state.upNext.map(\.id)
        #expect(display.move(order[3], after: nil))
        #expect(display.state.upNext.first?.id == order[3])
        // The hub refuses (reordering off); the display goes back to the hub's order.
        #expect(await waitFor { display.state.upNext.map(\.id) == order })
        #expect(hub.state.upNext.map(\.id) == order)
    }

    @Test func txtRecordFormat() {
        let data = ZoneAdvertiser.txtRecord(["name": "Up", "kind": "tv"])
        // Sorted: kind=tv, name=Up — each prefixed by its length.
        #expect(Array(data) == [7] + Array("kind=tv".utf8) + [7] + Array("name=Up".utf8))
    }
}

@MainActor
@Suite struct PortFallbackTests {
    /// Two hubs on one machine (or simulators sharing a Mac): the second falls back to the next port.
    @Test(.timeLimit(.minutes(1))) func secondServerFallsBack() async throws {
        let first = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        let (server1, task1) = try #require(await PartyServer.start(session: first, ports: [18781]))
        defer { task1.cancel(); Task { await server1.stop() } }
        let second = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        let started = Date()
        let result = await PartyServer.start(session: second, ports: [18781, 18782])
        let (server2, task2) = try #require(result)
        defer { task2.cancel(); Task { await server2.stop() } }
        #expect(server2.port == 18782)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

/// Hub settings changed from the web page (an Apple TV has no settings screens of its own).
@MainActor
@Suite(.serialized)
struct HostSettingsTests {
    func post(_ port: UInt16, _ path: String, _ body: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func track() throws -> [String: Any] {
        let data = try JSONEncoder.api.encode(DemoCatalog.track(21))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func queueingOffBlocksGuestsNotHosts() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.configureHub(kind: .tv, zoneName: "Living Room", serviceName: "Demo")
        hub.hostKey = "secret"
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18791]))
        defer { task.cancel(); Task { await server.stop() } }

        let (off, _) = try await post(18791, "/api/host/settings", ["key": "secret", "phonesCanQueue": false])
        #expect(off == 200)
        #expect(!hub.phonesCanQueue)
        #expect(hub.snapshot().canQueue == false)
        let (guest, _) = try await post(18791, "/api/add", ["track": try track(), "clientId": "guest"])
        #expect(guest == 403)
        let (host, _) = try await post(18791, "/api/add", ["track": try track(), "clientId": "host", "key": "secret"])
        #expect(host == 200)
        let (display, _) = try await post(18791, "/api/add", ["track": try track(), "clientId": "kitchen", "origin": "ipad"])
        #expect(display == 200)
    }

    /// The playlist past the live Up Next comes a page at a time, to the web page and to displays.
    @Test func upcomingPages() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        let big = try #require(try await DemoCatalog().libraryPlaylists().first { $0.id == "demo-big" })
        try await hub.load(playlist: big)
        try await hub.play()
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18796]))
        defer { task.cancel(); Task { await server.stop() } }

        let expectedTotal = DemoCatalog.bigTracks.count - 1 - QueueState.playlistWindow
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18796/api/upcoming?offset=0&limit=500")!)
        let page = try JSONDecoder.api.decode(UpcomingPage.self, from: data)
        #expect(page.total == expectedTotal)
        #expect(page.rows.count == 100) // capped
        #expect(page.rows.first?.trackID == DemoCatalog.bigTracks[QueueState.playlistWindow + 1].id)
        #expect(page.playlistName == "Big party")
        #expect(!String(decoding: data, as: UTF8.self).contains("colors")) // compact rows

        // Snapshots stay the live window only.
        #expect(hub.snapshot().upNext.count == QueueState.playlistWindow)

        // A display asks its hub.
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18796")!, clientID: "kitchen", name: "Kitchen iPad", kind: .ipad)
        let display = PartySession(remote: connection)
        let remote = try await display.upcoming(offset: 50, limit: 50)
        #expect(remote.total == expectedTotal)
        #expect(remote.rows.map(\.trackID) == page.rows[50..<100].map(\.trackID))
    }

    /// Hosts can list the library and search the service's playlists; guests can't.
    @Test func hostPlaylistSearch() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.hostKey = "secret"
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18797]))
        defer { task.cancel(); Task { await server.stop() } }

        let base = "http://127.0.0.1:18797/api/host/playlists"
        let (_, refused) = try await URLSession.shared.data(from: URL(string: "\(base)/search?key=nope&q=disco")!)
        #expect((refused as? HTTPURLResponse)?.statusCode == 403)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(base)/search?key=secret&q=disco")!)
        let found = try JSONDecoder.api.decode([PlaylistSummary].self, from: data)
        #expect(found.first?.name == "disco mix")
        let (library, _) = try await URLSession.shared.data(from: URL(string: "\(base)?key=secret")!)
        #expect(try JSONDecoder.api.decode([PlaylistSummary].self, from: library).contains { $0.id == "demo-big" })
    }

    /// Any hub (iPad or TV) can be stopped from the web page, by hosts only.
    @Test func onlyHostsStopTheZone() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.configureHub(kind: .ipad, id: "ipad-1", zoneName: "Upstairs", serviceName: "Demo")
        hub.hostKey = "secret"
        var stops = 0
        hub.onStopRequested = { stops += 1 }
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18795]))
        defer { task.cancel(); Task { await server.stop() } }

        let (refused, _) = try await post(18795, "/api/host/stop", ["key": "nope"])
        #expect(refused == 403)
        #expect(stops == 0)
        let (code, _) = try await post(18795, "/api/host/stop", ["key": "secret"])
        #expect(code == 200)
        #expect(stops == 1)
    }

    @Test func wifiIsHostOnly() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.hostKey = "secret"
        hub.noteDisplay(ZoneDisplay(id: "kitchen", name: "Kitchen iPad", kind: .ipad))
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18794]))
        defer { task.cancel(); Task { await server.stop() } }

        let (code, _) = try await post(18794, "/api/host/settings", [
            "key": "secret", "wifi": ["ssid": "Party", "password": "hunter22", "simpleQR": true],
        ])
        #expect(code == 200)
        #expect(hub.wifi == WifiDetails(ssid: "Party", password: "hunter22", simpleQR: true))
        // Guests never get it.
        let state = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18794/api/state")!).0
        #expect(!String(decoding: state, as: UTF8.self).contains("hunter22"))
        // Hosts do, with the connected displays.
        let (refused, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18794/api/host/details?key=nope")!)
        #expect(refused.isEmpty)
        let (details, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18794/api/host/details?key=secret")!)
        let text = String(decoding: details, as: UTF8.self)
        #expect(text.contains("hunter22") && text.contains("Kitchen iPad"))
    }

    @Test func forgettingHostsGivesTheAskerANewKey() async throws {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.hostKey = "old"
        hub.onForgetHostPhones = { hub.hostKey = "new"; return "new" }
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18793]))
        defer { task.cancel(); Task { await server.stop() } }

        let (code, data) = try await post(18793, "/api/host/forget", ["key": "old"])
        #expect(code == 200)
        #expect(try JSONDecoder().decode([String: String].self, from: data)["key"] == "new")
        let (again, _) = try await post(18793, "/api/host/forget", ["key": "old"])
        #expect(again == 403)
    }
}

struct LocalNameTests {
    @Test func followsTheZoneName() {
        #expect(FriendlyHostname.localName(forZone: "Living Room") == "living-room")
        #expect(FriendlyHostname.localName(forZone: "Naren's Living Room") == "narens-living-room")
        #expect(FriendlyHostname.localName(forZone: "Café  Upstairs!") == "cafe-upstairs")
        #expect(FriendlyHostname.localName(forZone: "Rock & Roll") == "rock-roll")
        #expect(FriendlyHostname.localName(forZone: "  -Den- ") == "den")
        #expect(FriendlyHostname.localName(forZone: "Kitchen 2") == "kitchen-2")
    }

    @Test func fallsBackToMusic() {
        #expect(FriendlyHostname.localName(forZone: nil) == "music")
        #expect(FriendlyHostname.localName(forZone: "") == "music")
        #expect(FriendlyHostname.localName(forZone: "🎉🎉") == "music")
    }

    @Test func fitsInADNSLabel() {
        let name = FriendlyHostname.localName(forZone: String(repeating: "ab ", count: 40))
        #expect(name.count <= 63)
        #expect(!name.hasSuffix("-"))
    }

    @Test func renamingChangesTheName() {
        let hostname = FriendlyHostname(name: "upstairs")
        hostname.rename(to: "living-room")
        #expect(hostname.hostname == "living-room.local")
    }
}
