#if DEBUG
import CanopyMusicCore
import Combine
import MediaPlayer
@preconcurrency import MusicKit
import ObjectiveC
import SwiftUI

/// `-libraryPlayTest <library id>`: plays one song only in the library ("i.…") the way a TV zone
/// does: fetched with `MusicLibraryRequest` (`SongCache`), then played by `AppleMusicEngine` on a
/// cold player, then the player read every second for 15 s, each step stamped, on screen, to the
/// console ("[library test]"), and to Library/Caches/library-playtest.log. A watchdog on its own
/// thread prints "[library test] MAIN THREAD BLOCKED for N s" while the main thread doesn't
/// answer, so a freeze shows in the console with the screen stuck. The player is read on another
/// thread (`PlayerReading.takeOffMain`), as the engine reads library songs on tvOS; add
/// `-libraryPlayTestMainReads` to read it on the main thread instead, as `poll` reads catalog songs.
///
/// `-libraryPlayTestVia <mode>` plays it another way instead (`playVia`). On a real TV the
/// player plays such a song but its current entry never arrives: the player service's
/// now-playing reply names the user's library by DSID, and MediaPlayer, finding only an
/// in-memory library with no DSID here, drops the reply. Each mode reads the player off the main
/// thread every second for 15 s. Run with `OS_ACTIVITY_DT_MODE=YES` to see Apple's own lines
/// ("[LIB] _mediaLibraryWithUniqueIdentifier…") beside these.
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

    private func log(_ line: String, at date: Date = Date()) {
        let stamped = "\(date.formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)"
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
        LibraryTestLog.sink = { line, date in log(line, at: date) }
        MainThreadWatchdog.start()
        log("library id \(libraryID); auth before: \(MusicAuthorization.currentStatus)")
        let status = await MusicAuthorization.request()
        log("auth: \(status)")
        let clock = ContinuousClock()
        let args = ProcessInfo.processInfo.arguments
        let via = args.firstIndex(of: "-libraryPlayTestVia").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

        // "nofetch": before any `MusicLibraryRequest`, which is what makes the in-memory library.
        if via == "nofetch" {
            await playUnfetched()
            log("done")
            return
        }

        // 1. The song, as the engine gets it: `SongCache.song(for:)`, a `MusicLibraryRequest`.
        let cache = SongCache()
        var track = QueueTrack.libraryOnly(libraryID: libraryID, title: libraryID, artist: "")
        log("request: MusicLibraryRequest<Song> id=\(libraryID)")
        var start = clock.now
        let fetched: Song
        do {
            fetched = try await cache.song(for: track)
            log("fetched in \((clock.now - start).inMilliseconds):\(fetched.title) – \(fetched.artistName), \(fetched.duration.map { "\(Int($0)) s" } ?? "no duration"), playParams=\(String(describing: fetched.playParameters))")
            track = .libraryOnly(libraryID: libraryID, title: fetched.title, artist: fetched.artistName, duration: fetched.duration)
        } catch {
            log("fetch threw after \((clock.now - start).inMilliseconds): \(error)")
            // A mode still runs, on the song made from its id (the simulator has no library).
            if let via, let song = unfetchedSong() {
                await playVia(via, song: song)
            }
            log("done")
            return
        }

        if let via {
            await playVia(via, song: fetched)
            log("done")
            return
        }

        // 2. Played by the engine, as a zone plays it ("[engine]" lines: queue set, play()
        // returned or threw, and on tvOS the off-main check that it started).
        let engine = AppleMusicEngine(cache: cache)
        engine.onEvent = { event in log("engine event: \(event)") }
        log("engine.play…")
        start = clock.now
        do {
            try await engine.play(track)
            log("engine.play returned after \((clock.now - start).inMilliseconds)")
        } catch {
            log("engine.play threw after \((clock.now - start).inMilliseconds): \(error)")
        }

        // `-libraryPlayTestAdvance`: the same song staged after itself, as a zone stages its next
        // song, and at 3 s a seek to 8 s before the end, so the engine's move on to the staged
        // song (by the clock: "[engine] moved on to … (by the clock)", then "engine event:
        // advancedToStaged") comes within the 15 s.
        let advance = args.contains("-libraryPlayTestAdvance")
        if advance {
            do {
                try await engine.stage(track)
                log("staged the song again after itself")
            } catch {
                log("stage threw: \(error)")
            }
        }

        // 3. The player every second.
        let mainReads = ProcessInfo.processInfo.arguments.contains("-libraryPlayTestMainReads")
        log("reading the player every second for 15 s, \(mainReads ? "on the main thread" : "off the main thread")")
        for second in 1...15 {
            if advance, second == 4, let duration = track.duration {
                log("seeking to \(Int(duration - 8)) s")
                engine.seek(to: duration - 8)
            }
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

    /// The modes of `-libraryPlayTestVia`:
    /// - "mediaplayer": `MPMusicPlayerController.applicationQueuePlayer` from the song's play
    ///   parameters (tvOS has no MediaPlayer library queries, but takes play parameters). Its
    ///   `nowPlayingItem` and `indexOfNowPlayingItem` each second.
    /// - "system": `SystemMusicPlayer`, which plays through the TV's Music app: does its
    ///   current entry arrive, the Music app having the account?
    /// - "entries": `ApplicationMusicPlayer` from an entry made here; its `queue.entries` (kept
    ///   in this process, or from the service?) after play, and after inserting the song again
    ///   as the engine stages, and whether either holds our entry.
    /// - "prefetch": a broad `MusicLibraryRequest<Song>` and one `<Album>` (limit 1) before
    ///   playing: does the in-memory library get a DSID ("[LIB]" considerations)?
    /// - "observe": the queue's and the state's `objectWillChange`, Observation on
    ///   `currentEntry` and `playbackStatus` (tvOS 26.4), and MediaPlayer's notifications (the
    ///   public ones and, by name, its private item-ended and queue-ended ones), each logged as
    ///   it comes, with a read of the player just after.
    /// - "privatelib": private API, to test the cause and not to ship: gives each in-memory
    ///   `MPMediaLibrary` with no user identity `ICUserIdentity.activeAccount` before playing.
    ///   MediaPlayer, on a device with several accounts (tvOS), skips a library with none when
    ///   the reply has a DSID, even one with the same database ID. With one, a database ID
    ///   match should be taken ("found in-memory library [databaseID match…").
    /// - "nofetch" (`playUnfetched`): no `MusicLibraryRequest` at all.
    private func playVia(_ via: String, song: Song) async {
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
                let index = player.indexOfNowPlayingItem
                log("mediaplayer \(second) s: state=\(player.playbackState.rawValue) time=\(String(format: "%.1f", player.currentPlaybackTime)) item=\(player.nowPlayingItem?.title ?? "nil") index=\(index == NSNotFound ? "NSNotFound" : "\(index)")")
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
            await watch("system", .system)
            player.pause()
        case "entries":
            let ours = MusicKit.MusicPlayer.Queue.Entry(song)
            log("entries: our entry id=\(ours.id) item=\(ours.item?.id.rawValue ?? "nil")")
            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue([ours])
            await logEntries("set", ours: ours.id)
            do {
                try await player.play()
                log("entries: play() returned after \((clock.now - start).inMilliseconds)")
            } catch {
                log("entries: play() threw after \((clock.now - start).inMilliseconds): \(error)")
            }
            await logEntries("after play", ours: ours.id)
            // As the engine stages: the same song again, after the current entry.
            do {
                try await player.queue.insert(song, position: .afterCurrentEntry)
                log("entries: inserted the song again after the current entry")
            } catch {
                log("entries: insert threw: \(error)")
            }
            await logEntries("after insert", ours: ours.id)
            await watch("entries", .application, ours: ours.id)
            await logEntries("at the end", ours: ours.id)
            player.pause()
        case "prefetch":
            do {
                var songs = MusicLibraryRequest<Song>()
                songs.limit = 1
                let response = try await songs.response()
                log("prefetch: MusicLibraryRequest<Song> limit 1 after \((clock.now - start).inMilliseconds): \(response.items.map { "\($0.title) \($0.id.rawValue) playParams=\(String(describing: $0.playParameters))" })")
            } catch {
                log("prefetch: MusicLibraryRequest<Song> threw: \(error)")
            }
            do {
                var albums = MusicLibraryRequest<Album>()
                albums.limit = 1
                let response = try await albums.response()
                log("prefetch: MusicLibraryRequest<Album> limit 1 after \((clock.now - start).inMilliseconds): \(response.items.map { "\($0.title) \($0.id.rawValue) playParams=\(String(describing: $0.playParameters))" })")
            } catch {
                log("prefetch: MusicLibraryRequest<Album> threw: \(error)")
            }
            await playApplication(song, label: "prefetch")
        case "observe":
            await observe(song)
        case "privatelib":
            giveLibrariesTheActiveAccount()
            await playApplication(song, label: "privatelib")
            log("privatelib: libraries at the end: \(LibraryTestPrivate.libraries())")
        default:
            log("unknown -libraryPlayTestVia \(via)")
        }
    }

    /// `ApplicationMusicPlayer` from the song, as the engine plays it, then `watch`.
    private func playApplication(_ song: Song, label: String) async {
        let player = ApplicationMusicPlayer.shared
        let start = ContinuousClock.now
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        do {
            try await player.play()
            log("\(label): play() returned after \((ContinuousClock.now - start).inMilliseconds)")
        } catch {
            log("\(label): play() threw after \((ContinuousClock.now - start).inMilliseconds): \(error)")
        }
        await watch(label, .application)
        player.pause()
    }

    /// "nofetch": the song made from an Apple Music API library-song resource holding only its
    /// id and play parameters, so nothing in this process has asked the library for anything
    /// when it plays. "[LIB] … considerations=()" then means the request made the library.
    private func playUnfetched() async {
        guard let song = unfetchedSong() else { return }
        log("nofetch: libraries before playing: \(LibraryTestPrivate.libraries())")
        await playApplication(song, label: "nofetch")
        log("nofetch: libraries at the end: \(LibraryTestPrivate.libraries())")
    }

    private func unfetchedSong() -> Song? {
        let json = #"{"id":"\#(libraryID)","type":"library-songs","attributes":{"name":"\#(libraryID)","playParams":{"id":"\#(libraryID)","kind":"song","isLibrary":true}}}"#
        do {
            let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
            log("decoded \(song.id.rawValue) without a request, playParams=\(String(describing: song.playParameters))")
            return song
        } catch {
            log("couldn't decode a song from \(json): \(error)")
            return nil
        }
    }

    /// The player read off the main thread every second for 15 s.
    private func watch(_ label: String, _ which: LibraryTestReads.Which, ours: String? = nil) async {
        for second in 1...15 {
            try? await Task.sleep(for: .seconds(1))
            let reading = await LibraryTestReads.offMain(within: 2) { LibraryTestReads.describe(which, ours: ours) }
            log("\(label) \(second) s: \(reading ?? "no answer from the player in 2 s")")
        }
    }

    private func logEntries(_ when: String, ours: String) async {
        let entries = await LibraryTestReads.offMain(within: 2) { LibraryTestReads.entries(ours: ours) }
        log("entries \(when): \(entries ?? "no answer in 2 s")")
    }

    private func observe(_ song: Song) async {
        let player = ApplicationMusicPlayer.shared
        var subscriptions = Set<AnyCancellable>()
        var observers: [any NSObjectProtocol] = []
        let names: [Notification.Name] = [
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
            // Not in the headers: names from MediaPlayer's binary.
            Notification.Name("MPMusicPlayerControllerQueueDidChangeNotification"),
            Notification.Name("MPMusicPlayerControllerItemPlaybackDidEndNotification"),
            Notification.Name("_MPMusicPlayerControllerQueueDidChangeNotification"),
            Notification.Name("_MPMusicPlayerControllerQueueDidEndNotification"),
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable note in
                LibraryTestLog.note("observe: \(note.name.rawValue) from \(note.object.map { "\(type(of: $0))" } ?? "nil") userInfo=\(note.userInfo.map { "\($0)" } ?? "nil")")
                LibraryTestReads.readSoon(after: "\(note.name.rawValue)")
            })
        }
        player.state.objectWillChange.sink { @Sendable _ in
            LibraryTestLog.note("observe: state objectWillChange")
            LibraryTestReads.readSoon(after: "state objectWillChange")
        }.store(in: &subscriptions)
        let subscribe = { (tag: String) in
            let queue = player.queue
            log("observe: queue \(tag) is \(ObjectIdentifier(queue))")
            queue.objectWillChange.sink { @Sendable _ in
                LibraryTestLog.note("observe: queue (\(tag)) objectWillChange")
                LibraryTestReads.readSoon(after: "queue (\(tag)) objectWillChange")
            }.store(in: &subscriptions)
        }
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        subscribe("as set")
        if #available(tvOS 26.4, *) { LibraryTestReads.track(1) }
        let start = ContinuousClock.now
        do {
            try await player.play()
            log("observe: play() returned after \((ContinuousClock.now - start).inMilliseconds)")
        } catch {
            log("observe: play() threw after \((ContinuousClock.now - start).inMilliseconds): \(error)")
        }
        // The queue object can be replaced on play.
        subscribe("after play")
        if #available(tvOS 26.4, *) { LibraryTestReads.track(100) }
        await watch("observe", .application)
        player.pause()
        try? await Task.sleep(for: .seconds(1))
        subscriptions.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func giveLibrariesTheActiveAccount() {
        log("privatelib: libraries before: \(LibraryTestPrivate.libraries())")
        log("privatelib: \(LibraryTestPrivate.giveLibrariesTheActiveAccount())")
        log("privatelib: libraries after: \(LibraryTestPrivate.libraries())")
    }
}

