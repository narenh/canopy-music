import CanopyMusicCore
import CoreGraphics
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif
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

    /// The song to play for `track`: a song only in the library (`QueueTrack.isLibraryOnly`) from
    /// the library, by its library id (the player plays it as it does a catalog song); anything
    /// else, a library copy of a catalog song included, from the catalog by its id.
    func song(for track: QueueTrack) async throws -> Song {
        guard track.isLibraryOnly, let libraryID = track.libraryID else { return try await song(for: track.id) }
        if let song = songs[libraryID] { return song }
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(libraryID))
        guard let song = try await request.response().items.first else { throw AppleMusicError.librarySongNotFound(libraryID) }
        songs[libraryID] = song
        return song
    }
}

enum AppleMusicError: LocalizedError {
    case songNotFound(String)
    case librarySongNotFound(String)
    /// tvOS: a song only in the library didn't start, or the player stopped answering
    /// (`AppleMusicEngine.libraryStartDeadline`).
    case libraryPlaybackStalled
    case badResponse

    var errorDescription: String? {
        switch self {
        case .songNotFound: "That song isn't available on Apple Music."
        case .librarySongNotFound: "That song isn't in this Apple Music library."
        case .libraryPlaybackStalled: "That library song didn't start playing."
        case .badResponse: "Apple Music sent back something unexpected."
        }
    }
}

struct AppleMusicCatalog: MusicCatalog {
    let cache: SongCache
    /// Which catalog song each unlabelled library track (iTunes Match / uploads) turned out to be.
    var memory: CatalogMatchMemory = .shared
    /// Library songs' artwork templates as playlists and searches list them, for the hub's relay.
    var artworkHints: LibraryArtworkHints = .shared
    /// How the most recent library playlist loads went, including which tracks were left out.
    var reports = PlaylistLoadReports()
    /// The songs of library albums a host's search named, by album, and the library searches it
    /// made, kept across keystrokes (`searchLibrarySongs`).
    private let albumTracks = KeptResults<[LibrarySongResource]>(lifetime: 10 * 60)
    private let librarySearches = KeptResults<LibrarySearchResponse.Results>(lifetime: 2 * 60)
    /// Animated album artwork for Now Playing (see `MotionArtwork`).
    let motionArtwork: MotionArtworkLookup? = MotionArtworkLookup(
        fetchReportingURL: AppleMusicCatalog.catalogData,
        storefront: { try? await MusicDataRequest.currentCountryCode }
    )

    /// Tracks left out of the last library playlist loaded through this catalog (no usable library
    /// id, or a catalog id the catalog doesn't know; songs only in the library play from it). 0
    /// before any library playlist has loaded.
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
    /// by how well they match (`SearchRanking`). Guests' search: the library's songs come as the
    /// catalog songs they are.
    func searchSongs(_ term: String) async throws -> [QueueTrack] {
        try await searchSongs(term, includingLibrary: false)
    }

    /// `includingLibrary` (a host's search): the library's songs come as its own copies (its art
    /// and titles), songs only in the library too, and each song once (`LibraryDuplicates`).
    func searchSongs(_ term: String, includingLibrary: Bool) async throws -> [QueueTrack] {
        async let librarySongs = try? searchLibrarySongs(term, byAlbum: includingLibrary)
        async let typedSongs = catalogSearch(term)
        let suggestions = try? await MusicCatalogSearchSuggestionsRequest(term: term, includingTopResultsOfTypes: [Song.self]).response()
        let topSongs: [Song] = suggestions?.topResults.compactMap {
            if case .song(let song) = $0 { song } else { nil }
        } ?? []
        // The first suggestion is the likeliest completion; skip it if it's just what was typed.
        var completed = suggestions?.suggestions.first?.searchTerm
        if completed?.caseInsensitiveCompare(term) == .orderedSame { completed = nil }
        let completedSongs = if let completed { (try? await catalogSearch(completed)) ?? [] } else { [Song]() }
        let typed: [Song]
        do {
            typed = try await typedSongs
        } catch {
            #if DEBUG
            print("[search] \"\(term)\" catalog search failed: \(Self.describe(error))")
            #endif
            throw error
        }
        let library = await librarySongs ?? []
        let libraryCatalogSongs = library.compactMap(\.song)
        #if DEBUG
        print("[search] \"\(term)\" → \"\(completed ?? "-")\": top \(topSongs.count), library \(library.count) (\(library.count - libraryCatalogSongs.count) library only), completed \(completedSongs.count), typed \(typed.count)")
        #endif
        var seen = Set<MusicItemID>()
        let unique = (topSongs + libraryCatalogSongs + completedSongs + typed).filter { seen.insert($0.id).inserted }
        await cache.store(unique)
        let tracks: [QueueTrack]
        if includingLibrary {
            let results: [LibraryDuplicates.Result] = topSongs.map { .catalog(QueueTrack($0)) }
                + library.map { .library($0.result) }
                + (completedSongs + typed).map { .catalog(QueueTrack($0)) }
            tracks = LibraryDuplicates.collapse(results)
        } else {
            tracks = unique.map(QueueTrack.init)
        }
        // Apple ranks by popularity; put what matches the typed words first (your library ahead).
        let ranked = SearchRanking.rank(tracks, for: term, library: Set(library.map(\.result.track.id)))
        return Array(ranked.prefix(40))
    }

