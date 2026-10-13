import CanopyMusicCore
import CanopyMusicServer
import Foundation

/// Spotify on an Apple TV hub: the sign-in a host runs from their phone, the Spotify Connect
/// device music plays on, and what the host's setup page is told (`SpotifySetup`). The TV can't
/// be the speaker itself: Spotify's tvOS app is only a Connect device while it's open, and
/// Canopy Music is the app on screen. Playback is the iPad's `SpotifyEngine` (follow mode).
@MainActor
@Observable
final class TVSpotify {
    let auth: SpotifyAuth
    let api: SpotifyAPI
    @ObservationIgnored let signIn = SpotifyHubSignIn()

    private(set) var clientID = SpotifyConfig.clientID
    private(set) var ownSignInPage = SpotifyConfig.ownSignInPage
    private(set) var displayName: String? {
        didSet { UserDefaults.standard.set(displayName, forKey: "spotifyDisplayName") }
    }
    /// Devices Spotify lists now (only ones with Spotify open and awake); nil until first read.
    private(set) var devices: [SpotifyDevice]?
    private(set) var deviceID: String? {
        didSet { UserDefaults.standard.set(deviceID, forKey: SpotifyEngine.deviceDefaultsKey) }
    }
    private(set) var deviceName: String? {
        didSet { UserDefaults.standard.set(deviceName, forKey: "spotifyDeviceName") }
    }
    /// Called when anything the host's page shows changes.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshing = false

