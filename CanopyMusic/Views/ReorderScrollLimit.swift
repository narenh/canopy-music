import SwiftUI
import UIKit

/// While a row of a `List` is being dragged to reorder it, the list can't scroll above row `row`
/// (an item of its first section): the drag's auto-scroll stops with that row's top at the top of
/// the list. Scrolling by hand is untouched. Goes in the List's background, where it finds the
/// List's collection view; if it can't, it does nothing.
///
/// A reorder is either a drag session (`hasActiveDrag`, what a press on the handle usually
/// becomes) or the reorder control's own long press, which some drags stay on. It's looked for
/// only while a finger is on the list. The offset is set back as soon as the auto-scroll changes
/// it, before anything is drawn, so the list stands still at the limit. (A lower top inset
/// instead confuses the drag's auto-scroll, which then runs the list the wrong way.)
struct ReorderScrollLimit: UIViewRepresentable {
    var row: Int?

    func makeUIView(context: Context) -> ReorderScrollLimitView { ReorderScrollLimitView() }

    func updateUIView(_ view: ReorderScrollLimitView, context: Context) {
        view.row = row
    }

    static func dismantleUIView(_ view: ReorderScrollLimitView, coordinator: ()) {
        view.detach()
    }
}

final class ReorderScrollLimitView: UIView, UIGestureRecognizerDelegate {
    var row: Int?
    private weak var collectionView: UICollectionView?
    /// Notices a finger on the list, so the drag is looked for only while there is one.
    private lazy var watcher: TouchWatcher = {
        let watcher = TouchWatcher(target: nil, action: nil)
        watcher.delegate = self
        watcher.onTouch = { [weak self] in self?.startWatching() }
        return watcher
    }()
    private var link: CADisplayLink?
    /// While a drag is held back: the limit row (as when it started) and its offset as last
    /// measured, and the furthest down the list has been.
    private struct Held {
        let row: Int
        var limit: CGFloat
        var furthest: CGFloat
    }
    private var held: Held?
    private var observations: [NSKeyValueObservation] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { attach() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attach()
    }

    /// Looks again over the next few run loops: the List can lay out its collection view after this.
    private func attach(tries: Int = 10) {
        guard collectionView == nil, window != nil else { return }
        if let found = findCollectionView() {
            collectionView = found
            found.addGestureRecognizer(watcher)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.attach(tries: tries - 1) }
        }
    }

    func detach() {
        stopWatching()
        release()
        collectionView?.removeGestureRecognizer(watcher)
        collectionView = nil
    }

    /// The List's collection view: the nearest one with this view's frame (it's the List's background).
    private func findCollectionView() -> UICollectionView? {
        guard let window else { return nil }
        let frame = convert(bounds, to: window)
        func matches(_ view: UICollectionView) -> Bool {
            let other = view.convert(view.bounds, to: window)
            return abs(other.minX - frame.minX) < 1 && abs(other.minY - frame.minY) < 1
                && abs(other.width - frame.width) < 1 && abs(other.height - frame.height) < 1
        }
        var ancestor = superview
        for _ in 0..<6 {
            guard let current = ancestor else { break }
            var queue = current.subviews
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let view = queue.removeFirst()
                visited += 1
                if let found = view as? UICollectionView {
                    if matches(found) { return found }
                    continue
                }
                queue += view.subviews
            }
            ancestor = current.superview
        }
        return nil
    }

    // MARK: Watching

    private func startWatching() {
        lastSeen = CACurrentMediaTime()
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopWatching() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard let collectionView else { stopWatching(); return }
        if isReordering(collectionView) {
            lastSeen = CACurrentMediaTime()
            hold(collectionView)
        } else if CACurrentMediaTime() - lastSeen > Self.grace {
            release()
            if !watcher.isTouching { stopWatching() }
        }
    }

    /// When a drag was last seen, or a finger came down. A press on the handle starts as the
    /// reorder control's long press and becomes a drag session a few frames later, with nothing
    /// in between (and the finger's touch cancelled); this bridges that.
    private var lastSeen: CFTimeInterval = 0
    private static let grace: CFTimeInterval = 0.4

    private func isReordering(_ collectionView: UICollectionView) -> Bool {
        if collectionView.hasActiveDrag { return true }
        // The reorder control's own long press (a control in the cell; a context menu's isn't).
        return collectionView.visibleCells.contains { cell in
            if cell.configurationState.isReordering { return true }
            var queue: [UIView] = [cell]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if view is UIControl, view.gestureRecognizers?.contains(where: { $0 is UILongPressGestureRecognizer && ($0.state == .began || $0.state == .changed) }) == true {
                    return true
                }
                queue += view.subviews
            }
            return false
        }
    }

    // MARK: Holding

    private func hold(_ collectionView: UICollectionView) {
        if held != nil {
            clamp(collectionView)
            return
        }
        guard let row, row > 0, row < collectionView.numberOfItems(inSection: 0),
              let limit = limit(row: row, in: collectionView) else { return }
        let y = collectionView.contentOffset.y
        held = Held(row: row, limit: limit, furthest: y)
        // Checked whenever the list scrolls or its rows change height, before anything is drawn.
        observations = [
            collectionView.observe(\.contentOffset) { [weak self] collectionView, _ in
                MainActor.assumeIsolated { self?.clamp(collectionView) }
            },
            collectionView.observe(\.contentSize) { [weak self] collectionView, _ in
                MainActor.assumeIsolated { self?.clamp(collectionView) }
            },
        ]
        // Someone had scrolled up into what's played: bring the top of the limit row back up.
        if y < limit {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: limit), animated: true)
        }
    }

    /// The offset with the limit row's top at the top of the list. The row just above it is the
    /// one measured: the limit row itself moves down when the dragged one makes room above it.
    private func limit(row: Int, in collectionView: UICollectionView) -> CGFloat? {
        guard row < collectionView.numberOfItems(inSection: 0),
              let above = collectionView.layoutAttributesForItem(at: IndexPath(item: row - 1, section: 0)) else { return nil }
        return above.frame.maxY - collectionView.adjustedContentInset.top
    }

    /// Keeps the offset from going above the limit, or, when the drag started above it, above the
    /// furthest down it has been since: the list can go back toward the limit row but no further.
    private func clamp(_ collectionView: UICollectionView) {
        guard var held, let limit = limit(row: held.row, in: collectionView) else { return }
        // When a drag starts, the List lays out the rows above again, out of view, at their
        // estimated heights, and everything below them jumps. Move with them, so what's in view
        // stays put.
        let shift = limit - held.limit
        if abs(shift) > 0.5 {
            held.limit = limit
            held.furthest += shift
            self.held = held
            collectionView.contentOffset.y += shift
            return
        }
        let y = collectionView.contentOffset.y
        held.furthest = max(held.furthest, y)
        self.held = held
        let floor = min(limit, held.furthest)
        if y < floor - 0.5 {
            collectionView.contentOffset.y = floor
        }
    }

    private func release() {
        observations = []
        held = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Never recognizes anything; only says when a finger comes down on its view, and whether one
/// still is.
private final class TouchWatcher: UIGestureRecognizer {
    var onTouch: () -> Void = {}
    private(set) var isTouching = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        isTouching = true
        onTouch()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if numberOfTouches <= touches.count { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        isTouching = false
    }
}
