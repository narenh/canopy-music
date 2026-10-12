#if DEBUG
import CanopyCore
import MediaPlayer
@preconcurrency import MusicKit
import SwiftUI

/// `-playTest`: plays one Apple Music song with nothing of Canopy Music's involved, first with
/// MusicKit's ApplicationMusicPlayer, then with MediaPlayer's applicationQueuePlayer, logging each
/// step on screen and to Library/Caches/playtest.log. For telling an Apple bug from ours.
struct TVPlayTestView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 22).monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(60)
        }
        .task { await run() }
    }

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)"
        print("[playtest] \(line)")
        lines.append(stamped)
        let url = URL.cachesDirectory.appending(path: "playtest.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((stamped + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((stamped + "\n").utf8).write(to: url)
        }
    }

    private func run() async {
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "playtest.log"))
        log("auth before: \(MusicAuthorization.currentStatus)")
        let status = await MusicAuthorization.request()
        log("auth: \(status)")
        do {
            let subscription = try await MusicSubscription.current
            log("subscription: canPlay=\(subscription.canPlayCatalogContent) storefront=\(String(describing: subscription))")
        } catch {
            log("subscription error: \(error)")
        }
        let song: Song
        do {
            var request = MusicCatalogSearchRequest(term: "Midnight City M83", types: [Song.self])
            request.limit = 1
            guard let first = try await request.response().songs.first else { log("no song found"); return }
            song = first
            log("song: \(song.title) – \(song.artistName) id=\(song.id)")
        } catch {
            log("search error: \(error)")
            return
        }

        // 1. MusicKit's ApplicationMusicPlayer.
        log("— ApplicationMusicPlayer —")
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        do {
            log("prepareToPlay…")
            try await player.prepareToPlay()
            log("play…")
            try await player.play()
            log("play returned")
        } catch {
            log("ApplicationMusicPlayer error: \(error)")
        }
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            log("status=\(player.state.playbackStatus) time=\(Int(player.playbackTime))")
        }
        player.stop()

        // 2. MediaPlayer's applicationQueuePlayer, by store ID.
        log("— applicationQueuePlayer —")
        let legacy = MPMusicPlayerController.applicationQueuePlayer
        legacy.setQueue(with: [song.id.rawValue])
        do {
            log("prepareToPlay…")
            try await legacy.prepareToPlay()
            legacy.play()
            log("play called")
        } catch {
            log("applicationQueuePlayer error: \(error)")
        }
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            log("state=\(legacy.playbackState.rawValue) time=\(Int(legacy.currentPlaybackTime))")
        }
        legacy.stop()

        // 3. A library playlist's first song, loaded the way the app loads it, on the plain player.
        log("— library playlist song, plain player —")
        let cache = SongCache()
        let catalog = AppleMusicCatalog(cache: cache)
        do {
            guard let playlist = try await catalog.libraryPlaylists().first else { log("no library playlists"); return }
            let tracks = try await catalog.tracks(in: playlist)
            log("playlist \(playlist.name): \(tracks.count) tracks")
            guard let first = tracks.first else { return }
            let librarySong = try await cache.song(for: first.id)
            log("song: \(librarySong.title) id=\(librarySong.id) playParams=\(String(describing: librarySong.playParameters))")
            player.queue = ApplicationMusicPlayer.Queue(for: [librarySong])
            try await player.play()
            log("play returned")
        } catch {
            log("library song error: \(error)")
        }
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(2))
            log("status=\(player.state.playbackStatus) time=\(Int(player.playbackTime))")
        }
        player.stop()

        // 4. The search song through the app's own engine, staging a second song like the app does.
        log("— app engine, catalog song —")
        let engine = AppleMusicEngine(cache: cache)
        await cache.store([song])
        do {
            try await engine.play(QueueTrack(song))
            log("engine play returned")
            var next = MusicCatalogSearchRequest(term: "Dreams Fleetwood Mac", types: [Song.self])
            next.limit = 1
            if let second = try await next.response().songs.first {
                await cache.store([second])
                try await engine.stage(QueueTrack(second))
                log("staged \(second.title)")
            }
        } catch {
            log("engine error: \(error)")
        }
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            log("engine playing=\(engine.isPlaying) time=\(Int(engine.currentTime))")
        }
        engine.pause()
        log("done")
    }
}
#endif
