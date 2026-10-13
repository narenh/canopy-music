import Foundation
import Testing
@testable import CanopyMusicCore

/// A relaunch while the music plays through Sonos: Sonos plays on while the app is gone, and the
/// restored session takes the group back as it is (`SonosEngine.attach`), or leaves the speakers
/// alone when they're on something else.
@MainActor
@Suite struct SonosAttachTests {
    let sim = SonosSimulator(rooms: [
        .init(id: "RINCON_BEAM", name: "Bedroom", model: "Beam", host: "10.0.0.1", volume: 30),
        .init(id: "RINCON_MOVE", name: "Move", model: "Move", host: "10.0.0.2", volume: 50),
        .init(id: "RINCON_ONE", name: "Kitchen", model: "One", host: "10.0.0.3", volume: 20),
    ])
    let bedroom = SonosTarget.Room(id: "RINCON_BEAM", name: "Bedroom", host: "10.0.0.1")
    let move = SonosTarget.Room(id: "RINCON_MOVE", name: "Move", host: "10.0.0.2")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-sonos-attach-\(UUID()).json")
    /// Actions that would restart the song or rebuild the queue.
    let restarts: Set<String> = ["RemoveAllTracksFromQueue", "AddURIToQueue", "SetAVTransportURI", "Seek", "Play"]

    func engine(_ target: SonosTarget) -> SonosEngine {
        let engine = SonosEngine(target: target, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: sim)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        return engine
    }

    /// The party before the relaunch: "a" playing in Bedroom + Move (Bedroom leading) with "b"
    /// staged after it, at `position`, paused if asked. Then the app goes away without a word to
    /// the speakers, its queue saved.
    func partyBeforeTheRelaunch(at position: TimeInterval = 95, paused: Bool = false) async throws {
        let engine = engine(SonosTarget(coordinator: bedroom, joining: [move]))
        let session = PartySession(catalog: SpotifyStubCatalog(ids: ["a", "b", "c"]), engine: engine, storeURL: url)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        session.seek(to: position)
        await settle()
        if paused {
            session.pause()
            await settle()
        }
        engine.stop()
        try JSONEncoder().encode(session.state).write(to: url)
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b")])
        #expect(sim.topology.contains(["RINCON_BEAM", "RINCON_MOVE"]))
    }

    /// The relaunched app's session, from the saved queue, its engine reading the speakers.
    func relaunch(_ target: SonosTarget? = nil, onTarget: (@MainActor (SonosTarget) -> Void)? = nil) async -> (PartySession, SonosEngine) {
        let engine = engine(target ?? SonosTarget(coordinator: bedroom, joining: [move]))
        let session = PartySession(catalog: SpotifyStubCatalog(ids: []), engine: engine, storeURL: url)
        // Wired after the session, as the app does.
        engine.onTargetChanged = onTarget
        await engine.attachTask?.value
        await settle()
        return (session, engine)
    }

    func sent(since index: Int) -> [SonosRequest] { sim.requests[index...].filter { !$0.isReadOnly } }

    @Test func aRelaunchTakesOverTheGroupStillPlayingOurSong() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        let before = sim.requests.count
        var targets: [SonosTarget] = []
        // Saved with the rooms the other way round: the group as it really is wins.
        let (session, engine) = await relaunch(SonosTarget(coordinator: move, joining: [bedroom])) { targets.append($0) }

        #expect(session.isPlaying)
        #expect(session.state.current?.track.id == "spotify:track:a")
        let playback = session.snapshot().playback
        #expect(playback.isPlaying)
        #expect(playback.position >= 95 && playback.position < 97)
        #expect(engine.isGrouped)
        #expect(engine.target.coordinator.id == "RINCON_BEAM")
        #expect(engine.target.rooms.map(\.id) == ["RINCON_BEAM", "RINCON_MOVE"])
        #expect(targets.last?.coordinator.id == "RINCON_BEAM")
        // Nothing sent: no clear, seek or play, and "b" is already queued after "a".
        #expect(sent(since: before).isEmpty)
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b")])

