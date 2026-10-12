#if DEBUG
import CanopyMusicCore
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
            // Exact title and artist first, so "Sympathy is a knife" isn't a remix or a feature.
            let match = results.first { Self.matches($0, song, exact: true) } ?? results.first { Self.matches($0, song) } ?? results.first
            print("[screenshot] \(song.title) – \(song.artist) -> \(match.map { "\($0.title) – \($0.artist)" } ?? "NOT FOUND")\(match.map { Self.matches($0, song) } == true ? "" : " (check)")")
            if let match { tracks.append(match) }
        }
        return tracks
    }

    private static func matches(_ track: QueueTrack, _ song: Song, exact: Bool = false) -> Bool {
        let fold = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if exact { return fold(track.title) == fold(song.title) && fold(track.artist) == fold(song.artist) }
        return fold(track.title).hasPrefix(fold(song.title)) && (song.artist.isEmpty || fold(track.artist).contains(fold(song.artist)))
    }
}

/// The hub's marketing values while posing, so displays (the Apple TV) show "Playing from
/// Living Room" and `music.local` on their join card instead of the simulator's own names.
/// Call `ScreenshotHub.pose(model)` right after `installScreenshotSession`.
@MainActor
enum ScreenshotHub {
    /// With a no-break space: it reads the same, but `-showZone $'Living\xc2\xa0Room'` on the Apple
    /// TV picks this zone over another "Living Room" on the network.
    static let zoneName = "Living\u{00A0}Room"
    static let guestAddress = "music.local"

    static func pose(_ model: AppModel) {
        model.zoneName = zoneName
        // mDNS confirms the simulator's own `.local` name after this (and again after renames): keep ours.
        Task { @MainActor in
            while true {
                if model.session.guestAddress != guestAddress { model.session.guestAddress = guestAddress }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
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
