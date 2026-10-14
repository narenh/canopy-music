import Foundation

/// A pretend Sonos household, answering the same SOAP actions real players take, in memory: no
/// request leaves the device. For tests and for the simulator (`-sonosFake`), so playback,
/// grouping and volume can be exercised without real speakers.
///
/// It follows what Sonos does as far as it's known (see docs/multi-device.md, "Sonos"): queue and
/// transport commands go to a group's coordinator (others answer 800); a player that joins
/// (`x-rincon:`) plays the group's music; one that leaves (`BecomeCoordinatorOfStandaloneGroup`)
/// is a group of its own, stopped; `DelegateGroupCoordinationTo` moves the group, its queue and
/// what's playing to the new coordinator; group volume keeps the members' balance from the last
/// snapshot. Rooms marked unreachable fail every request as a switched-off speaker would.
@MainActor
public final class SonosSimulator: SonosTransport {
    public struct Room: Sendable {
        public var id: String
        public var name: String
        /// "Beam".
        public var model: String
        public var host: String
        public var volume: Int
        public var reachable: Bool

        public init(id: String, name: String, model: String, host: String, volume: Int, reachable: Bool = true) {
            self.id = id
            self.name = name
            self.model = model
            self.host = host
            self.volume = volume
            self.reachable = reachable
        }
    }

    /// Something other than a queue playing in a group (the Sonos app's radio, the TV…).
    public struct Elsewhere: Sendable {
        public var uri: String
        public var title: String?
        public var artist: String?

        public init(uri: String, title: String? = nil, artist: String? = nil) {
            self.uri = uri
            self.title = title
            self.artist = artist
        }
    }

    struct Group {
        var coordinatorID: String
        var memberIDs: [String]
        var queue: [String] = []
        var titles: [String: (title: String?, artist: String?)] = [:]
        var track = 1
        var state: SonosTransportState = .stopped
        var position: TimeInterval = 0
        var positionAt = Date()
        /// nil: its own queue.
        var elsewhere: Elsewhere?
        var snapshot: [String: Int] = [:]
    }

    public private(set) var rooms: [Room]
    var groups: [Group]
    /// Every request, in order.
    public private(set) var requests: [SonosRequest] = []
    /// Accounts the favourites show (so discovery finds them), as (service id, serial).
    public var accounts: [(serviceID: Int, serial: Int)] = [(SonosMusicService.appleMusic.serviceID, 3), (SonosMusicService.spotify.serviceID, 4)]
    /// What `GetHouseholdID` answers (every room the same, as on a real household).
    public var householdID = "Sonos_Simulated"
    /// Service ids not linked on the household: their URIs are refused with 800 even by the
    /// coordinator, as a real S2 player answered `SetAVTransportURI` for Tidal (sid 174) there.
    /// `AddURIToQueue` is assumed to answer the same (not seen). A linked service plays with any
    /// serial, or none, as the real household did.
    public var unlinkedServices: Set<Int> = []
    /// Each request takes this long (a real player answers in tens of milliseconds).
    public var latency: Duration = .zero
    /// A room joining a group takes this long to be in it.
    public var joinDelay: Duration = .zero
    /// What-ifs for the parts of Sonos's behaviour not confirmed on real speakers: the new
    /// coordinator doesn't get the queue on a handoff, or a room that leaves plays on by itself
    /// with a copy of the group's queue.
    public var handoffDropsQueue = false
    public var leaverPlaysOn = false

    public init(rooms: [Room]) {
        self.rooms = rooms
        groups = rooms.map { Group(coordinatorID: $0.id, memberIDs: [$0.id]) }
    }

    public var changes: [SonosRequest] { requests.filter { !$0.isReadOnly } }

    // MARK: Setting the scene

    /// Puts `roomIDs` in one group, led by the first, playing nothing.
    public func group(_ roomIDs: [String]) {
        for id in roomIDs { detach(id) }
        removeEmptyGroups()
        groups.append(Group(coordinatorID: roomIDs[0], memberIDs: roomIDs))
    }

    /// The group led by `coordinatorID` plays something that isn't a queue.
    public func play(_ elsewhere: Elsewhere, in coordinatorID: String) {
        guard let g = groupIndex(coordinator: coordinatorID) else { return }
        groups[g].elsewhere = elsewhere
        groups[g].state = .playing
        groups[g].positionAt = Date()
    }

    /// The group led by `coordinatorID` reaches the end of its song: it goes on to the next
    /// entry in its queue, or after the last back to the first, stopped (as Sonos does).
    public func finishTrack(in coordinatorID: String) {
        guard let g = groupIndex(coordinator: coordinatorID), groups[g].elsewhere == nil else { return }
        if groups[g].track < groups[g].queue.count {
            groups[g].track += 1
        } else {
            groups[g].track = 1
            groups[g].state = .stopped
        }
        setPosition(g, 0)
    }

