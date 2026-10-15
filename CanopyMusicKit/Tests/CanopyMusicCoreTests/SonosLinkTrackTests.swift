import Foundation
import Testing
@testable import CanopyMusicCore

/// Songs from links on Sonos: one Sonos queue, with the link's audio as its plain https address
/// and minimal DIDL, for Apple Music and Spotify zones alike; and the engine still taking it for
/// its own song in whatever form Sonos reports it back.
@MainActor
@Suite struct SonosLinkTrackTests {
    static let id = "M9xQFZLlR5L-VkfG3YQQLp"
    static let audio = "https://cmdlp.example.com/audio/\(id).m4a?sig=k82Gxp4VBgSbf1T"

    static func link(ready: Bool = true, id: String = SonosLinkTrackTests.id) -> QueueTrack {
        var track = QueueTrack(id: QueueTrack.linkID(id), title: "Flickermood & Co", artist: "Forss", duration: 214,
                               artworkURL: URL(string: "https://i.ytimg.com/vi/x/hqdefault.jpg"))
        track.link = LinkTrack(id: id, service: "YouTube", status: ready ? .ready : .pending,
                               audioURL: URL(string: "https://cmdlp.example.com/audio/\(id).m4a?sig=k82Gxp4VBgSbf1T"))
        return track
    }

    @Test func aLinkIsItsPlainAudioAddressForEitherService() throws {
        for service in [SonosMusicService.appleMusic, .spotify] {
            let reference = SonosTrackReference(service: service, accountSerial: 3)
            #expect(try reference.uri(for: Self.link()) == Self.audio)
            let didl = try reference.metadata(for: Self.link())
            #expect(didl.contains("<dc:title>Flickermood &amp; Co</dc:title>"))
            #expect(didl.contains("<dc:creator>Forss</dc:creator>"))
            #expect(didl.contains("<upnp:albumArtURI>https://i.ytimg.com/vi/x/hqdefault.jpg</upnp:albumArtURI>"))
            #expect(didl.contains("<upnp:class>object.item.audioItem.musicTrack</upnp:class>"))
            #expect(!didl.contains("cdudn"))
        }
    }

    @Test func aLinkStillDownloadingHasNoAddressYet() {
        let reference = SonosTrackReference(service: .appleMusic, accountSerial: 3)
        #expect(throws: LinkPlaybackError.notReady) { try reference.uri(for: Self.link(ready: false)) }
    }

    /// As queued, and as Sonos may report it back: still ours.
    @Test func itsReadBackAsOursHoweverSonosWritesIt() {
        let expected = QueueTrack.linkID(Self.id)
        for uri in [
            Self.audio,
            Self.audio.replacingOccurrences(of: "&", with: "&amp;"),
            "https://cmdlp.example.com/audio/\(Self.id).m4a",
            "https://cmdlp.example.com/audio/\(Self.id)?sig=x",
            "aac://https://cmdlp.example.com/audio/\(Self.id).m4a?sig=x",
            "x-sonos-http:https%3a%2f%2fcmdlp.example.com%2faudio%2f\(Self.id).m4a%3fsig%3dx",
            "x-rincon-mp3radio://cmdlp.example.com/audio/\(Self.id).m4a?sig=x",
        ] {
            #expect(SonosURI.canopyTrackID(of: uri) == expected, "\(uri)")
        }
        for uri in [
            "https://example.com/audio/short.m4a",
            "https://example.com/audio/\(Self.id)xyz.m4a",
            "x-rincon-stream:RINCON_X",
            "https://example.com/songs/\(Self.id).m4a",
        ] {
            #expect(SonosURI.canopyTrackID(of: uri) == nil, "\(uri)")
        }
        // Other songs read as before.
        #expect(SonosURI.canopyTrackID(of: sonosURI("abc")) == "spotify:track:abc")
    }

    func engine(_ fake: FakeSonos, service: SonosMusicService = .spotify) -> (SonosEngine, EventRecorder) {
        let engine = SonosEngine(target: sonosTarget, reference: SonosTrackReference(service: service, accountSerial: 4), transport: fake)
        engine.pollInterval = (.seconds(3600), .seconds(3600))
        let recorder = EventRecorder()
        engine.onEvent = { recorder.events.append($0) }
        return (engine, recorder)
    }

    /// A link between two Spotify songs, in the same Sonos queue: no swap of player, and the
    /// engine follows it as its own.
    @Test func aLinkJoinsTheSonosQueue() async throws {
        let fake = FakeSonos()
        let (engine, recorder) = engine(fake)
        #expect(engine.canPlayLinks)
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(Self.link())
        #expect(fake.queue == [sonosURI("a"), Self.audio])
        fake.finishTrack()
        #expect(try await engine.applyLatestObservation())
        #expect(recorder.events.contains(.advancedToStaged))
        try await engine.stage(spotifyTrack("b"))
        #expect(fake.queue == [sonosURI("a"), Self.audio, sonosURI("b")])
        // Playing on the link: not someone else's music.
        _ = try await engine.applyLatestObservation()
        #expect(!engine.hasLostControl)
        fake.finishTrack()
        #expect(try await engine.applyLatestObservation())
    }

    @Test func aLinkCanBeTheSongPlayed() async throws {
        let fake = FakeSonos()
        let (engine, _) = engine(fake, service: .appleMusic)
        try await engine.play(Self.link())
        #expect(fake.queue == [Self.audio])
        fake.state = .playing
        _ = try await engine.applyLatestObservation()
        #expect(!engine.hasLostControl)
        #expect(engine.isPlaying)
    }

    /// Staging a link still downloading takes the song staged before out (the current one ends
    /// there), and throws, so the session stages the link again once it's ready.
    @Test func aLinkStillDownloadingUnstages() async throws {
        let fake = FakeSonos()
        let (engine, _) = engine(fake)
        try await engine.play(spotifyTrack("a"))
        try await engine.stage(spotifyTrack("b"))
        await #expect(throws: LinkPlaybackError.notReady) { try await engine.stage(Self.link(ready: false)) }
        #expect(fake.queue == [sonosURI("a")])
        try await engine.stage(Self.link())
        #expect(fake.queue == [sonosURI("a"), Self.audio])
    }

    /// A link Sonos refuses isn't the account's doing: the account isn't counted as rejected.
    @Test func aRefusedLinkIsntTheAccounts() async throws {
        let fake = FakeSonos()
        fake.failing["AddURIToQueue"] = 714
        let (engine, _) = engine(fake)
        final class Rejected { var count = 0 }
        let rejected = Rejected()
        engine.onAccountRejected = { _ in rejected.count += 1 }
        await #expect(throws: (any Error).self) { try await engine.play(Self.link()) }
        #expect(rejected.count == 0)
        await #expect(throws: (any Error).self) { try await engine.play(spotifyTrack("a")) }
        #expect(rejected.count == 1)
    }
}
