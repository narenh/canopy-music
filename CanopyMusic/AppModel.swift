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

    func load(_ playlist: PlaylistSummary) async {
        do {
            try await session.load(playlist: playlist, shuffle: shuffle)
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
