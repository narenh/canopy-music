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
    /// The music's play/pause: the video follows it (`fadesWhilePaused`).
    var isPlaying: Bool
    var cornerRadius: CGFloat

    /// The video found for the song, until it can start (not in Low Power Mode).
    @State private var found: URL?
    @State private var url: URL?
    @State private var isShowing = false
    /// Whether the video is actually moving (not stopped, nor starting up after a pause).
    @State private var isMoving = false
    /// The artwork's side, for the most video worth streaming.
    @State private var side: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.screenCovered) private var screenCovered
    @Environment(\.displayScale) private var displayScale

    /// To try, as the iPad's (`MotionArtworkView.fadesWhilePaused`): paused, the video fades to
    /// the still art, still moving until it's gone, then stops; it plays and fades back in.
    static let fadesWhilePaused = true
    static let pauseFade: TimeInterval = 0.8

    /// Shown, not faded to the still art: the music's playing and the video's moving.
    private var movesShown: Bool {
        !Self.fadesWhilePaused || (isPlaying && isMoving)
    }

    var body: some View {
        ZStack {
            // The artwork's size before there's a video, for `side`.
            Color.clear
            if let url {
                TVLoopingVideo(
                    url: url, pixels: side * displayScale,
                    isActive: scenePhase != .background && !screenCovered && !LowPowerMode.shared.isOn, isPlaying: isPlaying,
                    onMoving: { isMoving = $0 }
                ) {
                    withAnimation(.easeIn(duration: 0.8)) { isShowing = true }
                }
                .id(url)
                .opacity(isShowing ? 1 : 0)
                // Paused, a copy of the still art fades in over the video (still moving until it's
                // covered). Played, it fades away once the video's moving again, not while it's
                // still a stopped frame. The video itself stays opaque: see-through, it was seen
                // to dim until the fade ended (on the iPad).
                TVArtwork(track: track, large: true, cornerRadius: cornerRadius)
                    // Faded as one image: otherwise its placeholder gradient, under the picture,
                    // fades too and darkens the middle of the fade (as recorded on the iPad).
                    .compositingGroup()
                    .opacity(isShowing && !movesShown ? 1 : 0)
                    .animation(.easeInOut(duration: Self.pauseFade), value: movesShown)
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
            isMoving = false
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
    /// Called when the video starts moving (true) and when it stops (false).
    let onMoving: @MainActor (Bool) -> Void
    /// Called once, when the first frame is ready to show.
    let onReady: @MainActor () -> Void

    func makeUIView(context: Context) -> TVLoopingVideoView {
        let view = TVLoopingVideoView()
        view.onMoving = onMoving
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
    var onMoving: (@MainActor (Bool) -> Void)?
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

    /// `active` false (the app's in the background, or the video can't be seen) stops it at once.
    /// Otherwise it follows the music: `animated`, a pause lets it keep moving while it fades to
    /// the still art (`TVMotionArtworkView.fadesWhilePaused`), then stops it. (Easing the rate
    /// down instead stuttered on busy artwork at every length tried.)
    func setActive(_ active: Bool, playing: Bool, animated: Bool) {
        guard let player else { return }
        let wanted = active && playing
        guard wanted != wantsToPlay || !animated else { return }
        wantsToPlay = wanted
        pauseTimer?.invalidate()
        pauseTimer = nil
        if wanted {
            player.play()
        } else if animated, active, TVMotionArtworkView.fadesWhilePaused {
            pauseTimer = Timer.scheduledTimer(withTimeInterval: TVMotionArtworkView.pauseFade, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pauseTimer = nil
                    self?.player?.pause()
                }
            }
        } else {
            player.pause()
        }
    }

    /// Stops the video once it has faded out on a pause.
    private var pauseTimer: Timer?

    private func statusChanged(_ player: AVPlayer) {
        let status = switch player.timeControlStatus {
        case .paused: "paused"
        case .playing: "playing"
        case .waitingToPlayAtSpecifiedRate: "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: "unknown"
        }
        motionLog("video \(status), wants to play: \(wantsToPlay)")
        // Waiting (a stall while playing) leaves it as it was.
        switch player.timeControlStatus {
        case .playing: onMoving?(true)
        case .paused: onMoving?(false)
        default: break
        }
    }

    func stop() {
        wantsToPlay = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        readyObservation?.invalidate()
        readyObservation = nil
        onReady = nil
        onMoving = nil
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
