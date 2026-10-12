import CanopyMusicCore
import Foundation

/// Search and playlists through the Spotify Web API. Track ids are Spotify URIs.
struct SpotifyCatalog: MusicCatalog {
    let api: SpotifyAPI
    /// Which songs the latest loads left out (local files and anything else that isn't a track).
    var reports = PlaylistLoadReports()

    /// Development Mode caps search at 10 per request, so fetch two pages.
    func searchSongs(_ term: String) async throws -> [QueueTrack] {
        struct Reply: Decodable { var tracks: SpotifyPage<SpotifyTrackObject>? }
        var tracks: [QueueTrack] = []
        for offset in [0, 10] {
            let reply = try await api.get("/search", query: ["q": term, "type": "track", "limit": "10", "offset": "\(offset)"], as: Reply.self)
            let page = reply?.tracks?.items ?? []
            tracks += page.compactMap(QueueTrack.init(spotify:))
            if page.count < 10 { break }
        }
        return tracks
    }

    func libraryPlaylists() async throws -> [PlaylistSummary] {
        var summaries: [PlaylistSummary] = []
        var page = try await api.get("/me/playlists", query: ["limit": "50"], as: SpotifyPage<PlaylistObject?>.self)
        while let current = page {
            summaries += current.items.compactMap { $0?.summary(subtitle: "Your library") }
            guard let next = current.next else { break }
            page = try await api.getNext(next, as: SpotifyPage<PlaylistObject?>.self)
        }
        return summaries
    }

    /// Note: Development Mode only lets apps read the songs of playlists you own or collaborate on.
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] {
        struct Reply: Decodable { var playlists: SpotifyPage<PlaylistObject?>? }
        let reply = try await api.get("/search", query: ["q": term, "type": "playlist", "limit": "10"], as: Reply.self)
        return (reply?.playlists?.items ?? []).compactMap { $0?.summary(subtitle: $0?.owner?.display_name) }
    }

    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        var tracks: [QueueTrack] = []
        var report = PlaylistLoadReport(playlistID: playlist.id)
        var page = try await api.get("/playlists/\(playlist.id)/items", query: ["limit": "50"], as: SpotifyPage<PlaylistEntry>.self)
        while let current = page {
            for object in current.items.compactMap({ $0.item ?? $0.track }) {
                if let track = QueueTrack(spotify: object) {
                    tracks.append(track)
                } else {
                    report.skipped.append(QueueTrack(id: object.uri, title: object.name, artist: object.artists.map(\.name).joined(separator: ", "),
                                                     album: object.album?.name ?? ""))
                }
            }
            guard let next = current.next else { break }
            page = try await api.getNext(next, as: SpotifyPage<PlaylistEntry>.self)
        }
        report.loaded = tracks.count
        report.total = tracks.count + report.skipped.count
        await reports.record(report)
        return tracks
    }

    func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
        await reports.report(for: playlist.id)
    }

    var playlistDestination: String? { "Saves to your Spotify account" }

    /// A private playlist in the signed-in account, songs added 100 at a time. Uses the 2026 API
    /// (`/me/playlists`, `/items`) and falls back to the older paths where Spotify refuses them.
    func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        guard await api.auth.canSavePlaylists else { throw SpotifyError.needsPlaylistAccess }
        struct Create: Encodable { var name: String; var description: String; var `public` = false }
        struct Created: Decodable { var id: String }
        struct Items: Encodable { var uris: [String] }
        struct Me: Decodable { var id: String }
        let create = Create(name: name, description: description)
        let data: Data?
        do {
            data = try await api.send("POST", "/me/playlists", body: create)
        } catch SpotifyError.badResponse(let status, _) where status == 404 || status == 405 {
            guard let me = try await api.get("/me", as: Me.self) else { throw SpotifyError.badResponse(0, "") }
            data = try await api.send("POST", "/users/\(me.id)/playlists", body: create)
        }
        guard let data, let playlist = try? JSONDecoder().decode(Created.self, from: data) else { throw SpotifyError.badResponse(0, "") }
        let uris = tracks.map(\.id)
        for start in stride(from: 0, to: uris.count, by: 100) {
            let chunk = Items(uris: Array(uris[start..<min(start + 100, uris.count)]))
            do {
                try await api.send("POST", "/playlists/\(playlist.id)/items", body: chunk)
            } catch SpotifyError.badResponse(let status, _) where status == 404 || status == 405 {
                try await api.send("POST", "/playlists/\(playlist.id)/tracks", body: chunk)
            }
        }
    }

    private struct PlaylistObject: Decodable, Sendable {
        struct Owner: Decodable, Sendable { var display_name: String? }
        var id: String
        var name: String
        var images: [SpotifyImage]?
        var owner: Owner?

        func summary(subtitle: String?) -> PlaylistSummary {
            let art = images?.sorted { ($0.width ?? 0) < ($1.width ?? 0) }.first { ($0.width ?? 300) >= 200 } ?? images?.first
            return PlaylistSummary(id: id, name: name, subtitle: subtitle, artworkURL: art?.url, kind: .library)
        }
    }

    /// Playlist entries moved from `track` to `item` in the 2026 API; accept either.
    private struct PlaylistEntry: Decodable, Sendable {
        var item: SpotifyTrackObject?
        var track: SpotifyTrackObject?
    }
}

extension QueueTrack {
    init?(spotify object: SpotifyTrackObject) {
        guard object.is_local != true, object.type == nil || object.type == "track" else { return nil }
        let images = (object.album?.images ?? []).sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        self.init(
            id: object.uri,
            title: object.name,
            artist: object.artists.map(\.name).joined(separator: ", "),
            album: object.album?.name ?? "",
            duration: Double(object.duration_ms) / 1000,
            artworkURL: images.first?.url,
            thumbnailURL: images.last { ($0.width ?? 0) >= 60 }?.url ?? images.last?.url,
            colors: nil,
            isExplicit: object.explicit ?? false
        )
    }
}
