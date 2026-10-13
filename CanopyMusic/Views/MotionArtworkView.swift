import AVFoundation
import CanopyMusicCore
import SwiftUI

/// Animated album artwork over Now Playing's still artwork (see `MotionArtwork`): a muted,
/// looping video that fades in once its first frame is ready. Until then, or when the album has
/// none, the lookup fails or the video can't play, it shows nothing and the still art stays.
/// Lay it over the artwork, inside its frame and shadow.
struct MotionArtworkView: View {
    let track: QueueTrack?
    let catalog: any MusicCatalog
    var cornerRadius: CGFloat

    @State private var url: URL?
    @State private var isShowing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let url {
                LoopingVideo(url: url, isActive: scenePhase != .background) {
                    withAnimation(.easeIn(duration: 0.8)) { isShowing = true }
                }
                .id(url)
                .opacity(isShowing ? 1 : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: track?.id) {
            url = nil
            isShowing = false
            guard MotionArtwork.isEnabled, let track else { return }
            #if DEBUG
            // `-motionArtworkTestURL <HLS URL>`: plays that for every song, to try the video in the
            // simulator (which can't reach Apple Music) or with any service.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-motionArtworkTestURL"), i + 1 < args.count {
                url = URL(string: args[i + 1])
                return
            }
            #endif
            guard let lookup = catalog.motionArtwork else { return }
            let found = await lookup.videoURL(for: track)
            guard !Task.isCancelled else { return }
            url = found
        }
    }
}

/// A muted, looping `AVPlayerLayer`. It never publishes Now Playing info (no
/// `AVPlayerViewController`), never plays to AirPlay, and pauses while `isActive` is false.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    /// Called once, when the first frame is ready to show.
    let onReady: @MainActor () -> Void

    func makeUIView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        view.start(url: url, onReady: onReady)
        view.setActive(isActive)
        return view
    }

    func updateUIView(_ view: LoopingVideoView, context: Context) {
        view.setActive(isActive)
    }

    static func dismantleUIView(_ view: LoopingVideoView, coordinator: ()) {
        view.stop()
    }
}

private final class LoopingVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var onReady: (@MainActor () -> Void)?

    func start(url: URL, onReady: @escaping @MainActor () -> Void) {
        self.onReady = onReady
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let item = AVPlayerItem(url: url)
        // The artwork is at most about 700 pt; don't stream a 4K variant for it.
        item.preferredMaximumResolution = CGSize(width: 1440, height: 1440)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = player
        self.player = player
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in self?.revealOnce() }
        }
    }

    func setActive(_ active: Bool) {
        guard let player else { return }
        if active { player.play() } else { player.pause() }
    }

    func stop() {
        readyObservation?.invalidate()
        readyObservation = nil
        onReady = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
    }

    private func revealOnce() {
        guard let onReady else { return }
        self.onReady = nil
        onReady()
    }
}
