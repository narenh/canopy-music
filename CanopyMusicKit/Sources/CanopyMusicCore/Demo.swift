#if DEBUG
// Demo provider: debug builds only (simulator, previews, the Mac dev server).

import CoreGraphics
import Foundation
import ImageIO

/// Fake catalog for the simulator and previews, where MusicKit playback isn't available.
public struct DemoCatalog: MusicCatalog {
    public init() {}

    static let palette: [ArtworkColors] = [
        .init(background: "#3C3489", primary: "#EEEDFE", secondary: "#AFA9EC"),
        .init(background: "#712B13", primary: "#FAECE7", secondary: "#F0997B"),
        .init(background: "#085041", primary: "#E1F5EE", secondary: "#5DCAA5"),
        .init(background: "#72243E", primary: "#FBEAF0", secondary: "#ED93B1"),
        .init(background: "#0C447C", primary: "#E6F1FB", secondary: "#85B7EB"),
        .init(background: "#633806", primary: "#FAEEDA", secondary: "#EF9F27"),
        .init(background: "#27500A", primary: "#EAF3DE", secondary: "#97C459"),
    ]

    static let songs: [(String, String, String)] = [
        ("Midnight City", "M83", "Hurry Up, We're Dreaming"),
        ("Dreams", "Fleetwood Mac", "Rumours"),
        ("Ribs", "Lorde", "Pure Heroine"),
        ("Electric Feel", "MGMT", "Oracular Spectacular"),
        ("Feels Like We Only Go Backwards", "Tame Impala", "Lonerism"),
        ("Heat Waves", "Glass Animals", "Dreamland"),
        ("Kids", "MGMT", "Oracular Spectacular"),
        ("Dancing in the Dark", "Bruce Springsteen", "Born in the U.S.A."),
        ("Dancing in the Moonlight", "Toploader", "Onka's Big Moka"),
        ("Dancing On My Own", "Robyn", "Body Talk"),
        ("Get Lucky", "Daft Punk", "Random Access Memories"),
        ("Le Responsable", "Jacques Dutronc", "Jacques Dutronc"),
        ("Myth", "Beach House", "Bloom"),
        ("Instant Crush", "Daft Punk", "Random Access Memories"),
        ("Do I Wanna Know?", "Arctic Monkeys", "AM"),
        ("Pink + White", "Frank Ocean", "Blonde"),
        ("Bags", "Clairo", "Immunity"),
        ("Motion Sickness", "Phoebe Bridgers", "Stranger in the Alps"),
        ("Redbone", "Childish Gambino", "Awaken, My Love!"),
        ("Breezeblocks", "alt-J", "An Awesome Wave"),
        ("Tadow", "Masego and FKJ", "Tadow"),
        ("Sunflower", "Rex Orange County", "Apricot Princess"),
        ("Loving Is Easy", "Rex Orange County", "Pony"),
        ("Two Weeks", "Grizzly Bear", "Veckatimest"),
        ("Holocene", "Bon Iver", "Bon Iver, Bon Iver"),
        ("Night Owl", "Galimatias", "Urbanflora"),
        ("Cola", "CamelPhat and Elderbrook", "Cola"),
        ("Latch", "Disclosure", "Settle"),
        ("Innerbloom", "RÜFÜS DU SOL", "Bloom"),
        ("Coffee", "Sylvan Esso", "Sylvan Esso"),
    ]

    public static func track(_ index: Int) -> QueueTrack {
        let (title, artist, album) = songs[index % songs.count]
        return QueueTrack(
            id: "demo-\(index)", title: title, artist: artist, album: album,
            duration: 30, colors: palette[index % palette.count]
        )
    }

    public static let allTracks: [QueueTrack] = songs.indices.map(track)

    /// A long playlist, for the part of Up Next past the live window. Numbered, so the order shows.
    public static let bigTracks: [QueueTrack] = (0..<400).map { index in
        var track = track(index)
        track.title += " \(index + 1)"
        return track
    }

    public func searchSongs(_ term: String) async throws -> [QueueTrack] {
        try await Task.sleep(for: .milliseconds(250))
        return Self.allTracks.filter { Self.matches($0, term) }
    }

    /// Hosts also find the demo library: its copy of "Dreams" in place of the catalog's, and two
    /// uploads only in the library ("harbour", "paper"), with art from `DemoLibraryArtwork`.
    public func searchSongs(_ term: String, includingLibrary: Bool) async throws -> [QueueTrack] {
        let catalog = try await searchSongs(term)
        guard includingLibrary else { return catalog }
        let library = Self.librarySongs.filter { Self.matches($0.track, term) }
        return LibraryDuplicates.collapse(library.map { .library($0) } + catalog.map { .catalog($0) })
    }