    /// A room is switched off (every request to it fails), or back on.
    public func setReachable(_ roomID: String, _ reachable: Bool) {
        guard let r = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[r].reachable = reachable
    }

    public func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    /// The ids in each group, coordinator first.
    public var topology: [[String]] {
        groups.map { group in [group.coordinatorID] + group.memberIDs.filter { $0 != group.coordinatorID } }
    }

    public func state(of roomID: String) -> SonosTransportState? {
        groups.first { $0.memberIDs.contains(roomID) }?.state
    }

    public func queue(of roomID: String) -> [String] {
        groups.first { $0.memberIDs.contains(roomID) }?.queue ?? []
    }

    // MARK: SonosTransport

    public func get(host: String, path: String) async throws -> Data {
        if latency > .zero { try await Task.sleep(for: latency) }
        guard let room = rooms.first(where: { $0.host == host }), room.reachable else { throw SonosError.unreachable }
        guard path == "/xml/device_description.xml" else { throw SonosError.http(action: "GET \(path)", status: 404) }
        let e = SonosXMLEscape.escape
        let xml = "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device>"
            + "<deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>"
            + "<modelName>Sonos \(e(room.model))</modelName><displayName>\(e(room.model))</displayName>"
            + "<roomName>\(e(room.name))</roomName><UDN>uuid:\(room.id)</UDN><softwareVersion>97.1-80312</softwareVersion>"
            + "</device></root>"
        return Data(xml.utf8)
    }

