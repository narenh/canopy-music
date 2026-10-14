import SwiftUI

/// The background of the screens with no song to take colours from (the zone list, setup, the
/// start screen before a playlist is loaded, Spotify's setup page): the "Dusk" violet of
/// music.canopysf.com and the phone page's splash (`.splash` in `app.css`), drawn the same way
/// (three elliptical glows over a 170° linear base) but darkened to a near-black with a faint
/// violet glow. Static: drawn once, no animation.
struct DuskBackground: View {
    /// How much of Dusk shows: its colours are scaled by this towards black (1 is the web splash,
    /// 0 is black). Debug builds: `-duskStrength <0…1>` to compare levels.
    static let strength: Double = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-duskStrength"), i + 1 < args.count, let value = Double(args[i + 1]) {
            return min(1, max(0, value))
        }
        #endif
        return 0.2
    }()

    /// A radial gradient from `color` at `center` to transparent at the ellipse with radii
    /// `radii`, all as fractions of the view's size (CSS `radial-gradient(rx ry at x y, …)`).
    private struct Glow {
        let radii: CGSize
        let center: UnitPoint
        let rgb: (Double, Double, Double)
        let alpha: Double
    }

    /// Top to bottom, as CSS lists them.
    private static let glows = [
        Glow(radii: CGSize(width: 0.45, height: 0.55), center: UnitPoint(x: 0, y: 0.3), rgb: (120, 70, 180), alpha: 0.7),
        Glow(radii: CGSize(width: 0.35, height: 0.40), center: UnitPoint(x: 1, y: 0), rgb: (150, 90, 170), alpha: 0.55),
        Glow(radii: CGSize(width: 0.60, height: 0.50), center: UnitPoint(x: 0.6, y: 1.1), rgb: (30, 14, 60), alpha: 1),
    ]

    private static func color(_ rgb: (Double, Double, Double), alpha: Double = 1) -> Color {
        let k = strength / 255
        return Color(.sRGB, red: rgb.0 * k, green: rgb.1 * k, blue: rgb.2 * k, opacity: alpha)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                base(size)
                ForEach(Array(Self.glows.enumerated().reversed()), id: \.offset) { _, glow in
                    let color = Self.color(glow.rgb, alpha: glow.alpha)
                    EllipticalGradient(colors: [color, color.opacity(0)], center: .center,
                                       startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .frame(width: 2 * glow.radii.width * size.width, height: 2 * glow.radii.height * size.height)
                        .position(x: glow.center.x * size.width, y: glow.center.y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// `linear-gradient(170deg, #3d2266, #2a1748 60%, #1b0f33)`: CSS runs the line through the
    /// centre at 170° (clockwise from up), just long enough that the corners get the end colours.
    private func base(_ size: CGSize) -> some View {
        let angle = 170 * Double.pi / 180
        let (dx, dy) = (sin(angle), -cos(angle))
        let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
        let (ux, uy) = (size.width > 0 ? half * dx / size.width : 0, size.height > 0 ? half * dy / size.height : 0)
        return LinearGradient(
            stops: [
                .init(color: Self.color((61, 34, 102)), location: 0),
                .init(color: Self.color((42, 23, 72)), location: 0.6),
                .init(color: Self.color((27, 15, 51)), location: 1),
            ],
            startPoint: UnitPoint(x: 0.5 - ux, y: 0.5 - uy),
            endPoint: UnitPoint(x: 0.5 + ux, y: 0.5 + uy)
        )
        .frame(width: size.width, height: size.height)
    }
}
