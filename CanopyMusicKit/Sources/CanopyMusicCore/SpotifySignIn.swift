import CryptoKit
import Foundation

// Spotify sign-in through Canopy Music's relay page (docs/multi-device.md › Spotify sign-in).
//
// Since 2025 Spotify only accepts https redirect URIs (and http://127.0.0.1). An Apple TV can't
// receive one, so Spotify sends every sign-in to one fixed https page, the relay
// (https://music.canopysf.com/spotify, or the user's own copy), which forwards the browser to
// wherever `state` says the sign-in started: the iPad or Mac app (`canopy-music://`), or an
// Apple TV on the local network (`http://<tv>/spotify/callback`). The relay's repository
// (canopy-music-relay) defines the contract: its README and spotify.js.

public enum SpotifyRelay {
    /// The relay everyone uses unless they host their own: the redirect URI to register.
    public static let defaultPage = "https://music.canopysf.com/spotify"
    /// The relay page carries `<meta name="canopy-music-relay" content="1">`; `1` is the version
    /// of the `state` format below.
    public static let markerName = "canopy-music-relay"
    public static let markerVersion = "1"
    /// The relay sends an iPad or Mac sign-in to `canopy-music://spotify-callback?…`.
    public static let appScheme = "canopy-music"
    /// …and an Apple TV's to `http://<host>[:port]/spotify/callback?…`.
    public static let tvCallbackPath = "/spotify/callback"

    /// Where the sign-in started, as the relay reads it from `state`: compact JSON, then base64url
    /// without padding, at most 512 characters.
    public struct State: Codable, Equatable, Sendable {
        public enum Destination: String, Codable, Sendable {
            /// The iPad or Mac app.
            case app
            /// An Apple TV on the local network, at `host` (and `port`, if not 80).
            case tv
        }

        public var v: Int
        /// The nonce: 16–128 base64url characters, kept by the device that started the sign-in.
        public var n: String
        public var to: Destination
        public var host: String?
        public var port: Int?

        public init(nonce: String, to: Destination, host: String? = nil, port: Int? = nil) {
            v = 1
            n = nonce
            self.to = to
            self.host = to == .tv ? host : nil
            self.port = to == .tv && port != 80 ? port : nil
        }
    }

