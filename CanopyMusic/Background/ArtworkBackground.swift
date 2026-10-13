import CanopyMusicCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// Shared by the iPad (and Mac) app and the Apple TV app: this folder is in both targets.

/// The party background: the theme's base colour, the song's art blurred over it at half
/// opacity and drifting slowly (`ArtworkDrift`), and a shade from the base colour over that.
/// The iPad's `ThemedBackground` and the TV's root view use it, each with its own animation.
///
/// The art is blurred once per image into a small bitmap (`BlurredArtwork`) and drawn window
/// size, so nothing blurs per frame while it drifts.
struct ArtworkBackground: View {
    let track: QueueTrack?
    /// The image to blur (each app has its own rules, and debug-only demo art).
    let artworkURL: URL?
    let theme: ArtworkTheme
    /// Where blurred copies come from: the TV's artwork cache (which makes one with each image
    /// it loads), or `BlurredArtworkCache` on the iPad.
    let source: any BlurredArtworkSource
    /// The TV shows the song's colours as a gradient until its art is ready, or when it has none;
    /// the iPad shows only the base colour then.
    var colorsUntilLoaded = false

    var body: some View {
        ZStack {
            // The base colour animates from song to song; the blurred art cross-fades over it
            // while it drifts (one drift for every song, so a change doesn't jolt it), and the
            // shade cross-fades over that, still.
            Rectangle().fill(theme.base)
            ArtworkDrift {
                BlurredArtworkLayer(track: track, url: artworkURL, source: source, colorsUntilLoaded: colorsUntilLoaded)
                    .opacity(0.5)
                    .id(track?.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [theme.base.opacity(0.1), theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .id(track?.id)
                .transition(.opacity)
        }
        .ignoresSafeArea()
    }
}

/// Blurred copies of artwork, by image URL, for `ArtworkBackground`.
@MainActor protocol BlurredArtworkSource: AnyObject {
    /// The blurred copy, if it's ready.
    func blurredImage(for url: URL) -> UIImage?
    /// Loads the image and makes its blurred copy (once however many ask); nil if that fails.
    func loadBlurred(_ url: URL) async -> UIImage?
}

/// A song's art for the background, from its blurred copy, filling the square `ArtworkDrift`
/// gives it. Before that's ready: the song's colours as a gradient (`colorsUntilLoaded`) or
/// nothing; the art fades in when it arrives.
private struct BlurredArtworkLayer: View {
    let track: QueueTrack?
    let url: URL?
    let source: any BlurredArtworkSource
    let colorsUntilLoaded: Bool
    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            if let image = loaded ?? url.flatMap({ source.blurredImage(for: $0) }) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if colorsUntilLoaded {
                LinearGradient(
                    colors: [
                        track?.colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                        track?.colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .saturation(1.4)
            }
        }
        .task(id: url) {
            guard let url, loaded == nil, source.blurredImage(for: url) == nil else { return }
            let image = await source.loadBlurred(url)
            guard !Task.isCancelled, let image else { return }
            withAnimation(.easeInOut(duration: 1.2)) { loaded = image }
        }
    }
}

/// Makes the background's blurred copy of an image: shrunk to `side` square, blurred, and
/// saturated 1.4×. Blurred this much, drawn as big as the window it looks like the full image
/// blurred there by SwiftUI, and drifting never re-blurs.
enum BlurredArtwork {
    /// Side of the blurred copy, in pixels.
    static let side: CGFloat = 64

    /// The blur the background had as a SwiftUI `blur(radius:)`, as a fraction of the art's
    /// side (the art is as big as the window's longer side): on the TV 120 pt across a 1920-point
    /// screen; on the iPad 90 pt across a 13" iPad's 1376 points (its old live blur, which on
    /// smaller iPads was a little stronger and on big Mac windows weaker).
    #if os(tvOS)
    static let blurFraction: CGFloat = 120 / 1920
    #else
    static let blurFraction: CGFloat = 90 / 1376
    #endif

    private static let context = CIContext()

    /// Core Image's Gaussian radius needs about 1.5× SwiftUI's to match, side by side.
    static func make(from image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let input = CIImage(image: small) else { return nil }
        let blur = CIFilter.gaussianBlur()
        // Clamped so the edges don't fade: they're off screen in the original too.
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(1.5 * blurFraction * side)
        let color = CIFilter.colorControls()
        color.inputImage = blur.outputImage?.cropped(to: input.extent)
        color.saturation = 1.4
        color.brightness = 0
        color.contrast = 1
        guard let output = color.outputImage,
              let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Blurred copies of artwork by URL, for a background whose app has no artwork cache of its own
/// (the iPad's artwork is `AsyncImage`). Downloads go through `URLSession.shared`, so an image
/// Now Playing already loaded usually comes from the URL cache.
@MainActor
final class BlurredArtworkCache: BlurredArtworkSource {
    static let shared = BlurredArtworkCache()
    private let images = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 60
    }

    func blurredImage(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func loadBlurred(_ url: URL) async -> UIImage? {
        if let image = blurredImage(for: url) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            defer { loading[url] = nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            let blurred = await Task.detached(priority: .userInitiated) {
                UIImage(data: data).flatMap(BlurredArtwork.make(from:))
            }.value
            if let blurred { images.setObject(blurred, forKey: url as NSURL) }
            return blurred
        }
        loading[url] = task
        return await task.value
    }
}

/// The background art's slow drift (`BackgroundDrift` has the maths): `content` is laid out as a
/// square as big as the window's longer side, centred, and moved, turned and scaled so no edge
/// of it ever shows, in any window shape. It keeps going while paused and through song changes;
/// Reduce Motion stops it (the art then rests at 1.3×, centred).
struct ArtworkDrift<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far it drifts: 1 normally. Debug builds: `-driftStrength <multiplier>` (0 is off).
    static var strength: Double {
        #if DEBUG
        if let value = debugValue("-driftStrength") { return value }
        #endif
        return 1
    }

    /// How fast it drifts: 1 normally. Debug builds: `-driftSpeed <multiplier>`.
    static var speed: Double {
        #if DEBUG
        if let value = debugValue("-driftSpeed") { return value }
        #endif
        return 1
    }

    #if DEBUG
    private static func debugValue(_ flag: String) -> Double? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, let value = Double(args[i + 1]) else { return nil }
        return max(0, value)
    }
    #endif

    var body: some View {
        let strength = reduceMotion ? 0 : Self.strength
        GeometryReader { geo in
            let (width, height) = (Double(geo.size.width), Double(geo.size.height))
            let side = BackgroundDrift.artSide(width: width, height: height)
            // 30 frames a second is smooth at these speeds (a few points a second).
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: strength == 0)) { timeline in
                let pose = BackgroundDrift.pose(
                    at: timeline.date.timeIntervalSinceReferenceDate * Self.speed,
                    strength: strength, width: width, height: height
                )
                content
                    .frame(width: side, height: side)
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.degrees))
                    .offset(x: pose.dx, y: pose.dy)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipped()
    }
}

/// Debug builds, `-demoArtworkURLs`: demo tracks (which have no art) get a remote image each, to
/// try artwork and the background in the simulator. nil otherwise.
enum DemoArtwork {
    static func url(for track: QueueTrack?) -> URL? {
        #if DEBUG
        if let track, track.artworkURL == nil, track.thumbnailURL == nil,
           ProcessInfo.processInfo.arguments.contains("-demoArtworkURLs") {
            return URL(string: "https://picsum.photos/seed/\(track.id)/600")
        }
        #endif
        return nil
    }
}
