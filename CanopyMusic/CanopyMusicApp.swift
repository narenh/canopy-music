import CanopyCore
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

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var wasBackgrounded = false

    @MainActor private var model: AppModel { (UIApplication.shared.delegate as! AppDelegate).model }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = LandscapeHostingController(rootView: RootView(model: model))
        window.makeKeyAndVisible()
        self.window = window
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

    var body: some View {
        let current = model.session.state.current
        let takeover = current.flatMap { item -> (QueueItem, [LyricsEasterEgg.Line])? in
            guard easterEgg.matches(item.track), easterEgg.dismissedItemID != item.id,
                  let lines = easterEgg.lines else { return nil }
            return (item, lines)
        }
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
            if let current, easterEgg.matches(current.track) { await easterEgg.loadIfNeeded() }
        }
        .environment(model)
        .task {
            await model.startServerIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-diagnoseMusicKit") {
                await model.diagnoseMusicKit()
            }
            print("[debug] guest URL \(model.guestURL?.absoluteString ?? "none")")
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
}