    public static func encode(_ state: State) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return base64URL((try? encoder.encode(state)) ?? Data())
    }

    /// The state, if `string` is one in the relay's format (version 1, a nonce of the right shape).
    public static func decode(_ string: String) -> State? {
        guard string.count <= 512, !string.isEmpty,
              string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let state = try? JSONDecoder().decode(State.self, from: data),
              state.v == 1, isNonce(state.n) else { return nil }
        return state
    }

    /// A fresh nonce: 32 base64url characters (24 random bytes).
    public static func newNonce() -> String {
        base64URL(randomBytes(24))
    }

    static func isNonce(_ value: String) -> Bool {
        (16...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A host the relay will send an Apple TV's sign-in back to: a single-label `.local` name, or
    /// an IPv4 address in 10/8, 172.16/12 or 192.168/16 (written as four plain decimals).
    public static func isForwardableHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") {
            let label = lower.dropLast(6)
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && !($0.count > 1 && $0.first == "0") }) else { return false }
        let n = parts.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ $0 <= 255 }) else { return false }
        return n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168)
    }

    // MARK: The sign-in page setting

    /// What the "Spotify sign-in page" field holds, cleaned up: nil means the default page.
    public enum Address: Equatable, Sendable {
        case page(String?)
        /// `http://` or another scheme: Spotify only takes https.
        case notHTTPS
        /// Not an address at all.
        case invalid
    }

    /// Reads a typed address. Empty (or the default page itself) means the default; no scheme
    /// means `https://`. Spotify compares redirect URIs character for character, so nothing else
    /// is changed (a trailing slash stays).
    public static func address(_ typed: String) -> Address {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .page(nil) }
        if let range = text.range(of: "://") {
            guard text[..<range.lowerBound].lowercased() == "https" else { return .notHTTPS }
            text = "https://" + text[range.upperBound...]
        } else if text.lowercased().hasPrefix("http:") || text.lowercased().hasPrefix("https:") {
            return .invalid
        } else {
            text = "https://" + text
        }
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), url.scheme == "https",
              let host = url.host(), host.contains("."), url.fragment == nil, url.query == nil, url.user == nil else { return .invalid }
        return .page(text == defaultPage ? nil : text)
    }

    /// The result of checking an address before it's saved.
    public enum PageCheck: String, Codable, Equatable, Sendable {
        /// A Canopy Music sign-in page (or the default).
        case ok
        case notHTTPS
        case invalid
        /// Didn't load (no answer, or an error status).
        case unreachable
        /// Loaded, but without the marker.
        case notRelay
    }

    /// Whether `html` carries the relay's marker, `<meta name="canopy-music-relay" content="1">`,
    /// in either attribute order and with either kind of quotes.
    public static func hasMarker(html: String) -> Bool {
        var rest = html[...]
        while let start = rest.range(of: "<meta", options: .caseInsensitive) {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: ">") else { return false }
            let attributes = Self.attributes(String(after[..<end]))
            if attributes["name"]?.lowercased() == markerName, attributes["content"] == markerVersion { return true }
            rest = after[end...]
        }
        return false
    }

    private static func attributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [:] }
        var result: [String: String] = [:]
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0) } ?? ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// Checks a typed address: https, loads, and carries the marker. The default page isn't
    /// loaded. `load` fetches a page and returns its body and HTTP status.
    public static func check(_ typed: String, load: (URL) async throws -> (Data, Int)) async -> (PageCheck, page: String?) {
        switch address(typed) {
        case .notHTTPS: return (.notHTTPS, nil)
        case .invalid: return (.invalid, nil)
        case .page(nil): return (.ok, nil)
        case .page(let page?):
            guard let url = URL(string: page), let (data, status) = try? await load(url), (200..<300).contains(status) else {
                return (.unreachable, page)
            }
            return (hasMarker(html: String(decoding: data.prefix(256 * 1024), as: UTF8.self)) ? .ok : .notRelay, page)
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// One Spotify sign-in (authorization code with PKCE): the verifier and nonce stay on the device
/// that started it, and Spotify's tokens come straight back to it. `redirectURI` (the sign-in
/// page) goes, character for character, in both the authorize request and the token exchange.
public struct SpotifySignInRequest: Equatable, Sendable {
    public static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        // Saving the party as a playlist (private).
        "playlist-modify-private",
    ]

    public let clientID: String
    public let redirectURI: String
    /// PKCE's code verifier: never leaves this device.
    public let verifier: String
    public let nonce: String
    /// `state` as sent (the relay's format).
    public let state: String
    public let createdAt: Date

    public init(clientID: String, redirectURI: String, destination: SpotifyRelay.State.Destination,
                host: String? = nil, port: Int? = nil, now: Date = Date()) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        verifier = SpotifyRelay.base64URL(SpotifyRelay.randomBytes(48)) // 64 characters
        nonce = SpotifyRelay.newNonce()
        state = SpotifyRelay.encode(SpotifyRelay.State(nonce: nonce, to: destination, host: host, port: port))
        createdAt = now
    }

    public var codeChallenge: String {
        SpotifyRelay.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Spotify's sign-in page for this request.
    public var authorizeURL: URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        // `URLComponents` leaves `+`, `:` and `/` alone in values; Spotify reads a `+` as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The token request's form for the code Spotify sent back.
    public func tokenForm(code: String) -> [String: String] {
        ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
         "client_id": clientID, "code_verifier": verifier]
    }

    public enum Callback: Equatable, Sendable {
        case code(String)
        /// The user said no on Spotify's page (`error=access_denied`).
        case cancelled
        /// Spotify sent another error.
        case failed(String)
        /// No `state`, or another sign-in's: not this request's answer.
        case notOurs
    }

    /// What the relay passed on (`code` or `error`, and `state`), checked against this request.
    public func callback(_ query: [String: String]) -> Callback {
        guard let state = query["state"], let decoded = SpotifyRelay.decode(state), decoded.n == nonce else { return .notOurs }
        if let error = query["error"] { return error == "access_denied" ? .cancelled : .failed(error) }
        guard let code = query["code"], !code.isEmpty else { return .notOurs }
        return .code(code)
    }

    /// The query of a callback URL (`canopy-music://spotify-callback?…`).
    public static func query(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items where query[item.name] == nil { query[item.name] = item.value ?? "" }
        return query
    }
}