    #if DEBUG
    /// `-spotifyFake notSetUp|signedOut|signedIn|noDevice|asleep|conflict`: Spotify's state as
    /// the setup page shows it, without a Spotify account (the simulator can't sign in). Music
    /// plays from the demo player, as Spotify would (late staging, the next song locked).
    enum Fake: String { case notSetUp, signedOut, signedIn, noDevice, asleep, conflict }
    let fake: Fake? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-spotifyFake"), i + 1 < args.count else { return nil }
        return Fake(rawValue: args[i + 1])
    }()
    #endif

    init() {
        auth = SpotifyAuth()
        api = SpotifyAPI(auth: auth)
        displayName = UserDefaults.standard.string(forKey: "spotifyDisplayName")
        deviceID = UserDefaults.standard.string(forKey: SpotifyEngine.deviceDefaultsKey)
        deviceName = UserDefaults.standard.string(forKey: "spotifyDeviceName")
        signIn.configuration = { [weak self] in
            guard let self, !self.clientID.isEmpty else { return nil }
            return (clientID: self.clientID, redirectURI: SpotifyConfig.redirectURI)
        }
        signIn.exchange = { [weak self] request, code in
            guard let self else { return }
            try await self.auth.complete(request, code: code)
            await self.refresh(force: true)
        }
        signIn.onChange = { [weak self] in self?.onChange?() }
        auth.onAccountChanged = { [weak self] in self?.onChange?() }
        #if DEBUG
        applyFake()
        #endif
    }

    var isFake: Bool {
        #if DEBUG
        fake != nil
        #else
        false
        #endif
    }

    /// Signed in, as far as the TV knows (a fake sign-in counts).
    var isSignedIn: Bool {
        #if DEBUG
        if let fake { return ![.notSetUp, .signedOut].contains(fake) }
        #endif
        return auth.isSignedIn
    }

    /// The account as zones announce it (`SpotifyAccount.fingerprint`); nil until known.
    var accountFingerprint: String? {
        #if DEBUG
        if fake != nil { return isSignedIn ? SpotifyAccount.fingerprint(userID: "debug-user") : nil }
        #endif
        return auth.isSignedIn ? auth.accountFingerprint : nil
    }

    // MARK: Settings from the host's page

    /// A different developer app: the sign-in (and device) no longer apply.
    func setClientID(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != clientID else { return }
        UserDefaults.standard.set(id, forKey: SpotifyConfig.clientIDDefaultsKey)
        clientID = id
        #if DEBUG
        if fake != nil { onChange?(); return }
        #endif
        signIn.cancel()
        auth.signOut()
        displayName = nil
        devices = nil
        deviceID = nil
        deviceName = nil
        onChange?()
    }

    /// Checked on the TV (the phone never needs to reach the page), and saved if it passes.
    /// Keeps the sign-in: only new sign-ins use it.
    func setSignInPage(_ typed: String) async -> SpotifyRelay.PageCheck {
        let (check, page) = await SpotifyConfig.checkSignInPage(typed)
        if check == .ok {
            SpotifyConfig.setOwnSignInPage(page)
            ownSignInPage = SpotifyConfig.ownSignInPage
            onChange?()
        }
        return check
    }

    func chooseDevice(id: String) -> Bool {
        guard let device = devices?.first(where: { $0.id == id }) else { return false }
        deviceID = device.id
        deviceName = device.name
        onChange?()
        return true
    }

    // MARK: Reading Spotify

    /// The signed-in name (and the account for the zone announcement) and the devices. At most
    /// every 3 s: the setup page asks every 4 s while it isn't ready.
    func refresh(force: Bool = false) async {
        guard !isFake, auth.isSignedIn, !refreshing, force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        refreshing = true
        defer { refreshing = false }
        lastRefresh = Date()
        if displayName == nil || auth.accountFingerprint == nil || force {
            struct Me: Decodable { var id: String?; var display_name: String? }
            if let me = try? await api.get("/me", as: Me.self) {
                displayName = me.display_name
                if let id = me.id { auth.setAccount(userID: id) }
            }
        }
        struct Reply: Decodable { var devices: [SpotifyDevice] }
        if let reply = try? await api.get("/me/player/devices", as: Reply.self) {
            devices = reply.devices.filter { $0.id != nil }
            // Nothing chosen yet: whatever Spotify is playing on.
            if deviceID == nil, let active = devices?.first(where: \.is_active) {
                deviceID = active.id
                deviceName = active.name
            } else if let id = deviceID, let device = devices?.first(where: { $0.id == id }) {
                deviceName = device.name
            }
        }
        onChange?()
    }

    // MARK: What the host's page is told

    /// `conflict`: another zone on the network playing from this account.
    func setup(conflict: ZoneListing?) -> SpotifySetup {
        let account: SpotifySetup.Account = clientID.isEmpty ? .notSetUp : isSignedIn ? .signedIn : .signedOut
        var error: String?
        if case .failed(let reason) = signIn.lastOutcome {
            // Spotify's own error codes ("server_error") are said as such; ours are sentences.
            error = reason.contains(" ") ? reason : "Spotify said “\(reason)”. Try again."
        }
        return SpotifySetup(
            account: account, clientID: clientID, displayName: isSignedIn ? displayName : nil,
            signInPage: SpotifyConfig.redirectURI, ownSignInPage: ownSignInPage,
            signingIn: signIn.isBusy, signInError: error,
            devices: isSignedIn ? devices?.compactMap { device in
                device.id.map { SpotifySetup.Device(id: $0, name: device.name, type: device.type, isActive: device.is_active) }
            } : nil,
            deviceID: deviceID, deviceName: deviceName,
            conflictZone: conflict?.name, conflictAddress: conflict?.address
        )
    }

    #if DEBUG
    private func applyFake() {
        guard let fake else { return }
        let sonos = SpotifyDevice(id: "debug-sonos", name: "Sonos Move", type: "Speaker", is_active: false)
        let phone = SpotifyDevice(id: "debug-phone", name: "Naren's iPhone", type: "Smartphone", is_active: true)
        clientID = fake == .notSetUp ? "" : "4c1e8a07b5f94d2f0e6a1b39c7d2d2f0"
        displayName = "Naren"
        switch fake {
        case .notSetUp, .signedOut:
            devices = nil
            deviceID = nil
            deviceName = nil
        case .signedIn, .conflict:
            devices = [sonos, phone]
            deviceID = sonos.id
            deviceName = sonos.name
        case .noDevice:
            devices = []
            deviceID = nil
            deviceName = nil
        case .asleep:
            devices = [phone]
            deviceID = sonos.id
            deviceName = sonos.name
        }
    }
    #endif
}
