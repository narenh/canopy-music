import CanopyMusicCore
import CoreGraphics
import Foundation
import MusicKit

/// Holds MusicKit `Song`s by id so the player can play tracks that came through the provider-agnostic layer.
actor SongCache {
    private var songs: [String: Song] = [:]

    func store(_ newSongs: some Sequence<Song>) {
        for song in newSongs { songs[song.id.rawValue] = song }
    }

    func song(for id: String) async throws -> Song {
        if let song = songs[id] { return song }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try await request.response().items.first else { throw AppleMusicError.songNotFound(id) }
        songs[id] = song
        return song
    }
}

enum AppleMusicError: LocalizedError {
    case songNotFound(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .songNotFound: "That song isn't available on Apple Music."
        case .badResponse: "Apple Music sent back something unexpected."
        }
    }
}

struct AppleMusicCatalog: MusicCatalog {
    let cache: SongCache

    /// Apple Music's search matches whole words, so a half-typed last word ("beac") finds junk.
    /// Its typing suggestions complete it ("…beacons") and come with their own top songs, like the
    /// Music app's search. Gathered without duplicates from those top songs, matches from your
    /// library, a search for the completed phrase and one for exactly what was typed, then ranked
    /// by how well they match (`SearchRanking`).
    func searchSongs(_ term: String) async throws -> [QueueTrack] {
        async let librarySongs = try? searchLibrarySongs(term)
        async let typedSongs = catalogSearch(term)
        let suggestions = try? await MusicCatalogSearchSuggestionsRequest(term: term, includingTopResultsOfTypes: [Song.self]).response()
        let topSongs: [Song] = suggestions?.topResults.compactMap {
            if case .song(let song) = $0 { song } else { nil }
        } ?? []
        // The first suggestion is the likeliest completion; skip it if it's just what was typed.
        var completed = suggestions?.suggestions.first?.searchTerm
        if completed?.caseInsensitiveCompare(term) == .orderedSame { completed = nil }
        let completedSongs = if let completed { (try? await catalogSearch(completed)) ?? [] } else { [Song]() }
        let typed = try await typedSongs
        let library = await librarySongs ?? []
        #if DEBUG
        print("[search] \"\(term)\" → \"\(completed ?? "-")\": top \(topSongs.count), library \(library.count), completed \(completedSongs.count), typed \(typed.count)")
        #endif
        var seen = Set<MusicItemID>()
        let unique = (topSongs + library + completedSongs + typed).filter { seen.insert($0.id).inserted }
        await cache.store(unique)
        // Apple ranks by popularity; put what matches the typed words first (your library ahead).
        let ranked = SearchRanking.rank(unique.map(QueueTrack.init), for: term, library: Set(library.map(\.id.rawValue)))
        return Array(ranked.prefix(40))
    }

