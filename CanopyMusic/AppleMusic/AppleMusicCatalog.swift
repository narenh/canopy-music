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
    /// Which catalog song each unlabelled library track (iTunes Match / uploads) turned out to be.
    var memory: CatalogMatchMemory = .shared
    /// How the most recent library playlist loads went, including which tracks were left out.
    var reports = PlaylistLoadReports()

    /// Tracks left out of the last library playlist loaded through this catalog (not on Apple Music,
    /// or no confident match). 0 before any library playlist has loaded.
    var lastSkippedCount: Int {
        get async { await reports.last?.skippedCount ?? 0 }
    }

    /// How loading `playlist` went the last time, or nil if it hasn't been loaded (or isn't a library playlist).
    func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
        await reports.report(for: playlist.id)
    }

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
        // Uses remembered matches for uploads but doesn't search for them: this runs as you type.
        return try await catalogSongs(for: response.results.librarySongs?.data ?? [], searchUnlabelled: false).songs
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
        let (songs, report) = try await catalogSongs(for: resources, playlistID: id)
        await reports.record(report)
        #if DEBUG
        if report.skippedCount > 0 || report.unlabelled > 0 {
            print("[match] playlist \(id): loaded \(report.loaded) of \(report.total); unlabelled \(report.unlabelled) (memory \(report.matchedFromMemory), search \(report.matchedBySearch)); skipped \(report.skippedCount)")
        }
        #endif
        return songs
    }

    /// Maps library songs to their catalog songs, keeping order. Most come with their catalog song
    /// or its id. iTunes Match and uploaded copies come with neither, so they're found by searching
    /// the catalog for a song with the same title, artist, album and length (`CatalogMatching`),
    /// remembered for next time. Songs with no catalog match can't be played here and are skipped.
    private func catalogSongs(
        for resources: [LibrarySongResource], playlistID: String = "", searchUnlabelled: Bool = true
    ) async throws -> (songs: [Song], report: PlaylistLoadReport) {
        enum Slot { case song(Song), pending(String), remembered(String), search, skip }
        var report = PlaylistLoadReport(playlistID: playlistID)
        report.total = resources.count
        var slots: [Slot] = []
        for resource in resources {
            if let attached = resource.relationships?.catalog?.data.first {
                report.withCatalogSong += 1
                #if os(tvOS)
                // On tvOS the catalog song that comes with a library track can't start a fresh player:
                // the player's first update then refers to the user's library, which the app can't
                // open, so the player connection drops and polling it blocks the main thread. The same
                // song fetched from the catalog plays, so fetch them all.
                slots.append(.pending(attached.id.rawValue))
                #else
                slots.append(.song(attached))
                #endif
            } else if let catalogID = resource.attributes?.playParams?.catalogId {
                report.withCatalogIDOnly += 1
                slots.append(.pending(catalogID))
            } else {
                report.unlabelled += 1
                let recall: CatalogMatchMemory.Recall = if let id = resource.id { await memory.recall(id) } else { .unknown }
                switch recall {
                case .match(let catalogID): slots.append(.remembered(catalogID))
                case .recentMiss: report.recentlyUnmatched += 1; slots.append(.skip)
                case .unknown: slots.append(searchUnlabelled ? .search : .skip)
                }
            }
        }

        // Everything with a known catalog id, in batches of 100.
        let pendingIDs = slots.compactMap { slot -> String? in
            switch slot {
            case .pending(let id), .remembered(let id): id
            default: nil
            }
        }
        var fetched: [String: Song] = [:]
        for chunk in stride(from: 0, to: pendingIDs.count, by: 100).map({ Array(pendingIDs[$0..<min($0 + 100, pendingIDs.count)]) }) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            for song in try await request.response().items { fetched[song.id.rawValue] = song }
        }

        // A remembered song that's gone from the catalog gets searched for again.
        var changedMemory = false
        for index in slots.indices {
            guard case .remembered(let id) = slots[index], fetched[id] == nil else { continue }
            if let libraryID = resources[index].id { await memory.forget(libraryID) }
            changedMemory = true
            slots[index] = searchUnlabelled ? .search : .skip
        }

        let searchIndices = slots.indices.filter { if case .search = slots[$0] { true } else { false } }
        let found = await searchCatalog(for: searchIndices.map { (index: $0, wanted: resources[$0].track) })
        for (index, outcome) in found {
            guard let libraryID = resources[index].id else { continue }
            switch outcome {
            case .found(let song): await memory.remember(song.id.rawValue, for: libraryID)
            case .noMatch: await memory.remember(nil, for: libraryID)
            case .failed: continue  // Try again next load.
            }
            changedMemory = true
        }
        if changedMemory { await memory.save() }

        var songs: [Song] = []
        for (index, slot) in slots.enumerated() {
            let song: Song? = switch slot {
            case .song(let song): song
            case .pending(let id): fetched[id]
            case .remembered(let id): fetched[id]
            case .search: if case .found(let song) = found[index] { song } else { nil }
            case .skip: nil
            }
            if let song {
                songs.append(song)
                if case .remembered = slot { report.matchedFromMemory += 1 }
                if case .search = slot { report.matchedBySearch += 1 }
            } else {
                report.skipped.append(resources[index].track)
            }
        }
        report.loaded = songs.count
        return (songs, report)
    }

    private enum SearchOutcome: Sendable {
        case found(Song)
        case noMatch
        case failed
    }

    /// Catalog searches for unlabelled library tracks, a few at a time, keyed by the given index.
    private func searchCatalog(for lookups: [(index: Int, wanted: QueueTrack)]) async -> [Int: SearchOutcome] {
        let maxConcurrent = 6
        return await withTaskGroup(of: (Int, SearchOutcome).self) { group in
            var results: [Int: SearchOutcome] = [:]
            var next = 0
            func startNext() {
                guard next < lookups.count else { return }
                let lookup = lookups[next]
                next += 1
                group.addTask { (lookup.index, await findCatalogSong(matching: lookup.wanted)) }
            }
            for _ in 0..<maxConcurrent { startNext() }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                startNext()
            }
            return results
        }
    }

    private func findCatalogSong(matching wanted: QueueTrack) async -> SearchOutcome {
        guard !wanted.title.isEmpty, !wanted.artist.isEmpty else { return .noMatch }
        var request = MusicCatalogSearchRequest(term: CatalogMatching.searchTerm(for: wanted), types: [Song.self])
        request.limit = 10
        do {
            let songs = try await request.response().songs
            let candidates = songs.map {
                QueueTrack(id: $0.id.rawValue, title: $0.title, artist: $0.artistName, album: $0.albumTitle ?? "", duration: $0.duration)
            }
            guard let best = CatalogMatching.bestMatch(among: candidates, for: wanted),
                  let song = songs.first(where: { $0.id.rawValue == best.id }) else { return .noMatch }
            return .found(song)
        } catch {
            #if DEBUG
            print("[match] search for \"\(wanted.title)\" failed: \(error)")
            #endif
            return .failed
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

    #if DEBUG
    /// `-diagnosePlaylist <name>`: how the tracks of the library playlist whose name is (or
    /// contains) `name` map to catalog songs, written to Library/Caches/playlist-diagnosis.txt.
    /// Loads it twice through `tracks(in:)`: the second load should need no searches.
    /// Add `-forgetCatalogMatches` to clear remembered matches first, to see the searches again.
    static func diagnosePlaylist(named name: String) async {
        let file = URL.cachesDirectory.appending(path: "playlist-diagnosis.txt")
        var out = "Playlist diagnosis: \"\(name)\" (\(Date.now.formatted(.iso8601)))\n"
        func note(_ line: String) { out += line + "\n" }
        defer {
            try? out.write(to: file, atomically: true, encoding: .utf8)
            print("[diagnose] wrote \(file.path)\n\(out)")
        }
        guard MusicAuthorization.currentStatus == .authorized else { note("Apple Music not authorized"); return }
        let catalog = AppleMusicCatalog(cache: SongCache())
        if ProcessInfo.processInfo.arguments.contains("-forgetCatalogMatches") {
            await catalog.memory.forgetEverything()
            await catalog.memory.save()
            note("forgot remembered matches first")
        }
        do {
            let all = try await catalog.libraryPlaylists()
            guard let playlist = all.first(where: { $0.name == name })
                    ?? all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
                note("no library playlist named or containing that (of \(all.count))")
                return
            }
            note("playlist: \(playlist.name) id=\(playlist.id)")
            let clock = ContinuousClock()
            for attempt in ["first load", "second load"] {
                var tracks: [QueueTrack] = []
                let time = try await clock.measure { tracks = try await catalog.tracks(in: playlist) }
                guard let r = await catalog.loadReport(for: playlist) else { note("\(attempt): no report"); continue }
                let unmatched = r.unlabelled - r.matchedFromMemory - r.matchedBySearch
                note("")
                note("\(attempt) (\(time.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))):")
                note("  tracks: \(r.total)")
                note("  with catalog song attached: \(r.withCatalogSong)")
                note("  catalog id only: \(r.withCatalogIDOnly)")
                note("  neither (iTunes Match / uploads): \(r.unlabelled)")
                note("    resolved: \(r.matchedFromMemory + r.matchedBySearch) (from memory \(r.matchedFromMemory), by search \(r.matchedBySearch))")
                note("    unresolved: \(unmatched) (of which no-match remembered from an earlier load: \(r.recentlyUnmatched))")
                note("  catalog ids that didn't come back: \(r.skippedCount - unmatched)")
                note("  skipped: \(r.skippedCount); lastSkippedCount: \(await catalog.lastSkippedCount)")
                note("  app loads: \(tracks.count) of \(r.total)")
                if attempt == "first load" {
                    for track in r.skipped {
                        let length = track.duration.map { " \(Int($0) / 60):\(String(format: "%02d", Int($0) % 60))" } ?? ""
                        note("    skipped: \(track.title) – \(track.artist) [\(track.album)]\(length) (\(track.id))")
                    }
                }
            }
        } catch {
            note("error: \(error)")
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
        var name: String?
        var artistName: String?
        var albumName: String?
        var durationInMillis: Int?
    }
    struct Relationships: Decodable {
        struct Catalog: Decodable { var data: [Song] }
        var catalog: Catalog?
    }
    /// The library song id ("i.…").
    var id: String?
    var attributes: Attributes?
    var relationships: Relationships?

    /// The track as the library describes it (id is the library id).
    var track: QueueTrack {
        QueueTrack(
            id: id ?? "", title: attributes?.name ?? "", artist: attributes?.artistName ?? "",
            album: attributes?.albumName ?? "", duration: attributes?.durationInMillis.map { TimeInterval($0) / 1000 }
        )
    }
}

/// The latest `PlaylistLoadReport` per playlist, and the very latest.
actor PlaylistLoadReports {
    private(set) var last: PlaylistLoadReport?
    private var byPlaylist: [String: PlaylistLoadReport] = [:]

    func record(_ report: PlaylistLoadReport) {
        last = report
        byPlaylist[report.playlistID] = report
    }

    func report(for playlistID: String) -> PlaylistLoadReport? {
        byPlaylist[playlistID]
    }
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
