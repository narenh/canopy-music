import Foundation

/// The UPnP services Canopy Music talks to on a Sonos player (port 1400).
public enum SonosUPnPService: String, Sendable {
    case avTransport, queue, renderingControl, groupRenderingControl, zoneGroupTopology, musicServices, contentDirectory, groupManagement

    public var controlPath: String {
        switch self {
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .queue: "/MediaRenderer/Queue/Control"
        case .renderingControl: "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: "/ZoneGroupTopology/Control"
        case .musicServices: "/MusicServices/Control"
        case .contentDirectory: "/MediaServer/ContentDirectory/Control"
        case .groupManagement: "/GroupManagement/Control"
        }
    }

    public var urn: String {
        switch self {
        case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
        case .queue: "urn:schemas-sonos-com:service:Queue:1"
        case .renderingControl: "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .zoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .musicServices: "urn:schemas-upnp-org:service:MusicServices:1"
        case .contentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .groupManagement: "urn:schemas-upnp-org:service:GroupManagement:1"
        }
    }
}

/// One SOAP action call.
public struct SonosRequest: Sendable, Equatable {
    public var host: String
    public var service: SonosUPnPService
    public var action: String
    /// In order: UPnP cares about argument order.
    public var arguments: [Argument]

    public struct Argument: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(host: String, service: SonosUPnPService, action: String, arguments: [Argument] = []) {
        self.host = host
        self.service = service
        self.action = action
        self.arguments = arguments
    }

    public func argument(_ name: String) -> String? {
        arguments.first { $0.name == name }?.value
    }

    /// The SOAP envelope; argument values are XML-escaped (so DIDL-Lite metadata goes in as text).
    public var envelope: String {
        let args = arguments.map { "<\($0.name)>\(SonosXMLEscape.escape($0.value))</\($0.name)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(args)</u:\(action)></s:Body></s:Envelope>"
    }

    /// Actions that only read. The debug probe and discovery use only these.
    public static let readOnlyActions: Set<String> = [
        "GetZoneGroupState", "ListAvailableServices", "Browse", "GetPositionInfo", "GetTransportInfo",
        "GetMediaInfo", "GetTransportSettings", "GetCrossfadeMode", "GetVolume", "GetGroupVolume",
    ]

    public var isReadOnly: Bool { Self.readOnlyActions.contains(action) }
}

public enum SonosError: Error, LocalizedError, Equatable {
    /// The player answered with a UPnP error (701: can't do that now; 800: not the group's coordinator…).
    case upnp(action: String, code: Int?)
    case badResponse(action: String)
    case http(action: String, status: Int)
    /// The chosen room isn't on the network (asleep, unplugged, another Wi‑Fi).
    case unreachable
    /// No account for the zone's service was found on the Sonos.
    case noAccount
    /// The group's last room can't leave it: the music has to play somewhere.
    case lastRoom