    private func catalogSearch(_ term: String) async throws -> [Song] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        return Array(try await request.response().songs)
    }

    /// Library search via the Apple Music API, mapped to catalog songs (https artwork, playable by id).
    private func searchLibrarySongs(_ term: String) async throws -> [Song] {
        let encoded = term.replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let response: LibrarySearchResponse = try await fetch("/v1/me/library/search?term=\(encoded)&types=library-songs&limit=10&include=catalog")
        return try await catalogSongs(for: response.results.librarySongs?.data ?? [])
    }

    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] {
        var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
        request.limit = 25
        return try await request.response().playlists.map { playlist in
            PlaylistSummary(
                id: playlist.id.rawValue, name: playlist.name, subtitle: playlist.curatorName,
                artworkURL: playlist.artwork?.url(width: 300, height: 300), kind: .catalog
            )
        }
    }

    /// Uses the Apple Music API rather than `MusicLibraryRequest` so the ids are cloud library ids,
    /// which can be mapped to catalog songs (and therefore to https artwork phones can load).
    /// Most recently modified first.
    func libraryPlaylists() async throws -> [PlaylistSummary] {
        // Pages are 100 at most. The first page says how many there are, so fetch the rest in
        // parallel (one at a time took ~6 s for 500 playlists).
        let first: APIPage<LibraryPlaylistResource> = try await fetch("/v1/me/library/playlists?limit=100")
        var resources = first.data
        if let total = first.meta?.total, total > first.data.count {
            try await withThrowingTaskGroup(of: [LibraryPlaylistResource].self) { group in
                for offset in stride(from: first.data.count, to: total, by: 100) {
                    group.addTask {
                        let page: APIPage<LibraryPlaylistResource> = try await fetch("/v1/me/library/playlists?limit=100&offset=\(offset)")
                        return page.data
                    }
                }
                for try await page in group { resources += page }
            }
        } else {
            var path = first.next
            while let next = path {
                let page: APIPage<LibraryPlaylistResource> = try await fetch(next)
                resources += page.data
                path = page.next
            }
        }
        // ISO 8601 UTC timestamps sort correctly as strings.
        resources.sort { $0.sortDate > $1.sortDate }
        return resources.map { resource in
            PlaylistSummary(
                id: resource.id, name: resource.attributes?.name ?? "Untitled playlist",
                subtitle: resource.attributes?.lastModifiedDate.flatMap(Self.relativeDate),
                artworkURL: resource.attributes?.artwork?.url(size: 300), kind: .library
            )
        }
    }

    private static func relativeDate(_ iso: String) -> String? {
        guard let date = try? Date(iso, strategy: .iso8601) else { return nil }
        return "Updated " + date.formatted(.relative(presentation: .named))
    }

    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        let songs = switch playlist.kind {
        case .catalog: try await catalogPlaylistSongs(id: playlist.id)
        case .library: try await libraryPlaylistSongs(id: playlist.id)
        }
        await cache.store(songs)
        return songs.map(QueueTrack.init)
    }

    // MARK: Playlist loading

    private func catalogPlaylistSongs(id: String) async throws -> [Song] {
        let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else { return [] }
        guard var batch = try await playlist.with([.tracks]).tracks else { return [] }
        var songs = batch.compactMap(\.song)
        while batch.hasNextBatch, let next = try await batch.nextBatch() {
            songs += next.compactMap(\.song)
            batch = next
        }
        return songs
    }

    /// Library playlist tracks are library songs; map each to its catalog song.
    private func libraryPlaylistSongs(id: String) async throws -> [Song] {
        var resources: [LibrarySongResource] = []
        var path: String? = "/v1/me/library/playlists/\(id)/tracks?limit=100&include=catalog"
        while let next = path {
            let page: APIPage<LibrarySongResource> = try await fetch(next)
            resources += page.data
            path = page.next
        }
        return try await catalogSongs(for: resources)
    }

    /// Maps library songs to their catalog songs, keeping order. Songs with no catalog match
    /// (uploads, removed tracks) can't be played here and are skipped.
    private func catalogSongs(for resources: [LibrarySongResource]) async throws -> [Song] {
        enum Slot { case song(Song), pending(String) }
        let slots: [Slot] = resources.compactMap { resource in
            #if os(tvOS)
            // On tvOS the catalog song that comes with a library track can't start a fresh player:
            // the player's first update then refers to the user's library, which the app can't
            // open, so the player connection drops and polling it blocks the main thread. The same
            // song fetched from the catalog plays, so fetch them all.
            if let id = resource.relationships?.catalog?.data.first?.id.rawValue ?? resource.attributes?.playParams?.catalogId {
                return .pending(id)
            }
            #else
            if let song = resource.relationships?.catalog?.data.first { return .song(song) }
            if let catalogID = resource.attributes?.playParams?.catalogId { return .pending(catalogID) }
            #endif
            return nil
        }

        let pendingIDs = slots.compactMap { if case .pending(let id) = $0 { id } else { nil } }
        var fetched: [String: Song] = [:]
        for chunk in stride(from: 0, to: pendingIDs.count, by: 100).map({ Array(pendingIDs[$0..<min($0 + 100, pendingIDs.count)]) }) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            for song in try await request.response().items { fetched[song.id.rawValue] = song }
        }
        return slots.compactMap { slot in
            switch slot {
            case .song(let song): song
            case .pending(let id): fetched[id]
            }
        }
    }

    #if DEBUG
    static func benchmark() async {
        guard MusicAuthorization.currentStatus == .authorized else {
            print("[bench] Apple Music not authorized; skipping")
            return
        }
        let catalog = AppleMusicCatalog(cache: SongCache())
        let clock = ContinuousClock()
        do {
            var playlists: [PlaylistSummary] = []
            let listTime = try await clock.measure { playlists = try await catalog.libraryPlaylists() }
            print("[bench] library playlists: \(playlists.count) in \(listTime)")
            for playlist in playlists.prefix(4) {
                var count = 0
                let time = try await clock.measure { count = try await catalog.tracks(in: playlist).count }
                print("[bench] \"\(playlist.name)\": \(count) songs in \(time)")
            }
        } catch {
            print("[bench] failed: \(error)")
        }
    }
    #endif

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "https://api.music.apple.com" + path) else { throw AppleMusicError.badResponse }
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        return try JSONDecoder().decode(T.self, from: response.data)
    }
}

