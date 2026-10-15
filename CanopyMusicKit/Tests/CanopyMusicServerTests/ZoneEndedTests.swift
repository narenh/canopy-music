@testable import CanopyMusicCore
@testable import CanopyMusicServer
import FlyingFox
import Foundation
import Testing

/// Seen on real devices: a TV showing an iPad's zone sat on "Reconnecting" for ever after the
/// zone was ended. A hub ending its zone now says so on every socket before it stops; a display
/// whose hub vanished without a goodbye gives up once the zone has left the zone list too.
@MainActor
@Suite(.serialized)
struct ZoneEndedTests {
    func makeHub(port: UInt16) async throws -> (PartySession, PartyServer, Task<Void, Error>) {
        let hub = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        hub.configureHub(kind: .ipad, id: "ipad-1", zoneName: "Upstairs", serviceName: "Demo")
        let playlist = try #require(try await DemoCatalog().libraryPlaylists().first)
        try await hub.load(playlist: playlist)
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [port]))
        return (hub, server, task)
    }

    func waitFor(_ condition: @MainActor () -> Bool, timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    final class Inbox {
        var texts: [String] = []
        var closed = false
    }

    /// A phone's page on the hub's socket: what it's sent, until the socket closes.
    func phone(port: UInt16) -> (Inbox, URLSessionWebSocketTask) {
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.resume()
        let inbox = Inbox()
        Task { @MainActor in
            while true {
                guard let message = try? await task.receive() else { break }
                if case .string(let text) = message { inbox.texts.append(text) }
            }
            inbox.closed = true
        }
        return (inbox, task)
    }

    @Test func endingTheZoneSaysGoodbyeBeforeTheServerStops() async throws {
        let (hub, server, task) = try await makeHub(port: 18901)
        defer { task.cancel() }
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18901")!, clientID: "tv", name: "Bedroom", kind: .tv)
        var endings: [ZoneConnection.Ending] = []
        connection.onEnding = { endings.append($0) }
        let display = PartySession(remote: connection)
        connection.start(session: display)
        defer { connection.stop() }
        let (page, socket) = phone(port: 18901)
        defer { socket.cancel() }
        #expect(await waitFor { connection.isConnected && !page.texts.isEmpty })

        // As End Zone does: the goodbye first, then the queue is cleared, then the server stops.
        server.sayGoodbye()
        hub.end()
        let started = Date()
        await server.end()
        // Each socket sent it and closed, well inside the cap.
        #expect(Date().timeIntervalSince(started) < 1)

        #expect(await waitFor { page.closed })
        #expect(page.texts.last == ZoneMessage.ended)
        // Nothing after the goodbye: the cleared queue never reached the page.
        #expect(page.texts.filter { $0 == ZoneMessage.ended }.count == 1)
        let snapshots = page.texts.dropLast().compactMap { try? JSONDecoder.api.decode(PartySnapshot.self, from: Data($0.utf8)) }
        #expect(snapshots.count == page.texts.count - 1)
        #expect(snapshots.allSatisfy { $0.playlistName != nil })

        #expect(await waitFor { connection.ending == .ended })
        #expect(endings == [.ended])
        #expect(!connection.isConnected)
        // Its last snapshot stays (the app leaves the zone at once).
        #expect(display.zoneName == "Upstairs")
    }

    /// Quitting (or the server restarting after the background) isn't ending: no goodbye, and a
    /// display carries on trying.
    @Test func aPlainStopSaysNoGoodbye() async throws {
        let (_, server, task) = try await makeHub(port: 18902)
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18902")!, clientID: "tv", name: "Bedroom", kind: .tv)
        let display = PartySession(remote: connection)
        connection.start(session: display)
        defer { connection.stop() }
        let (page, socket) = phone(port: 18902)
        defer { socket.cancel() }
        #expect(await waitFor { connection.isConnected && !page.texts.isEmpty })

        task.cancel()
        await server.stop()
        #expect(await waitFor { !connection.isConnected })
        #expect(await waitFor { page.closed })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(connection.ending == nil)
        #expect(!page.texts.contains(ZoneMessage.ended))
    }

    /// Displays from before the message can't read it as a snapshot, so they skip it and see the
    /// socket close, as before.
    @Test func olderDisplaysSkipTheGoodbye() {
        #expect((try? JSONDecoder.api.decode(PartySnapshot.self, from: Data(ZoneMessage.ended.utf8))) == nil)
        #expect(ZoneMessage.isEnded(ZoneMessage.ended))
        let snapshot = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine()).snapshot()
        let text = try? String(decoding: JSONEncoder.api.encode(snapshot), as: UTF8.self)
        #expect(text.map(ZoneMessage.isEnded) == false)
    }

    /// A page that connects between the goodbye and the server stopping is told at once.
    @Test func aSocketOpenedAfterTheGoodbyeIsToldAtOnce() async throws {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        let sockets = OpenSockets()
        let encoder = SnapshotEncoder()

        func connect() async throws -> (Inbox, AsyncStream<WSMessage>.Continuation) {
            let (client, end) = AsyncStream.makeStream(of: WSMessage.self)
            let messages = try await SnapshotSocket(session: session, encoder: encoder, sockets: sockets).makeMessages(for: client)
            let inbox = Inbox()
            Task { @MainActor in
                for await message in messages {
                    switch message {
                    case .text(let text): inbox.texts.append(text)
                    case .close: inbox.closed = true
                    case .data: break
                    }
                }
            }
            return (inbox, end)
        }

        let (early, end1) = try await connect()
        defer { end1.finish() }
        #expect(await waitFor { early.texts.count == 1 })
        #expect(sockets.count == 1)
        sockets.sayGoodbye()
        #expect(await waitFor { early.closed })
        #expect(early.texts.last == ZoneMessage.ended)
        #expect(sockets.count == 0)

        let (late, end2) = try await connect()
        defer { end2.finish() }
        #expect(await waitFor { late.closed })
        #expect(late.texts == [ZoneMessage.ended])
        #expect(sockets.count == 0)
    }

    // MARK: The backstop

    @Test func theRule() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        var rule = HubVanishing()
        func gone(listed: Bool, at seconds: TimeInterval) -> Bool { rule.isGone(listed: listed, at: at(seconds)) }

        // Disconnected for ages, but still listed (restarting, or Bonjour hasn't caught up): stays.
        rule.disconnected(at: at(0))
        #expect(!gone(listed: true, at: 120))

        // Unlisted for a moment while the hub announces again after the background: stays.
        #expect(!gone(listed: false, at: 122))
        #expect(!gone(listed: false, at: 125))
        #expect(!gone(listed: true, at: 126))
        #expect(!gone(listed: false, at: 130))
        #expect(!gone(listed: false, at: 139))
        // Unlisted for 10 s without a break, and disconnected well over 25 s: gone.
        #expect(gone(listed: false, at: 140))

        // Unlisted from the start (a crash takes the announcement with it): 25 s disconnected.
        rule = HubVanishing()
        rule.disconnected(at: at(0))
        #expect(!gone(listed: false, at: 2))
        #expect(!gone(listed: false, at: 24))
        #expect(gone(listed: false, at: 25))

        // Reconnected meanwhile: the 25 s start over.
        rule = HubVanishing()
        rule.disconnected(at: at(0))
        #expect(!gone(listed: false, at: 20))
        rule.connected()
        rule.disconnected(at: at(22))
        #expect(!gone(listed: false, at: 40))
        #expect(gone(listed: false, at: 47))

        // Resting in the background: nothing from before counts.
        rule = HubVanishing()
        rule.disconnected(at: at(0))
        #expect(!gone(listed: false, at: 5))
        rule.startOver()
        rule.disconnected(at: at(300))
        #expect(!gone(listed: false, at: 301))
        #expect(!gone(listed: false, at: 320))
        #expect(gone(listed: false, at: 325))
    }

    @MainActor
    final class FakeZoneList: ZoneList {
        var zones: [ZoneListing] = []
    }

    @MainActor
    final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// A display on a hub that's gone (nothing answers on 18909), with a fake zone list and clock.
    func vanishedHub(listed: Bool) -> (ZoneConnection, FakeZoneList, FakeClock, ZoneListing, PartySession) {
        let zone = ZoneListing(id: "Upstairs", name: "Upstairs", kind: .ipad, address: "127.0.0.1:18909", hubID: "ipad-1")
        let list = FakeZoneList()
        if listed { list.zones = [ZoneListing(id: "Kitchen", name: "Kitchen", kind: .tv, address: "10.0.0.9", hubID: "tv-9"), zone] }
        let clock = FakeClock()
        let connection = ZoneConnection(baseURL: zone.baseURL!, clientID: "tv", name: "Bedroom", kind: .tv)
        connection.now = { clock.now }
        connection.isOnNetwork = { true }
        let display = PartySession(remote: connection)
        connection.start(session: display, listing: zone, in: list)
        return (connection, list, clock, zone, display)
    }

    @Test func aDisplayLeavesOnceItsHubHasGoneFromTheList() async {
        let (connection, list, clock, zone, _) = vanishedHub(listed: true)
        defer { connection.stop() }
        var endings: [ZoneConnection.Ending] = []
        connection.onEnding = { endings.append($0) }

        // Still listed, however long it's been: it keeps trying.
        clock.advance(90)
        connection.checkHub()
        #expect(connection.ending == nil)

        // Gone from the list (as a renamed zone that's still this hub isn't).
        list.zones = [ZoneListing(id: "Upstairs Den", name: "Upstairs Den", kind: .ipad, address: zone.address, hubID: "ipad-1")]
        clock.advance(20)
        connection.checkHub()
        #expect(connection.ending == nil)
        list.zones = []
        connection.checkHub()
        clock.advance(9)
        connection.checkHub()
        #expect(connection.ending == nil)
        clock.advance(1)
        connection.checkHub()
        #expect(connection.ending == .vanished)
        #expect(endings == [.vanished])
        #expect(!connection.isConnected)
    }

    @Test func restingIsntTheHubGoing() async {
        // The connection holds its session weakly: kept here, as the app does.
        let (connection, _, clock, _, display) = vanishedHub(listed: false)
        defer { connection.stop(); withExtendedLifetime(display) {} }
        connection.checkHub()
        clock.advance(5)
        connection.suspend()
        // In the background for a long while: nothing is decided there.
        clock.advance(600)
        connection.checkHub()
        #expect(connection.ending == nil)

        // Back: the hub gets its 25 s from now.
        connection.resume()
        connection.checkHub()
        clock.advance(24)
        connection.checkHub()
        #expect(connection.ending == nil)
        clock.advance(1)
        connection.checkHub()
        #expect(connection.ending == .vanished)
    }

    @Test func offTheNetworkNothingIsDecided() async {
        let (connection, _, clock, _, _) = vanishedHub(listed: false)
        defer { connection.stop() }
        connection.isOnNetwork = { false }
        clock.advance(120)
        connection.checkHub()
        #expect(connection.ending == nil)
        // Back on the Wi‑Fi: the zone list gets its 10 s, and the hub its 25 s, from now.
        connection.isOnNetwork = { true }
        connection.checkHub()
        clock.advance(24)
        connection.checkHub()
        #expect(connection.ending == nil)
        clock.advance(1)
        connection.checkHub()
        #expect(connection.ending == .vanished)
    }

    /// Without a zone list (`-joinAddress`, tests), a display never gives up by itself.
    @Test func withoutAListItKeepsTrying() async {
        let clock = FakeClock()
        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18909")!, clientID: "tv", name: "Bedroom", kind: .tv)
        connection.now = { clock.now }
        connection.isOnNetwork = { true }
        connection.start(session: PartySession(remote: connection))
        defer { connection.stop() }
        clock.advance(600)
        connection.checkHub()
        #expect(connection.ending == nil)
    }
}
