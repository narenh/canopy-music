import Foundation
import Testing
@testable import CanopyMusicCore

/// One side of a `LinkHandoffEngine` (Apple Music's player, or the link player), recording what
/// it was asked to do.
@MainActor
final class FakeSide: HandoffSide {
    let canReplaceStaged = true
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playing: QueueTrack?
    var staged: QueueTrack?
    var prepared: QueueTrack?
    var endsIntoHandoff = false
    var unplayable: Set<String> = []
    var crossfade: Bool?
    /// Every call, in order: "play a", "stage nil", "prepare L", "handOff", "pause"…
    var calls: [String] = []

    func play(_ track: QueueTrack) async throws {
        calls.append("play \(track.id)\(prepared?.id == track.id ? " (prepared)" : "")")
        prepared = nil
        if unplayable.contains(track.id) { throw URLError(.resourceUnavailable) }
        playing = track
        staged = nil
        isPlaying = true
        currentTime = 0
    }

    func stage(_ track: QueueTrack?) async throws {
        calls.append("stage \(track?.id ?? "nil")")
        staged = track
    }

    func resume() async throws {
        calls.append("resume")
        isPlaying = true
    }

    func pause() {
        calls.append("pause")
        isPlaying = false
    }

    func skipToStaged() async throws {
        calls.append("skipToStaged")
        guard staged != nil else { throw CancellationError() }
        finishTrack()
    }

    func restartCurrent() { currentTime = 0 }
    func seek(to time: TimeInterval) { currentTime = time }
    func setCrossfade(enabled: Bool, duration: TimeInterval?) { crossfade = enabled }

    func prepare(_ track: QueueTrack?) async throws {
        calls.append("prepare \(track?.id ?? "nil")")
        prepared = track
    }

    func handOff() {
        calls.append("handOff")
        isPlaying = false
        playing = nil
        staged = nil
    }

    func setEndsIntoHandoff(_ value: Bool) { endsIntoHandoff = value }

    /// The song plays to its end: on to the staged one, or the end.
    func finishTrack() {
        if let next = staged {
            playing = next
            staged = nil
            currentTime = 0
            onEvent?(.advancedToStaged)
        } else {
            playing = nil
            isPlaying = false
            onEvent?(.reachedEnd)
        }
    }
}

/// Apple Music and links on one device (`LinkHandoffEngine`): which side plays what, staging
/// within and across sides, the handoffs, and the session's rules (staging, end detection,
/// failed songs, rapid skips) across both kinds.
@MainActor
@Suite struct LinkHandoffEngineTests {
    static func link(_ id: String, ready: Bool = true) -> QueueTrack {
        var track = QueueTrack(id: QueueTrack.linkID(id), title: id, artist: "Artist", duration: 200)
        track.link = LinkTrack(id: id, service: "YouTube", status: ready ? .ready : .pending,
                               audioURL: URL(string: "https://cmdlp.example/audio/\(id).m4a?sig=s"))
        return track
    }

    func engine() -> (LinkHandoffEngine, music: FakeSide, links: FakeSide, events: () -> [PlaybackEvent]) {
        let music = FakeSide(), links = FakeSide()
        let engine = LinkHandoffEngine(music: music, links: links)
        final class Events { var list: [PlaybackEvent] = [] }
        let events = Events()
        engine.onEvent = { events.list.append($0) }
        return (engine, music, links, { events.list })
    }

    // MARK: The engine alone

    @Test func eachKindPlaysOnItsSide() async throws {
        let (engine, music, links, _) = engine()
        #expect(engine.canPlayLinks)
        try await engine.play(longSong("a"))
        #expect(music.playing?.id == "a")
        #expect(engine.active == .music)
        #expect(engine.isPlaying)
        try await engine.play(Self.link("L"))
        #expect(music.calls.last == "handOff")
        #expect(links.playing?.id == "link:L")
        #expect(engine.active == .link)
        links.currentTime = 42
        #expect(engine.currentTime == 42)
        try await engine.play(longSong("b"))
        #expect(links.calls.last == "handOff")
        #expect(music.playing?.id == "b")
    }

