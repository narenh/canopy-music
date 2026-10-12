import Foundation
import Observation

/// The base playlist past the live Up Next, for lists that carry on below it read-only (the
/// iPad's Up Next; the web page does the same in app.js). Loaded a page at a time as the end of
/// the list comes into view; when the queue moves on, the rows shown are fetched again.
@MainActor
@Observable
public final class UpcomingList {
    public private(set) var rows: [UpcomingPage.Row] = []
    /// Songs left in the cycle past the live Up Next; nil until the first page arrives.
    public private(set) var total: Int?
    public static let pageSize = 50

    @ObservationIgnored private var loading = false
    /// Bumped by every refetch, so a page fetched before it is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var version: Int?
    @ObservationIgnored private var refetchTask: Task<Void, Never>?

    public init() {}

    public var hasMore: Bool { total.map { rows.count < $0 } ?? true }

    /// The next page (call as the last rows appear).
    public func loadMore(from session: PartySession) async {
        guard !loading, hasMore, !session.state.upNext.isEmpty else { return }
        loading = true
        defer { loading = false }
        let started = generation
        guard let page = try? await session.upcoming(offset: rows.count, limit: Self.pageSize), started == generation else { return }
        let shown = Set(rows.map(\.id))
        rows += page.rows.filter { !shown.contains($0.id) }
        total = page.total
        version = page.version
    }

    /// Call when the queue changes. A song that just became live leaves at once (it now shows as
    /// a live row); the rest are fetched again shortly after, once a burst of changes settles.
    public func queueChanged(in session: PartySession, settle: Duration = .milliseconds(250)) {
        let state = session.state
        if state.upNext.isEmpty {
            generation += 1
            rows = []
            total = nil
            return
        }
        guard total != nil, version != state.version else { return }
        var live = Set(state.upNext.map(\.track.id))
        if let current = state.current { live.insert(current.track.id) }
        if rows.contains(where: { live.contains($0.trackID) }) { rows.removeAll { live.contains($0.trackID) } }
        refetchTask?.cancel()
        refetchTask = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self else { return }
            await self.refetch(from: session)
        }
    }

    /// The same number of rows as shown (at least a page), from the top.
    func refetch(from session: PartySession) async {
        generation += 1
        let started = generation
        let count = max(rows.count, Self.pageSize)
        var fetched: [UpcomingPage.Row] = []
        var last: UpcomingPage?
        while fetched.count < count {
            guard let page = try? await session.upcoming(offset: fetched.count, limit: min(100, count - fetched.count)) else { return }
            fetched += page.rows
            last = page
            if page.rows.isEmpty { break }
        }
        guard started == generation, let last else { return }
        rows = fetched
        total = last.total
        version = last.version
    }
}
