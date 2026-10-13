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
        .landscape
    }
}

/// `-capture` (debug builds): screenshot mode (no easter-egg takeover, no demo button). In a
/// portrait simulator (which this Mac can't rotate) iPadOS shows the landscape-only app
/// letterboxed and scaled down, so take full-resolution landscape screenshots with
/// `WindowSnapshot` rather than `simctl io screenshot`.
enum Capture {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-capture")
        #else
        false
        #endif
    }
}

#if DEBUG
/// `xcrun simctl spawn <sim> notifyutil -p com.canopysf.CanopyMusic.snapshot` writes the window,
/// at full resolution, to Library/Caches/snapshot.png.
@MainActor enum WindowSnapshot {
    private static weak var window: UIWindow?

    static func listen(_ window: UIWindow) {
        self.window = window
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in WindowSnapshot.write() }
        }, "com.canopysf.CanopyMusic.snapshot" as CFString, nil, .deliverImmediately)
    }

    private static func write() {
        guard let window else { return }
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("snapshot.png")
        try? image.pngData()?.write(to: url)
        print("[debug] snapshot \(Int(bounds.width))x\(Int(bounds.height)) @\(window.screen.scale)x → \(url.path)")
    }
}
#endif

/// The window can be resized (iPadOS windowing, and on a Mac), but never smaller than the
/// two-column layouts need.
enum WindowSize {
    static let minimum = CGSize(width: 1024, height: 700)

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
        window.rootViewController = LandscapeHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
        #if DEBUG
        WindowSnapshot.listen(window)
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let windowScene = scene as? UIWindowScene {
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
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

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
        let takeover = Capture.isOn ? nil : easterEgg.takeover(for: current)
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
        .animation(.easeInOut(duration: 0.6), value: takeover?.item.id)
        .task(id: current?.id) {
            model.zoneSongChanged()
            if let current, easterEgg.matches(current.track) { await easterEgg.loadIfNeeded() }
        }
        .environment(model)
        .task {
            await model.startOnLaunch()
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