    private func catalogSearch(_ term: String) async throws -> [Song] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        return Array(try await request.response().songs)
    }

    /// Library search via the Apple Music API, mapped to catalog songs (https artwork, playable by
    /// id) where they have one; the rest are songs only in the library. `byAlbum` (a host's
    /// search): the songs of the library albums the words name too, which the song search doesn't
    /// find by album title (`LibraryAlbumSearch`), from the same request; each album's tracks are
    /// fetched once and kept a while (`LibraryAlbumTracks`), so typing on costs nothing more.
    private func searchLibrarySongs(_ term: String, byAlbum: Bool) async throws -> [LoadedTrack] {
        let types = byAlbum ? "library-songs,library-albums" : "library-songs"
        // A host's: also with fewer words, kept where every typed word is in the song's title,
        // artist or album (`LibraryAlbumSearch`). Both at once; each answer kept a while.
        let broader = byAlbum ? LibraryAlbumSearch.broaderTerm(for: term) : nil
        async let fullResults = librarySearch(term, types: types)
        async let broadResults = broadLibrarySearch(broader, types: types)
        let full: LibrarySearchResponse.Results
        do {
            full = try await fullResults
        } catch {
            #if DEBUG
            print("[search] \"\(term)\" library search failed: \(Self.describe(error))")
            #endif
            throw error
        }
        let broad = await broadResults
        var resources = full.librarySongs?.data ?? []
        var seen = Set(resources.compactMap(\.id))
        let broadSongs = (broad?.librarySongs?.data ?? []).filter { song in
            LibraryAlbumSearch.matches(title: song.attributes?.name ?? "", artist: song.attributes?.artistName ?? "",
                                       album: song.attributes?.albumName ?? "", term: term)
        }
        resources += broadSongs.filter { $0.id.map { seen.insert($0).inserted } ?? true }
        var wanted: [LibraryAlbumSearch.Album] = []
        var albumSongs = 0
        if byAlbum {
            var albumIDs = Set<String>()
            let albums = ((full.libraryAlbums?.data ?? []) + (broad?.libraryAlbums?.data ?? [])).filter { albumIDs.insert($0.id).inserted }.map {
                LibraryAlbumSearch.Album(id: $0.id, name: $0.attributes?.name ?? "", artist: $0.attributes?.artistName ?? "")
            }
            wanted = LibraryAlbumSearch.albumsToExpand(albums, for: term)
            let tracks = await withTaskGroup(of: (String, [LibrarySongResource]).self) { group in
                for album in wanted {
                    group.addTask { (album.id, (try? await albumTracks.value(for: album.id) { try await libraryAlbumSongs(id: album.id) }) ?? []) }
                }
                var tracks: [String: [LibrarySongResource]] = [:]
                for await (id, songs) in group { tracks[id] = songs }
                return tracks
            }
            let added = LibraryAlbumSearch.songs(of: wanted, from: tracks).filter { $0.id.map { seen.insert($0).inserted } ?? true }
            albumSongs = added.count
            resources += added
        }
        #if DEBUG
        // Every search: what the API sent (an API miss) and what was kept (our filter).
        let broadLine = broader.map { "; broader \"\($0)\": songs \(broad?.librarySongs?.data.count ?? 0) (\(broadSongs.count) match), albums \(broad?.libraryAlbums?.data.count ?? 0)" } ?? ""
        print("[search] \"\(term)\" library: songs \(full.librarySongs?.data.count ?? 0), albums \(full.libraryAlbums?.data.count ?? 0)\(broadLine); "
              + "albums expanded \(wanted.map(\.name)) (+\(albumSongs) songs); library songs \(resources.count)")
        #endif
        // Uses remembered matches for uploads but doesn't search for them: this runs as you type.
        return try await catalogSongs(for: resources, searchUnlabelled: false).loaded
    }

    /// The API's library search for `term`, kept a couple of minutes (`librarySearches`): typing
    /// asks for the same broader words, and backspacing for the same words, again.
    private func librarySearch(_ term: String, types: String) async throws -> LibrarySearchResponse.Results {
        let encoded = term.replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        return try await librarySearches.value(for: "\(types)|\(term.lowercased())") {
            let response: LibrarySearchResponse = try await fetch("/v1/me/library/search?term=\(encoded)&types=\(types)&limit=25&include=catalog")
            return response.results
        }
    }

    private func broadLibrarySearch(_ term: String?, types: String) async -> LibrarySearchResponse.Results? {
        guard let term else { return nil }
        return try? await librarySearch(term, types: types)
    }

    /// A library album's songs, with their catalog songs, up to 100 (one page; a search adds
    /// `LibraryAlbumSearch.maxSongs` at most), each marked with the album, for its art
    /// (`LibraryArtworkHints.albumKey`).
    private func libraryAlbumSongs(id: String) async throws -> [LibrarySongResource] {
        let page: APIPage<LibrarySongResource> = try await fetch("/v1/me/library/albums/\(id)/tracks?limit=100&include=catalog")
        return page.data.map { song in
            var song = song
            var relationships = song.relationships ?? .init()
            relationships.albums = .init(data: [.init(id: id)])
            song.relationships = relationships
            return song
        }
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

    /// A library playlist's songs are the library's copies (`QueueTrack.libraryCopy`: its art and
    /// titles, played as their catalog songs), and its songs only in the library are those.
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        switch playlist.kind {
        case .catalog:
            let songs = try await catalogPlaylistSongs(id: playlist.id)
            await cache.store(songs)
            return songs.map(QueueTrack.init)
        case .library:
            let loaded = try await libraryPlaylistSongs(id: playlist.id)
            await cache.store(loaded.compactMap(\.song))
            return loaded.map(\.result.track)
        }
    }

    /// The library playlist list has no track count (nor does any library playlist attribute),
    /// and its tracks relationship comes only with one playlist by id, so each is counted on its
    /// own, as its row appears (`PlaylistSongCounts`): its tracks, without their catalog songs,
    /// 100 a page. A `meta.total` answers at once if the API sends one; an empty playlist's tracks
    /// are a 404. Catalog playlists (search results) aren't counted: they aren't empty.
    func songCount(of playlist: PlaylistSummary) async throws -> Int? {
        guard playlist.kind == .library else { return nil }
        struct Entry: Decodable {}
        var count = 0
        var path: String? = "/v1/me/library/playlists/\(playlist.id)/tracks?limit=100"
        while let next = path {
            let page: APIPage<Entry>
            do {
                page = try await fetch(next)
            } catch where count == 0 && Self.isNotFound(error) {
                return 0
            }
            if let total = page.meta?.total { return total }
            count += page.data.count
            path = page.next
        }
        return count
    }

    /// Apple Music's answer for the tracks of a library playlist that has none.
    private static func isNotFound(_ error: Error) -> Bool {
        (error as? MusicDataRequest.Error)?.status == 404
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

    /// Library playlist tracks are library songs; map each to its catalog song. With each one's
    /// library album, so the relay downloads an album's art once (`LibraryArtworkHints.albumKey`):
    /// its songs needn't credit the same artist. Without, if the API won't.
    private func libraryPlaylistSongs(id: String) async throws -> [LoadedTrack] {
        var resources: [LibrarySongResource] = []
        let withAlbums = "/v1/me/library/playlists/\(id)/tracks?limit=100&include=catalog,albums"
        var path: String? = withAlbums
        while let next = path {
            let page: APIPage<LibrarySongResource>
            do {
                page = try await fetch(next)
            } catch where resources.isEmpty && Self.isNotFound(error) {
                // An empty playlist has no tracks to find: it loads empty (`PlaylistLoadError`).
                break
            } catch where next == withAlbums {
                path = "/v1/me/library/playlists/\(id)/tracks?limit=100&include=catalog"
                continue
            }
            resources += page.data
            path = page.next
        }
        let (loaded, report) = try await catalogSongs(for: resources, playlistID: id)
        await reports.record(report)
        // Searches' art is kept with the next playlist's: they run as a host types.
        await artworkHints.save()
        #if DEBUG
        if report.skippedCount > 0 || report.unlabelled > 0 {
            print("[match] playlist \(id): loaded \(report.loaded) of \(report.total); unlabelled \(report.unlabelled) (memory \(report.matchedFromMemory), search \(report.matchedBySearch), library only \(report.libraryOnly)); skipped \(report.skippedCount)")
        }
        #endif
        return loaded
    }

    /// A library song as loaded: its catalog song when it has one, and the track it queues as (the
    /// library's copy of that song, or a song only in the library), for `LibraryDuplicates`.
    private struct LoadedTrack {
        var song: Song?
        var result: LibraryDuplicates.LibraryResult
    }

    /// Maps library songs to their catalog songs, keeping order. Most come with their catalog song
    /// or its id. iTunes Match and uploaded copies come with neither, so they're found by searching
    /// the catalog for a song with the same title, artist, album and length (`CatalogMatching`),
    /// remembered for next time. Each becomes the library's copy of its catalog song. Ones with no
    /// catalog match (an upload, or a match that's unknown or failed) play from the library
    /// (`QueueTrack.isLibraryOnly`). Only a track the library gives no usable id is skipped, or one
    /// whose catalog id the catalog doesn't know.
    private func catalogSongs(
        for resources: [LibrarySongResource], playlistID: String = "", searchUnlabelled: Bool = true
    ) async throws -> (loaded: [LoadedTrack], report: PlaylistLoadReport) {
        enum Slot { case song(Song), pending(String), remembered(String), search, skip }
        var report = PlaylistLoadReport(playlistID: playlistID)
        report.total = resources.count
        var slots: [Slot] = []
        // Each library song's art as listed here, so the relay downloads it with no lookup.
        await artworkHints.record(resources.compactMap { resource in
            resource.libraryID.map {
                LibraryArtworkHints.Listing(libraryID: $0, template: resource.attributes?.artwork?.url,
                                            album: resource.attributes?.albumName ?? "", artist: resource.attributes?.artistName ?? "",
                                            albumID: resource.libraryAlbumID)
            }
        })
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
        let searched = await searchCatalog(for: searchIndices.map { (index: $0, wanted: resources[$0].track) })
        report.searchConcurrency = searched.finalConcurrency
        for (index, result) in searched.results {
            report.searches += 1
            report.searchAttempts += result.attempts
            report.searchRetries += max(0, result.attempts - 1)
            report.searchErrors += result.errors
            if case .found = result.outcome, result.attempts > 1 { report.resolvedAfterRetry += 1 }
            if case .failed = result.outcome { report.searchesFailed += 1 }
            guard let libraryID = resources[index].id else { continue }
            switch result.outcome {
            case .found(let song): await memory.remember(song.id.rawValue, for: libraryID)
            case .noMatch: await memory.remember(nil, for: libraryID)
            case .failed: continue  // Errors every time: try again next load.
            }
            changedMemory = true
        }
        if changedMemory { await memory.save() }

        var loaded: [LoadedTrack] = []
        for (index, slot) in slots.enumerated() {
            let resource = resources[index]
            let song: Song? = switch slot {
            case .song(let song): song
            case .pending(let id): fetched[id]
            case .remembered(let id): fetched[id]
            case .search: if case .found(let song) = searched.results[index]?.outcome { song } else { nil }
            case .skip: nil
            }
            let hasArtwork = resource.attributes?.artwork != nil
            if let song {
                let track = resource.libraryID.map { QueueTrack(song).libraryCopy(libraryID: $0, title: resource.attributes?.name,
                                                                                   artist: resource.attributes?.artistName,
                                                                                   album: resource.attributes?.albumName) }
                    ?? QueueTrack(song)
                loaded.append(LoadedTrack(song: song, result: .init(track: track, isAppleMusicCopy: !resource.isUnlabelled, hasArtwork: hasArtwork)))
                if case .remembered = slot { report.matchedFromMemory += 1 }
                if case .search = slot { report.matchedBySearch += 1 }
            } else if resource.isUnlabelled, let track = resource.libraryOnlyTrack {
                // No catalog song: it plays from the library.
                loaded.append(LoadedTrack(song: nil, result: .init(track: track, isAppleMusicCopy: false, hasArtwork: hasArtwork)))
                report.libraryOnly += 1
            } else {
                report.skipped.append(resource.track)
            }
        }
        report.loaded = loaded.count
        return (loaded, report)
    }

    /// `noMatch` is a search that worked but found nothing acceptable (remembered for a day);
    /// `failed` is a search that errored on every try (not remembered).
    private enum SearchOutcome: Sendable {
        case found(Song)
        case noMatch
        case failed
    }

    private struct SearchResult: Sendable {
        var outcome: SearchOutcome
        var attempts: Int
        var errors: [String]
    }

    /// Searches started at once at first, and after searches start erroring (Apple Music
    /// throttles bursts). A search that errors is retried after `searchRetryDelays`.
    private static let searchConcurrency = 6
    private static let searchConcurrencyAfterErrors = 3
    private static let searchRetryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500)]

    /// Catalog searches for unlabelled library tracks, a few at a time, keyed by the given index.
    /// Once two searches have hit errors, fewer run at once for the rest of the load.
    private func searchCatalog(for lookups: [(index: Int, wanted: QueueTrack)]) async -> (results: [Int: SearchResult], finalConcurrency: Int) {
        await withTaskGroup(of: (Int, SearchResult).self) { group in
            var results: [Int: SearchResult] = [:]
            var limit = Self.searchConcurrency
            var next = 0, running = 0, searchesWithErrors = 0
            func fill() {
                while running < limit, next < lookups.count {
                    let lookup = lookups[next]
                    next += 1
                    running += 1
                    group.addTask { (lookup.index, await findCatalogSong(matching: lookup.wanted)) }
                }
            }
            fill()
            while let (index, result) = await group.next() {
                running -= 1
                results[index] = result
                if !result.errors.isEmpty {
                    searchesWithErrors += 1
                    if searchesWithErrors >= 2 { limit = min(limit, Self.searchConcurrencyAfterErrors) }
                }
                fill()
            }
            return (results, lookups.isEmpty ? 0 : limit)
        }
    }

    private func findCatalogSong(matching wanted: QueueTrack) async -> SearchResult {
        guard !wanted.title.isEmpty, !wanted.artist.isEmpty else { return SearchResult(outcome: .noMatch, attempts: 0, errors: []) }
        var request = MusicCatalogSearchRequest(term: CatalogMatching.searchTerm(for: wanted), types: [Song.self])
        request.limit = 10
        var errors: [String] = []
        for attempt in 0...Self.searchRetryDelays.count {
            if attempt > 0 { try? await Task.sleep(for: Self.searchRetryDelays[attempt - 1]) }
            do {
                let songs = try await request.response().songs
                let candidates = songs.map {
                    QueueTrack(id: $0.id.rawValue, title: $0.title, artist: $0.artistName, album: $0.albumTitle ?? "", duration: $0.duration)
                }
                let song = CatalogMatching.bestMatch(among: candidates, for: wanted)
                    .flatMap { best in songs.first { $0.id.rawValue == best.id } }
                return SearchResult(outcome: song.map { .found($0) } ?? .noMatch, attempts: attempt + 1, errors: errors)
            } catch {
                let description = Self.describe(error)
                errors.append(description)
                #if DEBUG
                print("[match] search \(attempt + 1) for \"\(wanted.title)\" failed: \(description)")
                #endif
            }
        }
        return SearchResult(outcome: .failed, attempts: Self.searchRetryDelays.count + 1, errors: errors)
    }

    /// An error as status/code/domain, short enough to tally ("status 429 TooManyRequests …").
    private static func describe(_ error: Error) -> String {
        if let error = error as? MusicDataRequest.Error {
            return "MusicDataRequest status \(error.status) \(error.code) \(error.title)"
        }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(String(describing: error).prefix(120))"
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
                note("    unresolved: \(unmatched) (of which no-match remembered from an earlier load: \(r.recentlyUnmatched); played from the library: \(r.libraryOnly))")
                note("  catalog ids that didn't come back: \(r.skippedCount - (unmatched - r.libraryOnly))")
                note("  searches: \(r.searches) (attempts \(r.searchAttempts), retries \(r.searchRetries), resolved after retry \(r.resolvedAfterRetry), failed every try \(r.searchesFailed), concurrency at end \(r.searchConcurrency))")
                note("  search errors: \(r.searchErrors.count)")
                for (error, count) in Dictionary(grouping: r.searchErrors, by: { $0 }).mapValues(\.count).sorted(by: { $0.value > $1.value }) {
                    note("    \(count)× \(error)")
                }
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

    // MARK: Saving a party

    var playlistDestination: String? { "Saves to your Apple Music library" }

    /// Creates a library playlist with the songs in order (Apple Music API, so it works on the
    /// Apple TV too). Songs from the library search have library ids ("i.…"); the rest are catalog
    /// songs. Added 100 at a time.
    func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        struct Ref: Encodable { var id: String; var type: String }
        struct Tracks: Encodable { var data: [Ref] }
        struct Create: Encodable {
            struct Attributes: Encodable { var name: String; var description: String }
            struct Relationships: Encodable { var tracks: Tracks }
            var attributes: Attributes
            var relationships: Relationships
        }
        struct Created: Decodable { struct Item: Decodable { var id: String }; var data: [Item] }
        let refs = tracks.map { Ref(id: $0.id, type: $0.id.hasPrefix("i.") ? "library-songs" : "songs") }
        let chunks = stride(from: 0, to: refs.count, by: 100).map { Array(refs[$0..<min($0 + 100, refs.count)]) }
        guard let first = chunks.first else { return }
        let body = Create(attributes: .init(name: name, description: description), relationships: .init(tracks: Tracks(data: first)))
        let data = try await send("POST", "/v1/me/library/playlists", body: body)
        guard let id = try JSONDecoder().decode(Created.self, from: data).data.first?.id else { throw AppleMusicError.badResponse }
        for chunk in chunks.dropFirst() {
            _ = try await send("POST", "/v1/me/library/playlists/\(id)/tracks", body: Tracks(data: chunk))
        }
    }

    // MARK: Library artwork

    var libraryArtwork: (any LibraryArtworkSource)? { self }

    private func send(_ method: String, _ path: String, body: some Encodable) async throws -> Data {
        guard let url = URL(string: "https://api.music.apple.com" + path) else { throw AppleMusicError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await MusicDataRequest(urlRequest: request).response().data
    }

    /// A catalog API path in the account's storefront ("albums/123?extend=editorialVideo"), raw,
    /// with the full URL requested. Errors are `MotionArtworkLookup.RequestError`s naming the URL.
    private static func catalogData(_ path: String) async throws -> (data: Data, url: String) {
        let storefront = try await MusicDataRequest.currentCountryCode
        let address = "https://api.music.apple.com/v1/catalog/\(storefront)/\(path)"
        guard let url = URL(string: address) else {
            throw MotionArtworkLookup.RequestError(url: address, description: "not a valid URL")
        }
        do {
            return (try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data, url.absoluteString)
        } catch {
            throw MotionArtworkLookup.RequestError(url: url.absoluteString, description: describe(error))
        }
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "https://api.music.apple.com" + path) else { throw AppleMusicError.badResponse }
        do {
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            ErrorReport.log(error, context: "Apple Music API \(path)")
            throw error
        }
    }
}

