import Foundation
import Testing
@testable import CanopyMusicCore

/// Rooms joining and leaving while the music plays, against the simulated household: none of
/// it may restart the song or rebuild the queue.
@MainActor
@Suite struct SonosGroupingTests {
    let sim = SonosSimulator(rooms: [
        .init(id: "RINCON_BEAM", name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
        .init(id: "RINCON_MOVE", name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
        .init(id: "RINCON_ONE", name: "Kitchen", model: "One", host: "10.0.0.3", volume: 20),
    ])
    let bedroom = SonosTarget.Room(id: "RINCON_BEAM", name: "Bedroom", host: "10.0.0.1")
    let move = SonosTarget.Room(id: "RINCON_MOVE", name: "Move", host: "10.0.0.2")
    let kitchen = SonosTarget.Room(id: "RINCON_ONE", name: "Kitchen", host: "10.0.0.3")

    func engine(_ target: SonosTarget) -> SonosEngine {
        let engine = SonosEngine(target: target, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: sim)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        return engine
    }

    /// Actions that would restart the song or rebuild the queue.
    let restarts: Set<String> = ["RemoveAllTracksFromQueue", "AddURIToQueue", "Seek", "Play"]

    @Test func addingBeforeTheMusicStartsOnlyNotesIt() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom))
        try await engine.addRoom(move)
        #expect(sim.requests.isEmpty)
        #expect(engine.target.rooms.map(\.id) == ["RINCON_BEAM", "RINCON_MOVE"])
        // Grouped at the first play.
        try await engine.play(spotifyTrack("a"))
        #expect(sim.topology.contains(["RINCON_BEAM", "RINCON_MOVE"]))
    }

    @Test func addingWhilePlayingJoinsWithoutARestart() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom))
        var targets: [SonosTarget] = []
        engine.onTargetChanged = { targets.append($0) }
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        let before = sim.requests.count
        try await engine.addRoom(move)
        let sent = sim.requests[before...].filter { !$0.isReadOnly }
        #expect(sent.map(\.action) == ["SetAVTransportURI"])
        #expect(sent.first?.host == "10.0.0.2")
        #expect(sent.first?.argument("CurrentURI") == "x-rincon:RINCON_BEAM")
        #expect(await engine.waitUntilGrouped("RINCON_MOVE", timeout: .seconds(1)))
        #expect(sim.state(of: "RINCON_MOVE") == .playing)
        #expect(targets.last?.rooms.map(\.id) == ["RINCON_BEAM", "RINCON_MOVE"])
        // Adding it again does nothing.
        try await engine.addRoom(move)
        #expect(sim.changes.filter { $0.action == "SetAVTransportURI" }.count == 2) // the queue URI at play, the join
    }

    @Test func aRoomThatNeverJoinsIsReported() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom))
        try await engine.play(spotifyTrack("a"))
        #expect(await engine.waitUntilGrouped("RINCON_ONE", timeout: .milliseconds(200), every: .milliseconds(50)) == false)
    }

    @Test func removingAMemberLeavesTheOthersPlaying() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move]))
        try await engine.play(spotifyTrack("a"))
        let before = sim.requests.count
        try await engine.removeRoom("RINCON_MOVE")
        let sent = sim.requests[before...].filter { !$0.isReadOnly }
        #expect(sent.map(\.action) == ["BecomeCoordinatorOfStandaloneGroup"])
        #expect(sent.first?.host == "10.0.0.2")
        #expect(engine.target.rooms.map(\.id) == ["RINCON_BEAM"])
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
        #expect(sim.state(of: "RINCON_MOVE") == .stopped)
        #expect(sim.topology.contains(["RINCON_MOVE"]))
    }

    /// If a room that left carried on with a copy of the queue, it's paused.
    @Test func aRoomThatPlaysOnAfterLeavingIsPaused() async throws {
        sim.leaverPlaysOn = true
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move]))
        try await engine.play(spotifyTrack("a"))
        try await engine.removeRoom("RINCON_MOVE")
        #expect(sim.state(of: "RINCON_MOVE") == .paused)
        #expect(sim.changes.last?.action == "Pause")
        #expect(sim.changes.last?.host == "10.0.0.2")
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
    }

    @Test func removingTheCoordinatorHandsTheGroupOver() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move, kitchen]))
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        let before = sim.requests.count
        try await engine.removeRoom("RINCON_BEAM")
        let sent = Array(sim.requests[before...].filter { !$0.isReadOnly })
        #expect(sent.map(\.action) == ["DelegateGroupCoordinationTo"])
        #expect(sent[0].host == "10.0.0.1")
        #expect(sent[0].argument("NewCoordinator") == "RINCON_MOVE")
        #expect(sent[0].argument("RejoinGroup") == "0")
        #expect(Set(sent.map(\.action)).isDisjoint(with: restarts))
        #expect(engine.target.coordinator.id == "RINCON_MOVE")
        #expect(engine.target.rooms.map(\.id) == ["RINCON_MOVE", "RINCON_ONE"])
        #expect(sim.topology.contains(["RINCON_MOVE", "RINCON_ONE"]))
        #expect(sim.state(of: "RINCON_MOVE") == .playing)
        #expect(sim.state(of: "RINCON_BEAM") == .stopped)
        // Commands follow the new coordinator, on the same queue: the next stage goes after "a".
        try await engine.stage(spotifyTrack("c"))
        #expect(sim.changes.last?.host == "10.0.0.2")
        #expect(sim.queue(of: "RINCON_MOVE") == [sonosURI("a"), sonosURI("c")])
        // And so do polls.
        let polls = sim.requests.count
        try await engine.applyLatestObservation()
        #expect(sim.requests[polls...].allSatisfy { $0.host == "10.0.0.2" })
    }

    /// Not confirmed on real speakers: the new coordinator doesn't get the queue. The song goes
    /// back on there, where it was, with the staged song behind it.
    @Test func aHandoffThatLosesTheQueuePutsTheSongBack() async throws {
        sim.handoffDropsQueue = true
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move]))
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        engine.seek(to: 42)
        await settle()
        try await engine.removeRoom("RINCON_BEAM")
        #expect(engine.target.coordinator.id == "RINCON_MOVE")
        #expect(sim.queue(of: "RINCON_MOVE") == [sonosURI("a"), sonosURI("b")])
        #expect(sim.state(of: "RINCON_MOVE") == .playing)
        let seek = try #require(sim.changes.last { $0.action == "Seek" && $0.argument("Unit") == "REL_TIME" })
        #expect(seek.host == "10.0.0.2")
        #expect((SonosTime.seconds(seek.argument("Target")) ?? 0) >= 42)
    }

    @Test func theLastRoomStays() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom))
        try await engine.play(spotifyTrack("a"))
        await #expect(throws: SonosError.lastRoom) { try await engine.removeRoom("RINCON_BEAM") }
        await #expect(throws: SonosError.lastRoom) { try await engine.removeRoom("RINCON_MOVE") }
    }

    @Test func removingBeforeTheMusicStartsOnlyNotesIt() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move]))
        try await engine.removeRoom("RINCON_BEAM")
        #expect(sim.requests.isEmpty)
        #expect(engine.target.coordinator.id == "RINCON_MOVE")
        #expect(engine.target.joining.isEmpty)
    }

    // MARK: Dropping the engine

    @Test func aDroppedEngineThatNeverPlayedLeavesTheRoomAlone() async throws {
        sim.play(.init(uri: "x-sonos-htastream:RINCON_BEAM:spdif"), in: "RINCON_BEAM")
        let engine = engine(SonosTarget(coordinator: bedroom))
        engine.restoredTrackID = "spotify:track:a"
        engine.pause()
        engine.shutDown()
        await settle()
        #expect(sim.changes.isEmpty)
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
    }

    /// After a relaunch, the group is still playing the session's song from before: it's ours.
    @Test func aDroppedEngineStopsItsSongFromBeforeARelaunch() async throws {
        let earlier = engine(SonosTarget(coordinator: bedroom))
        try await earlier.play(spotifyTrack("a"))
        let engine = engine(SonosTarget(coordinator: bedroom))
        engine.restoredTrackID = "spotify:track:a"
        engine.pause()
        engine.shutDown()
        for _ in 0..<5 { await settle() }
        #expect(sim.state(of: "RINCON_BEAM") == .paused)
    }

    @Test func aDroppedEngineStopsPolling() async throws {
        let engine = engine(SonosTarget(coordinator: bedroom))
        try await engine.play(spotifyTrack("a"))
        engine.shutDown()
        let count = sim.requests.count
        await engine.poll()
        #expect(sim.requests.count == count)
    }

    // MARK: Volume

    @Test func groupVolumeGoesToTheCoordinatorAndKeepsTheBalance() async throws {
        sim.group(["RINCON_BEAM", "RINCON_MOVE"])
        let client = SonosClient(transport: sim, host: "10.0.0.1")
        try await client.snapshotGroupVolume()
        try await client.setGroupVolume(80)
        #expect(sim.room("RINCON_BEAM")?.volume == 60)
        #expect(sim.room("RINCON_MOVE")?.volume == 100)
        let set = try #require(sim.requests.last)
        #expect(set.service == .groupRenderingControl)
        #expect(set.service.controlPath == "/MediaRenderer/GroupRenderingControl/Control")
        #expect(set.argument("DesiredVolume") == "80")
        try await SonosClient(transport: sim, host: "10.0.0.2").setVolume(140)
        #expect(sim.room("RINCON_MOVE")?.volume == 100)
        #expect(try await SonosClient(transport: sim, host: "10.0.0.3").volume() == 20)
    }
}