// MARK: - Apple Music API shapes

private struct APIPage<Resource: Decodable>: Decodable {
    struct Meta: Decodable { var total: Int? }
    var data: [Resource]
    var next: String?
    var meta: Meta?
}

private struct APIArtwork: Decodable {
    var url: String
    func url(size: Int) -> URL? {
        URL(string: url.replacingOccurrences(of: "{w}", with: "\(size)").replacingOccurrences(of: "{h}", with: "\(size)"))
    }
}

private struct LibraryPlaylistResource: Decodable {
    struct Attributes: Decodable {
        var name: String?
        var artwork: APIArtwork?
        var lastModifiedDate: String?
        var dateAdded: String?
    }
    var id: String
    var attributes: Attributes?

    var sortDate: String { attributes?.lastModifiedDate ?? attributes?.dateAdded ?? "" }
}

private struct LibrarySearchResponse: Decodable {
    struct Results: Decodable {
        var librarySongs: APIPage<LibrarySongResource>?
        enum CodingKeys: String, CodingKey { case librarySongs = "library-songs" }
    }
    var results: Results
}

private struct LibrarySongResource: Decodable {
    struct Attributes: Decodable {
        struct PlayParams: Decodable { var catalogId: String? }
        var playParams: PlayParams?
    }
    struct Relationships: Decodable {
        struct Catalog: Decodable { var data: [Song] }
        var catalog: Catalog?
    }
    var attributes: Attributes?
    var relationships: Relationships?
}

// MARK: - Conversions

private extension MusicKit.Track {
    var song: Song? {
        if case .song(let song) = self { song } else { nil }
    }
}

extension QueueTrack {
    init(_ song: Song) {
        self.init(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            duration: song.duration,
            artworkURL: song.artwork?.url(width: 1200, height: 1200),
            thumbnailURL: song.artwork?.url(width: 160, height: 160),
            colors: song.artwork.flatMap(ArtworkColors.init),
            isExplicit: song.contentRating == .explicit
        )
    }
}

extension ArtworkColors {
    init?(_ artwork: Artwork) {
        guard let background = artwork.backgroundColor?.hex else { return nil }
        self.init(
            background: background,
            primary: artwork.primaryTextColor?.hex ?? "#FFFFFF",
            secondary: artwork.secondaryTextColor?.hex ?? "#CCCCCC"
        )
    }
}

private extension CGColor {
    var hex: String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        let value = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value(c[0]), value(c[1]), value(c[2]))
    }
}
