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
/// Debug builds only: when the Apple Music API finds nothing, a public third-party service
/// (`MotionArtworkService`, artwork.m8tec.top) is asked by artist and album name. It doesn't
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

    private let fetchReportingURL: FetchReportingURL
    /// Song id → its album id.
    private var albumIDs: [String: String] = [:]
    /// Album id → its square motion video; `.some(nil)` when it has none.
    private var videos: [String: URL?] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    #if DEBUG
    /// Loads a `MotionArtworkService` URL (swapped out in tests).
    private var serviceLoad: MotionArtworkService.Load = MotionArtworkService.load
    /// `MotionArtworkService.cacheKey` → its square video; `.some(nil)` when it has none.
    private var serviceVideos: [String: URL?] = [:]
    #endif

    public init(fetch: @escaping Fetch) {
        self.fetchReportingURL = { path in (try await fetch(path), path) }
    }

    public init(fetchReportingURL: @escaping FetchReportingURL) {
        self.fetchReportingURL = fetchReportingURL
    }

    #if DEBUG
    init(fetch: @escaping Fetch, serviceLoad: @escaping MotionArtworkService.Load) {
        self.fetchReportingURL = { path in (try await fetch(path), path) }
        self.serviceLoad = serviceLoad
    }
    #endif

    private func fetch(_ path: String) async throws -> Data {
        try await fetchReportingURL(path).data
    }

    /// The square motion video for a track, from `MotionArtworkService` by its artist and album
    /// (debug builds, `usesThirdPartyService`). The Apple Music API isn't asked: it doesn't return
    /// motion artwork to our token (checked on a real Apple TV, every variant). nil when the
    /// service has none, the feature is off, the lookup failed, or this is a Release build.
    public func videoURL(for track: QueueTrack) async -> URL? {
        guard MotionArtwork.isEnabled else { return nil }
        #if DEBUG
        if MotionArtwork.usesThirdPartyService { return await serviceVideoURL(artist: track.artist, album: track.album) }
        #endif
        return nil
    }

    #if DEBUG
    /// The service's square video for an album, remembered per artist and album (also when it has
    /// none). Failures are silent and not remembered.
    private func serviceVideoURL(artist: String, album: String) async -> URL? {
        let key = MotionArtworkService.cacheKey(artist: artist, album: album)
        guard !key.isEmpty else { return nil }
        if let known = serviceVideos[key] { return known }
        var found: URL?
        for candidate in MotionArtworkService.artistCandidates(artist) {
            guard let url = MotionArtworkService.searchURL(artist: candidate, album: album) else { continue }
            let answer: MotionArtworkService.Answer
            do {
                let (data, status) = try await serviceLoad(url)
                answer = MotionArtworkService.answer(data: data, status: status)
            } catch {
                print("[motion] service \"\(candidate)\" / \"\(album)\": failed: \(error)")
                return nil
            }
            switch answer {
            case .found(let url): found = url
            case .none: continue
            case .unexpected(let status):
                print("[motion] service \"\(candidate)\" / \"\(album)\": unexpected response (status \(status))")
                return nil
            }
            if found != nil { break }
        }
        serviceVideos[key] = .some(found)
        print("[motion] service \"\(artist)\" / \"\(album)\": \(found?.absoluteString ?? "no animated artwork")")
        return found
    }

    /// Debug: what `MotionArtworkService` answers for an artist and album, for each artist name
    /// tried, without the cache.
    public func probeService(artist: String, album: String) async throws -> Data {
        var report: [String: Any] = [
            "enabled": MotionArtwork.isEnabled, "usesThirdPartyService": MotionArtwork.usesThirdPartyService,
            "artist": artist, "album": album,
        ]
        var attempts: [[String: Any]] = []
        var picked: URL?
        for candidate in MotionArtworkService.artistCandidates(artist) where picked == nil {
            guard let url = MotionArtworkService.searchURL(artist: candidate, album: album) else { continue }
            var attempt: [String: Any] = ["url": url.absoluteString]
            do {
                let (data, status) = try await serviceLoad(url)
                attempt["status"] = status
                attempt["response"] = Self.jsonValue(data)
                if case .found(let video) = MotionArtworkService.answer(data: data, status: status) { picked = video }
            } catch {
                attempt["error"] = String(describing: error)
            }
            attempts.append(attempt)
        }
        report["requests"] = attempts
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
/// artwork by artist and album name. `GET /api/v1/artwork/search?artist=…&album=…` answers 200
/// `{"url": "…square….m3u8", "url_tall": "….m3u8", …}`, or 404 `{"message": "No animated
/// artwork found."}`. Used only as `MotionArtworkLookup`'s fallback, for Apple Music zones.
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

    static let searchEndpoint = "https://artwork.m8tec.top/api/v1/artwork/search"
    static let timeout: TimeInterval = 8

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

    /// The album's title without Apple Music's release-type suffix ("Forever - Single" → "Forever").
    static func albumTitle(_ album: String) -> String {
        for suffix in [" - Single", " - EP"] where album.hasSuffix(suffix) {
            return String(album.dropLast(suffix.count))
        }
        return album
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
