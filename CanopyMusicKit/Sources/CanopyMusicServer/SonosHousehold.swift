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

    public static let bonjourType = "_sonos._tcp"

    public init(transport: any SonosTransport = URLSessionSonosTransport(timeout: 4)) {
        self.transport = transport
    }

    public func start() {
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
        self.players = players.sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
        hasSearched = true
        // Topology and services from any player that answers.
        for player in self.players {
            let client = SonosClient(transport: transport, host: player.host)
            guard let groups = try? await client.zoneGroups() else { continue }
            self.groups = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let available = try? await client.availableServices() {
                services = available.services
                serviceTypes = available.types
            }
            break
        }
        accounts = await findAccounts()
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

    /// Rooms to list: one per visible player, sorted by name.
    public var rooms: [SonosPlayer] {
        let invisible = Set(groups.flatMap(\.members).filter(\.isInvisible).map(\.id))
        return players.filter { !invisible.contains($0.id) }
    }

    /// A target for playing in `roomIDs` (the first is the coordinator).
    public func target(rooms roomIDs: [String]) -> SonosTarget? {
        let rooms = roomIDs.compactMap(player)
        guard let first = rooms.first else { return nil }
        let room = { (player: SonosPlayer) in SonosTarget.Room(id: player.id, name: player.roomName, host: player.host) }
        let group = group(containing: first.id)
        let leaves = group.map { $0.coordinatorID != first.id } ?? false
        let alreadyIn = Set(leaves ? [] : group?.members.map(\.id) ?? [])
        return SonosTarget(coordinator: room(first), joining: rooms.dropFirst().filter { !alreadyIn.contains($0.id) }.map(room), leavesGroup: leaves)
    }
}
