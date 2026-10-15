import CanopyMusicCore
import CanopyMusicServer
import CryptoKit
import ImageIO
import SwiftUI
import UIKit

// Shared by the iPad (and Mac) app and the Apple TV app: this folder is in both targets.

/// The image a track shows: the big one for Now Playing (and the background's blur, which comes
/// with it), the thumbnail for rows, each falling back to the other.
enum ArtworkURL {
    /// A library song's art is a relay path (`LibraryArtwork`, relative). On the hub it's made
    /// absolute against this, and `ArtworkCache` loads it from the hub's relay in process
    /// (`HubLibraryArtwork`), so it shows whether or not the zone is live (its server running).
    /// Displays get those paths made absolute against their zone's hub as they arrive
    /// (`ZoneConnection`), so they never use this.
    static let hubBase = URL(string: "canopy-relay://hub")!

    @MainActor static func url(for track: QueueTrack?, large: Bool) -> URL? {
        let url = large ? track?.artworkURL ?? track?.thumbnailURL : track?.thumbnailURL ?? track?.artworkURL
        if let url, url.scheme == nil {
            return URL(string: url.relativeString, relativeTo: hubBase)?.absoluteURL
        }
        // `-demoArtworkURLs` (debug builds): demo tracks get a remote image each.
        return url ?? DemoArtwork.url(for: track)
    }
}

/// The hub's library art for its own views: one relay for the app's run (its disk cache in
/// Caches), which the phone server shares (`PartyServer.start(libraryArtwork:)`), so what either
/// loads serves both. It warms the art of the session's next songs (`warmAhead`), live or not.
@MainActor
enum HubLibraryArtwork {
    static let relay = LibraryArtworkRelay(disk: .shared)
    private static weak var session: PartySession?
    private static var warming: Task<Void, Never>?

    /// The session the hub's views show now (a display's has no library art, and warms nothing).
    static func follow(_ session: PartySession) {
        guard session !== self.session else { return }
        self.session = session
        warming?.cancel()
        let relay = relay
        warming = Task { await relay.warmAhead(of: session) }
    }

    /// The art at a `hubBase` URL, from the relay.
    static func data(for url: URL) async -> Data? {
        guard let source = session?.catalog.libraryArtwork else { return nil }
        let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value
        return await relay.image(path: url.path, size: size.flatMap { Int($0) }, from: source)
    }
}

/// Artwork from `ArtworkCache`, decoded at the size it's drawn: an image already loaded shows from
/// the first frame (so a page sliding in on the TV has its real art, and a copy flying across the
/// iPad starts with it), and one that isn't loads and then shows (fading in where `fadesIn`).
/// Goes in a square the parent sizes; it fills it, and the parent clips. A row scrolled away
/// before its image came stops waiting for it, which lets its download go (`ArtworkCache.load`).
struct ArtworkImage: View {
    let url: URL
    var fadesIn = false
    @Environment(\.displayScale) private var scale
    @State private var loaded: UIImage?

