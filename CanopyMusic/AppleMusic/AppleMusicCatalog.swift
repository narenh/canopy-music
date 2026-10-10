import CanopyCore
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

    func searchSongs(_ term: String) async throws -> [CanopyCore.Track] {
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let songs = Array(try await request.response().songs)
        await cache.store(songs)
        return songs.map(CanopyCore.Track.init)
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
        var resources: [LibraryPlaylistResource] = []
        var path: String? = "/v1/me/library/playlists?limit=100"
        while let next = path {
            let page: APIPage<LibraryPlaylistResource> = try await fetch(next)
            resources += page.data
            path = page.next
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

    func tracks(in playlist: PlaylistSummary) async throws -> [CanopyCore.Track] {
        let songs = switch playlist.kind {
        case .catalog: try await catalogPlaylistSongs(id: playlist.id)
        case .library: try await libraryPlaylistSongs(id: playlist.id)
        }
        await cache.store(songs)
        return songs.map(CanopyCore.Track.init)
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
        enum Slot { case song(Song), pending(String) }
        var slots: [Slot] = []
        var path: String? = "/v1/me/library/playlists/\(id)/tracks?limit=100&include=catalog"
        while let next = path {
            let page: APIPage<LibrarySongResource> = try await fetch(next)
            for resource in page.data {
                if let song = resource.relationships?.catalog?.data.first {
                    slots.append(.song(song))
                } else if let catalogID = resource.attributes?.playParams?.catalogId {
                    slots.append(.pending(catalogID))
                }
                // Songs with no catalog match (uploads, removed tracks) can't be played here; skip them.
            }
            path = page.next
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

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "https://api.music.apple.com" + path) else { throw AppleMusicError.badResponse }
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        return try JSONDecoder().decode(T.self, from: response.data)
    }
}

// MARK: - Apple Music API shapes

private struct APIPage<Resource: Decodable>: Decodable {
    var data: [Resource]
    var next: String?
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

extension CanopyCore.Track {
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
