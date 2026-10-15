import CanopyMusicCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The hub's relay for the art of songs only in its account's library (`LibraryArtwork`), at
/// `GET /api/artwork/<library id>?size=<px>`: loaded from the catalog's `LibraryArtworkSource`,
/// scaled to one of a few sizes, and kept as JPEG within a byte budget, so a page's rows asking
/// again (and every phone asking for the same song) cost nothing. Art that isn't there is
/// remembered for a while too, so rows don't ask MusicKit again on every render.
actor LibraryArtworkRelay {
    /// The sizes served: a request gets the smallest at least as big as it asked for.
    static let sizes = [160, 300, 600, 1200]
    static let budgetBytes = 12 * 1024 * 1024
    static let missingFor: TimeInterval = 300

    private var images: [String: Data] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var bytes = 0
    private var missing: [String: Date] = [:]
    private var loading: [String: Task<Data?, Never>] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    static func size(for requested: Int?) -> Int {
        guard let requested else { return sizes[sizes.count - 1] }
        return sizes.first { $0 >= requested } ?? sizes[sizes.count - 1]
    }

    /// JPEG data for the song's art at `size` (one of `sizes`), or nil when there's none.
    func image(libraryID: String, size: Int, from source: any LibraryArtworkSource) async -> Data? {
        let key = "\(size)|\(libraryID)"
        if let data = images[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return data
        }
        if let since = missing[key], now().timeIntervalSince(since) < Self.missingFor { return nil }
        if let task = loading[key] { return await task.value }
        let task = Task<Data?, Never> {
            guard let original = try? await source.artwork(libraryID: libraryID, size: size) else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.jpeg(original, side: size) }.value
        }
        loading[key] = task
        let data = await task.value
        loading[key] = nil
        if let data {
            store(data, for: key)
        } else {
            missing[key] = now()
        }
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

    /// The image scaled down so its longer side is at most `side` (never up), as JPEG.
    static func jpeg(_ data: Data, side: Int) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
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
}