// MARK: - Library artwork

/// The art the hub relays for library songs (`/api/artwork/<library id>`, `LibraryArtwork`).
/// Songs a library playlist or a search listed come with their art's URL template
/// (`artworkHint`), which the relay downloads itself. Otherwise: the library's own, from the Apple
/// Music API's library song or, on an iPad or Mac, MediaPlayer's copy of the song (same title and
/// artist, the closest length); else, for a library copy of a catalog song, the catalog song's;
/// else its library album's. Debug builds log which one each song got, and how long it took.
extension AppleMusicCatalog: LibraryArtworkSource {
    func artworkHint(libraryID: String) async -> LibraryArtworkHint? {
        await artworkHints.hint(for: libraryID)
    }

    func artwork(libraryID: String, size: Int) async throws -> Data? {
        let clock = ContinuousClock(), start = clock.now
        // With its album too, for a song without art of its own; without, if the API won't.
        var page: APIPage<LibrarySongResource>? = try? await fetch("/v1/me/library/songs/\(libraryID)?include=catalog,albums")
        if page == nil { page = try? await fetch("/v1/me/library/songs/\(libraryID)?include=catalog") }
        let lookup = clock.now - start
        let resource = page?.data.first
        // "…: API 420 ms, image 180 ms, total 610 ms" (image: its download, or MediaPlayer's).
        func found(_ data: Data, _ how: String, downloadStart: ContinuousClock.Instant) -> Data {
            Self.artworkLog(libraryID, "\(how): API \(Self.ms(lookup)), image \(Self.ms(clock.now - downloadStart)), total \(Self.ms(clock.now - start))")
            return data
        }
        var downloadStart = clock.now
        if let url = resource?.attributes?.artwork?.url(size: size), let data = await Self.download(url) {
            return found(data, "the library's (API)", downloadStart: downloadStart)
        }
        #if os(iOS)
        var title = resource?.attributes?.name ?? ""
        var artist = resource?.attributes?.artistName ?? ""
        var duration = resource?.attributes?.durationInMillis.map { TimeInterval($0) / 1000 }
        if resource == nil {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(libraryID))
            if let song = try? await request.response().items.first {
                title = song.title
                artist = song.artistName
                duration = song.duration
            }
        }
        downloadStart = clock.now
        if let data = await Self.mediaLibraryArtwork(title: title, artist: artist, duration: duration, size: size) {
            return found(data, "the library's (MediaPlayer)", downloadStart: downloadStart)
        }
        #endif
        downloadStart = clock.now
        if let url = resource?.relationships?.catalog?.data.first?.artwork?.url(width: size, height: size), let data = await Self.download(url) {
            return found(data, "its catalog song's", downloadStart: downloadStart)
        }
        downloadStart = clock.now
        if let url = resource?.relationships?.albums?.data?.first?.attributes?.artwork?.url(size: size), let data = await Self.download(url) {
            return found(data, "its library album's", downloadStart: downloadStart)
        }
        Self.artworkLog(libraryID, (resource == nil ? "none (the library song didn't load)" : "none") + ": total \(Self.ms(clock.now - start))")
        return nil
    }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)) ms"
    }

    private static func download(_ url: URL) async -> Data? {
        guard url.scheme == "https" || url.scheme == "http",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    #if os(iOS)
    /// MediaPlayer's artwork for the library song with this title and artist (the closest length
    /// if there are several). Only if the app may already read the library: never asks.
    private static func mediaLibraryArtwork(title: String, artist: String, duration: TimeInterval?, size: Int) async -> Data? {
        guard !title.isEmpty, MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: title, forProperty: MPMediaItemPropertyTitle, comparisonType: .equalTo))
            let items = (query.items ?? []).filter { artist.isEmpty || $0.artist == artist }
            let distance = { (item: MPMediaItem) in abs(item.playbackDuration - (duration ?? item.playbackDuration)) }
            guard let item = items.min(by: { distance($0) < distance($1) }),
                  let image = item.artwork?.image(at: CGSize(width: size, height: size)) else { return nil }
            return image.jpegData(compressionQuality: 0.9)
        }.value
    }
    #endif

    private static func artworkLog(_ libraryID: String, _ found: String) {
        #if DEBUG
        print("[artwork] library song \(libraryID): \(found)")
        #endif
    }
}

