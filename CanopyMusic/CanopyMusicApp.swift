import SwiftUI

@main
struct CanopyMusicApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    var body: some Scene {
        WindowGroup {
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
            .environment(model)
            .task {
                await model.startServerIfNeeded()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-diagnoseMusicKit") {
                    await model.diagnoseMusicKit()
                }
                print("[debug] guest URL \(model.guestURL?.absoluteString ?? "none")")
                // `-autoResume` resumes a restored party, for testing playback without touching the iPad.
                if ProcessInfo.processInfo.arguments.contains("-autoResume") {
                    await model.play()
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
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasBackgrounded = true
                case .active:
                    // iOS tears down listening sockets while suspended; bring the phone server back.
                    if wasBackgrounded {
                        wasBackgrounded = false
                        Task { await model.restartServer() }
                    } else {
                        model.refreshAddresses()
                    }
                default:
                    break
                }
            }
        }
    }
}
