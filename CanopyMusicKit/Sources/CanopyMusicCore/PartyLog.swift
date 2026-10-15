import Foundation

/// A song that played in the zone.
public struct PlayedSong: Codable, Equatable, Sendable {
    /// The queue item, so going back to a song (or restarting it) doesn't log it twice.
    public var itemID: UUID
    public var track: QueueTrack
    /// nil for a base playlist song.
    public var requester: Requester?
    public var playedAt: Date

    public init(itemID: UUID, track: QueueTrack, requester: Requester?, playedAt: Date) {
        self.itemID = itemID
        self.track = track
        self.requester = requester
        self.playedAt = playedAt
    }
}

/// A song saving the party would save: one that played, or a request still waiting to.
public struct PartySong: Equatable, Sendable {
    public var track: QueueTrack
    /// nil for a base playlist song.
    public var requester: Requester?
}

/// Every song that played in the zone, in order, for saving the party as a playlist. Unlike the
/// queue's history it isn't capped. A song counts once it has started playing (the player took
/// it); songs skipped before they played, and songs that failed to play, don't.
public struct PartyLog: Codable, Equatable, Sendable {
    /// When the first song started.
    public private(set) var startedAt: Date?
    public private(set) var songs: [PlayedSong] = []

    public init() {}

    public var isEmpty: Bool { songs.isEmpty }

    /// Records that `item` started playing. Each queue item counts once.
    @discardableResult
    public mutating func record(_ item: QueueItem, at date: Date = Date()) -> Bool {
        guard !songs.contains(where: { $0.itemID == item.id }) else { return false }
        if startedAt == nil { startedAt = date }
        songs.append(PlayedSong(itemID: item.id, track: item.track, requester: item.requester, playedAt: date))
        return true
    }

    /// The songs to save, each once: the songs that played, in the order they played, then the
    /// requests still `waiting` to (the zone's current item and Up next, in queue order). Requests
    /// are the point of saving, so a request counts whether or not it got to play; one removed
    /// from the queue (or skipped) before playing doesn't. Base playlist songs count only once
    /// they've played. `onlyRequests` keeps the songs someone added (from a phone, the hub or a
    /// display), leaving out the base playlist's.
    public func songs(onlyRequests: Bool, waiting: [QueueItem] = []) -> [PartySong] {
        let played = songs.map { PartySong(track: $0.track, requester: $0.requester) }
        let loggedIDs = Set(songs.map(\.itemID))
        let pending = waiting
            .filter { $0.requester != nil && !loggedIDs.contains($0.id) }
            .map { PartySong(track: $0.track, requester: $0.requester) }
        var seen = Set<String>()
        return (played + pending).filter { song in
            // A song from a link isn't the service's to put in a playlist.
            guard song.track.link == nil, !onlyRequests || song.requester != nil else { return false }
            return seen.insert(song.track.id).inserted
        }
    }

    public func tracks(onlyRequests: Bool, waiting: [QueueItem] = []) -> [QueueTrack] {
        songs(onlyRequests: onlyRequests, waiting: waiting).map(\.track)
    }

    /// "Queued by Sam, Phil and 6 others": the people who added the saved songs from their phones
    /// and gave a name, most songs first. Songs added on the hub or a display, and phones without
    /// a name, aren't credited. nil when nobody is.
    public func credit(onlyRequests: Bool, waiting: [QueueItem] = []) -> String? {
        var names: [String] = []
        var counts: [String: Int] = [:]
        for song in songs(onlyRequests: onlyRequests, waiting: waiting) {
            guard let requester = song.requester, requester.origin == .phone,
                  let name = requester.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.lowercased() != "guest" else { continue }
            let key = name.lowercased()
            if counts[key] == nil { names.append(name) }
            counts[key, default: 0] += 1
        }
        guard !names.isEmpty else { return nil }
        // Stable: ties keep the order they first queued in.
        let ranked = names.enumerated()
            .sorted { (counts[$0.element.lowercased()]!, -$0.offset) > (counts[$1.element.lowercased()]!, -$1.offset) }
            .map(\.element)
        let list = switch ranked.count {
        case 1: ranked[0]
        case 2: "\(ranked[0]) and \(ranked[1])"
        case 3: "\(ranked[0]), \(ranked[1]) and \(ranked[2])"
        default: "\(ranked[0]), \(ranked[1]) and \(ranked.count - 2) others"
        }
        return "Queued by \(list)"
    }

    /// The saved playlist's description: the credit, then where it came from.
    public func playlistDescription(onlyRequests: Bool, waiting: [QueueItem] = []) -> String {
        [credit(onlyRequests: onlyRequests, waiting: waiting), "Canopy Music"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The name field starts as the party's date and a space ("2026-10-12 "), for the host to
    /// type the rest. Today before anything has played.
    public func suggestedName(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: startedAt ?? Date())
        return String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// What a hub needs to offer saving the party: shown before saving, on the hub and the web page.
public struct PartySaveInfo: Codable, Equatable, Sendable {
    /// "2026-10-12 "
    public var suggestedName: String
    /// Songs that would be saved with "Only songs guests added" off, and on (see
    /// `PartyLog.songs(onlyRequests:waiting:)`).
    public var allCount: Int
    public var requestCount: Int
    /// "Saves to your Apple Music library", or nil when the service can't save playlists.
    public var destination: String?

    /// Hubs offer saving as soon as someone has added a song (played or still in Up next): until
    /// then the party is just the base playlist, nothing worth saving, and End is a plain
    /// confirmation.
    public var offersSave: Bool { destination != nil && requestCount > 0 }
}

public enum PartySaveError: LocalizedError, Equatable {
    case nothingToSave(onlyRequests: Bool)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .nothingToSave(let onlyRequests): onlyRequests ? "Guests haven't added any songs yet." : "No songs have played or been added yet."
        case .unsupported: "This music service can't save playlists."
        }
    }
}
