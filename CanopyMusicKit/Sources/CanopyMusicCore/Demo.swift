#if DEBUG
// Demo provider: debug builds only (simulator, previews, the Mac dev server).

import Foundation

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
        let needle = term.lowercased()
        return Self.allTracks.filter {
            $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle)
        }
    }

    public func libraryPlaylists() async throws -> [PlaylistSummary] {
        [
            PlaylistSummary(id: "demo-party", name: "House party", subtitle: "30 songs", kind: .library),
            PlaylistSummary(id: "demo-chill", name: "Sunday chill", subtitle: "12 songs", kind: .library),
            PlaylistSummary(id: "demo-big", name: "Big party", subtitle: "400 songs", kind: .library),
            PlaylistSummary(id: "demo-skips", name: "Road trip", subtitle: "34 songs, 4 can't play", kind: .library),
        ] + (ProcessInfo.processInfo.arguments.contains("-manyPlaylists") ? Self.manyPlaylists : [])
    }

    /// `-manyPlaylists`: a library the size of a big real one, for the web page's picker.
    static let manyPlaylists: [PlaylistSummary] = (1...520).map { index in
        let names = ["Café", "Road trip", "Dinner", "Workout", "Sunday", "Après-ski", "Late night", "Focus"]
        return PlaylistSummary(id: "demo-many-\(index)", name: "\(names[index % names.count]) \(index)", subtitle: "30 songs", kind: .library)
    }

    public func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] {
        [PlaylistSummary(id: "demo-party", name: "\(term) mix", subtitle: "Apple Music", kind: .catalog)]
    }

    public func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        switch playlist.id {
        case "demo-chill": Array(Self.allTracks.suffix(12))
        case "demo-big": Self.bigTracks
        default: Self.allTracks
        }
    }

    /// "Road trip" leaves out songs as a library playlist with uploads does, so the "not on
    /// Apple Music" note can be seen in the simulator.
    public func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? {
        guard playlist.id == "demo-skips" else { return nil }
        var report = PlaylistLoadReport(playlistID: playlist.id)
        report.skipped = Self.unplayable
        report.loaded = Self.allTracks.count
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
