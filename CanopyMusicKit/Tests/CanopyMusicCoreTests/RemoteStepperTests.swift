import Foundation
import Testing
@testable import CanopyMusicCore

/// A display's connection that records what it sends, taking a moment to answer like a hub.
@MainActor
final class RecordingRemote: ZoneRemote {
    var sent: [ZoneCommand] = []
    func send(_ command: ZoneCommand) async throws {
        sent.append(command)
        try await Task.sleep(for: .milliseconds(50))
    }
    func search(_ term: String) async throws -> [QueueTrack] { [] }
    func upcoming(offset: Int, limit: Int) async throws -> UpcomingPage { .empty }
}

@MainActor
@Suite struct RemoteStepperTests {
    /// Presses while a skip or previous is still going are dropped, not queued.
    @Test func stepsGoOneAtATime() async throws {
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d"]), engine: engine)
        try await session.load(playlist: base)
        try await session.play()
        await settle()
        engine.finishTrack() // b
        await settle()
        #expect(session.state.current?.track.id == "b")
        let stepper = RemoteStepper()
        // Quick presses: right, right, left. Only the first goes.
        let right = Task { await stepper.step(session, forward: true) }
        let again = Task { await stepper.step(session, forward: true) }
        let left = Task { await stepper.step(session, forward: false) }
        #expect(await right.value)
        #expect(await !again.value)
        #expect(await !left.value)
        await settle()
        #expect(session.state.current?.track.id == "c")
        #expect(engine.playing?.id == "c")
        // Once it has moved on, the next press goes: back, as the back button does.
        #expect(!stepper.isStepping)
        #expect(await stepper.step(session, forward: false))
        #expect(session.state.current?.track.id == "b")
        #expect(engine.playing?.id == "b")
    }

    /// A display's left/right goes to its hub, one at a time, and only while the hub allows it.
    @Test func aDisplayFollowsItsHubsSetting() async throws {
        let remote = RecordingRemote()
        let display = PartySession(remote: remote)
        let stepper = RemoteStepper()
        let right = Task { await stepper.step(display, forward: true) }
        let left = Task { await stepper.step(display, forward: false) }
        #expect(await right.value)
        #expect(await !left.value)
        #expect(remote.sent == [.next])
        #expect(await stepper.step(display, forward: false))
        #expect(remote.sent == [.next, .previous])
        display.displaysCanControl = false
        #expect(await !stepper.step(display, forward: true))
        #expect(remote.sent == [.next, .previous])
    }
}
