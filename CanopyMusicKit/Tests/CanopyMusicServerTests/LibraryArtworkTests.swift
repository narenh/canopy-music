@testable import CanopyMusicCore
@testable import CanopyMusicServer
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Art for songs only in the hub's library, which pretends to load it with MusicKit.
actor FakeLibraryArtwork: LibraryArtworkSource {
    private(set) var asked: [String] = []
    /// The art's size: bigger than any size served, so each is scaled down.
    let side: Int

    init(side: Int = 1600) {
        self.side = side
    }

    func artwork(libraryID: String, size: Int) async throws -> Data? {
        asked.append("\(libraryID)@\(size)")
        guard libraryID != "i.NoArt" else { return nil }
        return Self.png(side: side)
    }

    static func png(side: Int) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// The demo catalog with library art (or none), and a library-only song in its playlist.
struct LibraryArtworkCatalog: MusicCatalog {
    let artwork: FakeLibraryArtwork?
    let demo = DemoCatalog()
    static let upload = QueueTrack.libraryOnly(libraryID: "i.bVl4FRZ1zY", title: "Chip the Glasses", artist: "Glenn Yarbrough", duration: 20)

    var libraryArtwork: (any LibraryArtworkSource)? { artwork }
    func searchSongs(_ term: String) async throws -> [QueueTrack] { try await demo.searchSongs(term) }
    func libraryPlaylists() async throws -> [PlaylistSummary] { try await demo.libraryPlaylists() }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [Self.upload] + DemoCatalog.allTracks.prefix(5) }
}

@MainActor
@Suite(.serialized)
struct LibraryArtworkTests {
    func get(_ url: String) async throws -> (status: Int, type: String?, data: Data) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type"), data)
    }

    func pixelWidth(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    @Test func relaysScaledAndCached() async throws {
        let artwork = FakeLibraryArtwork()
        let hub = PartySession(catalog: LibraryArtworkCatalog(artwork: artwork), engine: DemoPlaybackEngine())
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18861]))
        defer { task.cancel(); Task { await server.stop() } }
        let base = "http://127.0.0.1:18861/api/artwork"

        let thumbnail = try await get("\(base)/i.bVl4FRZ1zY?size=160")
        #expect(thumbnail.status == 200)
        #expect(thumbnail.type == "image/jpeg")
        #expect(pixelWidth(thumbnail.data) == 160)
        // Asked again (another row, another phone): from the relay's cache.
        let again = try await get("\(base)/i.bVl4FRZ1zY?size=160")
        #expect(again.data == thumbnail.data)
        // An odd size gets the next one up; none gets the largest.
        #expect(pixelWidth(try await get("\(base)/i.bVl4FRZ1zY?size=500").data) == 600)
        #expect(pixelWidth(try await get("\(base)/i.bVl4FRZ1zY").data) == 1200)
        #expect(await artwork.asked == ["i.bVl4FRZ1zY@160", "i.bVl4FRZ1zY@600", "i.bVl4FRZ1zY@1200"])
    }

    @Test func neverScaledUp() async throws {
        let hub = PartySession(catalog: LibraryArtworkCatalog(artwork: FakeLibraryArtwork(side: 400)), engine: DemoPlaybackEngine())
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18862]))
        defer { task.cancel(); Task { await server.stop() } }
        #expect(pixelWidth(try await get("http://127.0.0.1:18862/api/artwork/i.Small1?size=1200").data) == 400)
    }

    @Test func missingArt() async throws {
        let artwork = FakeLibraryArtwork()
        let hub = PartySession(catalog: LibraryArtworkCatalog(artwork: artwork), engine: DemoPlaybackEngine())
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18863]))
        defer { task.cancel(); Task { await server.stop() } }
        let base = "http://127.0.0.1:18863/api/artwork"

        // None to be had: 404, and not asked for again straight away.
        #expect(try await get("\(base)/i.NoArt?size=160").status == 404)
        #expect(try await get("\(base)/i.NoArt?size=160").status == 404)
        // Not a library id: never asked.
        #expect(try await get("\(base)/1440857781?size=160").status == 404)
        #expect(try await get("\(base)/i.abc%2F..?size=160").status == 404)
        #expect(await artwork.asked == ["i.NoArt@160"])

        // A service without library songs (Spotify) has nothing to relay.
        let other = PartySession(catalog: LibraryArtworkCatalog(artwork: nil), engine: DemoPlaybackEngine())
        let (otherServer, otherTask) = try #require(await PartyServer.start(session: other, ports: [18864]))
        defer { otherTask.cancel(); Task { await otherServer.stop() } }
        #expect(try await get("http://127.0.0.1:18864/api/artwork/i.bVl4FRZ1zY?size=160").status == 404)
    }

    /// The page gets the relay's path as it is; a display loads it from its zone's hub.
    @Test func displaysLoadItFromTheirHub() async throws {
        let hub = PartySession(catalog: LibraryArtworkCatalog(artwork: FakeLibraryArtwork()), engine: DemoPlaybackEngine())
        try await hub.load(playlist: PlaylistSummary(id: "mixed", name: "Mixed", kind: .library))
        try await hub.play()
        _ = hub.add(LibraryArtworkCatalog.upload, by: Requester(name: "Sam", clientID: "phone-1", origin: .phone))
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18865]))
        defer { task.cancel(); Task { await server.stop() } }

        let state = try await get("http://127.0.0.1:18865/api/state").data
        let snapshot = try JSONDecoder.api.decode(PartySnapshot.self, from: state)
        #expect(snapshot.current?.track.artworkURL?.relativeString == "/api/artwork/i.bVl4FRZ1zY?size=1200")

        let connection = ZoneConnection(baseURL: URL(string: "http://127.0.0.1:18865")!, clientID: "kitchen", name: "Kitchen iPad", kind: .ipad)
        let display = PartySession(remote: connection)
        connection.start(session: display)
        defer { connection.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !connection.hasSnapshot, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let current = try #require(display.state.current?.track)
        #expect(current.libraryID == "i.bVl4FRZ1zY")
        #expect(current.artworkURL?.absoluteString == "http://127.0.0.1:18865/api/artwork/i.bVl4FRZ1zY?size=1200")
        #expect(current.thumbnailURL?.absoluteString == "http://127.0.0.1:18865/api/artwork/i.bVl4FRZ1zY?size=160")
        // And the image is there.
        #expect(try await get(current.thumbnailURL!.absoluteString).status == 200)
        // Catalog songs keep their own art (the demo's have none).
        #expect(display.state.upNext.allSatisfy { $0.track.libraryID != nil || $0.track.artworkURL == nil })
    }
}
