@testable import CanopyMusicCore
@testable import CanopyMusicServer
import FlyingFox
import Foundation
import Testing

/// The WebSocket's snapshots: each page gets only what changes for it, and a snapshot every page
/// of a kind gets is encoded once.
@MainActor
@Suite struct SnapshotSocketTests {
    @MainActor
    final class Inbox {
        var texts: [String] = []
    }

    /// A page on `socket`: what it's sent, and its end of the connection (kept open).
    func connect(_ socket: SnapshotSocket) async throws -> (Inbox, AsyncStream<WSMessage>.Continuation) {
        let (client, end) = AsyncStream.makeStream(of: WSMessage.self)
        let messages = try await socket.makeMessages(for: client)
        let inbox = Inbox()
        Task { @MainActor in
            for await message in messages {
                if case .text(let text) = message { inbox.texts.append(text) }
            }
        }
        return (inbox, end)
    }

    func waitFor(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func eachPageGetsOnlyWhatChangesForIt() async throws {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        session.hostKey = "secret"
        let encoder = SnapshotEncoder()
        let (guest1, end1) = try await connect(SnapshotSocket(session: session, encoder: encoder))
        let (guest2, end2) = try await connect(SnapshotSocket(session: session, encoder: encoder))
        let (host, end3) = try await connect(SnapshotSocket(session: session, hostKey: "secret", encoder: encoder))
        defer { [end1, end2, end3].forEach { $0.finish() } }
        await waitFor { guest1.texts.count == 1 && guest2.texts.count == 1 && host.texts.count == 1 }
        #expect(guest1.texts.count == 1 && guest2.texts.count == 1 && host.texts.count == 1)

        // Only hosts see it: guests' pages aren't sent the same snapshot again.
        session.musicAccess = .ok
        await waitFor { host.texts.count == 2 }
        #expect(host.texts.count == 2)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(guest1.texts.count == 1 && guest2.texts.count == 1)

        // A change everyone sees: one encoding for both guests, one for the host.
        let before = encoder.encodes
        session.add(DemoCatalog.track(21), by: Requester(name: "Sam", clientID: "phone-1", origin: .phone))
        await waitFor { guest1.texts.count == 2 && guest2.texts.count == 2 && host.texts.count == 3 }
        #expect(guest1.texts.count == 2 && guest2.texts.count == 2 && host.texts.count == 3)
        #expect(encoder.encodes - before == 2)
        #expect(guest1.texts.last == guest2.texts.last)
        #expect(guest1.texts.last?.contains("phone-1") == true)
    }

    @Test func theSameSnapshotLaterShowsTheSame() {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        var first = session.snapshot()
        first.playback = PlaybackSnapshot(isPlaying: true, position: 10, capturedAt: Date(timeIntervalSince1970: 1000))
        var later = first
        later.playback = PlaybackSnapshot(isPlaying: true, position: 15.1, capturedAt: Date(timeIntervalSince1970: 1005))
        #expect(later.showsTheSame(as: first))
        // Off by more than a moment: sent.
        later.playback.position = 16
        #expect(!later.showsTheSame(as: first))
        // Paused where it was: the same; paused elsewhere, or playing again, isn't.
        first.playback.isPlaying = false
        later.playback = PlaybackSnapshot(isPlaying: false, position: 10, capturedAt: Date(timeIntervalSince1970: 1005))
        #expect(later.showsTheSame(as: first))
        later.playback.position = 11
        #expect(!later.showsTheSame(as: first))
        later.playback = PlaybackSnapshot(isPlaying: true, position: 10, capturedAt: Date(timeIntervalSince1970: 1005))
        #expect(!later.showsTheSame(as: first))
        // Anything else that differs is sent.
        var renamed = first
        renamed.zoneName = "Den"
        #expect(!renamed.showsTheSame(as: first))
    }

    @Test func eachSnapshotIsEncodedOncePerKind() {
        let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
        let encoder = SnapshotEncoder()
        let snapshot = session.snapshot()
        let text = encoder.text(for: snapshot, kind: "guest")
        #expect(encoder.text(for: snapshot, kind: "guest") == text)
        #expect(encoder.encodes == 1)
        #expect(encoder.text(for: snapshot, kind: "display") != nil)
        #expect(encoder.encodes == 2)
        var next = snapshot
        next.zoneName = "Den"
        #expect(encoder.text(for: next, kind: "guest") != text)
        #expect(encoder.encodes == 3)
    }
}
