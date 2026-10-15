import CanopyMusicCore
import dnssd
import Foundation
import Network
import Observation

// Zones: one hub per zone advertises `_canopymusic._tcp`; other Canopy devices browse for it and join
// as displays (docs/multi-device.md).

public enum ZoneService {
    public static let type = "_canopymusic._tcp"
    /// TXT key for the Spotify account fingerprint (Spotify hubs only; older peers ignore it).
    public static let spotifyAccountKey = "spotify"
}

/// A zone found on the network.
public struct ZoneListing: Identifiable, Hashable, Sendable {
    /// The Bonjour instance name (unique on the network).
    public var id: String
    public var name: String
    public var kind: HubKind
    /// Which Mac an `ipad`-kind hub is (`MacKind`); nil from iPads, TVs and older hubs.
    public var device: String?
    /// The hub's guest address by IP (`10.0.1.5` or `10.0.1.5:8080`).
    public var address: String
    /// Identifies the hub device, so a device can tell its own zone apart.
    public var hubID: String?
    public var nowPlaying: String?
    /// The Spotify account the hub plays from (`SpotifyAccount.fingerprint`), iPad or Apple TV;
    /// nil for Apple Music zones, hubs not signed in yet and older hubs.
    public var spotifyAccount: String?

    public init(id: String, name: String, kind: HubKind, device: String? = nil, address: String,
                hubID: String? = nil, nowPlaying: String? = nil, spotifyAccount: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.device = device
        self.address = address
        self.hubID = hubID
        self.nowPlaying = nowPlaying
        self.spotifyAccount = spotifyAccount
    }

    public var baseURL: URL? { URL(string: "http://\(address)") }

    /// Whether this zone is among `zones`: the same hub, or (an older hub that doesn't say which
    /// it is) the same announcement.
    public func isListed(in zones: [ZoneListing]) -> Bool {
        zones.contains { other in hubID.map { other.hubID == $0 } ?? (other.id == id) }
    }

    /// Other zones announcing this Spotify account (`fingerprint`), in list order. Only what the
    /// announcements say: a hub that quit without a Bonjour goodbye stays listed for a while, so
    /// before anything is blocked, `ZoneProbe` asks each one whether it's really there. A
    /// device's own zone (`ownHubID`) never counts, and an unknown account (not fetched yet)
    /// matches nothing.
    public static func usingSpotifyAccount(_ fingerprint: String?, in zones: [ZoneListing], ownHubID: String) -> [ZoneListing] {
        guard let fingerprint, !fingerprint.isEmpty else { return [] }
        return zones.filter { $0.hubID != ownHubID && $0.spotifyAccount == fingerprint }
    }
}

/// What a hub answers at `GET /api/zone`: which hub it is, the Spotify account fingerprint it
/// announces now (nil for Apple Music, or before the account is known), both public already in
/// its TXT record; and the Sonos rooms its zone plays on (`sonos`, nil when it doesn't), so
/// another hub shows them as "In use by …". Room ids are no more than any Sonos app on the
/// network sees.
public struct ZoneCheck: Codable, Equatable, Sendable {
    public var hub: String?
    public var spotify: String?
    public var sonos: SonosZoneClaim?

    public init(hub: String?, spotify: String?, sonos: SonosZoneClaim? = nil) {
        self.hub = hub
        self.spotify = spotify
        self.sonos = sonos
    }
}

/// Asks the other zones on the network (`GET /api/zone`) which Sonos rooms they play on, all at
/// once, each within `timeout`. A zone that doesn't answer, or answers as another hub than its
/// announcement says, adds nothing.
public struct SonosClaimExchange: Sendable {
    public let timeout: Duration
    private let fetch: ZoneProbe.Fetch

