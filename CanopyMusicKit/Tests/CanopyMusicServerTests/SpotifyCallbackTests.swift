@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import Testing

/// An Apple TV's Spotify sign-in: the phone asks the TV for Spotify's page, and the relay sends
/// the phone back to `/spotify/callback`, which answers only while that sign-in is pending.
@MainActor
@Suite(.serialized) struct SpotifyCallbackTests {
    final class FakeSetup: HubSetupHandler {
        var service = "appleMusic"
        func chooseService(_ service: String) -> Bool { self.service = service; return true }
        func setSpotifyClientID(_ clientID: String) {}
        func setSpotifySignInPage(_ typed: String) async -> SpotifyRelay.PageCheck { .ok }
        func chooseSpotifyDevice(id: String) -> Bool { true }
        func joinSpotifyConflict() -> String? { nil }
    }

    @MainActor struct TV {
        let session: PartySession
        let signIn: SpotifyHubSignIn
        let setup: FakeSetup
        let server: PartyServer
        let task: Task<Void, Error>
        let base: String
        var exchanged: () -> [String]

        func stop() async {
            task.cancel()
            await server.stop()
        }
    }

    func makeTV(port: UInt16, page: String = SpotifyRelay.defaultPage) async throws -> TV {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Spotify")
        session.hostKey = "secret"
        session.lanAddress = "192.168.1.20:\(port)"
        let signIn = SpotifyHubSignIn()
        signIn.configuration = { (clientID: "client", redirectURI: page) }
        final class Box { var codes: [String] = [] }
        let box = Box()
        signIn.exchange = { _, code in box.codes.append(code) }
        session.spotifySignIn = signIn
        let setup = FakeSetup()
        session.setupHandler = setup
        let (server, task) = try #require(await PartyServer.start(session: session, ports: [port]))
        return TV(session: session, signIn: signIn, setup: setup, server: server, task: task,
                  base: "http://127.0.0.1:\(port)", exchanged: { box.codes })
    }

    func get(_ url: String) async throws -> (Int, URL?) {
        let (_, response) = try await URLSession.shared.data(from: try #require(URL(string: url)))
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, http.url)
    }

    func post(_ url: String, _ body: [String: Any]) async throws -> (Int, Data) {
        var request = URLRequest(url: try #require(URL(string: url)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Starts a sign-in as the setup page does; returns its `state`.
    func startSignIn(_ tv: TV) async throws -> String {
        let (status, data) = try await post("\(tv.base)/api/host/spotify/sign-in", ["key": "secret"])
        #expect(status == 200)
        let url = try signInURL(data)
        return try #require(SpotifySignInRequest.query(of: url)["state"])
    }

    func signInURL(_ data: Data) throws -> URL {
        let reply = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let text = try #require(reply["url"])
        return try #require(URL(string: text))
    }

    @Test func closedUnlessASignInIsPending() async throws {
        let tv = try await makeTV(port: 18801)
        let request = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .tv, host: "192.168.1.20")
        let (status, _) = try await get("\(tv.base)/spotify/callback?code=abc&state=\(request.state)")
        #expect(status == 404)
        #expect(tv.exchanged().isEmpty)
        await tv.stop()
    }

    @Test func onlyHostsStartASignIn() async throws {
        let tv = try await makeTV(port: 18802)
        let (status, _) = try await post("\(tv.base)/api/host/spotify/sign-in", ["key": "nope"])
        #expect(status == 403)
        #expect(!tv.signIn.isPending)
        await tv.stop()
    }

    @Test func signInUsesTheSettingAndTheTVsAddress() async throws {
        let page = "https://naren.github.io/canopy-music-relay/spotify"
        let tv = try await makeTV(port: 18803, page: page)
        let (status, data) = try await post("\(tv.base)/api/host/spotify/sign-in", ["key": "secret"])
        #expect(status == 200)
        let query = SpotifySignInRequest.query(of: try signInURL(data))
        #expect(query["redirect_uri"] == page)
        // The test reaches it at 127.0.0.1, which the relay won't forward to: its LAN address.
        let sent = try #require(query["state"])
        let state = try #require(SpotifyRelay.decode(sent))
        #expect(state.to == .tv && state.host == "192.168.1.20" && state.port == 18803)
        #expect(state.n == tv.signIn.pending?.nonce)
        await tv.stop()
    }

    @Test func aWrongNonceIsRefusedAndTheSignInStaysPending() async throws {
        let tv = try await makeTV(port: 18804)
        _ = try await startSignIn(tv)
        let other = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .tv, host: "192.168.1.20")
        #expect(try await get("\(tv.base)/spotify/callback?code=abc&state=\(other.state)").0 == 400)
        #expect(try await get("\(tv.base)/spotify/callback?code=abc").0 == 400)
        #expect(tv.signIn.isPending)
        #expect(tv.exchanged().isEmpty)
        await tv.stop()
    }

