@testable import CanopyMusicCore
@testable import CanopyMusicServer
import Foundation
import ImageIO
import Testing

/// Image downloads the relay makes from URL templates, answered with a square PNG after `delay`.
actor FakeDownloads {
    private(set) var urls: [String] = []
    private(set) var mostAtOnce = 0
    private var running = 0
    var fails = false
    let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func failFromNowOn() { fails = true }

    func fetch(_ url: URL) async -> Data? {
        urls.append(url.absoluteString)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        if delay > .zero { try? await Task.sleep(for: delay) }
        running -= 1
        return fails ? nil : FakeLibraryArtwork.png(side: 1600)
    }
}

@Suite struct LibraryArtworkRelayTests {
    static let albumArt = "https://art.test/album/{w}x{h}bb.jpg"

    func relay(_ downloads: FakeDownloads, disk: LibraryArtworkDiskCache? = nil) -> LibraryArtworkRelay {
        LibraryArtworkRelay(disk: disk, download: { await downloads.fetch($0) })
    }

    func pixelWidth(_ data: Data?) -> Int? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "library-artwork-\(UUID().uuidString)")
    }

    /// A song listed with its art's template is downloaded from it at the largest size, without
    /// asking the service, and each size is scaled from that one download.
    @Test func templateWithoutALookup() async throws {
        let source = FakeLibraryArtwork(hints: ["i.A": LibraryArtworkHint(template: Self.albumArt)])
        let downloads = FakeDownloads()
        let relay = relay(downloads)
        #expect(pixelWidth(await relay.image(libraryID: "i.A", size: 160, from: source)) == 160)
        #expect(pixelWidth(await relay.image(libraryID: "i.A", size: 1200, from: source)) == 1200)
        #expect(pixelWidth(await relay.image(libraryID: "i.A", size: 300, from: source)) == 300)
        #expect(await downloads.urls == ["https://art.test/album/1200x1200bb.jpg"])
        #expect(await source.asked.isEmpty)
    }

    /// An album's songs with the same art share one download and one copy.
    @Test func anAlbumSharesItsImage() async throws {
        let hint = LibraryArtworkHint(template: Self.albumArt)
        let source = FakeLibraryArtwork(hints: ["i.A": hint, "i.B": hint, "i.C": hint])
        let downloads = FakeDownloads(delay: .milliseconds(50))
        let relay = relay(downloads)
        async let a = relay.image(libraryID: "i.A", size: 160, from: source)
        async let b = relay.image(libraryID: "i.B", size: 160, from: source)
        let c = await relay.image(libraryID: "i.C", size: 1200, from: source)
        let (first, second) = await (a, b)
        #expect(first != nil && first == second)
        #expect(pixelWidth(c) == 1200)
        #expect(await downloads.urls.count == 1)
    }

    /// However many sizes and pages ask for a song at once, it's looked up once.
    @Test func oneLookupForEveryoneAsking() async throws {
        let source = FakeLibraryArtwork(delay: .milliseconds(100))
        let relay = relay(FakeDownloads())
        let images = await withTaskGroup(of: Data?.self) { group in
            for size in [160, 160, 300, 1200, 1200, 600] {
                group.addTask { await relay.image(libraryID: "i.Busy", size: size, from: source) }
            }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(images.allSatisfy { $0 != nil })
        #expect(await source.asked == ["i.Busy@1200"])
    }

    /// A template that fails falls back to the service's lookup; a song without art of its own
    /// gets its album's.
    @Test func fallbacks() async throws {
        let source = FakeLibraryArtwork(
            hints: ["i.Broken": LibraryArtworkHint(template: "https://art.test/broken/{w}x{h}.jpg"),
                    "i.Bare": LibraryArtworkHint(albumTemplate: Self.albumArt)],
            without: ["i.Bare"]
        )
        let downloads = FakeDownloads()
        let relay = relay(downloads)
        await downloads.failFromNowOn()
        #expect(pixelWidth(await relay.image(libraryID: "i.Broken", size: 160, from: source)) == 160)
        #expect(await source.asked == ["i.Broken@1200"])
        // The album's art (it fails too, here) is tried only once the song's own lookup found none.
        #expect(await relay.image(libraryID: "i.Bare", size: 160, from: source) == nil)
        #expect(await source.asked == ["i.Broken@1200", "i.Bare@1200"])
        #expect(await downloads.urls == ["https://art.test/broken/1200x1200.jpg", "https://art.test/album/1200x1200bb.jpg"])

        let working = FakeDownloads()
        let fresh = self.relay(working)
        #expect(pixelWidth(await fresh.image(libraryID: "i.Bare", size: 160, from: source)) == 160)
        #expect(await working.urls == ["https://art.test/album/1200x1200bb.jpg"])
    }

    /// The hints give a song without art its album's: another song's of the same title and
    /// artist, ignoring case and punctuation.
    @Test func hintsLendAnAlbumsArt() async throws {
        let hints = LibraryArtworkHints(url: nil)
        await hints.record([
            .init(libraryID: "i.Bare", template: nil, album: "Spring Awakening (Tour, SF)", artist: "The Cast"),
            .init(libraryID: "i.Art", template: Self.albumArt, album: "spring awakening: tour SF", artist: "the cast"),
            .init(libraryID: "i.Alone", template: nil, album: "Bootlegs", artist: "The Cast"),
        ])
        #expect(await hints.hint(for: "i.Art") == LibraryArtworkHint(template: Self.albumArt))
        #expect(await hints.hint(for: "i.Bare") == LibraryArtworkHint(albumTemplate: Self.albumArt))
        #expect(await hints.hint(for: "i.Alone") == LibraryArtworkHint())
        #expect(await hints.hint(for: "i.Unlisted") == nil)
    }

    @Test func hintsAreKeptAcrossLaunches() async throws {
        let url = temporaryDirectory().appending(path: "hints.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hints = LibraryArtworkHints(url: url)
        await hints.record([.init(libraryID: "i.Art", template: Self.albumArt, album: "A", artist: "B"),
                            .init(libraryID: "i.Bare", template: nil, album: "A", artist: "B")])
        await hints.save()
        let relaunched = LibraryArtworkHints(url: url)
        #expect(await relaunched.hint(for: "i.Art") == LibraryArtworkHint(template: Self.albumArt))
        #expect(await relaunched.hint(for: "i.Bare") == LibraryArtworkHint(albumTemplate: Self.albumArt))
    }

    /// After a relaunch the art comes from disk, with no download and no lookup.
    @Test func diskCacheSurvivesARelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FakeLibraryArtwork(hints: ["i.A": LibraryArtworkHint(template: Self.albumArt)])
        let downloads = FakeDownloads()
        let first = relay(downloads, disk: LibraryArtworkDiskCache(directory: directory))
        let original = await first.image(libraryID: "i.A", size: 1200, from: source)
        #expect(original != nil)
        // A song found by the service's lookup is kept too.
        #expect(await first.image(libraryID: "i.Lookup", size: 160, from: source) != nil)

        let offline = FakeDownloads()
        await offline.failFromNowOn()
        let lookups = FakeLibraryArtwork(hints: ["i.A": LibraryArtworkHint(template: Self.albumArt)], without: ["i.Lookup"])
        let relaunched = relay(offline, disk: LibraryArtworkDiskCache(directory: directory))
        #expect(await relaunched.image(libraryID: "i.A", size: 1200, from: lookups) == original)
        #expect(pixelWidth(await relaunched.image(libraryID: "i.A", size: 160, from: lookups)) == 160)
        #expect(pixelWidth(await relaunched.image(libraryID: "i.Lookup", size: 160, from: lookups)) == 160)
        #expect(await offline.urls.isEmpty)
        #expect(await lookups.asked.isEmpty)
    }

    /// Past its budget, the disk cache drops what was used longest ago.
    @Test func diskCacheEvictsTheLeastRecentlyUsed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LibraryArtworkDiskCache(directory: directory, budgetBytes: 2500)
        let kilobyte = Data(repeating: 7, count: 1000)
        await disk.store(kilobyte, for: "a")
        try await Task.sleep(for: .milliseconds(20))
        await disk.store(kilobyte, for: "b")
        try await Task.sleep(for: .milliseconds(20))
        #expect(await disk.data(for: "a") == kilobyte)  // "a" is now the most recently used
        try await Task.sleep(for: .milliseconds(20))
        await disk.store(kilobyte, for: "c")
        #expect(await disk.data(for: "b") == nil)
        #expect(await disk.data(for: "a") == kilobyte)
        #expect(await disk.data(for: "c") == kilobyte)
        #expect(await disk.totalBytes == 2000)
        // A new instance (a relaunch) reads what's there, and keeps to the budget: "c" was used last.
        let relaunched = LibraryArtworkDiskCache(directory: directory, budgetBytes: 1500)
        #expect(await relaunched.totalBytes == 1000)
        #expect(await relaunched.data(for: "a") == nil)
        #expect(await relaunched.data(for: "c") == kilobyte)
    }

    /// `warm` loads the songs given, a few at a time, at the sizes the views ask for.
    @Test func warmingLoadsAheadAFewAtATime() async throws {
        let ids = (1...8).map { "i.Song\($0)" }
        let source = FakeLibraryArtwork(hints: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, LibraryArtworkHint(template: "https://art.test/\($0)/{w}x{h}.jpg"))
        }))
        let downloads = FakeDownloads(delay: .milliseconds(30))
        let relay = relay(downloads)
        await relay.warm(ids, from: source)
        let deadline = Date().addingTimeInterval(5)
        while await relay.isWarming, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        for id in ids {
            #expect(pixelWidth(await relay.cachedImage(libraryID: id, size: 1200)) == 1200)
            #expect(pixelWidth(await relay.cachedImage(libraryID: id, size: 160)) == 160)
        }
        #expect(await downloads.urls.count == ids.count)
        #expect(await downloads.mostAtOnce <= LibraryArtworkRelay.warmConcurrency)
        // The same songs again (the next snapshot) start nothing.
        await relay.warm(ids, from: source)
        #expect(!(await relay.isWarming))
        #expect(await downloads.urls.count == ids.count)
    }
}

