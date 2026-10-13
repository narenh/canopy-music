import Foundation
import Testing
@testable import CanopyMusicCore

/// A pretend Sonos group: a queue, a position and a transport state, driven by the same SOAP
/// actions a real player takes. It answers every host (members too) and records each request.
@MainActor
final class FakeSonos: SonosTransport {
    var requests: [SonosRequest] = []
    var queue: [String] = []
    var track = 1
    var state: SonosTransportState = .stopped
    var position: TimeInterval = 0
    /// Overrides what `GetPositionInfo` says is playing (another source took the room).
    var foreignURI: String?
    /// Actions that fail with this UPnP code.
    var failing: [String: Int] = [:]

    var actions: [String] { requests.map(\.action) }
    var changes: [SonosRequest] { requests.filter { !$0.isReadOnly } }

    func send(_ request: SonosRequest) async throws -> [String: String] {
        requests.append(request)
        if let code = failing[request.action] { throw SonosError.upnp(action: request.action, code: code) }
        switch request.action {
        case "RemoveAllTracksFromQueue":
            queue = []
        case "AddURIToQueue":
            let uri = request.argument("EnqueuedURI")!
            let desired = Int(request.argument("DesiredFirstTrackNumberEnqueued")!)!
            let index = desired == 0 || desired > queue.count ? queue.count : desired - 1
            queue.insert(uri, at: index)
            return ["FirstTrackNumberEnqueued": "\(index + 1)", "NumTracksAdded": "1", "NewQueueLength": "\(queue.count)"]
        case "RemoveTrackFromQueue":
            let number = Int(request.argument("ObjectID")!.split(separator: "/").last!)!
            queue.remove(at: number - 1)
            if number < track { track -= 1 }
        case "Seek":
            if request.argument("Unit") == "TRACK_NR" {
                track = Int(request.argument("Target")!)!
                position = 0
            } else {
                position = SonosTime.seconds(request.argument("Target")) ?? 0
            }
        case "Play": state = .playing
        case "Pause": state = .paused
        case "GetPositionInfo":
            let uri = foreignURI ?? (queue.indices.contains(track - 1) ? queue[track - 1] : "")
            return ["Track": "\(track)", "TrackURI": uri, "RelTime": SonosTime.string(position), "TrackDuration": "0:03:00",
                    "TrackMetaData": "NOT_IMPLEMENTED"]
        case "GetTransportInfo":
            return ["CurrentTransportState": state.rawValue, "CurrentTransportStatus": "OK", "CurrentSpeed": "1"]
        default:
            break
        }
        return [:]
    }

    func get(host: String, path: String) async throws -> Data { Data() }

    /// The current song ends: on to the next queue entry, or (at the end) back to the first, stopped.
    func finishTrack() {
        if track < queue.count {
            track += 1
            position = 0
        } else {
            track = 1
            position = 0
            state = .stopped
        }
    }
}

let sonosTarget = SonosTarget(coordinator: .init(id: "RINCON_MOVE", name: "Sonos Move", host: "10.0.1.224"))
func spotifyTrack(_ id: String) -> QueueTrack { QueueTrack(id: "spotify:track:\(id)", title: id, artist: "Artist", duration: 180) }
func sonosURI(_ id: String) -> String { "x-sonos-spotify:spotify%3atrack%3a\(id)?sid=12&flags=8232&sn=4" }

@MainActor
@Suite struct SonosEngineTests {
    let fake = FakeSonos()
    let engine: SonosEngine
    var events: [PlaybackEvent] { recorder.events }
    let recorder = EventRecorder()