    public var errorDescription: String? {
        switch self {
        case .upnp(let action, let code): "Sonos refused \(action)\(code.map { " (error \($0))" } ?? "")."
        case .badResponse(let action): "Sonos sent an unexpected answer to \(action)."
        case .http(let action, let status): "Sonos answered \(action) with HTTP \(status)."
        case .unreachable: "The Sonos speaker isn't answering. Check it's on and on this Wi\u{2011}Fi."
        case .noAccount: "Sonos has no account for this music service. Add it in the Sonos app."
        case .lastRoom: "Music has to play in at least one room."
        }
    }
}

/// Sends SOAP actions to players. A protocol so tests (and the playback path, until it's been
/// tried on real speakers) can use a fake.
public protocol SonosTransport: Sendable {
    func send(_ request: SonosRequest) async throws -> [String: String]
    /// A plain GET on port 1400 (`/xml/device_description.xml`, `/status/accounts`).
    func get(host: String, path: String) async throws -> Data
}

/// The real thing: HTTP to `http://{host}:1400`. Requests time out well inside
/// `PartySession.defaultEngineCallTimeout`, and honour task cancellation.
public struct URLSessionSonosTransport: SonosTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: SonosRequest) async throws -> [String: String] {
        guard let url = URL(string: "http://\(request.host):1400\(request.service.controlPath)") else { throw SonosError.unreachable }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("\"\(request.service.urn)#\(request.action)\"", forHTTPHeaderField: "SOAPACTION")
        urlRequest.httpBody = Data(request.envelope.utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code != .cancelled {
            throw SonosError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 500 { throw SonosError.upnp(action: request.action, code: SonosParse.soapFaultCode(data)) }
        guard status == 200 else { throw SonosError.http(action: request.action, status: status) }
        guard let values = SonosParse.soapResponse(data) else { throw SonosError.badResponse(action: request.action) }
        return values
    }

    public func get(host: String, path: String) async throws -> Data {
        guard let url = URL(string: "http://\(host):1400\(path)") else { throw SonosError.unreachable }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw SonosError.http(action: "GET \(path)", status: status) }
            return data
        } catch let error as URLError where error.code != .cancelled {
            throw SonosError.unreachable
        }
    }
}

/// Typed calls on one player.
public struct SonosClient: Sendable {
    public let transport: any SonosTransport
    public let host: String

    public init(transport: any SonosTransport, host: String) {
        self.transport = transport
        self.host = host
    }

    @discardableResult
    func call(_ service: SonosUPnPService, _ action: String, _ arguments: [SonosRequest.Argument] = []) async throws -> [String: String] {
        try await transport.send(SonosRequest(host: host, service: service, action: action, arguments: arguments))
    }

    private static let instance = SonosRequest.Argument("InstanceID", "0")

    // MARK: Read-only

    public func positionInfo() async throws -> SonosPositionInfo {
        SonosParse.positionInfo(try await call(.avTransport, "GetPositionInfo", [Self.instance]))
    }

    public func transportState() async throws -> SonosTransportState? {
        SonosParse.transportState(try await call(.avTransport, "GetTransportInfo", [Self.instance]))
    }

    public func mediaInfo() async throws -> [String: String] {
        try await call(.avTransport, "GetMediaInfo", [Self.instance])
    }

    public func zoneGroups() async throws -> [SonosGroup] {
        SonosParse.zoneGroups(try await call(.zoneGroupTopology, "GetZoneGroupState")["ZoneGroupState"] ?? "")
    }

    public func availableServices() async throws -> (services: [SonosServiceDescriptor], types: [Int]) {
        SonosParse.availableServices(try await call(.musicServices, "ListAvailableServices"))
    }

    public func browse(_ objectID: String, count: Int = 100) async throws -> [SonosItem] {
        SonosParse.browseItems(try await call(.contentDirectory, "Browse", [
            .init("ObjectID", objectID), .init("BrowseFlag", "BrowseDirectChildren"), .init("Filter", "*"),
            .init("StartingIndex", "0"), .init("RequestedCount", "\(count)"), .init("SortCriteria", ""),
        ]))
    }

    /// This player's own volume (0–100).
    public func volume() async throws -> Int {
        let reply = try await call(.renderingControl, "GetVolume", [Self.instance, .init("Channel", "Master")])
        guard let volume = reply["CurrentVolume"].flatMap(Int.init) else { throw SonosError.badResponse(action: "GetVolume") }
        return volume
    }

    /// The group's volume (sent to its coordinator).
    public func groupVolume() async throws -> Int {
        let reply = try await call(.groupRenderingControl, "GetGroupVolume", [Self.instance])
        guard let volume = reply["CurrentVolume"].flatMap(Int.init) else { throw SonosError.badResponse(action: "GetGroupVolume") }
        return volume
    }

    public func deviceDescription() async throws -> SonosPlayer? {
        SonosParse.deviceDescription(try await transport.get(host: host, path: "/xml/device_description.xml"), host: host)
    }

