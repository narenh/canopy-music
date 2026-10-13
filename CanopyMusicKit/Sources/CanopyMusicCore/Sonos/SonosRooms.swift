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
    /// Didn't answer: dimmed, and can't be ticked.
    case notResponding

    /// `live`: the zone's music is playing through Sonos (the party), so ticked rooms are playing it.
    public static func of(roomID: String, model: String, ticked: Bool, joining: Bool, live: Bool, reading: SonosRoomReading?) -> SonosRoomStatus {
        if joining { return .joining }
        if let reading, !reading.responding { return .notResponding }
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
        case .notResponding: "Not responding"
        }
    }

    public var canTick: Bool { self != .notResponding && self != .joining }
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