    init() {
        engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600)) // tests poll by hand
        let recorder = recorder
        engine.onEvent = { recorder.events.append($0) }
    }

    @Test func playReplacesTheQueueAndPlaysIt() async throws {
        fake.queue = ["someone else's song"]
        try await engine.play(spotifyTrack("a"))
        #expect(fake.actions == ["RemoveAllTracksFromQueue", "AddURIToQueue", "SetAVTransportURI", "SetPlayMode", "Seek", "Play"])
        #expect(fake.requests.allSatisfy { $0.host == "10.0.1.224" })
        let add = fake.requests[1]
        #expect(add.argument("EnqueuedURI") == sonosURI("a"))
        #expect(add.argument("EnqueuedURIMetaData")?.contains("<desc id=\"cdudn\"") == true)
        #expect(fake.requests[2].argument("CurrentURI") == "x-rincon-queue:RINCON_MOVE#0")
        #expect(fake.requests[4].argument("Unit") == "TRACK_NR")
        #expect(fake.requests[4].argument("Target") == "1")
        #expect(fake.queue == [sonosURI("a")])
        #expect(engine.isPlaying)
    }

    @Test func stagingInsertsAfterTheCurrentSongAndReplaces() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        #expect(fake.queue == [sonosURI("a"), sonosURI("b")])
        // Restage: the new song goes in right after the current one, then the old one goes.
        try await engine.stage(spotifyTrack("c"))
        #expect(fake.queue == [sonosURI("a"), sonosURI("c")])
        let restage = fake.changes.suffix(2)
        #expect(restage.map(\.action) == ["AddURIToQueue", "RemoveTrackFromQueue"])
        #expect(restage.first?.argument("DesiredFirstTrackNumberEnqueued") == "2")
        #expect(restage.first?.argument("EnqueueAsNext") == "1")
        #expect(restage.last?.argument("ObjectID") == "Q:0/3")
        // Unstage.
        try await engine.stage(nil)
        #expect(fake.queue == [sonosURI("a")])
    }

    @Test func movingOnToTheStagedSong() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        await engine.poll() // settling after play: nothing read yet
        try await engine.applyLatestObservation()
        #expect(events.isEmpty || events == [.statusChanged])
        fake.finishTrack()
        let advanced = try await engine.applyLatestObservation()
        #expect(advanced)
        #expect(events.contains(.advancedToStaged))
        // The next stage goes after the new current song (#2).
        try await engine.stage(spotifyTrack("c"))
        #expect(fake.queue == [sonosURI("a"), sonosURI("b"), sonosURI("c")])
        #expect(fake.changes.last?.argument("DesiredFirstTrackNumberEnqueued") == "3")
    }

    @Test func reachingTheEnd() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.applyLatestObservation() // seen playing
        fake.finishTrack()
        try await engine.applyLatestObservation()
        #expect(events.filter { $0 == .reachedEnd }.count == 1)
        #expect(!engine.isPlaying)
        // Said once.
        try await engine.applyLatestObservation()
        #expect(events.filter { $0 == .reachedEnd }.count == 1)
    }

    @Test func pausingIsNotTheEnd() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.applyLatestObservation()
        engine.pause()
        await settle()
        #expect(fake.state == .paused)
        fake.state = .stopped
        try await engine.applyLatestObservation()
        #expect(!events.contains(.reachedEnd))
    }

    @Test func skipToStaged() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        try await engine.skipToStaged()
        #expect(fake.track == 2)
        #expect(events.contains(.advancedToStaged))
    }

    /// A stage that lands as the song changes: the player is already on the staged song, so it
    /// says so and the stage is dropped (the session stages again behind the new song).
    @Test func stageRacingTheSongChange() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        fake.finishTrack()
        await #expect(throws: CancellationError.self) { try await engine.stage(spotifyTrack("c")) }
        #expect(events.contains(.advancedToStaged))
        #expect(fake.queue == [sonosURI("a"), sonosURI("b")])
    }

    @Test func anotherSourceTakesTheRoom() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.applyLatestObservation()
        #expect(engine.isPlaying)
        fake.foreignURI = "x-sonos-htastream:RINCON_MOVE:spdif"
        try await engine.applyLatestObservation()
        #expect(!engine.isPlaying)
        #expect(events.last == .statusChanged)
        #expect(!events.contains(.reachedEnd))
        // Pausing now leaves the other source alone.
        let before = fake.changes.count
        engine.pause()
        await settle()
        #expect(fake.changes.count == before)
        // Play takes the room back with our song.
        fake.foreignURI = nil
        try await engine.resume()
        #expect(fake.changes.suffix(6).map(\.action) == ["RemoveAllTracksFromQueue", "AddURIToQueue", "SetAVTransportURI", "SetPlayMode", "Seek", "Play"])
    }

    /// It looked like another source took the room, but the group is on our song after all: a
    /// pause (the music moving to another output) still stops it.
    @Test func pauseStopsOurSongAfterAMisreadTakeover() async throws {
        try await engine.play(spotifyTrack("a"))
        try await engine.applyLatestObservation()
        fake.foreignURI = "x-sonos-htastream:RINCON_MOVE:spdif"
        try await engine.applyLatestObservation()
        fake.foreignURI = nil
        engine.pause()
        await settle()
        #expect(fake.changes.last?.action == "Pause")
        #expect(fake.state == .paused)
    }

    @Test func nothingIsSentBeforeItHasPlayed() async {
        engine.pause()
        engine.seek(to: 30)
        engine.setCrossfade(enabled: true, duration: nil)
        await settle()
        #expect(fake.requests.isEmpty)
    }

    @Test func crossfadeIsSetWhenPlaybackStarts() async throws {
        engine.setCrossfade(enabled: true, duration: 6)
        try await engine.play(spotifyTrack("a"))
        let crossfade = try #require(fake.requests.first { $0.action == "SetCrossfadeMode" })
        #expect(crossfade.argument("CrossfadeMode") == "1")
    }

    @Test func seekSendsRelativeTime() async throws {
        try await engine.play(spotifyTrack("a"))
        engine.seek(to: 75.4)
        await settle()
        let seek = try #require(fake.changes.last)
        #expect(seek.argument("Unit") == "REL_TIME")
        #expect(seek.argument("Target") == "0:01:15")
    }

    @Test func unplayableTracksFailBeforeAnythingIsSent() async {
        await #expect(throws: SonosTrackReference.Failure.self) { try await engine.play(QueueTrack(id: "spotify:episode:x", title: "x", artist: "y")) }
        #expect(fake.requests.isEmpty)
    }

    @Test func groupingRoomsOnFirstPlay() async throws {
        let target = SonosTarget(coordinator: .init(id: "RINCON_MOVE", name: "Sonos Move", host: "10.0.1.224"),
                                 joining: [.init(id: "RINCON_BEAM", name: "Bedroom", host: "10.0.1.161")], leavesGroup: true)
        let grouped = SonosEngine(target: target, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        try await grouped.play(spotifyTrack("a"))
        #expect(fake.actions.prefix(2) == ["BecomeCoordinatorOfStandaloneGroup", "SetAVTransportURI"])
        #expect(fake.requests[1].host == "10.0.1.161")
        #expect(fake.requests[1].argument("CurrentURI") == "x-rincon:RINCON_MOVE")
        try await grouped.play(spotifyTrack("b"))
        #expect(fake.actions.filter { $0 == "BecomeCoordinatorOfStandaloneGroup" }.count == 1)
        #expect(target.name == "Sonos Move + Bedroom")
    }
}

