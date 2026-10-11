import Foundation

public enum AddResult: Equatable, Sendable {
    case added(QueueItem, index: Int)
    case alreadyQueued(QueueItem, index: Int)
    case nowPlaying
}

/// The whole queue as a value type. All rules live here so they can be unit tested without audio.
///
/// `upNext` is one list: playlist items and requests are interleaved freely. Playlist items are
/// materialized a window at a time from `playlist`, looping forever.
public struct QueueState: Codable, Equatable, Sendable {
    public static let playlistWindow = 25
    public static let historyLimit = 100

    /// Base playlist in play order (already shuffled if shuffle was on).
    public private(set) var playlist: [QueueTrack] = []
    public private(set) var playlistName: String?
    /// Next position in `playlist` to materialize into `upNext`.
    public private(set) var cursor = 0
    public private(set) var cycle = 0
    /// Positions in the current cycle that were already satisfied by a request.
    public private(set) var skipPositions: Set<Int> = []

    public private(set) var current: QueueItem?
    public private(set) var upNext: [QueueItem] = []
    public private(set) var history: [QueueItem] = []
    /// Set when the next item has been handed to a player that can't take it back.
    public private(set) var lockedNextID: UUID?
    public private(set) var version = 0

    public init() {}

    // MARK: Playlist

    /// Starts over with a new base playlist in its original order: clears now playing, requests,
    /// and everything queued. Nothing is current until playback starts.
    public mutating func load(playlist tracks: [QueueTrack], name: String?) {
        playlist = tracks
        playlistName = name
        cursor = 0
        cycle = 0
        skipPositions = []
        current = nil
        upNext = []
        lockedNextID = nil
        refill()
        version += 1
    }

    /// Reshuffles the base playlist and rebuilds the playlist songs in Up Next. Requests stay put.
    public mutating func shufflePlaylist() {
        playlist.shuffle()
        cursor = 0
        skipPositions = []
        upNext.removeAll { !$0.isRequest && $0.id != lockedNextID }
        refill()
        version += 1
    }

    mutating func refill() {
        guard !playlist.isEmpty else { return }
        var have = upNext.lazy.filter { !$0.isRequest }.count
        // Never show a playlist song twice: short playlists keep one copy of each queued, and
        // loop by re-adding songs as they play.
        let target = min(Self.playlistWindow, playlist.count)
        var guardCount = 0
        while have < target, guardCount < playlist.count * 2 + Self.playlistWindow {
            guardCount += 1
            if cursor >= playlist.count {
                cursor = 0
                cycle += 1
                skipPositions = []
            }
            defer { cursor += 1 }
            if skipPositions.remove(cursor) != nil { continue }
            upNext.append(QueueItem(track: playlist[cursor], requester: nil))
            have += 1
        }
    }

    // MARK: Requests

    /// Lowest index an item may be inserted at or moved to (the locked item can't be displaced).
    var floorIndex: Int {
        if let locked = lockedNextID, upNext.first?.id == locked { return 1 }
        return 0
    }

    /// First come, first served: right after the last request nobody has dragged.
    public var requestInsertionIndex: Int {
        let afterAnchor = upNext.lastIndex { $0.isRequest && $0.autoPlaced }.map { $0 + 1 } ?? 0
        return max(afterAnchor, floorIndex)
    }

    @discardableResult
    public mutating func addRequest(_ track: QueueTrack, by requester: Requester, at date: Date = Date()) -> AddResult {
        if current?.track.id == track.id { return .nowPlaying }
        if let index = upNext.firstIndex(where: { $0.isRequest && $0.track.id == track.id }) {
            return .alreadyQueued(upNext[index], index: index)
        }

        // Dedupe against the playlist: drop the next playlist copy of this song.
        if let dup = upNext.firstIndex(where: { !$0.isRequest && $0.track.id == track.id && $0.id != lockedNextID }) {
            upNext.remove(at: dup)
        } else if cursor < playlist.count,
                  let pos = playlist[cursor...].firstIndex(where: { $0.id == track.id }) {
            skipPositions.insert(pos)
        }

        let item = QueueItem(track: track, requester: requester, addedAt: date)
        let index = requestInsertionIndex
        upNext.insert(item, at: index)
        refill()
        version += 1
        return .added(item, index: index)
    }

    // MARK: Editing

    @discardableResult
    public mutating func move(_ id: UUID, to destination: Int) -> Bool {
        guard id != lockedNextID, let from = upNext.firstIndex(where: { $0.id == id }) else { return false }
        var item = upNext.remove(at: from)
        item.autoPlaced = false
        let to = min(max(destination, floorIndex), upNext.count)
        upNext.insert(item, at: to)
        version += 1
        return true
    }

    /// Moves `id` to directly after `anchor`, or to the top when `anchor` is nil.
    @discardableResult
    public mutating func move(_ id: UUID, after anchor: UUID?) -> Bool {
        guard id != anchor else { return false }
        guard let anchor else { return move(id, to: 0) }
        guard let from = upNext.firstIndex(where: { $0.id == id }),
              var anchorIndex = upNext.firstIndex(where: { $0.id == anchor }) else { return false }
        if from < anchorIndex { anchorIndex -= 1 }
        return move(id, to: anchorIndex + 1)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> QueueItem? {
        guard id != lockedNextID, let index = upNext.firstIndex(where: { $0.id == id }) else { return nil }
        let item = upNext.remove(at: index)
        refill()
        version += 1
        return item
    }

    // MARK: Playback progression

    /// Moves `current` into history and makes the next item current.
    /// Pass the id of the item the player actually advanced to, in case the list changed underneath it.
    @discardableResult
    public mutating func advance(to id: UUID? = nil) -> QueueItem? {
        if let current {
            history.insert(current, at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        var index = 0
        if let id, let found = upNext.firstIndex(where: { $0.id == id }) { index = found }
        current = upNext.indices.contains(index) ? upNext.remove(at: index) : nil
        lockedNextID = nil
        refill()
        version += 1
        return current
    }

    /// Makes the most recently played song current again; the current song goes back to the
    /// top of Up Next. Returns false when there's no history.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard !history.isEmpty else { return false }
        if let current { upNext.insert(current, at: 0) }
        current = history.removeFirst()
        lockedNextID = nil
        version += 1
        return true
    }

    public mutating func lockNext() {
        guard let first = upNext.first, lockedNextID != first.id else { return }
        lockedNextID = first.id
        version += 1
    }

    public mutating func unlockNext() {
        guard lockedNextID != nil else { return }
        lockedNextID = nil
        version += 1
    }

    public mutating func clearRequests() {
        upNext.removeAll { $0.isRequest && $0.id != lockedNextID }
        refill()
        version += 1
    }
}
