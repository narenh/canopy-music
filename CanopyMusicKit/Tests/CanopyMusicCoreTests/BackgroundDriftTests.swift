import Foundation
import Testing
@testable import CanopyMusicCore

@Suite struct BackgroundDriftTests {
    /// Window sizes: TV, iPad landscape and portrait (13", 11", mini), and Mac windows up to wide
    /// and tall ones.
    static let sizes: [(Double, Double)] = [
        (1920, 1080), (1376, 1032), (1032, 1376), (1180, 820), (820, 1180), (744, 1133),
        (1800, 1200), (2560, 1080), (3440, 1440), (1080, 2560), (1200, 1800), (900, 900),
    ]

    /// Whether the art square, posed, covers the window point (x, y) (relative to its centre).
    private func covers(_ pose: BackgroundDrift.Pose, side: Double, x: Double, y: Double) -> Bool {
        // Forward: art point p → R(θ)·(scale·p) + d. Invert it for the window point.
        let r = pose.degrees * .pi / 180
        let (px, py) = (x - pose.dx, y - pose.dy)
        let u = (cos(r) * px + sin(r) * py) / pose.scale
        let v = (-sin(r) * px + cos(r) * py) / pose.scale
        return abs(u) <= side / 2 && abs(v) <= side / 2
    }

    /// Over half an hour of drift at strength 1 and 2, no window corner (nor edge midpoint) ever
    /// falls outside the art, whatever the window's shape.
    @Test func neverShowsAnEdge() {
        for (w, h) in Self.sizes {
            let side = BackgroundDrift.artSide(width: w, height: h)
            for strength in [1.0, 2.0] {
                for step in 0..<3600 {
                    let pose = BackgroundDrift.pose(at: Double(step) * 0.5, strength: strength, width: w, height: h)
                    for (x, y) in [(w / 2, h / 2), (-w / 2, h / 2), (w / 2, -h / 2), (-w / 2, -h / 2), (0, h / 2), (w / 2, 0)] {
                        #expect(covers(pose, side: side, x: x, y: y), "\(w)×\(h) strength \(strength) t \(Double(step) * 0.5)")
                    }
                }
            }
        }
    }

    /// The clamp is tight: a little smaller and a corner shows.
    @Test func minimumScaleIsTight() {
        for (w, h) in Self.sizes {
            let side = BackgroundDrift.artSide(width: w, height: h)
            let needed = BackgroundDrift.minimumScale(degrees: 12, dx: 0.2 * w, dy: -0.15 * h, width: w, height: h)
            let posed = BackgroundDrift.Pose(scale: needed - 0.02, degrees: 12, dx: 0.2 * w, dy: -0.15 * h)
            let corners = [(w / 2, h / 2), (-w / 2, h / 2), (w / 2, -h / 2), (-w / 2, -h / 2)]
            #expect(corners.contains { !covers(posed, side: side, x: $0.0, y: $0.1) })
        }
    }

    /// Strength 0 is still: the iPad's old static background (1.3×, centred, level).
    @Test func strengthZeroIsStill() {
        for (w, h) in Self.sizes {
            for t in [0.0, 17.0, 1234.5] {
                let pose = BackgroundDrift.pose(at: t, strength: 0, width: w, height: h)
                #expect(pose == BackgroundDrift.Pose(scale: 1.3, degrees: 0, dx: 0, dy: 0))
            }
        }
    }

    @Test func artSideIsTheLongerSide() {
        #expect(BackgroundDrift.artSide(width: 2560, height: 1080) == 2560)
        #expect(BackgroundDrift.artSide(width: 820, height: 1180) == 1180)
    }
}
