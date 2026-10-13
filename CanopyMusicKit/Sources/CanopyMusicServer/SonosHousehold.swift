import CanopyMusicCore
import Foundation
import Network
import Observation

/// The Sonos players on the network, their groups, and the music-service accounts the household
/// gives away. Discovery only reads: Bonjour `_sonos._tcp`, each player's device description,
/// the group topology, the services list, favourites, and each group's queue and current track.
/// Nothing here changes what a speaker is doing.
@MainActor
@Observable
public final class SonosHousehold {
    public private(set) var players: [SonosPlayer] = []
    public private(set) var groups: [SonosGroup] = []
    /// Accounts by Sonos service id (`SonosMusicService.serviceID`).
    public private(set) var accounts: [SonosAccount] = []
    /// What `ListAvailableServices` lists (the region's services; not which are linked).
    public private(set) var services: [SonosServiceDescriptor] = []
    public private(set) var serviceTypes: [Int] = []
    /// True once a browse has had time to find something (or found nothing).
    public private(set) var hasSearched = false
    public private(set) var isRefreshing = false

    @ObservationIgnored private var browser: NWBrowser?
    /// Bonjour instance → player address from its TXT `location`.
    @ObservationIgnored private var locations: [String: String] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored public let transport: any SonosTransport
    @ObservationIgnored public var log: (@MainActor (String) -> Void)?
    /// After each refresh (players, groups and accounts read again).
    @ObservationIgnored public var onRefresh: (@MainActor () -> Void)?

    /// Each room as last read by `readRooms` (volume, whether it answers, what it's playing).
    public private(set) var readings: [String: SonosRoomReading] = [:]
    /// The player to read the topology from first: the zone's coordinator, so the household
    /// listed is the one the zone plays in.
    @ObservationIgnored public var preferredHost: String?
    /// Fixed player addresses instead of Bonjour (a simulated household).
    @ObservationIgnored private let fixedHosts: [String]?

    public static let bonjourType = "_sonos._tcp"

    /// `fixedHosts`: the players are at these addresses; nothing is browsed (with a
    /// `SonosSimulator` transport, the simulator's rooms).
    public init(transport: any SonosTransport = URLSessionSonosTransport(timeout: 4), fixedHosts: [String]? = nil) {
        self.transport = transport
        self.fixedHosts = fixedHosts
    }

