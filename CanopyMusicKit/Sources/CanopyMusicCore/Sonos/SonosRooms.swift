import Foundation

/// One room as last read: whether it answered, its volume, and what its group is playing.
public struct SonosRoomReading: Equatable, Sendable {
    public var responding: Bool
    /// 0–100; nil until read.
    public var volume: Int?
    /// The coordinator of the group it's in.
    public var coordinatorID: String?
    /// What its group is playing, when that's something playing now and not a Canopy Music
    /// queue ("Playing Ribs – Lorde", "Playing TV"); nil when it's idle or paused.
    public var elsewhere: String?

    public init(responding: Bool, volume: Int? = nil, coordinatorID: String? = nil, elsewhere: String? = nil) {
        self.responding = responding
        self.volume = volume
        self.coordinatorID = coordinatorID
        self.elsewhere = elsewhere
    }

    public static let notResponding = SonosRoomReading(responding: false)
}

/// What a room's second line says in the speaker lists.
public enum SonosRoomStatus: Equatable, Sendable {
    /// Ticked and playing the zone's music.
    case ours
    /// Ticked, on its way into the group.
    case joining
    /// Its model ("Beam"): idle, or ticked before the music has started.
    case idle(model: String)
    /// Playing something else (shown in orange); ticking it takes it over.
    case busy(String)
    /// Another Canopy Music zone plays on it (orange, "In use by Living Room iPad (Apple
    /// Music)"). It isn't ticked: "Use" takes it over, once confirmed.
    case inUse(zone: String, service: String)
    /// Didn't answer: dimmed, and can't be ticked.
    case notResponding

    /// `live`: the zone's music is playing through Sonos (the party), so ticked rooms are playing it.
    /// `claim`: another zone's, playing on this room (`SonosOutputController.claim(on:)`); never
    /// this zone's own.
    public static func of(roomID: String, model: String, ticked: Bool, joining: Bool, live: Bool, reading: SonosRoomReading?,
                          claim: SonosZoneClaim? = nil) -> SonosRoomStatus {
        if joining { return .joining }
        if let reading, !reading.responding { return .notResponding }
        if let claim { return .inUse(zone: claim.zone, service: claim.service) }
        if ticked, live { return .ours }
        if !ticked, let elsewhere = reading?.elsewhere { return .busy(elsewhere) }
        return .idle(model: model)
    }

    public var text: String {
        switch self {
        case .ours: "Playing Canopy Music"
        case .joining: "Joining…"
        case .idle(let model): model
        case .busy(let what): what
        case .inUse(let zone, let service): "In use by \(zone) (\(service))"
        case .notResponding: "Not responding"
        }
    }

    /// Orange: playing something else, or another zone's.
    public var isBusy: Bool {
        switch self {
        case .busy, .inUse: true
        default: false
        }
    }

    public var isInUse: Bool {
        if case .inUse = self { return true }
        return false
    }

    /// A tick takes it: not a room that doesn't answer, one joining, or another zone's (that's
    /// "Use", confirmed first).
    public var canTick: Bool { self != .notResponding && self != .joining && !isInUse }
}

/// The Sonos rooms a hub's zone plays on, as it tells other hubs (`GET /api/zone`, `sonos`), so
/// theirs can say "In use by …" rather than offer them as free. Only rooms Sonos's own layout
/// can confirm: room ids (`RINCON_…`), the first leading.
public struct SonosZoneClaim: Codable, Equatable, Sendable {
    /// The zone's name ("Living Room iPad").
    public var zone: String
    /// The service it streams, as the Sonos app names it ("Apple Music", "Spotify").
    public var service: String
    /// The Sonos household (`Sonos_…`); nil before it has been read.
    public var household: String?
    /// The rooms it plays on, the coordinator first.
    public var rooms: [String]

    public init(zone: String, service: String, household: String? = nil, rooms: [String]) {
        self.zone = zone
        self.service = service
        self.household = household
        self.rooms = rooms
    }

    /// Whether this claim is the one playing on `roomID`, given the group it's in now (its
    /// coordinator, `coordinatorID`, from the live layout; nil if not read): the zone lists the
    /// room, and the room's group is led by one of the zone's rooms. A room someone has since
    /// moved into another group (the Sonos app, or a zone that took it over) isn't the claim's.
    public func covers(_ roomID: String, coordinatorID: String?) -> Bool {
        guard rooms.contains(roomID) else { return false }
        guard let coordinatorID else { return true }
        return rooms.contains(coordinatorID)
    }

    /// The claim playing on `roomID` among several (two hubs can list a room for a moment, as one
    /// takes it from the other): the one whose coordinator leads the room's group, else the first
    /// that covers it.
    public static func playing(on roomID: String, coordinatorID: String?, in claims: [SonosZoneClaim]) -> SonosZoneClaim? {
        let covering = claims.filter { $0.covers(roomID, coordinatorID: coordinatorID) }
        return covering.first { $0.rooms.first == coordinatorID } ?? covering.first
    }
}

public enum SonosNowPlaying {
    /// What a group is playing, for a room's second line: nil when it isn't playing, or it's a
    /// queue of Canopy Music's own (`ourCoordinatorID`'s).
    public static func describe(state: SonosTransportState?, position: SonosPositionInfo?, mediaURI: String?,
                                mediaTitle: String? = nil, coordinatorID: String, ourCoordinatorID: String?) -> String? {
        guard SonosPlaybackRules.isPlaying(state), coordinatorID != ourCoordinatorID else { return nil }
        let uri = position?.trackURI ?? mediaURI ?? ""
        let source = mediaURI ?? uri
        if source.hasPrefix("x-sonos-htastream:") { return "Playing TV" }
        if source.hasPrefix("x-rincon-stream:") { return "Playing line-in" }
        if source.hasPrefix("x-sonos-vli:") || uri.hasPrefix("x-sonos-vli:") {
            let lower = (source + uri).lowercased()
            if lower.contains("airplay") { return "Playing from AirPlay" }
            if lower.contains("spotify") { return "Playing from Spotify" }
        }
        let title = position?.item?.title.flatMap { $0.isEmpty ? nil : $0 }
        let artist = position?.item?.creator.flatMap { $0.isEmpty ? nil : $0 }
        if let title {
            return "Playing \(title)" + (artist.map { " – \($0)" } ?? "")
        }
        if let mediaTitle, !mediaTitle.isEmpty { return "Playing \(mediaTitle)" }
        return "Playing something else"
    }
}
