import AVFoundation
import CanopyCore
import CanopyServer
import Foundation
import MusicKit
import Security
import SwiftUI
import UIKit

/// App-wide state: which provider is active, the party session, the phone server, and host settings.
@MainActor
@Observable
final class AppModel {
    enum Provider: String {
        /// No service chosen yet (fresh install, during setup). Never offered in the UI; its
        /// session can't search or play, so neither Apple Music nor Spotify is touched.
        case none
        case appleMusic, spotify
        #if DEBUG
        /// Fake songs, no audio. Debug builds only.
        case demo
        #endif

        var title: String {
            switch self {
            case .none: "No service"
            case .appleMusic: "Apple Music"
            case .spotify: "Spotify"
            #if DEBUG
            case .demo: "Demo"
            #endif
            }
        }

        /// App tint: Apple Music red, Spotify green, Canopy green before a choice and for the demo.
        var accent: Color {
            switch self {
            case .none: Color("AccentColor")
            case .appleMusic: Color(red: 0.98, green: 0.18, blue: 0.28)
            case .spotify: Color(red: 0.12, green: 0.84, blue: 0.38)
            #if DEBUG
            case .demo: Color("AccentColor")
            #endif
            }
        }
    }

    /// True until a music service has been chosen on the first-launch screen.
    private(set) var needsOnboarding: Bool
    /// Setup was reopened from Settings › Change Service (skips the network step).
    private(set) var isChangingService = false

    let spotifyAuth: SpotifyAuth
    /// Mirrors `SpotifyConfig.clientID` so views update when it's entered.
    private(set) var spotifyClientID = SpotifyConfig.clientID
    let spotifyAPI: SpotifyAPI
    /// The Spotify Connect device to play on, by id (the iPad's Spotify app, an Apple TV…).
    var spotifyDeviceID: String? {
        didSet { UserDefaults.standard.set(spotifyDeviceID, forKey: SpotifyEngine.deviceDefaultsKey) }
    }
    var spotifyDeviceName: String? {
        didSet { UserDefaults.standard.set(spotifyDeviceName, forKey: "spotifyDeviceName") }
    }
    /// Spotify's device type ("Tablet", "TV", "Speaker"…) for the chosen device.
    var spotifyDeviceType: String? {
        didSet { UserDefaults.standard.set(spotifyDeviceType, forKey: "spotifyDeviceType") }
    }
    /// Devices Spotify currently lists (only ones with Spotify open and awake).
    private(set) var spotifyDevices: [SpotifyDevice] = []
    /// False until the first device check finishes, so status can say "Checking…".
    private(set) var spotifyDevicesLoaded = false
    private(set) var spotifyDisplayName: String? {
        didSet { UserDefaults.standard.set(spotifyDisplayName, forKey: "spotifyDisplayName") }
    }

    var spotifyDeviceAvailable: Bool {
        guard let id = spotifyDeviceID else { return false }
        return spotifyDevices.contains { $0.id == id }
    }

    /// Spotify lost the chosen device (usually asleep), so playback commands would fail.
    var spotifyDisconnected: Bool {
        !isDisplay && provider == .spotify && spotifyDevicesLoaded && !spotifyDeviceAvailable
    }

    /// Music plays from this iPad (so its AirPlay speaker choice matters). Spotify reports the
    /// iPad's own app as a "Tablet"; unknown counts as this iPad.
    var spotifyPlaysOnThisIPad: Bool {
        guard let type = spotifyDeviceType else { return true }
        return type.lowercased() == "tablet"
    }

    private(set) var provider: Provider
    private(set) var session: PartySession
    /// Last fetched "Your playlists", so reopening the picker shows them at once while it refreshes.
    @ObservationIgnored var libraryPlaylistsCache: [PlaylistSummary] = []
    private(set) var isLocked = false
    private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    /// Apple Music playback needs a subscription; search works without one. Kept current by
    /// `MusicSubscription.subscriptionUpdates` once authorized.
    private(set) var canPlayAppleMusic = true
    private(set) var canBecomeAppleMusicSubscriber = false
    /// Sync Library on. Without it the Apple Music API has no library playlists to list.
    private(set) var appleMusicLibrarySynced = true
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    /// This device's own guest page (hub). Displays show their hub's instead; see `guestURL`.
    private var localGuestURL: URL?
    /// Key in the Host Control QR code. Forgetting phones replaces it.
    @ObservationIgnored private var hostKey = UserDefaults.standard.string(forKey: "hostControlKey") ?? AppModel.newHostKey()
    /// Client IDs of phones that have used the host key, for the "N phones" count.
    private(set) var hostPhones: [String] = UserDefaults.standard.stringArray(forKey: "hostControlPhones") ?? []
    private var localFriendlyURL: URL?
    var errorMessage: String?
    /// Shows "Where should music play?" (host Music section or the party screen's device button).
    var isPickingSpotifyDevice = false