        // The song ends: the group goes on to "b" from its queue, and "c" is staged behind it.
        sim.finishTrack(in: "RINCON_BEAM")
        try await engine.applyLatestObservation()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:b")
        #expect(session.isPlaying)
        #expect(sent(since: before).map(\.action) == ["AddURIToQueue"])
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b"), sonosURI("c")])
    }

    /// Pause, Play, seek and skip on the group taken over, none of them starting the song again.
    @Test func theControlsWorkOnTheGroupTakenOver() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        let (session, _) = await relaunch()
        var before = sim.requests.count

        session.pause()
        await settle()
        #expect(!session.isPlaying)
        #expect(sim.state(of: "RINCON_BEAM") == .paused)
        #expect(sent(since: before).map(\.action) == ["Pause"])

        before = sim.requests.count
        try await session.play()
        await settle()
        #expect(session.isPlaying)
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
        #expect(sent(since: before).map(\.action) == ["Play"])
        #expect(session.engine.currentTime >= 95)

        before = sim.requests.count
        session.seek(to: 30)
        await settle()
        #expect(sent(since: before).map { "\($0.action) \($0.argument("Unit") ?? "")" } == ["Seek REL_TIME"])

        // Skip goes to "b", already queued after "a".
        before = sim.requests.count
        await session.skip()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:b")
        #expect(sent(since: before).filter { $0.action == "RemoveAllTracksFromQueue" }.isEmpty)
        #expect(sent(since: before).first.map { "\($0.action) \($0.argument("Target") ?? "")" } == "Seek 2")
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
    }

    @Test func aRelaunchFindsOurSongPausedWhereItWas() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch(paused: true)
        let before = sim.requests.count
        let (session, engine) = await relaunch()

        #expect(!session.isPlaying)
        #expect(session.engine.currentTime >= 95 && session.engine.currentTime < 96)
        #expect(engine.isGrouped)
        #expect(sent(since: before).isEmpty)
        #expect(sim.state(of: "RINCON_BEAM") == .paused)

        // Play resumes it there.
        try await session.play()
        await settle()
        #expect(session.isPlaying)
        #expect(sent(since: before).map(\.action) == ["Play"])
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
        #expect(session.engine.currentTime >= 95)
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b")])
    }

    /// The TV took Bedroom's group over while the app was gone: it's left alone; Play takes the
    /// rooms back as usual.
    @Test func aGroupOnAnotherSourceIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        sim.play(.init(uri: "x-sonos-htastream:RINCON_BEAM:spdif"), in: "RINCON_BEAM")
        let before = sim.requests.count
        let (session, engine) = await relaunch()

        #expect(!session.isPlaying)
        #expect(!engine.isGrouped)
        #expect(engine.attachedTrackID == nil)
        #expect(sent(since: before).isEmpty)
        #expect(sim.state(of: "RINCON_BEAM") == .playing)

        try await session.play()
        await settle()
        #expect(session.isPlaying)
        #expect(sent(since: before).contains { $0.action == "RemoveAllTracksFromQueue" })
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b")])
        #expect(sim.state(of: "RINCON_BEAM") == .playing)
    }

    /// Neither room answers for the layout: nothing is taken over, and nothing sent.
    @Test func anUnreadableLayoutLeavesTheSpeakersAlone() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        sim.setReachable("RINCON_BEAM", false)
        sim.setReachable("RINCON_MOVE", false)
        let before = sim.requests.count
        let (session, engine) = await relaunch()

        #expect(!session.isPlaying)
        #expect(!engine.isGrouped)
        #expect(sent(since: before).isEmpty)
        #expect(sim.requests[before...].allSatisfy { $0.action == "GetZoneGroupState" })

        // Back on: Play starts the song through the normal path.
        sim.setReachable("RINCON_BEAM", true)
        sim.setReachable("RINCON_MOVE", true)
        try await session.play()
        await settle()
        #expect(session.isPlaying)
        #expect(sent(since: before).contains { $0.action == "RemoveAllTracksFromQueue" })
    }

    /// Dropping a session that took the group over pauses our song (the engine has started).
    @Test func droppingTheSessionTakenOverPausesOurSong() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        let (session, _) = await relaunch()
        let before = sim.requests.count
        session.shutdown()
        for _ in 0..<5 { await settle() }
        #expect(sim.state(of: "RINCON_BEAM") == .paused)
        #expect(sent(since: before).map(\.action) == ["Pause"])
    }

    /// The session's next song isn't the group's next queue entry: the session stages its own.
    @Test func anotherNextEntryIsRestaged() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await partyBeforeTheRelaunch()
        // "b" went from the group's queue (the Sonos app, say).
        try await SonosClient(transport: sim, host: "10.0.0.1").removeFromQueue(trackNumber: 2)
        let before = sim.requests.count
        let (session, _) = await relaunch()
        #expect(session.isPlaying)
        #expect(sent(since: before).filter { restarts.contains($0.action) }.map(\.action) == ["AddURIToQueue"])
        #expect(sim.queue(of: "RINCON_BEAM") == [sonosURI("a"), sonosURI("b")])
    }
}