/// An Apple TV's sign-in, run from a host's phone: the TV makes the request (so the verifier and
/// nonce stay on the TV), the phone opens Spotify, and the relay sends the phone back to the TV's
/// `/spotify/callback`, which is answered only while a sign-in is pending and not expired.
@MainActor
public final class SpotifyHubSignIn {
    /// How long a sign-in may take, from the phone opening Spotify to the code coming back.
    public static let lifetime: TimeInterval = 10 * 60

    public enum Outcome: Equatable, Sendable {
        case signedIn
        case cancelled
        case failed(String)
        /// Not this sign-in's answer (a wrong or missing nonce); the sign-in stays pending.
        case notOurs
        /// Nothing pending: none started, it expired, or it already finished.
        case notPending
    }

    /// The client ID and sign-in page to use (the TV's settings); nil if Spotify isn't set up.
    public var configuration: (@MainActor () -> (clientID: String, redirectURI: String)?)?
    /// Exchanges the code for tokens and keeps them (the app's `SpotifyAuth`).
    public var exchange: (@MainActor (SpotifySignInRequest, String) async throws -> Void)?
    /// Called when a sign-in starts or finishes, so the host's page can be told.
    public var onChange: (@MainActor () -> Void)?
    public var now: @MainActor () -> Date = { Date() }

    public private(set) var pending: SpotifySignInRequest?
    /// How the last sign-in ended; cleared when another starts.
    public private(set) var lastOutcome: Outcome?

    public init() {}

    /// The code came back and is being exchanged for tokens.
    public private(set) var exchanging = false

    public var isPending: Bool {
        guard let pending else { return false }
        return now().timeIntervalSince(pending.createdAt) < Self.lifetime
    }

    /// Started and not finished: waiting for the phone to come back, or exchanging its code.
    public var isBusy: Bool { isPending || exchanging }

    /// Starts a sign-in (replacing one still pending) for a phone that reached this TV at `host`
    /// (a `.local` name or private IPv4 address) and `port`. Returns Spotify's page to open, or
    /// nil if Spotify isn't set up or `host` isn't one the relay will send the phone back to.
    public func begin(host: String, port: Int?) -> URL? {
        guard SpotifyRelay.isForwardableHost(host), let configuration = configuration?(), !configuration.clientID.isEmpty else { return nil }
        let request = SpotifySignInRequest(clientID: configuration.clientID, redirectURI: configuration.redirectURI,
                                           destination: .tv, host: host, port: port, now: now())
        pending = request
        lastOutcome = nil
        onChange?()
        return request.authorizeURL
    }

    public func cancel() {
        guard pending != nil else { return }
        pending = nil
        onChange?()
    }

