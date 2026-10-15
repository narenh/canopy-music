import SwiftUI
import UIKit

// Shared with the TV target (a symlink there).

/// A progress bar's white fill (the iPad's `ProgressBar`, the TV's `TVProgress`), moved by Core
/// Animation: told where the song is and, while it plays, how long it is, the fill runs on to the
/// end by itself, so the bar moves smoothly with no main-thread work between the few updates a
/// second its time labels need. An update that agrees with where the fill has got to leaves it
/// running; a seek restarts it from there. Never narrower than it is tall: from the first moment
/// past 0:00 it's a dot, which grows. (Hide it at 0:00 itself.)
struct ProgressFill: UIViewRepresentable {
    /// How far through the song, 0...1.
    let fraction: Double
    /// The song's length while the fill should move on by itself (playing); nil holds it still.
    let duration: TimeInterval?

    func makeUIView(context: Context) -> ProgressFillView { ProgressFillView() }

    func updateUIView(_ view: ProgressFillView, context: Context) {
        view.show(fraction: fraction, duration: duration)
    }
}

final class ProgressFillView: UIView {
    private let fill = CALayer()
    private static let key = "progress"
    /// What it was last told, and when: where the fill should be since (`expected(at:)`).
    private var anchor: (fraction: Double, duration: TimeInterval?, time: CFTimeInterval) = (0, nil, 0)
    private var laidOutSize: CGSize = .zero
    /// How far, in seconds of the song, an update can be from where the fill has got to and still
    /// leave it running: more than the demo player's quarter-second steps, less than any seek.
    private static let tolerance: TimeInterval = 0.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        fill.backgroundColor = UIColor.white.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(fraction: Double, duration: TimeInterval?) {
        let now = CACurrentMediaTime()
        if let duration, duration == anchor.duration, fill.animation(forKey: Self.key) != nil,
           abs(expected(at: now) - fraction) * duration < Self.tolerance { return }
        if duration == nil, anchor.duration == nil, fraction == anchor.fraction { return }
        anchor = (fraction, duration, now)
        apply(at: now)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new size (the bar thickening while scrubbing): on from where it has got to.
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        let now = CACurrentMediaTime()
        anchor = (expected(at: now), anchor.duration, now)
        apply(at: now)
    }

    private func expected(at time: CFTimeInterval) -> Double {
        guard let duration = anchor.duration, duration > 0 else { return anchor.fraction }
        return min(1, anchor.fraction + (time - anchor.time) / duration)
    }

    private func apply(at now: CFTimeInterval) {
        let (width, height) = (bounds.width, bounds.height)
        let start = min(max(anchor.fraction, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAnimation(forKey: Self.key)
        fill.cornerRadius = height / 2
        fill.position = CGPoint(x: 0, y: height / 2)
        fill.bounds = CGRect(x: 0, y: 0, width: max(width * start, height), height: height)
        if let duration = anchor.duration, duration > 0, start < 1, width > height {
            let remaining = (1 - start) * duration
            // The dot holds until the song's share of the bar is wider than it.
            let dotEnds = (height / width - start) * duration
            let grow = CAKeyframeAnimation(keyPath: "bounds.size.width")
            if dotEnds > 0 {
                grow.values = [height, height, width]
                grow.keyTimes = [0, NSNumber(value: dotEnds / remaining), 1]
            } else {
                grow.values = [width * start, width]
                grow.keyTimes = [0, 1]
            }
            grow.duration = remaining
            grow.beginTime = fill.convertTime(now, from: nil)
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            // It moves a few points a second at most: 30 frames a second is smooth.
            grow.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            fill.add(grow, forKey: Self.key)
        }
        CATransaction.commit()
    }
}
