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
    /// The music's play/pause: the video follows it (`fadesWhilePaused`; as the TV's
    /// `TVMotionArtworkView`).
    var isPlaying: Bool
    /// Holds the video back while true: Now Playing's page is sliding in, or isn't the song playing
    /// (`NowPlayingView`), so only one player runs. One that's showing stays (paused, as it leaves).
    var waits = false
    var cornerRadius: CGFloat
    /// Now Playing can't be seen (the search results are over it): the video pauses.
    var isHidden = false
    /// Told when the video starts showing over the still art and when it goes (Low Power Mode,
    /// another song): Now Playing hides its equalizer bars while it shows.
    var onShowing: (Bool) -> Void = { _ in }
    /// Told when a video known ahead to be coming (`MotionArtworkAhead`) won't show after all:
    /// the lookup found none, the video failed or didn't show in time, or Low Power Mode. Now
    /// Playing, which left its equalizer bars out for it, brings them back.
    var onWontShow: () -> Void = {}

    /// The video found for the song, until it can start (`waits`).
    @State private var found: Found?
    @State private var url: URL?
    @State private var isShowing = false
    /// Whether the video is actually moving (not stopped, nor starting up after a pause).
    @State private var isMoving = false
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
    /// To try (against a plain pause, false): paused, the video fades to the still art over
    /// `pauseFade`, still moving until it's gone, then stops; it plays and fades back in with the
    /// music over `resumeFade`.
    static let fadesWhilePaused = true
    static let pauseFade: TimeInterval = 0.6
    static let resumeFade: TimeInterval = 0.8

    /// Shown, not faded to the still art: the music's playing and the video's moving.
    private var movesShown: Bool {
        !Self.fadesWhilePaused || (isPlaying && isMoving)
    }

    static func leavesMusicAlone(isDisplay: Bool) -> Bool {
        if isDisplay { return true }
        // On a Mac this is macOS 27 (an iPad app's iOS version follows the Mac's).
        if #available(iOS 27, *) { return true }
        return false
    }

    #if DEBUG
    /// `-motionArtworkTestURL <URL>`: that video for every song, to try the video in the simulator
    /// (which can't reach Apple Music) or with any service. With `-motionArtworkTestEveryOther`,
    /// only songs whose id ends in an even digit (every other demo song), to try songs without.
    /// nil without the argument; `.some(nil)` for a song left without.
    static func testVideo(for track: QueueTrack) -> URL?? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-motionArtworkTestURL"), i + 1 < args.count else { return nil }
        if args.contains("-motionArtworkTestEveryOther"), let digit = track.id.last?.wholeNumberValue, digit % 2 == 1 {
            return .some(nil)
        }
        return .some(URL(string: args[i + 1]))
    }
    #endif

    var body: some View {
        ZStack {
            // The artwork's size before there's a video, for `side`.
            Color.clear
            if let url {
                LoopingVideo(
                    url: url, pixels: side * displayScale,
                    isActive: !inBackground && !isHidden && !screenCovered && !LowPowerMode.shared.isOn, isPlaying: isPlaying,
                    onMoving: { isMoving = $0 }
                ) {
                    withAnimation(.easeIn(duration: 0.8)) { isShowing = true }
                } onFailed: {
                    onWontShow()
                }
                .id(url)
                .opacity(isShowing ? 1 : 0)
                // Paused, a copy of the still art fades in over the video (still moving until it's
                // covered). Played, it fades away once the video's moving again, not while it's
                // still a stopped frame. The video itself stays opaque: see-through, it was seen
                // to dim until the fade ended.
                ArtworkView(track: track, large: true, cornerRadius: cornerRadius)
                    // Faded as one image: otherwise its placeholder gradient, under the picture,
                    // fades too and darkens the middle of the fade (as recorded).
                    .compositingGroup()
                    .opacity(isShowing && !movesShown ? 1 : 0)
                    .animation(.easeInOut(duration: movesShown ? Self.resumeFade : Self.pauseFade), value: movesShown)
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
            isMoving = false
            guard MotionArtwork.isEnabled, Self.leavesMusicAlone(isDisplay: model.isDisplay), let track else { return }
            #if DEBUG
            if let test = Self.testVideo(for: track) {
                // `-motionArtworkTestDelay <seconds>`: as if the lookup took that long, to try a
                // lookup that answers after the page has slid in.
                let args = ProcessInfo.processInfo.arguments
                if let d = args.firstIndex(of: "-motionArtworkTestDelay"), d + 1 < args.count, let seconds = Double(args[d + 1]) {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                }
                MotionArtworkAhead.shared.remember(test, for: track)
                if test == nil { onWontShow() }
                found = test.map { Found(url: $0, trackID: track.id) }
                return
            }
            #endif
            guard let lookup = catalog.motionArtwork else { return }
            var video = await lookup.videoURL(for: track)
            // Once more a moment later: a failed lookup isn't remembered, but nothing asks again
            // until the song changes, so one hiccup cost the whole song. An album known to have
            // none answers from the lookup's memory.
            if video == nil {
                guard !Task.isCancelled else { return }
                onWontShow()
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                video = await lookup.videoURL(for: track)
            }
            guard !Task.isCancelled else { return }
            motionLog("lookup \"\(track.title)\" (\(track.id), album \(track.albumID ?? "unknown")): \(video?.absoluteString ?? "none")")
            MotionArtworkAhead.shared.remember(video, for: track)
            found = video.map { Found(url: $0, trackID: track.id) }
        }
        // A video that hasn't shown a while after it started (a stream that stalls) gives the
        // equalizer bars back; they go again if it shows after all.
        .task(id: url) {
            guard url != nil else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, !isShowing else { return }
            motionLog("not showing \"\(track?.title ?? "nothing")\" 10 s after it started")
            onWontShow()
        }
        // Started from here, not from the task: the task holds this view as it was when the song
        // changed, so `waits` there could still say the page was sliding in. A lookup that
        // answered after the page landed then never started its video.
        .onChange(of: found) { startIfReady() }
        .onChange(of: waits) { startIfReady() }
        .onChange(of: isShowing) { _, showing in onShowing(showing) }
        // Low Power Mode: the video fades out to the still art and goes; it comes back without.
        .onChange(of: LowPowerMode.shared.isOn) { _, lowPower in
            guard lowPower else {
                // Back before it had gone: it fades back in.
                if url != nil { withAnimation(.easeIn(duration: 0.8)) { isShowing = true } }
                startIfReady()
                return
            }
            onWontShow()
            withAnimation(.easeOut(duration: 0.8)) { isShowing = false } completion: {
                if LowPowerMode.shared.isOn { url = nil }
            }
        }
    }

    private func startIfReady() {
        guard url == nil else { return }
        guard let found else {
            motionLog("not starting \"\(track?.title ?? "nothing")\": no video (yet)")
            return
        }
        if waits {
            motionLog("not starting \"\(track?.title ?? "nothing")\": waits (sliding, or not the song playing)")
        } else if LowPowerMode.shared.isOn {
            motionLog("not starting \"\(track?.title ?? "nothing")\": Low Power Mode")
        } else {
            url = found.url
        }
    }

    /// A video found, and the song it's for: a new song with the same video is still a change.
    private struct Found: Equatable {
        let url: URL
        let trackID: QueueTrack.ID
    }
}