/// What each room's second line says.
struct SonosRoomStatusTests {
    typealias S = SonosRoomStatus

    @Test func lines() {
        let idle = SonosRoomReading(responding: true, volume: 20)
        let busy = SonosRoomReading(responding: true, volume: 20, elsewhere: "Playing TV")
        #expect(S.of(roomID: "a", model: "Beam", ticked: true, joining: false, live: true, reading: idle) == .ours)
        #expect(S.of(roomID: "a", model: "Beam", ticked: true, joining: false, live: false, reading: idle) == .idle(model: "Beam"))
        #expect(S.of(roomID: "a", model: "Beam", ticked: false, joining: false, live: true, reading: idle) == .idle(model: "Beam"))
        #expect(S.of(roomID: "a", model: "Beam", ticked: false, joining: false, live: true, reading: busy) == .busy("Playing TV"))
        #expect(S.of(roomID: "a", model: "Beam", ticked: false, joining: true, live: true, reading: busy) == .joining)
        #expect(S.of(roomID: "a", model: "Beam", ticked: false, joining: false, live: true, reading: .notResponding) == .notResponding)
        #expect(S.of(roomID: "a", model: "Beam", ticked: false, joining: false, live: true, reading: nil) == .idle(model: "Beam"))
        #expect(S.ours.text == "Playing Canopy Music")
        #expect(!S.notResponding.canTick)
        #expect(S.busy("Playing TV").canTick)
    }

