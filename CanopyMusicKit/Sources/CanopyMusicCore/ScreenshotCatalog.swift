#if DEBUG
// App Store screenshots: debug builds only, and only with `-screenshots`.

import Foundation

/// `-screenshots` (with the demo provider): invented artists, songs, and albums, with covers made
/// from Unsplash photos, for App Store screenshots that show no real album art or service. The
/// covers aren't in any bundle: they're read from the repo (`AppStoreScreenshots/Covers`, with
/// each photo's source in its README), which a simulator can reach, so only the simulator shows
/// them. The art goes through the hub's library-art relay (`/api/artwork/…`), as an Apple Music
/// library song's does, so the hub, its displays, and phones all show it.
public struct ScreenshotCatalog: MusicCatalog {
    public init() {}

    public static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-screenshots") }

    struct Album {
        let title: String
        let artist: String
        /// In `AppStoreScreenshots/Covers`.
        let cover: String
        let colors: ArtworkColors
        /// Title and length in seconds.
        let songs: [(String, TimeInterval)]
    }

    static let albums: [Album] = [
        Album(title: "Neon Hallways", artist: "Hollow Coast", cover: "1500462918059-b1a0cb512f1d",
              colors: .init(background: "#B0246A", primary: "#FFF0F6", secondary: "#FFB3D1"),
              songs: [("Neon Hallways", 214), ("Slow Satellites", 247), ("Wishing Well Parade", 198)]),
        Album(title: "Afterglow Radio", artist: "Marigold Static", cover: "1481437642641-2f0ae875f836",
              colors: .init(background: "#6B3A12", primary: "#FFF3E2", secondary: "#F5B66A"),
              songs: [("Sunset Polaroid", 223), ("Ferris Wheel Heart", 205), ("Summer in Reverse", 239)]),
        Album(title: "Low Tide Hearts", artist: "Juno Vale", cover: "1544365558-35aa4afcf11f",
              colors: .init(background: "#0E3B4A", primary: "#E6F8FC", secondary: "#E97AB0"),
              songs: [("Window Seat Weather", 231), ("Static in My Chest", 196), ("Rain Check", 184)]),
        Album(title: "Northbound Lights", artist: "The Paper Pilots", cover: "1508726989460-5741fe0304b3",
              colors: .init(background: "#1B2235", primary: "#FDEEE3", secondary: "#F08A4B"),
              songs: [("Northbound Lights", 262), ("Ember Sky", 217), ("Long Drive Home", 244)]),
        Album(title: "Spectrum Kids", artist: "Lumen Drift", cover: "1573655349936-de6bed86f839",
              colors: .init(background: "#14305E", primary: "#F2F7FF", secondary: "#F7C948"),
              songs: [("Light Through Glass", 208), ("Spectrum Kids", 191)]),
        Album(title: "Red Shift Summer", artist: "Velvet Arcade", cover: "1550275994-cdc89cd1948f",
              colors: .init(background: "#3A0D4A", primary: "#FCEBFF", secondary: "#FF4F7B"),
              songs: [("Red Shift", 202), ("Laser Tag Romance", 186), ("Night Bus Disco", 229)]),
        Album(title: "Fever Bloom", artist: "Tamsin Reyes", cover: "1563089145-599997674d42",
              colors: .init(background: "#4B1670", primary: "#FBEFFF", secondary: "#FF7AC8"),
              songs: [("Fever Bloom", 199), ("Ultraviolet Kiss", 211), ("Dancing on Mars", 226)]),
        Album(title: "Pine & Ember", artist: "Wild Orchard", cover: "1509934053585-b72b60c14695",
              colors: .init(background: "#2A2420", primary: "#FAF0E6", secondary: "#D98A4E"),
              songs: [("Campfire Choir", 253), ("Pinewood Letters", 238)]),
        Album(title: "Paper Waves", artist: "Oslo Moth", cover: "1558591710-4b4a1ae0f04d",
              colors: .init(background: "#5D6675", primary: "#FFFFFF", secondary: "#D7DCE4"),
              songs: [("Paper Waves", 219), ("Quiet Machines", 247)]),
        Album(title: "Colour Theory", artist: "Ruby Fathom", cover: "1604871000636-074fa5117945",
              colors: .init(background: "#0B2140", primary: "#EAF4FF", secondary: "#F47B5B"),
              songs: [("Colour Theory", 207), ("Undertow Dance", 232), ("Coral Sleep", 195)]),
        // Guests' requests only (`request`): not in "Saturday Night", so no cover shows twice in Up Next.
        Album(title: "Wire Garden", artist: "Echo Parlour", cover: "1549317336-206569e8475c",
              colors: .init(background: "#10153A", primary: "#EEF1FF", secondary: "#FF4FA0"),
              songs: [("Coil Lights", 203), ("Sparkline", 188)]),
        Album(title: "Ochre Fields", artist: "The June Harbour", cover: "1472120435266-53107fd0c44a",
              colors: .init(background: "#5A2416", primary: "#FFF1E0", secondary: "#FFB347"),
              songs: [("Late August", 241), ("Hayfield Sunset", 226)]),
    ]

