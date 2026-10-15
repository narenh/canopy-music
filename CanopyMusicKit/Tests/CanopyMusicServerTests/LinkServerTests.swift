@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// Links through the phone server: `POST /api/link` (looked up for one phone's results),
/// `POST /api/add` of a link (the hub fills its audio in), what snapshots carry (never the
/// token, never a link's signed audio address), and an Apple TV's `POST /api/host/links`.
@MainActor
@Suite(.serialized) struct LinkServerTests {
    /// cmdlp without a network: every link one track, pending when looked up and then as
    /// `status` says (ready: already downloaded), the lookup as slow as asked.
    @MainActor
    final class Links: LinkService {
        var lookupDelay: Duration = .zero
        var refusal: CmdlpError?
        var status: LinkTrack.Status = .ready
        private(set) var resolved: [String] = []
        private(set) var normalized: [Bool] = []

        static let track = CmdlpTrack(id: "L1L1L1L1L1L1L1L1L1L1L1", zone: "zone-1", status: .pending, title: "Pasted", artist: "Uploader",
                                      duration: 180, artwork: "https://i.ytimg.com/vi/x/hqdefault.jpg", service: "YouTube", stage: "queued",
                                      audioUrl: "https://cmdlp.example/audio/L1L1L1L1L1L1L1L1L1L1L1.m4a?sig=TOPSECRETSIG")

        func resolve(_ url: String, zone: String, normalize: Bool) async throws -> CmdlpTrack {
            resolved.append(url)
            normalized.append(normalize)
            if lookupDelay > .zero { try await Task.sleep(for: lookupDelay) }
            if let refusal { throw refusal }
            return Self.track
        }

        func track(id: String) async throws -> CmdlpTrack {
            var track = Self.track
            track.status = status
            if status == .pending { track.progress = .init(percent: 37) }
            if status == .failed { track.error = "ERROR: [youtube] abc: Video unavailable" }
            return track
        }
        func deleteZone(_ zone: String) async throws {}
    }

    final class Setup: HubSetupHandler {
        var links: [(address: String?, token: String?, forget: Bool, normalize: Bool?)] = []
        func chooseService(_ service: String) -> Bool { true }
        func setSpotifyClientID(_ clientID: String) {}
        func setSpotifySignInPage(_ typed: String) async -> SpotifyRelay.PageCheck { .ok }
        func chooseSpotifyDevice(id: String) -> Bool { true }
        func checkSpotifyConflict() async -> String? { nil }
        func joinSpotifyConflict() -> String? { nil }
        func setLinks(address: String?, token: String?, forgetToken: Bool, normalize: Bool?) -> Bool {
            links.append((address, token, forgetToken, normalize))
            return true
        }
    }

    struct Hub {
        let session: PartySession
        let links: Links
        let server: PartyServer
        let task: Task<Void, Error>
        let base: String

        func stop() async {
            task.cancel()
            await server.stop()
        }
    }

    /// A hub whose engine plays links (`playsLinks`), or doesn't (Spotify Connect).
    func hub(port: UInt16, playsLinks: Bool = true, configured: Bool = true) async throws -> Hub {
        let engine: any PlaybackEngine = playsLinks
            ? LinkHandoffEngine(music: DemoPlaybackEngine(), links: DemoPlaybackEngine()) : DemoPlaybackEngine()
        let session = PartySession(catalog: DemoCatalog(), engine: engine)
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        session.hostKey = "secret"
        let links = Links()
        if configured {
            session.linkZone = "zone-1"
            session.linkService = links
        }
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        return Hub(session: session, links: links, server: server, task: task, base: "http://127.0.0.1:\(port)")
    }

    func post(_ url: String, _ body: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: try #require(URL(string: url)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func text(_ url: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: try #require(URL(string: url)))
        return String(decoding: data, as: UTF8.self)
    }