    var hostPIN: String { didSet { defaults.set(hostPIN, forKey: "hostPIN") } }
    var crossfade: Bool {
        didSet {
            defaults.set(crossfade, forKey: "crossfade")
            applyCrossfade()
        }
    }
    /// Crossfade length in seconds; 0 means the system default.
    var crossfadeSeconds: Double {
        didSet {
            defaults.set(crossfadeSeconds, forKey: "crossfadeSeconds")
            applyCrossfade()
        }
    }
    var wifiSSID: String { didSet { defaults.set(wifiSSID, forKey: "wifiSSID") } }
    var wifiPassword: String { didSet { defaults.set(wifiPassword, forKey: "wifiPassword") } }
    /// Plain Join Wi‑Fi code with a caption, for phones that struggle with the Wi‑Fi symbol design.
    var wifiSimpleQR: Bool { didSet { defaults.set(wifiSimpleQR, forKey: "wifiSimpleQR") } }
    /// The `<name>.local` address guests can type. Set through `setLocalName(_:)`.
    private(set) var localName: String
    /// Runs the LAN web server guests use to queue from their phones.
    /// Guests can drag songs around from their phones. Off: phones can still add and remove their own.
    var phoneReorderEnabled: Bool {
        didSet {
            defaults.set(phoneReorderEnabled, forKey: "phoneReorderEnabled")
            session.phonesCanReorder = phoneReorderEnabled
        configureHubSession()
        connectHostControl()
        }
    }

