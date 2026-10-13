import Foundation

/// How big artwork is decoded (iPad, Mac and Apple TV): each image is decoded at the size it's
/// drawn, rounded up to a bucket, never at its full size. Only the numbers live here (so they can
/// be tested); the apps' `ArtworkCache` decodes with ImageIO.
public enum ArtworkSizing {
    /// Decoded sizes, in pixels: a row's art on the TV is 54 px (64), on an iPad 52 pt at 2× (128),
    /// the TV's Now Playing art up to 600 px (640), the iPad's a little more at 2× (1024). Nothing
    /// is ever decoded past the last one, whatever it's drawn at.
    public static let buckets = [64, 128, 192, 256, 384, 512, 640, 768, 1024, 1536, 2048]

    /// The bucket for art drawn `points` across at `scale` pixels a point: the smallest one with at
    /// least that many pixels.
    public static func bucket(points: Double, scale: Double) -> Int {
        let pixels = (max(points, 0) * max(scale, 1)).rounded(.up)
        return buckets.first { Double($0) >= pixels } ?? buckets.last!
    }

    /// The longest side ImageIO's thumbnail of a `width` × `height` image may have for `bucket`:
    /// enough that its shorter side comes to `bucket` (art fills a square, cropping the rest), but
    /// never more than the image has (no upsampling) nor than the biggest bucket.
    public static func thumbnailMaxPixelSize(bucket: Int, width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return bucket }
        let longer = max(width, height), shorter = min(width, height)
        let side = Int((Double(bucket) * Double(longer) / Double(shorter)).rounded(.up))
        return min(side, longer, buckets.last!)
    }

    /// What a decoded image costs in memory (8 bits a channel, 4 channels), for the cache budgets.
    public static func cost(width: Int, height: Int) -> Int {
        max(width, 0) * max(height, 0) * 4
    }

    /// The TV has 2 GB and a long party to get through; the iPad has more.
    public static let tvBudgetBytes = 64 << 20
    public static let padBudgetBytes = 96 << 20
    /// The background's blurred copies are 64 px square (16 KB each).
    public static let blurredBudgetBytes = 2 << 20

    /// Beyond these an image is skipped (the song's colours show instead): the hub takes any
    /// artwork URL a guest's phone sends, and album art is never this big (Apple Music's is 3000 px
    /// at most). Images between a normal size and these limits are still only ever decoded at
    /// their bucket's size, never in full.
    public static let maxDataBytes = 20 << 20
    public static let maxSide = 10_000

    public enum Verdict: Equatable, Sendable {
        case decode
        case tooMuchData(bytes: Int)
        case tooBig(width: Int, height: Int)
    }

    /// Whether an image of `dataBytes` whose header says `width` × `height` is worth decoding.
    public static func verdict(dataBytes: Int, width: Int, height: Int) -> Verdict {
        if dataBytes > maxDataBytes { return .tooMuchData(bytes: dataBytes) }
        if width > maxSide || height > maxSide { return .tooBig(width: width, height: height) }
        return .decode
    }
}
