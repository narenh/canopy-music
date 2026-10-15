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
    /// The music's play/pause: the video eases to a stop with it, and back up (as Apple Music's,
    /// and the TV's `TVMotionArtworkView`).
    var isPlaying: Bool
    /// Holds the video back while true: Now Playing's page is sliding in, or isn't the song playing
    /// (`NowPlayingView`), so only one player runs. One that's showing stays (paused, as it leaves).
    var waits = false
    var cornerRadius: CGFloat
    /// Now Playing can't be seen (the search results are over it): the video pauses.
    var isHidden = false

    /// The video found for the song, until it can start (`waits`).
    @State private var found: URL?
    @State private var url: URL?
    @State private var isShowing = false
    /// Whether the app is in the background (the video stops there). Not `scenePhase`: under this
    /// app's UIKit scene delegate it reads `.background` even in the foreground, which kept the
    /// video paused on its first frame.
    @State private var inBackground = UIApplication.shared.applicationState == .background
    /// The artwork's side, for the most video worth streaming.
    @State private var side: CGFloat = 0

    @Environment(AppModel.self) private var model
    @Environment(\.screenCovered) private var screenCovered
    @Environment(\.displayScale) private var displayScale

    /// Whether the video can play without pausing the music. A display plays no music, so it
    /// always can. On an iPad hub on iOS 27 the video is cut off from the audio session
    /// (`LoopingVideoView.start`); a Mac hub on macOS 27 has no cut-off but was seen not to pause.
    /// Before 27 a hub keeps the still art: a paused party is far worse than art that doesn't move.
    private var leavesMusicAlone: Bool {
        if model.isDisplay { return true }
        // On a Mac this is macOS 27 (an iPad app's iOS version follows the Mac's).
        if #available(iOS 27, *) { return true }
        return false
    }

    var body: some View {
        ZStack {
            // The artwork's size before there's a video, for `side`.
            Color.clear
            if let url {
                LoopingVideo(
                    url: url, pixels: side * displayScale,
                    isActive: !inBackground && !isHidden && !screenCovered && !LowPowerMode.shared.isOn, isPlaying: isPlaying
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
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in inBackground = true }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) { _ in inBackground = false }
        .task(id: track?.id) {
            found = nil
            url = nil
            isShowing = false
            guard MotionArtwork.isEnabled, leavesMusicAlone, let track else { return }
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
            // Only Apple Music catalog songs have it: not a link, nor a song only in the library
            // (no lookup, no retry, no log line).
            guard let lookup = catalog.motionArtwork, MotionArtwork.isCatalogID(track.id) else { return }
            var video = await lookup.videoURL(for: track)
            // Once more a moment later: a failed lookup isn't remembered, but nothing asks again
            // until the song changes, so one hiccup cost the whole song. An album known to have
            // none answers from the lookup's memory.
            if video == nil {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                video = await lookup.videoURL(for: track)
            }
            guard !Task.isCancelled else { return }
            motionLog("lookup \"\(track.title)\" (\(track.id), album \(track.albumID ?? "unknown")): \(video?.absoluteString ?? "none")")
            found = video
            startIfReady()
        }
        .onChange(of: waits) { startIfReady() }
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
        if !waits, !LowPowerMode.shared.isOn, url == nil { url = found }
    }
}

/// A muted, looping `AVPlayerLayer`. It never publishes Now Playing info (no
/// `AVPlayerViewController`), never plays to AirPlay, never touches the audio session (iOS 27),
/// pauses while `isActive` is false, and follows the music's play/pause (`isPlaying`).
private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    /// The artwork's side in pixels: the most video worth streaming.
    let pixels: CGFloat
    let isActive: Bool
    let isPlaying: Bool
    /// Called once, when the first frame is ready to show.
    let onReady: @MainActor () -> Void

    func makeUIView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        view.start(url: url, pixels: pixels, onReady: onReady)
        view.setActive(isActive, playing: isPlaying, animated: false)
        return view
    }

    func updateUIView(_ view: LoopingVideoView, context: Context) {
        view.setMaximumResolution(pixels)
        view.setActive(isActive, playing: isPlaying, animated: true)
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
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var onReady: (@MainActor () -> Void)?
    /// Whether we want it playing (`setActive`), for the debug log.
    private var wantsToPlay = false
    /// False until the player is cut off from the audio session; `setActive` meanwhile only
    /// remembers what it was asked (`requested`).
    private var canPlay = false
    private var requested = (active: false, playing: false)

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
        // Muted or not, a playing AVPlayer activates the app's audio session, which is `.playback`
        // with long-form audio (`AppModel.init`), so not mixable: that interrupts the Apple Music
        // player, which plays in its own session (as found on the Apple TV), and pauses the music.
        // Disconnected, the player leaves the session alone. Not on a Mac, which lacks it.
        if #available(iOS 27, *), !ProcessInfo.processInfo.isiOSAppOnMac {
            player.setDisconnectedFromSystemAudio(true) {
                Task { @MainActor [weak self] in self?.allowPlaying() }
            }
        } else {
            canPlay = true
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in self?.revealOnce() }
        }
        // Debug log of what the player does, to check on a real iPad whether the music pauses it.
        // Unlike the TV's (`.ambient`), the app's audio session is `.playback` with long-form
        // audio, for multi-speaker AirPlay (`AppModel.init`), so it isn't mixable.
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

    /// `active` false (the app's in the background, or the video can't be seen) stops it at once. Otherwise it follows the
    /// music: `animated`, the rate eases down to a stop or back up to normal speed over
    /// `rampDuration`, as Apple Music's motion artwork does; a stream that can't play slower than
    /// normal just pauses and plays.
    func setActive(_ active: Bool, playing: Bool, animated: Bool) {
        requested = (active, playing)
        guard let player, canPlay else { return }
        let wanted = active && playing
        guard wanted != wantsToPlay || !animated else { return }
        wantsToPlay = wanted
        rampTimer?.invalidate()
        rampTimer = nil
        let canRamp = animated && active && (player.currentItem?.canPlaySlowForward ?? false)
        motionLog("\(wanted ? "play" : "pause") (active: \(active), music playing: \(playing), \(canRamp ? "eased" : "at once"))")
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

    /// The video variant streamed is no bigger than the artwork's side in pixels (side × scale).
    private var maximumPixels: CGFloat = 0

    /// Before the artwork is laid out: what it used to be, about 700 pt at 2×.
    private static func maximum(_ pixels: CGFloat) -> CGFloat {
        pixels > 0 ? pixels.rounded(.up) : 1440
    }

    /// A new size (a window resized): later variants follow it.
    func setMaximumResolution(_ pixels: CGFloat) {
        let maximum = Self.maximum(pixels)
        guard maximum != maximumPixels else { return }
        maximumPixels = maximum
        for item in looper?.loopingPlayerItems ?? [] {
            item.preferredMaximumResolution = CGSize(width: maximum, height: maximum)
        }
    }

    private func allowPlaying() {
        guard player != nil, !canPlay else { return }
        canPlay = true
        motionLog("disconnected from system audio")
        setActive(requested.active, playing: requested.playing, animated: false)
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
        motionLog("video \(status), rate \(player.rate), wants to play: \(wantsToPlay)")
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

/// Debug builds: a line in Library/Caches/motion.log (and the console).
private func motionLog(_ line: String) {
    #if DEBUG
    let text = "\(Date()) [motion] \(line)\n"
    print(text, terminator: "")
    let url = URL.cachesDirectory.appending(path: "motion.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
    #endif
}
