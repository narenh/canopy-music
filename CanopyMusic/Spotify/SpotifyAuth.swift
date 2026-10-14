import CanopyMusicCore
import Foundation
import Security

/// Shared by the iPad (and Mac) app and the Apple TV app (CanopyMusic/Spotify is in both targets).
enum SpotifyConfig {
    static let clientIDDefaultsKey = "spotifyClientID"
    /// The user's own Spotify sign-in page (a copy of the relay); absent for the default.
    static let signInPageDefaultsKey = "spotifySignInPage"

    /// Each host uses their own Spotify developer app (Development Mode allows 5 accounts per app),
    /// entered at setup. Not a secret: sign-in uses PKCE. See README › Spotify.
    static var clientID: String {
        (UserDefaults.standard.string(forKey: clientIDDefaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The user's own sign-in page, or nil for the default (music.canopysf.com).
    static var ownSignInPage: String? {
        let page = UserDefaults.standard.string(forKey: signInPageDefaultsKey) ?? ""
        return page.isEmpty || page == SpotifyRelay.defaultPage ? nil : page
    }

    /// The redirect URI: the sign-in page Spotify sends the browser to, which forwards it to
    /// wherever the sign-in started. What the user registers in their Spotify app, and what's
    /// sent, character for character, in the authorize request and the token exchange.
    static var redirectURI: String { ownSignInPage ?? SpotifyRelay.defaultPage }

    /// Changing it keeps the current sign-in: only new sign-ins use it (refreshing doesn't).
    static func setOwnSignInPage(_ page: String?) {
        if let page { UserDefaults.standard.set(page, forKey: signInPageDefaultsKey) } else {
            UserDefaults.standard.removeObject(forKey: signInPageDefaultsKey)
        }
    }

    /// Checks a typed sign-in page before it's saved: https, loads, and carries the relay's
    /// marker (`SpotifyRelay.check`). The page is fetched from this device.
    static func checkSignInPage(_ typed: String) async -> (SpotifyRelay.PageCheck, page: String?) {
        await SpotifyRelay.check(typed) { url in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// What a check says, under the field.
    static func message(for check: SpotifyRelay.PageCheck) -> String {
        switch check {
        case .ok: "Canopy Music sign-in page found."
        case .notHTTPS: "Use an https:// address."
        case .invalid: "That isn't a web address."
        case .unreachable: "Couldn't open this page."
        case .notRelay: "This isn't a Canopy Music sign-in page."
        }
    }

    /// The relay page sends an iPad or Mac sign-in back to `canopy-music://spotify-callback`.
    static let callbackScheme = SpotifyRelay.appScheme

    static var isConfigured: Bool { !clientID.isEmpty }
}

enum SpotifyError: LocalizedError {
    case notConfigured
    case notSignedIn
    /// The user said no on Spotify's page (the relay passed on `error=access_denied`).
    case signInCancelled
    /// The sign-in sheet was closed without an answer: maybe Spotify showed its own error page
    /// (an unregistered redirect URI), which the app can't see.
    case signInClosed
    /// Spotify answered with another error, or the answer wasn't this sign-in's.
    case signInFailed(String)
    /// The redirect URI isn't one the Spotify app has registered.
    case redirectNotRegistered(String)
    case badResponse(Int, String)
    case rateLimited(retryAfter: Int)
    case noDevice
    /// Signed in before Canopy Music asked to save playlists.
    case needsPlaylistAccess

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Spotify Client ID first."
        #if os(tvOS)
        case .notSignedIn: "Sign in to Spotify on the setup page."
        #else
        case .notSignedIn: "Sign in to Spotify in host mode."
        #endif
        case .signInCancelled, .signInClosed: "Spotify sign-in was cancelled."
        case .signInFailed(let reason): "Couldn't sign in to Spotify (\(reason))."
        case .redirectNotRegistered(let page): "Add \(page) to your Spotify app's Redirect URIs."
        case .badResponse(let code, let message): message.isEmpty ? "Spotify returned error \(code)." : "Spotify: \(message)."
        case .rateLimited(let seconds): "Spotify is rate limiting Canopy Music. Try again in \(seconds) s."
        case .noDevice: "Open Spotify on the device music plays from."
        #if os(tvOS)
        case .needsPlaylistAccess: "Sign in to Spotify again to let Canopy Music save playlists."
        #else
        case .needsPlaylistAccess: "Sign in to Spotify again on the \(DeviceKind.noun) to let Canopy Music save playlists."
        #endif
        }
    }
}

/// Spotify tokens: sign-in (authorization code + PKCE, through the relay page; the iPad's browser
/// sheet is `SpotifyAuth.signIn()` in the iPad app, the TV's is run from a host's phone) and
/// refresh. Tokens live in the keychain so a relaunch mid-party doesn't need another sign-in.
@MainActor
@Observable
final class SpotifyAuth {
    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// What the sign-in allowed, space separated. nil for sign-ins saved by earlier builds.
        var scope: String?
    }

    private(set) var isSignedIn: Bool
    /// This sign-in's account as zones announce it (`SpotifyAccount.fingerprint`), never the id
    /// itself. Fetched once per sign-in (`refreshSpotifyProfile`), so nil until then (e.g.
    /// offline); signing out or in again clears it.
    private(set) var accountFingerprint: String? {
        didSet {
            UserDefaults.standard.set(accountFingerprint, forKey: Self.accountDefaultsKey)
            if accountFingerprint != oldValue { onAccountChanged?() }
        }
    }
    /// Called when `accountFingerprint` changes (the zone re-announces it).
    @ObservationIgnored var onAccountChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    private static let accountDefaultsKey = "spotifyAccount"

    init() {
        tokens = Keychain.load(Tokens.self)
        isSignedIn = tokens != nil
        accountFingerprint = tokens == nil ? nil : UserDefaults.standard.string(forKey: Self.accountDefaultsKey)
    }

    /// The signed-in account's user id (from `GET /v1/me`); only its fingerprint is kept.
    func setAccount(userID: String) {
        guard isSignedIn, !userID.isEmpty else { return }
        accountFingerprint = SpotifyAccount.fingerprint(userID: userID)
    }

    /// The sign-in allows saving playlists. Sign-ins from before that was asked for need to sign
    /// in again (once): Spotify only grants new scopes through the sign-in page.
    var canSavePlaylists: Bool {
        tokens?.scope?.split(separator: " ").contains("playlist-modify-private") == true
    }

    /// A new sign-in for this device's settings (client ID and sign-in page).
    func newRequest(destination: SpotifyRelay.State.Destination, host: String? = nil, port: Int? = nil) throws -> SpotifySignInRequest {
        guard SpotifyConfig.isConfigured else { throw SpotifyError.notConfigured }
        return SpotifySignInRequest(clientID: SpotifyConfig.clientID, redirectURI: SpotifyConfig.redirectURI,
                                    destination: destination, host: host, port: port)
    }

    /// Finishes a sign-in: exchanges the code Spotify sent back for tokens, with the request's
    /// verifier and the same redirect URI. A failure leaves an earlier sign-in as it was.
    func complete(_ request: SpotifySignInRequest, code: String) async throws {
        try await exchange(request.tokenForm(code: code))
        // Possibly another account: fetched again for this sign-in.
        accountFingerprint = nil
    }

    func signOut() {
        tokens = nil
        Keychain.delete()
        isSignedIn = false
        accountFingerprint = nil
    }

    /// A valid access token, refreshing it if it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw SpotifyError.notSignedIn }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor in
            defer { self.refreshTask = nil }
            // Refreshing doesn't use the redirect URI, so a changed sign-in page changes nothing here.
            try await self.exchange([
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": SpotifyConfig.clientID,
            ])
            return self.tokens!.accessToken
        }
        refreshTask = task
        return try await task.value
    }

    private func exchange(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let refreshing = form["grant_type"] == "refresh_token"
            // A refresh token Spotify refuses is finished; a sign-in that failed leaves the
            // current one alone.
            if refreshing, status == 400 || status == 401 { signOut() }
            struct Reply: Decodable { var error: String?; var error_description: String? }
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
            let reason = reply?.error_description ?? reply?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
            if !refreshing, let page = form["redirect_uri"], reason.localizedCaseInsensitiveContains("redirect") {
                throw SpotifyError.redirectNotRegistered(page)
            }
            throw SpotifyError.badResponse(status, reason)
        }
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double
            var scope: String?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let next = Tokens(
            accessToken: reply.access_token,
            // Spotify may or may not rotate the refresh token.
            refreshToken: reply.refresh_token ?? tokens?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(reply.expires_in),
            scope: reply.scope ?? tokens?.scope
        )
        tokens = next
        Keychain.save(next)
        isSignedIn = true
    }
}

private enum Keychain {
    static let service = "com.canopysf.CanopyMusic.spotify"

    static func save(_ value: some Encodable) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
