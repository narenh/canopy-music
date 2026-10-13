@testable import CanopyMusicCore
import CryptoKit
import Foundation
import Testing

/// Spotify sign-in through the relay page: the `state` format the relay reads, the nonce, the
/// authorize request, the sign-in page setting and its marker check.
struct SpotifyRelayStateTests {
    @Test func readsTheRelayReadmeExamples() throws {
        let tv = try #require(SpotifyRelay.decode("eyJ2IjoxLCJuIjoicTNKazhzWG8xZll4MlRiWiIsInRvIjoidHYiLCJob3N0IjoiYmVkcm9vbS10di5sb2NhbCIsInBvcnQiOjgwfQ"))
        #expect(tv.n == "q3Jk8sXo1fYx2TbZ")
        #expect(tv.to == .tv)
        #expect(tv.host == "bedroom-tv.local")
        #expect(tv.port == 80)
        let app = try #require(SpotifyRelay.decode("eyJ2IjoxLCJuIjoicTNKazhzWG8xZll4MlRiWiIsInRvIjoiYXBwIn0"))
        #expect(app.to == .app)
        #expect(app.host == nil && app.port == nil)
    }

    @Test func encodesCompactBase64URLJSON() throws {
        let nonce = SpotifyRelay.newNonce()
        let encoded = SpotifyRelay.encode(.init(nonce: nonce, to: .tv, host: "192.168.1.20", port: 8080))
        #expect(encoded.count <= 512)
        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(!encoded.contains("="))
        // What the relay's own decoder sees: base64url, padded back, then JSON.
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try #require(Data(base64Encoded: base64))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["v"] as? Int == 1)
        #expect(json["n"] as? String == nonce)
        #expect(json["to"] as? String == "tv")
        #expect(json["host"] as? String == "192.168.1.20")
        #expect(json["port"] as? Int == 8080)
        #expect(!String(decoding: data, as: UTF8.self).contains(" "))
    }

    @Test func appStateCarriesNoAddressAndPort80IsLeftOut() throws {
        let app = try #require(SpotifyRelay.decode(SpotifyRelay.encode(.init(nonce: SpotifyRelay.newNonce(), to: .app, host: "x.local", port: 8080))))
        #expect(app.host == nil && app.port == nil)
        let tv = try #require(SpotifyRelay.decode(SpotifyRelay.encode(.init(nonce: SpotifyRelay.newNonce(), to: .tv, host: "den.local", port: 80))))
        #expect(tv.host == "den.local" && tv.port == nil)
    }

    @Test func refusesWhatTheRelayWouldRefuse() {
        func state(_ json: String) -> String { SpotifyRelay.base64URL(Data(json.utf8)) }
        #expect(SpotifyRelay.decode(state(#"{"v":2,"n":"q3Jk8sXo1fYx2TbZ","to":"app"}"#)) == nil)
        #expect(SpotifyRelay.decode(state(#"{"v":1,"n":"short","to":"app"}"#)) == nil)
        #expect(SpotifyRelay.decode(state(#"{"v":1,"n":"q3Jk8sXo1fYx2TbZ!","to":"app"}"#)) == nil)
        #expect(SpotifyRelay.decode(state(#"{"v":1,"n":"q3Jk8sXo1fYx2TbZ","to":"phone"}"#)) == nil)
        #expect(SpotifyRelay.decode("not+base64url") == nil)
        #expect(SpotifyRelay.decode(String(repeating: "A", count: 513)) == nil)
        #expect(SpotifyRelay.decode("") == nil)
    }

    @Test func noncesAreFreshAndInTheRelaysShape() {
        let nonces = (0..<50).map { _ in SpotifyRelay.newNonce() }
        #expect(Set(nonces).count == 50)
        #expect(nonces.allSatisfy { $0.count == 32 && SpotifyRelay.isNonce($0) })
    }

    @Test func forwardableHostsAreTheRelays() {
        for host in ["bedroom-tv.local", "Living-Room.local", "10.0.1.5", "172.16.0.1", "172.31.255.254", "192.168.1.20"] {
            #expect(SpotifyRelay.isForwardableHost(host), "\(host)")
        }
        for host in ["music.canopysf.com", "a.b.local", "-tv.local", "tv-.local", ".local", "8.8.8.8", "172.32.0.1",
                     "192.169.0.1", "010.0.0.1", "10.0.0", "10.0.0.256", "localhost", "127.0.0.1", "[fe80::1]"] {
            #expect(!SpotifyRelay.isForwardableHost(host), "\(host)")
        }
    }
}

struct SpotifySignInRequestTests {
    func query(_ url: URL) -> [String: String] { SpotifySignInRequest.query(of: url) }