@MainActor
final class EventRecorder {
    var events: [PlaybackEvent] = []
}

/// The rules on their own: what each reading means.
struct SonosPlaybackRulesTests {
    typealias O = SonosPlaybackRules.Observation
    typealias C = SonosPlaybackRules.Context
    let a = "spotify:track:a", b = "spotify:track:b"

    @Test func onOurSong() {
        let c = C(currentID: a, currentNumber: 1, stagedID: b, stagedNumber: 2, sawPlaying: true)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .playing), c) == .nothing)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .transitioning), c) == .nothing)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .paused), c) == .nothing)
    }

    @Test func onTheStagedSong() {
        let c = C(currentID: a, currentNumber: 1, stagedID: b, stagedNumber: 2)
        #expect(SonosPlaybackRules.step(O(trackNumber: 2, trackID: b, state: .playing), c) == .advancedToStaged)
        // Same song staged twice in a row: only its queue position tells.
        let same = C(currentID: a, currentNumber: 1, stagedID: a, stagedNumber: 2, sawPlaying: true)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .playing), same) == .nothing)
        #expect(SonosPlaybackRules.step(O(trackNumber: 2, trackID: a, state: .playing), same) == .advancedToStaged)
    }

    @Test func stoppedAfterPlaying() {
        let c = C(currentID: a, currentNumber: 3, sawPlaying: true)
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: a, state: .stopped), c) == .reachedEnd)
        // Back at the top of the queue, stopped: the queue ran out.
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: "spotify:track:old", state: .stopped), c) == .reachedEnd)
        // Not before it was seen playing (the moment after a play), not when we paused it, not twice.
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: a, state: .stopped), C(currentID: a, currentNumber: 3)) == .nothing)
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: a, state: .stopped), C(currentID: a, currentNumber: 3, pausedByUs: true, sawPlaying: true)) == .nothing)
        #expect(SonosPlaybackRules.step(O(trackNumber: 3, trackID: a, state: .stopped), C(currentID: a, currentNumber: 3, reportedEnd: true, sawPlaying: true)) == .nothing)
    }

    @Test func somewhereElseInTheQueue() {
        let c = C(currentID: a, currentNumber: 3, sawPlaying: true)
        // Further on (a stale entry): back to the session's queue.
        #expect(SonosPlaybackRules.step(O(trackNumber: 4, trackID: "spotify:track:stale", state: .playing), c) == .reachedEnd)
        // Earlier (the Sonos app went back) or a new queue: someone else's choice.
        #expect(SonosPlaybackRules.step(O(trackNumber: 2, trackID: "spotify:track:old", state: .playing), c) == .lostControl)
    }

    @Test func anotherSource() {
        let c = C(currentID: a, currentNumber: 1, sawPlaying: true)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: nil, state: .playing), c) == .lostControl)
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: nil, state: .paused), c) == .nothing)
        // Between songs, no track for a moment: not someone else yet.
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: nil, state: .transitioning), c) == .nothing)
    }

    @Test func nothingOfOursYet() {
        #expect(SonosPlaybackRules.step(O(trackNumber: 1, trackID: a, state: .stopped), C(currentID: nil, currentNumber: nil)) == .nothing)
    }

    @Test func observationFromPositionInfo() throws {
        let info = SonosParse.positionInfo(try SonosFixture.soap("position_info_queue"))
        let o = O(info, state: .paused)
        #expect(o.trackNumber == 1)
        #expect(o.trackID == "spotify:track:3eXYltBvZSCOs6fM1La6ho")
        #expect(o.duration == 158)
    }
}

