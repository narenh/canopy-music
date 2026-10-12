import CanopyCore
import CanopyServer
@preconcurrency import MusicKit
import Security
import SwiftUI
import UIKit

/// Canopy Music on Apple TV. Every launch shows the zone list. "Create a new zone" makes this TV
/// the hub (Apple Music), run entirely from hosts' phones; choosing a zone shows it as a display.
/// See docs/multi-device.md.
@main
struct CanopyTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
@Observable
final class TVModel {
    enum Role: Equatable { case choosing, hub, display }

    private(set) var role: Role = .choosing
    private(set) var session: PartySession
    let browser = ZoneBrowser()
    private(set) var guestURL: URL?
    private(set) var friendlyURL: URL?
    private(set) var hostURL: URL?
    /// The hub's party starts once a phone has taken Host Control from the start screen.
    private(set) var hostJoined = false
    private(set) var authorizationDenied = false
    /// Display mode.
    private(set) var connection: ZoneConnection?
    private(set) var shownZone: ZoneListing?

    @ObservationIgnored let deviceID: String
    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    @ObservationIgnored private var hostname = FriendlyHostname(name: "music")
    @ObservationIgnored private let advertiser = ZoneAdvertiser()
    @ObservationIgnored private var hostKey = TVModel.newKey()
    @ObservationIgnored private let defaults = UserDefaults.standard

    var zoneName: String {
        get { defaults.string(forKey: "zoneName") ?? UIDevice.current.name }
        set { defaults.set(newValue, forKey: "zoneName") }
    }

    /// Demo songs instead of Apple Music: the simulator can't play Apple Music.
    private var usesDemo: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    init() {
        if let id = UserDefaults.standard.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "deviceID")
        }
        session = PartySession(catalog: DemoOrEmptyCatalog(), engine: SilentEngine())
    }

    // MARK: Hub

    func createZone() async {
        if !usesDemo {
            let status = await MusicAuthorization.request()
            authorizationDenied = status != .authorized
            guard status == .authorized else { return }
        }
        let store = URL.applicationSupportDirectory.appending(path: "tv-party.json")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if usesDemo {
            #if DEBUG
            session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine(), storeURL: store)
            #endif
        } else {
            let cache = SongCache()
            session = PartySession(catalog: AppleMusicCatalog(cache: cache), engine: AppleMusicEngine(cache: cache), storeURL: store)
        }
        hostKey = Self.newKey()
        hostJoined = false
        session.configureHub(kind: .tv, zoneName: zoneName, serviceName: usesDemo ? "Demo" : "Apple Music")
        session.hostKey = hostKey
        session.onHostPhone = { [weak self] _ in
            guard let self, !self.hostJoined else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self.hostJoined = true }
        }
        session.onSettingsChanged = { [weak self] in
            guard let self, let name = self.session.zoneName else { return }
            self.zoneName = name
            self.advertise()
        }
        session.onStopRequested = { [weak self] in self?.stopZone() }
        UIApplication.shared.isIdleTimerDisabled = true
        role = .hub
        await startServer()
    }

    func stopZone() {
        if session.isPlaying { session.pause() }
        serverTask?.cancel()
        serverTask = nil
        let server = server
        Task { await server?.stop() }
        self.server = nil
        hostname.unregister()
        advertiser.stop()
        guestURL = nil
        friendlyURL = nil
        hostURL = nil
        hostJoined = false
        role = .choosing
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The remote's play/pause button: always on a hub; on a display, if its hub allows it.
    func playPause() {
        guard role == .hub || session.displaysCanControl else { return }
        Task { await session.togglePlayPause() }
    }

    private func startServer() async {
        guard let (server, task) = await PartyServer.start(session: session) else { return }
        self.server = server
        serverTask = task
        guard let ip = LocalNetwork.lanAddress() else { return }
        guestURL = server.url(host: ip)
        if hostname.register(address: ip) {
            friendlyURL = server.url(host: hostname.hostname)
            session.guestAddress = hostname.hostname + (server.port == 80 ? "" : ":\(server.port)")
        }
        session.lanAddress = ip + (server.port == 80 ? "" : ":\(server.port)")
        hostURL = guestURL.flatMap { URL(string: "\($0.absoluteString)/?host=\(hostKey)") }
        #if DEBUG
        print("[tv] host \(hostURL?.absoluteString ?? "-")")
        #endif
        advertise()
    }

    /// Announces this zone; called again when the song or name changes.
    func advertise() {
        guard role == .hub, let server, let address = session.lanAddress else { return }
        let playing = session.state.current.map { "\($0.track.title) – \($0.track.artist)" } ?? ""
        advertiser.advertise(name: zoneName, port: server.port, txt: [
            "name": zoneName, "kind": HubKind.tv.rawValue, "addr": address, "hub": deviceID, "playing": String(playing.prefix(120)),
        ])
    }

    // MARK: Display

    func show(_ zone: ZoneListing) {
        guard let url = zone.baseURL else { return }
        let connection = ZoneConnection(baseURL: url, clientID: deviceID, name: UIDevice.current.name, kind: .tv)
        let mirror = PartySession(remote: connection)
        session = mirror
        connection.start(session: mirror)
        self.connection = connection
        shownZone = zone
        role = .display
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func leave() {
        connection?.stop()
        connection = nil
        shownZone = nil
        session = PartySession(catalog: DemoOrEmptyCatalog(), engine: SilentEngine())
        role = .choosing
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The display's guest QR points at its hub.
    var shownGuestURL: URL? {
        role == .display ? session.lanAddress.flatMap { URL(string: "http://\($0)") } : guestURL
    }
    var shownFriendlyURL: URL? {
        role == .display ? session.guestAddress.flatMap { URL(string: "http://\($0)") } : friendlyURL
    }

    private static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Placeholders while no zone is running.
struct DemoOrEmptyCatalog: MusicCatalog {
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [] }
}

@MainActor
final class SilentEngine: PlaybackEngine {
    let canReplaceStaged = true
    let isPlaying = false
    let currentTime: TimeInterval = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    func play(_ track: QueueTrack) async throws {}
    func stage(_ track: QueueTrack?) async throws {}
    func resume() async throws {}
    func pause() {}
    func skipToStaged() async throws {}
    func restartCurrent() {}
    func seek(to time: TimeInterval) {}
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}
}
