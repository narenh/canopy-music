import CanopyMusicCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The hub's relay for the art of songs only in its account's library (`LibraryArtwork`), at
/// `GET /api/artwork/<library id>?size=<px>`. Each song's image is found once, at the largest size
/// served, and the smaller sizes are scaled from it:
/// - straight from its URL template when the service listed the song with one (`artworkHint`, a
///   library playlist's tracks and searches carry it), with no request to the service;
/// - else from the source's own lookup (`LibraryArtworkSource.artwork`);
/// - else, for a song without art of its own, its album's (another song's from the same album).
/// Songs whose art is the same URL (an album's) share one image: one download, one copy. Kept as
/// JPEG within a byte budget in memory and on disk (`LibraryArtworkDiskCache`), so a page's rows
/// asking again, every phone asking for the same song, and a relaunch cost nothing. Art that isn't
/// there is remembered for a while too, so rows don't ask again on every render. `warm` loads the
/// next songs' art before anything shows them.
actor LibraryArtworkRelay {
    /// The sizes served: a request gets the smallest at least as big as it asked for.
    static let sizes = [160, 300, 600, 1200]
    static let largest = sizes[sizes.count - 1]
    static let budgetBytes = 12 * 1024 * 1024
    static let missingFor: TimeInterval = 300
    /// The songs `warm` loads at once, and the sizes it loads: what Now Playing and rows ask for.
    static let warmConcurrency = 3
    static let warmSizes = [LibraryArtwork.largeSize, LibraryArtwork.thumbnailSize]

    /// A song's image at the largest size, and which image it is (`imageKeys`).
    struct Original: Sendable {
        var key: String
        var jpeg: Data
    }

    /// By "<size>|<image key>".
    private var images: [String: Data] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var bytes = 0
    private var missing: [String: Date] = [:]
    /// Which image each song's art is, once found: "t:<URL template>" for art from a template
    /// (an album's songs often share one), "id:<library id>" for the source's own lookup.
    private var imageKeys: [String: String] = [:]
    /// Songs being found, however many sizes and pages ask at once.
    private var finding: [String: Task<Original?, Never>] = [:]
    /// Templates being downloaded, however many songs share them.
    private var downloads: [String: Task<Data?, Never>] = [:]
    /// Smaller sizes being scaled, by "<size>|<image key>".
    private var scaling: [String: Task<Data?, Never>] = [:]
    private var warmQueue: [String] = []
    private var warmStarted: Set<String> = []
    private var warming = 0
    private var inFlight = 0
    private let disk: LibraryArtworkDiskCache?
    private let download: @Sendable (URL) async -> Data?
    private let now: @Sendable () -> Date

    init(disk: LibraryArtworkDiskCache? = nil, download: @escaping @Sendable (URL) async -> Data? = LibraryArtworkRelay.download,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.disk = disk
        self.download = download
        self.now = now
    }

    static func size(for requested: Int?) -> Int {
        guard let requested else { return largest }
        return sizes.first { $0 >= requested } ?? largest
    }

    /// JPEG data for the song's art at `size` (one of `sizes`), or nil when there's none.
    func image(libraryID: String, size: Int, from source: any LibraryArtworkSource) async -> Data? {
        if let key = imageKeys[libraryID], let data = cached("\(size)|\(key)") { return data }
        if let since = missing[libraryID], now().timeIntervalSince(since) < Self.missingFor { return nil }
        let clock = ContinuousClock(), start = clock.now
        inFlight += 1
        defer { inFlight -= 1 }
        Self.log("\(libraryID)@\(size): asked (\(inFlight) in flight)")
        guard let original = await original(libraryID: libraryID, from: source) else {
            missing[libraryID] = now()
            Self.log("\(libraryID)@\(size): none, \(Self.ms(clock.now - start))")
            return nil
        }
        let key = "\(size)|\(original.key)"
        if let data = size >= Self.largest ? original.jpeg : cached(key) {
            Self.log("\(libraryID)@\(size): \(data.count / 1024) KB in \(Self.ms(clock.now - start))")
            return data
        }
        let scaleStart = clock.now
        guard let data = await scaled(original, size: size, key: key) else { return nil }
        Self.log("\(libraryID)@\(size): \(data.count / 1024) KB in \(Self.ms(clock.now - start)) (scaled from the largest in \(Self.ms(clock.now - scaleStart)))")
        return data
    }

    /// `original` at `size`, scaled once however many ask at once.
    private func scaled(_ original: Original, size: Int, key: String) async -> Data? {
        if let task = scaling[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { Self.jpeg(original.jpeg, side: size) }
        scaling[key] = task
        let data = await task.value
        scaling[key] = nil
        if let data { store(data, for: key) }
        return data
    }

    /// Starts loading the art of `libraryIDs` (the song playing and the next ones), in that order,
    /// `warmConcurrency` at a time, at the sizes the views ask for, unless already started. A new
    /// list replaces the songs still waiting from the last.
    func warm(_ libraryIDs: [String], from source: any LibraryArtworkSource) {
        if warmStarted.count > 2000 { warmStarted = [] }
        let wanted = libraryIDs.filter { !warmStarted.contains($0) }
        guard wanted != warmQueue else { return }
        warmQueue = wanted
        if !wanted.isEmpty { Self.log("warming \(wanted.count): \(wanted.joined(separator: ", "))") }
        startWarming(from: source)
    }

    private func startWarming(from source: any LibraryArtworkSource) {
        while warming < Self.warmConcurrency, !warmQueue.isEmpty {
            let libraryID = warmQueue.removeFirst()
            warmStarted.insert(libraryID)
            warming += 1
            Task {
                let clock = ContinuousClock(), start = clock.now
                for size in Self.warmSizes {
                    _ = await image(libraryID: libraryID, size: Self.size(for: size), from: source)
                }
                Self.log("\(libraryID): warmed in \(Self.ms(clock.now - start))")
                warmed(from: source)
            }
        }
    }

    private func warmed(from source: any LibraryArtworkSource) {
        warming -= 1
        startWarming(from: source)
    }

    /// `warm` has songs still loading or waiting (tests).
    var isWarming: Bool { warming > 0 || !warmQueue.isEmpty }

    /// The song's art at `size` if it's in memory now, without loading it (tests).
    func cachedImage(libraryID: String, size: Int) -> Data? {
        imageKeys[libraryID].flatMap { images["\(size)|\($0)"] }
    }

    // MARK: Finding a song's art

    private func original(libraryID: String, from source: any LibraryArtworkSource) async -> Original? {
        if let key = imageKeys[libraryID], let jpeg = cached("\(Self.largest)|\(key)") { return Original(key: key, jpeg: jpeg) }
        if let task = finding[libraryID] { return await task.value }
        let task = Task { await find(libraryID: libraryID, from: source) }
        finding[libraryID] = task
        let original = await task.value
        finding[libraryID] = nil
        if let original {
            imageKeys[libraryID] = original.key
            store(original.jpeg, for: "\(Self.largest)|\(original.key)")
        }
        return original
    }

    private func find(libraryID: String, from source: any LibraryArtworkSource) async -> Original? {
        let clock = ContinuousClock(), start = clock.now
        let hint = await source.artworkHint(libraryID: libraryID)
        if let template = hint?.template, let original = await original(template: template) {
            Self.log("\(libraryID): its own art, from its template, in \(Self.ms(clock.now - start))")
            return original
        }
        let key = "id:\(libraryID)"
        if let jpeg = await disk?.data(for: key) {
            Self.log("\(libraryID): from disk in \(Self.ms(clock.now - start))")
            return Original(key: key, jpeg: jpeg)
        }
        let lookupStart = clock.now
        if let data = try? await source.artwork(libraryID: libraryID, size: Self.largest) {
            let lookup = clock.now - lookupStart
            let scaleStart = clock.now
            if let jpeg = await Task.detached(priority: .userInitiated, operation: { Self.jpeg(data, side: Self.largest) }).value {
                await disk?.store(jpeg, for: key)
                Self.log("\(libraryID): from the source's lookup in \(Self.ms(clock.now - start)) (lookup \(Self.ms(lookup)), scale \(Self.ms(clock.now - scaleStart)); listed: \(hint == nil ? "no" : "yes, without art"))")
                return Original(key: key, jpeg: jpeg)
            }
        }
        if let template = hint?.albumTemplate, let original = await original(template: template) {
            Self.log("\(libraryID): its album's art in \(Self.ms(clock.now - start))")
            return original
        }
        return nil
    }

    /// The image at `template`, at the largest size: in memory, on disk, or downloaded (once for
    /// every song that has it).
    private func original(template: String) async -> Original? {
        let key = "t:\(template)"
        if let jpeg = cached("\(Self.largest)|\(key)") { return Original(key: key, jpeg: jpeg) }
        if let jpeg = await disk?.data(for: key) { return Original(key: key, jpeg: jpeg) }
        if let task = downloads[key] { return await task.value.map { Original(key: key, jpeg: $0) } }
        let download = download
        let task = Task<Data?, Never> {
            guard let url = LibraryArtworkHint.url(template, size: Self.largest) else { return nil }
            let clock = ContinuousClock(), start = clock.now
            guard let data = await download(url) else {
                Self.log("download failed after \(Self.ms(clock.now - start)): \(url.absoluteString)")
                return nil
            }
            let downloaded = clock.now - start
            let jpeg = await Task.detached(priority: .userInitiated) { Self.jpeg(data, side: Self.largest) }.value
            Self.log("downloaded \(data.count / 1024) KB in \(Self.ms(downloaded)), scaled in \(Self.ms(clock.now - start - downloaded))")
            return jpeg
        }
        downloads[key] = task
        let jpeg = await task.value
        downloads[key] = nil
        if let jpeg { await disk?.store(jpeg, for: key) }
        return jpeg.map { Original(key: key, jpeg: $0) }
    }

    // MARK: Memory

    private func cached(_ key: String) -> Data? {
        guard let data = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return data
    }

    private func store(_ data: Data, for key: String) {
        guard data.count <= Self.budgetBytes else { return }
        if let old = images[key] { bytes -= old.count }
        images[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        bytes += data.count
        while bytes > Self.budgetBytes, let oldest = order.first {
            order.removeFirst()
            bytes -= images.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    // MARK: Images

    static func download(_ url: URL) async -> Data? {
        guard url.scheme == "https" || url.scheme == "http",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// The image scaled down so its longer side is at most `side` (never up), as JPEG. A JPEG
    /// that's already no bigger is kept as it is.
    static func jpeg(_ data: Data, side: Int) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= side, (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)) ms"
    }

    /// Debug builds: what each request cost, for reading a real hub's log.
    private static func log(_ line: @autoclosure () -> String) {
        #if DEBUG
        print("[artwork relay] \(line())")
        #endif
    }
}
