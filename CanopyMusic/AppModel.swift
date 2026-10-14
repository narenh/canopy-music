import AVFoundation
import CanopyMusicCore
import CanopyMusicServer
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

    let spotifyAuth: SpotifyAuth
    /// Mirrors `SpotifyConfig.clientID` so views update when it's entered.
    private(set) var spotifyClientID = SpotifyConfig.clientID
    /// Mirrors `SpotifyConfig.ownSignInPage`: the user's own Spotify sign-in page, nil for the default.
    private(set) var spotifyOwnSignInPage = SpotifyConfig.ownSignInPage
    /// The redirect URI to register: the sign-in page in use.
    var spotifyRedirectURI: String { spotifyOwnSignInPage ?? SpotifyRelay.defaultPage }
    /// The last sign-in's sheet was closed without an answer. Spotify may have shown its own
    /// error page there (an unregistered redirect URI), which the app can't see, so the sign-in
    /// step says what to check.
    private(set) var spotifySignInClosed = false
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

    /// Spotify lost the chosen device (usually asleep), so playback commands would fail. Not when
    /// Sonos plays the zone's songs: Spotify Connect isn't used then.
    var spotifyDisconnected: Bool {
        !isDisplay && provider == .spotify && !usesSonos && spotifyDevicesLoaded && !spotifyDeviceAvailable
    }

    /// Music plays from this iPad or Mac (so its AirPlay speaker choice matters). Spotify reports
    /// the iPad's own app as a "Tablet" and the Mac's desktop app as a "Computer", so on a Mac
    /// only "Computer" counts. Spotify gives no way to tell this device's own app from another of
    /// the same type on the account, so another iPad (or computer) counts too. Unknown counts as
    /// this device.
    var spotifyPlaysOnThisDevice: Bool {
        guard let type = spotifyDeviceType else { return true }
        return type.lowercased() == (DeviceKind.isMac ? "computer" : "tablet")
    }

    /// The start screen's "Plays on" row offers AirPlay speakers. With Spotify: only once a device
    /// is chosen and it's this iPad or Mac, even while Spotify there is asleep (picking speakers
    /// is part of getting ready).
    var showsSpeakerChoice: Bool {
        provider != .spotify || (spotifyDeviceID != nil && spotifyPlaysOnThisDevice)
    }

    private(set) var provider: Provider
    private(set) var session: PartySession
    /// Last fetched "Your playlists", so reopening the picker shows them at once while it refreshes.
    @ObservationIgnored var libraryPlaylistsCache: [PlaylistSummary] = []
    /// The party screen is showing and host mode is behind press and hold (and the PIN). A live
    /// zone remembers it, so after a crash it comes back locked.
    private(set) var isLocked = false {
        didSet { if isLive { zoneRecord.wasLocked = isLocked } }
    }
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
    /// The Host Control key and the phones that have used it (shared with the Apple TV app).
    let hostControl = HostControl()
    private var localFriendlyURL: URL?
    var errorMessage: String?
    /// Shows "Where should music play?" (host Music section or the party screen's device button).
    var isPickingSpotifyDevice = false {
        didSet { if !isPickingSpotifyDevice { startsWhenDeviceChosen = false } }
    }
    /// Start found no Spotify device to play on: choosing one in the picker presses Start again.
    @ObservationIgnored private var startsWhenDeviceChosen = false

    var hostPIN: String {
        didSet {
            defaults.set(hostPIN, forKey: "hostPIN")
        }
    }
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
    var wifiSSID: String { didSet { defaults.set(wifiSSID, forKey: "wifiSSID"); session.wifi.ssid = wifiSSID } }
    var wifiPassword: String { didSet { defaults.set(wifiPassword, forKey: "wifiPassword"); session.wifi.password = wifiPassword } }
    /// Plain Join Wi‑Fi code with a caption, for phones that struggle with the Wi‑Fi symbol design.
    var wifiSimpleQR: Bool { didSet { defaults.set(wifiSimpleQR, forKey: "wifiSimpleQR"); session.wifi.simpleQR = wifiSimpleQR } }
    /// Runs the LAN web server guests use to queue from their phones.
    /// Guests can drag songs around from their phones. Off: phones can still add and remove their own.
    var phoneReorderEnabled: Bool {
        didSet {
            defaults.set(phoneReorderEnabled, forKey: "phoneReorderEnabled")
            session.phonesCanReorder = phoneReorderEnabled
        }
    }

    /// Whether guests can queue from their phones. The server keeps running either way: host phones
    /// and displays use it too.
    var phoneQueueEnabled: Bool {
        didSet {
            guard phoneQueueEnabled != oldValue else { return }
            defaults.set(phoneQueueEnabled, forKey: "phoneQueueEnabled")
            session.phonesCanQueue = phoneQueueEnabled
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
        // start with no service, and "Create a new zone" runs setup first.
        let saved = Provider(rawValue: defaults.string(forKey: "provider") ?? "")
        let provider = saved == Provider.none ? nil : saved
        self.provider = provider ?? .none
        var needsOnboarding = provider == nil
        #if DEBUG
        let setupFlags = ["-onboarding", "-onboardingSpotify", "-onboardingNetwork"]
        if ProcessInfo.processInfo.arguments.contains(where: setupFlags.contains) { needsOnboarding = true }
        // `-createZoneName` and `-createZonePIN` open setup's second step (name and PIN).
        if ProcessInfo.processInfo.arguments.contains(where: ["-createZoneName", "-createZonePIN"].contains) { needsOnboarding = false }
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
        let household = Self.makeHousehold()
        sonos = household
        let sonosOutput = Self.loadSonosOutput()
        let sonosAccounts = Self.loadSonosAccounts()
        self.sonosOutput = sonosOutput
        self.sonosChosenAccounts = sonosAccounts
        // A zone is recorded only once its music has started (`startZone`). Older builds recorded
        // it at Create: one of theirs where music never started isn't one to come back to, so
        // it's ended, as End does (before its saved queue loads), and the list has nothing to resume.
        let record = ZoneRecord()
        record.settleStarted(songsPlayed: QueueState.saved(at: Self.storeURL(provider ?? .none))?.log.isEmpty == false)
        if record.endsOnLaunch {
            for each in Self.allProviders { try? FileManager.default.removeItem(at: Self.storeURL(each)) }
            record.ended()
        }
        self.session = Self.makeSession(provider ?? .none, spotify: spotifyAPI,
                                        sonos: Self.makeSonosPlayback(provider ?? .none, output: sonosOutput, accounts: sonosAccounts, found: []),
                                        sonosTransport: household.transport)
        hostPIN = defaults.string(forKey: "hostPIN") ?? ""
        if let id = UserDefaults.standard.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "deviceID")
        }
        zoneName = UserDefaults.standard.string(forKey: "zoneName") ?? DeviceKind.name
        displaysCanControl = UserDefaults.standard.object(forKey: "displaysCanControl") as? Bool ?? true
        // Launches start at the zone list, unless this iPad was hosting a zone that wasn't ended
        // (a crash, or a quit by the system): then it goes straight back in, paused, locked if it was.
        var role = ZoneRole.choosing
        var locked = false
        var restoring = false
        if record.restoresOnLaunch, let provider, Self.canRestore(provider, spotifyAuth: spotifyAuth) {
            if provider == .spotify, spotifyAuth.accountFingerprint != nil {
                // Spotify: only once no other zone turns out to be using the account, so it starts
                // at the list and `startOnLaunch()` goes back in (or asks there).
                restoresAfterSpotifyCheck = true
            } else {
                role = .hub
                locked = record.wasLocked
                restoring = true
            }
        }
        #if DEBUG
        // Debug launches that go straight to the start screen, with nothing live (`-autoParty` and
        // `-autoResume` then press Start).
        let debugFlags = ["-autoParty", "-autoSearch", "-autoLoad", "-autoResume", "-autoPrevious", "-autoStress", "-showSettings",
                          "-showPicker", "-appleMusicState", "-qrGallery", "-backgroundFor", "-screenshotParty",
                          "-easterEggPreview", "-diagnoseMusicKit", "-benchAppleMusic", "-autoLoadPlaylist", "-confirmEnd", "-showSave", "-spotifyState",
                          "-switchService", "-openServiceMenu", "-sonosProbe", "-sonosSelect", "-sonosFake", "-showOutputPicker", "-showPINSheet"]
        if ProcessInfo.processInfo.arguments.contains(where: debugFlags.contains) {
            role = .hub
            locked = false
            restoring = false
            restoresAfterSpotifyCheck = false
        }
        // `-onboarding`, `-onboardingSpotify`, `-onboardingNetwork`: setup's first step (the
        // service), as "Create a new zone" on a fresh install. `-createZoneName`,
        // `-createZonePIN`: its second step, at the name or the PIN, for checking their layout.
        if ProcessInfo.processInfo.arguments.contains(where: (setupFlags + ["-createZoneName", "-createZonePIN"]).contains) {
            role = .creating
            locked = false
            restoring = false
            restoresAfterSpotifyCheck = false
        }
        #endif
        zoneRole = role
        isRestoringZone = restoring
        isLive = restoring
        isLocked = locked
        crossfade = defaults.bool(forKey: "crossfade")
        crossfadeSeconds = defaults.double(forKey: "crossfadeSeconds")
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        wifiPassword = defaults.string(forKey: "wifiPassword") ?? ""
        wifiSimpleQR = defaults.bool(forKey: "wifiSimpleQR")
        phoneQueueEnabled = defaults.object(forKey: "phoneQueueEnabled") as? Bool ?? true
        phoneReorderEnabled = defaults.object(forKey: "phoneReorderEnabled") as? Bool ?? true
        // The `.local` address follows the zone name.
        hostname = FriendlyHostname(name: FriendlyHostname.localName(forZone: zoneName))
        defaults.removeObject(forKey: "localName") // the old editable address
        applyCrossfade()
        watchAppleMusicSubscription()
        session.phonesCanReorder = phoneReorderEnabled // didSet doesn't run during init
        configureHubSession()
        watchHostnameRenames()
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
        // `-spotifyState none|self|selfOffline|other`: Spotify with no device chosen, this
        // iPad's (or, with `-device`, this Mac's) Spotify available or asleep, or a TV. Fakes
        // what the device list would say; no sign-in, so nothing refreshes it.
        if let i = args.firstIndex(of: "-spotifyState"), i + 1 < args.count {
            self.provider = .spotify
            let state = args[i + 1]
            let own = SpotifyDevice(id: "debug-self", name: DeviceKind.noun, type: DeviceKind.isMac ? "Computer" : "Tablet", is_active: true)
            let tv = SpotifyDevice(id: "debug-tv", name: "Living Room TV", type: "TV", is_active: false)
            let chosen: SpotifyDevice? = switch state {
            case "self", "selfOffline": own
            case "other": tv
            default: nil
            }
            spotifyDeviceID = chosen?.id
            spotifyDeviceName = chosen?.name
            spotifyDeviceType = chosen?.type
            spotifyDevices = state == "selfOffline" ? [tv] : [own, tv]
            spotifyDevicesLoaded = true
        }
        // `-fakeSpotifyConflict <zone>`: Spotify, with a zone of that name on the network using the
        // same account (Spotify can't be reached in the simulator). The zone list then presses
        // "Create a new zone" and Start, which asks. The made-up zone isn't probed: it counts as
        // answering (`zoneUsingSpotifyAccount`).
        if let i = args.firstIndex(of: "-fakeSpotifyConflict"), i + 1 < args.count {
            self.provider = .spotify
            self.needsOnboarding = false
            let account = SpotifyAccount.fingerprint(userID: "debug-user")
            debugSpotifyAccount = account
            debugZones = [ZoneListing(id: args[i + 1], name: args[i + 1], kind: .ipad, address: "192.0.2.1",
                                      hubID: "debug-other-hub", nowPlaying: "Dreams – Fleetwood Mac", spotifyAccount: account)]
        }
        #endif
        spotifyAuth.onAccountChanged = { [weak self] in self?.advertiseZone() }
        sonos.onRefresh = { [weak self] in self?.sonosRefreshed() }
        #if DEBUG
        sonos.log = { print("[sonos] \($0)") }
        // `-sonosProbe`: logs everything the Sonos household gives away (read-only) to
        // Library/Caches/sonos.log, and goes to the start screen, whose Speakers list shows it too.
        if ProcessInfo.processInfo.arguments.contains("-sonosProbe") {
            Task { [sonos] in
                let url = await SonosProbe(household: sonos).run()
                print("[sonos-probe] log at \(url.path)")
            }
        }
        #endif

        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)

        // Long-form audio is what lets the AirPlay picker select several AirPlay 2 speakers at once.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    /// Whether a zone that was running can come back by itself at launch: the service is still
    /// signed in, and there's a network to announce it on. Otherwise the list offers Resume.
    private static func canRestore(_ provider: Provider, spotifyAuth: SpotifyAuth) -> Bool {
        guard LocalNetwork.lanAddress() != nil else { return false }
        #if DEBUG
        // `-noRestore`: as if it couldn't (e.g. no network), to test falling back to Resume.
        if ProcessInfo.processInfo.arguments.contains("-noRestore") { return false }
        #endif
        switch provider {
        case .none: return false
        case .appleMusic: return MusicAuthorization.currentStatus == .authorized
        case .spotify: return spotifyAuth.isSignedIn
        #if DEBUG
        case .demo: return true
        #endif
        }
    }

    /// Where each service's queue is saved between launches.
    private static func storeURL(_ provider: Provider) -> URL {
        URL.applicationSupportDirectory.appending(path: "party-\(provider.rawValue).json")
    }

    private static var allProviders: [Provider] {
        #if DEBUG
        [.appleMusic, .spotify, .demo]
        #else
        [.appleMusic, .spotify]
        #endif
    }

    /// `sonos` set: the zone's songs play on those Sonos rooms, streamed from that account, instead
    /// of on this device (or, for Spotify, a Spotify Connect device).
    private static func makeSession(_ provider: Provider, spotify: SpotifyAPI, sonos: SonosPlayback? = nil, sonosTransport: any SonosTransport) -> PartySession {
        let store = storeURL(provider)
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let sonosEngine = sonos.map { playback in
            // The household's transport: with `-sonosFake`, the simulated household's.
            let engine = SonosEngine(target: playback.target, reference: playback.reference, transport: sonosTransport)
            #if DEBUG
            engine.log = { print("[sonos-engine] \($0)") }
            #endif
            return engine
        }
        switch provider {
        case .none:
            return PartySession(catalog: NoServiceCatalog(), engine: NoServiceEngine())
        case .appleMusic:
            let cache = SongCache()
            return PartySession(catalog: AppleMusicCatalog(cache: cache), engine: sonosEngine ?? AppleMusicEngine(cache: cache), storeURL: store)
        case .spotify:
            return PartySession(catalog: SpotifyCatalog(api: spotify), engine: sonosEngine ?? SpotifyEngine(api: spotify), storeURL: store)
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

    /// First-launch choice; always records it, even if it matches the default. Nothing is live
    /// yet, so there's no account check here: Start does that (`startZone`).
    func chooseProvider(_ next: Provider) {
        setProvider(next)
        defaults.set(next.rawValue, forKey: "provider")
    }

    func finishOnboarding() {
        needsOnboarding = false
    }

    /// The start screen's Music row, before Start only (a live zone's service changes only by
    /// ending it). Nothing is live, so this just swaps the private session. Spotify is signed in
    /// first (the row's sheet does that), then asks where music plays, as setup does; Apple Music
    /// asks for access if it hasn't yet, and a refusal shows in the row.
    func switchService(to next: Provider) {
        guard zoneRole == .hub, !isLive, !isStartingZone, next != provider else { return }
        chooseProvider(next)
        switch next {
        case .spotify:
            isPickingSpotifyDevice = true
        case .appleMusic:
            if MusicAuthorization.currentStatus == .notDetermined { Task { await requestAuthorization() } }
        default:
            break
        }
    }

    /// Only while nothing is live (setup, the start screen): the session is private, so it's
    /// simply replaced.
    func setProvider(_ next: Provider) {
        guard next != provider else { return }
        session.shutdown()
        provider = next
        defaults.set(next.rawValue, forKey: "provider")
        session = Self.makeSession(next, spotify: spotifyAPI, sonos: sonosPlayback, sonosTransport: sonos.transport)
        session.phonesCanReorder = phoneReorderEnabled
        // The new session gets this zone's settings, host control and web-page hooks, as at launch.
        configureHubSession()
        connectHostControl()
        libraryPlaylistsCache = []
        applyCrossfade()
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

    /// The Spotify sign-in page setting (nil: the default). Changing it keeps the current
    /// sign-in: only new sign-ins use it.
    func setSpotifySignInPage(_ page: String?) {
        SpotifyConfig.setOwnSignInPage(page)
        spotifyOwnSignInPage = SpotifyConfig.ownSignInPage
    }

    func signInToSpotify() async {
        spotifySignInClosed = false
        do {
            try await spotifyAuth.signIn()
            await refreshSpotifyProfile()
        } catch SpotifyError.signInCancelled {
            // "Cancel" on Spotify's own page: nothing to say.
        } catch SpotifyError.signInClosed {
            spotifySignInClosed = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The signed-in name, and the account's id for the zone announcement (only its fingerprint
    /// is kept, `SpotifyAuth.accountFingerprint`).
    func refreshSpotifyProfile() async {
        struct Me: Decodable { var id: String?; var display_name: String? }
        guard spotifyAuth.isSignedIn,
              let me = try? await spotifyAPI.get("/me", as: Me.self) else { return }
        spotifyDisplayName = me.display_name
        if let id = me.id { spotifyAuth.setAccount(userID: id) }
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
        if wasAvailable, !spotifyDeviceAvailable, provider == .spotify, !usesSonos, session.state.current != nil {
            isPickingSpotifyDevice = true
        }
    }

    func selectSpotifyDevice(_ device: SpotifyDevice) {
        let changed = device.id != spotifyDeviceID
        spotifyDeviceID = device.id
        spotifyDeviceName = device.name
        spotifyDeviceType = device.type
        // Choosing a Spotify Connect device means Spotify plays there, not on Sonos rooms. The
        // rebuild pauses the Sonos rooms and carries a song that was playing over to the device.
        let leftSonos = sonosOutput != nil
        if leftSonos {
            sonosOutput = nil
            rebuildSessionForOutput()
        }
        // Start found nowhere to play: it goes on, on this device.
        if startsWhenDeviceChosen {
            isPickingSpotifyDevice = false
            Task { await startZone() }
            return
        }
        // Mid-party, move playback to the new device (resuming targets it by id). Not after
        // leaving Sonos: the rebuild already plays there if the music was playing.
        if !leftSonos, changed, session.state.current != nil, session.isPlaying || isLocked {
            Task { await play() }
        }
    }

    private func applyCrossfade() {
        session.setCrossfade(enabled: crossfade, duration: crossfadeSeconds > 0 ? crossfadeSeconds : nil)
    }

    var isReady: Bool {
        switch provider {
        case .none: false
        // On Sonos, the account linked in the Sonos app streams: this device's own Apple Music
        // subscription, or Spotify device, doesn't matter.
        case .appleMusic: authorization == .authorized && (canPlayAppleMusic || usesSonos)
        case .spotify: spotifyAuth.isSignedIn && (spotifyDeviceAvailable || usesSonos)
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
        /// First-run setup, once ever: the service (`needsOnboarding`), then the zone's name and PIN.
        case creating
        /// This device's own zone: the start screen (pure setup, nothing live) until Start, then
        /// the live zone, where this device plays the music (`isLive`).
        case hub
        /// Showing another device's zone.
        case display
    }

    private(set) var zoneRole: ZoneRole
    var isDisplay: Bool { zoneRole == .display }
    /// The zone has started (or came back after a crash): it's recorded, the phone server runs,
    /// and it's announced with its `.local` name. False on the start screen, where nothing is.
    private(set) var isLive = false
    /// Start was pressed and the music is starting (the button shows a spinner).
    private(set) var isStartingZone = false
    var zoneName: String {
        didSet {
            defaults.set(zoneName, forKey: "zoneName")
            if !isDisplay { session.zoneName = zoneName }
            followZoneName()
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
    /// Whether this iPad has a zone, and how to come back into it (shared with the Apple TV app).
    @ObservationIgnored private let zoneRecord = ZoneRecord()
    /// Launching straight back into the zone; `startOnLaunch()` falls back to the list if it can't.
    @ObservationIgnored private var isRestoringZone = false
    /// A Spotify zone to go straight back into once no other zone turns out to be using the account.
    @ObservationIgnored private var restoresAfterSpotifyCheck = false
    @ObservationIgnored private var advertisedPlaying: String?
    #if DEBUG
    /// `-fakeSpotifyConflict`: a made-up account and a zone using it.
    @ObservationIgnored private var debugSpotifyAccount: String?
    private var debugZones: [ZoneListing] = []
    #endif

    /// Zones on the network other than this device's own.
    var otherZones: [ZoneListing] {
        var zones = zoneBrowser.zones
        #if DEBUG
        zones += debugZones
        #endif
        return zones.filter { $0.hubID != deviceID }
    }

    // MARK: One zone per Spotify account

    /// Another zone using this device's Spotify account, and what this device was about to do
    /// (Spotify plays one stream per account; two zones on one would fight over it).
    struct SpotifyAccountConflict {
        enum Trigger {
            /// Start on the start screen.
            case start
            /// Resume on the list, or the automatic restore at launch.
            case resume, restore
        }
        let zone: ZoneListing
        let trigger: Trigger
    }
    /// Shows "Another zone is using this Spotify account" until it's answered.
    private(set) var spotifyConflict: SpotifyAccountConflict?

    /// The account as zones announce it; nil while it isn't known (not fetched yet, e.g. offline).
    var spotifyAccountFingerprint: String? {
        #if DEBUG
        if let debugSpotifyAccount { return debugSpotifyAccount }
        #endif
        return spotifyAuth.isSignedIn ? spotifyAuth.accountFingerprint : nil
    }

    /// Before this device starts using its Spotify account: true if no zone on the network is
    /// already; otherwise asks (`spotifyConflict`) and nothing goes ahead until it's answered.
    /// Zones announcing the account are asked first whether they're really there (`ZoneProbe`,
    /// up to about 2 s): a stale announcement never blocks. An account not known yet doesn't block.
    /// False without asking if `stillWanted` no longer holds once the check is done (the person
    /// moved on meanwhile).
    private func spotifyAccountIsFree(for trigger: SpotifyAccountConflict.Trigger, if stillWanted: () -> Bool) async -> Bool {
        let zone = await zoneUsingSpotifyAccount()
        guard stillWanted() else { return false }
        guard let zone else { return true }
        spotifyConflict = SpotifyAccountConflict(zone: zone, trigger: trigger)
        return false
    }

    @ObservationIgnored private let zoneProbe = ZoneProbe()

    /// The first zone announcing this device's Spotify account that answers as itself, still on
    /// it; nil if none does.
    private func zoneUsingSpotifyAccount() async -> ZoneListing? {
        let fingerprint = spotifyAccountFingerprint
        #if DEBUG
        // `-fakeSpotifyConflict`: the made-up zone has no server to ask, so it isn't probed; it
        // counts as answering.
        if let fake = ZoneListing.usingSpotifyAccount(fingerprint, in: debugZones, ownHubID: deviceID).first { return fake }
        let log: (@Sendable (String) -> Void)? = { print("[zones] \($0)") }
        #else
        let log: (@Sendable (String) -> Void)? = nil
        #endif
        return await zoneProbe.zoneUsingSpotifyAccount(fingerprint, in: zoneBrowser.zones, ownHubID: deviceID, log: log)
    }

    /// Cancel: what asked doesn't happen, and the other zone is left alone. Start stays on the
    /// start screen; Resume and the restore at launch stay on the zone list.
    func cancelSpotifyConflict() {
        spotifyConflict = nil
    }

    /// Join: shows the other zone as a display instead; no Spotify session is kept here.
    func joinSpotifyConflict() {
        guard let conflict = spotifyConflict else { return }
        spotifyConflict = nil
        join(conflict.zone)
    }

    /// Launch: the zone browse's first results (or a definite "nothing"), for at most `seconds`.
    private func waitForZoneBrowse(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !zoneBrowser.hasSearched, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// This iPad has a zone that wasn't ended (and didn't come back by itself at launch), so the
    /// list offers to resume it, and creating a new zone asks first. Ending the zone clears it.
    var canResumeZone: Bool { zoneRecord.hasZone && provider != .none }

    /// The guest page shown in QR codes: this hub's, or the hub a display is showing.
    var guestURL: URL? {
        isDisplay ? session.lanAddress.flatMap { URL(string: "http://\($0)") } : localGuestURL
    }
    var friendlyURL: URL? {
        isDisplay ? session.guestAddress.flatMap { URL(string: "http://\($0)") } : localFriendlyURL
    }
    var showsGuestQR: Bool { isDisplay ? guestURL != nil && session.phonesCanQueue : phoneQueueEnabled }

    /// "Create a new zone" on the list. The first time (no service ever chosen) it runs setup:
    /// the service, then the zone's name and PIN (`ZoneRole.creating`). After that it goes straight
    /// to the start screen with the last name and PIN. A new zone always starts empty: a zone this
    /// device still had is ended first (the list asked). Nothing is live until Start.
    func beginCreatingZone() {
        clearZone()
        zoneRole = needsOnboarding ? .creating : .hub
    }

    func cancelCreatingZone() {
        zoneRole = .choosing
    }

    /// Setup's last step, name and PIN: on to the start screen.
    func finishCreatingZone(name: String, pin: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        zoneName = trimmed.isEmpty ? DeviceKind.name : String(trimmed.prefix(40))
        hostPIN = pin ?? ""
        zoneRole = .hub
    }

    /// Back to the zone list from the start screen, where nothing is live.
    func leaveStartScreen() {
        guard zoneRole == .hub, !isLive, !isStartingZone else { return }
        zoneRole = .choosing
    }

    /// The start screen's Start can be pressed: something to play, and the service ready. With
    /// Spotify, signed in is enough: no reachable device shows the device picker (`startZone`).
    var canStartZone: Bool {
        guard session.hasParty else { return false }
        return provider == .spotify ? spotifyAuth.isSignedIn : isReady
    }

    /// Start on the start screen. The zone goes live only once its music has actually started:
    /// then it's recorded, the phone server starts, the zone is announced under its `.local`
    /// name, and the party screen locks. With Spotify, another zone on the account asks first,
    /// and no reachable device shows "Where should music play?", which presses Start again once
    /// one is chosen. If the music can't start, nothing is live and the error shows.
    func startZone() async {
        guard zoneRole == .hub, !isLive, !isStartingZone else { return }
        // The spinner shows from here, while another zone on the account is checked too.
        isStartingZone = true
        defer { isStartingZone = false }
        if provider == .spotify, !(await spotifyAccountIsFree(for: .start, if: { zoneRole == .hub && !isLive })) { return }
        do {
            try await session.play()
        } catch SpotifyError.noDevice {
            spotifyDevices.removeAll { $0.id == spotifyDeviceID }
            isPickingSpotifyDevice = true
            startsWhenDeviceChosen = true
            await refreshSpotifyDevices()
            return
        } catch {
            errorMessage = "Couldn't start playback. \(error.localizedDescription)"
            return
        }
        // Left the start screen meanwhile (e.g. joined another zone): nothing goes live.
        guard zoneRole == .hub, !isLive else {
            session.pause()
            return
        }
        isLive = true
        zoneRecord.began()
        // The party screen comes up with its guest QR code (the spinner shows meanwhile).
        await startServerIfNeeded()
        if isLive { lock() }
    }

    /// Back into the zone this iPad had, paused, locked if it was: host mode stays behind the PIN.
    /// With Spotify, another zone on the account asks first (checked with that zone, so a tap
    /// may take up to about 2 s; a second tap meanwhile is ignored).
    func resumeZone() async {
        guard zoneRole == .choosing, !isCheckingResume else { return }
        if provider == .spotify {
            isCheckingResume = true
            defer { isCheckingResume = false }
            guard await spotifyAccountIsFree(for: .resume, if: { zoneRole == .choosing }) else { return }
        }
        resumeHosting()
    }
    @ObservationIgnored private var isCheckingResume = false

    private func resumeHosting() {
        zoneRole = .hub
        isLive = true
        zoneRecord.resumedHosting()
        if zoneRecord.wasLocked { lock() } else { isLocked = false }
        Task { await startServerIfNeeded() }
    }

    /// Launch: starts the phone server, and if this launch went straight back into the zone but it
    /// can't be announced, falls back to the zone list (which offers Resume), keeping the zone.
    func startOnLaunch() async {
        // Zones on the network: the list, and checking for another zone on this Spotify account.
        zoneBrowser.start()
        // Sonos rooms for the Speakers section (read-only until a room is chosen and played).
        sonos.start()
        // A sign-in from before zones announced their account (or one made offline).
        if spotifyAuth.isSignedIn, spotifyAuth.accountFingerprint == nil {
            Task { await refreshSpotifyProfile() }
        }
        if restoresAfterSpotifyCheck {
            restoresAfterSpotifyCheck = false
            await waitForZoneBrowse(seconds: 3)
            // Something chosen on the list meanwhile wins; a zone on this account asks there.
            guard zoneRole == .choosing, spotifyConflict == nil,
                  await spotifyAccountIsFree(for: .restore, if: { zoneRole == .choosing && spotifyConflict == nil }) else { return }
            resumeHosting()
            isRestoringZone = true
        }
        if isRestoringZone, isLocked { lock() } // keeps the screen awake, as locking does
        await startServerIfNeeded()
        guard isRestoringZone else { return }
        isRestoringZone = false
        if zoneRole == .hub, server == nil || session.lanAddress == nil {
            isLive = false
            zoneRole = .choosing
            isLocked = false
            UIApplication.shared.isIdleTimerDisabled = false
            await stopServer()
        }
    }

    /// Ends this zone and goes back to the start screen, with nothing live: stops the music, the
    /// server, the Bonjour announcement and the `.local` name, and clears the queue, history, base
    /// playlist and saved queue, so there's nothing to resume and the next zone starts empty.
    /// Settings stay.
    func endZone() {
        clearZone()
        isLive = false
        zoneRole = .hub
        isLocked = false
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await stopServer() }
    }

    /// Empties the queue and its saved copies and forgets the zone, so there's nothing to resume.
    private func clearZone() {
        session.end()
        // Queues saved under another service (from before a service change) would come back too.
        for other in Self.allProviders where other != provider {
            try? FileManager.default.removeItem(at: Self.storeURL(other))
        }
        zoneRecord.ended()
    }

    /// Shows another device's zone. Displays don't run a server or play anything.
    func join(_ zone: ZoneListing) {
        guard let url = zone.baseURL else { return }
        session.shutdown()
        isLive = false
        Task { await stopServer() }
        // A Mac shows up as an iPad-kind display (older hubs couldn't decode a new kind) that says
        // which Mac it is beside that, for its icon, with its own name, e.g. "MacBook Air".
        let connection = ZoneConnection(baseURL: url, clientID: deviceID, name: DeviceKind.name, kind: .ipad, device: DeviceKind.device)
        let mirror = PartySession(remote: connection)
        session = mirror
        connection.start(session: mirror)
        displayConnection = connection
        displayedZone = zone
        zoneRole = .display
        // A display starts at the zone list next time; this iPad's own zone stays resumable.
        zoneRecord.stoppedHosting()
        lock()
    }

    func leaveZone() {
        displayConnection?.stop()
        displayConnection = nil
        displayedZone = nil
        session.shutdown()
        session = Self.makeSession(provider, spotify: spotifyAPI, sonos: sonosPlayback, sonosTransport: sonos.transport)
        session.phonesCanReorder = phoneReorderEnabled
        configureHubSession()
        connectHostControl()
        applyCrossfade()
        zoneRole = .choosing
        isLocked = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func configureHubSession() {
        session.configureHub(kind: .ipad, device: DeviceKind.device, id: deviceID, zoneName: zoneName, serviceName: provider == .none ? nil : provider.title)
        session.displaysCanControl = displaysCanControl
        session.phonesCanQueue = phoneQueueEnabled
        session.wifi = WifiDetails(ssid: wifiSSID, password: wifiPassword, simpleQR: wifiSimpleQR)
        wireSonosEngine()
    }

    /// Announces this zone (or refreshes what's playing in the announcement). Only a live zone.
    func advertiseZone() {
        guard zoneRole == .hub, isLive, let server, let address = session.lanAddress else { return }
        let playing = session.nowPlaying.map { "\($0.track.title) – \($0.track.artist)" } ?? ""
        advertisedPlaying = playing
        var txt = [
            "name": zoneName, "kind": HubKind.ipad.rawValue, "addr": address, "hub": deviceID, "playing": String(playing.prefix(120)),
        ]
        // Which Mac this is, beside `kind=ipad` (older peers ignore it); nothing on an iPad.
        if let device = DeviceKind.device { txt["device"] = device }
        // The Spotify account (a fingerprint, never the id or name), so another device can see
        // it's in use before starting a zone on it. Only once known; never for Apple Music.
        if provider == .spotify, let account = spotifyAccountFingerprint {
            txt[ZoneService.spotifyAccountKey] = account
        }
        // `GET /api/zone` answers the same, for devices checking this zone is really here.
        session.announcedSpotifyAccount = txt[ZoneService.spotifyAccountKey]
        zoneAdvertiser.advertise(name: zoneName, port: server.port, txt: txt)
    }

    /// Called when the current song changes.
    func zoneSongChanged() {
        let playing = session.nowPlaying.map { "\($0.track.title) – \($0.track.artist)" } ?? ""
        if playing != advertisedPlaying { advertiseZone() }
    }

    // MARK: Host control

    /// The Host Control QR code: the guest page plus the key. Uses the IP so every phone resolves it;
    /// the page moves to the `.local` address itself when the phone can reach it.
    var hostControlURL: URL? {
        guard let guestURL else { return nil }
        return URL(string: "\(guestURL.absoluteString)/?host=\(hostControl.key)")
    }

    /// Revokes every phone with host control by replacing the key.
    func forgetHostPhones() {
        hostControl.forget()
        session.hostKey = hostControl.key
        session.hostPhoneCount = 0
    }

    private func connectHostControl() {
        hostControl.attach(to: session)
        // Settings changed by a host on the web page: keep ours in step and saved.
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            if let name = self.session.zoneName, name != self.zoneName { self.zoneName = name }
            if self.session.phonesCanReorder != self.phoneReorderEnabled { self.phoneReorderEnabled = self.session.phonesCanReorder }
            if self.session.displaysCanControl != self.displaysCanControl { self.displaysCanControl = self.session.displaysCanControl }
            if self.session.phonesCanQueue != self.phoneQueueEnabled { self.phoneQueueEnabled = self.session.phonesCanQueue }
            let wifi = self.session.wifi
            if wifi.ssid != self.wifiSSID { self.wifiSSID = wifi.ssid }
            if wifi.password != self.wifiPassword { self.wifiPassword = wifi.password }
            if wifi.simpleQR != self.wifiSimpleQR { self.wifiSimpleQR = wifi.simpleQR }
        }
        // A host stopped the zone from the web page (it asked them first): as ending it here does.
        session.onStopRequested = { [weak self] in self?.endZone() }
    }

    #if DEBUG
    /// `-screenshotParty`: swaps in a posed session and goes straight to the party screen, live
    /// (for its QR codes) but not recorded, so nothing comes back after a relaunch.
    func installScreenshotSession(_ session: PartySession) {
        provider = .appleMusic
        self.session = session
        configureHubSession()
        connectHostControl()
        needsOnboarding = false
        isLive = true
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
            guard self.isLive, self.zoneRole == .hub else { return }
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
        // Only a live zone runs the phone server: the start screen has none.
        guard isLive, zoneRole == .hub else { return }
        guard let (server, task) = await PartyServer.start(session: session) else {
            localGuestURL = nil
            localFriendlyURL = nil
            return
        }
        self.server = server
        serverTask = task
        refreshAddresses()
    }

    /// The `.local` address guests can type: the confirmed one, or the one being checked.
    var localAddress: String {
        localFriendlyURL?.host ?? "\(FriendlyHostname.localName(forZone: zoneName)).local"
    }

    /// The `.local` name follows the zone name: a renamed zone announces its new name, which is
    /// handed out once it's confirmed (`watchHostnameRenames`).
    private func followZoneName() {
        guard hostname.rename(to: FriendlyHostname.localName(forZone: zoneName)) else { return }
        localFriendlyURL = nil
        if !isDisplay { session.guestAddress = nil }
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

    /// The guest Wi‑Fi for the "Join Wi‑Fi" code: this hub's own, or (display) its hub's, from snapshots.
    var shownWifi: WifiDetails {
        isDisplay ? session.wifi : WifiDetails(ssid: wifiSSID, password: wifiPassword, simpleQR: wifiSimpleQR)
    }

    var wifiJoinPayload: String? {
        let wifi = shownWifi
        return wifi.ssid.isEmpty ? nil : LocalNetwork.wifiJoinPayload(ssid: wifi.ssid, password: wifi.password)
    }

    // MARK: Sonos output

    /// Rooms chosen as the output, and how to reach them (kept, so a relaunch plays there before
    /// discovery has run again).
    struct SonosOutput: Codable, Equatable {
        /// The first leads the group.
        var roomIDs: [String]
        var target: SonosTarget
    }

    /// What a `SonosEngine` needs.
    struct SonosPlayback: Equatable {
        var target: SonosTarget
        var reference: SonosTrackReference
    }

    let sonos: SonosHousehold
    #if DEBUG
    @ObservationIgnored private var debugSelectedSonos = false
    #endif
    /// nil: music plays on this device (AirPlay) or, for Spotify, the chosen Spotify Connect device.
    /// Kept in step with the engine's rooms as they join and leave, so a relaunch plays there.
    private(set) var sonosOutput: SonosOutput? {
        didSet {
            guard !Self.isSonosFake else { return }
            defaults.set(try? JSONEncoder().encode(sonosOutput), forKey: "sonosOutput")
        }
    }
    /// The account Sonos streams from, per service (`SonosMusicService.rawValue`), as chosen.
    private(set) var sonosChosenAccounts: [String: SonosAccount] {
        didSet {
            guard !Self.isSonosFake else { return }
            defaults.set(try? JSONEncoder().encode(sonosChosenAccounts), forKey: "sonosAccounts")
        }
    }
    /// Rooms on their way into the group (a spinner, "Joining…"), until Sonos has them in it.
    private(set) var sonosJoining: Set<String> = []

    /// `-sonosFake`: a simulated household (`SonosFakeHousehold`) instead of the real speakers.
    static var isSonosFake: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-sonosFake")
        #else
        false
        #endif
    }

    private static func makeHousehold() -> SonosHousehold {
        #if DEBUG
        if isSonosFake {
            let simulator = SonosFakeHousehold.make()
            return SonosHousehold(transport: simulator, fixedHosts: simulator.rooms.map(\.host))
        }
        #endif
        return SonosHousehold()
    }

    private static func loadSonosOutput() -> SonosOutput? {
        if isSonosFake { return nil }
        return UserDefaults.standard.data(forKey: "sonosOutput").flatMap { try? JSONDecoder().decode(SonosOutput.self, from: $0) }
    }

    private static func loadSonosAccounts() -> [String: SonosAccount] {
        if isSonosFake { return [:] }
        return UserDefaults.standard.data(forKey: "sonosAccounts").flatMap { try? JSONDecoder().decode([String: SonosAccount].self, from: $0) } ?? [:]
    }

    /// The zone's service as Sonos knows it; nil for no service (and the demo).
    var sonosService: SonosMusicService? { Self.sonosService(for: provider) }

    private static func sonosService(for provider: Provider) -> SonosMusicService? {
        switch provider {
        case .appleMusic: .appleMusic
        case .spotify: .spotify
        default: nil
        }
    }

    /// Linked accounts found for the zone's service.
    var sonosAccountsForZone: [SonosAccount] {
        sonosService.map(sonos.accounts(for:)) ?? []
    }

    /// The account that streams the zone's songs: the one chosen for the service, else the first found.
    var sonosAccount: SonosAccount? {
        guard let service = sonosService else { return nil }
        return Self.account(for: service, chosen: sonosChosenAccounts, found: sonosAccountsForZone)
    }

    private static func account(for service: SonosMusicService, chosen: [String: SonosAccount], found: [SonosAccount]) -> SonosAccount? {
        guard let pick = chosen[service.rawValue] else { return found.first }
        // A newer reading of the same account (its token) wins.
        return found.first { $0.id == pick.id } ?? pick
    }

    private var sonosPlayback: SonosPlayback? {
        Self.makeSonosPlayback(provider, output: sonosOutput, accounts: sonosChosenAccounts, found: sonosAccountsForZone)
    }

    private static func makeSonosPlayback(_ provider: Provider, output: SonosOutput?, accounts: [String: SonosAccount], found: [SonosAccount]) -> SonosPlayback? {
        guard let output, let service = sonosService(for: provider),
              let account = account(for: service, chosen: accounts, found: found) else { return nil }
        return SonosPlayback(target: output.target, reference: SonosTrackReference(service: service, accountSerial: account.serialNumber, token: account.token))
    }

    /// The zone's songs play on Sonos rooms.
    var usesSonos: Bool { sonosPlayback != nil }

    /// The session's engine when it plays through Sonos.
    var sonosEngine: SonosEngine? { session.engine as? SonosEngine }

    /// The zone's music is playing through Sonos rooms right now (the party has started there),
    /// so ticked rooms say "Playing Canopy Music".
    var sonosIsLive: Bool { sonosEngine?.isGrouped == true }

    /// The engine's rooms as they change (joining, leaving, a new coordinator) are the output.
    private func wireSonosEngine() {
        guard let engine = sonosEngine else { return }
        engine.restoredTrackID = session.state.current?.track.id
        engine.onTargetChanged = { [weak self, weak engine] target in
            guard let self, let engine, self.sonosEngine === engine else { return }
            self.sonosOutput = SonosOutput(roomIDs: target.rooms.map(\.id), target: target)
            self.sonos.preferredHost = target.coordinator.host
        }
        sonos.preferredHost = engine.target.coordinator.host
    }

    /// Switches the zone's music to these rooms (the first leads; the others join its group when
    /// music starts), from this device or a Spotify Connect device: the session is rebuilt, with
    /// a gap. Picks the first account found for the service if none is chosen yet.
    func selectSonos(rooms roomIDs: [String]) {
        guard !roomIDs.isEmpty, let target = sonos.target(rooms: roomIDs) else { return useThisDevice() }
        if let service = sonosService, sonosChosenAccounts[service.rawValue] == nil, let first = sonosAccountsForZone.first {
            sonosChosenAccounts[service.rawValue] = first
        }
        sonosOutput = SonosOutput(roomIDs: target.rooms.map(\.id), target: target)
        rebuildSessionForOutput()
    }

    /// Back to this device (AirPlay), or for Spotify its Spotify Connect device. Start screen only.
    func useThisDevice() {
        guard sonosOutput != nil else { return }
        sonosOutput = nil
        rebuildSessionForOutput()
    }

    func isSonosRoomTicked(_ roomID: String) -> Bool {
        sonosOutput?.roomIDs.contains(roomID) == true
    }

    /// A room's row was tapped (start screen picker or the party screen's Speakers panel).
    func toggleSonosRoom(_ roomID: String) {
        if isSonosRoomTicked(roomID) { removeSonosRoom(roomID) } else { addSonosRoom(roomID) }
    }

    /// Adds a room. Not on Sonos yet: the music moves there (a rebuild, with a gap). On Sonos and
    /// playing: it joins the group without a restart, and shows "Joining…" until it's in it.
    /// Before the music has started there: it's just added to the rooms.
    func addSonosRoom(_ roomID: String) {
        guard let player = sonos.player(roomID), !sonosJoining.contains(roomID) else { return }
        guard let output = sonosOutput else { return selectSonos(rooms: [roomID]) }
        guard let engine = sonosEngine else {
            // No account to stream from yet: only the choice changes.
            if let target = sonos.target(rooms: output.roomIDs + [roomID]) { sonosOutput = SonosOutput(roomIDs: target.rooms.map(\.id), target: target) }
            return
        }
        let room = SonosHousehold.room(player)
        guard engine.isGrouped else {
            if let target = sonos.target(rooms: output.roomIDs + [roomID]) { engine.retarget(target) }
            return
        }
        sonosJoining.insert(roomID)
        let session = session
        Task {
            defer { sonosJoining.remove(roomID) }
            do {
                try await session.withEngine { try await engine.addRoom(room) }
                if !(await engine.waitUntilGrouped(roomID)) {
                    errorMessage = "\(room.name) didn't join. Check it's on and on this Wi\u{2011}Fi."
                }
            } catch {
                errorMessage = "Couldn't add \(room.name). \(error.localizedDescription)"
            }
            await sonos.readRooms(ourCoordinatorID: engine.target.coordinator.id)
        }
    }

    /// Takes a room out, the music playing on in the others without a restart (the coordinator
    /// first hands the group to another room). The last room on the start screen goes back to this
    /// device (or the Spotify Connect device); the Speakers panel doesn't offer that.
    func removeSonosRoom(_ roomID: String) {
        guard let output = sonosOutput, output.roomIDs.contains(roomID) else { return }
        guard output.roomIDs.count > 1 else { return useThisDevice() }
        guard let engine = sonosEngine else {
            let rest = output.roomIDs.filter { $0 != roomID }
            if let target = sonos.target(rooms: rest) { sonosOutput = SonosOutput(roomIDs: rest, target: target) }
            return
        }
        let session = session
        Task {
            do {
                try await session.withEngine { try await engine.removeRoom(roomID) }
            } catch {
                errorMessage = "Couldn't take \(sonos.player(roomID)?.roomName ?? "the room") out. \(error.localizedDescription)"
            }
            await sonos.readRooms(ourCoordinatorID: engine.target.coordinator.id)
        }
    }

    /// "Whose account plays".
    func chooseSonosAccount(_ account: SonosAccount) {
        guard let service = sonosService else { return }
        sonosChosenAccounts[service.rawValue] = account
        rebuildSessionForOutput()
    }

    // MARK: Sonos volume

    /// Sets one room's volume (the Speakers panel's sliders send at most every ~150 ms).
    func setSonosVolume(_ volume: Int, room roomID: String) {
        guard let player = sonos.player(roomID) else { return }
        sonos.noteVolume(volume, for: roomID)
        let client = SonosClient(transport: sonos.transport, host: player.host)
        Task { try? await client.setVolume(volume) }
    }

    /// Before the All Speakers slider moves: Sonos remembers each room's volume, so the group
    /// volume keeps their balance.
    func beginSonosGroupVolume() {
        guard let engine = sonosEngine else { return }
        let client = SonosClient(transport: sonos.transport, host: engine.target.coordinator.host)
        Task { try? await client.snapshotGroupVolume() }
    }

    /// The group's volume (the average of its rooms'), each room moved in proportion.
    func setSonosGroupVolume(_ volume: Int) {
        guard let engine = sonosEngine else { return }
        let client = SonosClient(transport: sonos.transport, host: engine.target.coordinator.host)
        Task { try? await client.setGroupVolume(volume) }
    }

    /// Reads volumes, groups and what each room is playing (while a speaker list shows).
    func readSonosRooms() async {
        await sonos.readRooms(ourCoordinatorID: sonosIsLive ? sonosEngine?.target.coordinator.id : nil)
    }

    /// Discovery has news: rooms may have new addresses, accounts may have turned up. New
    /// addresses go into the output (and an engine that hasn't played yet); the session is
    /// rebuilt if the account it streams from changed, unless it's playing right now.
    private func sonosRefreshed() {
        #if DEBUG
        // `-sonosSelect <room name>`: chooses that room once it's found, as tapping it would
        // (nothing is sent to it until Start). For checking the chosen state's layout.
        let args = ProcessInfo.processInfo.arguments
        if !debugSelectedSonos, let i = args.firstIndex(of: "-sonosSelect"), i + 1 < args.count,
           let room = sonos.rooms.first(where: { $0.roomName == args[i + 1] }) {
            debugSelectedSonos = true
            selectSonos(rooms: [room.id])
            return
        }
        #endif
        if let output = sonosOutput {
            var target = output.target
            target.coordinator.host = sonos.player(target.coordinator.id)?.host ?? target.coordinator.host
            for index in target.joining.indices {
                target.joining[index].host = sonos.player(target.joining[index].id)?.host ?? target.joining[index].host
            }
            // The fallback for a first play that can't read the layout (it's read live then),
            // kept current rather than as saved. Not once the engine has grouped: it owns that.
            if sonosEngine?.isGrouped != true, let group = sonos.group(containing: target.coordinator.id) {
                target.leavesGroup = group.coordinatorID != target.coordinator.id
            }
            if target != output.target {
                sonosOutput = SonosOutput(roomIDs: target.rooms.map(\.id), target: target)
                if let engine = sonosEngine, !engine.isGrouped { engine.retarget(target) }
            }
        }
        let current = sonosEngine.map { SonosPlayback(target: $0.target, reference: $0.reference) }
        guard current != sonosPlayback, !session.isPlaying else { return }
        rebuildSessionForOutput()
    }

    /// Swaps the session for one that plays through the current output: moving between this
    /// device (or a Spotify Connect device) and Sonos, or a new Sonos account. The queue carries
    /// over (it's saved, and read back), and so does a song in progress, from where it was.
    ///
    /// Only the new output plays: the old session is shut down first, which pauses the old
    /// output if (and only if) it was playing this zone's music, and stops every loop of its
    /// engine, so nothing there can start the music again.
    private func rebuildSessionForOutput() {
        guard zoneRole != .display, !isStartingZone else { return }
        let wasPlaying = session.isPlaying
        let position = session.engine.currentTime
        let hadSong = session.state.current != nil
        session.shutdown()
        session = Self.makeSession(provider, spotify: spotifyAPI, sonos: sonosPlayback, sonosTransport: sonos.transport)
        session.phonesCanReorder = phoneReorderEnabled
        configureHubSession()
        connectHostControl()
        applyCrossfade()
        if isLive { Task { await restartServer() } }
        guard wasPlaying, hadSong else { return }
        let rebuilt = session
        Task {
            // Rebuilt again meanwhile: that rebuild decides what plays.
            guard session === rebuilt else { return }
            await play()
            if position > 1, session === rebuilt { session.seek(to: position) }
        }
    }

    #if DEBUG
    /// `-sonosFakeParty <1|2>`: the party screen, live, playing through the simulated household
    /// (`-sonosFake`) in Bedroom (and Move): made-up Apple Music songs, nothing sent anywhere.
    func startFakeSonosParty(rooms count: Int) async {
        while sonos.rooms.count < 3 || sonos.isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
        let names = Array(["Bedroom", "Move"].prefix(max(1, count)))
        let ids = names.compactMap { name in sonos.rooms.first { $0.roomName == name }?.id }
        guard let target = sonos.target(rooms: ids), let account = sonos.accounts(for: .appleMusic).first else { return }
        provider = .appleMusic
        authorization = .authorized
        needsOnboarding = false
        sonosChosenAccounts[SonosMusicService.appleMusic.rawValue] = account
        sonosOutput = SonosOutput(roomIDs: ids, target: target)
        session.shutdown()
        let engine = SonosEngine(target: target, reference: SonosTrackReference(service: .appleMusic, accountSerial: account.serialNumber),
                                 transport: sonos.transport)
        engine.log = { print("[sonos-engine] \($0)") }
        session = PartySession(catalog: FixedCatalog(tracks: SonosFakeHousehold.songs), engine: engine)
        session.phonesCanReorder = phoneReorderEnabled
        configureHubSession()
        connectHostControl()
        try? await session.load(playlist: PlaylistSummary(id: "fake", name: "Saturday Night", kind: .library))
        try? await session.play()
        zoneRole = .hub
        isLive = true
        lock()
        await restartServer()
    }
    #endif
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
