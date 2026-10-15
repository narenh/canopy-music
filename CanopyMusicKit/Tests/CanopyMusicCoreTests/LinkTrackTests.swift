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

    static func link(_ id: String = "M9xQFZLlR5L-VkfG3YQQLp", status: LinkTrack.Status = .ready) -> QueueTrack {
        var track = QueueTrack(id: QueueTrack.linkID(id), title: "Flickermood", artist: "Forss", duration: 214)
        track.link = LinkTrack(id: id, service: "SoundCloud", status: status,
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
        #expect(found.progress?.percent == 42.7)
        #expect(found.progress?.eta == 3)
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
        let track = Self.link()
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

    /// Queues saved while links still showed their download (`stage`, `percent`) still load.
    @Test func olderLinkFieldsAreIgnored() throws {
        let json = Data(#"{"id": "A", "service": "YouTube", "status": "ready", "stage": "converting", "percent": 40, "audioURL": "https://x.example/a.m4a"}"#.utf8)
        let link = try JSONDecoder().decode(LinkTrack.self, from: json)
        #expect(link.isPlayable)
    }

    // MARK: Preparing

    static let added = Date(timeIntervalSince1970: 1000)

    static func at(_ seconds: TimeInterval) -> Date { added.addingTimeInterval(seconds) }

    /// What cmdlp said, in turn: seconds after it was added, and its overall percent and ETA.
    static func estimate(_ notes: [(TimeInterval, Double?, Double?)]) -> LinkPrepEstimate {
        var estimate = LinkPrepEstimate()
        for (seconds, percent, eta) in notes { estimate.note(percent: percent, eta: eta, at: at(seconds)) }
        return estimate
    }

    /// "Preparing… N%" is cmdlp's overall figure (download and conversion together): whole
    /// percents, at most 99 until the link is queued, and never going back.
    @Test func thePercentageOnlyGoesUpAndStopsAt99() {
        var estimate = LinkPrepEstimate()
        estimate.note(percent: nil, eta: nil)
        #expect(estimate.percent == nil)
        estimate.note(percent: 37.8, eta: 6)
        #expect(estimate.percent == 37)
        estimate.note(percent: 64, eta: 4)
        #expect(estimate.percent == 64)
        // Never back, whatever cmdlp says next (a figure that dips, or none for a moment).
        estimate.note(percent: 50, eta: 5)
        #expect(estimate.percent == 64)
        estimate.note(percent: nil, eta: nil)
        #expect(estimate.percent == 64)
        // All done at cmdlp, but not yet queued.
        estimate.note(percent: 100, eta: 0)
        #expect(estimate.percent == 99)
        estimate.note(percent: .nan, eta: .infinity)
        #expect(estimate.percent == 99)
    }

    /// "More than 15 seconds" from when it was added: cmdlp's overall ETA when there is one,
    /// otherwise the rate between the first and latest percentages, once they're a second apart.
    @Test func estimatesWhetherPreparingTakesLong() {
        func takesLong(_ notes: [(TimeInterval, Double?, Double?)], now: TimeInterval) -> Bool {
            Self.estimate(notes).takesLong(addedAt: Self.added, now: Self.at(now))
        }
        // Nothing to go on yet.
        #expect(!LinkPrepEstimate().takesLong(addedAt: Self.added, now: Self.at(2)))
        #expect(!takesLong([(1, nil, nil)], now: 1))
        #expect(!takesLong([(1, 10, nil)], now: 1))
        // 10% a second from 10% at 1 s: done around 10 s.
        #expect(!takesLong([(1, 10, nil), (3, 30, nil)], now: 3))
        // 2% a second from 10% at 1 s: around 45 s.
        #expect(takesLong([(1, 10, nil), (3, 14, nil)], now: 3))
        // Less than a second apart: not yet a rate.
        #expect(!takesLong([(1, 10, nil), (1.5, 11, nil)], now: 1.5))
        // cmdlp's ETA wins over the rate.
        #expect(takesLong([(1, 10, nil), (3, 30, 20)], now: 3))
        #expect(!takesLong([(1, 10, nil), (3, 14, 5)], now: 3))
        // Past 15 s, it has taken long, whatever the estimate.
        #expect(takesLong([(1, 10, nil), (16, 99, 0)], now: 16))
    }

    /// The overall ETA counts the conversion still to come: an hour-long video downloaded in about
    /// 7 s and then converted for about 8, so 99% of the download is about half of the whole.
    @Test func aLongConversionCountsTowardsTheEstimate() {
        // At 7 s, half done with 8 s to go: more than 15.
        #expect(Self.estimate([(2, 14, 12), (7, 48, 8.5)]).takesLong(addedAt: Self.added, now: Self.at(7)))
        // No ETA: 6% a second since 2 s, so about 9 s more.
        #expect(Self.estimate([(2, 14, nil), (7, 44, nil)]).takesLong(addedAt: Self.added, now: Self.at(7)))
        // A short song, converted quickly: under.
        #expect(!Self.estimate([(1, 30, nil), (2, 70, 1.5)]).takesLong(addedAt: Self.added, now: Self.at(2)))
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
        guard case .added(let first, _) = state.addRequest(LinkTrackTests.link(), by: requester) else {
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

    /// A link isn't the music service's to put in a saved playlist.
    @Test func savingThePartyLeavesLinksOut() {
        var log = PartyLog()
        log.record(QueueItem(track: track("a"), requester: requester))
        log.record(QueueItem(track: LinkTrackTests.link(), requester: requester))
        #expect(log.tracks(onlyRequests: false).map(\.id) == ["a"])
        #expect(log.tracks(onlyRequests: true, waiting: [QueueItem(track: LinkTrackTests.link("BBBBBBBBBBBBBBBBBBBBBB"), requester: requester)]).map(\.id) == ["a"])
    }
}