    var body: some View {
        GeometryReader { geo in
            let bucket = ArtworkSizing.bucket(points: Double(max(geo.size.width, geo.size.height)), scale: Double(scale))
            ZStack {
                if let image = ArtworkCache.shared.image(for: url, bucket: bucket) ?? loaded {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .task(id: bucket) {
                guard ArtworkCache.shared.image(for: url, bucket: bucket) == nil else { return }
                let image = await ArtworkCache.shared.load(url, bucket: bucket)
                guard !Task.isCancelled, let image else { return }
                if fadesIn {
                    withAnimation(.easeOut(duration: 0.25)) { loaded = image }
                } else {
                    loaded = image
                }
            }
        }
    }
}

/// Decoded artwork in memory, by URL and size bucket (`ArtworkSizing`), shared by every artwork
/// view, with the background's blurred copy of each image (`BlurredArtwork`). Each image is decoded
/// by ImageIO at its bucket's size, never in full: an Up next row's art costs 16 KB, not the 5.8 MB
/// of a 1200 px decode, and a guest's enormous image can't fill the memory of a 2 GB Apple TV.
/// Both caches have a byte budget, so a long party's art is evicted rather than kept.
///
/// Loading, for every kind of image (catalog art, a hub's relay over the network, this hub's relay
/// in process):
/// - one download per URL and one decode per bucket, however many views ask at once;
/// - one decode per bucket for the same bytes under different URLs: a hub's relay sends an album's
///   art for each of its songs, each at its own URL;
/// - a few downloads per host at once (`connectionsPerHost`), the rest queued: Now Playing's size
///   first, then the most recently asked, so the rows on screen after a fast scroll go before
///   rows already scrolled past; a load nobody waits for any more (its rows scrolled away) is
///   cancelled, queued or downloading;
/// - responses kept on disk as their headers allow (the app's `URLCache`), so a relaunch or rows
///   evicted from memory don't download again (the relay's say a day).
@MainActor
final class ArtworkCache: BlurredArtworkSource {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    /// Decoded images by their bytes (SHA-256) and bucket.
    private let sameImages = NSCache<NSString, UIImage>()
    private let blurredImages = NSCache<NSURL, UIImage>()
    private var loading: [String: Shared<UIImage?>] = [:]
    private var downloads: [URL: Shared<Fetched?>] = [:]
    private var gates: [String: Gate] = [:]
    private var inFlight = 0
    private let session: URLSession

    /// The size the blur is made from (`BlurredArtwork.side` is 64; a little more to shrink from).
    static let blurBucket = 128
    /// Downloads at once from one host (URLSession's own limit is a few more, so this queue,
    /// which knows what's on screen, decides the order).
    static let connectionsPerHost = 4

    private init() {
        #if os(tvOS)
        images.totalCostLimit = ArtworkSizing.tvBudgetBytes
        #else
        images.totalCostLimit = ArtworkSizing.padBudgetBytes
        #endif
        // A long Up next (a 150-song playlist) and Now Playing's sizes; the byte budget decides.
        images.countLimit = 600
        sameImages.totalCostLimit = images.totalCostLimit / 4
        blurredImages.totalCostLimit = ArtworkSizing.blurredBudgetBytes
        blurredImages.countLimit = 80
        // The app's URL cache (`URLCache.shared`), as before.
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = Self.connectionsPerHost + 2
        session = URLSession(configuration: configuration)
    }

    private static func key(_ url: URL, _ bucket: Int) -> NSString {
        "\(bucket)|\(url.absoluteString)" as NSString
    }

    /// The image at `url` decoded for `bucket`, if it's loaded.
    func image(for url: URL, bucket: Int) -> UIImage? {
        images.object(forKey: Self.key(url, bucket))
    }

    /// The image at `url`, downloaded (once however many ask) and decoded at `bucket`'s size (once
    /// a bucket, and once for the same bytes at another URL); its blurred copy is made with the
    /// first size loaded. nil if it fails, the image is absurdly big (`ArtworkSizing.verdict`), or
    /// everyone waiting stopped (cancelled: their views went away).
    func load(_ url: URL, bucket: Int) async -> UIImage? {
        if let image = image(for: url, bucket: bucket) { return image }
        let key = Self.key(url, bucket) as String
        let shared: Shared<UIImage?>
        if let existing = loading[key] {
            shared = existing
        } else {
            let asked = ContinuousClock.now
            shared = Shared(Task { await self.make(url, bucket: bucket, key: key, asked: asked) })
            loading[key] = shared
        }
        let image = await shared.join { [weak self] in
            if self?.loading[key] === shared { self?.loading[key] = nil }
        }
        if loading[key] === shared { loading[key] = nil }
        return image
    }

    private func make(_ url: URL, bucket: Int, key: String, asked: ContinuousClock.Instant) async -> UIImage? {
        guard let fetched = await data(for: url, priority: bucket) else {
            let after = Self.ms(ContinuousClock.now - asked)
            Self.log(url, bucket, Task.isCancelled ? "cancelled after \(after) (nobody waiting)" : "failed after \(after)")
            return nil
        }
        let decodeStart = ContinuousClock.now
        let sameKey = "\(bucket)|\(fetched.hash)" as NSString
        let image: UIImage
        var how = fetched.source
        if let same = sameImages.object(forKey: sameKey) {
            image = same
            how += ", decoded already (same image)"
        } else {
            let data = fetched.data
            guard let decoded = await Task.detached(priority: .userInitiated, operation: { ArtworkDecoder.decode(data, bucket: bucket, from: url) }).value else {
                Self.log(url, bucket, "\(fetched.source), didn't decode")
                return nil
            }
            image = decoded
        }
        guard let cgImage = image.cgImage else { return nil }
        let cost = ArtworkSizing.cost(width: cgImage.width, height: cgImage.height)
        images.setObject(image, forKey: key as NSString, cost: cost)
        sameImages.setObject(image, forKey: sameKey, cost: cost)
        let decoded = ContinuousClock.now - decodeStart
        Self.log(url, bucket, "\(how): waited \(Self.ms(fetched.waited)), fetch \(Self.ms(fetched.took)), decode \(Self.ms(decoded)), "
                 + "\(fetched.data.count / 1024) KB, total \(Self.ms(ContinuousClock.now - asked)); in flight \(inFlight), queued \(gates.values.map(\.queued).reduce(0, +))")
        if blurredImage(for: url) == nil {
            let blurred = await Task.detached(priority: .userInitiated) { BlurredArtwork.make(from: image) }.value
            if let blurred, let cg = blurred.cgImage {
                blurredImages.setObject(blurred, forKey: url as NSURL, cost: ArtworkSizing.cost(width: cg.width, height: cg.height))
            }
        }
        return image
    }

    /// Starts loading `urls` at `bucket`, for images about to be wanted (the next songs' Now
    /// Playing art, so the TV's slide has it).
    func prewarm(_ urls: [URL], bucket: Int) {
        for url in urls where image(for: url, bucket: bucket) == nil {
            Task { _ = await load(url, bucket: bucket) }
        }
    }

    /// Waits until the image at `url` is ready at `bucket`, or `limit` has passed (it keeps loading
    /// then). Returns whether it's ready.
    func ready(_ url: URL, bucket: Int, within limit: Duration) async -> Bool {
        if image(for: url, bucket: bucket) != nil { return true }
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { @MainActor in
                _ = await self.load(url, bucket: bucket)
                once.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume()
            }
        }
        return image(for: url, bucket: bucket) != nil
    }

    // MARK: BlurredArtworkSource

    func blurredImage(for url: URL) -> UIImage? {
        blurredImages.object(forKey: url as NSURL)
    }

    /// Loads the image at `url` small (`blurBucket`), which makes its blurred copy, unless a load
    /// at another size made it already.
    func loadBlurred(_ url: URL) async -> UIImage? {
        if let blurred = blurredImage(for: url) { return blurred }
        _ = await load(url, bucket: Self.blurBucket)
        return blurredImage(for: url)
    }

    // MARK: Downloads

    /// An image's bytes, where they came from, and what getting them cost.
    private struct Fetched: Sendable {
        var data: Data
        var hash: String
        /// "<kind> from <network | disk>", or "relay in process".
        var source: String
        var waited: Duration
        var took: Duration
    }

    /// The bytes at `url`, fetched once however many loads ask at once (the biggest bucket asking
    /// first goes first in its host's queue).
    private func data(for url: URL, priority: Int) async -> Fetched? {
        let shared: Shared<Fetched?>
        if let existing = downloads[url] {
            shared = existing
        } else {
            shared = Shared(Task { await self.fetch(url, priority: priority) })
            downloads[url] = shared
        }
        let fetched = await shared.join { [weak self] in
            if self?.downloads[url] === shared { self?.downloads[url] = nil }
        }
        if downloads[url] === shared { downloads[url] = nil }
        return fetched
    }

    private func fetch(_ url: URL, priority: Int) async -> Fetched? {
        let kind = Kind(url)
        let asked = ContinuousClock.now
        if kind == .hubRelay {
            inFlight += 1
            defer { inFlight -= 1 }
            guard let data = await HubLibraryArtwork.data(for: url) else { return nil }
            let took = ContinuousClock.now - asked
            let hash = await Task.detached { Self.hash(data) }.value
            return Fetched(data: data, hash: hash, source: kind.rawValue, waited: .zero, took: took)
        }
        let host = url.host ?? ""
        let gate = gates[host] ?? Gate(limit: Self.connectionsPerHost)
        gates[host] = gate
        guard await gate.enter(priority: priority) else { return nil }
        defer { gate.leave() }
        let waited = ContinuousClock.now - asked
        inFlight += 1
        defer { inFlight -= 1 }
        let metrics = FetchMetrics()
        guard let (data, response) = try? await session.data(from: url, delegate: metrics),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200), !data.isEmpty else { return nil }
        let took = ContinuousClock.now - asked - waited
        let hash = await Task.detached { Self.hash(data) }.value
        return Fetched(data: data, hash: hash, source: "\(kind.rawValue) from \(metrics.fromCache ? "disk" : "network")", waited: waited, took: took)
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What an image is, for the log.
    private enum Kind: String {
        case catalog = "catalog CDN"
        case hubRelay = "relay in process"
        case relay = "relay HTTP"
        case other

        init(_ url: URL) {
            if url.scheme == ArtworkURL.hubBase.scheme {
                self = .hubRelay
            } else if url.path.hasPrefix(LibraryArtwork.pathPrefix) {
                self = .relay
            } else if url.host?.hasSuffix("mzstatic.com") == true {
                self = .catalog
            } else {
                self = .other
            }
        }
    }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)) ms"
    }

    /// Debug builds: each load that wasn't already in memory, and what it cost.
    private static func log(_ url: URL, _ bucket: Int, _ line: @autoclosure () -> String) {
        #if DEBUG
        // A library id, or the end of the path (catalog art's last two parts tell albums apart).
        let name = url.path.hasPrefix(LibraryArtwork.pathPrefix) ? String(url.path.dropFirst(LibraryArtwork.pathPrefix.count))
            : String(url.pathComponents.suffix(2).joined(separator: "/").suffix(48))
        print("[artwork cache] \(name)@\(bucket): \(line())")
        #endif
    }

    /// Resumes a wait once, whichever finishes first.
    @MainActor private final class Once {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// Work several callers wait on: once every one of them has been cancelled (their views went
/// away), the work is cancelled too.
@MainActor
private final class Shared<Value: Sendable> {
    let task: Task<Value, Never>
    private var waiters = 0
    private var gone = 0

    init(_ task: Task<Value, Never>) {
        self.task = task
    }

    /// The work's result, waiting as one of its callers. `abandoned` runs when the last caller
    /// still waiting is cancelled, as the work is.
    func join(abandoned: @escaping @MainActor () -> Void) async -> Value {
        waiters += 1
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.leave(abandoned) }
        }
    }

    private func leave(_ abandoned: @MainActor () -> Void) {
        gone += 1
        guard gone >= waiters else { return }
        task.cancel()
        abandoned()
    }
}

