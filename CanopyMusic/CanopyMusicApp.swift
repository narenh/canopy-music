import CanopyMusicCore
import CanopyMusicServer
import SwiftUI
import UIKit

// UIKit lifecycle (a scene delegate) so the window scene can be given a minimum size.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @MainActor let model = AppModel()
}

/// Lays `content` out at the landscape size and turns it 90° to fill a portrait screen.
struct CaptureRotated<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.height, height: geo.size.width)
                .rotationEffect(.degrees(90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
        // The portrait status bar and home indicator would end up on the side once turned.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// `-capture` (debug builds): screenshot mode (no easter-egg takeover, no demo button). In a
/// portrait simulator (which this Mac can't rotate) it draws the landscape UI turned 90°, so
/// `simctl io screenshot` gives full-resolution landscape screenshots once the image is turned back.
enum Capture {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-capture")
        #else
        false
        #endif
    }
}

/// The window can be resized (iPadOS windowing, and on a Mac), but never smaller than the
/// two-column layouts need: an iPad mini's portrait width (744 pt), and the height Create Zone's
/// PIN step needs.
enum WindowSize {
    static let minimum = CGSize(width: 744, height: 700)

    @MainActor static func restrict(_ scene: UIWindowScene) {
        scene.sizeRestrictions?.minimumSize = minimum
        #if DEBUG
        // `-windowSize 1512x982`: pins the window to that size (Mac, iPadOS windowing), for
        // checking layouts at sizes no iPad has.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-windowSize"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                let size = CGSize(width: parts[0], height: parts[1])
                scene.sizeRestrictions?.minimumSize = size
                scene.sizeRestrictions?.maximumSize = size
            }
        }
        #endif
    }

    /// `-canvas 1728x1117` (debug builds): lays the app out at that size and scales it to fit the
    /// screen, so the simulator shows layouts for window sizes no iPad has (a Mac's full screen).
    static var canvas: CGSize? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-canvas"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        #else
        nil
        #endif
    }
}

/// On a Mac the window can grow past any iPad: each screen's content stops at 1800×1200 pt
/// (1200×1800 in a portrait window) and stays in the middle, while the screen's background, drawn
/// outside this, still fills the window. No iPad reaches it in either orientation (a 13" is
/// 1376×1032 pt), so iPads are unaffected.
struct ContentCap: Layout {
    static let long: CGFloat = 1800
    static let short: CGFloat = 1200

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let landscape = bounds.width >= bounds.height
        let size = CGSize(width: min(bounds.width, landscape ? Self.long : Self.short),
                          height: min(bounds.height, landscape ? Self.short : Self.long))
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
        }
    }
}

/// Lays `content` out at `size`, scaled down if it doesn't fit (see `WindowSize.canvas`).
struct CanvasScaled<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: size.width, height: size.height)
                .clipped()
                .scaleEffect(min(1, geo.size.width / size.width, geo.size.height / size.height))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(.black)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var wasBackgrounded = false

    @MainActor private var model: AppModel { (UIApplication.shared.delegate as! AppDelegate).model }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        WindowSize.restrict(windowScene)
        let window = UIWindow(windowScene: windowScene)
        let app = AnyView(RootView(model: model))
        let root = WindowSize.canvas.map { size in AnyView(CanvasScaled(size: size) { app }) } ?? app
        window.rootViewController = UIHostingController(rootView: Capture.isOn ? AnyView(CaptureRotated { root }) : root)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // iOS tears down listening sockets while suspended; bring the phone server back.
        if wasBackgrounded {
            wasBackgrounded = false
            Task { await model.restartServer() }
        } else {
            model.refreshAddresses()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        wasBackgrounded = true
    }
}

struct RootView: View {
    let model: AppModel
    @State private var easterEgg = LyricsEasterEgg()