/// Whether a song's animated art will show, known before its page slides in: Now Playing leaves
/// the equalizer bars out of a song with video from the slide's first frame, rather than showing
/// them as it arrives and fading them out when the video starts. Filled by looking up the next
/// songs ahead (`lookAhead`; only the lookup, not the video) and by `MotionArtworkView`'s own.
@MainActor
final class MotionArtworkAhead {
    static let shared = MotionArtworkAhead()

    /// Track id → its video, or nil when it has none (or the lookup failed). Not there: not
    /// known yet.
    private var videos: [QueueTrack.ID: URL?] = [:]

    /// True when the song's video was found, motion artwork can show here and Low Power Mode is
    /// off; false when it can't show; nil when that isn't known yet.
    func willShow(_ track: QueueTrack?, isDisplay: Bool) -> Bool? {
        guard let track, Self.allowed(isDisplay: isDisplay) else { return false }
        guard let known = videos[track.id] else { return nil }
        return known != nil
    }

    func remember(_ video: URL?, for track: QueueTrack) {
        videos[track.id] = .some(video)
    }

    /// Looks up the videos of the next songs. One known to have a video isn't asked again; the
    /// others are (`MotionArtworkLookup` answers an album known to have none from memory, and a
    /// failed lookup gets another go).
    func lookAhead(_ tracks: [QueueTrack], catalog: any MusicCatalog, isDisplay: Bool) async {
        for track in tracks where (videos[track.id] ?? nil) == nil {
            guard Self.allowed(isDisplay: isDisplay), !Task.isCancelled else { return }
            #if DEBUG
            if let test = MotionArtworkView.testVideo(for: track) {
                remember(test, for: track)
                continue
            }
            #endif
            // Apple Music catalog songs only, as `MotionArtworkLookup` itself checks.
            guard MotionArtwork.isCatalogID(track.id), let lookup = catalog.motionArtwork else { continue }
            let video = await lookup.videoURL(for: track)
            remember(video, for: track)
        }
    }