/// One host's downloads: `limit` at once, the rest waiting, the biggest image first (Now
/// Playing's), then the most recently asked (the rows on screen now). A wait that's cancelled
/// leaves the queue.
@MainActor
private final class Gate {
    private struct Waiter {
        var id: Int
        var priority: Int
        var continuation: CheckedContinuation<Bool, Never>
    }

    let limit: Int
    private var running = 0
    private var waiting: [Waiter] = []
    private var nextID = 0

    var queued: Int { waiting.count }

    init(limit: Int) {
        self.limit = limit
    }

    /// Whether the caller may go ahead (it must `leave` after); false when it was cancelled.
    func enter(priority: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard running >= limit else {
            running += 1
            return true
        }
        let id = nextID
        nextID += 1
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        // Cancelled just as its turn came: give the turn on.
        if granted, Task.isCancelled {
            leave()
            return false
        }
        return granted
    }

    func leave() {
        guard let next = waiting.indices.max(by: { (waiting[$0].priority, waiting[$0].id) < (waiting[$1].priority, waiting[$1].id) }) else {
            running -= 1
            return
        }
        waiting.remove(at: next).continuation.resume(returning: true)
    }

    private func cancel(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

/// Whether a response came from the URL cache (disk) or the network, for the log.
private final class FetchMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cached = false

    var fromCache: Bool { lock.withLock { cached } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let local = metrics.transactionMetrics.last?.resourceFetchType == .localCache
        lock.withLock { cached = local }
    }
}

/// Decodes artwork at a bucket's size with ImageIO's thumbnailer, which reads the image's size
/// from its header first and never holds the whole decoded image (a JPEG is decoded scaled down).
enum ArtworkDecoder {
    static func decode(_ data: Data, bucket: Int, from url: URL) -> UIImage? {
        // Before any parsing: the size check needs only the byte count.
        let dataVerdict = ArtworkSizing.verdict(dataBytes: data.count, width: 0, height: 0)
        guard dataVerdict == .decode else {
            skipped(url, dataVerdict)
            return nil
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let verdict = ArtworkSizing.verdict(dataBytes: data.count, width: width, height: height)
        guard verdict == .decode else {
            skipped(url, verdict)
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ArtworkSizing.thumbnailMaxPixelSize(bucket: bucket, width: width, height: height),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func skipped(_ url: URL, _ verdict: ArtworkSizing.Verdict) {
        #if DEBUG
        print("[artwork] skipped \(url.absoluteString): \(verdict)")
        #endif
    }
}
