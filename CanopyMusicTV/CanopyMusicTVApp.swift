import CanopyMusicCore
import CanopyMusicServer
@preconcurrency import MusicKit
import Security
import SwiftUI
import UIKit

/// Canopy Music on Apple TV. Every launch shows the zone list. "Create a new zone" makes this TV
/// the hub (Apple Music), run entirely from hosts' phones; choosing a zone shows it as a display.
/// See docs/multi-device.md.
@main
struct CanopyMusicTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-playTest") {
                TVPlayTestView()
            } else {
                TVRootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
            #else
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
            #endif
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
    /// The "Scan to host" link: the guest page plus the Host Control key.
    var hostURL: URL? {
        guestURL.flatMap { URL(string: "\($0.absoluteString)/?host=\(hostControl.key)") }
    }
    /// The hub's party starts once a phone has taken Host Control from the start screen.
    private(set) var hostJoined = false
    private(set) var authorizationDenied = false
    /// Display mode.
    private(set) var connection: ZoneConnection?
    private(set) var shownZone: ZoneListing?

    @ObservationIgnored let deviceID: String
    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    /// The `.local` address, which follows the zone name (as on the iPad).
    @ObservationIgnored private let hostname = FriendlyHostname(name: "music")
    @ObservationIgnored private let advertiser = ZoneAdvertiser()
    /// The Host Control key and the phones that have used it (shared with the iPad app).
    let hostControl = HostControl()
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
        debugLog("createZone")
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
        hostJoined = false
        hostname.rename(to: FriendlyHostname.localName(forZone: zoneName))
        session.configureHub(kind: .tv, zoneName: zoneName, serviceName: usesDemo ? "Demo" : "Apple Music")
        // Same settings, saved under the same names, as an iPad hub.
        session.phonesCanQueue = defaults.object(forKey: "phoneQueueEnabled") as? Bool ?? true
        session.phonesCanReorder = defaults.object(forKey: "phoneReorderEnabled") as? Bool ?? true
        session.displaysCanControl = defaults.object(forKey: "displaysCanControl") as? Bool ?? true
        session.wifi = WifiDetails(ssid: defaults.string(forKey: "wifiSSID") ?? "", password: defaults.string(forKey: "wifiPassword") ?? "",
                                   simpleQR: defaults.bool(forKey: "wifiSimpleQR"))
        hostControl.attach(to: session) { [weak self] _ in
            guard let self, !self.hostJoined else { return }
            withAnimation(.easeInOut(duration: 0.8)) { self.hostJoined = true }
        }
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.session.phonesCanQueue, forKey: "phoneQueueEnabled")
            self.defaults.set(self.session.phonesCanReorder, forKey: "phoneReorderEnabled")
            self.defaults.set(self.session.displaysCanControl, forKey: "displaysCanControl")
            self.defaults.set(self.session.wifi.ssid, forKey: "wifiSSID")
            self.defaults.set(self.session.wifi.password, forKey: "wifiPassword")
            self.defaults.set(self.session.wifi.simpleQR, forKey: "wifiSimpleQR")
            if let name = self.session.zoneName { self.zoneName = name }
            self.followZoneName()
            self.advertise()
        }
        session.onStopRequested = { [weak self] in self?.stopZone() }
        UIApplication.shared.isIdleTimerDisabled = true
        role = .hub
        // Not tied to the caller: the zone list (and any task it started) goes away right here.
        await Task { await self.startServer() }.value
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
        hostJoined = false
        role = .choosing
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// A renamed zone announces its new `.local` name, handed out once it's confirmed.
    private func followZoneName() {
        guard hostname.rename(to: FriendlyHostname.localName(forZone: zoneName)) else { return }
        friendlyURL = nil
        session.guestAddress = nil
    }

    /// The remote's play/pause button: always on a hub; on a display, if its hub allows it.
    func playPause() {
        guard role == .hub || session.displaysCanControl else { return }
        Task { await session.togglePlayPause() }
    }

    private func startServer() async {
        debugLog("starting server")
        guard let (server, task) = await PartyServer.start(session: session) else {
            debugLog("server failed to start")
            return
        }
        debugLog("server on \(server.port)")
        self.server = server
        serverTask = task
        guard let ip = LocalNetwork.lanAddress() else { return }
        guestURL = server.url(host: ip)
        // Hand out the .local name only once it's confirmed ours: another zone may already have
        // it, and this follows the name we end up with (and the zone's new name after a rename).
        hostname.onConfirmed = { [weak self] name in
            guard let self, let server = self.server else { return }
            self.friendlyURL = server.url(host: name)
            self.session.guestAddress = name + (server.port == 80 ? "" : ":\(server.port)")
        }
        hostname.register(address: ip)
        session.lanAddress = ip + (server.port == 80 ? "" : ":\(server.port)")
        #if DEBUG
        print("[tv] host \(hostURL?.absoluteString ?? "-")")
        debugLog("host \(hostURL?.absoluteString ?? "-")")
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

    /// The "Join Wi‑Fi" code next to the guest QR: this hub's Wi‑Fi, set by a host on the web page.
    /// A display doesn't know its hub's (as on the iPad).
    var wifiPayload: String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fakeWifi") {
            return LocalNetwork.wifiJoinPayload(ssid: "Canopy Guest", password: "summer-party-2026")
        }
        #endif
        guard role == .hub, !session.wifi.ssid.isEmpty else { return nil }
        return LocalNetwork.wifiJoinPayload(ssid: session.wifi.ssid, password: session.wifi.password)
    }

    /// A display that isn't connected to its hub (yet, or any more).
    var isWaitingForHub: Bool {
        role == .display && connection.map { !$0.isConnected } == true
    }

    /// The display's guest QR points at its hub.
    var shownGuestURL: URL? {
        role == .display ? session.lanAddress.flatMap { URL(string: "http://\($0)") } : guestURL
    }
    var shownFriendlyURL: URL? {
        role == .display ? session.guestAddress.flatMap { URL(string: "http://\($0)") } : friendlyURL
    }

    /// Debug builds: appends to Library/Caches/tv.log (the simulator's console capture is unreliable).
    func debugLog(_ line: String) {
        #if DEBUG
        let url = URL.cachesDirectory.appending(path: "tv.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        #endif
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
