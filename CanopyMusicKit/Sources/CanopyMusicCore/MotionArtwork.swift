import Foundation

/// Animated ("motion") album artwork, shown only on the iPad's large Now Playing artwork, for
/// Apple Music zones. Experimental: everything about it hangs off `isEnabled`, and removing it
/// means deleting this file, `MotionArtworkView.swift`, the `motionArtwork` lines in `MusicCatalog`
/// and `AppleMusicCatalog`, the overlay line in `NowPlayingView` and `/api/debug/motion`.
///
/// Apple Music API albums can carry an `editorialVideo` attribute when asked for it with
/// `extend=editorialVideo`: HLS (`.m3u8`) videos in several shapes, of which a square one suits
/// the artwork (`attributes.editorialVideo.motionDetailSquare.video`). Only some albums have one.
///
/// On a real Apple TV our request came back without `editorialVideo`, even for albums with motion
/// art in the Music app; a public project that gets it adds `platform=web`. Try query variants
/// with `GET /api/debug/motion?…&platform=<value>&extend=<value>` (debug builds), then set
/// `albumQuery` to the one that works.
///
/// Debug builds only: a public third-party service (`MotionArtworkService`, artwork.m8tec.top)
/// is asked instead, by the song's exact catalog album (`QueueTrack.albumID`) when known, else by
/// artist and album name (accepted only when the album it answers for has our names). It doesn't
/// exist in Release builds.
public enum MotionArtwork {
    /// The feature switch. Off: no lookups and no video; Now Playing shows the still artwork.
    public static let isEnabled = true

    #if DEBUG
    /// Debug builds: whether to fall back to the third-party `MotionArtworkService` when the
    /// Apple Music API finds no motion artwork. Still only with `isEnabled`.
    public static let usesThirdPartyService = true
    #endif

    /// The query on the album request. **The switch for request variants**: e.g. `platform: "web"`.
    public static let albumQuery = AlbumQuery(extend: "editorialVideo", platform: nil)

    /// Query parameters for the album request. nil or empty leaves a parameter out.
    public struct AlbumQuery: Sendable, Equatable {
        public var extend: String?
        public var platform: String?

        public init(extend: String?, platform: String?) {
            self.extend = extend
            self.platform = platform
        }

        /// This query with any given values in place of its own (an empty value removes one).
        public func overriding(extend: String?, platform: String?) -> AlbumQuery {
            AlbumQuery(extend: extend ?? self.extend, platform: platform ?? self.platform)
        }
    }

    /// Square motion video entries in `editorialVideo`, best first. Other keys that say "square"
    /// or "1x1" come after these.
    static let preferredSquareKeys = ["motionDetailSquare", "motionSquareVideo1x1"]

