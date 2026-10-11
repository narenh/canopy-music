#if DEBUG
import CanopyCore
import Foundation

/// `-screenshotParty <scene>`: the party screen posed with real Apple Music catalog songs (looked up,
/// not played), for App Store screenshots from the simulator. Pair with `-capture`.
struct ScreenshotScene {
    struct Song { let title: String; let artist: String }

    let current: Song
    let upNext: [Song]
    /// Seconds into the current song.
    let time: TimeInterval

    static let all: [String: ScreenshotScene] = [
        "bigstick": ScreenshotScene(
            current: Song(title: "Big Stick", artist: "MUNA"),
            upNext: [
                Song(title: "The Dead Dance", artist: "Lady Gaga"),
                Song(title: "Replay", artist: "Lady Gaga"),
                Song(title: "Judas", artist: "Lady Gaga"),
                Song(title: "BOY CRAZY.", artist: "Kesha"),
                Song(title: "Aura", artist: "Lady Gaga"),
                Song(title: "Wannabeher", artist: "MUNA"),
                Song(title: "Don't Start Now", artist: "Dua Lipa"),
                Song(title: "Venus", artist: "Lady Gaga"),
                // The 13" list shows more rows than the 11" screenshot this matches.
                Song(title: "Sympathy is a knife", artist: "Charli xcx"),
                Song(title: "Number One Fan", artist: "MUNA"),
                Song(title: "Anaheim Star", artist: "Rebecca Black"),
                Song(title: "Home By Now", artist: "MUNA"),
            ],
            time: 29
        ),
        "venus": ScreenshotScene(
            current: Song(title: "Venus", artist: "Lady Gaga"),
            upNext: phoneQueue,
            time: 3
        ),
        "phone": ScreenshotScene(
            current: Song(title: "Number One Fan", artist: "MUNA"),
            upNext: Array(phoneQueue.dropFirst()),
            time: 52
        ),
    ]

    private static let phoneQueue = [
        Song(title: "Number One Fan", artist: "MUNA"),
        Song(title: "Guess / JOYRIDE (Mixed)", artist: "Charli xcx"),
        Song(title: "Sugar Water Cyanide", artist: "Rebecca Black"),
        Song(title: "Anaheim Star", artist: "Rebecca Black"),
        Song(title: "Sympathy is a knife", artist: "Charli xcx"),
        Song(title: "Home By Now", artist: "MUNA"),
        Song(title: "Vogue / yes, and? (Mixed)", artist: "Madonna"),
        Song(title: "Platinum", artist: "Cobrah"),
        Song(title: "Ozempic Wegovy Mounjaro", artist: ""),
        Song(title: "Danceteria Afterhours", artist: "Madonna"),
        // Fill the taller 13" list.
        Song(title: "Don't Start Now", artist: "Dua Lipa"),
        Song(title: "BOY CRAZY.", artist: "Kesha"),
        Song(title: "Wannabeher", artist: "MUNA"),
    ]

    /// Finds each song in the catalog: the first result whose title and artist match, else the first result.
    func resolve(with catalog: MusicCatalog) async -> [QueueTrack] {
        var tracks: [QueueTrack] = []
        for song in [current] + upNext {
            let results = (try? await catalog.searchSongs("\(song.title) \(song.artist)")) ?? []
            let match = results.first { Self.matches($0, song) } ?? results.first
            print("[screenshot] \(song.title) – \(song.artist) -> \(match.map { "\($0.title) – \($0.artist)" } ?? "NOT FOUND")\(match.map { Self.matches($0, song) } == true ? "" : " (check)")")
            if let match { tracks.append(match) }
        }
        return tracks
    }

    private static func matches(_ track: QueueTrack, _ song: Song) -> Bool {
        let fold = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return fold(track.title).hasPrefix(fold(song.title)) && (song.artist.isEmpty || fold(track.artist).contains(fold(song.artist)))
    }
}

/// A catalog that "contains" one playlist: the resolved scene.
struct FixedCatalog: MusicCatalog {
    let tracks: [QueueTrack]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { tracks }
}

/// Pretends to play, frozen at `time`.
@MainActor
final class PosedEngine: PlaybackEngine {
    let canReplaceStaged = true
    let isPlaying = true
    let currentTime: TimeInterval
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    init(time: TimeInterval) { currentTime = time }

    func play(_ track: QueueTrack) async throws {}
    func stage(_ track: QueueTrack?) async throws {}
    func resume() async throws {}
    func pause() {}
    func skipToStaged() async throws {}
    func restartCurrent() {}
    func seek(to time: TimeInterval) {}
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}
}
#endif