    private static func matches(_ track: QueueTrack, _ term: String) -> Bool {
        let needle = term.lowercased()
        return track.title.lowercased().contains(needle) || track.artist.lowercased().contains(needle)
    }

    static let librarySongs: [LibraryDuplicates.LibraryResult] = [
        .init(track: track(1).libraryCopy(libraryID: "i.DemoDreams1", title: "Dreams (2004 Remaster)", artist: nil, album: nil),
              isAppleMusicCopy: false, hasArtwork: true),
        .init(track: .libraryOnly(libraryID: "i.DemoUpload1", title: "Harbour Lights (Live at the Lido)", artist: "The Tidelines",
                                  album: "Bootlegs", duration: 30), isAppleMusicCopy: false, hasArtwork: true),
        .init(track: .libraryOnly(libraryID: "i.DemoUpload3", title: "Paper Planes (Demo)", artist: "Juniper Row",
                                  album: "Demos 2009", duration: 30), isAppleMusicCopy: false, hasArtwork: false),
    ]

    public var libraryArtwork: (any LibraryArtworkSource)? { DemoLibraryArtwork() }

    /// Song counts come with the list, as Spotify's do. `-lazyCounts` leaves them out, as Apple
    /// Music's library list does, so rows count themselves (`songCount(of:)`). `-staleCounts`
    /// lists "New playlist" with the songs it had before they were removed, and adds "Voice
    /// memos", whose songs all can't play, so the pickers' start path can be tried on both.
    public func libraryPlaylists() async throws -> [PlaylistSummary] {
        let args = ProcessInfo.processInfo.arguments
        let stale = args.contains("-staleCounts")
        let playlists = [
            PlaylistSummary(id: "demo-party", name: "House party", songCount: 30, kind: .library),
            PlaylistSummary(id: "demo-chill", name: "Sunday chill", songCount: 12, kind: .library),
            PlaylistSummary(id: "demo-empty", name: "New playlist", songCount: stale ? 3 : 0, kind: .library),
            PlaylistSummary(id: "demo-big", name: "Big party", songCount: 400, kind: .library),
            PlaylistSummary(id: "demo-skips", name: "Road trip", subtitle: "4 can't play", songCount: 34, kind: .library),
        ] + (stale ? [PlaylistSummary(id: "demo-unplayable", name: "Voice memos", songCount: Self.unplayable.count, kind: .library)] : [])
        + DemoSavedPlaylists.all().map { saved in
            PlaylistSummary(id: saved.id, name: saved.name, subtitle: saved.description, songCount: saved.tracks.count, kind: .library)
        } + (args.contains("-manyPlaylists") ? Self.manyPlaylists : [])
        guard args.contains("-lazyCounts") else { return playlists }
        return playlists.map { var playlist = $0; playlist.songCount = nil; return playlist }
    }

    /// `-manyPlaylists`: a library the size of a big real one, for the web page's picker.
    static let manyPlaylists: [PlaylistSummary] = (1...520).map { index in
        let names = ["Café", "Road trip", "Dinner", "Workout", "Sunday", "Après-ski", "Late night", "Focus"]
        return PlaylistSummary(id: "demo-many-\(index)", name: "\(names[index % names.count]) \(index)", songCount: 30, kind: .library)
    }

    /// `-lazyCounts`: each count takes a moment, as a request per playlist would.
    public func songCount(of playlist: PlaylistSummary) async throws -> Int? {
        try await Task.sleep(for: .milliseconds(Int.random(in: 300...900)))
        if let saved = DemoSavedPlaylists.all().first(where: { $0.id == playlist.id }) { return saved.tracks.count }
        return switch playlist.id {
        case "demo-empty": 0
        case "demo-chill": 12
        case "demo-big": 400
        case "demo-skips": 34
        case "demo-unplayable": Self.unplayable.count
        default: Self.allTracks.count
        }
    }