    /// Catalog API paths, relative to `/v1/catalog/{storefront}/`.
    static func songPath(_ songID: String) -> String { "songs/\(songID)?include=albums" }
    static func albumPath(_ albumID: String, query: AlbumQuery = albumQuery) -> String {
        var components = URLComponents()
        components.path = "albums/\(albumID)"
        let items = [("extend", query.extend), ("platform", query.platform)].compactMap { name, value in
            value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: name, value: $0) }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? "albums/\(albumID)"
    }

    /// Whether `id` is an Apple Music catalog id (all digits). Library ids ("i.…") aren't.
    public static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The album id in a catalog song response (`songs/{id}?include=albums`): the first album in
    /// its `albums` relationship.
    public static func albumID(inSongResponse data: Data) -> String? {
        guard let song = firstResource(in: data),
              let relationships = song["relationships"] as? [String: Any],
              let albums = relationships["albums"] as? [String: Any],
              let first = (albums["data"] as? [[String: Any]])?.first,
              let id = first["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The catalog album id in an Apple Music song link, which every catalog song carries as its
    /// `url` attribute: "https://music.apple.com/us/album/forever/1440833098?i=1440833101" →
    /// "1440833098". The id is the all-digit path component after "album" (a slug may sit
    /// between them). nil for anything else.
    public static func albumID(inSongURL url: URL?) -> String? {
        guard let url, url.host?.lowercased().hasSuffix("music.apple.com") == true else { return nil }
        let parts = url.pathComponents
        guard let album = parts.firstIndex(where: { $0.lowercased() == "album" }) else { return nil }
        return parts[(album + 1)...].last(where: isCatalogID)
    }

    /// The `editorialVideo` attribute of a catalog album response (`albums/{id}?extend=editorialVideo`).
    static func editorialVideo(inAlbumResponse data: Data) -> [String: Any]? {
        (firstResource(in: data)?["attributes"] as? [String: Any])?["editorialVideo"] as? [String: Any]
    }

    /// The best square motion video in a catalog album response, or nil when it has none (or the
    /// response isn't shaped as expected).
    public static func squareVideoURL(inAlbumResponse data: Data) -> URL? {
        editorialVideo(inAlbumResponse: data).flatMap(squareVideoURL(inEditorialVideo:))
    }

    /// The best square entry in an `editorialVideo` object. Each entry is expected to look like
    /// `{"previewFrame": {…artwork…}, "video": "https://….m3u8"}`; a bare URL string is accepted too.
    static func squareVideoURL(inEditorialVideo editorialVideo: [String: Any]) -> URL? {
        let otherSquareKeys = editorialVideo.keys
            .filter { key in
                !preferredSquareKeys.contains(key)
                    && (key.localizedCaseInsensitiveContains("square") || key.contains("1x1"))
            }
            .sorted()
        for key in preferredSquareKeys + otherSquareKeys {
            if let url = videoURL(in: editorialVideo[key]) { return url }
        }
        return nil
    }

    private static func videoURL(in entry: Any?) -> URL? {
        let string = (entry as? [String: Any])?["video"] as? String ?? entry as? String
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func firstResource(in data: Data) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (root["data"] as? [[String: Any]])?.first
    }
}

/// Finds motion artwork for songs: the song's catalog album, then that album's `editorialVideo`.
/// Remembers each song's album and each album's video (or that it has none), so a song plays
/// back without asking again. Errors aren't remembered: the next song change tries again.
public actor MotionArtworkLookup {
    /// Fetches a catalog API path relative to `/v1/catalog/{storefront}/` and returns the raw body.
    public typealias Fetch = @Sendable (_ path: String) async throws -> Data
    /// Like `Fetch`, also returning the full URL it requested (shown by `probe`).
    public typealias FetchReportingURL = @Sendable (_ path: String) async throws -> (data: Data, url: String)

    /// The account's storefront ("us", "gb"…), or nil when unknown.
    public typealias Storefront = @Sendable () async -> String?

    private let fetchReportingURL: FetchReportingURL
    private let storefront: Storefront
    /// Song id → its album id.
    private var albumIDs: [String: String] = [:]
    /// Album id → its square motion video; `.some(nil)` when it has none.
    private var videos: [String: URL?] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    #if DEBUG
    /// Loads a `MotionArtworkService` URL (swapped out in tests).
    private var serviceLoad: MotionArtworkService.Load = MotionArtworkService.load
    /// `MotionArtworkService.cacheKey(for:)` (per album id, or per artist and album name) → its
    /// square video; `.some(nil)` when it has none.
    private var serviceVideos: [String: URL?] = [:]
    #endif

    public init(fetch: @escaping Fetch, storefront: @escaping Storefront = { nil }) {
        self.fetchReportingURL = { path in (try await fetch(path), path) }
        self.storefront = storefront
    }

    public init(fetchReportingURL: @escaping FetchReportingURL, storefront: @escaping Storefront = { nil }) {
        self.fetchReportingURL = fetchReportingURL
        self.storefront = storefront
    }

    #if DEBUG
    init(fetch: @escaping Fetch, storefront: @escaping Storefront = { nil }, serviceLoad: @escaping MotionArtworkService.Load) {
        self.fetchReportingURL = { path in (try await fetch(path), path) }
        self.storefront = storefront
        self.serviceLoad = serviceLoad
    }
    #endif

    private func fetch(_ path: String) async throws -> Data {
        try await fetchReportingURL(path).data
    }

    /// The square motion video for a track, from `MotionArtworkService` (debug builds,
    /// `usesThirdPartyService`): by the track's exact catalog album when it has an `albumID`, else
    /// by its artist and album name. The Apple Music API isn't asked: it doesn't return motion
    /// artwork to our token (checked on a real Apple TV, every variant). nil when the service has
    /// none, the feature is off, the lookup failed, or this is a Release build.
    public func videoURL(for track: QueueTrack) async -> URL? {
        guard MotionArtwork.isEnabled else { return nil }
        #if DEBUG
        if MotionArtwork.usesThirdPartyService { return await serviceVideoURL(for: track) }
        #endif
        return nil
    }

    #if DEBUG
    /// The service's square video for a track's album, remembered per album id (or per artist and
    /// album name), also when it has none. Failures are silent and not remembered.
    private func serviceVideoURL(for track: QueueTrack) async -> URL? {
        let key = MotionArtworkService.cacheKey(for: track)
        guard !key.isEmpty else { return nil }
        if let known = serviceVideos[key] { return known }
        guard case .video(let found) = await askService(for: track).outcome else { return nil }
        serviceVideos[key] = .some(found)
        return found
    }

    /// Asks the service about a track's album: one request for its album link when it has a
    /// catalog album id (that answer is the album's, so the names aren't checked), else a name
    /// search per artist candidate until one is accepted. A search answer naming a different
    /// album or artist is rejected and counts as none. Logs what happened; caches nothing.
    private func askService(for track: QueueTrack) async -> MotionArtworkService.Lookup {
        if let albumID = MotionArtworkService.usableAlbumID(track.albumID) {
            let link = MotionArtworkService.albumLink(albumID: albumID, storefront: await storefront())
            let route = MotionArtworkService.Route.albumLink(albumID: albumID, link: link)
            guard let url = MotionArtworkService.albumLinkURL(link) else { return .init(route: route, attempts: [], outcome: .failed) }
            let attempt = await askService(url, checkingNamesOf: nil)
            let outcome: MotionArtworkService.Outcome = switch attempt.verdict {
            case .accepted(let video): .video(video)
            case .none: .video(nil)
            case .rejected, .unexpected, .failed: .failed
            }
            print("[motion] service album \(albumID) (\(link)): \(attempt.verdict.summary)")
            return .init(route: route, attempts: [attempt], outcome: outcome)
        }
        var attempts: [MotionArtworkService.Attempt] = []
        for candidate in MotionArtworkService.artistCandidates(track.artist) {
            guard let url = MotionArtworkService.searchURL(artist: candidate, album: track.album) else { continue }
            let attempt = await askService(url, checkingNamesOf: track)
            attempts.append(attempt)
            switch attempt.verdict {
            case .accepted(let video):
                print("[motion] service \"\(candidate)\" / \"\(track.album)\": \(video.absoluteString)")
                return .init(route: .search, attempts: attempts, outcome: .video(video))
            case .rejected(let artist, let album):
                print("[motion] service \"\(candidate)\" / \"\(track.album)\": rejected, it answered for \"\(artist ?? "?")\" / \"\(album ?? "?")\", we have \"\(track.artist)\" / \"\(track.album)\"")
            case .none:
                continue
            case .unexpected, .failed:
                print("[motion] service \"\(candidate)\" / \"\(track.album)\": \(attempt.verdict.summary)")
                return .init(route: .search, attempts: attempts, outcome: .failed)
            }
        }
        print("[motion] service \"\(track.artist)\" / \"\(track.album)\": no animated artwork")
        return .init(route: .search, attempts: attempts, outcome: .video(nil))
    }

    /// One service request. With a track, a found video is accepted only when the names in the
    /// response match the track's (`MotionArtworkService.namesMatch`).
    private func askService(_ url: URL, checkingNamesOf track: QueueTrack?) async -> MotionArtworkService.Attempt {
        do {
            let (data, status) = try await serviceLoad(url)
            let verdict: MotionArtworkService.Verdict
            switch MotionArtworkService.answer(data: data, status: status) {
            case .found(let video):
                let names = MotionArtworkService.names(in: data)
                if let track, !MotionArtworkService.namesMatch(names, artist: track.artist, album: track.album) {
                    verdict = .rejected(artist: names.artist, album: names.album)
                } else {
                    verdict = .accepted(video)
                }
            case .none: verdict = .none
            case .unexpected(let status): verdict = .unexpected(status: status)
            }
            return .init(url: url, checksNames: track != nil, status: status, body: data, error: nil, verdict: verdict)
        } catch {
            return .init(url: url, checksNames: track != nil, status: nil, body: nil, error: String(describing: error), verdict: .failed)
        }
    }

    /// Debug: what `MotionArtworkService` answers for a track, without the cache: which path was
    /// taken (`albumLink` when it has a catalog album id, else `search`), each URL requested, the
    /// service's response and the verdict on it.
    public func probeService(track: QueueTrack) async throws -> Data {
        let lookup = await askService(for: track)
        var report: [String: Any] = [
            "enabled": MotionArtwork.isEnabled, "usesThirdPartyService": MotionArtwork.usesThirdPartyService,
            "artist": track.artist, "album": track.album, "albumID": track.albumID ?? NSNull(),
        ]
        switch lookup.route {
        case .albumLink(_, let link):
            report["path"] = "albumLink"
            report["albumLink"] = link
        case .search:
            report["path"] = "search"
        }
        report["requests"] = lookup.attempts.map { attempt -> [String: Any] in
            var entry: [String: Any] = ["url": attempt.url.absoluteString, "verdict": attempt.verdictDescription]
            if let status = attempt.status { entry["status"] = status }
            if let body = attempt.body { entry["response"] = Self.jsonValue(body) }
            if let error = attempt.error { entry["error"] = error }
            return entry
        }
        var picked: URL?
        if case .video(let url) = lookup.outcome { picked = url }
        report["pickedSquareURL"] = picked?.absoluteString ?? NSNull()
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    #endif

    /// The square motion video for a catalog song's album, or nil (feature off, not a catalog
    /// song, no motion artwork, or the lookup failed).
    public func videoURL(forSongID songID: String) async -> URL? {
        guard MotionArtwork.isEnabled, MotionArtwork.isCatalogID(songID) else { return nil }
        if let albumID = albumIDs[songID], let known = videos[albumID] { return known }
        if let running = inFlight[songID] { return await running.value }
        let task = Task { await resolve(songID) }
        inFlight[songID] = task
        let url = await task.value
        inFlight[songID] = nil
        return url
    }

    private func resolve(_ songID: String) async -> URL? {
        do {
            let albumID: String
            if let known = albumIDs[songID] {
                albumID = known
            } else {
                guard let found = MotionArtwork.albumID(inSongResponse: try await fetch(MotionArtwork.songPath(songID))) else { return nil }
                albumIDs[songID] = found
                albumID = found
            }
            if let known = videos[albumID] { return known }
            let url = MotionArtwork.squareVideoURL(inAlbumResponse: try await fetch(MotionArtwork.albumPath(albumID)))
            videos[albumID] = .some(url)
            #if DEBUG
            print("[motion] song \(songID) album \(albumID): \(url?.absoluteString ?? "no square motion video")")
            #endif
            return url
        } catch {
            #if DEBUG
            print("[motion] song \(songID): lookup failed: \(error)")
            #endif
            return nil
        }
    }

    /// A failed request, with the full URL it was for (thrown by a `FetchReportingURL`, so
    /// `probe` can show the URL of a request that failed).
    public struct RequestError: Error, CustomStringConvertible {
        public var url: String
        public var description: String

        public init(url: String, description: String) {
            self.url = url
            self.description = description
        }
    }

    /// Debug: the raw responses behind a lookup, to check the field names on a real device.
    /// Given a song, fetches it (with its albums) and uses its first album unless `albumID` is
    /// given too. The album request uses `albumQuery` (default: `MotionArtwork.albumQuery`).
    /// Reports each request's full URL, and its error if it failed. Works whether or not the
    /// feature is on; uses no cache.
    public func probe(albumID: String?, songID: String?, albumQuery: MotionArtwork.AlbumQuery = MotionArtwork.albumQuery) async throws -> Data {
        var report: [String: Any] = ["enabled": MotionArtwork.isEnabled]
        var albumID = albumID
        if let songID {
            let path = MotionArtwork.songPath(songID)
            report["songRequest"] = path
            do {
                let (data, url) = try await fetchReportingURL(path)
                let found = MotionArtwork.albumID(inSongResponse: data)
                report["songURL"] = url
                report["songAlbumID"] = found ?? NSNull()
                report["songResponse"] = Self.jsonValue(data)
                albumID = albumID ?? found
            } catch {
                Self.note(error, as: "song", in: &report)
            }
        }
        if let albumID {
            let path = MotionArtwork.albumPath(albumID, query: albumQuery)
            report["albumRequest"] = path
            report["albumID"] = albumID
            do {
                let (data, url) = try await fetchReportingURL(path)
                let editorialVideo = MotionArtwork.editorialVideo(inAlbumResponse: data)
                report["albumURL"] = url
                report["editorialVideoKeys"] = editorialVideo.map { Array($0.keys).sorted() } ?? NSNull()
                report["pickedSquareURL"] = MotionArtwork.squareVideoURL(inAlbumResponse: data)?.absoluteString ?? NSNull()
                report["albumResponse"] = Self.jsonValue(data)
            } catch {
                Self.note(error, as: "album", in: &report)
            }
        }
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func note(_ error: Error, as name: String, in report: inout [String: Any]) {
        if let error = error as? RequestError { report["\(name)URL"] = error.url }
        report["\(name)Error"] = String(describing: error)
    }

    private static func jsonValue(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    }
}

#if DEBUG
/// Debug builds only: a public third-party service that finds an album's Apple Music motion
/// artwork. Two ways to ask:
/// - `GET /api/v1/artwork/url?url=https://music.apple.com/<storefront>/album/<albumId>`: that exact
///   album (its server takes `music.apple.com/(<storefront>/)album/(<slug>/)<digits>`).
/// - `GET /api/v1/artwork/search?artist=…&album=…`: by name, which can land on another edition or
///   another artist's album, so its answer is checked against our names (`namesMatch`).
///
/// Both answer 200 `{"url": "…square….m3u8", "url_tall": "….m3u8" or null, "artist": "…",
/// "album": "…", "isCached": true}`, or 404 `{"message": "No animated artwork found."}` (checked
/// against the live service in October 2026). Used only by `MotionArtworkLookup`, for Apple
/// Music zones.
enum MotionArtworkService {
    /// Loads a URL: the body and HTTP status.
    typealias Load = @Sendable (URL) async throws -> (data: Data, status: Int)

    enum Answer: Equatable {
        case found(URL)
        /// The service has no motion artwork for it.
        case none
        /// Anything else (not remembered).
        case unexpected(status: Int)
    }

    /// How a track's album was asked about.
    enum Route: Equatable, Sendable {
        /// By its exact catalog album: the Apple Music album link sent.
        case albumLink(albumID: String, link: String)
        /// By artist and album name.
        case search
    }

    /// What one request came to.
    enum Verdict: Equatable, Sendable {
        /// A video, and (for a search) the names in the response match ours.
        case accepted(URL)
        /// A search answered with a video for an album with other names (counts as none).
        case rejected(artist: String?, album: String?)
        /// No motion artwork.
        case none
        case unexpected(status: Int)
        /// The request itself failed.
        case failed

        var summary: String {
            switch self {
            case .accepted(let url): url.absoluteString
            case .rejected(let artist, let album): "rejected: answered for \"\(artist ?? "?")\" / \"\(album ?? "?")\""
            case .none: "no animated artwork"
            case .unexpected(let status): "unexpected response (status \(status))"
            case .failed: "request failed"
            }
        }
    }

    struct Attempt: Sendable {
        var url: URL
        /// Whether the names in a found answer were checked against ours (searches).
        var checksNames: Bool
        var status: Int?
        var body: Data?
        var error: String?
        var verdict: Verdict

        /// The verdict as the debug probe shows it.
        var verdictDescription: String {
            switch verdict {
            case .accepted: checksNames ? "accepted: names match" : "accepted: exact album link (names not checked)"
            case .rejected(let artist, let album): "rejected: names differ (service: \"\(artist ?? "?")\" / \"\(album ?? "?")\")"
            case .none: "none: no animated artwork"
            case .unexpected(let status): "unexpected: status \(status) (not remembered)"
            case .failed: "failed (not remembered)"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The square video, or nil when there's none (both remembered).
        case video(URL?)
        /// Couldn't tell (not remembered).
        case failed
    }

    struct Lookup: Sendable {
        var route: Route
        var attempts: [Attempt]
        var outcome: Outcome
    }

    static let searchEndpoint = "https://artwork.m8tec.top/api/v1/artwork/search"
    static let albumLinkEndpoint = "https://artwork.m8tec.top/api/v1/artwork/url"
    static let timeout: TimeInterval = 8
    /// Used when the account's storefront isn't known.
    static let defaultStorefront = "us"

    static let load: Load = { url in
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func searchURL(artist: String, album: String) -> URL? {
        guard var components = URLComponents(string: searchEndpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "album", value: albumTitle(album))]
        // `+` is left alone in query values; encode it so it isn't read as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }

    /// A track's album id if it's a catalog album id (all digits), else nil.
    static func usableAlbumID(_ albumID: String?) -> String? {
        guard let albumID = albumID?.trimmingCharacters(in: .whitespaces), MotionArtwork.isCatalogID(albumID) else { return nil }
        return albumID
    }

    /// The Apple Music link for a catalog album: "https://music.apple.com/us/album/1440833098".
    /// The storefront is lowercased; anything but two letters becomes `defaultStorefront`.
    static func albumLink(albumID: String, storefront: String?) -> String {
        let code = storefront?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let valid = code.count == 2 && code.allSatisfy { $0.isASCII && $0.isLetter }
        return "https://music.apple.com/\(valid ? code : defaultStorefront)/album/\(albumID)"
    }

    /// The service request for an album link.
    static func albumLinkURL(_ link: String) -> URL? {
        guard var components = URLComponents(string: albumLinkEndpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        return components.url
    }

    /// The album's title without Apple Music's release-type suffix ("Forever - Single" → "Forever").
    static func albumTitle(_ album: String) -> String {
        for suffix in [" - Single", " - EP"] {
            if let range = album.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                return String(album[..<range.lowerBound])
            }
        }
        return album
    }

    /// The artist and album a service answer is for.
    struct Names: Equatable, Sendable {
        var artist: String?
        var album: String?
    }

    static func names(in data: Data) -> Names {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Names(artist: root?["artist"] as? String, album: root?["album"] as? String)
    }

    /// Text for comparing names: case and diacritics folded, apostrophes dropped ("Don't" =
    /// "Dont"), every other run of punctuation and whitespace one space, trimmed.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "`", "\u{00B4}"]
        var result = ""
        var gap = false
        for character in folded where !apostrophes.contains(character) {
            if character.isLetter || character.isNumber {
                if gap, !result.isEmpty { result.append(" ") }
                gap = false
                result.append(character)
            } else {
                gap = true
            }
        }
        return result
    }

    /// Whether a search answer is for our album: its album equals ours, and its artist equals our
    /// whole artist string or our first artist, after `normalized` (and without " - Single" /
    /// " - EP" on either album). An answer without names doesn't match.
    static func namesMatch(_ names: Names, artist: String, album: String) -> Bool {
        guard let theirArtist = names.artist, let theirAlbum = names.album else { return false }
        let ourAlbum = comparable(albumTitle(album))
        guard !ourAlbum.isEmpty, comparable(albumTitle(theirAlbum)) == ourAlbum else { return false }
        let answered = comparable(theirArtist)
        return !answered.isEmpty && artistCandidates(artist).contains { comparable($0) == answered }
    }

    /// `normalized`, or for a name with no letters or digits ("÷", "+"), the name with only case
    /// folded and the ends trimmed, so such names can still match.
    private static func comparable(_ text: String) -> String {
        let result = normalized(text)
        return result.isEmpty ? text.trimmingCharacters(in: .whitespaces).lowercased() : result
    }

    /// The artist names to try, in order: the whole artist string, then its first artist when it
    /// lists several ("ILLENIUM, Tom Grennan & Alna" → "ILLENIUM").
    static func artistCandidates(_ artist: String) -> [String] {
        let whole = artist.trimmingCharacters(in: .whitespaces)
        guard !whole.isEmpty else { return [] }
        var first = whole
        for separator in [",", " & ", " feat. ", " feat ", " ft. ", " featuring "] {
            if let range = first.range(of: separator, options: .caseInsensitive) {
                first = String(first[..<range.lowerBound])
            }
        }
        first = first.trimmingCharacters(in: .whitespaces)
        return first.isEmpty || first == whole ? [whole] : [whole, first]
    }

    /// Cache key for a track: its catalog album id when it has one, else its artist and album
    /// name; empty when there's nothing to ask about.
    static func cacheKey(for track: QueueTrack) -> String {
        if let albumID = usableAlbumID(track.albumID) { return "album:" + albumID }
        let key = cacheKey(artist: track.artist, album: track.album)
        return key.isEmpty ? "" : "name:" + key
    }

    /// Cache key for an artist and album; empty when either is missing.
    static func cacheKey(artist: String, album: String) -> String {
        let artist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        let album = album.trimmingCharacters(in: .whitespaces).lowercased()
        return artist.isEmpty || album.isEmpty ? "" : artist + "\n" + album
    }

    static func answer(data: Data, status: Int) -> Answer {
        switch status {
        case 200:
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let string = root?["url"] as? String, let url = URL(string: string),
                  url.scheme?.lowercased() == "https" else { return .none }
            return .found(url)
        case 404: return .none
        default: return .unexpected(status: status)
        }
    }
}
#endif
