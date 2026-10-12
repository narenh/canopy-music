@testable import CanopyCore
@testable import CanopyServer
import Foundation
import Testing

/// A real hub server and a display mirroring it over HTTP + WebSocket on localhost.
@MainActor
@Suite(.serialized)
struct ZoneTests {
    func makeHub(port: UInt16) async throws -> (PartySession, PartyServer, Task<Void, Error>) {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.configureHub(kind: .tv, zoneName: "Living Room", serviceName: "Demo")
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
