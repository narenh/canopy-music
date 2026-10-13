import CanopyMusicCore
import ImageIO
import SwiftUI
import UIKit

// Shared by the iPad (and Mac) app and the Apple TV app: this folder is in both targets.

/// The image a track shows: the big one for Now Playing (and the background's blur, which comes
/// with it), the thumbnail for rows, each falling back to the other.
enum ArtworkURL {
    static func url(for track: QueueTrack?, large: Bool) -> URL? {
        let url = large ? track?.artworkURL ?? track?.thumbnailURL : track?.thumbnailURL ?? track?.artworkURL
        // `-demoArtworkURLs` (debug builds): demo tracks get a remote image each.
        return url ?? DemoArtwork.url(for: track)
    }
}

/// Artwork from `ArtworkCache`, decoded at the size it's drawn: an image already loaded shows from
/// the first frame (so a page sliding in on the TV has its real art, and a copy flying across the
/// iPad starts with it), and one that isn't loads and then shows (fading in where `fadesIn`).
/// Goes in a square the parent sizes; it fills it, and the parent clips.
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
@MainActor
final class ArtworkCache: BlurredArtworkSource {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    private let blurredImages = NSCache<NSURL, UIImage>()
    /// One download for all the sizes asked for at once (the first Up next rows and their
    /// pre-warm at Now Playing size start together).
    private var downloads: [URL: Task<Data?, Never>] = [:]
    private var loading: [String: Task<UIImage?, Never>] = [:]

    /// The size the blur is made from (`BlurredArtwork.side` is 64; a little more to shrink from).
    static let blurBucket = 128

    private init() {
        #if os(tvOS)
        images.totalCostLimit = ArtworkSizing.tvBudgetBytes
        #else
        images.totalCostLimit = ArtworkSizing.padBudgetBytes
        #endif
        images.countLimit = 160
        blurredImages.totalCostLimit = ArtworkSizing.blurredBudgetBytes
        blurredImages.countLimit = 80
    }

    private static func key(_ url: URL, _ bucket: Int) -> NSString {
        "\(bucket)|\(url.absoluteString)" as NSString
    }

    /// The image at `url` decoded for `bucket`, if it's loaded.
    func image(for url: URL, bucket: Int) -> UIImage? {
        images.object(forKey: Self.key(url, bucket))
    }

    /// The image at `url`, downloaded (once however many ask) and decoded at `bucket`'s size (once
    /// a bucket); its blurred copy is made with the first size loaded. nil if it fails, or the
    /// image is absurdly big (`ArtworkSizing.verdict`).
    func load(_ url: URL, bucket: Int) async -> UIImage? {
        if let image = image(for: url, bucket: bucket) { return image }
        let key = Self.key(url, bucket)
        if let task = loading[key as String] { return await task.value }
        // The task caches what it made before anyone waiting on it carries on.
        let task = Task<UIImage?, Never> {
            defer { loading[key as String] = nil }
            guard let data = await data(for: url) else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                ArtworkDecoder.decode(data, bucket: bucket, from: url)
            }.value
            guard let image = decoded, let cgImage = image.cgImage else { return nil }
            images.setObject(image, forKey: key, cost: ArtworkSizing.cost(width: cgImage.width, height: cgImage.height))
            if blurredImage(for: url) == nil {
                let blurred = await Task.detached(priority: .userInitiated) { BlurredArtwork.make(from: image) }.value
                if let blurred, let cg = blurred.cgImage {
                    blurredImages.setObject(blurred, forKey: url as NSURL, cost: ArtworkSizing.cost(width: cg.width, height: cg.height))
                }
            }
            return image
        }
        loading[key as String] = task
        return await task.value
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

    private func data(for url: URL) async -> Data? {
        if let task = downloads[url] { return await task.value }
        let task = Task<Data?, Never> {
            defer { downloads[url] = nil }
            return try? await URLSession.shared.data(from: url).0
        }
        downloads[url] = task
        return await task.value
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