/// Lines from other threads (notifications, Combine, Observation), stamped as they come.
enum LibraryTestLog {
    @MainActor static var sink: ((String, Date) -> Void)?

    nonisolated static func note(_ line: String) {
        let date = Date()
        Task { @MainActor in sink?(line, date) }
    }
}

/// Reads of the players on their own thread, one at a time, each with a deadline.
enum LibraryTestReads {
    enum Which: Sendable { case application, system }

    private static let queue = DispatchQueue(label: "com.canopysf.CanopyMusic.library-test-reads", qos: .userInitiated)

    nonisolated static func offMain<T: Sendable>(within seconds: TimeInterval, _ read: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let answer = Answer<T>(continuation)
            queue.async { answer.give(read()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { answer.give(nil) }
        }
    }

    /// Status, time, current entry, and (`ApplicationMusicPlayer`) the queue's entry count.
    nonisolated static func describe(_ which: Which, ours: String? = nil) -> String {
        let status: MusicKit.MusicPlayer.PlaybackStatus
        let time: TimeInterval
        let entry: MusicKit.MusicPlayer.Queue.Entry?
        var count = ""
        switch which {
        case .application:
            let player = ApplicationMusicPlayer.shared
            status = player.state.playbackStatus
            time = player.playbackTime
            entry = player.queue.currentEntry
            count = " entries=\(player.queue.entries.count)"
        case .system:
            let player = SystemMusicPlayer.shared
            status = player.state.playbackStatus
            time = player.playbackTime
            entry = player.queue.currentEntry
        }
        let current = entry.map(describeEntry) ?? "nil"
        let isOurs = ours.map { id in entry.map { $0.id == id ? " (ours)" : " (not ours)" } ?? "" } ?? ""
        return "status=\(status) time=\(String(format: "%.1f", time)) currentEntry=\(current)\(isOurs)\(count)"
    }

    nonisolated static func describeEntry(_ entry: MusicKit.MusicPlayer.Queue.Entry) -> String {
        "“\(entry.title)” id=\(entry.id) item=\(entry.item?.id.rawValue ?? "nil")\(entry.isTransient ? " transient" : "")"
    }

    nonisolated static func entries(ours: String) -> String {
        let queue = ApplicationMusicPlayer.shared.queue
        let entries = Array(queue.entries)
        let list = entries.map { "\(describeEntry($0))\($0.id == ours ? " (ours)" : "")" }
        return "\(entries.count) entries \(list); current=\(queue.currentEntry.map(describeEntry) ?? "nil")"
    }

    /// A read 100 ms after something said the player will change.
    nonisolated static func readSoon(after cause: String) {
        queue.asyncAfter(deadline: .now() + 0.1) {
            LibraryTestLog.note("observe: after \(cause): \(describe(.application)); MPMusicPlayerController \(LibraryTestPrivate.mediaPlayerNowPlaying())")
        }
    }

    /// Observation (tvOS 26.4): `currentEntry` and `playbackStatus`, tracked on the read queue
    /// and tracked again after each change.
    @available(tvOS 26.4, *)
    nonisolated static func track(_ n: Int) {
        queue.async {
            withObservationTracking {
                let player = ApplicationMusicPlayer.shared
                _ = player.queue.currentEntry
                _ = player.state.playbackStatus
            } onChange: {
                LibraryTestLog.note("observe: Observation says currentEntry or playbackStatus will change (#\(n))")
                queue.asyncAfter(deadline: .now() + 0.1) {
                    LibraryTestLog.note("observe: after Observation #\(n): \(describe(.application))")
                    track(n + 1)
                }
            }
        }
    }

    /// Whichever of a read and its deadline comes first.
    private final class Answer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<T?, Never>?

        init(_ waiter: CheckedContinuation<T?, Never>) {
            self.waiter = waiter
        }

        func give(_ value: T?) {
            let waiter = lock.withLock {
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(returning: value)
        }
    }
}

struct LibraryTestError: Error, ExpressibleByStringLiteral {
    let message: String
    init(stringLiteral message: String) { self.message = message }
    init(_ message: String) { self.message = message }
}

/// Private MediaPlayer and iTunesCloud API, for "privatelib" and the logs: never in a release.
enum LibraryTestPrivate {
    /// `+[MPMediaLibrary mediaLibraries]` (a set), or why not.
    private nonisolated static func mediaLibraries() -> Result<[AnyObject], LibraryTestError> {
        guard let libraryClass = NSClassFromString("MPMediaLibrary") as AnyObject? else { return .failure("no MPMediaLibrary") }
        guard libraryClass.responds(to: NSSelectorFromString("mediaLibraries")) else { return .failure("no +[MPMediaLibrary mediaLibraries]") }
        let result = libraryClass.perform(NSSelectorFromString("mediaLibraries"))?.takeUnretainedValue()
        if let set = result as? NSSet { return .success(set.allObjects as [AnyObject]) }
        if let array = result as? [AnyObject] { return .success(array) }
        return .failure(LibraryTestError("+[MPMediaLibrary mediaLibraries] gave \(String(describing: result))"))
    }

