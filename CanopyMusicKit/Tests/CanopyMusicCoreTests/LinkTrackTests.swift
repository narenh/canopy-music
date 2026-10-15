import Foundation
import Testing
@testable import CanopyMusicCore

/// A song from a link (`QueueTrack.link`, `Links.swift`): how it's coded, shown, counted as the
/// same song, and kept in the queue.
@Suite struct LinkTrackTests {
    /// A track as cmdlp answers `GET /tracks/{id}` mid-download (openapi.yaml's fields).
    static let pendingJSON = Data(#"""
    {"id": "M9xQFZLlR5L-VkfG3YQQLp", "zone": "living-room", "status": "pending", "title": "Flickermood",
     "artist": "Forss", "duration": 213.886, "artwork": "https://i1.sndcdn.com/artworks-000-t500x500.jpg",
     "source": "Soundcloud", "service": "SoundCloud", "stage": "downloading",
     "progress": {"percent": 42.7, "downloadedBytes": 1835008, "totalBytes": null, "totalBytesEstimate": null, "speed": 1000, "eta": 3},
     "webpageUrl": "https://soundcloud.com/forss/flickermood", "url": "https://soundcloud.com/forss/flickermood",
     "audioUrl": "https://cmdlp.example.com/audio/M9xQFZLlR5L-VkfG3YQQLp.m4a?sig=k82Gxp4VBgSbf1T", "createdAt": "2026-10-14T20:00:00Z"}
    """#.utf8)

    static func link(_ id: String = "M9xQFZLlR5L-VkfG3YQQLp", status: LinkTrack.Status = .ready, percent: Double? = nil) -> QueueTrack {
        var track = QueueTrack(id: QueueTrack.linkID(id), title: "Flickermood", artist: "Forss", duration: 214)
        track.link = LinkTrack(id: id, service: "SoundCloud", status: status, stage: status == .pending ? "downloading" : nil, percent: percent,
                               audioURL: URL(string: "https://cmdlp.example.com/audio/\(id).m4a?sig=secret"))
        return track
    }

    // MARK: cmdlp's JSON

    @Test func readsCmdlpsTrack() throws {
        let found = try JSONDecoder().decode(CmdlpTrack.self, from: Self.pendingJSON)
        #expect(found.status == .pending)
        let track = found.queueTrack
        #expect(track.id == "link:M9xQFZLlR5L-VkfG3YQQLp")
        #expect(track.title == "Flickermood")
        #expect(track.artist == "Forss")
        #expect(track.duration == 213.886)
        #expect(track.artworkURL?.absoluteString == "https://i1.sndcdn.com/artworks-000-t500x500.jpg")
        #expect(track.thumbnailURL == track.artworkURL)
        #expect(track.link?.service == "SoundCloud")
        #expect(track.link?.stage == "downloading")
        // Whole percents: each change is a snapshot to every phone.
        #expect(track.link?.percent == 42)
        #expect(track.link?.audioURL?.query() == "sig=k82Gxp4VBgSbf1T")
        #expect(track.link?.isPlayable == false)
    }

    /// No title or artist (cmdlp sends null): still a row that reads sensibly.
    @Test func fillsInWhatCmdlpLeavesOut() throws {
        let found = CmdlpTrack(id: "AAAAAAAAAAAAAAAAAAAAAA", status: .ready, title: nil, artist: "  ", service: "YouTube",
                               audioUrl: "https://cmdlp.example.com/audio/AAAAAAAAAAAAAAAAAAAAAA.m4a?sig=x")
        #expect(found.queueTrack.title == "Untitled")
        #expect(found.queueTrack.artist == "YouTube")
        #expect(found.queueTrack.link?.isPlayable == true)
        #expect(found.queueTrack.artworkURL == nil)
    }

    @Test func aStatusCmdlpAddsLaterReadsAsPending() throws {
        let json = Data(#"{"id": "A", "status": "paused_by_admin", "audioUrl": "https://x.example/a"}"#.utf8)
        #expect(try JSONDecoder().decode(CmdlpTrack.self, from: json).status == .pending)
    }

    // MARK: Coding in the queue

    @Test func roundTrips() throws {
        let track = Self.link(status: .pending, percent: 40)
        #expect(try JSONDecoder().decode(QueueTrack.self, from: JSONEncoder().encode(track)) == track)
    }

    /// Saved queues and older peers' payloads, without `link`, decode as before.
    @Test func oldPayloadsStillDecode() throws {
        let track = try JSONDecoder().decode(QueueTrack.self, from: QueueTrackCodingTests.withoutAlbumID)
        #expect(track.link == nil)
        let state = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(QueueState()))
        #expect(state.current == nil)
    }

    /// No `link` key for other songs, so their JSON is as before.
    @Test func leavesOutAMissingLink() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(QueueTrack(id: "1", title: "T", artist: "A"))) as? [String: Any]
        #expect(json?["link"] == nil)
    }

    /// An older display ignores `link` and shows the song as any other.
    @Test func olderDisplaysShowItAsASong() throws {
        struct OldQueueTrack: Decodable {
            var id: String
            var title: String
            var artist: String
            var album: String
            var isExplicit: Bool
            var duration: TimeInterval?
            var artworkURL: URL?
        }
        let old = try JSONDecoder().decode(OldQueueTrack.self, from: JSONEncoder().encode(Self.link()))
        #expect(old.title == "Flickermood")
        #expect(old.artist == "Forss")
        #expect(old.duration == 214)
    }

    // MARK: Guests

    @Test func guestsDontGetTheAudioAddress() throws {
        let track = Self.link()
        #expect(track.forGuests.link?.audioURL == nil)
        #expect(track.forGuests.link?.id == track.link?.id)
        #expect(track.forGuests.title == track.title)
        let text = String(decoding: try JSONEncoder().encode(QueueItem(track: track, requester: nil).forGuests), as: UTF8.self)
        #expect(!text.contains("sig="))
        // Other songs are left as they are.
        let song = QueueTrack(id: "1", title: "T", artist: "A")
        #expect(song.forGuests == song)
    }

    @Test func rowsSayHowFarTheDownloadHasGot() {
        #expect(Self.link(status: .pending, percent: 40).rowSubtitle == "Downloading 40% · Forss")
        var track = Self.link(status: .pending)
        #expect(track.rowSubtitle == "Downloading · Forss")
        track.link?.stage = "queued"
        #expect(track.rowSubtitle == "Waiting to download · Forss")
        track.link?.stage = "converting"
        #expect(track.rowSubtitle == "Converting · Forss")
        track.artist = ""
        #expect(track.rowSubtitle == "Converting")
        #expect(Self.link().rowSubtitle == "Forss")
        #expect(QueueTrack(id: "1", title: "T", artist: "A").rowSubtitle == "A")
    }

    // MARK: Telling a link from a search

    @Test func recognisesALink() {
        #expect(LinkURL.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ") != nil)
        #expect(LinkURL.parse("  https://soundcloud.com/forss/flickermood\n") != nil)
        #expect(LinkURL.parse("http://youtu.be/dQw4w9WgXcQ") != nil)
        #expect(LinkURL.parse("HTTPS://archive.org/details/x") != nil)
        #expect(LinkURL.parse("fleetwood mac dreams") == nil)
        #expect(LinkURL.parse("youtube.com/watch?v=x") == nil)
        #expect(LinkURL.parse("https://youtube.com/watch?v=x and more") == nil)
        #expect(LinkURL.parse("ftp://example.com/song.mp3") == nil)
        #expect(LinkURL.parse("https://localhost/x") == nil)
        #expect(LinkURL.parse("https:") == nil)
    }

    @Test func cmdlpAddresses() {
        #expect(CmdlpClient.baseURL(" https://cmdlp.example.com/ ")?.absoluteString == "https://cmdlp.example.com")
        #expect(CmdlpClient.baseURL("http://127.0.0.1:3002")?.absoluteString == "http://127.0.0.1:3002")
        #expect(CmdlpClient.baseURL("cmdlp.example.com") == nil)
        #expect(CmdlpClient.baseURL("") == nil)
        #expect(LinkTokenHint.of("cmdlp_abcdefgh1234") == "1234")
        #expect(LinkTokenHint.of(nil) == nil)
        #expect(LinkZone.isValid(LinkZone.make()))
        #expect(LinkZone.isValid(LinkZone.make(prefix: "Living Room iPad!")))
        #expect(LinkZone.make() != LinkZone.make())
        #expect(!LinkZone.isValid("a zone"))
    }

    /// What a phone is told when cmdlp refuses: its own sentence where the guest can act on it,
    /// plain words otherwise (never yt-dlp's raw message, nor anything about the token).
    @Test func refusalsArePlainSentences() {
        let playlist = CmdlpError(status: 422, reason: "playlist", message: "That's a playlist, not one track.")
        #expect(LinkRefusal(resolving: playlist).message == "That's a playlist, not one track.")
        for reason in ["unsupported_link", "live", "blocked"] {
            #expect(LinkRefusal(resolving: CmdlpError(status: 422, reason: reason, message: "cmdlp says \(reason)")).message == "cmdlp says \(reason)")
        }
        #expect(LinkRefusal(resolving: CmdlpError(status: 502, reason: "lookup_failed", message: "ERROR: [youtube] x: Private video")).message
                == "Couldn't find a song at that link. It may be private or removed.")
        #expect(LinkRefusal(resolving: CmdlpError(status: 401, reason: "unauthorized", message: "No bearer token.")) == .unavailable)
        #expect(LinkRefusal(resolving: URLError(.timedOut)) == .unavailable)
        #expect(LinkRefusal(resolving: LinkRefusal.notHere) == .notHere)
    }
}

/// The queue's rules for link tracks (`QueueState`).
@Suite struct LinkQueueTests {
    let requester = Requester(name: "Sam", clientID: "phone-1", origin: .phone)

    func queue(_ ids: [String] = ["a", "b", "c"]) -> QueueState {
        var state = QueueState()
        state.load(playlist: ids.map(track), name: "Base")
        state.advance()
        return state
    }

    /// The same cmdlp id is the same song: queued once, and "playing" while it plays.
    @Test func theSameLinkIsTheSameSong() {
        var state = queue()
        guard case .added(let first, _) = state.addRequest(LinkTrackTests.link(status: .pending), by: requester) else {
            Issue.record("not added")
            return
        }
        guard case .alreadyQueued(let again, _) = state.addRequest(LinkTrackTests.link(status: .ready), by: requester) else {
            Issue.record("queued twice")
            return
        }
        #expect(again.id == first.id)
        #expect(state.upNext.filter { $0.track.link != nil }.count == 1)
        // Another link is another song.
        guard case .added = state.addRequest(LinkTrackTests.link("BBBBBBBBBBBBBBBBBBBBBB"), by: requester) else {
            Issue.record("a different link wasn't added")
            return
        }
        state.advance(to: first.id)
        let playing = state.addRequest(LinkTrackTests.link(), by: requester)
        #expect(playing == .nowPlaying)
    }

    @Test func progressReachesEveryCopy() {
        var state = queue()
        state.addRequest(LinkTrackTests.link(status: .pending, percent: 10), by: requester)
        let version = state.version
        var link = LinkTrackTests.link(status: .pending, percent: 55).link!
        let changed = state.updateLink(link)
        #expect(changed)
        #expect(state.version == version + 1)
        #expect(state.upNext.first { $0.track.link != nil }?.track.link?.percent == 55)
        // The same again changes nothing, so nothing is sent.
        let again = state.updateLink(link)
        #expect(!again)
        #expect(state.version == version + 1)
        link.status = .ready
        link.percent = nil
        state.updateLink(link)
        #expect(state.upNext.first { $0.track.link != nil }?.track.link?.isPlayable == true)
    }

    /// A failed link leaves Up next, even as the locked next song.
    @Test func aFailedLinkLeavesEvenWhenLocked() {
        var state = queue()
        state.addRequest(LinkTrackTests.link(status: .pending), by: requester)
        #expect(state.upNext.first?.track.link != nil)
        state.lockNext()
        let removed = state.removeLink("M9xQFZLlR5L-VkfG3YQQLp")
        #expect(removed.count == 1)
        #expect(state.lockedNextID == nil)
        #expect(!state.upNext.contains { $0.track.link != nil })
        let none = state.removeLink("M9xQFZLlR5L-VkfG3YQQLp")
        #expect(none.isEmpty)
    }

    /// A link still downloading at its turn: the next song that isn't plays, the link right after it.
    @Test func postponingPlaysTheNextReadySong() {
        var state = QueueState()
        state.addRequest(LinkTrackTests.link(status: .pending), by: requester)
        state.addRequest(LinkTrackTests.link("BBBBBBBBBBBBBBBBBBBBBB", status: .pending), by: requester)
        state.addRequest(track("x"), by: requester)
        state.advance()
        #expect(state.current?.track.link?.id == "M9xQFZLlR5L-VkfG3YQQLp")
        let postponed = state.postponeCurrent()
        #expect(postponed)
        #expect(state.current?.track.id == "x")
        #expect(state.upNext.map(\.track.id) == ["link:M9xQFZLlR5L-VkfG3YQQLp", "link:BBBBBBBBBBBBBBBBBBBBBB"])
        #expect(state.history.isEmpty)
        // Nothing but links still downloading after it: nothing to play instead.
        state.advance()
        let postponedAgain = state.postponeCurrent()
        #expect(!postponedAgain)
        #expect(state.current?.track.link?.id == "M9xQFZLlR5L-VkfG3YQQLp")
    }

    @Test func droppingTheCurrentSongDoesntCountItAsPlayed() {
        var state = queue()
        state.addRequest(LinkTrackTests.link(status: .failed), by: requester)
        state.advance()
        let history = state.history
        let next = state.dropCurrent()
        #expect(next?.track.id == "b")
        #expect(state.history == history)
    }

    /// A link isn't the music service's to put in a saved playlist.
    @Test func savingThePartyLeavesLinksOut() {
        var log = PartyLog()
        log.record(QueueItem(track: track("a"), requester: requester))
        log.record(QueueItem(track: LinkTrackTests.link(), requester: requester))
        #expect(log.tracks(onlyRequests: false).map(\.id) == ["a"])
        #expect(log.tracks(onlyRequests: true, waiting: [QueueItem(track: LinkTrackTests.link("BBBBBBBBBBBBBBBBBBBBBB"), requester: requester)]).map(\.id) == ["a"])
    }
}
