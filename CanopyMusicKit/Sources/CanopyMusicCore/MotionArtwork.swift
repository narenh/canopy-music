import Foundation

/// Animated ("motion") album artwork, shown only on the iPad's large Now Playing artwork, for
/// Apple Music zones. Experimental: everything about it hangs off `isEnabled`, and removing it
/// means deleting this file, `MotionArtworkView.swift`, the `motionArtwork` lines in `MusicCatalog`
/// and `AppleMusicCatalog`, the overlay line in `NowPlayingView` and `/api/debug/motion`.
///
/// Apple Music API albums can carry an `editorialVideo` attribute when asked for it with
/// `extend=editorialVideo`: HLS (`.m3u8`) videos in several shapes, of which a square one suits
/// the artwork. Only some albums have one.
///
/// The field names here are a best guess, not yet checked against a real response: run
/// `GET /api/debug/motion?song=<id>` (debug builds) on a real device to see what comes back.
public enum MotionArtwork {
    /// The feature switch. Off: no lookups and no video; Now Playing shows the still artwork.
    public static let isEnabled = true

    /// Square motion video entries in `editorialVideo`, best first (unverified names). Other keys
    /// that say "square" or "1x1" come after these.
    static let preferredSquareKeys = ["motionDetailSquare", "motionSquareVideo1x1"]

    /// Catalog API paths, relative to `/v1/catalog/{storefront}/`.
    static func songPath(_ songID: String) -> String { "songs/\(songID)?include=albums" }
    static func albumPath(_ albumID: String) -> String { "albums/\(albumID)?extend=editorialVideo" }

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

    private let fetch: Fetch
    /// Song id → its album id.
    private var albumIDs: [String: String] = [:]
    /// Album id → its square motion video; `.some(nil)` when it has none.
    private var videos: [String: URL?] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

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

    /// Debug: the raw responses behind a lookup, to check the field names on a real device.
    /// Given a song, fetches it (with its albums) and uses its first album unless `albumID` is
    /// given too. Works whether or not the feature is on; uses no cache.
    public func probe(albumID: String?, songID: String?) async throws -> Data {
        var report: [String: Any] = ["enabled": MotionArtwork.isEnabled]
        var albumID = albumID
        if let songID {
            let path = MotionArtwork.songPath(songID)
            let data = try await fetch(path)
            let found = MotionArtwork.albumID(inSongResponse: data)
            report["songRequest"] = path
            report["songAlbumID"] = found ?? NSNull()
            report["songResponse"] = Self.jsonValue(data)
            albumID = albumID ?? found
        }
        if let albumID {
            let path = MotionArtwork.albumPath(albumID)
            let data = try await fetch(path)
            let editorialVideo = MotionArtwork.editorialVideo(inAlbumResponse: data)
            report["albumRequest"] = path
            report["albumID"] = albumID
            report["editorialVideoKeys"] = editorialVideo.map { Array($0.keys).sorted() } ?? NSNull()
            report["pickedSquareURL"] = MotionArtwork.squareVideoURL(inAlbumResponse: data)?.absoluteString ?? NSNull()
            report["albumResponse"] = Self.jsonValue(data)
        }
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func jsonValue(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    }
}