    @Test func whatOtherMusicIsCalled() {
        func describe(_ uri: String, title: String? = nil, artist: String? = nil, state: SonosTransportState = .playing, mediaTitle: String? = nil) -> String? {
            let item = SonosItem(id: "-1", title: title, creator: artist, uri: uri)
            return SonosNowPlaying.describe(state: state, position: SonosPositionInfo(track: 1, trackURI: uri, duration: nil, position: nil, item: item),
                                            mediaURI: uri, mediaTitle: mediaTitle, coordinatorID: "X", ourCoordinatorID: "Y")
        }
        #expect(describe("x-sonos-htastream:RINCON_X:spdif") == "Playing TV")
        #expect(describe("x-rincon-stream:RINCON_X") == "Playing line-in")
        #expect(describe("x-sonos-spotify:spotify%3atrack%3aabc?sid=12", title: "Ribs", artist: "Lorde") == "Playing Ribs – Lorde")
        #expect(describe("x-sonosapi-stream:s1234?sid=254", mediaTitle: "KEXP") == "Playing KEXP")
        #expect(describe("x-sonosapi-stream:s1234?sid=254") == "Playing something else")
        #expect(describe("x-sonos-spotify:spotify%3atrack%3aabc?sid=12", title: "Ribs", state: .paused) == nil)
        // Our own group's music isn't something else.
        #expect(SonosNowPlaying.describe(state: .playing, position: nil, mediaURI: nil, coordinatorID: "Y", ourCoordinatorID: "Y") == nil)
    }
}