/// The hub warms the art of the song playing and the next ones as the queue changes.
@MainActor
@Suite(.serialized)
struct LibraryArtworkWarmingTests {
    @Test func aLoadedPlaylistsArtIsLoadedAhead() async throws {
        let artwork = FakeLibraryArtwork()
        let hub = PartySession(catalog: LibraryArtworkCatalog(artwork: artwork), engine: DemoPlaybackEngine())
        let (server, task) = try #require(await PartyServer.start(session: hub, ports: [18867]))
        defer { task.cancel(); Task { await server.stop() } }
        try await hub.load(playlist: PlaylistSummary(id: "mixed", name: "Mixed", kind: .library))
        // Nobody has asked for it, and it's been looked up.
        let deadline = Date().addingTimeInterval(5)
        while await artwork.asked.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await artwork.asked == ["\(LibraryArtworkCatalog.upload.libraryID!)@1200"])
        // The hub's own views get it in process, at the sizes they ask for.
        let thumbnail = try #require(LibraryArtworkCatalog.upload.thumbnailURL)
        let url = try #require(URL(string: thumbnail.relativeString, relativeTo: URL(string: "http://127.0.0.1:18867")!))
        #expect(await server.libraryArtwork(at: url.absoluteURL) != nil)
        #expect(await artwork.asked.count == 1)
    }
}
