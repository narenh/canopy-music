import Foundation
import Testing
@testable import CanopyMusicCore

/// The sample responses follow the shape a public project reads (`attributes.editorialVideo
/// .motionDetailSquare.video`, an `.m3u8`, next to `motionDetailTall.video`), not a response
/// captured by this app.
@Suite struct MotionArtworkTests {
    static let squareURL = "https://mvod.itunes.apple.com/itunes-assets/HLSMusic/square/P1_Default.m3u8"
    static let otherSquareURL = "https://mvod.itunes.apple.com/itunes-assets/HLSMusic/square1x1/P2_Default.m3u8"
    static let tallURL = "https://mvod.itunes.apple.com/itunes-assets/HLSMusic/tall/P3_Default.m3u8"

    static func entry(_ url: String) -> String {
        """
        {"previewFrame": {"url": "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.{f}", "width": 3840, "height": 3840},
         "video": "\(url)"}
        """
    }

    static func album(editorialVideo: String?) -> Data {
        let extra = editorialVideo.map { ", \"editorialVideo\": \($0)" } ?? ""
        return Data("""
        {"data": [{"id": "1440833098", "type": "albums", "href": "/v1/catalog/us/albums/1440833098",
          "attributes": {"name": "An Album", "artistName": "Someone"\(extra)}}]}
        """.utf8)
    }

    static let song = Data("""
    {"data": [{"id": "1440833101", "type": "songs", "attributes": {"name": "A Song"},
      "relationships": {"albums": {"href": "/v1/catalog/us/songs/1440833101/albums",
        "data": [{"id": "1440833098", "type": "albums", "attributes": {"name": "An Album"}}]}}}]}
    """.utf8)

    /// `editorialVideo` as it's expected to come back: a square and a tall motion video.
    static let editorialVideo = """
    {"motionDetailSquare": \(entry(squareURL)), "motionDetailTall": \(entry(tallURL))}
    """