    /// The relay's forward (`code` or `error`, and `state`). A matching answer ends the sign-in
    /// whatever it says, so each code is used once.
    public func complete(_ query: [String: String]) async -> Outcome {
        guard let request = pending, isPending else {
            if pending != nil { pending = nil; onChange?() }
            return .notPending
        }
        let outcome: Outcome
        switch request.callback(query) {
        case .notOurs:
            return .notOurs
        case .cancelled:
            pending = nil
            outcome = .cancelled
        case .failed(let error):
            pending = nil
            outcome = .failed(error)
        case .code(let code):
            // Used once: a second answer finds nothing pending.
            pending = nil
            exchanging = true
            defer { exchanging = false }
            do {
                guard let exchange else { throw CancellationError() }
                try await exchange(request, code)
                outcome = .signedIn
            } catch {
                outcome = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        lastOutcome = outcome
        onChange?()
        return outcome
    }
}

// MARK: - What a TV's host sees while setting up Spotify

/// An Apple TV hub's Spotify setup, for the host setting the zone up on their phone. Only in
/// hosts' snapshots (`PartySnapshot.spotify`), as `musicAccess` is.
public struct SpotifySetup: Codable, Equatable, Sendable {
    public enum Account: String, Codable, Sendable {
        /// No Client ID yet.
        case notSetUp
        case signedOut
        case signedIn
    }

    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// Spotify's device type ("Speaker", "Smartphone", …).
        public var type: String
        public var isActive: Bool

        public init(id: String, name: String, type: String, isActive: Bool) {
            self.id = id
            self.name = name
            self.type = type
            self.isActive = isActive
        }
    }

    public var account: Account
    public var clientID: String
    public var displayName: String?
    /// The sign-in page in use: the redirect URI to register.
    public var signInPage: String
    /// The user's own page (nil: the default).
    public var ownSignInPage: String?
    /// A sign-in was started and hasn't come back yet.
    public var signingIn: Bool
    /// How the last sign-in failed ("cancelled", or Spotify's or the token request's error).
    public var signInError: String?
    /// Spotify Connect devices Spotify lists now; nil until the first list has come in.
    public var devices: [Device]?
    /// Where music plays (chosen on the phone).
    public var deviceID: String?
    public var deviceName: String?
    /// Another zone on the network playing from this Spotify account, and its address.
    public var conflictZone: String?
    public var conflictAddress: String?

    public init(account: Account, clientID: String, displayName: String? = nil, signInPage: String, ownSignInPage: String? = nil,
                signingIn: Bool = false, signInError: String? = nil, devices: [Device]? = nil, deviceID: String? = nil,
                deviceName: String? = nil, conflictZone: String? = nil, conflictAddress: String? = nil) {
        self.account = account
        self.clientID = clientID
        self.displayName = displayName
        self.signInPage = signInPage
        self.ownSignInPage = ownSignInPage
        self.signingIn = signingIn
        self.signInError = signInError
        self.devices = devices
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.conflictZone = conflictZone
        self.conflictAddress = conflictAddress
    }

    /// Signed in, and the chosen device is one Spotify lists now.
    public var isReady: Bool {
        account == .signedIn && deviceID != nil && devices?.contains { $0.id == deviceID } == true
    }
}

/// What a TV hub does for the host's setup page beyond the queue: the music service, and
/// Spotify's Client ID, sign-in page, sign-in and device (the app implements it).
@MainActor
public protocol HubSetupHandler: AnyObject, Sendable {
    /// "appleMusic" or "spotify". Only while the zone is waiting for setup; false if it can't.
    func chooseService(_ service: String) -> Bool
    func setSpotifyClientID(_ clientID: String)
    /// Checks the address (https, loads, has the marker) and saves it if it's good (empty: the
    /// default). Returns the check.
    func setSpotifySignInPage(_ typed: String) async -> SpotifyRelay.PageCheck
    func chooseSpotifyDevice(id: String) -> Bool
    /// Before Continue or Start the music: asks the zones announcing this Spotify account whether
    /// they're really there (`ZoneProbe`, at most about 2 s), and returns the name of the first one
    /// that is; nil if none (a stale announcement never blocks). Snapshots follow the answer.
    func checkSpotifyConflict() async -> String?
    /// Join the zone already using this Spotify account as a display; returns its address.
    func joinSpotifyConflict() -> String?
    /// The cmdlp server's address (empty turns links off) and, when given, its token; or forgets
    /// the token. The hub keeps the token to itself and checks the connection
    /// (`PartySession.linkSetup`). `normalize`, when given, is the hub's "Normalize audio"
    /// (`LinkNormalize`); nil keeps it. False when this hub doesn't take links from the page.
    func setLinks(address: String?, token: String?, forgetToken: Bool, normalize: Bool?) -> Bool
}

public extension HubSetupHandler {
    func setLinks(address: String?, token: String?, forgetToken: Bool, normalize: Bool?) -> Bool { false }
}