    @Test func redirectURIIsExactlyTheSignInPage() throws {
        for page in [SpotifyRelay.defaultPage, "https://naren.github.io/canopy-music-relay/spotify", "https://relay.example.com/spotify/"] {
            let request = SpotifySignInRequest(clientID: "4c1e0000d2f0", redirectURI: page, destination: .app)
            #expect(query(request.authorizeURL)["redirect_uri"] == page)
            #expect(request.tokenForm(code: "abc")["redirect_uri"] == page)
        }
    }

    @Test func authorizeRequestIsPKCEWithTheRelayState() throws {
        let request = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .tv, host: "den.local", port: 8080)
        let q = query(request.authorizeURL)
        #expect(request.authorizeURL.absoluteString.hasPrefix("https://accounts.spotify.com/authorize?"))
        #expect(q["client_id"] == "client")
        #expect(q["response_type"] == "code")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["scope"] == SpotifySignInRequest.scopes.joined(separator: " "))
        let challenge = SpotifyRelay.base64URL(Data(SHA256.hash(data: Data(request.verifier.utf8))))
        #expect(q["code_challenge"] == challenge)
        #expect((43...128).contains(request.verifier.count))
        let sent = try #require(q["state"])
        let state = try #require(SpotifyRelay.decode(sent))
        #expect(state.n == request.nonce)
        #expect(state.to == .tv && state.host == "den.local" && state.port == 8080)
        // The verifier only goes in the token request.
        #expect(!request.authorizeURL.absoluteString.contains(request.verifier))
        #expect(request.tokenForm(code: "c")["code_verifier"] == request.verifier)
    }

    @Test func callbacksAreCheckedAgainstTheNonce() {
        let request = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .app)
        let other = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .app)
        #expect(request.callback(["code": "abc", "state": request.state]) == .code("abc"))
        #expect(request.callback(["code": "abc", "state": other.state]) == .notOurs)
        #expect(request.callback(["code": "abc"]) == .notOurs)
        #expect(request.callback(["code": "abc", "state": "garbage"]) == .notOurs)
        #expect(request.callback(["state": request.state]) == .notOurs)
        #expect(request.callback(["error": "access_denied", "state": request.state]) == .cancelled)
        #expect(request.callback(["error": "server_error", "state": request.state]) == .failed("server_error"))
        // Another sign-in's "cancelled" is not ours either.
        #expect(request.callback(["error": "access_denied", "state": other.state]) == .notOurs)
    }

    @Test func readsTheAppCallbackURL() throws {
        let request = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .app)
        let url = try #require(URL(string: "canopy-music://spotify-callback?code=AQB-x_1&state=\(request.state)"))
        #expect(request.callback(SpotifySignInRequest.query(of: url)) == .code("AQB-x_1"))
    }
}

struct SpotifySignInPageTests {
    @Test func readsTypedAddresses() {
        #expect(SpotifyRelay.address("") == .page(nil))
        #expect(SpotifyRelay.address("   ") == .page(nil))
        #expect(SpotifyRelay.address("https://music.canopysf.com/spotify") == .page(nil))
        #expect(SpotifyRelay.address("music.canopysf.com/spotify") == .page(nil))
        #expect(SpotifyRelay.address("naren.github.io/canopy-music-relay/spotify") == .page("https://naren.github.io/canopy-music-relay/spotify"))
        #expect(SpotifyRelay.address(" HTTPS://naren.github.io/canopy-music-relay/spotify ") == .page("https://naren.github.io/canopy-music-relay/spotify"))
        #expect(SpotifyRelay.address("https://relay.example.com/spotify/") == .page("https://relay.example.com/spotify/"))
        #expect(SpotifyRelay.address("http://relay.example.com/spotify") == .notHTTPS)
        #expect(SpotifyRelay.address("canopy-music://spotify-callback") == .notHTTPS)
        #expect(SpotifyRelay.address("https://relay.example.com/spotify?x=1") == .invalid)
        #expect(SpotifyRelay.address("https://relay.example.com/spotify#top") == .invalid)
        #expect(SpotifyRelay.address("not an address") == .invalid)
        #expect(SpotifyRelay.address("localhost/spotify") == .invalid)
    }

    @Test func findsTheMarker() {
        #expect(SpotifyRelay.hasMarker(html: #"<head><meta charset="utf-8"><meta name="canopy-music-relay" content="1"></head>"#))
        #expect(SpotifyRelay.hasMarker(html: #"<META content='1' NAME='Canopy-Music-Relay' />"#))
        #expect(SpotifyRelay.hasMarker(html: #"<meta name=canopy-music-relay content=1>"#))
        #expect(!SpotifyRelay.hasMarker(html: #"<meta name="canopy-music-relay" content="2">"#))
        #expect(!SpotifyRelay.hasMarker(html: #"<meta name="robots" content="1">"#))
        #expect(!SpotifyRelay.hasMarker(html: "<p>canopy-music-relay content=1</p>"))
        #expect(!SpotifyRelay.hasMarker(html: ""))
    }