    // MARK: Changes playback (never sent by discovery or the probe)

    /// Appends (`position` 0) or inserts at a 1-based position; returns where it landed.
    public func addToQueue(uri: String, metadata: String, position: Int, asNext: Bool) async throws -> Int {
        let reply = try await call(.avTransport, "AddURIToQueue", [
            Self.instance, .init("EnqueuedURI", uri), .init("EnqueuedURIMetaData", metadata),
            .init("DesiredFirstTrackNumberEnqueued", "\(position)"), .init("EnqueueAsNext", asNext ? "1" : "0"),
        ])
        guard let first = reply["FirstTrackNumberEnqueued"].flatMap(Int.init) else { throw SonosError.badResponse(action: "AddURIToQueue") }
        return first
    }

    public func removeFromQueue(trackNumber: Int) async throws {
        try await call(.avTransport, "RemoveTrackFromQueue", [Self.instance, .init("ObjectID", "Q:0/\(trackNumber)"), .init("UpdateID", "0")])
    }

    public func clearQueue() async throws {
        try await call(.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
    }

    public func setTransportURI(_ uri: String, metadata: String = "") async throws {
        try await call(.avTransport, "SetAVTransportURI", [Self.instance, .init("CurrentURI", uri), .init("CurrentURIMetaData", metadata)])
    }

    public func seek(trackNumber: Int) async throws {
        try await call(.avTransport, "Seek", [Self.instance, .init("Unit", "TRACK_NR"), .init("Target", "\(trackNumber)")])
    }

    public func seek(to time: TimeInterval) async throws {
        try await call(.avTransport, "Seek", [Self.instance, .init("Unit", "REL_TIME"), .init("Target", SonosTime.string(time))])
    }

    public func play() async throws {
        try await call(.avTransport, "Play", [Self.instance, .init("Speed", "1")])
    }

    public func pause() async throws {
        try await call(.avTransport, "Pause", [Self.instance])
    }

    public func setPlayModeNormal() async throws {
        try await call(.avTransport, "SetPlayMode", [Self.instance, .init("NewPlayMode", "NORMAL")])
    }

    public func setCrossfade(_ on: Bool) async throws {
        try await call(.avTransport, "SetCrossfadeMode", [Self.instance, .init("CrossfadeMode", on ? "1" : "0")])
    }

    /// Leaves whatever group the player is in, as a group of its own.
    public func leaveGroup() async throws {
        try await call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [Self.instance])
    }

    /// Sent to a group's coordinator: hands the group (its queue and what's playing) to `roomID`,
    /// another member. With `rejoin` false this player leaves the group.
    public func delegateCoordination(to roomID: String, rejoin: Bool) async throws {
        try await call(.avTransport, "DelegateGroupCoordinationTo", [
            Self.instance, .init("NewCoordinator", roomID), .init("RejoinGroup", rejoin ? "1" : "0"),
        ])
    }

    public func setVolume(_ volume: Int) async throws {
        try await call(.renderingControl, "SetVolume", [Self.instance, .init("Channel", "Master"), .init("DesiredVolume", "\(Self.clamp(volume))")])
    }

    /// Sent to a group's coordinator before a group volume change: the members' volumes as they
    /// are now, so `setGroupVolume` keeps their balance.
    public func snapshotGroupVolume() async throws {
        try await call(.groupRenderingControl, "SnapshotGroupVolume", [Self.instance])
    }

    /// Sent to a group's coordinator: moves every member's volume in proportion to the last snapshot.
    public func setGroupVolume(_ volume: Int) async throws {
        try await call(.groupRenderingControl, "SetGroupVolume", [Self.instance, .init("DesiredVolume", "\(Self.clamp(volume))")])
    }

    static func clamp(_ volume: Int) -> Int { min(100, max(0, volume)) }
}