    private static func allowed(isDisplay: Bool) -> Bool {
        MotionArtwork.isEnabled && MotionArtworkView.leavesMusicAlone(isDisplay: isDisplay) && !LowPowerMode.shared.isOn
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
    /// Called when the video starts moving (true) and when it stops (false).
    let onMoving: @MainActor (Bool) -> Void
    /// Called once, when the first frame is ready to show.
    let onReady: @MainActor () -> Void
    /// Called once if the video can't play.
    let onFailed: @MainActor () -> Void

    func makeUIView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        view.onMoving = onMoving
        view.start(url: url, pixels: pixels, onReady: onReady, onFailed: onFailed)
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
    private var looperObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var onReady: (@MainActor () -> Void)?
    private var onFailed: (@MainActor () -> Void)?
    var onMoving: (@MainActor (Bool) -> Void)?
    /// Whether we want it playing (`setActive`), for the debug log.
    private var wantsToPlay = false
    /// False until the player is cut off from the audio session; `setActive` meanwhile only
    /// remembers what it was asked (`requested`).
    private var canPlay = false
    private var requested = (active: false, playing: false)

    func start(url: URL, pixels: CGFloat, onReady: @escaping @MainActor () -> Void, onFailed: @escaping @MainActor () -> Void) {
        self.onReady = onReady
        self.onFailed = onFailed
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
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        looperObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let error = looper.error.map { String(describing: $0) } ?? "no error"
            Task { @MainActor [weak self] in self?.failOnce(error) }
        }
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

    /// `active` false (the app's in the background, or the video can't be seen) stops it at once.
    /// Otherwise it follows the music: `animated`, a pause lets it keep moving while it fades to
    /// the still art (`MotionArtworkView.fadesWhilePaused`), then stops it. (Easing the rate down
    /// instead stuttered on busy artwork at every length tried.)
    func setActive(_ active: Bool, playing: Bool, animated: Bool) {
        requested = (active, playing)
        guard let player, canPlay else { return }
        let wanted = active && playing
        guard wanted != wantsToPlay || !animated else { return }
        wantsToPlay = wanted
        pauseTimer?.invalidate()
        pauseTimer = nil
        motionLog("\(wanted ? "play" : "pause") at \(String(format: "%.3f", player.currentTime().seconds)) s (active: \(active), music playing: \(playing))")
        if wanted {
            player.play()
        } else if animated, active, MotionArtworkView.fadesWhilePaused {
            pauseTimer = Timer.scheduledTimer(withTimeInterval: MotionArtworkView.pauseFade, repeats: false) { [weak self] _ in
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

    private func statusChanged(_ player: AVPlayer) {
        let status = switch player.timeControlStatus {
        case .paused: "paused"
        case .playing: "playing"
        case .waitingToPlayAtSpecifiedRate: "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: "unknown"
        }
        motionLog("video \(status), rate \(player.rate), at \(String(format: "%.3f", player.currentTime().seconds)) s, wants to play: \(wantsToPlay)")
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
        looperObservation?.invalidate()
        looperObservation = nil
        onReady = nil
        onFailed = nil
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

    private func failOnce(_ error: String) {
        guard let onFailed else { return }
        self.onFailed = nil
        motionLog("video failed: \(error)")
        onFailed()
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
