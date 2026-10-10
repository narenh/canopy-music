import CanopyCore
import CanopyServer
import Foundation
import MusicKit
import UIKit

/// App-wide state: which provider is active, the party session, the phone server, and host settings.
@MainActor
@Observable
final class AppModel {
    enum Provider: String { case appleMusic, demo }

    private(set) var provider: Provider
    private(set) var session: PartySession
    private(set) var isLocked = false
    private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    private(set) var guestURL: URL?
    private(set) var friendlyURL: URL?
    var errorMessage: String?

    var hostPIN: String { didSet { defaults.set(hostPIN, forKey: "hostPIN") } }
    var shuffle: Bool { didSet { defaults.set(shuffle, forKey: "shuffle") } }
    var crossfade: Bool {
        didSet {
            defaults.set(crossfade, forKey: "crossfade")
            session.setCrossfade(crossfade)
        }
    }
    var wifiSSID: String { didSet { defaults.set(wifiSSID, forKey: "wifiSSID") } }
    var wifiPassword: String { didSet { defaults.set(wifiPassword, forKey: "wifiPassword") } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var server: PartyServer?
    @ObservationIgnored private var serverTask: Task<Void, Error>?
    @ObservationIgnored private let hostname = FriendlyHostname(name: "canopymusic")

    init() {
        #if targetEnvironment(simulator)
        let fallback = Provider.demo
        #else
        let fallback = Provider.appleMusic
        #endif
        let provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? fallback
        self.provider = provider
        self.session = Self.makeSession(provider)
        hostPIN = defaults.string(forKey: "hostPIN") ?? ""
        shuffle = defaults.object(forKey: "shuffle") as? Bool ?? true
        crossfade = defaults.bool(forKey: "crossfade")
        wifiSSID = defaults.string(forKey: "wifiSSID") ?? ""
        wifiPassword = defaults.string(forKey: "wifiPassword") ?? ""
        session.setCrossfade(crossfade)

        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    private static func makeSession(_ provider: Provider) -> PartySession {
        let store = URL.applicationSupportDirectory.appending(path: "party-\(provider.rawValue).json")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        switch provider {
        case .appleMusic:
            let cache = SongCache()
            return PartySession(catalog: AppleMusicCatalog(cache: cache), engine: AppleMusicEngine(cache: cache), storeURL: store)
        case .demo:
            return PartySession(catalog: DemoCatalog(), engine: DemoPlaybackEngine(), storeURL: store)
        }
    }

    // MARK: Provider

    var isDemo: Bool { provider == .demo }

    func setDemoMode(_ demo: Bool) {
        let next: Provider = demo ? .demo : .appleMusic
        guard next != provider else { return }
        session.engine.pause()
        provider = next
        defaults.set(next.rawValue, forKey: "provider")
        session = Self.makeSession(next)
        session.setCrossfade(crossfade)
        Task { await restartServer() }
    }

    var isReady: Bool { isDemo || authorization == .authorized }

    func requestAuthorization() async {
        authorization = await MusicAuthorization.request()
    }

    // MARK: Party

    func start(_ playlist: PlaylistSummary) async {
        do {
            try await session.start(playlist: playlist, shuffle: shuffle)
        } catch {
            errorMessage = "Couldn't load “\(playlist.name)”. \(error.localizedDescription)"
        }
    }

    func resumeRestoredParty() async {
        do {
            try await session.resumeRestoredParty()
        } catch {
            errorMessage = "Couldn't resume. \(error.localizedDescription)"
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
        if server != nil {
            refreshAddresses()
            return
        }
        await restartServer()
    }

    func restartServer() async {
        serverTask?.cancel()
        await server?.stop()
        server = nil
        guard let (server, task) = await PartyServer.start(session: session) else {
            guestURL = nil
            friendlyURL = nil
            return
        }
        self.server = server
        serverTask = task
        refreshAddresses()
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

    var wifiJoinPayload: String? {
        wifiSSID.isEmpty ? nil : LocalNetwork.wifiJoinPayload(ssid: wifiSSID, password: wifiPassword)
    }
}
