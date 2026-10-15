import Foundation
import Testing
@testable import CanopyMusicCore

/// Library-only Apple Music songs through the Sonos engine: queued in the Sonos app's form, and
/// still ours once Sonos rewrites them in its queue (`.unknown` → `.mp4`, flags 0 → 8232).
@MainActor
@Suite struct SonosLibraryTrackTests {
    let fake = FakeSonos()
    let engine: SonosEngine
    let recorder = EventRecorder()

    init() {
        engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: .appleMusic, accountSerial: 3), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600)) // tests poll by hand
        let recorder = recorder
        engine.onEvent = { recorder.events.append($0) }
    }

    func upload(_ id: String) -> QueueTrack {
        .libraryOnly(libraryID: "i.\(id)", title: id, artist: "Artist", duration: 20)
    }

    func queued(_ id: String) -> String { "x-sonos-http:librarytrack%3ai.\(id).unknown?sid=204&flags=0&sn=3" }
    func rewritten(_ id: String) -> String { "x-sonos-http:librarytrack%3ai.\(id).mp4?sid=204&flags=8232&sn=3" }

    @Test func playsAndStagesInTheSonosAppsForm() async throws {
        try await engine.play(upload("Aa1"))
        #expect(fake.queue == [queued("Aa1")])
        let add = try #require(fake.changes.first { $0.action == "AddURIToQueue" })
        #expect(add.argument("EnqueuedURIMetaData")?.contains("10032020librarytrack%3ai.Aa1") == true)
        // A library song and a catalog song mix in one queue.
        try await engine.stage(QueueTrack(id: "1440857781", title: "Catalog", artist: "Artist"))
        #expect(fake.queue == [queued("Aa1"), "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8224&sn=3"])
        try await engine.stage(upload("Bb2"))
        #expect(fake.queue == [queued("Aa1"), queued("Bb2")])
    }

    /// Sonos's rewrite must not read as another source taking the room, nor lose the staged song.
    @Test func rewrittenURIsStayOurs() async throws {
        try await engine.play(upload("Aa1"))
        try await engine.stage(upload("Bb2"))
        fake.queue = [rewritten("Aa1"), rewritten("Bb2")]
        try await engine.applyLatestObservation()
        #expect(engine.isPlaying)
        #expect(!recorder.events.contains(.reachedEnd))
        fake.finishTrack()
        let advanced = try await engine.applyLatestObservation()
        #expect(advanced)
        #expect(recorder.events.contains(.advancedToStaged))
        #expect(!recorder.events.contains(.reachedEnd))
        // The next stage goes after the rewritten current song.
        try await engine.stage(upload("Cc3"))
        #expect(fake.queue == [rewritten("Aa1"), rewritten("Bb2"), queued("Cc3")])
    }

    @Test func endOfARewrittenSong() async throws {
        try await engine.play(upload("Aa1"))
        fake.queue = [rewritten("Aa1")]
        try await engine.applyLatestObservation()
        fake.finishTrack()
        try await engine.applyLatestObservation()
        #expect(recorder.events.filter { $0 == .reachedEnd }.count == 1)
    }
}
