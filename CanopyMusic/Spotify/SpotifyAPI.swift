import Foundation
import Observation

/// Thin Spotify Web API client: auth headers, one retry on 401, and request counting so we can
/// see how close a party gets to Development Mode's (unpublished) quota.
@MainActor
@Observable
final class SpotifyAPI {
    let auth: SpotifyAuth
    private(set) var requestCount = 0
    private(set) var rateLimitedCount = 0
    @ObservationIgnored let startedAt = Date()

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    var requestsPerMinute: Double {
        Double(requestCount) / max(Date().timeIntervalSince(startedAt) / 60, 1)
    }

    /// Returns the response body, or nil for 204 No Content.
    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws -> Data? {
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if method != "GET" {
            request.httpBody = Data()
        }

        for attempt in 0..<2 {
            request.setValue("Bearer \(try await auth.accessToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            requestCount += 1
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            #if DEBUG
            print("[spotify] \(method) \(components.path)\(components.query.map { "?" + $0 } ?? "") -> \(status) \(String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " "))")
            #endif
            switch status {
            case 200..<300:
                return status == 204 || data.isEmpty ? nil : data
            case 401 where attempt == 0:
                continue
            case 429:
                rateLimitedCount += 1
                let retry = Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                throw SpotifyError.rateLimited(retryAfter: retry)
            // "NO_ACTIVE_DEVICE" (nothing active) or "Device not found" (the chosen device went to sleep).
            case 404 where String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("device"):
                throw SpotifyError.noDevice
            default:
                throw SpotifyError.badResponse(status, Self.message(in: data))
            }
        }
        throw SpotifyError.notSignedIn
    }

    /// Spotify's own error text (`{"error": {"message": …}}`), not the raw JSON.
    private static func message(in data: Data) -> String {
        struct Reply: Decodable { struct Body: Decodable { var message: String? }; var error: Body? }
        if let message = (try? JSONDecoder().decode(Reply.self, from: data))?.error?.message, !message.isEmpty {
            return message
        }
        return ""
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T? {
        guard let data = try await send("GET", path, query: query) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Follows a full `next` URL from a paged response.
    func getNext<T: Decodable>(_ next: String, as type: T.Type) async throws -> T? {
        guard let url = URL(string: next), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.replacingOccurrences(of: "/v1", with: "")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        return try await get(path, query: query, as: type)
    }
}

// MARK: - Response shapes

struct SpotifyImage: Decodable, Sendable {
    var url: URL
    var width: Int?
}

struct SpotifyTrackObject: Decodable, Sendable {
    struct Artist: Decodable, Sendable { var name: String }
    struct Album: Decodable, Sendable {
        var name: String
        var images: [SpotifyImage]?
    }
    var uri: String
    var name: String
    var duration_ms: Int
    var explicit: Bool?
    var is_local: Bool?
    var type: String?
    var artists: [Artist]
    var album: Album?
}

struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    var items: [Item]
    var next: String?
}

struct SpotifyDevice: Decodable, Identifiable, Hashable, Sendable {
    var id: String?
    var name: String
    var type: String
    var is_active: Bool
}

struct SpotifyPlayerState: Decodable, Sendable {
    struct Device: Decodable, Sendable { var id: String? }
    /// Only what the engine needs, so podcast episodes, ads or local files still decode.
    struct Item: Decodable, Sendable {
        var uri: String
        var name: String?
        var duration_ms: Int?
    }
    var is_playing: Bool
    var progress_ms: Int?
    var item: Item?
    var device: Device?

    init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case is_playing, progress_ms, item, device }
        let container = try decoder.container(keyedBy: Keys.self)
        is_playing = (try? container.decode(Bool.self, forKey: .is_playing)) ?? false
        progress_ms = try? container.decodeIfPresent(Int.self, forKey: .progress_ms)
        item = try? container.decodeIfPresent(Item.self, forKey: .item)
        device = try? container.decodeIfPresent(Device.self, forKey: .device)
    }
}
