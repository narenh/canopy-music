import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum SpotifyConfig {
    static let clientIDDefaultsKey = "spotifyClientID"

    /// Each host uses their own Spotify developer app (Development Mode allows 5 accounts per app),
    /// entered in Settings. Not a secret: sign-in uses PKCE. See README › Spotify.
    static var clientID: String {
        (UserDefaults.standard.string(forKey: clientIDDefaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let redirectURI = "canopy-music://spotify-callback"
    static let callbackScheme = "canopy-music"
    static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
    ]

    static var isConfigured: Bool { !clientID.isEmpty }
}

enum SpotifyError: LocalizedError {
    case notConfigured
    case notSignedIn
    case signInCancelled
    case badResponse(Int, String)
    case rateLimited(retryAfter: Int)
    case noDevice

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Spotify Client ID in Settings first."
        case .notSignedIn: "Sign in to Spotify in host mode."
        case .signInCancelled: "Spotify sign-in was cancelled."
        case .badResponse(let code, let message): "Spotify returned \(code). \(message)"
        case .rateLimited(let seconds): "Spotify is rate limiting Canopy. Try again in \(seconds) s."
        case .noDevice: "Pick a Spotify device in Settings, and make sure Spotify is open on it."
        }
    }
}

/// Spotify sign-in (authorization code + PKCE, in an in-app browser sheet) and token refresh.
/// Tokens live in the keychain so a relaunch mid-party doesn't need another sign-in.
@MainActor
@Observable
final class SpotifyAuth {
    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private(set) var isSignedIn: Bool
    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private let presenter = PresentationAnchor()

    init() {
        tokens = Keychain.load(Tokens.self)
        isSignedIn = tokens != nil
    }

    func signIn() async throws {
        guard SpotifyConfig.isConfigured else { throw SpotifyError.notConfigured }
        let verifier = Self.randomString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: SpotifyConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: SpotifyConfig.callbackScheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error.map { _ in SpotifyError.signInCancelled } ?? SpotifyError.signInCancelled)
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw SpotifyError.signInCancelled }
        try await exchange([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": SpotifyConfig.clientID,
            "code_verifier": verifier,
        ])
    }

    func signOut() {
        tokens = nil
        Keychain.delete()
        isSignedIn = false
    }

    /// A valid access token, refreshing it if it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw SpotifyError.notSignedIn }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor in
            defer { self.refreshTask = nil }
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
            if status == 400 || status == 401 { signOut() }
            throw SpotifyError.badResponse(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let next = Tokens(
            accessToken: reply.access_token,
            // Spotify may or may not rotate the refresh token.
            refreshToken: reply.refresh_token ?? tokens?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(reply.expires_in)
        )
        tokens = next
        Keychain.save(next)
        isSignedIn = true
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
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

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
