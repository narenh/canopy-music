import Foundation

// Link tracks: a guest pastes a YouTube, SoundCloud, Bandcamp, Mixcloud, or archive.org link into
// a phone's search, the hub resolves it through canopy-cmdlp (which downloads it and serves an
// AAC .m4a at a signed `audioUrl`), and once it's downloaded it joins the queue like any other
// song (`LinkPreparation`). Hidden and inert unless the hub has a cmdlp address and token
// (`PartySession.linkService`).

/// A song from a link, as cmdlp last described it (`QueueTrack.link`). In the queue it's always
/// ready: a link joins Up Next only once its download is.
public struct LinkTrack: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, ready, failed

        /// Anything else cmdlp might add later reads as still downloading.
        public init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
        }
    }

    /// cmdlp's track id (22 characters of base64url). The same link twice in a zone is one id.
    public var id: String
    /// "YouTube", "SoundCloud"…
    public var service: String?
    public var status: Status
    /// The signed audio. Only the hub and Sonos need it: snapshots and search results leave it
    /// out (`forGuests`).
    public var audioURL: URL?

    public init(id: String, service: String? = nil, status: Status, audioURL: URL? = nil) {
        self.id = id
        self.service = service
        self.status = status
        self.audioURL = audioURL
    }

    /// Ready, with its audio's address: a player can start it.
    public var isPlayable: Bool { status == .ready && audioURL != nil }
}

public extension QueueTrack {
    /// A link track's id: "link:" and cmdlp's id, so the same link is the same song.
    static func linkID(_ cmdlpID: String) -> String { "link:\(cmdlpID)" }

    /// Without what only the hub needs (a link's signed audio address), for phones and displays.
    var forGuests: QueueTrack {
        guard link?.audioURL != nil else { return self }
        var track = self
        track.link?.audioURL = nil
        return track
    }
}

public extension QueueItem {
    var forGuests: QueueItem {
        guard track.link?.audioURL != nil else { return self }
        var item = self
        item.track = track.forGuests
        return item
    }
}

/// Telling a pasted link from a search: the whole query is one http(s) address with a host.
public enum LinkURL {
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains(".") else { return nil }
        return url
    }
}

// MARK: - canopy-cmdlp

/// A track as cmdlp answers `POST /resolve` and `GET /tracks/{id}`.
public struct CmdlpTrack: Codable, Equatable, Sendable {
    public struct Progress: Codable, Equatable, Sendable {
        public var percent: Double?
        public var downloadedBytes: Int?
        public var totalBytes: Int?
        public var speed: Double?
        /// Seconds yt-dlp expects the download still to take, when it knows.
        public var eta: Double?

        public init(percent: Double? = nil, eta: Double? = nil) {
            self.percent = percent
            self.eta = eta
        }
    }

    public var id: String
    public var zone: String?
    public var status: LinkTrack.Status
    public var title: String?
    public var artist: String?
    public var duration: Double?
    public var artwork: String?
    public var service: String?
    public var stage: String?
    public var progress: Progress?
    public var audioUrl: String?
    public var error: String?

    public init(id: String, zone: String? = nil, status: LinkTrack.Status, title: String? = nil, artist: String? = nil,
                duration: Double? = nil, artwork: String? = nil, service: String? = nil, stage: String? = nil,
                progress: Progress? = nil, audioUrl: String? = nil, error: String? = nil) {
        self.id = id
        self.zone = zone
        self.status = status
        self.title = title
        self.artist = artist
        self.duration = duration
        self.artwork = artwork
        self.service = service
        self.stage = stage
        self.progress = progress
        self.audioUrl = audioUrl
        self.error = error
    }

    public var link: LinkTrack {
        LinkTrack(id: id, service: service, status: status, audioURL: audioUrl.flatMap(URL.init(string:)))
    }

    /// As a queue song. Its art is the site's (or cmdlp's own SoundCloud logo, which needs no
    /// token), loaded directly by phones and displays.
    public var queueTrack: QueueTrack {
        let art = artwork.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        var track = QueueTrack(id: QueueTrack.linkID(id), title: title?.nonEmpty ?? "Untitled", artist: artist?.nonEmpty ?? service ?? "",
                               duration: duration.flatMap { $0 > 0 ? $0 : nil }, artworkURL: art, thumbnailURL: art)
        track.link = link
        return track
    }
}

// MARK: - Preparing

/// A link a guest added while cmdlp was still downloading it. It joins Up Next as their request
/// once the download is ready, whether or not their page is still open; nothing half-downloaded
/// is ever queued. Only the phones that added it see how it's going (`LinkProgress`). Saved
/// beside the queue, so a hub relaunched meanwhile carries on watching it.
public struct LinkPreparation: Codable, Equatable, Sendable {
    /// cmdlp's track id.
    public var linkID: String
    /// The cmdlp zone it's downloading in.
    public var zone: String?
    public var title: String
    /// Who it's queued for: the guest (or host) who added it first.
    public var requester: Requester
    /// The queue item's id once it's queued (a display's chosen id, or a new one).
    public var itemID: UUID
    /// When it was added: the request's time, and where "more than 15 seconds" counts from.
    public var addedAt: Date
    /// The phones that added it, first the requester's: each sees it preparing, and is told if
    /// it fails.
    public var clients: [String]
    /// It's expected to take more than `LinkPrepEstimate.limit` (`LinkProgress.takesLong`). Once
    /// set it stays, so the phone's message doesn't come and go.
    public var takesLong: Bool

