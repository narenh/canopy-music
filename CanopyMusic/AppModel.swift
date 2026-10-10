import AVFoundation
import CanopyCore
import CanopyServer
import Foundation
import MusicKit
import SwiftUI
import UIKit

/// App-wide state: which provider is active, the party session, the phone server, and host settings.
@MainActor
@Observable
final class AppModel {
    enum Provider: String, CaseIterable {
        case appleMusic, spotify
        #if DEBUG
        /// Fake songs, no audio. Debug builds only.
        case demo
        #endif

        var title: String {
            switch self {
            case .appleMusic: "Apple Music"
            case .spotify: "Spotify"
            #if DEBUG
            case .demo: "Demo"
            #endif
            }
        }

        /// App tint: Apple Music red, Spotify green, Canopy green for the demo.
        var accent: Color {
            switch self {
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
    let spotifyAPI: SpotifyAPI
    /// The Spotify Connect device to play on, by id (the iPad's Spotify app, an Apple TV…).
    var spotifyDeviceID: String? {
        didSet { UserDefaults.standard.set(spotifyDeviceID, forKey: SpotifyEngine.deviceDefaultsKey) }
    }
    var spotifyDeviceName: String? {
        didSet { UserDefaults.standard.set(spotifyDeviceName, forKey: "spotifyDeviceName") }
    }

    private(set) var provider: Provider
    private(set) var session: PartySession
    private(set) var isLocked = false
    private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    /// Apple Music playback needs a subscription; search works without one. Kept current by
    /// `MusicSubscription.subscriptionUpdates` once authorized.
    private(set) var canPlayAppleMusic = true
    private(set) var canBecomeAppleMusicSubscriber = false
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    private(set) var guestURL: URL?
    private(set) var friendlyURL: URL?
    var errorMessage: String?

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
    /// The `<name>.local` address guests can type. Set through `setLocalName(_:)`.
    private(set) var localName: String
    /// Runs the LAN web server guests use to queue from their phones.
    var phoneQueueEnabled: Bool {
        didSet {
            defaults.set(phoneQueueEnabled, forKey: "phoneQueueEnabled")
            Task { phoneQueueEnabled ? await restartServer() : await stopServer() }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    @ObservationIgnored private var hostname = FriendlyHostname(name: "music")

    init() {
        #if DEBUG && targetEnvironment(simulator)
        let fallback = Provider.demo
        #else
        let fallback = Provider.appleMusic
        #endif
        let provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? fallback
        self.provider = provider
        var needsOnboarding = defaults.string(forKey: "provider") == nil
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
        self.session = Self.makeSession(provider, spotify: spotifyAPI)
        hostPIN = defaults.string(forKey: "hostPIN") ?? ""
        crossfade = defaults.bool(forKey: "crossfade")
        crossfadeSeconds = defaults.double(forKey: "crossfadeSeconds")
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        wifiPassword = defaults.string(forKey: "wifiPassword") ?? ""
        phoneQueueEnabled = defaults.object(forKey: "phoneQueueEnabled") as? Bool ?? true
        let savedName = Self.sanitizedLocalName(defaults.string(forKey: "localName") ?? "")
        localName = savedName
        hostname = FriendlyHostname(name: savedName)
        applyCrossfade()
        watchAppleMusicSubscription()

        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)

        // Long-form audio is what lets the AirPlay picker select several AirPlay 2 speakers at once.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private static func makeSession(_ provider: Provider, spotify: SpotifyAPI) -> PartySession {
        let store = URL.applicationSupportDirectory.appending(path: "party-\(provider.rawValue).json")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        switch provider {
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

    func finishOnboarding() {
        needsOnboarding = false
    }

    func setProvider(_ next: Provider) {
        guard next != provider else { return }
        session.engine.pause()
        provider = next
        defaults.set(next.rawValue, forKey: "provider")
        session = Self.makeSession(next, spotify: spotifyAPI)
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
    }

    func signInToSpotify() async {
        do {
            try await spotifyAuth.signIn()
        } catch SpotifyError.signInCancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func spotifyDevices() async -> [SpotifyDevice] {
        struct Reply: Decodable { var devices: [SpotifyDevice] }
        do {
            return try await spotifyAPI.get("/me/player/devices", as: Reply.self)?.devices ?? []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func applyCrossfade() {
        session.setCrossfade(enabled: crossfade, duration: crossfadeSeconds > 0 ? crossfadeSeconds : nil)
    }

    var isReady: Bool {
        switch provider {
        case .appleMusic: authorization == .authorized && canPlayAppleMusic
        case .spotify: spotifyAuth.isSignedIn && spotifyDeviceID != nil
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
        } catch {
            errorMessage = "Couldn't start playback. \(error.localizedDescription)"
        }
    }

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
        guard phoneQueueEnabled else { return }
        if server != nil {
            refreshAddresses()
            return
        }
        await restartServer()
    }

    func restartServer() async {
        await stopServer()
        guard phoneQueueEnabled else { return }
        guard let (server, task) = await PartyServer.start(session: session) else {
            guestURL = nil
            friendlyURL = nil
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
        refreshAddresses()
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

    func stopServer() async {
        serverTask?.cancel()
        serverTask = nil
        await server?.stop()
        server = nil
        hostname.unregister()
        guestURL = nil
        friendlyURL = nil
    }

    func refreshAddresses() {
        guard let server, let ip = LocalNetwork.lanAddress() else {
            guestURL = nil
            friendlyURL = nil
            return
        }
        guestURL = server.url(host: ip)
        friendlyURL = hostname.register(address: ip) ? server.url(host: hostname.hostname) : nil
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
        wifiSSID.isEmpty ? nil : LocalNetwork.wifiJoinPayload(ssid: wifiSSID, password: wifiPassword)
    }
}
