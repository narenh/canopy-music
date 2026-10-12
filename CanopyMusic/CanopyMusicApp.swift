import CanopyMusicCore
import SwiftUI
import UIKit

// UIKit lifecycle so the root view controller can lock the scene to landscape. On iPadOS 26+,
// Info.plist orientations alone don't stop rotation for resizable apps; the root view controller
// has to ask for the lock (`prefersInterfaceOrientationLocked`).

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @MainActor let model = AppModel()

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Capture.isOn ? .portrait : .landscape
    }
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

/// `-capture` (debug builds): runs in portrait and draws the landscape UI turned 90°, so the
/// simulator (which this Mac can't rotate) produces full-resolution landscape screenshots once
/// the image is turned back.
enum Capture {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-capture")
        #else
        false
        #endif
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var wasBackgrounded = false

    @MainActor private var model: AppModel { (UIApplication.shared.delegate as! AppDelegate).model }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = RootView(model: model)
        window.rootViewController = LandscapeHostingController(rootView: Capture.isOn ? AnyView(CaptureRotated { root }) : AnyView(root))
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let windowScene = scene as? UIWindowScene, !Capture.isOn {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
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

/// Landscape only, and asks iPadOS to lock rotation once it's in landscape.
final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Capture.isOn ? .portrait : .landscape }

    override var prefersInterfaceOrientationLocked: Bool {
        view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersInterfaceOrientationLocked()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
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
        let current = model.session.state.current
        let takeover = current.flatMap { item -> (QueueItem, [LyricsEasterEgg.Line])? in
            guard !Capture.isOn, easterEgg.matches(item.track), easterEgg.dismissedItemID != item.id,
                  let lines = easterEgg.lines else { return nil }
            return (item, lines)
        }
        Group {
            switch model.zoneRole {
            case .choosing:
                ZoneListView()
                    .transition(.opacity)
            case .creating:
                CreateZoneView()
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
        .animation(.easeInOut(duration: 0.6), value: takeover?.0.id)
        .task(id: current?.id) {
            model.zoneSongChanged()
            if let current, easterEgg.matches(current.track) { await easterEgg.loadIfNeeded() }
        }
        .environment(model)
        .task {
            await model.startServerIfNeeded()
            #if DEBUG
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
            }
            // `-autoLoad` loads the first demo playlist without playing, for host-screen screenshots.
            if ProcessInfo.processInfo.arguments.contains("-autoLoad"), model.isDemo,
               let first = try? await model.session.catalog.libraryPlaylists().first {
                await model.load(first)
            }
            // `-autoResume` resumes a restored party, for testing playback without touching the iPad.
            if ProcessInfo.processInfo.arguments.contains("-autoResume") {
                await model.play()
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
            // `-autoParty` starts a demo party and locks, for screenshots and UI work in the simulator.
            if ProcessInfo.processInfo.arguments.contains("-autoParty"), model.isDemo {
                if model.session.state.current == nil, let first = try? await model.session.catalog.libraryPlaylists().first {
                    await model.load(first)
                }
                await model.play()
                model.lock()
            }
            #endif
        }
    }

    /// Today's single-device app: setup, host mode and the party screen.
    @ViewBuilder private var hubContent: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else if model.isLocked {
                PartyView()
                    .transition(.opacity)
            } else {
                HostView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.isLocked)
        .animation(.easeInOut(duration: 0.5), value: model.needsOnboarding)
        .tint(model.provider.accent)
    }
}
