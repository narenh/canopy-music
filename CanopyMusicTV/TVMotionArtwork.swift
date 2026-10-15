import AVFoundation
import CanopyMusicCore
import SwiftUI

/// Animated album artwork over the party screen's Now Playing art (see `MotionArtwork`; the
/// iPad's is `MotionArtworkView`): a muted, looping video that fades in once its first frame is
/// ready. Until then, or when the album has none, the lookup fails or the video can't play, it
/// shows nothing and the still art stays. Lay it over the artwork, inside its frame and shadow.
///
/// It belongs to one song's page of the party screen's slide: the page going out keeps its video
/// playing as it leaves (it stops when the page is gone), and the page coming in looks its song
/// up itself, so a lookup still going for the last song can't land on it.
struct TVMotionArtworkView: View {
    let track: QueueTrack?
    let catalog: any MusicCatalog
    /// The music's play/pause: the video eases to a stop with it, and back up (as Apple Music's).
    var isPlaying: Bool
    var cornerRadius: CGFloat

    /// The video found for the song, until it can start (not in Low Power Mode).
    @State private var found: URL?
    @State private var url: URL?
    @State private var isShowing = false
    /// The artwork's side, for the most video worth streaming.
    @State private var side: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.screenCovered) private var screenCovered
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            // The artwork's size before there's a video, for `side`.
            Color.clear
            if let url {
                TVLoopingVideo(
                    url: url, pixels: side * displayScale,
                    isActive: scenePhase != .background && !screenCovered && !LowPowerMode.shared.isOn, isPlaying: isPlaying
                ) {
                    withAnimation(.easeIn(duration: 0.8)) { isShowing = true }
                }
                .id(url)
                .opacity(isShowing ? 1 : 0)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { max($0.size.width, $0.size.height) }) { side = $0 }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: track?.id) {
            found = nil
            url = nil
            isShowing = false
            guard MotionArtwork.isEnabled, let track else { return }
            #if DEBUG
            // `-motionArtworkTestURL <HLS URL>`: plays that for every song, to try the video in the
            // simulator (which can't reach Apple Music) or with any service.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-motionArtworkTestURL"), i + 1 < args.count {
                found = URL(string: args[i + 1])
                startIfReady()
                return
            }
            #endif
            // Nil for Spotify and demo hubs. A display TV has its own (service only, Apple Music songs).
            guard let lookup = catalog.motionArtwork else { return }
            let video = await lookup.videoURL(for: track)
            guard !Task.isCancelled else { return }
            found = video
            startIfReady()
        }
        // Low Power Mode: the video fades out to the still art and goes; it comes back without.
        .onChange(of: LowPowerMode.shared.isOn) { _, lowPower in
            guard lowPower else {
                // Back before it had gone: it fades back in.
                if url != nil { withAnimation(.easeIn(duration: 0.8)) { isShowing = true } }
                startIfReady()
                return
            }
            withAnimation(.easeOut(duration: 0.8)) { isShowing = false } completion: {
                if LowPowerMode.shared.isOn { url = nil }
            }
        }
    }

    private func startIfReady() {
        if !LowPowerMode.shared.isOn, url == nil { url = found }
    }
}

/// A muted, looping `AVPlayerLayer`. It never publishes Now Playing info (no
/// `AVPlayerViewController`), never plays to AirPlay, doesn't keep the screen awake (the zone's
/// own setting does that), and pauses while `isActive` is false.
private struct TVLoopingVideo: UIViewRepresentable {
    let url: URL
    /// The artwork's side in pixels: the most video worth streaming.
    let pixels: CGFloat
    let isActive: Bool
    let isPlaying: Bool
    /// Called once, when the first frame is ready to show.
    let onReady: @MainActor () -> Void

    func makeUIView(context: Context) -> TVLoopingVideoView {
        let view = TVLoopingVideoView()
        view.start(url: url, pixels: pixels, onReady: onReady)
        view.setActive(isActive, playing: isPlaying, animated: false)
        return view
    }

    func updateUIView(_ view: TVLoopingVideoView, context: Context) {
        view.setMaximumResolution(pixels)
        view.setActive(isActive, playing: isPlaying, animated: true)
    }