// MARK: - Apple Music API shapes

private struct APIPage<Resource: Decodable>: Decodable {
    struct Meta: Decodable { var total: Int? }
    var data: [Resource]
    var next: String?
    var meta: Meta?
}

/// Search answers are kept across keystrokes (`KeptResults`).
extension APIPage: Sendable where Resource: Sendable {}

private struct APIArtwork: Decodable {
    var url: String
    /// Hex without "#", when the API sends them.
    var bgColor: String?
    var textColor1: String?
    var textColor2: String?

    /// As MusicKit fills it (`LibraryArtworkHint.url`: `{c}` and `{f}` too).
    func url(size: Int) -> URL? {
        LibraryArtworkHint.url(url, size: size)
    }

    var colors: ArtworkColors? {
        guard let bgColor else { return nil }
        return ArtworkColors(background: "#" + bgColor, primary: "#" + (textColor1 ?? "FFFFFF"), secondary: "#" + (textColor2 ?? "CCCCCC"))
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
        var libraryAlbums: APIPage<LibraryAlbumResource>?
        enum CodingKeys: String, CodingKey {
            case librarySongs = "library-songs"
            case libraryAlbums = "library-albums"
        }
    }
    var results: Results
}

private struct LibraryAlbumResource: Decodable {
    struct Attributes: Decodable {
        var name: String?
        var artistName: String?
    }
    /// The library album id ("l.…").
    var id: String
    var attributes: Attributes?
}