    /// Every song, album by album.
    public static let allTracks: [QueueTrack] = albums.enumerated().flatMap { albumIndex, album in
        album.songs.enumerated().map { songIndex, song in
            let cover = coverID(albumIndex)
            return QueueTrack(
                id: "shot-\(albumIndex)-\(songIndex)", title: song.0, artist: album.artist, album: album.title,
                duration: song.1,
                artworkURL: LibraryArtwork.url(libraryID: cover, size: LibraryArtwork.largeSize),
                thumbnailURL: LibraryArtwork.url(libraryID: cover, size: LibraryArtwork.thumbnailSize),
                colors: album.colors
            )
        }
    }

    /// A library id for the relay's path (`LibraryArtwork.isLibraryID`), one per album.
    static func coverID(_ albumIndex: Int) -> String { "i.ShotCover\(albumIndex)" }

    /// The party's order: albums mixed, as a real playlist would be.
    static let partyOrder: [QueueTrack] = {
        let byAlbum = albums.indices.map { album in allTracks.filter { $0.album == albums[album].title } }
        var mixed: [QueueTrack] = []
        for round in 0..<3 {
            for album in [5, 0, 2, 6, 1, 9, 3, 7, 4, 8] where round < byAlbum[album].count {
                mixed.append(byAlbum[album][round])
            }
        }
        return mixed
    }()

    /// Songs for guests' requests (`-autoParty`), from the two albums "Saturday Night" leaves out.
    public static func request(_ index: Int) -> QueueTrack {
        let picks = [("Wire Garden", "Coil Lights"), ("Ochre Fields", "Late August")]
        let (album, title) = picks[index % picks.count]
        return allTracks.first { $0.album == album && $0.title == title } ?? allTracks[index]
    }

    static let playlists: [(id: String, name: String, tracks: [QueueTrack])] = [
        ("shot-saturday", "Saturday Night", partyOrder),
        ("shot-dinner", "Dinner Party", allTracks.filter { ["Afterglow Radio", "Paper Waves", "Pine & Ember", "Low Tide Hearts"].contains($0.album) }),
        ("shot-sunday", "Sunday Morning", allTracks.filter { ["Spectrum Kids", "Paper Waves", "Northbound Lights"].contains($0.album) }),
        ("shot-roadtrip", "Road Trip", allTracks.filter { ["Northbound Lights", "Afterglow Radio", "Colour Theory", "Neon Hallways"].contains($0.album) }),
        ("shot-latenight", "Late Night", allTracks.filter { ["Red Shift Summer", "Fever Bloom", "Neon Hallways"].contains($0.album) }),
    ]

    public func searchSongs(_ term: String) async throws -> [QueueTrack] {
        try await Task.sleep(for: .milliseconds(150))
        let needle = term.lowercased()
        return Self.allTracks.filter {
            $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle) || $0.album.lowercased().contains(needle)
        }
    }

    public func libraryPlaylists() async throws -> [PlaylistSummary] {
        Self.playlists.map { PlaylistSummary(id: $0.id, name: $0.name, songCount: $0.tracks.count, kind: .library) }
    }

    public func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }

    public func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        Self.playlists.first { $0.id == playlist.id }?.tracks ?? Self.partyOrder
    }

    public var libraryArtwork: (any LibraryArtworkSource)? { ScreenshotCovers() }
}

/// The covers, from the repo (see `ScreenshotCatalog`).
struct ScreenshotCovers: LibraryArtworkSource {
    /// `AppStoreScreenshots/Covers`, from this file's place in the repo.
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "AppStoreScreenshots/Covers")

    func artwork(libraryID: String, size: Int) async throws -> Data? {
        guard let index = ScreenshotCatalog.albums.indices.first(where: { ScreenshotCatalog.coverID($0) == libraryID }) else { return nil }
        let file = Self.folder.appending(path: "\(ScreenshotCatalog.albums[index].cover).jpg")
        let data = try? Data(contentsOf: file)
        if data == nil { print("[screenshots] no cover at \(file.path)") }
        return data
    }
}
#endif
