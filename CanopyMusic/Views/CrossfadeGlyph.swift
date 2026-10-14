import SwiftUI

/// Crossfade: one song's bars shrinking as the next one's grow. SF Symbols has no crossfade
/// symbol, so this draws the same glyph as the web party page's Crossfade button (index.html):
/// on a 24-point grid, round-capped strokes 2.2 wide, the song fading in at 55%. It fills its
/// frame (as a square, centered) in the foreground style, its strokes scaling with it, so give
/// it a frame where a symbol would get a font size. Shared with the TV target (a symlink there).
struct CrossfadeGlyph: View {
    var body: some View {
        ZStack {
            CrossfadeBars(bars: Self.fadingOut)
            CrossfadeBars(bars: Self.fadingIn).opacity(0.55)
        }
    }

    /// Each bar's x, top and bottom on the 24-point grid: the song ending, tall to short...
    private static let fadingOut = [CrossfadeBars.Bar(x: 3, top: 5, bottom: 19),
                                    CrossfadeBars.Bar(x: 6.5, top: 7, bottom: 17),
                                    CrossfadeBars.Bar(x: 10, top: 9.5, bottom: 14.5)]
    /// ...and the song starting, short to tall.
    private static let fadingIn = [CrossfadeBars.Bar(x: 14, top: 9.5, bottom: 14.5),
                                   CrossfadeBars.Bar(x: 17.5, top: 7, bottom: 17),
                                   CrossfadeBars.Bar(x: 21, top: 5, bottom: 19)]
}

/// One group of the glyph's bars, already stroked (so it fills, and the stroke scales with the
/// frame as the SVG's does).
private struct CrossfadeBars: Shape {
    struct Bar {
        let x: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    let bars: [Bar]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let left = rect.midX - 12 * scale, top = rect.midY - 12 * scale
        var path = Path()
        for bar in bars {
            path.move(to: CGPoint(x: left + bar.x * scale, y: top + bar.top * scale))
            path.addLine(to: CGPoint(x: left + bar.x * scale, y: top + bar.bottom * scale))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round))
    }
}