    public func start() {
        if let fixedHosts {
            guard locations.isEmpty else { return }
            browsed(Dictionary(uniqueKeysWithValues: fixedHosts.map { ($0, $0) }))
            return
        }
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: String] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let record) = result.metadata,
                      let host = Self.host(fromTXT: record.dictionary) else { continue }
                found[name] = host
            }
            Task { @MainActor in self?.browsed(found) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    try? await Task.sleep(for: .seconds(2))
                    self?.hasSearched = true
                case .failed(let error):
                    self?.log?("browse failed: \(error)")
                    self?.hasSearched = true
                default:
                    break
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

    /// The player's address from its TXT record (`location=http://10.0.1.161:1400/xml/…`).
    nonisolated static func host(fromTXT txt: [String: String]) -> String? {
        txt["location"].flatMap(SonosParse.host(ofLocation:))
    }

    private func browsed(_ found: [String: String]) {
        guard found != locations else { return }
        log?("bonjour: \(found.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", "))")
        locations = found
        refresh()
    }

    /// Reads everything again (debounced: one refresh at a time, the latest wins).
    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    public func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let hosts = Array(Set(locations.values)).sorted()
        var players: [SonosPlayer] = []
        for host in hosts {
            do {
                if let player = try await SonosClient(transport: transport, host: host).deviceDescription() {
                    players.append(player)
                }
            } catch {
                log?("\(host): no device description (\(error))")
            }
        }
        guard !Task.isCancelled else { return }
        let previous = self.players
        self.players = players.sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
        hasSearched = true
        // Topology and services from any player that answers (the zone's coordinator first).
        for host in topologyHosts {
            let client = SonosClient(transport: transport, host: host)
            guard let groups = try? await client.zoneGroups() else { continue }
            self.groups = Self.sorted(groups)
            if let available = try? await client.availableServices() {
                services = available.services
                serviceTypes = available.types
            }
            break
        }
        // Rooms the topology lists whose description didn't come (asleep, or not answering just
        // now): kept from before, else listed by name, so they show as not responding.
        let known = Set(self.players.map(\.id))
        let missing = groups.flatMap(\.members).filter { !$0.isInvisible && !known.contains($0.id) }.compactMap { member -> SonosPlayer? in
            guard let host = member.host else { return nil }
            return previous.first { $0.id == member.id } ?? SonosPlayer(id: member.id, roomName: member.roomName, modelName: "Sonos", displayName: "Sonos", host: host)
        }
        if !missing.isEmpty {
            self.players = (self.players + missing).sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
        }
        accounts = await findAccounts()
        onRefresh?()
    }

    private var topologyHosts: [String] {
        let hosts = players.map(\.host)
        guard let preferredHost, hosts.contains(preferredHost) else { return hosts }
        return [preferredHost] + hosts.filter { $0 != preferredHost }
    }

    private static func sorted(_ groups: [SonosGroup]) -> [SonosGroup] {
        groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads the groups again, and each room's volume and what its group is playing (for the
    /// speaker lists, while one is showing). Only reads. A room that doesn't answer is marked so.
    /// `ourCoordinatorID`: the zone's group, whose music isn't "something else".
    public func readRooms(ourCoordinatorID: String?) async {
        for host in topologyHosts {
            if let groups = try? await SonosClient(transport: transport, host: host).zoneGroups() {
                self.groups = Self.sorted(groups)
                break
            }
        }
        var readings: [String: SonosRoomReading] = [:]
        // What each group plays, from its coordinator.
        var playing: [String: String?] = [:]
        for group in groups {
            guard let host = group.coordinator?.host else { continue }
            let client = SonosClient(transport: transport, host: host)
            guard let state = try? await client.transportState() else { continue }
            var description: String?
            if SonosPlaybackRules.isPlaying(state), group.coordinatorID != ourCoordinatorID {
                let media = try? await client.mediaInfo()
                let position = try? await client.positionInfo()
                let mediaTitle = media?["CurrentURIMetaData"].flatMap { SonosParse.didlItems($0).first?.title }
                description = SonosNowPlaying.describe(state: state, position: position, mediaURI: media?["CurrentURI"], mediaTitle: mediaTitle,
                                                       coordinatorID: group.coordinatorID, ourCoordinatorID: ourCoordinatorID)
            }
            playing[group.coordinatorID] = description
        }
        // All at once: a room that doesn't answer takes the whole timeout.
        let transport = transport
        let volumes = await withTaskGroup(of: (String, Int?).self) { tasks in
            for room in rooms {
                tasks.addTask { (room.id, try? await SonosClient(transport: transport, host: room.host).volume()) }
            }
            var volumes: [String: Int] = [:]
            for await (id, volume) in tasks { if let volume { volumes[id] = volume } }
            return volumes
        }
        for room in rooms {
            let coordinator = group(containing: room.id)?.coordinatorID
            guard let volume = volumes[room.id] else {
                readings[room.id] = .notResponding
                continue
            }
            readings[room.id] = SonosRoomReading(responding: true, volume: volume, coordinatorID: coordinator,
                                                 elsewhere: coordinator.flatMap { playing[$0] ?? nil })
        }
        self.readings = readings
    }

    /// A volume just set here, shown at once rather than at the next reading.
    public func noteVolume(_ volume: Int, for roomID: String) {
        readings[roomID]?.volume = volume
    }

    /// Accounts read off favourites and every group's queue and current track. Current S2
    /// firmware's `/status/accounts` is empty and nothing lists linked accounts, so an account
    /// shows up here only once something from it has been played or saved on this household.
    private func findAccounts() async -> [SonosAccount] {
        var lists: [[SonosAccount]] = []
        if let any = players.first {
            let client = SonosClient(transport: transport, host: any.host)
            if let favourites = try? await client.browse("FV:2") {
                lists.append(SonosParse.accounts(in: favourites, seenIn: nil))
            }
        }
        for group in groups {
            guard let host = group.coordinator?.host else { continue }
            let client = SonosClient(transport: transport, host: host)
            if let info = try? await client.positionInfo(), let uri = info.trackURI {
                let item = SonosItem(id: "now", title: info.item?.title, uri: uri, desc: info.item?.desc)
                lists.append(SonosParse.accounts(in: [item], seenIn: group.name))
            }
            if let queue = try? await client.browse("Q:0", count: 200) {
                lists.append(SonosParse.accounts(in: queue, seenIn: group.name))
            }
        }
        return SonosParse.merge(lists)
    }

    // MARK: Questions the UI asks

    public func accounts(for service: SonosMusicService) -> [SonosAccount] {
        let sid = SonosParse.serviceID(for: service, in: services)
        return accounts.filter { $0.serviceID == sid }
    }

    public func player(_ id: String) -> SonosPlayer? { players.first { $0.id == id } }

    /// The group a room is in.
    public func group(containing roomID: String) -> SonosGroup? {
        groups.first { $0.members.contains { $0.id == roomID } }
    }

    /// Rooms to list: one per visible player, sorted by name. Only this household's (the topology
    /// read lists only the household of the player it's read from): a second Sonos system on the
    /// network isn't offered.
    public var rooms: [SonosPlayer] {
        let members = groups.flatMap(\.members)
        let invisible = Set(members.filter(\.isInvisible).map(\.id))
        let household = Set(members.map(\.id))
        return players.filter { !invisible.contains($0.id) && (household.isEmpty || household.contains($0.id)) }
    }

    /// A target for playing in `roomIDs` (the first is the coordinator). Every room is in it, even
    /// one already in the coordinator's group (joining again changes nothing), so the target is
    /// exactly the rooms chosen. `leavesGroup` is from the last reading, only a fallback: the
    /// engine reads the layout live at the first play, and may let another chosen room lead.
    public func target(rooms roomIDs: [String]) -> SonosTarget? {
        let rooms = roomIDs.compactMap(player)
        guard let first = rooms.first else { return nil }
        let leaves = group(containing: first.id).map { $0.coordinatorID != first.id } ?? false
        return SonosTarget(coordinator: Self.room(first), joining: rooms.dropFirst().map(Self.room), leavesGroup: leaves)
    }

    public static func room(_ player: SonosPlayer) -> SonosTarget.Room {
        SonosTarget.Room(id: player.id, name: player.roomName, host: player.host)
    }
}