    /// `-qrGallery` covers the app with QR design variants (debug builds only).
    @ViewBuilder private var debugOverlay: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qrGallery") { QRGallery() }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-backgroundFor"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            BackgroundPreview(term: ProcessInfo.processInfo.arguments[i + 1])
        }
        #endif
    }

    var body: some View {
        // What's actually playing (in a Spotify zone, possibly a track from outside the queue).
        let current = model.session.nowPlaying
        let takeover = Capture.isOn ? nil : easterEgg.takeover(for: current)
        Group {
            switch model.zoneRole {
            case .choosing:
                ZoneListView()
                    .transition(.opacity)
            case .creating:
                // First-run setup: the service, then the zone's name and PIN.
                Group {
                    if model.needsOnboarding {
                        OnboardingView()
                    } else {
                        CreateZoneView()
                    }
                }
                .transition(.opacity)
            case .display:
                PartyView()
                    .transition(.opacity)
            case .hub:
                hubContent
            }
        }
        .overlay { debugOverlay }
        .animation(.easeInOut(duration: 0.4), value: model.zoneRole)
        .animation(.easeInOut(duration: 0.4), value: model.isLocked)
        .animation(.easeInOut(duration: 0.5), value: model.needsOnboarding)
        .tint(model.provider.accent)
        .overlay {
            if let (item, lines) = takeover {
                TakeoverView(lines: lines, track: item.track, session: model.session) {
                    easterEgg.dismissedItemID = item.id
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: takeover?.item.id)
        // Spotify plays one stream per account: another zone already on this device's account
        // asks at Start (and Resume, or the restore at launch) (`AppModel.spotifyConflict`).
        .alert("Another zone is using this Spotify account",
               isPresented: Binding(get: { model.spotifyConflict != nil }, set: { _ in }),
               presenting: model.spotifyConflict) { _ in
            Button("Cancel", role: .cancel) { model.cancelSpotifyConflict() }
            Button("Join") { model.joinSpotifyConflict() }
        } message: { conflict in
            Text("End \(conflict.zone.name) to start a new one from here, or join it as a display.")
        }
        .task(id: current?.id) {
            model.zoneSongChanged()
            if let current, easterEgg.matches(current.track) { await easterEgg.loadIfNeeded() }
        }
        .environment(model)
        // Unnamed requests from a Mac hub are labelled with the kind of Mac, not "iPad".
        .environment(\.hubDeviceNoun, MacKind(wire: model.session.hubDevice)?.noun ?? "iPad")
        .task {
            await model.startOnLaunch()
            #if DEBUG
            DeviceKind.logRawValues()
            if ProcessInfo.processInfo.arguments.contains("-diagnoseMusicKit") {
                await model.diagnoseMusicKit()
            }
            // `-benchAppleMusic` times playlist loading without touching the chosen service.
            if ProcessInfo.processInfo.arguments.contains("-benchAppleMusic") {
                await AppleMusicCatalog.benchmark()
            }
            // `-diagnosePlaylist <name>` writes Library/Caches/playlist-diagnosis.txt.
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-diagnosePlaylist"), i + 1 < ProcessInfo.processInfo.arguments.count {
                await AppleMusicCatalog.diagnosePlaylist(named: ProcessInfo.processInfo.arguments[i + 1])
            }
            print("[debug] guest URL \(model.guestURL?.absoluteString ?? "none")")
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-screenshotParty"), i + 1 < args.count, let scene = ScreenshotScene.all[args[i + 1]] {
                let tracks = await scene.resolve(with: AppleMusicCatalog(cache: SongCache()))
                let session = PartySession(catalog: FixedCatalog(tracks: tracks), engine: PosedEngine(time: scene.time))
                try? await session.load(playlist: PlaylistSummary(id: "screenshot", name: "2026 June", kind: .library))
                try? await session.play()
                model.installScreenshotSession(session)
                ScreenshotHub.pose(model)
            }
            // `-autoLoad` loads the first demo playlist without playing, for host-screen screenshots.
            if ProcessInfo.processInfo.arguments.contains("-autoLoad"), model.isDemo,
               let first = try? await model.session.catalog.libraryPlaylists().first {
                await model.load(first)
            }
            // `-autoLoadPlaylist <id>` loads that demo playlist (e.g. `demo-skips`, which leaves songs out).
            if let i = args.firstIndex(of: "-autoLoadPlaylist"), i + 1 < args.count, model.isDemo,
               let playlist = try? await model.session.catalog.libraryPlaylists().first(where: { $0.id == args[i + 1] }) {
                await model.load(playlist)
            }
            // `-autoResume` presses Start on the saved queue, for testing playback without touching the iPad.
            if ProcessInfo.processInfo.arguments.contains("-autoResume") {
                await model.startZone()
            }
            // `-autoPrevious` presses back 2 s after starting, to test going back on a device.
            if ProcessInfo.processInfo.arguments.contains("-autoPrevious") {
                try? await Task.sleep(for: .seconds(2))
                await model.session.previous()
            }
            // `-autoStress` fires back, back, next without waiting, like quick taps.
            if ProcessInfo.processInfo.arguments.contains("-autoStress") {
                try? await Task.sleep(for: .seconds(4))
                let session = model.session
                Task { await session.previous() }
                Task { await session.previous() }
                Task { await session.skip() }
            }
            // `-autoParty` starts a demo party (Start: live and locked), for screenshots and UI work
            // in the simulator.
            if ProcessInfo.processInfo.arguments.contains("-autoParty"), model.isDemo {
                if model.session.state.current == nil, let first = try? await model.session.catalog.libraryPlaylists().first {
                    await model.load(first)
                }
                await model.startZone()
            }
            // `-autoChangePlaylist <id>` (with `-autoParty`): 8 s into the party, picks that demo
            // playlist as host mode's picker does, to check that the song plays on.
            if let i = args.firstIndex(of: "-autoChangePlaylist"), i + 1 < args.count, model.isDemo {
                try? await Task.sleep(for: .seconds(8))
                if let playlist = try? await model.session.catalog.libraryPlaylists().first(where: { $0.id == args[i + 1] }) {
                    await model.load(playlist)
                }
            }
            // `-fakeSpotifyFollow` poses follow mode (Spotify zones) on the demo party, since
            // Spotify can't be reached from the simulator: a track from outside the queue playing
            // ("From Spotify"), two songs in Spotify's own queue above Up next, and the next song
            // locked. `-fakeSpotifyIssue` shows the host's "Couldn't queue" line instead of the lock.
            // Held for as long as this session lasts (the demo player moving on would clear it).
            if args.contains("-fakeSpotifyFollow"), model.isDemo {
                let session = model.session
                let colors = { (bg: String, sec: String) in ArtworkColors(background: bg, primary: "#FFFFFF", secondary: sec) }
                let external = QueueTrack(id: "spotify:track:fake-external", title: "Espresso", artist: "Sabrina Carpenter",
                                          album: "Short n' Sweet", duration: 175, colors: colors("#5A3A1E", "#E8B07A"))
                let foreign = [
                    QueueTrack(id: "spotify:track:fake-q1", title: "Good Luck, Babe!", artist: "Chappell Roan", duration: 218, colors: colors("#7A1F3D", "#F29BB8")),
                    QueueTrack(id: "spotify:track:fake-q2", title: "Birds of a Feather", artist: "Billie Eilish", duration: 210, colors: colors("#1E3A5A", "#8CB8E8")),
                ]
                let issue = args.contains("-fakeSpotifyIssue") ? "Couldn't queue the next song on Spotify" : nil
                while model.session === session {
                    session.serviceName = "Spotify"
                    session.debugPoseFollow(external: external, foreign: foreign, issue: issue)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            #endif
        }
    }

    /// This device's own zone: the start screen and host mode (`HostView`), and the party screen.
    @ViewBuilder private var hubContent: some View {
        Group {
            if model.isLocked {
                PartyView()
                    .transition(.opacity)
            } else {
                HostView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.isLocked)
        .tint(model.provider.accent)
    }
}
