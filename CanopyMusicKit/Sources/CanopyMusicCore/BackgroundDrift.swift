import Foundation

/// The party background's slow drift (iPad, Mac and Apple TV): the blurred art's scale, offset
/// and rotation each follow two or three sines with periods of 40–90 s that never line up, so it
/// doesn't visibly repeat. Only the maths lives here; `ArtworkDrift` (shared by both apps) draws it.
///
/// The art is a square as big as the window's longer side, centred, so in a landscape window it
/// overhangs the top and bottom and in a portrait one the sides. The pose never lets an edge of
/// it show: its scale is at least what keeps every corner of the window inside the turned,
/// moved square (`minimumScale`).
public enum BackgroundDrift {
    public struct Pose: Equatable, Sendable {
        public var scale: Double
        /// Clockwise on screen.
        public var degrees: Double
        /// Points, right and down.
        public var dx: Double
        public var dy: Double
    }

    /// The scale with no drift (strength 0): the art 1.3× the window's longer side, as the iPad's
    /// background always was.
    public static let restingScale = 1.3

    /// The art layer's side for a window: the longer of its sides.
    public static func artSide(width: Double, height: Double) -> Double {
        max(width, height)
    }

    /// The pose at time `t` (seconds). At strength 1 (8× the first, too-subtle tuning, chosen on a
    /// real TV): scale about 1.3 ± 0.6, up to about 29% of the window off centre each way, and up
    /// to 16° turned. The blur hides small moves, so it takes this much to read as drifting.
    /// Strength 0 is still: `restingScale`, centred, level.
    public static func pose(at t: Double, strength s: Double, width: Double, height: Double) -> Pose {
        let dx = s * width * wave(t, [(0.144, 47, 0.3), (0.096, 79, 2.1), (0.048, 61, 4.0)])
        let dy = s * height * wave(t, [(0.144, 59, 1.2), (0.096, 89, 3.4), (0.048, 43, 5.1)])
        let degrees = s * wave(t, [(9.6, 67, 0.7), (6.4, 41, 2.9)])
        let scale = restingScale + s * wave(t, [(0.36, 53, 1.9), (0.24, 83, 0.4)])
        let needed = minimumScale(degrees: degrees, dx: dx, dy: dy, width: width, height: height)
        return Pose(scale: max(scale, needed), degrees: degrees, dx: dx, dy: dy)
    }

    /// The smallest scale at which the art square (side `artSide`, scaled about its centre, turned
    /// `degrees` clockwise, then moved by `dx`, `dy`) still covers the whole window, plus a couple
    /// of points so antialiasing never shows a sliver. Each window corner is taken into the art's
    /// own frame (moved back, turned back); the square must reach the farthest one along either of
    /// its axes. This holds for any window shape: wide Mac windows, and portrait ones where the
    /// art overhangs the sides rather than the top and bottom.
    public static func minimumScale(degrees: Double, dx: Double, dy: Double, width: Double, height: Double) -> Double {
        let side = artSide(width: width, height: height)
        guard side > 0 else { return 1 }
        let radians = degrees * .pi / 180
        let (c, s) = (cos(radians), sin(radians))
        var reach = 0.0
        for (x, y) in [(width / 2, height / 2), (-width / 2, height / 2), (width / 2, -height / 2), (-width / 2, -height / 2)] {
            let (px, py) = (x - dx, y - dy)
            // Turned back by -degrees.
            let u = c * px + s * py
            let v = -s * px + c * py
            reach = max(reach, abs(u), abs(v))
        }
        return (2 * reach + margin) / side
    }

    /// Points of art kept past the window's farthest corner.
    static let margin = 4.0

    private static func wave(_ t: Double, _ terms: [(amplitude: Double, period: Double, phase: Double)]) -> Double {
        terms.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * t / $1.period + $1.phase) }
    }
}
