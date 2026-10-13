import CanopyMusicCore
import Foundation
import Testing
@testable import CanopyMusicServer

/// The household as the speaker lists read it, from the simulated one.
@MainActor
@Suite struct SonosHouseholdTests {
    let sim = SonosSimulator(rooms: [
        .init(id: "RINCON_BEAM", name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
        .init(id: "RINCON_MOVE", name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
        .init(id: "RINCON_ONE", name: "Kitchen", model: "One", host: "10.0.0.3", volume: 20, reachable: false),
    ])

    func household() async -> SonosHousehold {
        let household = SonosHousehold(transport: sim, fixedHosts: ["10.0.0.1", "10.0.0.2", "10.0.0.3"])
        household.start()
        for _ in 0..<100 where household.players.count < 3 || household.isRefreshing {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return household
    }

    @Test func roomsVolumesAndWhatTheyrePlaying() async {
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3aabc?sid=12&flags=8232&sn=4", title: "Ribs", artist: "Lorde"), in: "RINCON_MOVE")
        let household = await household()
        #expect(household.rooms.map(\.roomName) == ["Bedroom", "Kitchen", "Move"])
        #expect(household.player("RINCON_BEAM")?.displayName == "Beam")
        // Kitchen didn't describe itself: listed from the topology by name.
        #expect(household.player("RINCON_ONE")?.host == "10.0.0.3")
        #expect(household.accounts(for: .spotify).map(\.serialNumber) == [4])
        await household.readRooms(ourCoordinatorID: "RINCON_BEAM")
        #expect(household.readings["RINCON_BEAM"] == SonosRoomReading(responding: true, volume: 30, coordinatorID: "RINCON_BEAM"))
        #expect(household.readings["RINCON_MOVE"]?.elsewhere == "Playing Ribs – Lorde")
        #expect(household.readings["RINCON_ONE"] == .notResponding)
        // Only reads.
        #expect(sim.changes.isEmpty)
    }

    @Test func theZonesOwnGroupIsntSomethingElse() async {
        sim.group(["RINCON_BEAM", "RINCON_MOVE"])
        sim.play(.init(uri: "x-sonos-spotify:spotify%3atrack%3aabc?sid=12&flags=8232&sn=4", title: "Ribs"), in: "RINCON_BEAM")
        let household = await household()
        await household.readRooms(ourCoordinatorID: "RINCON_BEAM")
        #expect(household.readings["RINCON_MOVE"]?.elsewhere == nil)
        #expect(household.readings["RINCON_MOVE"]?.coordinatorID == "RINCON_BEAM")
    }
}
