import Foundation

/// One Sonos player (a room, or one speaker of a stereo pair or home theatre).
public struct SonosPlayer: Codable, Hashable, Sendable, Identifiable {
    /// `RINCON_…`, the player's UDN without `uuid:`.
    public var id: String
    public var roomName: String
    /// "Sonos Beam".
    public var modelName: String
    /// "Beam", the model's short name.
    public var displayName: String
    /// IP address (or host) of the player's port-1400 API.
    public var host: String
    public var softwareVersion: String?

    public init(id: String, roomName: String, modelName: String, displayName: String, host: String, softwareVersion: String? = nil) {
        self.id = id
        self.roomName = roomName
        self.modelName = modelName
        self.displayName = displayName
        self.host = host
        self.softwareVersion = softwareVersion
    }
}

/// A group of rooms playing together, as `GetZoneGroupState` reports it. A room on its own is a
/// group of one. Commands for the group go to its coordinator.
public struct SonosGroup: Codable, Hashable, Sendable, Identifiable {
    public struct Member: Codable, Hashable, Sendable {
        public var id: String
        public var roomName: String
        public var host: String?
        /// Satellites, subs and the second speaker of a pair are listed but aren't rooms.
        public var isInvisible: Bool

        public init(id: String, roomName: String, host: String?, isInvisible: Bool = false) {
            self.id = id
            self.roomName = roomName
            self.host = host
            self.isInvisible = isInvisible
        }
    }

    public var id: String
    public var coordinatorID: String
    public var members: [Member]

    public init(id: String, coordinatorID: String, members: [Member]) {
        self.id = id
        self.coordinatorID = coordinatorID
        self.members = members
    }

    /// The rooms in the group, coordinator first.
    public var rooms: [Member] {
        let visible = members.filter { !$0.isInvisible }
        return visible.filter { $0.id == coordinatorID } + visible.filter { $0.id != coordinatorID }
    }

    public var coordinator: Member? { members.first { $0.id == coordinatorID } }

    /// "Bedroom" or "Bedroom + Kitchen".
    public var name: String { rooms.map(\.roomName).joined(separator: " + ") }
}

/// The music services Canopy Music can hand to Sonos. Ids are Sonos's service ids (`sid`),
/// as `ListAvailableServices` reports them (checked against a real S2 household: Apple Music
/// is 204, Spotify 12).
public enum SonosMusicService: String, Codable, Sendable, CaseIterable {
    case appleMusic, spotify

    public var serviceID: Int {
        switch self {
        case .appleMusic: 204
        case .spotify: 12
        }
    }

    /// The name `ListAvailableServices` gives it.
    public var sonosName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }

    public init?(serviceID: Int) {
        guard let match = Self.allCases.first(where: { $0.serviceID == serviceID }) else { return nil }
        self = match
    }

    /// Sonos's "service type": sid × 256 + 7. Checked on a real S2 household: the type list from
    /// `ListAvailableServices` has 52231 (204) and 3079 (12), and favourites from Sonos Radio
    /// (sid 303) carry `SA_RINCON77575_…` (303 × 256 + 7).
    public static func serviceType(forServiceID sid: Int) -> Int { sid * 256 + 7 }

    public var serviceType: Int { Self.serviceType(forServiceID: serviceID) }
}

/// A music-service account linked in the Sonos app, as far as the household gives it away: its
/// service id and account serial number (`sn`). Current S2 firmware lists no accounts (and no
/// names for them), so these are read off item URIs the household has played or saved.
public struct SonosAccount: Codable, Hashable, Sendable, Identifiable {
    public var serviceID: Int
    public var serialNumber: Int
    /// The `desc` token seen with this account's items, when one was (`SA_RINCON3079_X_#Svc3079-0-Token`).
    public var token: String?
    /// Where it was seen: a song title, to help tell accounts apart.
    public var example: String?
    /// The room whose queue (or now playing) it was seen in; nil for favourites.
    public var seenIn: String?

    public var id: String { "\(serviceID):\(serialNumber)" }
    public var service: SonosMusicService? { SonosMusicService(serviceID: serviceID) }

    public init(serviceID: Int, serialNumber: Int, token: String? = nil, example: String? = nil, seenIn: String? = nil) {
        self.serviceID = serviceID
        self.serialNumber = serialNumber
        self.token = token
        self.example = example
        self.seenIn = seenIn
    }
}

/// A service as `ListAvailableServices` describes it.
public struct SonosServiceDescriptor: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var auth: String?

    public init(id: Int, name: String, auth: String? = nil) {
        self.id = id
        self.name = name
        self.auth = auth
    }
}

/// One DIDL-Lite item (queue entry, favourite, now playing).
public struct SonosItem: Hashable, Sendable {
    public var id: String
    public var title: String?
    public var creator: String?
    public var album: String?
    /// The `res` URI (empty for favourites that are shortcuts).
    public var uri: String?
    public var duration: TimeInterval?
    public var upnpClass: String?
    /// `desc` (the service token), from the item or from its `r:resMD`.
    public var desc: String?
    /// A favourite's own metadata (`r:resMD`), parsed: its item id and desc are what the Sonos app
    /// used for it.
    public var resMetadataItemID: String?
    public var favoriteDescription: String?

    public init(id: String, title: String? = nil, creator: String? = nil, album: String? = nil, uri: String? = nil,
                duration: TimeInterval? = nil, upnpClass: String? = nil, desc: String? = nil,
                resMetadataItemID: String? = nil, favoriteDescription: String? = nil) {
        self.id = id
        self.title = title
        self.creator = creator
        self.album = album
        self.uri = uri
        self.duration = duration
        self.upnpClass = upnpClass
        self.desc = desc
        self.resMetadataItemID = resMetadataItemID
        self.favoriteDescription = favoriteDescription
    }
}

/// AVTransport `GetPositionInfo`.
public struct SonosPositionInfo: Hashable, Sendable {
    /// 1-based position in the queue.
    public var track: Int
    public var trackURI: String?
    public var duration: TimeInterval?
    public var position: TimeInterval?
    public var item: SonosItem?

    public init(track: Int, trackURI: String?, duration: TimeInterval?, position: TimeInterval?, item: SonosItem? = nil) {
        self.track = track
        self.trackURI = trackURI
        self.duration = duration
        self.position = position
        self.item = item
    }
}

/// AVTransport `CurrentTransportState`.
public enum SonosTransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
}
