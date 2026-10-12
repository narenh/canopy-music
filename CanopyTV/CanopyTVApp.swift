import CanopyCore
import CanopyServer
import Security
import SwiftUI
import UIKit

/// Canopy on Apple TV (spike): the TV shows the party; phones do everything else through the
/// guest page and Host Control. Plays demo songs for now.
@main
struct CanopyTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}

@MainActor
@Observable
final class TVModel {
    let session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine())
    private(set) var guestURL: URL?
    private(set) var friendlyURL: URL?
    private(set) var hostURL: URL?
    /// The party starts once a phone has taken host control from the launch QR code.
    private(set) var hostJoined = ProcessInfo.processInfo.arguments.contains("-skipHostQR")

    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    // Not music.local, so it doesn't clash with the iPad app while both exist.
    @ObservationIgnored private let hostname = FriendlyHostname(name: "canopy-tv")
    @ObservationIgnored private let hostKey: String = {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }()

    func start() async {
        UIApplication.shared.isIdleTimerDisabled = true
        session.hostKey = hostKey
        session.onHostPhone = { [weak self] _ in
            guard let self, !self.hostJoined else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self.hostJoined = true }
            Task { try? await self.session.play() }
        }
        if let playlist = try? await DemoCatalog().libraryPlaylists().first {
            try? await session.load(playlist: playlist)
        }
        if hostJoined { try? await session.play() }

        guard let (server, task) = await PartyServer.start(session: session) else { return }
        self.server = server
        serverTask = task
        guard let ip = LocalNetwork.lanAddress() else { return }
        guestURL = server.url(host: ip)
        if hostname.register(address: ip) {
            friendlyURL = server.url(host: hostname.hostname)
            session.guestAddress = hostname.hostname + (server.port == 80 ? "" : ":\(server.port)")
        }
        hostURL = guestURL.flatMap { URL(string: "\($0.absoluteString)/?host=\(hostKey)") }
        print("[tv] guest \(guestURL?.absoluteString ?? "-") host \(hostURL?.absoluteString ?? "-")")
    }
}
