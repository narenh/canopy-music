import AVFoundation
import CanopyMusicCore
import CanopyMusicServer
@preconcurrency import MusicKit
import Security
import SwiftUI
import UIKit

/// Canopy Music on Apple TV. Launches show the zone list, unless this TV was hosting a zone that
/// wasn't ended (a crash, or a quit by the system): then it goes straight back in. "Create a new
/// zone" makes this TV the hub (Apple Music), run entirely from hosts' phones; choosing a zone
/// shows it as a display. See docs/multi-device.md.
@main
struct CanopyMusicTVApp: App {
    @State private var model = TVModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        scene
            .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }

    private var scene: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-playTest") {
                TVPlayTestView()
            } else {
                TVRootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .task {
                        // `-diagnosePlaylist <name>` (as on the iPad): how a library playlist's songs
                        // map to catalog songs, in Library/Caches/playlist-diagnosis.txt and the console.
                        let args = ProcessInfo.processInfo.arguments
                        if let i = args.firstIndex(of: "-diagnosePlaylist"), i + 1 < args.count {
                            if MusicAuthorization.currentStatus == .notDetermined { _ = await MusicAuthorization.request() }
                            await AppleMusicCatalog.diagnosePlaylist(named: args[i + 1])
                        }
                    }
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
    /// Whether this TV has a zone, and how to come back into it (shared with the iPad app).
    @ObservationIgnored private let zoneRecord = ZoneRecord()
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
        // The app's own audio is only the motion artwork's silent video; the music plays in the
        // Apple Music player's own session. Left at the default (not mixable), the music starting
        // interrupted this session and paused the video. Ambient mixes, so it never is.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        restoreZoneIfNeeded()
    }

    // MARK: Hub

    /// The hub's queue, kept between launches until the zone is ended. In Caches: tvOS doesn't let
    /// apps create Application Support (the simulator does), so saving there silently failed and
    /// no zone came back. The system may clear Caches when storage is low; the zone then ends.
    private static var storeURL: URL { URL.cachesDirectory.appending(path: "tv-party.json") }

    /// This TV has a zone that wasn't ended (and didn't come back by itself at launch): the list
    /// offers to resume it, and creating a new zone asks first.
    var canResumeZone: Bool { zoneRecord.hasZone }

    /// Creates a new, empty zone: "Scan to host", with the server running for the phone that sets
    /// it up, but not announced and not recorded until its music starts (`ZoneRecord.songStarted`).
    /// A zone this TV still had is ended first (the list asked).
    /// Apple Music access isn't asked for here: the host's setup page shows whether the TV can
    /// play Apple Music, and the TV asks for access when that page opens (`checkMusicAccess`).
    func createZone() async {
        debugLog("createZone")
        authorizationDenied = false
        openZone(fresh: true)
        // Not tied to the caller: the zone list (and any task it started) goes away right here.
        await Task { await self.startServer() }.value
    }

    /// Back into the zone this TV had.
    func resumeZone() async {
        debugLog("resumeZone")
        guard await authorize() else { return }
        openZone(fresh: false)
        // Its saved queue is gone (tvOS may clear Caches): back to "Scan to host", with its code,
        // rather than "Continue on your phone".
        if session.isWaitingForSetup {
            zoneRecord.hostJoined = false
            hostJoined = false
        }
        await Task { await self.startServer() }.value
    }

    /// Launch: straight back into the zone if this TV was hosting it when the app quit or crashed.
    /// Music stays paused. If it can't (no Apple Music access, no network), the list offers Resume.
    /// A zone exists only once its music has started, so there's always something to come back to,
    /// except for a zone an older build recorded at Create where music never started, and a zone
    /// whose saved queue tvOS cleared: those are ended, and the TV starts at the zone list.
    private func restoreZoneIfNeeded() {
        zoneRecord.settleStarted(songsPlayed: QueueState.saved(at: Self.storeURL)?.log.isEmpty == false)
        let queueCleared = zoneRecord.hasZone && !FileManager.default.fileExists(atPath: Self.storeURL.path)
        if zoneRecord.endsOnLaunch || queueCleared {
            // As End does. Nothing else is running yet: no server, Bonjour or `.local` name.
            debugLog("nothing to come back to; ending the zone")
            try? FileManager.default.removeItem(at: Self.storeURL)
            zoneRecord.ended()
            return
        }
        guard zoneRecord.restoresOnLaunch, LocalNetwork.lanAddress() != nil,
              usesDemo || MusicAuthorization.currentStatus == .authorized else { return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("-playTest"), !args.contains("-noRestore") else { return }
        #endif
        debugLog("restoring zone")
        #if DEBUG
        TVZoneListView.didAutoCreate = true // `-createZone` is for a launch that starts at the list
        #endif
        openZone(fresh: false)
        Task {
            await startServer()
            if role == .hub, server == nil || guestURL == nil {
                debugLog("restore failed; back to the zone list")
                closeZone()
            }
        }
    }

    private func authorize() async -> Bool {
        guard !usesDemo else { return true }
        let status = await MusicAuthorization.request()
        authorizationDenied = status != .authorized
        return status == .authorized
    }

    /// Makes this TV the hub of its zone: a new, empty one, or the one it had (from the saved queue).
    private func openZone(fresh: Bool) {
        let store = Self.storeURL
        session.shutdown()
        if usesDemo {
            #if DEBUG
            session = PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine(), storeURL: store)
            #endif
        } else {
            let cache = SongCache()
            session = PartySession(catalog: AppleMusicCatalog(cache: cache), engine: AppleMusicEngine(cache: cache), storeURL: store)
        }
        if fresh {
            // The same clearing as End. The new zone is recorded once its music starts.
            session.end()
            zoneRecord.ended()
        } else {
            zoneRecord.resumedHosting()
        }
        // A zone that had a host (or a playlist) is past "Scan to host".
        hostJoined = !fresh && (zoneRecord.hostJoined || session.hasParty || session.state.playlistName != nil)
        hostname.rename(to: FriendlyHostname.localName(forZone: zoneName))
        session.configureHub(kind: .tv, id: deviceID, zoneName: zoneName, serviceName: usesDemo ? "Demo" : "Apple Music")
        // Same settings, saved under the same names, as an iPad hub.
        session.phonesCanQueue = defaults.object(forKey: "phoneQueueEnabled") as? Bool ?? true
        session.phonesCanReorder = defaults.object(forKey: "phoneReorderEnabled") as? Bool ?? true
        session.displaysCanControl = defaults.object(forKey: "displaysCanControl") as? Bool ?? true
        session.screensaverWhilePlaying = defaults.bool(forKey: "screensaverWhilePlaying")
        session.wifi = WifiDetails(ssid: defaults.string(forKey: "wifiSSID") ?? "", password: defaults.string(forKey: "wifiPassword") ?? "",
                                   simpleQR: defaults.bool(forKey: "wifiSimpleQR"))
        hostControl.attach(to: session) { [weak self] _ in
            guard let self, !self.hostJoined else { return }
            self.zoneRecord.hostJoined = true // a zone not recorded yet takes it when it begins
            withAnimation(.easeInOut(duration: 0.8)) { self.hostJoined = true }
        }
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.session.phonesCanQueue, forKey: "phoneQueueEnabled")
            self.defaults.set(self.session.phonesCanReorder, forKey: "phoneReorderEnabled")
            self.defaults.set(self.session.displaysCanControl, forKey: "displaysCanControl")
            self.defaults.set(self.session.screensaverWhilePlaying, forKey: "screensaverWhilePlaying")
            self.defaults.set(self.session.wifi.ssid, forKey: "wifiSSID")
            self.defaults.set(self.session.wifi.password, forKey: "wifiPassword")
            self.defaults.set(self.session.wifi.simpleQR, forKey: "wifiSimpleQR")
            if let name = self.session.zoneName { self.zoneName = name }
            self.followZoneName()
            self.advertise()
        }
        session.onStopRequested = { [weak self] in self?.stopZone() }
        session.onMusicAccessCheck = { [weak self] in self?.checkMusicAccess(asking: true) }
        // The zone becomes real when its music starts (a phone's "Start the music"): only then is
        // it recorded, so only then does it come back after a crash or offer Resume.
        session.onSongStarted = { [weak self] in
            guard let self else { return }
            self.zoneRecord.songStarted(hostJoined: self.hostJoined)
        }
        role = .hub
        // Known before the host's page connects (without asking: that waits for the page).
        checkMusicAccess(asking: false)
    }

    // MARK: Apple Music access

    /// The check under way, and whether another was asked for meanwhile (and if it may ask).
    @ObservationIgnored private var musicCheck: Task<Void, Never>?
    @ObservationIgnored private var musicCheckAgain: Bool?

    /// Works out whether this TV can play Apple Music, for the host setting the zone up on their
    /// phone (`musicAccess` in hosts' snapshots). `asking`: the host's setup page is open, so if
    /// the TV has never asked for Apple Music access, it asks now.
    func checkMusicAccess(asking: Bool) {
        guard role == .hub else { return }
        if musicCheck != nil {
            musicCheckAgain = (musicCheckAgain ?? false) || asking
            return
        }
        musicCheck = Task { [weak self] in
            guard let self else { return }
            let session = self.session
            let access = await self.currentMusicAccess(asking: asking)
            if access != session.musicAccess { self.debugLog("Apple Music access: \(access.rawValue)") }
            session.musicAccess = access
            self.musicCheck = nil
            if let again = self.musicCheckAgain {
                self.musicCheckAgain = nil
                self.checkMusicAccess(asking: again)
            }
        }
    }

    private func currentMusicAccess(asking: Bool) async -> MusicAccess {
        #if DEBUG
        // `-musicAccess ok|notDetermined|denied|noSubscription|error`: what the setup page is told,
        // whatever the TV's own (the simulator can't play Apple Music). `-musicAccessAfterPrompt
        // <status>`: a forced notDetermined becomes that 3 s after the page asks, as if the host
        // had answered the TV's prompt.
        let defaults = UserDefaults.standard
        if let forced = defaults.string(forKey: "musicAccess").flatMap(MusicAccess.init(rawValue:)) {
            if let answered = debugPromptAnswer { return answered }
            if forced == .notDetermined, asking,
               let answer = defaults.string(forKey: "musicAccessAfterPrompt").flatMap(MusicAccess.init(rawValue:)) {
                debugLog("pretending to ask for Apple Music access")
                try? await Task.sleep(for: .seconds(3))
                debugPromptAnswer = answer
                return answer
            }
            return forced
        }
        #endif
        if usesDemo { return .ok }
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined, asking {
            debugLog("asking for Apple Music access")
            status = await MusicAuthorization.request()
        }
        switch status {
        case .authorized: break
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .error
        }
        do {
            let subscription = try await MusicSubscription.current
            if subscription.canPlayCatalogContent {
                // Signed in with a subscription; this also needs the user token and the network.
                try await Self.requestStorefront()
                return .ok
            }
        } catch {
            debugLog("Apple Music check failed: \(String(reflecting: error))")
            return .error
        }
        // No subscription, or no Apple Account signed in at all: the user token says which.
        do {
            try await Self.requestStorefront()
        } catch MusicTokenRequestError.userNotSignedIn {
            debugLog("Apple Music check: no Apple Account signed in")
            return .error
        } catch {
            debugLog("Apple Music check, no subscription: \(String(reflecting: error))")
        }
        return .noSubscription
    }

    #if DEBUG
    @ObservationIgnored private var debugPromptAnswer: MusicAccess?
    #endif

    /// The signed-in account's storefront: needs the developer and user tokens and the network.
    private static func requestStorefront() async throws {
        let url = URL(string: "https://api.music.apple.com/v1/me/storefront")!
        _ = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
    }

    /// Ends the zone (Menu › End, or a host on the web page) and goes back to the zone list: stops
    /// the music, the server, the Bonjour announcement and the `.local` name, and clears the queue
    /// and the saved queue, so the next zone starts empty. Settings and Host Control stay.
    func stopZone() {
        session.end()
        zoneRecord.ended()
        closeZone()
    }

    /// Menu › End offers to save the party once someone has added a song, played or not (and the
    /// service can save); otherwise it's a plain End.
    var canSaveParty: Bool { role == .hub && session.partySaveInfo.offersSave }

    /// The name Menu › End saves under: what the host typed after the party's date, or, left as
    /// just the date, the date and the zone ("2026-10-12 Attic").
    func partyPlaylistName(typed: String) -> String {
        let date = session.partyLog.suggestedName()
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == date.trimmingCharacters(in: .whitespaces) ? date + zoneName : name
    }

    /// Saves the songs guests added (as the web page's default). The caller ends the zone after.
    func saveParty(typedName: String) async throws {
        try await session.savePartyPlaylist(name: partyPlaylistName(typed: typedName), onlyRequests: true)
    }

    /// Back to the zone list without touching the zone itself (`stopZone` ends it first).
    private func closeZone() {
        session.shutdown()
        session = PartySession(catalog: DemoOrEmptyCatalog(), engine: SilentEngine())
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

    /// Set when the app goes to the background (Home, another app).
    @ObservationIgnored private var wasBackgrounded = false

    /// tvOS closes an app's listening sockets while it's in the background, so a hub coming back
    /// starts its server, `.local` name and announcement again (as the iPad does).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wasBackgrounded = true
        case .active:
            // Back from Settings, or from the Apple Music prompt: the host's page shows the change.
            if role == .hub { checkMusicAccess(asking: false) }
            guard wasBackgrounded else { return }
            wasBackgrounded = false
            guard role == .hub else { return }
            debugLog("back from the background: restarting the server")
            serverTask?.cancel()
            serverTask = nil
            let old = server
            server = nil
            // No QR codes until the new server is up (`startServer` sets these again).
            guestURL = nil
            friendlyURL = nil
            hostname.unregister()
            advertiser.stop()
            Task {
                await old?.stop()
                guard role == .hub, server == nil else { return }
                await startServer()
            }
        default:
            break
        }
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

    /// Announces this zone; called again when the song or name changes. Not until a host has
    /// picked the music (crash-restore included): a zone with nothing to play isn't one to join.
    /// The server and the host's QR link work all along.
    func advertise() {
        guard role == .hub, !session.isWaitingForSetup, let server, let address = session.lanAddress else { return }
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
        session.shutdown()
        session = mirror
        connection.start(session: mirror)
        self.connection = connection
        shownZone = zone
        role = .display
        // A display starts at the zone list next time; this TV's own zone stays resumable.
        zoneRecord.stoppedHosting()
    }

    func leave() {
        connection?.stop()
        connection = nil
        shownZone = nil
        session.shutdown()
        session = PartySession(catalog: DemoOrEmptyCatalog(), engine: SilentEngine())
        role = .choosing
    }

    /// The "Join Wi‑Fi" code next to the guest QR: this hub's Wi‑Fi, set by a host on the web page.
    /// A display shows its hub's, from snapshots.
    var wifiPayload: String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fakeWifi") {
            return LocalNetwork.wifiJoinPayload(ssid: "Canopy Guest", password: "summer-party-2026")
        }
        #endif
        guard role != .choosing, !session.wifi.ssid.isEmpty else { return nil }
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