    static func dismantleUIView(_ view: TVLoopingVideoView, coordinator: ()) {
        view.stop()
    }
}

private final class TVLoopingVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var onReady: (@MainActor () -> Void)?
    /// Whether we want it playing (`setActive`), for the debug log.
    private var wantsToPlay = false

    func start(url: URL, pixels: CGFloat, onReady: @escaping @MainActor () -> Void) {
        self.onReady = onReady
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let item = AVPlayerItem(url: url)
        // No bigger a variant than the artwork is drawn (`setMaximumResolution`).
        maximumPixels = Self.maximum(pixels)
        item.preferredMaximumResolution = CGSize(width: maximumPixels, height: maximumPixels)
        motionLog("start, at most \(Int(maximumPixels)) px")
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
        // Debug log of what the player does, to check the music never pauses it (the app's audio
        // session is `.ambient` for that; see `TVModel.init`).
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.statusChanged(player) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            motionLog("audio session interruption \(type == .began ? "began" : type == .ended ? "ended" : "?")")
        }
    }

    /// The video variant streamed is no bigger than the artwork's side in pixels (side × scale).
    private var maximumPixels: CGFloat = 0

    /// Before the artwork is laid out: its biggest, 600 pt at 2× on a 4K TV.
    private static func maximum(_ pixels: CGFloat) -> CGFloat {
        pixels > 0 ? pixels.rounded(.up) : 1200
    }

    /// A new size: later variants follow it.
    func setMaximumResolution(_ pixels: CGFloat) {
        let maximum = Self.maximum(pixels)
        guard maximum != maximumPixels else { return }
        maximumPixels = maximum
        for item in looper?.loopingPlayerItems ?? [] {
            item.preferredMaximumResolution = CGSize(width: maximum, height: maximum)
        }
    }

    /// `active` false (the app's in the background, or the video can't be seen) stops it at once. Otherwise it follows the
    /// music: `animated`, the rate eases down to a stop or back up to normal speed over
    /// `rampDuration`, as Apple Music's motion artwork does; a stream that can't play slower than
    /// normal just pauses and plays.
    func setActive(_ active: Bool, playing: Bool, animated: Bool) {
        guard let player else { return }
        let wanted = active && playing
        guard wanted != wantsToPlay || !animated else { return }
        wantsToPlay = wanted
        rampTimer?.invalidate()
        rampTimer = nil
        let canRamp = animated && active && (player.currentItem?.canPlaySlowForward ?? false)
        guard canRamp else {
            if wanted { player.play() } else { player.pause() }
            return
        }
        ramp = (from: Double(player.rate), to: wanted ? 1 : 0, start: Date())
        if wanted, player.rate == 0 { player.rate = 0.05 }
        rampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rampStep() }
        }
    }

    static let rampDuration: TimeInterval = 0.25
    private var rampTimer: Timer?
    private var ramp: (from: Double, to: Double, start: Date)?

    private func rampStep() {
        guard let player, let ramp else {
            rampTimer?.invalidate()
            rampTimer = nil
            return
        }
        let progress = min(1, Date().timeIntervalSince(ramp.start) / Self.rampDuration)
        // Ease out: quick at first, settling into the new speed.
        let eased = 1 - pow(1 - progress, 2)
        if progress >= 1 {
            rampTimer?.invalidate()
            rampTimer = nil
            self.ramp = nil
            if ramp.to == 0 { player.pause() } else { player.rate = 1 }
        } else {
            player.rate = Float(max(ramp.from + (ramp.to - ramp.from) * eased, 0.05))
        }
    }

    private func statusChanged(_ player: AVPlayer) {
        let status = switch player.timeControlStatus {
        case .paused: "paused"
        case .playing: "playing"
        case .waitingToPlayAtSpecifiedRate: "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: "unknown"
        }
        motionLog("video \(status), wants to play: \(wantsToPlay)")
    }

    func stop() {
        wantsToPlay = false
        rampTimer?.invalidate()
        rampTimer = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
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

/// Debug builds: a line in Library/Caches/tv.log (as `TVModel.debugLog`).
private func motionLog(_ line: String) {
    #if DEBUG
    let url = URL.cachesDirectory.appending(path: "tv.log")
    let text = "\(Date()) [motion] \(line)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
    #endif
}