    public init(linkID: String, zone: String?, title: String, requester: Requester, itemID: UUID, addedAt: Date,
                clients: [String], takesLong: Bool = false) {
        self.linkID = linkID
        self.zone = zone
        self.title = title
        self.requester = requester
        self.itemID = itemID
        self.addedAt = addedAt
        self.clients = clients
        self.takesLong = takesLong
    }
}

/// How a link being prepared is getting on, for the phones that added it: "Preparing… 37%", and
/// once it's expected to take more than 15 seconds, a line saying it will queue by itself.
public struct LinkProgress: Codable, Equatable, Sendable {
    /// The song's id, as in the phone's results ("link:…").
    public var id: String
    public var title: String
    /// Whole percents, at most 99 until it's ready; nil before cmdlp knows.
    public var percent: Int?
    public var takesLong: Bool

    public init(id: String, title: String, percent: Int?, takesLong: Bool) {
        self.id = id
        self.title = title
        self.percent = percent
        self.takesLong = takesLong
    }
}

/// A link that couldn't be prepared, for a phone that added it: the song's id and the sentence
/// to show ("Couldn’t add “Title”").
public struct LinkFailure: Codable, Equatable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// What a phone hears about the links it added (`PartySession.linkProgress(for:)`): those still
/// preparing, and those that failed since it last asked (each told once).
public struct LinkProgressReply: Codable, Equatable, Sendable {
    public var preparing: [LinkProgress]
    public var failed: [LinkFailure]

    public init(preparing: [LinkProgress], failed: [LinkFailure]) {
        self.preparing = preparing
        self.failed = failed
    }
}

/// What became of a link a phone added: queued at once (it was already downloaded), or
/// preparing, to be queued when it's ready.
public enum LinkAddResult: Equatable, Sendable {
    case queued(AddResult)
    case preparing(LinkProgress)
}

/// Whether a link being prepared will take more than `limit` seconds from when it was added: the
/// time so far, plus what's left (yt-dlp's ETA when cmdlp passes it on, otherwise the download's
/// rate between the first and latest percentages seen, once they're a second apart). Without an
/// estimate, only once the time so far is past the limit.
public enum LinkPrepEstimate {
    public static let limit: TimeInterval = 15

    public struct Sample: Equatable, Sendable {
        public var at: Date
        public var percent: Double

        public init(at: Date, percent: Double) {
            self.at = at
            self.percent = percent
        }
    }

    public static func takesLong(addedAt: Date, first: Sample?, latest: Sample?, eta: Double?, now: Date,
                                 limit: TimeInterval = limit) -> Bool {
        let elapsed = now.timeIntervalSince(addedAt)
        if elapsed > limit { return true }
        if let eta, eta.isFinite, eta >= 0 { return elapsed + eta > limit }
        guard let first, let latest else { return false }
        let span = latest.at.timeIntervalSince(first.at)
        guard span >= 1, latest.percent > first.percent else { return false }
        let remaining = (100 - min(latest.percent, 100)) / ((latest.percent - first.percent) / span)
        return elapsed + remaining > limit
    }
}

/// cmdlp's error: `{"error": "<a sentence>", "reason": "<snake_case>"}` with its status.
public struct CmdlpError: Error, Equatable, LocalizedError {
    public var status: Int
    public var reason: String?
    public var message: String?

    public init(status: Int, reason: String? = nil, message: String? = nil) {
        self.status = status
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message ?? "canopy-cmdlp answered \(status)." }
}

/// What the hub asks of cmdlp. `CmdlpClient` in the apps; a fake in tests.
public protocol LinkService: Sendable {
    /// Looks the link up and starts downloading it, in `zone`. The same link again is the same track.
    func resolve(_ url: String, zone: String) async throws -> CmdlpTrack
    func track(id: String) async throws -> CmdlpTrack
    /// The zone's party is over: its downloads stop and its files go.
    func deleteZone(_ zone: String) async throws
}

/// cmdlp over HTTPS. The token goes only in the Authorization header: nothing here logs it.
public struct CmdlpClient: LinkService {
    public let baseURL: URL
    private let token: String
    private let urlSession: URLSession

    public init(baseURL: URL, token: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.urlSession = urlSession
    }

    /// "https://cmdlp.example.com/" as typed: trimmed, its trailing slashes gone. nil unless it's
    /// an http(s) address with a host.
    public static func baseURL(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil, url.query == nil else { return nil }
        return url
    }

