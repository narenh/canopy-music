#if DEBUG
import CanopyMusicCore
import Foundation

/// `-sonosFake`: a made-up Sonos household for the simulator, so the speaker lists and the
/// Speakers panel can be seen and used without real speakers. Everything stays in memory
/// (`SonosSimulator`): nothing is sent to any device.
///
/// Bedroom (Beam) is idle, Move (Move) is playing something from the Sonos app, and Kitchen
/// (One) doesn't answer. Pair with `-sonosFakeParty 1|2` for the party screen playing in
/// Bedroom (and Move), and `-sonosPanel` to open its Speakers panel.
@MainActor
enum SonosFakeHousehold {
    static func make() -> SonosSimulator {
        let simulator = SonosSimulator(rooms: [
            .init(id: "RINCON_FAKEBEDROOM01400", name: "Bedroom", model: "Beam", host: "192.0.2.11", volume: 38),
            .init(id: "RINCON_FAKEMOVE0001400", name: "Move", model: "Move", host: "192.0.2.12", volume: 25),
            .init(id: "RINCON_FAKEKITCHEN01400", name: "Kitchen", model: "One", host: "192.0.2.13", volume: 30, reachable: false),
        ])
        simulator.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3a6dOtVTDdiauQNBQEDOtlAB?sid=12&flags=8232&sn=4",
                             title: "Birds of a Feather", artist: "Billie Eilish"), in: "RINCON_FAKEMOVE0001400")
        // Feels like real speakers: answers take a moment, and joining a group longer.
        simulator.latency = .milliseconds(40)
        simulator.joinDelay = .milliseconds(1200)
        return simulator
    }

    /// Made-up Apple Music catalog songs for `-sonosFakeParty` (ids are numeric, as Sonos needs).
    static let songs: [QueueTrack] = {
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
#endif