    @Test func spotifysErrorGoesBackToSetup() async throws {
        let tv = try await makeTV(port: 18805)
        let state = try await startSignIn(tv)
        let (status, landed) = try await get("\(tv.base)/spotify/callback?error=access_denied&state=\(state)")
        // Back to the setup page (the redirect, followed).
        #expect(status == 200)
        #expect(landed?.path == "/")
        #expect(tv.signIn.lastOutcome == .cancelled)
        #expect(!tv.signIn.isPending)
        #expect(tv.exchanged().isEmpty)
        await tv.stop()
    }

    @Test func theCodeIsExchangedOnce() async throws {
        let tv = try await makeTV(port: 18806)
        let state = try await startSignIn(tv)
        let (status, landed) = try await get("\(tv.base)/spotify/callback?code=AQB-code_1&state=\(state)")
        #expect(status == 200 && landed?.path == "/")
        #expect(tv.exchanged() == ["AQB-code_1"])
        #expect(tv.signIn.lastOutcome == .signedIn)
        // Used: the same link again is closed.
        #expect(try await get("\(tv.base)/spotify/callback?code=AQB-code_1&state=\(state)").0 == 404)
        #expect(tv.exchanged() == ["AQB-code_1"])
        await tv.stop()
    }

    @Test func expires() async throws {
        let tv = try await makeTV(port: 18807)
        var now = Date()
        tv.signIn.now = { now }
        let state = try await startSignIn(tv)
        now = now.addingTimeInterval(SpotifyHubSignIn.lifetime + 1)
        #expect(try await get("\(tv.base)/spotify/callback?code=abc&state=\(state)").0 == 404)
        #expect(tv.exchanged().isEmpty)
        await tv.stop()
    }

    @Test func choosingTheServiceIsForHosts() async throws {
        let tv = try await makeTV(port: 18808)
        #expect(try await post("\(tv.base)/api/host/service", ["key": "nope", "service": "spotify"]).0 == 403)
        #expect(tv.setup.service == "appleMusic")
        #expect(try await post("\(tv.base)/api/host/service", ["key": "secret", "service": "spotify"]).0 == 204)
        #expect(tv.setup.service == "spotify")
        await tv.stop()
    }

    @Test func callbackTargetIsTheAddressThePhoneUsed() {
        func target(_ header: String?, _ fallbacks: [String?] = []) -> String? {
            PartyServer.callbackTarget(hostHeader: header, fallbacks: fallbacks).map { "\($0.host)|\($0.port.map(String.init) ?? "-")" }
        }
        #expect(target("den.local") == "den.local|-")
        #expect(target("den.local:8080") == "den.local|8080")
        #expect(target("192.168.1.20:80") == "192.168.1.20|-")
        #expect(target("10.0.0.7:8081") == "10.0.0.7|8081")
        // Not one the relay forwards to: the hub's own addresses instead.
        #expect(target("127.0.0.1:18803", ["den.local:8080", "192.168.1.20:8080"]) == "den.local|8080")
        #expect(target("localhost", [nil, "192.168.1.20"]) == "192.168.1.20|-")
        #expect(target("music.example.com", [nil, nil]) == nil)
        #expect(target("den.local:99999", ["192.168.1.20"]) == "192.168.1.20|-")
    }
}