    /// Each prints as "<MPMediaLibrary [memory] uid=… dsid=…>".
    nonisolated static func libraries() -> String {
        switch mediaLibraries() {
        case .success(let libraries): libraries.isEmpty ? "none" : libraries.map { "\($0)" }.joined(separator: ", ")
        case .failure(let error): error.message
        }
    }

    /// Sets `_userIdentity` on each in-memory library that has none to `ICUserIdentity.activeAccount`.
    nonisolated static func giveLibrariesTheActiveAccount() -> String {
        guard let libraryClass = NSClassFromString("MPMediaLibrary"),
              let identityClass = NSClassFromString("ICUserIdentity") as AnyObject?,
              let ivar = class_getInstanceVariable(libraryClass, "_userIdentity") else {
            return "no MPMediaLibrary._userIdentity or ICUserIdentity"
        }
        guard identityClass.responds(to: NSSelectorFromString("activeAccount")),
              let active = identityClass.perform(NSSelectorFromString("activeAccount"))?.takeUnretainedValue() else {
            return "no +[ICUserIdentity activeAccount]"
        }
        let libraries: [AnyObject]
        switch mediaLibraries() {
        case .success(let found): libraries = found
        case .failure(let error): return error.message
        }
        var changed = 0
        for library in libraries where object_getIvar(library, ivar) == nil {
            object_setIvarWithStrongDefault(library, ivar, active)
            changed += 1
        }
        return "gave \(changed) of \(libraries.count) libraries the identity \(active)"
    }

    /// `MPMusicPlayerController.applicationMusicPlayer` (which `ApplicationMusicPlayer` wraps):
    /// its now-playing item and index, which come from the same now-playing reply.
    nonisolated static func mediaPlayerNowPlaying() -> String {
        let player = MPMusicPlayerController.applicationMusicPlayer
        let index = player.indexOfNowPlayingItem
        return "item=\(player.nowPlayingItem?.title ?? "nil") index=\(index == NSNotFound ? "NSNotFound" : "\(index)") state=\(player.playbackState.rawValue)"
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
