#if DEBUG
import Foundation

/// `-sonosFake` (iPad, Mac and Apple TV): a made-up Sonos household for the simulator, so the
/// speaker lists, the Speakers panel and the phone page's Sonos choices can be seen and used
/// without real speakers. Everything stays in memory (`SonosSimulator`): nothing is sent to any
/// device.
///
/// Bedroom (Beam) is idle, Move (Move) is playing something from the Sonos app, and Kitchen
/// (One) doesn't answer. On the iPad, pair with `-sonosFakeParty 1|2` for the party screen
/// playing in Bedroom (and Move), and `-sonosPanel` to open its Speakers panel.
///
/// `-sonosFakeOtherZone` (`otherZone`): another Canopy Music zone, "Living Room iPad" on Apple
/// Music, plays in Bedroom and Move (grouped, Bedroom leading), and Kitchen answers, so it's the
/// free room. The hub is told of that zone as if it had asked it (`otherZoneClaim`); no second
/// hub runs.
@MainActor
public enum SonosFakeHousehold {
    public static let bedroom = "RINCON_FAKEBEDROOM01400"
    public static let move = "RINCON_FAKEMOVE0001400"
    public static let kitchen = "RINCON_FAKEKITCHEN01400"

    /// The made-up zone `-sonosFakeOtherZone` says plays in Bedroom and Move.
    public static let otherZoneClaim = SonosZoneClaim(zone: "Living Room iPad", service: "Apple Music", household: "Sonos_Simulated",
                                                      rooms: [bedroom, move])

    public static var isOtherZone: Bool { ProcessInfo.processInfo.arguments.contains("-sonosFakeOtherZone") }

    public static func make(otherZone: Bool = isOtherZone) -> SonosSimulator {
        let simulator = SonosSimulator(rooms: [
            .init(id: bedroom, name: "Bedroom", model: "Beam", host: "192.0.2.11", volume: 38),
            .init(id: move, name: "Move", model: "Move", host: "192.0.2.12", volume: 25),
            .init(id: kitchen, name: "Kitchen", model: "One", host: "192.0.2.13", volume: 30, reachable: otherZone),
        ])
        if otherZone {
            simulator.group([bedroom, move])
            simulator.play(.init(uri: "x-sonos-http:song%3a1000000001.mp4?sid=204&flags=8224&sn=3", title: "Ribs", artist: "Lorde"), in: bedroom)
        } else {
            simulator.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3a6dOtVTDdiauQNBQEDOtlAB?sid=12&flags=8232&sn=4",
                                 title: "Birds of a Feather", artist: "Billie Eilish"), in: move)
        }
        // Feels like real speakers: answers take a moment, and joining a group longer.
        simulator.latency = .milliseconds(40)
        simulator.joinDelay = .milliseconds(1200)
        return simulator
    }

    /// Made-up Apple Music catalog songs for `-sonosFakeParty` (ids are numeric, as Sonos needs).
    public static let songs: [QueueTrack] = {
        func colors(_ background: String, _ secondary: String) -> ArtworkColors {
            ArtworkColors(background: background, primary: "#FFFFFF", secondary: secondary)
        }
        return [
            QueueTrack(id: "1000000001", title: "Ribs", artist: "Lorde", album: "Pure Heroine", duration: 258, colors: colors("#0F5444", "#5CC6A0")),
            QueueTrack(id: "1000000002", title: "Dreams", artist: "Fleetwood Mac", album: "Rumours", duration: 257, colors: colors("#5A3A1E", "#E8B07A")),
            QueueTrack(id: "1000000003", title: "Dancing On My Own", artist: "Robyn", album: "Body Talk", duration: 288, colors: colors("#1E3A5A", "#8CB8E8")),
            QueueTrack(id: "1000000004", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 244, colors: colors("#3A1E5A", "#B88CE8")),
            QueueTrack(id: "1000000005", title: "Heads Will Roll", artist: "Yeah Yeah Yeahs", album: "It's Blitz!", duration: 222, colors: colors("#7A1F3D", "#F29BB8")),
        ]
    }()
}

/// The demo catalog with ids as the service's own catalog gives them, so Sonos can carry them
/// and read them back: "demo-12" is "2000000012" (Apple Music: catalog ids are all digits) or
/// "spotify:track:2000000012". For a simulator hub playing through the fake household
/// (`-sonosFake`), which has no real catalog.
public struct SonosFakeCatalog: MusicCatalog {
    private let demo = DemoCatalog()
    private let service: SonosMusicService

    public init(service: SonosMusicService = .appleMusic) {
        self.service = service
    }

    func sonosID(_ id: String) -> String {
        guard id.hasPrefix("demo-"), let number = Int(id.split(separator: "-").last ?? "") else { return id }
        let digits = String(2_000_000_000 + number)
        return service == .spotify ? "spotify:track:\(digits)" : digits
    }

    func sonosTrack(_ track: QueueTrack) -> QueueTrack {
        var track = track
        track.id = sonosID(track.id)
        return track
    }

    public func searchSongs(_ term: String) async throws -> [QueueTrack] {
        try await demo.searchSongs(term).map(sonosTrack)
    }

    public func libraryPlaylists() async throws -> [PlaylistSummary] { try await demo.libraryPlaylists() }
    public func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { try await demo.searchPlaylists(term) }

    public func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] {
        try await demo.tracks(in: playlist).map(sonosTrack)
    }

    public func songCount(of playlist: PlaylistSummary) async throws -> Int? { try await demo.songCount(of: playlist) }
    public func loadReport(for playlist: PlaylistSummary) async -> PlaylistLoadReport? { await demo.loadReport(for: playlist) }
    public var playlistDestination: String? { demo.playlistDestination }

    public func savePlaylist(name: String, description: String, tracks: [QueueTrack]) async throws {
        try await demo.savePlaylist(name: name, description: description, tracks: tracks)
    }
}
#endif
