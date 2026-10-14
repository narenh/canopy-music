import Foundation

/// Song counts for playlist rows whose list doesn't include them: Apple Music's library playlist
/// list has no count, so each playlist is counted on its own as its row appears (the iPad's
/// picker, the web pickers through `/api/host/playlists/counts`), a few at once so a long list
/// still shows straight away. Counts are remembered for a few minutes, and a load records what it
/// found (`PartySession.load`), so a playlist emptied since it was counted shows as empty.
public actor PlaylistSongCounts {
    public static let shared = PlaylistSongCounts()

    /// Counts fetched at once; the rest wait their turn.
    public let limit: Int
    /// How long a count is trusted before a row asks again (songs may have been added elsewhere).
    public let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var known: [String: (count: Int, at: Date)] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = 4, lifetime: TimeInterval = 300, now: @escaping @Sendable () -> Date = Date.init) {
        self.limit = limit
        self.lifetime = lifetime
        self.now = now
    }

    /// `playlist`'s count: a remembered one (a load just now beats a list that may be older),
    /// the list's own (Spotify), or fetched through `catalog.songCount(of:)`. nil when it isn't
    /// known (it failed, or the row went away while it waited its turn).
    public func count(of playlist: PlaylistSummary, in catalog: any MusicCatalog) async -> Int? {
        if let count = remembered(playlist.id) { return count }
        if let listed = playlist.songCount { return listed }
        await acquire()
        defer { release() }
        // Another row may have counted it meanwhile.
        if let count = remembered(playlist.id) { return count }
        guard !Task.isCancelled, let count = try? await catalog.songCount(of: playlist) else { return nil }
        record(count, for: playlist.id)
        return count
    }

    public func record(_ count: Int, for playlistID: String) {
        known[playlistID] = (count, now())
    }

    private func remembered(_ id: String) -> Int? {
        guard let entry = known[id], now().timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.count
    }

    /// A free slot, or a wait for one (handed over by `release`).
    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