    var phoneQueueEnabled: Bool {
        didSet {
            guard phoneQueueEnabled != oldValue else { return }
            defaults.set(phoneQueueEnabled, forKey: "phoneQueueEnabled")
            Task { phoneQueueEnabled ? await restartServer() : await stopServer() }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    /// Serializes server start/stop so two callers can't start two servers (the second would
    /// lose port 80 and land on 8080).
    @ObservationIgnored private var serverOperation: Task<Void, Never>?
    @ObservationIgnored private var hostname = FriendlyHostname(name: "music")

    init() {
        // Nothing saved (or a choice this build doesn't have, e.g. "demo" in a release build):
        // start with no service and show setup.
        let saved = Provider(rawValue: defaults.string(forKey: "provider") ?? "")
        let provider = saved == Provider.none ? nil : saved
        self.provider = provider ?? .none
        var needsOnboarding = provider == nil
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboarding") { needsOnboarding = true }
        #endif
        self.needsOnboarding = needsOnboarding
        let spotifyAuth = SpotifyAuth()
        let spotifyAPI = SpotifyAPI(auth: spotifyAuth)
        self.spotifyAuth = spotifyAuth
        self.spotifyAPI = spotifyAPI
        self.spotifyDeviceID = UserDefaults.standard.string(forKey: SpotifyEngine.deviceDefaultsKey)
        self.spotifyDeviceName = UserDefaults.standard.string(forKey: "spotifyDeviceName")
        self.spotifyDeviceType = UserDefaults.standard.string(forKey: "spotifyDeviceType")
        self.spotifyDisplayName = UserDefaults.standard.string(forKey: "spotifyDisplayName")
        self.session = Self.makeSession(provider ?? .none, spotify: spotifyAPI)
        hostPIN = defaults.string(forKey: "hostPIN") ?? ""
        if let id = UserDefaults.standard.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "deviceID")
        }
        zoneName = UserDefaults.standard.string(forKey: "zoneName") ?? UIDevice.current.name
        displaysCanControl = UserDefaults.standard.object(forKey: "displaysCanControl") as? Bool ?? true
        // Every launch starts at the zone list, except debug launches that go straight to a party.
        var role = ZoneRole.choosing
        #if DEBUG
        let debugFlags = ["-autoParty", "-autoSearch", "-autoLoad", "-autoResume", "-autoPrevious", "-autoStress", "-showSettings",
                          "-showPicker", "-appleMusicState", "-qrGallery", "-backgroundFor", "-screenshotParty", "-onboarding",
                          "-onboardingSpotify", "-onboardingNetwork", "-easterEggPreview", "-diagnoseMusicKit", "-benchAppleMusic"]
        if ProcessInfo.processInfo.arguments.contains(where: debugFlags.contains) { role = .hub }
        #endif
        zoneRole = role
        crossfade = defaults.bool(forKey: "crossfade")
        crossfadeSeconds = defaults.double(forKey: "crossfadeSeconds")
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        wifiPassword = defaults.string(forKey: "wifiPassword") ?? ""
        wifiSimpleQR = defaults.bool(forKey: "wifiSimpleQR")
        phoneQueueEnabled = defaults.object(forKey: "phoneQueueEnabled") as? Bool ?? true
        phoneReorderEnabled = defaults.object(forKey: "phoneReorderEnabled") as? Bool ?? true
        let savedName = Self.sanitizedLocalName(defaults.string(forKey: "localName") ?? "")
        localName = savedName
        hostname = FriendlyHostname(name: savedName)
        applyCrossfade()
        watchAppleMusicSubscription()
        session.phonesCanReorder = phoneReorderEnabled // didSet doesn't run during init
        configureHubSession()
        watchHostnameRenames()
        defaults.set(hostKey, forKey: "hostControlKey")
        connectHostControl()
        #if DEBUG
        // `-appleMusicState ready|unsynced|nosub|denied`: fakes the host Music row for screenshots.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-appleMusicState"), i + 1 < args.count {
            self.provider = .appleMusic
            switch args[i + 1] {
            case "unsynced": authorization = .authorized; appleMusicLibrarySynced = false
            case "nosub": authorization = .authorized; canPlayAppleMusic = false; canBecomeAppleMusicSubscriber = true
            case "denied": authorization = .denied
            default: authorization = .authorized
            }
        }
        #endif

        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)

        // Long-form audio is what lets the AirPlay picker select several AirPlay 2 speakers at once.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private static func makeSession(_ provider: Provider, spotify: SpotifyAPI) -> PartySession {
        let store = URL.applicationSupportDirectory.appending(path: "party-\(provider.rawValue).json")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        switch provider {
        case .none:
            return PartySession(catalog: NoServiceCatalog(), engine: NoServiceEngine())
        case .appleMusic:
            let cache = SongCache()
            return PartySession(catalog: AppleMusicCatalog(cache: cache), engine: AppleMusicEngine(cache: cache), storeURL: store)
        case .spotify:
            return PartySession(catalog: SpotifyCatalog(api: spotify), engine: SpotifyEngine(api: spotify), storeURL: store)
        #if DEBUG
        case .demo:
            return PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine(), storeURL: store)
        #endif
        }
    }

    // MARK: Provider

    var isDemo: Bool {
        #if DEBUG
        provider == .demo
        #else
        false
        #endif
    }

    /// First-launch choice; always records it, even if it matches the default.
    func chooseProvider(_ next: Provider) {
        setProvider(next)
        defaults.set(next.rawValue, forKey: "provider")
    }

    func changeService() {
        isChangingService = true
        needsOnboarding = true
    }

    func finishOnboarding() {
        isChangingService = false
        needsOnboarding = false
        // The phone page (and its local network prompt) waits until setup is done.
        Task { await startServerIfNeeded() }
    }

    func setProvider(_ next: Provider) {
        guard next != provider else { return }
        if session.engine.isPlaying { session.engine.pause() }
        provider = next
        defaults.set(next.rawValue, forKey: "provider")
        session = Self.makeSession(next, spotify: spotifyAPI)
        session.phonesCanReorder = phoneReorderEnabled
        libraryPlaylistsCache = []
        applyCrossfade()
        Task { await restartServer() }
    }

    /// Changing the Spotify app means existing tokens no longer apply.
    func setSpotifyClientID(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != SpotifyConfig.clientID else { return }
        defaults.set(id, forKey: SpotifyConfig.clientIDDefaultsKey)
        spotifyClientID = id
        spotifyAuth.signOut()
        spotifyDeviceID = nil
        spotifyDeviceName = nil
        spotifyDeviceType = nil
        spotifyDisplayName = nil
    }

    func signInToSpotify() async {
        do {
            try await spotifyAuth.signIn()
            await refreshSpotifyProfile()
        } catch SpotifyError.signInCancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSpotifyProfile() async {
        struct Me: Decodable { var display_name: String? }
        guard spotifyAuth.isSignedIn,
              let me = try? await spotifyAPI.get("/me", as: Me.self) else { return }
        spotifyDisplayName = me.display_name
    }

    /// Quietly refreshes the device list; failures keep the last list rather than alerting.
    func refreshSpotifyDevices() async {
        struct Reply: Decodable { var devices: [SpotifyDevice] }
        guard spotifyAuth.isSignedIn,
              let reply = try? await spotifyAPI.get("/me/player/devices", as: Reply.self) else { return }
        let wasAvailable = spotifyDevicesLoaded && spotifyDeviceAvailable
        spotifyDevices = reply.devices.filter { $0.id != nil }
        #if DEBUG
        print("[spotify-devices] " + reply.devices.map { "\($0.name) type=\($0.type) active=\($0.is_active) volume=\($0.supports_volume.map(String.init) ?? "?")" }.joined(separator: " | "))
        #endif
        spotifyDevicesLoaded = true
        // Spotify plays on one device per account. If playback moved (e.g. picked in the Spotify
        // app), follow it, so commands don't pull it back and the AirPlay button is right.
        if let active = spotifyDevices.first(where: \.is_active), active.id != spotifyDeviceID {
            spotifyDeviceID = active.id
        }
        if let id = spotifyDeviceID, let device = spotifyDevices.first(where: { $0.id == id }) {
            spotifyDeviceName = device.name
            spotifyDeviceType = device.type
        }
        #if DEBUG
        print("[spotify-devices] chosen=\(spotifyDeviceName ?? "nil") type=\(spotifyDeviceType ?? "nil")")
        #endif
        // Lost the device mid-party: ask where music should play (once per loss, so Done sticks).
        if wasAvailable, !spotifyDeviceAvailable, provider == .spotify, session.state.current != nil {
            isPickingSpotifyDevice = true
        }
    }

    func selectSpotifyDevice(_ device: SpotifyDevice) {
        let changed = device.id != spotifyDeviceID
        spotifyDeviceID = device.id
        spotifyDeviceName = device.name
        spotifyDeviceType = device.type
        // Mid-party, move playback to the new device (resuming targets it by id).
        if changed, session.state.current != nil, session.isPlaying || isLocked {
            Task { await play() }
        }
    }

    private func applyCrossfade() {
        session.setCrossfade(enabled: crossfade, duration: crossfadeSeconds > 0 ? crossfadeSeconds : nil)
    }

    var isReady: Bool {
        switch provider {
        case .none: false
        case .appleMusic: authorization == .authorized && canPlayAppleMusic
        case .spotify: spotifyAuth.isSignedIn && spotifyDeviceAvailable
        #if DEBUG
        case .demo: true
        #endif
        }
    }

    func requestAuthorization() async {
        authorization = await MusicAuthorization.request()
        watchAppleMusicSubscription()
    }

    func watchAppleMusicSubscription() {
        guard authorization == .authorized, subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                self?.canPlayAppleMusic = subscription.canPlayCatalogContent
                self?.canBecomeAppleMusicSubscriber = subscription.canBecomeSubscriber
                self?.appleMusicLibrarySynced = subscription.hasCloudLibraryEnabled
            }
        }
    }

    // MARK: Party

    func load(_ playlist: PlaylistSummary) async {
        do {
            try await session.load(playlist: playlist)
        } catch {
            errorMessage = "Couldn't load “\(playlist.name)”. \(error.localizedDescription)"
        }
    }

    func play() async {
        do {
            try await session.play()
        } catch SpotifyError.noDevice {
            // The chosen device went away (usually Spotify asleep on it): show where music can
            // play instead of an error.
            spotifyDevices.removeAll { $0.id == spotifyDeviceID }
            isPickingSpotifyDevice = true
            await refreshSpotifyDevices()
        } catch {
            errorMessage = "Couldn't start playback. \(error.localizedDescription)"
        }
    }

    // MARK: Zones (docs/multi-device.md)

    enum ZoneRole: Equatable {
        /// The zone list (every launch).
        case choosing
        /// Naming a new zone and setting its PIN.
        case creating
        /// This iPad plays the music for its zone.
        case hub
        /// Showing another device's zone.
        case display
    }

    private(set) var zoneRole: ZoneRole
    var isDisplay: Bool { zoneRole == .display }
    var zoneName: String {
        didSet {
            defaults.set(zoneName, forKey: "zoneName")
            if !isDisplay { session.zoneName = zoneName }
            advertiseZone()
        }
    }
    /// Play/pause, skip and scrubbing on displays (a hub setting).
    var displaysCanControl: Bool {
        didSet {
            defaults.set(displaysCanControl, forKey: "displaysCanControl")
            if !isDisplay { session.displaysCanControl = displaysCanControl }
        }
    }
    let zoneBrowser = ZoneBrowser()
    private(set) var displayConnection: ZoneConnection?
    private(set) var displayedZone: ZoneListing?
    @ObservationIgnored let deviceID: String
    @ObservationIgnored private let zoneAdvertiser = ZoneAdvertiser()
    @ObservationIgnored private var advertisedPlaying: String?

    /// This iPad ran a zone last time, so the list offers to resume it.
    var canResumeZone: Bool { defaults.bool(forKey: "wasHub") && provider != .none }

    /// The guest page shown in QR codes: this hub's, or the hub a display is showing.
    var guestURL: URL? {
        isDisplay ? session.lanAddress.flatMap { URL(string: "http://\($0)") } : localGuestURL
    }
    var friendlyURL: URL? {
        isDisplay ? session.guestAddress.flatMap { URL(string: "http://\($0)") } : localFriendlyURL
    }
    var showsGuestQR: Bool { isDisplay ? guestURL != nil : phoneQueueEnabled }

    func beginCreatingZone() {
        zoneRole = .creating
    }

    func cancelCreatingZone() {
        zoneRole = .choosing
    }

    func finishCreatingZone(name: String, pin: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        zoneName = trimmed.isEmpty ? UIDevice.current.name : String(trimmed.prefix(40))
        hostPIN = pin ?? ""
        becomeHub()
    }

    func resumeZone() {
        becomeHub()
    }

    private func becomeHub() {
        zoneRole = .hub
        defaults.set(true, forKey: "wasHub")
        isLocked = false
        if provider == .none {
            needsOnboarding = true
        } else {
            Task { await startServerIfNeeded() }
        }
    }

    /// Stops running this zone (the server and its announcement) and goes back to the zone list.
    func stopHosting() {
        if session.engine.isPlaying { session.pause() }
        zoneRole = .choosing
        isLocked = false
        Task { await stopServer() }
    }

    /// Shows another device's zone. Displays don't run a server or play anything.
    func join(_ zone: ZoneListing) {
        guard let url = zone.baseURL else { return }
        if session.engine.isPlaying { session.pause() }
        Task { await stopServer() }
        let connection = ZoneConnection(baseURL: url, clientID: deviceID, name: UIDevice.current.name, kind: .ipad)
        let mirror = PartySession(remote: connection)
        session = mirror
        connection.start(session: mirror)
        displayConnection = connection
        displayedZone = zone
        zoneRole = .display
        lock()
    }

    func leaveZone() {
        displayConnection?.stop()
        displayConnection = nil
        displayedZone = nil
        session = Self.makeSession(provider, spotify: spotifyAPI)
        session.phonesCanReorder = phoneReorderEnabled
        configureHubSession()
        connectHostControl()
        applyCrossfade()
        zoneRole = .choosing
        isLocked = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func configureHubSession() {
        session.configureHub(kind: .ipad, zoneName: zoneName, serviceName: provider == .none ? nil : provider.title)
        session.displaysCanControl = displaysCanControl
    }

    /// Announces this zone (or refreshes what's playing in the announcement).
    func advertiseZone() {
        guard zoneRole == .hub, let server, let address = session.lanAddress else { return }
        let playing = session.state.current.map { "\($0.track.title) – \($0.track.artist)" } ?? ""
        advertisedPlaying = playing
        zoneAdvertiser.advertise(name: zoneName, port: server.port, txt: [
            "name": zoneName, "kind": HubKind.ipad.rawValue, "addr": address, "hub": deviceID, "playing": String(playing.prefix(120)),
        ])
    }

    /// Called when the current song changes.
    func zoneSongChanged() {
        let playing = session.state.current.map { "\($0.track.title) – \($0.track.artist)" } ?? ""
        if playing != advertisedPlaying { advertiseZone() }
    }

    // MARK: Host control

    /// The Host Control QR code: the guest page plus the key. Uses the IP so every phone resolves it;
    /// the page moves to the `.local` address itself when the phone can reach it.
    var hostControlURL: URL? {
        guard let guestURL else { return nil }
        return URL(string: "\(guestURL.absoluteString)/?host=\(hostKey)")
    }

    /// Revokes every phone with host control by replacing the key.
    func forgetHostPhones() {
        hostKey = Self.newHostKey()
        defaults.set(hostKey, forKey: "hostControlKey")
        hostPhones = []
        defaults.set(hostPhones, forKey: "hostControlPhones")
        session.hostKey = hostKey
    }

    private func connectHostControl() {
        session.hostKey = hostKey
        // Settings changed by a host on the web page: keep ours in step and saved.
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            if let name = self.session.zoneName, name != self.zoneName { self.zoneName = name }
            if self.session.phonesCanReorder != self.phoneReorderEnabled { self.phoneReorderEnabled = self.session.phonesCanReorder }
            if self.session.displaysCanControl != self.displaysCanControl { self.displaysCanControl = self.session.displaysCanControl }
        }
        session.onHostPhone = { [weak self] clientID in
            guard let self, !self.hostPhones.contains(clientID) else { return }
            self.hostPhones.append(clientID)
            self.defaults.set(self.hostPhones, forKey: "hostControlPhones")
        }
    }

    private static func newHostKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    #if DEBUG
    /// `-screenshotParty`: swaps in a posed session and goes straight to the party screen.
    func installScreenshotSession(_ session: PartySession) {
        provider = .appleMusic
        self.session = session
        configureHubSession()
        connectHostControl()
        needsOnboarding = false
        lock()
        // The phone server was started with the old session.
        Task { await restartServer() }
    }
    #endif

    func lock() {
        isLocked = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// An empty PIN unlocks without asking.
    func unlock(pin: String) -> Bool {
        guard hostPIN.isEmpty || pin == hostPIN else { return false }
        isLocked = false
        return true
    }

    // MARK: Phone server

    func startServerIfNeeded() async {
        await serially {
            guard self.phoneQueueEnabled, !self.needsOnboarding, self.zoneRole == .hub else { return }
            if self.server != nil {
                self.refreshAddresses()
                return
            }
            await self.restartServerNow()
        }
    }

    func restartServer() async {
        await serially { await self.restartServerNow() }
    }

    func stopServer() async {
        await serially { await self.stopServerNow() }
    }

    private func serially(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = serverOperation
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        serverOperation = task
        await task.value
    }

    private func restartServerNow() async {
        await stopServerNow()
        guard phoneQueueEnabled, !needsOnboarding, zoneRole == .hub else { return }
        guard let (server, task) = await PartyServer.start(session: session) else {
            localGuestURL = nil
            localFriendlyURL = nil
            return
        }
        self.server = server
        serverTask = task
        refreshAddresses()
    }

    /// Changes the `.local` name and re-announces it.
    func setLocalName(_ raw: String) {
        let name = Self.sanitizedLocalName(raw)
        guard name != localName else { return }
        localName = name
        defaults.set(name, forKey: "localName")
        hostname.unregister()
        hostname = FriendlyHostname(name: name)
        watchHostnameRenames()
        refreshAddresses()
    }

    /// The `.local` name is handed out only once mDNS confirms it's ours (it may have moved to
    /// `name-2.local` if another zone has it).
    private func watchHostnameRenames() {
        hostname.onConfirmed = { [weak self] name in
            guard let self, let server = self.server else { return }
            self.localFriendlyURL = server.url(host: name)
            self.session.guestAddress = name + (server.port == 80 ? "" : ":\(server.port)")
        }
    }

    /// Lowercase letters, digits and hyphens, at most 63 characters; empty means "music".
    static func sanitizedLocalName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var name = raw.lowercased()
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
        while name.hasPrefix("-") { name.removeFirst() }
        while name.hasSuffix("-") { name.removeLast() }
        name = String(name.prefix(63))
        return name.isEmpty ? "music" : name
    }

    private func stopServerNow() async {
        serverTask?.cancel()
        serverTask = nil
        await server?.stop()
        server = nil
        hostname.unregister()
        zoneAdvertiser.stop()
        localGuestURL = nil
        localFriendlyURL = nil
    }

    func refreshAddresses() {
        guard let server, let ip = LocalNetwork.lanAddress() else {
            localGuestURL = nil
            localFriendlyURL = nil
            return
        }
        localGuestURL = server.url(host: ip)
        // Set again by `onConfirmed` once the name is checked.
        localFriendlyURL = nil
        session.guestAddress = nil
        hostname.register(address: ip)
        session.lanAddress = ip + (server.port == 80 ? "" : ":\(server.port)")
        advertiseZone()
    }

    #if DEBUG
    /// `-diagnoseMusicKit`: walks through each Apple Music step and prints what fails.
    func diagnoseMusicKit() async {
        print("[diag] bundle=\(Bundle.main.bundleIdentifier ?? "?") provider=\(provider.rawValue)")
        print("[diag] auth before=\(MusicAuthorization.currentStatus)")
        let status = await MusicAuthorization.request()
        authorization = status
        print("[diag] auth after=\(status)")
        do {
            let sub = try await MusicSubscription.current
            print("[diag] subscription canPlayCatalog=\(sub.canPlayCatalogContent) cloudLibrary=\(sub.hasCloudLibraryEnabled) canBecomeSubscriber=\(sub.canBecomeSubscriber)")
        } catch {
            print("[diag] subscription error: \(String(reflecting: error))")
        }
        do {
            var request = MusicCatalogSearchRequest(term: "daft punk", types: [Song.self])
            request.limit = 3
            let response = try await request.response()
            print("[diag] catalog search ok: \(response.songs.map(\.title))")
        } catch {
            print("[diag] catalog search error: \(String(reflecting: error))")
        }
        do {
            let url = URL(string: "https://api.music.apple.com/v1/me/storefront")!
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            print("[diag] storefront ok: \(String(decoding: response.data.prefix(200), as: UTF8.self))")
        } catch {
            print("[diag] storefront error: \(String(reflecting: error))")
        }
        do {
            let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists?limit=3")!
            let data = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for item in (object?["data"] as? [[String: Any]]) ?? [] {
                let attributes = item["attributes"] as? [String: Any] ?? [:]
                print("[diag] playlist attrs: \(attributes.filter { !($0.value is [String: Any]) })")
            }
        } catch {
            print("[diag] raw playlists error: \(error)")
        }
        do {
            let playlists = try await session.catalog.libraryPlaylists()
            print("[diag] library playlists ok: \(playlists.count) \(playlists.prefix(5).map(\.name))")
            if let first = playlists.first {
                let tracks = try await session.catalog.tracks(in: first)
                print("[diag] tracks in \(first.name): \(tracks.count)")
            }
        } catch {
            print("[diag] library playlists error: \(String(reflecting: error))")
        }
        print("[diag] done")
    }
    #endif

    var wifiJoinPayload: String? {
        // Wi‑Fi details are this hub's; a display doesn't know its hub's.
        isDisplay || wifiSSID.isEmpty ? nil : LocalNetwork.wifiJoinPayload(ssid: wifiSSID, password: wifiPassword)
    }
}

// MARK: - No service yet

/// Session parts for before a service is chosen: nothing to search, nothing to play.
private struct NoServiceCatalog: MusicCatalog {
    func searchSongs(_ term: String) async throws -> [QueueTrack] { [] }
    func libraryPlaylists() async throws -> [PlaylistSummary] { [] }
    func searchPlaylists(_ term: String) async throws -> [PlaylistSummary] { [] }
    func tracks(in playlist: PlaylistSummary) async throws -> [QueueTrack] { [] }
}

@MainActor
private final class NoServiceEngine: PlaybackEngine {
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