    /// The next song on the same side is lined up there; on the other side, this one runs out
    /// and the other gets it ready.
    @Test func stagingWithinAndAcrossSides() async throws {
        let (engine, music, links, _) = engine()
        try await engine.play(longSong("a"))
        try await engine.stage(longSong("b"))
        #expect(music.staged?.id == "b")
        try await engine.stage(Self.link("L"))
        #expect(music.staged == nil)
        #expect(music.endsIntoHandoff)
        #expect(links.prepared?.id == "link:L")
        #expect(links.playing == nil)
        // Back to an Apple Music song next: the prepared link goes.
        try await engine.stage(longSong("c"))
        #expect(links.prepared == nil)
        #expect(!music.endsIntoHandoff)
        #expect(music.staged?.id == "c")
        // Nothing next.
        try await engine.stage(nil)
        #expect(music.staged == nil)
    }

    /// A link still downloading can't be got ready: staging it throws (the session tries again
    /// as the download moves on), and the song playing still runs out.
    @Test func aLinkStillDownloadingCantBeStaged() async throws {
        let (engine, music, links, _) = engine()
        try await engine.play(longSong("a"))
        try await engine.stage(longSong("b"))
        await #expect(throws: LinkPlaybackError.notReady) { try await engine.stage(Self.link("L", ready: false)) }
        #expect(music.staged == nil)
        #expect(music.endsIntoHandoff)
        #expect(links.prepared == nil)
        try await engine.stage(Self.link("L"))
        #expect(links.prepared?.id == "link:L")
    }

    /// The song after a link is got ready in Apple Music's player while the link plays, and its
    /// play then uses it.
    @Test func appleMusicGetsReadyDuringALink() async throws {
        let (engine, music, links, _) = engine()
        try await engine.play(Self.link("L"))
        try await engine.stage(longSong("b"))
        #expect(music.prepared?.id == "b")
        #expect(links.endsIntoHandoff)
        links.finishTrack()
        try await engine.play(longSong("b"))
        #expect(links.calls.suffix(1) == ["handOff"])
        #expect(music.calls.last == "play b (prepared)")
    }

    /// Only the side playing speaks for the engine.
    @Test func theIdleSidesEventsAreIgnored() async throws {
        let (engine, music, links, events) = engine()
        try await engine.play(longSong("a"))
        links.onEvent?(.reachedEnd)
        links.onEvent?(.statusChanged)
        #expect(events().isEmpty)
        music.onEvent?(.statusChanged)
        #expect(events() == [.statusChanged])
        music.finishTrack()
        #expect(events() == [.statusChanged, .reachedEnd])
    }

    @Test func skippingToTheStagedSongOnlyWithinASide() async throws {
        let (engine, music, _, events) = engine()
        try await engine.play(longSong("a"))
        try await engine.stage(longSong("b"))
        try await engine.skipToStaged()
        #expect(music.playing?.id == "b")
        #expect(events() == [.advancedToStaged])
        try await engine.stage(Self.link("L"))
        await #expect(throws: CancellationError.self) { try await engine.skipToStaged() }
    }

    /// With links on, an Apple Music song is lined up only near the end of the one before, so a
    /// link queued in the meantime takes its place cleanly.
    @Test func appleMusicSongsAreLinedUpLateOnceLinksAreOn() async throws {
        let (engine, music, links, _) = engine()
        engine.linksEnabled = { true }
        engine.musicStageLead = 0.5
        try await engine.play(longSong("a").withDuration(1))
        try await engine.stage(longSong("b"))
        #expect(music.staged == nil)
        #expect(!music.calls.contains("stage b"))
        // A link queued meanwhile: nothing of "b" to take back.
        try await engine.stage(Self.link("L"))
        try await engine.stage(longSong("b"))
        #expect(links.prepared == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(music.staged == nil)
        music.currentTime = 0.6
        // The hold's next look (it waited out the 0.5 s it had left).
        try await Task.sleep(for: .milliseconds(600))
        await settle()
        #expect(music.staged?.id == "b")
        #expect(music.calls.filter { $0 == "stage b" }.count == 1)
        // Off: lined up at once, as Apple Music's engine alone does.
        let (plain, plainMusic, _, _) = self.engine()
        try await plain.play(longSong("a"))
        try await plain.stage(longSong("b"))
        #expect(plainMusic.staged?.id == "b")
    }

    @Test func crossfadeIsAppleMusicsOnly() {
        let (engine, music, links, _) = engine()
        engine.setCrossfade(enabled: true, duration: 6)
        #expect(music.crossfade == true)
        #expect(links.crossfade == true) // and the link player ignores it
    }

    // MARK: With the session