    public func resolve(_ url: String, zone: String) async throws -> CmdlpTrack {
        // A lookup can take up to 90 s on cmdlp's side.
        try await call("POST", "/resolve", body: ["url": url, "zone": zone], timeout: 100)
    }

    public func track(id: String) async throws -> CmdlpTrack {
        try await call("GET", "/tracks/\(id)", timeout: 15)
    }

    public func deleteZone(_ zone: String) async throws {
        struct Deleted: Decodable { var deleted: Int? }
        let _: Deleted = try await call("DELETE", "/zones/\(zone)", timeout: 15)
    }

    /// `GET /health` (no token): whether cmdlp is up, for the host's "Test connection".
    public static func health(baseURL: URL, urlSession: URLSession = .shared) async throws {
        var request = URLRequest(url: baseURL.appending(path: "health"), timeoutInterval: 10)
        request.httpMethod = "GET"
        let (data, response) = try await urlSession.data(for: request)
        struct Health: Decodable { var ok: Bool }
        guard (response as? HTTPURLResponse)?.statusCode == 200, (try? JSONDecoder().decode(Health.self, from: data))?.ok == true else {
            throw CmdlpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Whether the token works: a track id that can't exist answers 404 with a good token, 401
    /// without one. Nothing is downloaded.
    public func checkToken() async throws {
        do {
            let _: CmdlpTrack = try await call("GET", "/tracks/AAAAAAAAAAAAAAAAAAAAAA", timeout: 10)
        } catch let error as CmdlpError where error.status == 404 {
            return
        }
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw CmdlpError(status: status, reason: body?.reason, message: body?.error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct ErrorBody: Decodable {
        var error: String?
        var reason: String?
    }
}

/// Why a link can't be queued, in a sentence for the phone that pasted it.
public struct LinkRefusal: Error, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }

    /// The zone plays on Spotify Connect, or the hub doesn't take links.
    public static let notHere = LinkRefusal("Links can't play in this zone.")
    public static let unavailable = LinkRefusal("Links aren't working right now. Try again in a moment.")

    /// What a phone is told when cmdlp refused or failed. cmdlp's own sentence for the refusals a
    /// guest can do something about (not one song, a live stream, YouTube's bot check); a plain
    /// one for the rest (yt-dlp's raw message, a bad token, cmdlp unreachable).
    public init(resolving error: any Error) {
        if let refusal = error as? LinkRefusal { self = refusal; return }
        guard let error = error as? CmdlpError else { self = .unavailable; return }
        switch error.reason {
        case "unsupported_link", "playlist", "live", "blocked", "bad_url":
            self.init(error.message ?? "That link can't be played.")
        case "lookup_failed":
            self.init("Couldn't find a song at that link. It may be private or removed.")
        case "timeout":
            self.init("Looking that link up took too long. Try again.")
        default:
            self = .unavailable
        }
    }
}

/// "Test connection": cmdlp's `/health` (no token), then the token. A sentence for the host.
public enum LinkConnectionCheck {
    public static func run(baseURL typed: String, token: String?, urlSession: URLSession = .shared) async -> String {
        guard let base = CmdlpClient.baseURL(typed) else { return "Enter the server's address first." }
        do {
            try await CmdlpClient.health(baseURL: base, urlSession: urlSession)
        } catch {
            return "Couldn't reach \(base.host() ?? "the server")."
        }
        guard let token else { return "The server is up. Add its API token to turn links on." }
        do {
            try await CmdlpClient(baseURL: base, token: token, urlSession: urlSession).checkToken()
            return "Connected. Guests can paste links into search."
        } catch let error as CmdlpError where error.status == 401 {
            return "The server is up, but it didn't accept the token."
        } catch {
            return "The server is up, but the token couldn't be checked."
        }
    }
}

/// An Apple TV hub's link settings as its hosts' phones see them (`PartySnapshot.linkSetup`): the
/// address, the token's last four characters (never the token), and how the last check went.
public struct LinkSetup: Codable, Equatable, Sendable {
    public var address: String
    public var tokenHint: String?
    public var status: String?

    public init(address: String, tokenHint: String?, status: String? = nil) {
        self.address = address
        self.tokenHint = tokenHint
        self.status = status
    }
}

/// The hub's cmdlp settings: the address (not secret) and the token (the Keychain's).
public protocol LinkTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String?)
}

/// What the host sees of the token: its last four characters.
public enum LinkTokenHint {
    public static func of(_ token: String?) -> String? {
        guard let token, token.count >= 4 else { return nil }
        return String(token.suffix(4))
    }
}

/// A cmdlp zone name for a new party: a fresh one each time, within cmdlp's 1–64 letters,
/// digits, `-`, or `_`.
public enum LinkZone {
    public static func make(prefix: String = "canopy") -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = String(prefix.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(30))
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        return "\(cleaned.isEmpty ? "canopy" : cleaned)-\(random)"
    }

    public static func isValid(_ zone: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return (1...64).contains(zone.count) && zone.allSatisfy(allowed.contains)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