    @Test func readsTheSquareVideo() {
        #expect(MotionArtwork.preferredSquareKeys.first == "motionDetailSquare")
        let data = Self.album(editorialVideo: Self.editorialVideo)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: data)?.absoluteString == Self.squareURL)
    }

    @Test func picksMotionDetailSquareFirst() {
        let data = Self.album(editorialVideo: """
        {"motionDetailTall": \(Self.entry(Self.tallURL)),
         "motionSquareVideo1x1": \(Self.entry(Self.otherSquareURL)),
         "motionDetailSquare": \(Self.entry(Self.squareURL))}
        """)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: data)?.absoluteString == Self.squareURL)
    }

    @Test func fallsBackToOtherSquareShapes() {
        let oneByOne = Self.album(editorialVideo: """
        {"motionDetailTall": \(Self.entry(Self.tallURL)), "motionSquareVideo1x1": \(Self.entry(Self.otherSquareURL))}
        """)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: oneByOne)?.absoluteString == Self.otherSquareURL)

        let unknownSquare = Self.album(editorialVideo: """
        {"motionTallVideo3x4": \(Self.entry(Self.tallURL)), "motionSomethingSquare": \(Self.entry(Self.squareURL))}
        """)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: unknownSquare)?.absoluteString == Self.squareURL)
    }

    @Test func skipsEntriesWithoutAUsableVideo() {
        let data = Self.album(editorialVideo: """
        {"motionDetailSquare": {"previewFrame": {"url": "x"}}, "motionSquareVideo1x1": \(Self.entry(Self.otherSquareURL))}
        """)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: data)?.absoluteString == Self.otherSquareURL)
    }

    @Test func noSquareVideoMeansNil() {
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Self.album(editorialVideo: nil)) == nil)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Self.album(editorialVideo: """
        {"motionDetailTall": \(Self.entry(Self.tallURL))}
        """)) == nil)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Self.album(editorialVideo: "{}")) == nil)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Data("not json".utf8)) == nil)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Data(#"{"data": []}"#.utf8)) == nil)
        #expect(MotionArtwork.squareVideoURL(inAlbumResponse: Self.album(editorialVideo: """
        {"motionDetailSquare": {"video": "not a url"}}
        """)) == nil)
    }

    @Test func findsTheSongsAlbum() {
        #expect(MotionArtwork.albumID(inSongResponse: Self.song) == "1440833098")
        #expect(MotionArtwork.albumID(inSongResponse: Data(#"{"data": [{"id": "1", "type": "songs"}]}"#.utf8)) == nil)
    }

    @Test func albumRequestQuery() {
        #expect(MotionArtwork.albumPath("1440833098") == "albums/1440833098?extend=editorialVideo")
        let web = MotionArtwork.AlbumQuery(extend: "editorialVideo", platform: "web")
        #expect(MotionArtwork.albumPath("1440833098", query: web) == "albums/1440833098?extend=editorialVideo&platform=web")
        let none = MotionArtwork.AlbumQuery(extend: "", platform: nil)
        #expect(MotionArtwork.albumPath("1440833098", query: none) == "albums/1440833098")
    }

    @Test func albumQueryOverrides() {
        let base = MotionArtwork.AlbumQuery(extend: "editorialVideo", platform: "web")
        #expect(base.overriding(extend: nil, platform: nil) == base)
        #expect(base.overriding(extend: "editorialVideo,editorialArtwork", platform: "ios")
                == MotionArtwork.AlbumQuery(extend: "editorialVideo,editorialArtwork", platform: "ios"))
        #expect(MotionArtwork.albumPath("1", query: base.overriding(extend: nil, platform: "")) == "albums/1?extend=editorialVideo")
    }

    @Test func onlyCatalogIDsCount() {
        #expect(MotionArtwork.isCatalogID("1440833101"))
        #expect(!MotionArtwork.isCatalogID("i.ZYxbqJ8UxAB1"))
        #expect(!MotionArtwork.isCatalogID(""))
        #expect(!MotionArtwork.isCatalogID("6rqhFgbbKwnb9MLmUQDhG6"))
    }

    // MARK: Lookup

    actor Requests {
        var paths: [String] = []
        func note(_ path: String) { paths.append(path) }
    }

    struct Offline: Error {}

    @Test func looksUpTheAlbumOnceAndRemembersIt() async {
        let requests = Requests()
        let album = Self.album(editorialVideo: Self.editorialVideo)
        let lookup = MotionArtworkLookup { path in
            await requests.note(path)
            return path.hasPrefix("songs/") ? Self.song : album
        }
        #expect(await lookup.videoURL(forSongID: "1440833101")?.absoluteString == Self.squareURL)
        #expect(await lookup.videoURL(forSongID: "1440833101")?.absoluteString == Self.squareURL)
        #expect(await requests.paths == ["songs/1440833101?include=albums", "albums/1440833098?extend=editorialVideo"])
    }

    @Test func remembersAlbumsWithoutMotionArtwork() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup { path in
            await requests.note(path)
            return path.hasPrefix("songs/") ? Self.song : Self.album(editorialVideo: nil)
        }
        #expect(await lookup.videoURL(forSongID: "1440833101") == nil)
        #expect(await lookup.videoURL(forSongID: "1440833101") == nil)
        #expect(await requests.paths.count == 2)
    }

    @Test func libraryOnlySongsAreNotLookedUp() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup { path in
            await requests.note(path)
            return Data()
        }
        #expect(await lookup.videoURL(forSongID: "i.ZYxbqJ8UxAB1") == nil)
        #expect(await requests.paths.isEmpty)
    }

    @Test func failuresAreNotRemembered() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup(fetch: { path in
            await requests.note(path)
            throw Offline()
        })
        #expect(await lookup.videoURL(forSongID: "1440833101") == nil)
        #expect(await lookup.videoURL(forSongID: "1440833101") == nil)
        #expect(await requests.paths.count == 2)
    }

    @Test func probeReportsTheRawResponses() async throws {
        let album = Self.album(editorialVideo: Self.editorialVideo)
        let lookup = MotionArtworkLookup { path in path.hasPrefix("songs/") ? Self.song : album }
        let data = try await lookup.probe(albumID: nil, songID: "1440833101")
        let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["songAlbumID"] as? String == "1440833098")
        #expect(report["albumID"] as? String == "1440833098")
        #expect(report["albumRequest"] as? String == "albums/1440833098?extend=editorialVideo")
        #expect(report["editorialVideoKeys"] as? [String] == ["motionDetailSquare", "motionDetailTall"])
        #expect(report["pickedSquareURL"] as? String == Self.squareURL)
        #expect(report["albumResponse"] is [String: Any])
    }

    @Test func probeTriesQueryVariantsAndShowsTheURL() async throws {
        let base = "https://api.music.apple.com/v1/catalog/us/"
        let lookup = MotionArtworkLookup(fetchReportingURL: { path in
            (path.hasPrefix("songs/") ? Self.song : Self.album(editorialVideo: nil), base + path)
        })
        let query = MotionArtwork.albumQuery.overriding(extend: nil, platform: "web")
        let data = try await lookup.probe(albumID: "1440833098", songID: nil, albumQuery: query)
        let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["albumURL"] as? String == base + "albums/1440833098?extend=editorialVideo&platform=web")
        #expect(report["editorialVideoKeys"] is NSNull)
        #expect(report["songURL"] == nil)
    }

    @Test func probeReportsFailedRequests() async throws {
        let url = "https://api.music.apple.com/v1/catalog/us/albums/1?platform=bogus"
        let lookup = MotionArtworkLookup(fetchReportingURL: { _ in
            throw MotionArtworkLookup.RequestError(url: url, description: "status 400")
        })
        let data = try await lookup.probe(albumID: "1", songID: nil)
        let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["albumURL"] as? String == url)
        #expect(report["albumError"] as? String == "status 400")
    }
}

#if DEBUG
/// The third-party service motion artwork asks (debug builds), with a fake loader: no real requests.
@Suite struct MotionArtworkServiceTests {
    static let square = "https://mvod.itunes.apple.com/itunes-assets/HLSVideo/x/P1_default.m3u8"
    static let found = Data(#"{"url": "\#(square)", "url_tall": "https://mvod.itunes.apple.com/y.m3u8", "artist": "ILLENIUM", "album": "ODYSSEY", "isCached": true}"#.utf8)
    static let missing = Data(#"{"message": "No animated artwork found."}"#.utf8)

    actor Requests {
        var urls: [URL] = []
        func note(_ url: URL) { urls.append(url) }
    }

    static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    static func track(artist: String, album: String) -> QueueTrack {
        QueueTrack(id: "1", title: "Forever", artist: artist, album: album, duration: 200, artworkURL: nil, thumbnailURL: nil, colors: nil, isExplicit: false)
    }

    @Test func answers() {
        #expect(MotionArtworkService.answer(data: Self.found, status: 200) == .found(URL(string: Self.square)!))
        #expect(MotionArtworkService.answer(data: Self.missing, status: 404) == .none)
        #expect(MotionArtworkService.answer(data: Data(), status: 500) == .unexpected(status: 500))
    }

    @Test func requestNames() throws {
        let url = try #require(MotionArtworkService.searchURL(artist: "Simon & Garfunkel", album: "Bookends + 1 - Single"))
        #expect(url.absoluteString.hasPrefix("https://artwork.m8tec.top/api/v1/artwork/search?"))
        #expect(Self.query(url) == ["artist": "Simon & Garfunkel", "album": "Bookends + 1"])
        #expect(MotionArtworkService.albumTitle("ODYSSEY - EP") == "ODYSSEY")
        #expect(MotionArtworkService.albumTitle("ODYSSEY") == "ODYSSEY")
        #expect(MotionArtworkService.artistCandidates("ILLENIUM, Tom Grennan & Alna") == ["ILLENIUM, Tom Grennan & Alna", "ILLENIUM"])
        #expect(MotionArtworkService.artistCandidates("ILLENIUM") == ["ILLENIUM"])
    }

    /// Only the service is asked (never the Apple Music API): the whole artist, then the first
    /// artist; the answer is remembered.
    @Test func asksOnlyTheServiceAndRemembers() async {
        let requests = Requests()
        let apple = Requests()
        let lookup = MotionArtworkLookup(fetch: { path in
            await apple.note(URL(string: "https://example.com/\(path)")!)
            return Data()
        }, serviceLoad: { url in
            await requests.note(url)
            return Self.query(url)["artist"] == "ILLENIUM" ? (Self.found, 200) : (Self.missing, 404)
        })
        let track = Self.track(artist: "ILLENIUM, Tom Grennan & Alna", album: "ODYSSEY")
        #expect(await lookup.videoURL(for: track) == URL(string: Self.square))
        #expect(await lookup.videoURL(for: track) == URL(string: Self.square))
        #expect(await requests.urls.count == 2)
        #expect(await apple.urls.isEmpty)
    }

    // MARK: Album link

    static func answer(artist: String, album: String) -> Data {
        Data(#"{"url": "\#(square)", "url_tall": null, "artist": "\#(artist)", "album": "\#(album)", "isCached": true}"#.utf8)
    }

    @Test func albumLinks() throws {
        #expect(MotionArtworkService.albumLink(albumID: "1440833098", storefront: "gb") == "https://music.apple.com/gb/album/1440833098")
        #expect(MotionArtworkService.albumLink(albumID: "1440833098", storefront: "GB") == "https://music.apple.com/gb/album/1440833098")
        #expect(MotionArtworkService.albumLink(albumID: "1440833098", storefront: nil) == "https://music.apple.com/us/album/1440833098")
        #expect(MotionArtworkService.albumLink(albumID: "1440833098", storefront: "") == "https://music.apple.com/us/album/1440833098")
        #expect(MotionArtworkService.albumLink(albumID: "1440833098", storefront: "usa") == "https://music.apple.com/us/album/1440833098")
        let url = try #require(MotionArtworkService.albumLinkURL("https://music.apple.com/gb/album/1440833098"))
        #expect(url.absoluteString == "https://artwork.m8tec.top/api/v1/artwork/url?url=https://music.apple.com/gb/album/1440833098")
        #expect(Self.query(url) == ["url": "https://music.apple.com/gb/album/1440833098"])
    }

    @Test func onlyCatalogAlbumIDsAreUsed() {
        #expect(MotionArtworkService.usableAlbumID("1440833098") == "1440833098")
        #expect(MotionArtworkService.usableAlbumID(nil) == nil)
        #expect(MotionArtworkService.usableAlbumID("") == nil)
        #expect(MotionArtworkService.usableAlbumID("l.abc123") == nil)
    }

    // MARK: Name guard

    static func matches(_ theirs: (String, String), _ ours: (String, String)) -> Bool {
        MotionArtworkService.namesMatch(.init(artist: theirs.0, album: theirs.1), artist: ours.0, album: ours.1)
    }

    @Test func guardAcceptsTheSameAlbum() {
        #expect(Self.matches(("ILLENIUM", "ODYSSEY"), ("ILLENIUM", "ODYSSEY")))
        #expect(Self.matches(("illenium", "Odyssey"), ("ILLENIUM", "ODYSSEY")))
        #expect(Self.matches(("Simon & Garfunkel", "Bookends"), ("Simon  &  Garfunkel", "Bookends")))
        #expect(Self.matches(("Taylor Swift", "Fearless (Taylor’s Version)"), ("Taylor Swift", "Fearless (Taylor's Version)")))
        #expect(Self.matches(("Ed Sheeran", "÷"), ("Ed Sheeran", "÷")))
    }

    @Test func guardRejectsOtherAlbumsAndArtists() {
        #expect(!Self.matches(("ILLENIUM", "ODYSSEY (Deluxe)"), ("ILLENIUM", "ODYSSEY")))
        #expect(!Self.matches(("ILLENIUM", "ODYSSEY"), ("ILLENIUM", "ODYSSEY (Deluxe)")))
        #expect(!Self.matches(("Someone Else", "ODYSSEY"), ("ILLENIUM", "ODYSSEY")))
        #expect(!Self.matches(("Ed Sheeran", "×"), ("Ed Sheeran", "÷")))
        #expect(!MotionArtworkService.namesMatch(.init(artist: nil, album: "ODYSSEY"), artist: "ILLENIUM", album: "ODYSSEY"))
        #expect(!MotionArtworkService.namesMatch(.init(artist: "ILLENIUM", album: nil), artist: "ILLENIUM", album: "ODYSSEY"))
    }

    @Test func guardIgnoresSingleAndEPSuffixes() {
        #expect(Self.matches(("Gryffin", "Forever"), ("Gryffin", "Forever - Single")))
        #expect(Self.matches(("Gryffin", "Forever - Single"), ("Gryffin", "Forever")))
        #expect(Self.matches(("Gryffin", "Forever - EP"), ("Gryffin", "Forever - Single")))
        #expect(MotionArtworkService.albumTitle("Forever - single") == "Forever")
    }

    @Test func guardTakesTheWholeArtistOrTheFirst() {
        let ours = ("ILLENIUM, Tom Grennan & Alna", "ODYSSEY")
        #expect(Self.matches(("ILLENIUM", "ODYSSEY"), ours))
        #expect(Self.matches(("ILLENIUM, Tom Grennan & Alna", "ODYSSEY"), ours))
        #expect(!Self.matches(("Tom Grennan", "ODYSSEY"), ours))
        #expect(Self.matches(("Calvin Harris", "Funk Wav Bounces, Vol. 1"), ("Calvin Harris feat. Frank Ocean", "Funk Wav Bounces Vol.1")))
        #expect(!Self.matches(("Frank Ocean", "Funk Wav Bounces Vol. 1"), ("Calvin Harris feat. Frank Ocean", "Funk Wav Bounces Vol. 1")))
    }

    @Test func guardFoldsDiacriticsAndPunctuation() {
        #expect(Self.matches(("Sigur Ros", "Takk…"), ("Sigur Rós", "Takk...")))
        #expect(Self.matches(("BEYONCÉ", "I AM...SASHA FIERCE"), ("Beyoncé", "I Am... Sasha Fierce")))
        #expect(Self.matches(("Röyksopp", "Melody A.M."), ("Royksopp", "Melody A. M.")))
        #expect(MotionArtworkService.normalized("  Hoppípolla — (Live!)  ") == "hoppipolla live")
    }

    // MARK: Which way the lookup asks

    @Test func asksByAlbumLinkWhenTheTrackHasAnAlbumID() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup(fetch: { _ in Data() }, storefront: { "gb" }, serviceLoad: { url in
            await requests.note(url)
            // The exact album's answer is taken whatever its names.
            return (Self.answer(artist: "ILLENIUM", album: "ODYSSEY (Deluxe)"), 200)
        })
        var track = Self.track(artist: "ILLENIUM", album: "ODYSSEY")
        track.albumID = "1440833098"
        #expect(await lookup.videoURL(for: track) == URL(string: Self.square))
        #expect(await lookup.videoURL(for: track) == URL(string: Self.square))
        let urls = await requests.urls
        #expect(urls.count == 1)
        #expect(urls.first?.path == "/api/v1/artwork/url")
        #expect(urls.first.map(Self.query) == ["url": "https://music.apple.com/gb/album/1440833098"])
    }

    @Test func albumLinkWithoutArtworkIsRememberedAndDoesNotSearch() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup(fetch: { _ in Data() }, serviceLoad: { url in
            await requests.note(url)
            return (Self.missing, 404)
        })
        var track = Self.track(artist: "ILLENIUM", album: "ODYSSEY")
        track.albumID = "1440833098"
        #expect(await lookup.videoURL(for: track) == nil)
        #expect(await lookup.videoURL(for: track) == nil)
        let urls = await requests.urls
        #expect(urls.count == 1)
        #expect(urls.first.map(Self.query) == ["url": "https://music.apple.com/us/album/1440833098"])
    }

    @Test func searchesByNameWithoutACatalogAlbumID() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup(fetch: { _ in Data() }, serviceLoad: { url in
            await requests.note(url)
            return (Self.answer(artist: "ILLENIUM", album: "ODYSSEY"), 200)
        })
        var track = Self.track(artist: "ILLENIUM", album: "ODYSSEY")
        track.albumID = "l.libraryAlbum"
        #expect(await lookup.videoURL(for: track) == URL(string: Self.square))
        let urls = await requests.urls
        #expect(urls.map(\.path) == ["/api/v1/artwork/search"])
        #expect(urls.first.map(Self.query) == ["artist": "ILLENIUM", "album": "ODYSSEY"])
    }

    @Test func searchAnswerForAnotherAlbumCountsAsNoneAndIsRemembered() async {
        let requests = Requests()
        let lookup = MotionArtworkLookup(fetch: { _ in Data() }, serviceLoad: { url in
            await requests.note(url)
            return (Self.answer(artist: "ILLENIUM", album: "ODYSSEY (Deluxe)"), 200)
        })
        let track = Self.track(artist: "ILLENIUM, Tom Grennan & Alna", album: "ODYSSEY")
        #expect(await lookup.videoURL(for: track) == nil)
        #expect(await lookup.videoURL(for: track) == nil)
        // Both artist candidates were tried once, then the "none" was remembered.
        #expect(await requests.urls.count == 2)
    }

    @Test func probeShowsThePathURLResponseAndVerdict() async throws {
        let lookup = MotionArtworkLookup(fetch: { _ in Data() }, storefront: { "us" }, serviceLoad: { url in
            url.path.hasSuffix("/url") ? (Self.answer(artist: "ILLENIUM", album: "ODYSSEY"), 200)
                : (Self.answer(artist: "Someone Else", album: "ODYSSEY"), 200)
        })
        var track = Self.track(artist: "ILLENIUM", album: "ODYSSEY")
        track.albumID = "1440833098"
        let linkedData = try await lookup.probeService(track: track)
        let linked = try #require(try JSONSerialization.jsonObject(with: linkedData) as? [String: Any])
        #expect(linked["path"] as? String == "albumLink")
        #expect(linked["albumLink"] as? String == "https://music.apple.com/us/album/1440833098")
        #expect(linked["pickedSquareURL"] as? String == Self.square)
        let linkRequest = try #require((linked["requests"] as? [[String: Any]])?.first)
        #expect(linkRequest["url"] as? String == "https://artwork.m8tec.top/api/v1/artwork/url?url=https://music.apple.com/us/album/1440833098")
        #expect(linkRequest["status"] as? Int == 200)
        #expect((linkRequest["response"] as? [String: Any])?["album"] as? String == "ODYSSEY")
        #expect((linkRequest["verdict"] as? String)?.hasPrefix("accepted") == true)

        track.albumID = nil
        let searchedData = try await lookup.probeService(track: track)
        let searched = try #require(try JSONSerialization.jsonObject(with: searchedData) as? [String: Any])
        #expect(searched["path"] as? String == "search")
        #expect(searched["albumLink"] == nil)
        #expect(searched["pickedSquareURL"] is NSNull)
        let searchRequest = try #require((searched["requests"] as? [[String: Any]])?.first)
        #expect((searchRequest["url"] as? String)?.hasPrefix("https://artwork.m8tec.top/api/v1/artwork/search?") == true)
        #expect((searchRequest["verdict"] as? String)?.hasPrefix("rejected") == true)
    }
}
#endif

@Suite struct SongLinkAlbumTests {
    @Test func readsTheAlbumIDFromASongLink() {
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://music.apple.com/us/album/forever/1440833098?i=1440833101")) == "1440833098")
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://music.apple.com/gb/album/1440833098")) == "1440833098")
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://music.apple.com/album/1989-taylors-version/1708308989?i=1")) == "1708308989")
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://music.apple.com/us/song/forever/1440833101")) == nil)
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://example.com/us/album/forever/1440833098")) == nil)
        #expect(MotionArtwork.albumID(inSongURL: URL(string: "https://music.apple.com/us/album/forever")) == nil)
        #expect(MotionArtwork.albumID(inSongURL: nil) == nil)
    }
}