    public func send(_ request: SonosRequest) async throws -> [String: String] {
        requests.append(request)
        if latency > .zero { try await Task.sleep(for: latency) }
        guard let room = rooms.first(where: { $0.host == request.host }), room.reachable else { throw SonosError.unreachable }
        guard let g = groups.firstIndex(where: { $0.memberIDs.contains(room.id) }) else { throw SonosError.unreachable }
        let isCoordinator = groups[g].coordinatorID == room.id
        let coordinatorOnly: Set<String> = [
            "RemoveAllTracksFromQueue", "AddURIToQueue", "RemoveTrackFromQueue", "Seek", "Play", "Pause",
            "SetPlayMode", "SetCrossfadeMode", "DelegateGroupCoordinationTo", "SnapshotGroupVolume", "SetGroupVolume", "GetGroupVolume",
        ]
        if coordinatorOnly.contains(request.action), !isCoordinator {
            throw SonosError.upnp(action: request.action, code: 800)
        }
        switch request.action {
        // Topology and content
        case "GetZoneGroupState":
            return ["ZoneGroupState": zoneGroupState()]
        case "ListAvailableServices":
            return [:]
        case "GetHouseholdID":
            return ["CurrentHouseholdID": householdID]
        case "Browse":
            return ["Result": browse(request.argument("ObjectID") ?? "", group: groups[g]), "NumberReturned": "0", "TotalMatches": "0"]

        // Volume
        case "GetVolume":
            return ["CurrentVolume": "\(room.volume)"]
        case "SetVolume":
            setVolume(room.id, Int(request.argument("DesiredVolume") ?? "") ?? room.volume)
        case "GetGroupVolume":
            return ["CurrentVolume": "\(groupVolume(groups[g]))"]
        case "SnapshotGroupVolume":
            groups[g].snapshot = Dictionary(uniqueKeysWithValues: groups[g].memberIDs.compactMap { id in self.room(id).map { (id, $0.volume) } })
        case "SetGroupVolume":
            setGroupVolume(g, Int(request.argument("DesiredVolume") ?? "") ?? 0)

        // Grouping
        case "SetAVTransportURI":
            let uri = request.argument("CurrentURI") ?? ""
            if uri.hasPrefix("x-rincon:") {
                if joinDelay > .zero { try await Task.sleep(for: joinDelay) }
                join(room.id, to: String(uri.dropFirst("x-rincon:".count)))
            } else if let sid = SonosURI.serviceAndAccount(of: uri)?.serviceID, unlinkedServices.contains(sid) {
                throw SonosError.upnp(action: request.action, code: 800)
            } else if isCoordinator {
                groups[g].elsewhere = uri == SonosURI.queue(of: room.id) ? nil : Elsewhere(uri: uri)
                groups[g].state = .stopped
            } else {
                throw SonosError.upnp(action: request.action, code: 800)
            }
        case "BecomeCoordinatorOfStandaloneGroup":
            if groups[g].memberIDs.count == 1 {
                groups[g].state = .stopped
            } else {
                standalone(room.id)
            }
        case "DelegateGroupCoordinationTo":
            guard let next = request.argument("NewCoordinator"), groups[g].memberIDs.contains(next), next != room.id else {
                throw SonosError.upnp(action: request.action, code: 402)
            }
            groups[g].coordinatorID = next
            if handoffDropsQueue {
                groups[g].queue = []
                groups[g].state = .stopped
            }
            if request.argument("RejoinGroup") != "1" { standalone(room.id) }

        // Queue and transport (coordinator)
        case "RemoveAllTracksFromQueue":
            groups[g].queue = []
            groups[g].track = 1
        case "AddURIToQueue":
            let uri = request.argument("EnqueuedURI") ?? ""
            if let sid = SonosURI.serviceAndAccount(of: uri)?.serviceID, unlinkedServices.contains(sid) {
                throw SonosError.upnp(action: request.action, code: 800)
            }
            let desired = Int(request.argument("DesiredFirstTrackNumberEnqueued") ?? "0") ?? 0
            let index = desired == 0 || desired > groups[g].queue.count ? groups[g].queue.count : desired - 1
            groups[g].queue.insert(uri, at: index)
            if let item = SonosParse.didlItems(request.argument("EnqueuedURIMetaData") ?? "").first {
                groups[g].titles[uri] = (item.title, item.creator)
            }
            return ["FirstTrackNumberEnqueued": "\(index + 1)", "NumTracksAdded": "1", "NewQueueLength": "\(groups[g].queue.count)"]
        case "RemoveTrackFromQueue":
            let number = Int(request.argument("ObjectID")?.split(separator: "/").last ?? "") ?? 0
            guard groups[g].queue.indices.contains(number - 1) else { throw SonosError.upnp(action: request.action, code: 701) }
            groups[g].queue.remove(at: number - 1)
            if number < groups[g].track { groups[g].track -= 1 }
        case "Seek":
            if request.argument("Unit") == "TRACK_NR" {
                groups[g].track = Int(request.argument("Target") ?? "") ?? 1
                setPosition(g, 0)
            } else {
                setPosition(g, SonosTime.seconds(request.argument("Target")) ?? 0)
            }
        case "Play":
            setPosition(g, position(groups[g]))
            groups[g].state = .playing
        case "Pause":
            guard SonosPlaybackRules.isPlaying(groups[g].state) else { throw SonosError.upnp(action: request.action, code: 701) }
            setPosition(g, position(groups[g]))
            groups[g].state = .paused
        case "SetPlayMode", "SetCrossfadeMode":
            break

        // Reading the transport
        case "GetTransportInfo":
            return ["CurrentTransportState": groups[g].state.rawValue, "CurrentTransportStatus": "OK", "CurrentSpeed": "1"]
        case "GetMediaInfo":
            if !isCoordinator { return ["CurrentURI": SonosURI.joinGroup(of: groups[g].coordinatorID)] }
            return ["CurrentURI": groups[g].elsewhere?.uri ?? SonosURI.queue(of: room.id), "NrTracks": "\(groups[g].queue.count)"]
        case "GetPositionInfo":
            // As a real member answers (a Move in a Beam's group): track 1, the coordinator's x-rincon.
            if !isCoordinator { return ["Track": "1", "TrackURI": SonosURI.joinGroup(of: groups[g].coordinatorID), "RelTime": "NOT_IMPLEMENTED"] }
            return positionInfo(groups[g])
        default:
            break
        }
        return [:]
    }

    // MARK: Inside

    private func groupIndex(coordinator: String) -> Int? {
        groups.firstIndex { $0.coordinatorID == coordinator }
    }

    /// Takes a player out of its group (the group carries on without it, under its next member
    /// if it led it).
    private func detach(_ id: String) {
        guard let g = groups.firstIndex(where: { $0.memberIDs.contains(id) }) else { return }
        groups[g].memberIDs.removeAll { $0 == id }
        if groups[g].coordinatorID == id, let next = groups[g].memberIDs.first { groups[g].coordinatorID = next }
    }

    private func removeEmptyGroups() {
        groups.removeAll { $0.memberIDs.isEmpty }
    }

    private func standalone(_ id: String) {
        let old = groups.first { $0.memberIDs.contains(id) }
        detach(id)
        removeEmptyGroups()
        var group = Group(coordinatorID: id, memberIDs: [id])
        if leaverPlaysOn, let old {
            group.queue = old.queue
            group.titles = old.titles
            group.track = old.track
            group.state = old.state
            group.position = position(old)
        }
        groups.append(group)
    }

    private func join(_ id: String, to coordinator: String) {
        guard let target = groupIndex(coordinator: coordinator), !groups[target].memberIDs.contains(id) else { return }
        detach(id)
        removeEmptyGroups()
        groups[groupIndex(coordinator: coordinator)!].memberIDs.append(id)
    }