    /// The first snapshot a socket gets.
    func firstSnapshot(_ url: String) async throws -> String {
        let socket = URLSession.shared.webSocketTask(with: try #require(URL(string: url)))
        socket.resume()
        defer { socket.cancel() }
        guard case .string(let text) = try await socket.receive() else { return "" }
        return text
    }

    func error(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
    }

    @Test func aPastedLinkComesBackAsOneSongWithoutItsAudio() async throws {
        let hub = try await hub(port: 18951)
        defer { Task { await hub.stop() } }
        let (status, data) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1"])
        #expect(status == 200)
        let track = try JSONDecoder().decode(QueueTrack.self, from: data)
        #expect(track.id == "link:L1L1L1L1L1L1L1L1L1L1L1")
        #expect(track.title == "Pasted")
        #expect(track.link?.service == "YouTube")
        #expect(!String(decoding: data, as: UTF8.self).contains("TOPSECRETSIG"))

        // Picked (already downloaded): queued, and the hub (only) has its audio.
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let (added, reply) = try await post("\(hub.base)/api/add", ["track": body, "clientId": "phone-1", "name": "Sam"])
        #expect(added == 200)
        #expect(String(decoding: reply, as: UTF8.self).contains("\"added\""))
        #expect(hub.session.state.upNext.first?.track.link?.audioURL?.absoluteString.contains("TOPSECRETSIG") == true)

        // Every kind of snapshot: the song, never its signed address.
        for snapshot in [try await text("\(hub.base)/api/state"),
                         try await firstSnapshot("ws://127.0.0.1:18951/ws"),
                         try await firstSnapshot("ws://127.0.0.1:18951/ws?display=1"),
                         try await firstSnapshot("ws://127.0.0.1:18951/ws?key=secret")] {
            #expect(snapshot.contains("link:L1L1L1L1L1L1L1L1L1L1L1"))
            #expect(snapshot.contains("\"links\":true"))
            #expect(!snapshot.contains("TOPSECRETSIG"))
            #expect(!snapshot.contains("/audio/"))
        }
    }

    /// A phone's made-up audio address isn't taken: the hub's own record is.
    @Test func aPhonesAudioAddressIsIgnored() async throws {
        let hub = try await hub(port: 18952)
        defer { Task { await hub.stop() } }
        var track = Links.track.queueTrack
        track.link?.audioURL = URL(string: "https://evil.example/song.m4a")
        let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        let (status, _) = try await post("\(hub.base)/api/add", ["track": body, "clientId": "phone-1"])
        #expect(status == 200)
        #expect(hub.session.state.upNext.first?.track.link?.audioURL?.host() == "cmdlp.example")
    }

    /// Still downloading: `/api/add` says "preparing" with its progress, which only the phones
    /// that added it can follow (`/api/link/progress`), and it's queued once it's ready.
    @Test func aLinkStillDownloadingIsPreparedForItsPhone() async throws {
        let hub = try await hub(port: 18959)
        defer { Task { await hub.stop() } }
        hub.links.status = .pending
        hub.session.linkPollInterval = .milliseconds(20)
        let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Links.track.queueTrack.forGuests)) as? [String: Any])
        let (status, data) = try await post("\(hub.base)/api/add", ["track": body, "clientId": "phone-1", "name": "Sam"])
        #expect(status == 200)
        let reply = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(reply["result"] as? String == "preparing")
        let progress = try #require(reply["progress"] as? [String: Any])
        #expect(progress["id"] as? String == "link:L1L1L1L1L1L1L1L1L1L1L1")
        #expect(progress["percent"] as? Int == 37)
        #expect(progress["takesLong"] as? Bool == false)
        #expect(hub.session.state.upNext.isEmpty)
        #expect(!(try await text("\(hub.base)/api/state")).contains("L1L1L1"))

        let (_, mine) = try await post("\(hub.base)/api/link/progress", ["clientId": "phone-1"])
        let following = try JSONDecoder().decode(LinkProgressReply.self, from: mine)
        #expect(following.preparing.map(\.id) == ["link:L1L1L1L1L1L1L1L1L1L1L1"])
        let (_, theirs) = try await post("\(hub.base)/api/link/progress", ["clientId": "phone-2"])
        #expect(try JSONDecoder().decode(LinkProgressReply.self, from: theirs) == LinkProgressReply(preparing: [], failed: []))

        hub.links.status = .ready
        for _ in 0..<100 where hub.session.state.upNext.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hub.session.state.upNext.first?.track.id == "link:L1L1L1L1L1L1L1L1L1L1L1")
        #expect(hub.session.state.upNext.first?.requester?.clientID == "phone-1")
        let (_, done) = try await post("\(hub.base)/api/link/progress", ["clientId": "phone-1"])
        #expect(try JSONDecoder().decode(LinkProgressReply.self, from: done) == LinkProgressReply(preparing: [], failed: []))
    }

    /// One that fails: the phone that added it hears so once, in plain words; Up Next is untouched.
    @Test func aFailedPreparationIsToldToItsPhoneOnce() async throws {
        let hub = try await hub(port: 18960)
        defer { Task { await hub.stop() } }
        hub.links.status = .pending
        hub.session.linkPollInterval = .milliseconds(20)
        let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Links.track.queueTrack.forGuests)) as? [String: Any])
        _ = try await post("\(hub.base)/api/add", ["track": body, "clientId": "phone-1"])
        hub.links.status = .failed
        for _ in 0..<100 where !hub.session.linkPreparations.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let (_, first) = try await post("\(hub.base)/api/link/progress", ["clientId": "phone-1"])
        let told = try JSONDecoder().decode(LinkProgressReply.self, from: first)
        #expect(told.failed.map(\.text) == ["Couldn’t add “Pasted”"])
        #expect(!String(decoding: first, as: UTF8.self).contains("ERROR"))
        let (_, again) = try await post("\(hub.base)/api/link/progress", ["clientId": "phone-1"])
        #expect(try JSONDecoder().decode(LinkProgressReply.self, from: again).failed.isEmpty)
        #expect(hub.session.state.upNext.isEmpty)
    }

    @Test func refusalsSayWhyToThePhone() async throws {
        let hub = try await hub(port: 18953)
        defer { Task { await hub.stop() } }
        hub.links.refusal = CmdlpError(status: 422, reason: "live", message: "That's a live stream.")
        let (status, data) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/live", "clientId": "phone-1"])
        #expect(status == 409)
        #expect(error(data) == "That's a live stream.")

        let spotify = try await self.hub(port: 18954, playsLinks: false)
        defer { Task { await spotify.stop() } }
        let (refused, reason) = try await post("\(spotify.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1"])
        #expect(refused == 409)
        #expect(error(reason) == "Zone player does not support direct audio.")
        #expect(spotify.links.resolved.isEmpty)
        // Adding one anyway (an older page) is refused the same way.
        let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Links.track.queueTrack.forGuests)) as? [String: Any])
        let (add, addReason) = try await post("\(spotify.base)/api/add", ["track": body, "clientId": "phone-1"])
        #expect(add == 409)
        #expect(error(addReason) == "Zone player does not support direct audio.")
    }

    /// Not set up: nothing says links exist, and a pasted link is just a search.
    @Test func withoutCmdlpLinksDontExist() async throws {
        let hub = try await hub(port: 18955, configured: false)
        defer { Task { await hub.stop() } }
        let state = try await text("\(hub.base)/api/state")
        #expect(!state.contains("\"links\""))
        let (status, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1"])
        #expect(status == 409)
        #expect(hub.links.resolved.isEmpty)
    }

    /// A slow lookup answers 202 until it's done; asking again joins it.
    @Test func aSlowLookupAnswersLater() async throws {
        let hub = try await hub(port: 18956)
        defer { Task { await hub.stop() } }
        hub.links.lookupDelay = .milliseconds(800)
        hub.session.linkLookupWait = 0.2
        let (first, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/slow", "clientId": "phone-1"])
        #expect(first == 202)
        try await Task.sleep(for: .seconds(1))
        let (second, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/slow", "clientId": "phone-1"])
        #expect(second == 200)
        #expect(hub.links.resolved.count == 1)
    }

    /// Queueing from phones off: guests can't paste links either; hosts can.
    @Test func queueingOffStopsGuestsNotHosts() async throws {
        let hub = try await hub(port: 18957)
        defer { Task { await hub.stop() } }
        hub.session.phonesCanQueue = false
        let (guest, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1"])
        #expect(guest == 403)
        let (host, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1", "key": "secret"])
        #expect(host == 200)
    }

    /// An Apple TV's links, from a host's settings sheet: hosts only, and the token never comes
    /// back, only its last four characters.
    @Test func aTVsLinkSettingsAreHostsOnly() async throws {
        let hub = try await hub(port: 18958)
        defer { Task { await hub.stop() } }
        let setup = Setup()
        hub.session.setupHandler = setup
        let (denied, _) = try await post("\(hub.base)/api/host/links", ["key": "wrong", "address": "https://x.example", "token": "cmdlp_abcd1234"])
        #expect(denied == 403)
        let (status, _) = try await post("\(hub.base)/api/host/links", ["key": "secret", "address": "https://cmdlp.example", "token": "cmdlp_abcd1234"])
        #expect(status == 204)
        #expect(setup.links.first?.token == "cmdlp_abcd1234")
        #expect(setup.links.first?.address == "https://cmdlp.example")
        hub.session.linkSetup = LinkSetup(address: "https://cmdlp.example", tokenHint: LinkTokenHint.of("cmdlp_abcd1234"), status: "Connected.")
        let host = try await firstSnapshot("ws://127.0.0.1:18958/ws?key=secret")
        #expect(host.contains("\"tokenHint\":\"1234\""))
        #expect(!host.contains("cmdlp_abcd1234"))
        let guest = try await firstSnapshot("ws://127.0.0.1:18958/ws")
        #expect(!guest.contains("linkSetup"))
        let display = try await firstSnapshot("ws://127.0.0.1:18958/ws?display=1")
        #expect(!display.contains("linkSetup"))
        let (forget, _) = try await post("\(hub.base)/api/host/links", ["key": "secret", "forgetToken": true])
        #expect(forget == 204)
        #expect(setup.links.last?.forget == true)
        #expect(setup.links.allSatisfy { $0.normalize == nil })
    }

    /// An Apple TV's "Normalize audio", from a host's settings sheet: on its own, the address
    /// and token untouched; hosts' snapshots say which it is.
    @Test func aTVsNormalizeSettingComesFromHosts() async throws {
        let hub = try await hub(port: 18961)
        defer { Task { await hub.stop() } }
        let setup = Setup()
        hub.session.setupHandler = setup
        let (denied, _) = try await post("\(hub.base)/api/host/links", ["key": "wrong", "normalize": false])
        #expect(denied == 403)
        #expect(setup.links.isEmpty)
        let (off, _) = try await post("\(hub.base)/api/host/links", ["key": "secret", "normalize": false])
        #expect(off == 204)
        let (on, _) = try await post("\(hub.base)/api/host/links", ["key": "secret", "normalize": true])
        #expect(on == 204)
        #expect(setup.links.map(\.normalize) == [false, true])
        #expect(setup.links.allSatisfy { $0.address == nil && $0.token == nil && !$0.forget })
        hub.session.linkSetup = LinkSetup(address: "https://cmdlp.example", tokenHint: "1234", normalize: false)
        let host = try await firstSnapshot("ws://127.0.0.1:18961/ws?key=secret")
        #expect(host.contains("\"normalize\":false"))
    }

    /// The hub's setting goes with each phone's lookup.
    @Test func aPhonesLookupCarriesTheHubsNormalizeSetting() async throws {
        let hub = try await hub(port: 18962)
        defer { Task { await hub.stop() } }
        hub.session.linkNormalize = false
        let (status, _) = try await post("\(hub.base)/api/link", ["url": "https://youtu.be/abc", "clientId": "phone-1"])
        #expect(status == 200)
        #expect(hub.links.normalized == [false])
    }
}