    func session(_ ids: [String]) async throws -> (PartySession, LinkHandoffEngine, music: FakeSide, links: FakeSide) {
        let (engine, music, links, _) = engine()
        let session = PartySession(catalog: StubCatalog(ids: ids), engine: engine)
        session.landingDelay = 0.05
        try await session.load(playlist: base)
        return (session, engine, music, links)
    }

    func add(_ track: QueueTrack, to session: PartySession) async {
        session.add(track, by: Requester(name: "Sam", clientID: "phone-1", origin: .phone))
        await settle()
    }

    /// Apple Music → link → Apple Music: each song starts as the one before ends, the next song
    /// is got ready on the other side meanwhile, and the queue and party log follow.
    @Test func aLinkBetweenAppleMusicSongs() async throws {
        let (session, engine, music, links) = try await session(["a", "b"])
        try await session.play()
        await settle()
        #expect(music.staged?.id == "b")
        await add(Self.link("L"), to: session)
        #expect(session.state.upNext.first?.track.id == "link:L")
        #expect(music.staged == nil)
        #expect(links.prepared?.id == "link:L")

        music.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "link:L")
        #expect(links.calls.contains("play link:L (prepared)"))
        #expect(engine.active == .link)
        #expect(session.isPlaying)
        #expect(music.prepared?.id == "b")
        #expect(links.endsIntoHandoff)

        links.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "b")
        #expect(music.calls.last?.hasPrefix("play b (prepared)") == true || music.calls.contains("play b (prepared)"))
        #expect(links.calls.last == "handOff")
        #expect(engine.active == .music)
        #expect(session.partyLog.songs.map(\.track.id) == ["a", "link:L", "b"])
    }

    /// Two links in a row follow each other on the link side, gaplessly.
    @Test func linkAfterLinkStaysOnTheLinkSide() async throws {
        let (session, engine, music, links) = try await session(["a"])
        await add(Self.link("L1"), to: session)
        await add(Self.link("L2"), to: session)
        try await session.play()
        await settle()
        #expect(session.state.current?.track.id == "link:L1")
        #expect(links.staged?.id == "link:L2")
        links.finishTrack()
        await settle()
        #expect(session.state.current?.track.id == "link:L2")
        #expect(engine.active == .link)
        #expect(!music.calls.contains("handOff") || music.playing == nil)
        #expect(music.prepared?.id == "a")
    }

    /// A link that won't play (its audio gone) is skipped like any song that can't play, and
    /// the next Apple Music song plays.
    @Test func aLinkThatWontPlayIsSkipped() async throws {
        let (session, _, music, links) = try await session(["a", "b", "c"])
        links.unplayable = ["link:L"]
        try await session.play()
        await add(Self.link("L"), to: session)
        music.finishTrack()
        await settle()
        #expect(links.calls.contains("play link:L (prepared)"))
        #expect(session.state.current?.track.id == "b")
        #expect(music.playing?.id == "b")
        #expect(session.playerIssue == "Skipped “L”, which couldn't play")
    }

    /// Quick skips across both kinds: the player hears only the song they land on.
    @Test func rapidSkipsAcrossKindsLandOnce() async throws {
        let (session, engine, music, links) = try await session(["a", "b", "c", "d"])
        try await session.play()
        await add(Self.link("L"), to: session)
        let musicPlays = music.calls.filter { $0.hasPrefix("play") }.count
        async let first: Void = session.skip()
        async let second: Void = session.skip()
        async let third: Void = session.skip()
        _ = await (first, second, third)
        await settle()
        #expect(session.state.current?.track.id == "c")
        #expect(!links.calls.contains { $0.hasPrefix("play") })
        #expect(music.calls.filter { $0.hasPrefix("play") }.count == musicPlays + 1)
        #expect(music.playing?.id == "c")
        #expect(engine.active == .music)
    }

    /// A skip from an Apple Music song onto a link it had ready.
    @Test func aSkipOntoALink() async throws {
        let (session, engine, music, links) = try await session(["a", "b"])
        try await session.play()
        await add(Self.link("L"), to: session)
        await session.skip()
        await settle()
        #expect(session.state.current?.track.id == "link:L")
        #expect(engine.active == .link)
        #expect(music.calls.contains("handOff"))
        #expect(links.calls.contains("play link:L (prepared)"))
    }
}

private extension QueueTrack {
    func withDuration(_ seconds: TimeInterval) -> QueueTrack {
        var track = self
        track.duration = seconds
        return track
    }
}