    private func position(_ group: Group) -> TimeInterval {
        group.state == .playing ? group.position + Date().timeIntervalSince(group.positionAt) : group.position
    }

    private func setPosition(_ g: Int, _ seconds: TimeInterval) {
        groups[g].position = seconds
        groups[g].positionAt = Date()
    }

    private func setVolume(_ id: String, _ volume: Int) {
        guard let r = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[r].volume = min(100, max(0, volume))
    }

    private func groupVolume(_ group: Group) -> Int {
        let volumes = group.memberIDs.compactMap { room($0)?.volume }
        return volumes.isEmpty ? 0 : Int((Double(volumes.reduce(0, +)) / Double(volumes.count)).rounded())
    }

    private func setGroupVolume(_ g: Int, _ desired: Int) {
        let snapshot = groups[g].snapshot.isEmpty
            ? Dictionary(uniqueKeysWithValues: groups[g].memberIDs.compactMap { id in room(id).map { (id, $0.volume) } })
            : groups[g].snapshot
        let average = Double(snapshot.values.reduce(0, +)) / Double(max(1, snapshot.count))
        for (id, volume) in snapshot {
            setVolume(id, average > 0 ? Int((Double(volume) * Double(desired) / average).rounded()) : desired)
        }
    }

    private func positionInfo(_ group: Group) -> [String: String] {
        if let elsewhere = group.elsewhere {
            return ["Track": "1", "TrackURI": elsewhere.uri, "RelTime": SonosTime.string(position(group)), "TrackDuration": "0:00:00",
                    "TrackMetaData": didl(uri: elsewhere.uri, title: elsewhere.title, artist: elsewhere.artist)]
        }
        let uri = group.queue.indices.contains(group.track - 1) ? group.queue[group.track - 1] : ""
        let titles = group.titles[uri]
        return ["Track": "\(uri.isEmpty ? 0 : group.track)", "TrackURI": uri, "RelTime": SonosTime.string(position(group)),
                "TrackDuration": "0:03:30", "TrackMetaData": uri.isEmpty ? "NOT_IMPLEMENTED" : didl(uri: uri, title: titles?.title, artist: titles?.artist)]
    }

    private func zoneGroupState() -> String {
        let e = SonosXMLEscape.escape
        var xml = "<ZoneGroupState><ZoneGroups>"
        for group in groups {
            xml += "<ZoneGroup Coordinator=\"\(group.coordinatorID)\" ID=\"\(group.coordinatorID):1\">"
            for id in group.memberIDs {
                guard let room = room(id) else { continue }
                xml += "<ZoneGroupMember UUID=\"\(id)\" Location=\"http://\(e(room.host)):1400/xml/device_description.xml\" ZoneName=\"\(e(room.name))\"/>"
            }
            xml += "</ZoneGroup>"
        }
        return xml + "</ZoneGroups><VanishedDevices></VanishedDevices></ZoneGroupState>"
    }

    private func browse(_ objectID: String, group: Group) -> String {
        let e = SonosXMLEscape.escape
        var items = ""
        if objectID == "FV:2" {
            for (index, account) in accounts.enumerated() {
                let uri = account.serviceID == SonosMusicService.spotify.serviceID
                    ? "x-sonos-spotify:spotify%3atrack%3a4uLU6hMCjMI75M1A2tKUQC?sid=\(account.serviceID)&flags=8232&sn=\(account.serial)"
                    : "x-sonos-http:song%3a1440857781.mp4?sid=\(account.serviceID)&flags=8224&sn=\(account.serial)"
                items += "<item id=\"FV:2/\(index + 1)\" parentID=\"FV:2\" restricted=\"false\"><dc:title>Favourite \(index + 1)</dc:title>"
                    + "<upnp:class>object.itemobject.item.sonos-favorite</upnp:class><res>\(e(uri))</res></item>"
            }
        } else if objectID == "Q:0", group.elsewhere == nil {
            for (index, uri) in group.queue.enumerated() {
                items += "<item id=\"Q:0/\(index + 1)\" parentID=\"Q:0\" restricted=\"true\"><res>\(e(uri))</res>"
                    + "<dc:title>\(e(group.titles[uri]?.title ?? "Track"))</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class></item>"
            }
        }
        return SonosTrackReference.didlOpen + items + "</DIDL-Lite>"
    }

    private func didl(uri: String, title: String?, artist: String?) -> String {
        let e = SonosXMLEscape.escape
        var item = "<item id=\"-1\" parentID=\"-1\" restricted=\"true\"><res>\(e(uri))</res>"
        if let title { item += "<dc:title>\(e(title))</dc:title>" }
        if let artist { item += "<dc:creator>\(e(artist))</dc:creator>" }
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class></item>"
        return SonosTrackReference.didlOpen + item + "</DIDL-Lite>"
    }
}