/// The engine under a real `PartySession`: songs move on through the Sonos queue.
@MainActor
@Suite struct SonosSessionTests {
    @Test func partyPlaysThroughTheSonosQueue() async throws {
        let fake = FakeSonos()
        let engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        let session = PartySession(catalog: SpotifyStubCatalog(ids: ["a", "b", "c"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:a")
        #expect(fake.queue == [sonosURI("a"), sonosURI("b")])
        // Seen playing, then the song ends and Sonos moves on.
        try await engine.applyLatestObservation()
        fake.finishTrack()
        try await engine.applyLatestObservation()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:b")
        #expect(fake.queue == [sonosURI("a"), sonosURI("b"), sonosURI("c")])
        // Skip goes to the staged song on Sonos.
        await session.skip()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:c")
        #expect(fake.track == 3)
        // The base playlist comes round again: "a" is staged behind "c" and plays next.
        #expect(fake.queue == [sonosURI("a"), sonosURI("b"), sonosURI("c"), sonosURI("a")])
        fake.finishTrack()
        try await engine.applyLatestObservation()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:a")
        #expect(fake.track == 4)
    }

    /// The Sonos queue runs out under the session (its staged song was removed in the Sonos
    /// app, say): the session plays its next song itself.
    @Test func queueRunningOutPlaysTheNextSong() async throws {
        let fake = FakeSonos()
        let engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        let session = PartySession(catalog: SpotifyStubCatalog(ids: ["a", "b"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        try await engine.applyLatestObservation()
        fake.queue.removeLast()
        fake.finishTrack()
        try await engine.applyLatestObservation()
        await settle()
        #expect(session.state.current?.track.id == "spotify:track:b")
        #expect(fake.queue.first == sonosURI("b"))
        #expect(fake.state == .playing)
    }

    @Test func aSonosErrorFailsPlay() async throws {
        let fake = FakeSonos()
        fake.failing["AddURIToQueue"] = 804
        let engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .spotify, accountSerial: 4), transport: fake)
        let session = PartySession(catalog: SpotifyStubCatalog(ids: ["a"]), engine: engine)
        try await session.load(playlist: base)
        await #expect(throws: SonosError.upnp(action: "AddURIToQueue", code: 804)) { try await session.play() }
    }
}

struct SpotifyStubCatalog: MusicCatalog {
    var ids: [String]
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { ids.map(spotifyTrack) }
}