/// Answers for a host's search as they type (`searchLibrarySongs`: library searches, library
/// albums' songs), by key: each fetched once however many keystrokes ask at once, and kept
/// `lifetime`, so the next keystrokes asking the same add no request. A failure isn't kept.
private actor KeptResults<Value: Sendable> {
    static var maxKept: Int { 50 }

    let lifetime: TimeInterval
    private var kept: [String: (value: Value, at: Date)] = [:]
    private var loading: [String: Task<Value, Error>] = [:]

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func value(for key: String, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let entry = kept[key], Date().timeIntervalSince(entry.at) < lifetime { return entry.value }
        let task = loading[key] ?? Task { try await load() }
        loading[key] = task
        defer { loading[key] = nil }
        let value = try await task.value
        if kept.count >= Self.maxKept { kept = kept.filter { Date().timeIntervalSince($0.value.at) < lifetime } }
        if kept.count >= Self.maxKept { kept = [:] }
        kept[key] = (value, Date())
        return value
    }
}

private struct LibrarySongResource: Decodable {
    struct Attributes: Decodable {
        struct PlayParams: Decodable { var catalogId: String? }
        var playParams: PlayParams?
        var name: String?
        var artistName: String?
        var albumName: String?
        var durationInMillis: Int?
        /// The library's own artwork (absent when it has none).
        var artwork: APIArtwork?
        var contentRating: String?
    }
    struct Relationships: Decodable {
        struct Catalog: Decodable { var data: [Song] }
        /// The library album, when asked for (`include=albums`). Optional throughout, so a
        /// relationship that comes without its data never fails the song.
        struct Albums: Decodable {
            struct Album: Decodable {
                struct Attributes: Decodable { var artwork: APIArtwork? }
                /// The library album id ("l.…").
                var id: String?
                var attributes: Attributes?
            }
            var data: [Album]?
        }
        var catalog: Catalog?
        var albums: Albums?
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