    @Test func checksBeforeSaving() async {
        let relay = Data(#"<!doctype html><meta name="canopy-music-relay" content="1"><title>Canopy Music</title>"#.utf8)
        let other = Data("<!doctype html><title>Something else</title>".utf8)
        var loaded: [URL] = []
        func load(_ body: Data, _ status: Int) -> (URL) async throws -> (Data, Int) {
            { url in loaded.append(url); return (body, status) }
        }
        #expect(await SpotifyRelay.check("naren.github.io/canopy-music-relay/spotify", load: load(relay, 200)) == (.ok, "https://naren.github.io/canopy-music-relay/spotify"))
        #expect(loaded.map(\.absoluteString) == ["https://naren.github.io/canopy-music-relay/spotify"])
        #expect(await SpotifyRelay.check("https://example.com/spotify", load: load(other, 200)).0 == .notRelay)
        #expect(await SpotifyRelay.check("https://example.com/spotify", load: load(relay, 404)).0 == .unreachable)
        #expect(await SpotifyRelay.check("https://example.com/spotify", load: { _ in throw URLError(.cannotFindHost) }).0 == .unreachable)
        loaded = []
        #expect(await SpotifyRelay.check("http://example.com/spotify", load: load(relay, 200)).0 == .notHTTPS)
        #expect(await SpotifyRelay.check("nope nope", load: load(relay, 200)).0 == .invalid)
        // The default needs no check.
        #expect(await SpotifyRelay.check("", load: load(other, 500)) == (.ok, nil))
        #expect(loaded.isEmpty)
    }
}

/// An Apple TV's sign-in: pending only for a while, answered only with its own nonce, used once.
@MainActor
@Suite struct SpotifyHubSignInTests {
    let clock = Date(timeIntervalSince1970: 1_000_000)

    func makeSignIn(page: String = SpotifyRelay.defaultPage, exchanged: @escaping (SpotifySignInRequest, String) -> Void = { _, _ in }) -> SpotifyHubSignIn {
        let signIn = SpotifyHubSignIn()
        signIn.configuration = { (clientID: "client", redirectURI: page) }
        signIn.exchange = { request, code in exchanged(request, code) }
        return signIn
    }

    @Test func startsOnlyForAnAddressTheRelayForwardsTo() throws {
        let signIn = makeSignIn()
        #expect(signIn.begin(host: "music.canopysf.com", port: nil) == nil)
        #expect(!signIn.isPending)
        let url = try #require(signIn.begin(host: "den.local", port: nil))
        #expect(signIn.isPending)
        let sent = try #require(SpotifySignInRequest.query(of: url)["state"])
        let state = try #require(SpotifyRelay.decode(sent))
        #expect(state.to == .tv && state.host == "den.local" && state.n == signIn.pending?.nonce)
        signIn.configuration = { nil }
        #expect(signIn.begin(host: "den.local", port: nil) == nil)
    }

    @Test func usesTheSignInPageSetting() throws {
        let page = "https://naren.github.io/canopy-music-relay/spotify"
        let signIn = makeSignIn(page: page)
        let url = try #require(signIn.begin(host: "192.168.1.20", port: 8080))
        #expect(SpotifySignInRequest.query(of: url)["redirect_uri"] == page)
        #expect(signIn.pending?.tokenForm(code: "abc")["redirect_uri"] == page)
    }

    @Test func exchangesItsOwnCodeOnce() async throws {
        var exchanged: [(String, String, String)] = []
        let signIn = makeSignIn { request, code in exchanged.append((code, request.verifier, request.redirectURI)) }
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        let request = try #require(signIn.pending)
        #expect(await signIn.complete(["code": "abc", "state": request.state]) == .signedIn)
        #expect(exchanged.count == 1)
        #expect(exchanged.first?.0 == "abc" && exchanged.first?.1 == request.verifier && exchanged.first?.2 == SpotifyRelay.defaultPage)
        #expect(!signIn.isPending)
        #expect(signIn.lastOutcome == .signedIn)
        // The same answer again finds nothing pending.
        #expect(await signIn.complete(["code": "abc", "state": request.state]) == .notPending)
        #expect(exchanged.count == 1)
    }

    @Test func aWrongNonceChangesNothing() async throws {
        var exchanged = 0
        let signIn = makeSignIn { _, _ in exchanged += 1 }
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        let other = SpotifySignInRequest(clientID: "client", redirectURI: SpotifyRelay.defaultPage, destination: .tv, host: "den.local")
        #expect(await signIn.complete(["code": "abc", "state": other.state]) == .notOurs)
        #expect(await signIn.complete(["code": "abc"]) == .notOurs)
        #expect(signIn.isPending)
        #expect(exchanged == 0)
    }