    public func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] {
        [PlaylistSummary(id: "demo-party", name: "\(term) mix", subtitle: "Apple Music", kind: .catalog)]
    }

    public func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        if let saved = DemoSavedPlaylists.all().first(where: { $0.id == playlist.id }) { return saved.tracks }
        return switch playlist.id {
        case "demo-chill": Array(Self.allTracks.suffix(12))
        case "demo-big": Self.bigTracks
        case "demo-empty", "demo-unplayable": []
        default: Self.allTracks
        }
    }

    public var playlistDestination: String? { "Saves to the demo library" }

    /// Saved playlists show up in the demo library (in the playlist pickers), with their
    /// description as the subtitle. `-failSave` makes saving fail, to see the retry.
    public func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        try await Task.sleep(for: .milliseconds(800))
        if ProcessInfo.processInfo.arguments.contains("-failSave") { throw DemoSaveError() }
        DemoSavedPlaylists.add(.init(id: "demo-saved-\(UUID().uuidString)", name: name, description: description, tracks: tracks))
    }

    /// "Road trip" leaves out songs as a library playlist with uploads does, so the "not on
    /// Apple Music" note can be seen in the simulator. "Voice memos" (`-staleCounts`) is nothing else.
    public func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
        guard playlist.id == "demo-skips" || playlist.id == "demo-unplayable" else { return nil }
        var report = PlaylistLoadReport(playlistID: playlist.id)
        report.skipped = Self.unplayable
        report.loaded = playlist.id == "demo-skips" ? Self.allTracks.count : 0
        report.total = report.loaded + report.skipped.count
        return report
    }

    static let unplayable: [QueueTrack] = [
        QueueTrack(id: "demo-upload-1", title: "Harbour Lights (Live at the Lido)", artist: "The Tidelines", album: "Bootlegs"),
        QueueTrack(id: "demo-upload-2", title: "Mum's Birthday Song", artist: "Uncle Rob", album: "Voice Memos"),
        QueueTrack(id: "demo-upload-3", title: "Paper Planes (Demo)", artist: "Juniper Row", album: "Demos 2009"),
        QueueTrack(id: "demo-upload-4", title: "Untitled 4", artist: "Unknown Artist", album: "Unknown Album"),
    ]
}

struct DemoSaveError: LocalizedError {
    var errorDescription: String? { "The demo library didn't answer (-failSave)." }
}

/// Playlists saved to the demo library, kept between launches.
enum DemoSavedPlaylists {
    struct Saved: Codable {
        var id: String
        var name: String
        var description: String
        var tracks: [QueueTrack]
    }

    private static let key = "demoSavedPlaylists"

    static func all() -> [Saved] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
    }

    static func add(_ playlist: Saved) {
        let next = [playlist] + all()
        UserDefaults.standard.set(try? JSONEncoder().encode(next), forKey: key)
    }
}

/// The demo library's art, as the hub relays it (`/api/artwork/…`): a square of one of the demo
/// colours per song, or none for the songs the demo library has no art for.
struct DemoLibraryArtwork: LibraryArtworkSource {
    func artwork(libraryID: String, size: Int) async throws -> Data? {
        guard let index = DemoCatalog.librarySongs.firstIndex(where: { $0.track.libraryID == libraryID }),
              DemoCatalog.librarySongs[index].hasArtwork else { return nil }
        let colors = DemoCatalog.palette[(index + 3) % DemoCatalog.palette.count]
        let side = max(16, min(size, 1200))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(Self.color(colors.background))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(Self.color(colors.secondary))
        context.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func color(_ hex: String) -> CGColor {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// Timer-driven fake player. Tracks last `track.duration` seconds (30 in the demo catalog).
@MainActor
public final class DemoPlaybackEngine: PlaybackEngine {
    public let canReplaceStaged: Bool
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    private var current: QueueTrack?
    private var staged: QueueTrack?
    private var ticker: Task<Void, Never>?

    public init(canReplaceStaged: Bool = true) {
        self.canReplaceStaged = canReplaceStaged
    }

    public func play(_ track: QueueTrack) async throws {
        current = track
        staged = nil
        currentTime = 0
        isPlaying = true
        startTicker()
        onEvent?(.statusChanged)
    }

    public func stage(_ track: QueueTrack?) async throws {
        staged = track
    }

    public func resume() async throws {
        guard current != nil else { return }
        isPlaying = true
        startTicker()
        onEvent?(.statusChanged)
    }

    public func pause() {
        isPlaying = false
        ticker?.cancel()
        onEvent?(.statusChanged)
    }

    public func skipToStaged() async throws {
        guard staged != nil else { throw CancellationError() }
        moveToStaged()
    }

    public func restartCurrent() {
        currentTime = 0
    }

    public func seek(to time: TimeInterval) {
        currentTime = time
    }

    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    private func moveToStaged() {
        if let next = staged {
            current = next
            staged = nil
            currentTime = 0
            onEvent?(.advancedToStaged)
        } else {
            current = nil
            isPlaying = false
            ticker?.cancel()
            onEvent?(.reachedEnd)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            // Real elapsed time, not 0.25 per tick: a sleep runs a little long, which made the
            // demo's clock run a few percent slow, so displays (timing it from snapshots) ran ahead.
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isPlaying else { return }
                let now = Date()
                self.currentTime += now.timeIntervalSince(last)
                last = now
                if self.currentTime >= (self.current?.duration ?? 30) { self.moveToStaged() }
            }
        }
    }
}
#endif