    /// The id, if it's a library id a relay path and a Sonos URI can carry.
    var libraryID: String? { id.flatMap { LibraryArtwork.isLibraryID($0) ? $0 : nil } }

    /// Its library album's id, when the request included it (or set it: an album's tracks).
    var libraryAlbumID: String? { relationships?.albums?.data?.first?.id }

    /// It came with neither its catalog song nor a catalog id: an iTunes Match or uploaded copy,
    /// not one added from Apple Music.
    var isUnlabelled: Bool {
        relationships?.catalog?.data.first == nil && attributes?.playParams?.catalogId == nil
    }

    /// As a song only in the library, which plays from it.
    var libraryOnlyTrack: QueueTrack? {
        guard let libraryID, let name = attributes?.name, !name.isEmpty else { return nil }
        return .libraryOnly(
            libraryID: libraryID, title: name, artist: attributes?.artistName ?? "", album: attributes?.albumName ?? "",
            duration: attributes?.durationInMillis.map { TimeInterval($0) / 1000 }, colors: attributes?.artwork?.colors,
            isExplicit: attributes?.contentRating == "explicit"
        )
    }
}

// MARK: - Conversions

private extension MusicKit.Track {
    var song: Song? {
        if case .song(let song) = self { song } else { nil }
    }
}

extension QueueTrack {
    /// Every catalog song becomes a `QueueTrack` here (playlists, search, library tracks matched
    /// to the catalog, the tvOS refetch). `albumID` comes from data the song already has: its
    /// `albums` relationship if a request loaded it (none of ours ask for it), else its `url`
    /// attribute, which Apple Music fills for catalog songs with the album's link
    /// (".../album/<slug>/<albumId>?i=<songId>"). No extra request.
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
            isExplicit: song.contentRating == .explicit,
            albumID: song.albums?.first.map(\.id.rawValue).flatMap { MotionArtwork.isCatalogID($0) ? $0 : nil }
                ?? MotionArtwork.albumID(inSongURL: song.url)
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