    @Test func spotifysErrorEndsTheSignIn() async throws {
        let signIn = makeSignIn()
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        let state = try #require(signIn.pending?.state)
        #expect(await signIn.complete(["error": "access_denied", "state": state]) == .cancelled)
        #expect(!signIn.isPending)
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        #expect(signIn.lastOutcome == nil)
        #expect(await signIn.complete(["error": "server_error", "state": try #require(signIn.pending?.state)]) == .failed("server_error"))
    }

    @Test func expires() async throws {
        var now = clock
        var exchanged = 0
        let signIn = makeSignIn { _, _ in exchanged += 1 }
        signIn.now = { now }
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        let state = try #require(signIn.pending?.state)
        now = clock.addingTimeInterval(SpotifyHubSignIn.lifetime - 1)
        #expect(signIn.isPending)
        now = clock.addingTimeInterval(SpotifyHubSignIn.lifetime + 1)
        #expect(!signIn.isPending)
        #expect(await signIn.complete(["code": "abc", "state": state]) == .notPending)
        #expect(exchanged == 0)
        #expect(signIn.pending == nil)
    }

    @Test func aFailedExchangeSaysWhy() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "Spotify: Invalid redirect URI." } }
        let signIn = SpotifyHubSignIn()
        signIn.configuration = { (clientID: "client", redirectURI: SpotifyRelay.defaultPage) }
        signIn.exchange = { _, _ in throw Refused() }
        _ = try #require(signIn.begin(host: "den.local", port: nil))
        #expect(await signIn.complete(["code": "abc", "state": try #require(signIn.pending?.state)]) == .failed("Spotify: Invalid redirect URI."))
        #expect(!signIn.isBusy)
    }
}

/// An Apple TV's Spotify setup reaches hosts' pages only, and the TV can change service under the
/// same session while the host is still setting it up.
@MainActor
@Suite struct TVSpotifySetupTests {
    func makeTV() -> PartySession {
        let tv = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: FakeEngine())
        tv.configureHub(kind: .tv, zoneName: "Den", serviceName: "Apple Music")
        tv.hostKey = "secret"
        return tv
    }

    @Test func onlyHostsSeeSpotifysSetup() async {
        let tv = makeTV()
        tv.musicAccess = .ok
        tv.spotifySetup = SpotifySetup(account: .signedOut, clientID: "4c1e", signInPage: SpotifyRelay.defaultPage)
        #expect(tv.snapshot().spotify == nil)
        #expect(tv.snapshot(hostKey: "wrong").spotify == nil)
        #expect(tv.snapshot(hostKey: "secret").spotify?.account == .signedOut)
        #expect(tv.snapshot(hostKey: "secret").musicAccess == .ok)
        // Encoded, guests' snapshots don't carry the field at all.
        let guest = String(decoding: try! JSONEncoder().encode(tv.snapshot()), as: UTF8.self)
        #expect(!guest.contains("4c1e") && !guest.contains("signInPage"))

        var host = tv.snapshots(hostKey: "secret").makeAsyncIterator()
        var guestStream = tv.snapshots().makeAsyncIterator()
        _ = await host.next()
        _ = await guestStream.next()
        tv.spotifySetup?.account = .signedIn
        tv.spotifySetup?.displayName = "Naren"
        #expect(await host.next()?.spotify?.displayName == "Naren")
        #expect(await guestStream.next()?.spotify == nil)
    }

    @Test func readyNeedsTheChosenDeviceListed() {
        var setup = SpotifySetup(account: .signedIn, clientID: "c", signInPage: SpotifyRelay.defaultPage)
        #expect(!setup.isReady)
        setup.devices = [.init(id: "d1", name: "Sonos Move", type: "Speaker", isActive: false)]
        #expect(!setup.isReady)
        setup.deviceID = "d2"
        #expect(!setup.isReady)
        setup.deviceID = "d1"
        #expect(setup.isReady)
        setup.account = .signedOut
        #expect(!setup.isReady)
    }

    @Test func changesServiceOnlyBeforeAnythingLoads() async throws {
        let tv = makeTV()
        var host = tv.snapshots(hostKey: "secret").makeAsyncIterator()
        let epoch = await host.next()?.epoch
        let spotify = FakeSpotifyEngine()
        #expect(tv.replaceService(catalog: StubCatalog(ids: ["s1", "s2"]), engine: spotify, serviceName: "Spotify"))
        let next = await host.next()
        #expect(next?.service == "Spotify")
        // The same session: pages stay connected and keep comparing versions.
        #expect(next?.epoch == epoch)
        #expect(tv.engine === spotify)
        try await tv.load(playlist: base)
        #expect(tv.state.upNext.map(\.track.id).contains("s1"))
        // Something's loaded: no more changing.
        #expect(!tv.replaceService(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine(), serviceName: "Apple Music"))
        #expect(tv.serviceName == "Spotify")
    }
}