    /// `fetch` replaces the network (tests); by default an ephemeral `URLSession`.
    public init(timeout: Duration = .seconds(2), fetch: ZoneProbe.Fetch? = nil) {
        self.timeout = timeout
        if let fetch {
            self.fetch = fetch
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Double(timeout.components.seconds) + 1
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            self.fetch = { url in
                let (data, response) = try await session.data(from: url)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    /// Each zone that answered as itself, with its claim (nil: it plays on no Sonos rooms).
    public func ask(_ zones: [ZoneListing]) async -> [(zone: ZoneListing, claim: SonosZoneClaim?)] {
        await withTaskGroup(of: (ZoneListing, SonosZoneClaim?)?.self) { group in
            for zone in zones {
                guard let url = zone.baseURL?.appending(path: "api/zone") else { continue }
                group.addTask { await self.answer(url, zone: zone) }
            }
            var answers: [(zone: ZoneListing, claim: SonosZoneClaim?)] = []
            for await answer in group {
                if let answer { answers.append((answer.0, answer.1)) }
            }
            return answers
        }
    }

    private func answer(_ url: URL, zone: ZoneListing) async -> (ZoneListing, SonosZoneClaim?)? {
        await withTaskGroup(of: (ZoneListing, SonosZoneClaim?)??.self) { group in
            group.addTask {
                guard let (data, status) = try? await fetch(url), status == 200,
                      let check = try? JSONDecoder().decode(ZoneCheck.self, from: data),
                      zone.hubID == nil || check.hub == zone.hubID else { return .some(nil) }
                return .some((zone, check.sonos))
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}

/// Asks zones whose announcement says they use a Spotify account whether they really are, before
/// that blocks anything: a Bonjour announcement outlives a hub that quit without a goodbye (quit
/// from Xcode, or asleep), and a stale one must never block anyone. A zone counts only if its
/// hub answers `GET /api/zone` within `timeout` as the same hub, on the same account.
public struct ZoneProbe: Sendable {
    /// One GET: the body and HTTP status. Throws if nothing answers.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    /// How a zone answered.
    public enum Answer: Equatable, Sendable {
        /// The same hub, still on the account.
        case there
        /// No answer (refused, unreachable or too slow), or not a hub's answer.
        case silent
        /// Another hub answers at that address now.
        case otherHub
        /// The hub answers, but isn't on that account any more.
        case otherAccount
    }

    public let timeout: Duration
    private let fetch: Fetch

    /// `fetch` replaces the network (tests); by default an ephemeral `URLSession`.
    public init(timeout: Duration = .seconds(2), fetch: Fetch? = nil) {
        self.timeout = timeout
        if let fetch {
            self.fetch = fetch
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Double(timeout.components.seconds) + 1
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            self.fetch = { url in
                let (data, response) = try await session.data(from: url)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    /// The first of the zones announcing this account (`ZoneListing.usingSpotifyAccount`) that
    /// answers as itself, still on it; nil if none does. They're asked at once, and the first to
    /// confirm wins, so this takes at most `timeout`. Zones that turn out to be gone go to `log`.
    public func zoneUsingSpotifyAccount(_ fingerprint: String?, in zones: [ZoneListing], ownHubID: String,
                                        log: (@Sendable (String) -> Void)? = nil) async -> ZoneListing? {
        let candidates = ZoneListing.usingSpotifyAccount(fingerprint, in: zones, ownHubID: ownHubID)
        guard let fingerprint, !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: (ZoneListing, Answer).self) { group in
            for zone in candidates {
                group.addTask { (zone, await self.ask(zone, fingerprint: fingerprint)) }
            }
            for await (zone, answer) in group {
                if answer == .there {
                    group.cancelAll()
                    return zone
                }
                log?("\(zone.name) (\(zone.address)) announces this Spotify account but isn't using it (\(answer)); ignored")
            }
            return nil
        }
    }

    /// Whether `zone` is really there, as its announcement says, on `fingerprint`. No answer
    /// within `timeout` is `.silent`.
    public func ask(_ zone: ZoneListing, fingerprint: String) async -> Answer {
        await withTaskGroup(of: Answer?.self) { group in
            group.addTask { await self.answer(zone, fingerprint: fingerprint) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .silent
        }
    }

    private func answer(_ zone: ZoneListing, fingerprint: String) async -> Answer {
        guard let base = zone.baseURL,
              let (data, status) = try? await fetch(base.appending(path: "api/zone")) else { return .silent }
        switch status {
        case 200:
            guard let check = try? JSONDecoder().decode(ZoneCheck.self, from: data) else { return .silent }
            if check.hub != zone.hubID { return .otherHub }
            return check.spotify == fingerprint ? .there : .otherAccount
        case 404:
            // A hub from before `/api/zone`: it answers, so it's there; its snapshot says which hub
            // it is, and the account is the one it announces.
            guard let (data, status) = try? await fetch(base.appending(path: "api/state")), status == 200,
                  let snapshot = try? JSONDecoder.api.decode(PartySnapshot.self, from: data) else { return .silent }
            return snapshot.hubID == zone.hubID ? .there : .otherHub
        default:
            return .silent
        }
    }
}

// MARK: - Hub: advertise

/// Advertises this device's zone. The TXT record carries the zone name, hub kind, address and
/// what's playing; `update` refreshes it without re-registering.
public final class ZoneAdvertiser: @unchecked Sendable {
    private var service: DNSServiceRef?
    private let queue = DispatchQueue(label: "canopymusic.zone-advertiser")
    private var registeredName: String?

    public init() {}

    public func advertise(name: String, port: UInt16, txt: [String: String]) {
        let record = Self.txtRecord(txt)
        if service != nil, registeredName == name {
            record.withUnsafeBytes { bytes in
                _ = DNSServiceUpdateRecord(service, nil, 0, UInt16(bytes.count), bytes.baseAddress, 0)
            }
            return
        }
        stop()
        var ref: DNSServiceRef?
        let status = record.withUnsafeBytes { bytes in
            // No flags: if the name is taken, mDNS picks "Name (2)" and so on by itself.
            DNSServiceRegister(&ref, 0, 0, name, ZoneService.type, nil, nil, port.bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, nil, nil)
        }
        guard status == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        service = ref
        registeredName = name
    }

    public func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        registeredName = nil
    }

    deinit { stop() }

    /// DNS TXT format: each entry is a length byte then `key=value` (at most 255 bytes).
    static func txtRecord(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            var entry = Data("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = entry.prefix(255) }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data.isEmpty ? Data([0]) : data
    }
}

// MARK: - Displays: browse

/// The zones on the network, as a display sees them (a `ZoneBrowser`; a fake in tests).
@MainActor
public protocol ZoneList: AnyObject {
    var zones: [ZoneListing] { get }
}

/// Live list of zones on the network.
@MainActor
@Observable
public final class ZoneBrowser: ZoneList {
    public private(set) var zones: [ZoneListing] = []
    /// True once the first browse results (or a definite "nothing") have come in.
    public private(set) var hasSearched = false
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ZoneService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let zones = results.compactMap(Self.listing(from:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.zones = zones
                self?.hasSearched = true
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    // Nothing on the network shows as "ready" with no results; give it a moment.
                    try? await Task.sleep(for: .milliseconds(900))
                    self?.hasSearched = true
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    nonisolated static func listing(from result: NWBrowser.Result) -> ZoneListing? {
        guard case .service(let instance, _, _, _) = result.endpoint,
              case .bonjour(let record) = result.metadata else { return nil }
        return listing(instance: instance, txt: record.dictionary)
    }

    /// A zone from its advertised TXT record (the keys `ZoneAdvertiser` is given).
    nonisolated static func listing(instance: String, txt: [String: String]) -> ZoneListing? {
        guard let address = txt["addr"], !address.isEmpty else { return nil }
        return ZoneListing(
            id: instance,
            name: txt["name"] ?? instance,
            kind: HubKind(rawValue: txt["kind"] ?? "") ?? .ipad,
            device: txt["device"].flatMap { $0.isEmpty ? nil : $0 },
            address: address,
            hubID: txt["hub"],
            nowPlaying: txt["playing"].flatMap { $0.isEmpty ? nil : $0 },
            spotifyAccount: txt[ZoneService.spotifyAccountKey].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Displays: connect

/// The backstop for a hub that goes away without saying its zone ended (quit, crashed, lost
/// power): its display gives up once it has been disconnected for `disconnectedFor` and the zone
/// has been missing from the zone list for `unlistedFor`, each without a break. Never while the
/// zone is listed: a hub restarting its server (back from the background) stays listed, but for
/// the moment it takes to announce again, which `unlistedFor` rides out. A display resting in
/// the background, or off the network itself, starts both over.
public struct HubVanishing: Sendable {
    public var disconnectedFor: TimeInterval = 25
    public var unlistedFor: TimeInterval = 10
    private(set) var disconnectedSince: Date?
    private(set) var unlistedSince: Date?

    public init() {}

    mutating func connected() {
        disconnectedSince = nil
    }

    mutating func disconnected(at now: Date) {
        if disconnectedSince == nil { disconnectedSince = now }
    }

    /// In the background, or off the network: nothing it sees then counts.
    mutating func startOver() {
        disconnectedSince = nil
        unlistedSince = nil
    }

    /// Whether the hub is gone, with the zone `listed` or not now.
    mutating func isGone(listed: Bool, at now: Date) -> Bool {
        if listed {
            unlistedSince = nil
        } else if unlistedSince == nil {
            unlistedSince = now
        }
        guard let disconnectedSince, let unlistedSince else { return false }
        return now.timeIntervalSince(disconnectedSince) >= disconnectedFor && now.timeIntervalSince(unlistedSince) >= unlistedFor
    }
}

/// A display's connection to its hub: mirrors the hub's queue into a `PartySession` over the
/// same WebSocket the guest page uses, and sends edits over the JSON API.
@MainActor
@Observable
public final class ZoneConnection: ZoneRemote {
    /// Why a display stopped showing its zone by itself.
    public enum Ending: Equatable, Sendable {
        /// The hub said the zone ended (`ZoneMessage.ended`).
        case ended
        /// The hub went away without a goodbye (`HubVanishing`).
        case vanished
    }

    public let baseURL: URL
    public private(set) var isConnected = false
    /// True once a snapshot has arrived (so the UI can wait before showing the party screen).
    public private(set) var hasSnapshot = false
    /// Set once the zone has ended, or its hub has gone: the connection has stopped for good.
    public private(set) var ending: Ending?
    /// Called once, as `ending` is set: the app goes back to the zone list.
    @ObservationIgnored public var onEnding: (@MainActor (Ending) -> Void)?

    @ObservationIgnored public let clientID: String
    @ObservationIgnored private let name: String
    @ObservationIgnored private let kind: HubKind
    @ObservationIgnored private let device: String?
    @ObservationIgnored private weak var session: PartySession?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Looks for the zone in `zoneList` every few seconds while disconnected (`checkHub`).
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var zoneList: (any ZoneList)?
    @ObservationIgnored private var listing: ZoneListing?
    @ObservationIgnored var vanishing = HubVanishing()
    /// The clock and the network check (replaced in tests).
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var isOnNetwork: () -> Bool = { LocalNetwork.lanAddress() != nil }
    /// The socket open now (or opening), so `suspend` and `stop` can close it.
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// In the background (`suspend`): nothing runs until `resume`.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `device` is which Mac this display is (`MacKind`), for its icon in the hub's lists; nil
    /// on an iPad or TV.
    public init(baseURL: URL, clientID: String, name: String, kind: HubKind, device: String? = nil) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.name = name
        self.kind = kind
        self.device = device
    }

    /// `listing` is the zone as `zoneList` shows it: once the hub has been gone a while without a
    /// goodbye (`HubVanishing`), the connection ends (`.vanished`). Without them it never does.
    public func start(session: PartySession, listing: ZoneListing? = nil, in zoneList: (any ZoneList)? = nil) {
        guard ending == nil else { return }
        self.session = session
        if let listing, let zoneList {
            self.listing = listing
            self.zoneList = zoneList
        }
        // Not connected yet: a hub that never answers counts from now.
        vanishing.disconnected(at: now())
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sayHello()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        watcher?.cancel()
        if self.zoneList != nil {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.checkHub()
                }
            }
        }
    }

    /// The app went to the background: no check-ins, and the socket closes, until `resume`. The
    /// hub drops the display from its list after `PartySession.displayTimeout` (30 s), as it
    /// does one iOS has suspended; a quick trip away keeps it listed. Resting isn't the hub
    /// going away: `HubVanishing` starts over when it's back.
    public func suspend() {
        guard loop != nil else { return }
        isSuspended = true
        loop?.cancel()
        heartbeat?.cancel()
        watcher?.cancel()
        loop = nil
        heartbeat = nil
        watcher = nil
        vanishing.startOver()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
    }

    /// Back in the foreground: checks in and reconnects at once.
    public func resume() {
        guard isSuspended, let session else { return }
        isSuspended = false
        start(session: session)
    }

    public func stop() {
        // Leaving: tell the hub, so it drops this display now rather than after its timeout.
        if heartbeat != nil || isSuspended {
            struct Bye: Encodable { var clientId: String }
            let bye = Bye(clientId: clientID)
            Task { [self] in _ = try? await post("/api/display/bye", bye) }
        }
        stopRunning()
        isSuspended = false
    }

    private func stopRunning() {
        loop?.cancel()
        heartbeat?.cancel()
        watcher?.cancel()
        loop = nil
        heartbeat = nil
        watcher = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
    }

    /// The zone ended, or its hub is gone: nothing more is tried (and no goodbye is posted to a
    /// hub that isn't there), and the app is told.
    private func end(_ ending: Ending) {
        guard self.ending == nil else { return }
        stopRunning()
        isSuspended = false
        self.ending = ending
        onEnding?(ending)
    }

    /// The backstop (`HubVanishing`), every few seconds: whether the hub has been gone long
    /// enough, by the zone list.
    func checkHub() {
        guard ending == nil, !isSuspended, let zoneList, let listing else { return }
        if isConnected {
            vanishing.connected()
            return
        }
        // Off the network, this display sees no zones at all; that isn't the hub going away.
        guard isOnNetwork() else {
            vanishing.startOver()
            return
        }
        let now = now()
        vanishing.disconnected(at: now)
        if vanishing.isGone(listed: listing.isListed(in: zoneList.zones), at: now) { end(.vanished) }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            guard let url = Self.webSocketURL(baseURL) else { return }
            let socket = urlSession.webSocketTask(with: url)
            self.socket = socket
            socket.resume()
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .string(let text) = message else { continue }
                    guard let snapshot = try? JSONDecoder.api.decode(PartySnapshot.self, from: Data(text.utf8)) else {
                        // The hub's last word before it stops: the zone has ended.
                        if ZoneMessage.isEnded(text) {
                            end(.ended)
                            return
                        }
                        continue
                    }
                    // Relayed library art loads from this hub, not from this device.
                    session?.apply(snapshot.resolvingArtwork(against: baseURL))
                    hasSnapshot = true
                    isConnected = true
                    vanishing.connected()
                    attempt = 0
                }
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
            }
            isConnected = false
            vanishing.disconnected(at: now())
            attempt += 1
            try? await Task.sleep(for: .seconds(min(Double(attempt), 5)))
        }
    }

    private func sayHello() async {
        struct Hello: Encodable { var clientId: String; var name: String; var kind: HubKind; var device: String? }
        _ = try? await post("/api/display/hello", Hello(clientId: clientID, name: name, kind: kind, device: device))
    }

    // MARK: ZoneRemote

    public func send(_ command: ZoneCommand) async throws {
        do {
            switch command {
            case .add(let track, let itemID):
                struct Add: Encodable { var track: QueueTrack; var name: String; var clientId: String; var itemId: UUID; var origin: String }
                try await post("/api/add", Add(track: track, name: name, clientId: clientID, itemId: itemID, origin: "ipad"))
            case .move(let id, let after):
                // With its client ID, so the hub knows it's a display (not limited by "Limit
                // reorders") rather than a page from before the limit.
                struct Move: Encodable { var id: UUID; var after: UUID?; var clientId: String }
                try await post("/api/move", Move(id: id, after: after, clientId: clientID))
            case .remove(let id):
                // The phones' endpoint: the hub removes only requests carrying this client ID
                // (`/api/add` records it on a display's adds), and never the locked next song.
                // Hubs from before displays could remove take it the same way.
                struct Remove: Encodable { var id: UUID; var clientId: String }
                try await post("/api/remove", Remove(id: id, clientId: clientID))
            case .play, .pause, .next, .previous, .seek:
                struct Playback: Encodable { var clientId: String; var action: String; var time: TimeInterval? }
                let (action, time): (String, TimeInterval?) = switch command {
                case .play: ("play", nil)
                case .pause: ("pause", nil)
                case .next: ("next", nil)
                case .previous: ("previous", nil)
                case .seek(let t): ("seek", t)
                default: ("", nil)
                }
                try await post("/api/display/playback", Playback(clientId: clientID, action: action, time: time))
            }
        } catch {
            // Refused or failed: drop the optimistic edit by taking the hub's state as is.
            await refresh()
            throw error
        }
    }

    public func search(_ term: String) async throws -> [QueueTrack] {
        var components = URLComponents(url: baseURL.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        let (data, response) = try await urlSession.data(from: components.url!)
        try Self.check(response)
        return try JSONDecoder.api.decode([QueueTrack].self, from: data).map { $0.resolvingArtwork(against: baseURL) }
    }

    public func upcoming(offset: Int, limit: Int) async throws -> UpcomingPage {
        var components = URLComponents(url: baseURL.appending(path: "api/upcoming"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "\(limit)")]
        let (data, response) = try await urlSession.data(from: components.url!)
        try Self.check(response)
        return try JSONDecoder.api.decode(UpcomingPage.self, from: data).resolvingArtwork(against: baseURL)
    }

    private func refresh() async {
        guard let (data, _) = try? await urlSession.data(from: baseURL.appending(path: "api/state")),
              let snapshot = try? JSONDecoder.api.decode(PartySnapshot.self, from: data) else { return }
        session?.apply(snapshot.resolvingArtwork(against: baseURL), force: true)
    }

    @discardableResult
    private func post(_ path: String, _ body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.api.encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response)
        return data
    }

    nonisolated static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    nonisolated static func webSocketURL(_ base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "ws"
        components.path = "/ws"
        // Display snapshots: with the hub's guest Wi‑Fi (older hubs ignore it).
        components.queryItems = [URLQueryItem(name: "display", value: "1")]
        return components.url
    }
}
