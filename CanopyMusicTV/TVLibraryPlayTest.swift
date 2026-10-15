#if DEBUG
import CanopyMusicCore
import MediaPlayer
@preconcurrency import MusicKit
import SwiftUI

/// `-libraryPlayTest <library id>`: plays one song only in the library ("i.…") the way a TV zone
/// does: fetched with `MusicLibraryRequest` (`SongCache`), then played by `AppleMusicEngine` on a
/// cold player, then the player read every second for 15 s, each step stamped, on screen, to the
/// console ("[library test]"), and to Library/Caches/library-playtest.log. A watchdog on its own
/// thread prints "[library test] MAIN THREAD BLOCKED for N s" while the main thread doesn't
/// answer, so a freeze shows in the console with the screen stuck. The player is read on another
/// thread (`PlayerReading.takeOffMain`), as the engine reads library songs on tvOS; add
/// `-libraryPlayTestMainReads` to read it on the main thread instead, as `poll` reads catalog songs.
struct TVLibraryPlayTestView: View {
    let libraryID: String
    @State private var lines: [String] = []

    static var libraryID: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-libraryPlayTest"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

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

    private static let file = URL.cachesDirectory.appending(path: "library-playtest.log")

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)"
        print("[library test] \(stamped)")
        lines.append(stamped)
        if let handle = try? FileHandle(forWritingTo: Self.file) {
            handle.seekToEndOfFile()
            handle.write(Data((stamped + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((stamped + "\n").utf8).write(to: Self.file)
        }
    }

    private func run() async {
        try? FileManager.default.removeItem(at: Self.file)
        MainThreadWatchdog.start()
        log("library id \(libraryID); auth before: \(MusicAuthorization.currentStatus)")
        let status = await MusicAuthorization.request()
        log("auth: \(status)")
        let clock = ContinuousClock()

        // 1. The song, as the engine gets it: `SongCache.song(for:)`, a `MusicLibraryRequest`.
        let cache = SongCache()
        var track = QueueTrack.libraryOnly(libraryID: libraryID, title: libraryID, artist: "")
        log("request: MusicLibraryRequest<Song> id=\(libraryID)")
        var start = clock.now
        do {
            let song = try await cache.song(for: track)
            log("fetched in \((clock.now - start).inMilliseconds):\(song.title) – \(song.artistName), \(song.duration.map { "\(Int($0)) s" } ?? "no duration"), playParams=\(String(describing: song.playParameters))")
            track = .libraryOnly(libraryID: libraryID, title: song.title, artist: song.artistName, duration: song.duration)
        } catch {
            log("fetch threw after \((clock.now - start).inMilliseconds): \(error)")
            log("done")
            return
        }

        // `-libraryPlayTestVia mediaplayer|system`: the same song through another player instead,
        // since `ApplicationMusicPlayer` took it but had no entry and stopped at once on a real TV.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-libraryPlayTestVia"), i + 1 < args.count {
            await playVia(args[i + 1], track: track, cache: cache)
            log("done")
            return
        }

        // 2. Played by the engine, as a zone plays it ("[engine]" lines: queue set, play()
        // returned or threw, and on tvOS the off-main check that it started).
        let engine = AppleMusicEngine(cache: cache)
        log("engine.play…")
        start = clock.now
        do {
            try await engine.play(track)
            log("engine.play returned after \((clock.now - start).inMilliseconds)")
        } catch {
            log("engine.play threw after \((clock.now - start).inMilliseconds): \(error)")
        }

        // 3. The player every second.
        let mainReads = ProcessInfo.processInfo.arguments.contains("-libraryPlayTestMainReads")
        log("reading the player every second for 15 s, \(mainReads ? "on the main thread" : "off the main thread")")
        for second in 1...15 {
            try? await Task.sleep(for: .seconds(1))
            let reading = mainReads ? PlayerReading.take() : await PlayerReading.takeOffMain(within: 2)
            let player = reading.map { "status=\($0.status) playbackTime=\(String(format: "%.1f", $0.time)) currentEntry=\($0.title ?? "nil") (\($0.itemID ?? "no item"))" }
                ?? "no answer from the player in 2 s"
            log("\(second) s: \(player); engine playing=\(engine.isPlaying) time=\(String(format: "%.1f", engine.currentTime))")
        }
        engine.pause()
        engine.shutDown()
        log("done")
    }

    /// "mediaplayer": `MPMusicPlayerController.applicationQueuePlayer` from the song's play
    /// parameters (tvOS has no MediaPlayer library queries, but takes play parameters). "system":
    /// `SystemMusicPlayer`, which plays through the TV's Music app. Read every second for 15 s.
    private func playVia(_ via: String, track: QueueTrack, cache: SongCache) async {
        guard let song = try? await cache.song(for: track) else { log("\(via): song gone"); return }
        let clock = ContinuousClock()
        let start = clock.now
        switch via {
        case "mediaplayer":
            guard let parameters = song.playParameters,
                  let data = try? JSONEncoder().encode(parameters),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let playParameters = MPMusicPlayerPlayParameters(dictionary: dictionary) else {
                log("mediaplayer: no play parameters"); return
            }
            log("mediaplayer: play parameters \(dictionary)")
            let player = MPMusicPlayerController.applicationQueuePlayer
            player.setQueue(with: MPMusicPlayerPlayParametersQueueDescriptor(playParametersQueue: [playParameters]))
            do {
                try await player.prepareToPlay()
                log("mediaplayer: prepared after \((clock.now - start).inMilliseconds)")
            } catch {
                log("mediaplayer: prepareToPlay threw after \((clock.now - start).inMilliseconds): \(error)")
            }
            player.play()
            for second in 1...15 {
                try? await Task.sleep(for: .seconds(1))
                log("mediaplayer \(second) s: state=\(player.playbackState.rawValue) time=\(String(format: "%.1f", player.currentPlaybackTime)) item=\(player.nowPlayingItem?.title ?? "nil")")
            }
            player.stop()
        case "system":
            let player = SystemMusicPlayer.shared
            player.queue = [song]
            do {
                try await player.play()
                log("system: play() returned after \((clock.now - start).inMilliseconds)")
            } catch {
                log("system: play() threw after \((clock.now - start).inMilliseconds): \(error)")
            }
            for second in 1...15 {
                try? await Task.sleep(for: .seconds(1))
                log("system \(second) s: status=\(player.state.playbackStatus) time=\(String(format: "%.1f", player.playbackTime)) entry=\(player.queue.currentEntry?.title ?? "nil")")
            }
            player.pause()
        default:
            log("unknown -libraryPlayTestVia \(via)")
        }
    }
}

/// Pings the main queue every second from its own thread, and prints while it doesn't answer.
enum MainThreadWatchdog {
    @MainActor private static var started = false

    @MainActor static func start() {
        guard !started else { return }
        started = true
        let thread = Thread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                let asked = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 1) == .timedOut {
                    var seconds = 1
                    print("[library test] MAIN THREAD BLOCKED for \(seconds) s")
                    while answered.wait(timeout: .now() + 1) == .timedOut {
                        seconds += 1
                        print("[library test] MAIN THREAD BLOCKED for \(seconds) s")
                    }
                    print("[library test] main thread answered again after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        thread.name = "library test watchdog"
        thread.start()
    }
}
#endif
