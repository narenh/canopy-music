import CanopyMusicCore
import SwiftUI

/// The single reorderable queue. Always in edit mode so the drag handles are visible to guests.
struct UpNextList: View {
    let session: PartySession
    /// Which rows get the edit-mode delete control (−). Defaults to none.
    var canDelete: (QueueItem) -> Bool = { _ in false }
    /// Which rows get a press-and-hold Remove menu instead (keeps artwork aligned). On a display,
    /// the requests it added itself always get it (`PartySession.isOwnRequest`); the hub removes them.
    var canRemoveByMenu: (QueueItem) -> Bool = { _ in false }
    /// False on a display when its hub has turned off reordering from phones.
    var canReorder = true
    /// Items whose row should stay empty while a flying copy is on its way in.
    var arriving: Set<UUID> = []
    var flashing: Set<UUID> = []
    @Binding var scrollTarget: UUID?
    var onArtworkFrame: (UUID, CGRect) -> Void = { _, _ in }
    /// Shows recently played songs and the current song (dimmed, "Now Playing") above the queue.
    /// The list rests on the first upcoming song and drifts back to it after `Idle.timeout`.
    var showsHistory = false
    /// Changing this scrolls back to the first upcoming song.
    var homeSignal = 0

    @Environment(\.artworkTheme) private var theme
    @State private var returnTask: Task<Void, Never>?
    /// The rest of the base playlist, read-only below the live queue (docs/multi-device.md).
    @State private var upcoming = UpcomingList()
    @State private var isScrolling = false
    private static let fadeHeight: CGFloat = 48
    private static let historyLimit = 20

    /// One row per song. Songs keep the same row as they go from upcoming to now playing to
    /// played, so the list restyles rows instead of moving them between separate sections
    /// (which left stale, still-draggable rows behind).
    /// `foreign`: Spotify zones, a song in Spotify's own queue that Canopy didn't put there
    /// (`PartySession.foreignUpcoming`). It plays before Canopy's next song, so it sits first,
    /// read-only and locked, with no requester.
    private enum Kind { case played, nowPlaying, foreign, upcoming }
    private struct Row: Identifiable {
        let item: QueueItem
        let kind: Kind
        var id: UUID { item.id }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if showsHistory {
            rows += session.state.history.prefix(Self.historyLimit).reversed().map { Row(item: $0, kind: .played) }
            // While Spotify plays a track from outside the queue, that's Now Playing; the queue's
            // own current song (finished or interrupted) shows as played above it.
            if let current = session.state.current {
                rows.append(Row(item: current, kind: session.externalCurrent == nil ? .nowPlaying : .played))
            }
            if let external = session.externalCurrent { rows.append(Row(item: external, kind: .nowPlaying)) }
        }
        rows += session.foreignUpcoming.map { Row(item: $0, kind: .foreign) }
        rows += session.state.upNext.map { Row(item: $0, kind: .upcoming) }
        return rows
    }

    /// Where the list rests: the first song still to play. Played and now-playing rows sit above
    /// it, for context when someone scrolls up.
    private var homeID: UUID? { session.foreignUpcoming.first?.id ?? session.state.upNext.first?.id }

    var body: some View {
        let rows = rows
        let firstUpcoming = rows.firstIndex { $0.kind == .upcoming } ?? rows.count
        ScrollViewReader { proxy in
            List {
                ForEach(rows) { row in
                    let item = row.item
                    let foreign = row.kind == .foreign
                    let locked = foreign || item.id == session.state.lockedNextID
                    let upcoming = row.kind == .upcoming
                    UpNextRow(
                        item: item, locked: locked, foreign: foreign, nowPlaying: row.kind == .nowPlaying,
                        hidden: arriving.contains(item.id), onArtworkFrame: onArtworkFrame
                    )
                    .opacity(upcoming || foreign ? 1 : 0.4)
                    .allowsHitTesting(upcoming)
                    .modifier(RemoveMenu(enabled: upcoming && (canRemoveByMenu(item) || session.isOwnRequest(item)) && !locked) {
                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { _ = session.remove(item.id) }
                    })
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(flashing.contains(item.id) ? theme.accent.opacity(0.32) : .clear)
                            .padding(.horizontal, 4)
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparatorTint(.white.opacity(0.08))
                    .moveDisabled(!upcoming || locked || !canReorder)
                    .deleteDisabled(!upcoming || !canDelete(item) || locked)
                    .id(item.id)
                    .onAppear {
                        // The end of the live queue is in view: start on the rest of the playlist.
                        if item.id == session.state.upNext.last?.id, self.upcoming.total == nil { loadMoreUpcoming() }
                    }
                }
                .onMove { source, destination in
                    guard let from = source.first, rows.indices.contains(from), rows[from].kind == .upcoming else { return }
                    // Convert list positions to Up next positions; nothing can go above the queue.
                    let to = max(destination, firstUpcoming) - firstUpcoming
                    let fromInQueue = from - firstUpcoming
                    session.move(rows[from].id, to: to > fromInQueue ? to - 1 : to)
                }
                .onDelete(perform: rows.contains(where: { $0.kind == .upcoming && canDelete($0.item) }) ? { offsets in
                    for index in offsets where rows.indices.contains(index) && rows[index].kind == .upcoming && canDelete(rows[index].item) {
                        session.remove(rows[index].id)
                    }
                } : nil)
                // The rest of the playlist carries on the same list: no handle, no delete, and
                // nothing can be dropped among them (they're outside the ForEach that moves).
                ForEach(upcoming.rows) { row in
                    UpcomingRow(row: row)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowSeparatorTint(.white.opacity(0.08))
                        .moveDisabled(true)
                        .deleteDisabled(true)
                        .onAppear { if row.id == upcoming.rows.last?.id { loadMoreUpcoming() } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Feather the bottom edge instead of a hard cut; the margin lets the last row scroll clear of it.
            .contentMargins(.bottom, Self.fadeHeight, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                }
            }
            .environment(\.editMode, .constant(.active))
            .onChange(of: session.state.version) { upcoming.queueChanged(in: session) }
            .onChange(of: ObjectIdentifier(session)) { upcoming = UpcomingList() }
            .animation(.spring(duration: 0.45, bounce: 0.12), value: rows.map(\.id))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
            }
            .onScrollPhaseChange { old, new in
                // Only a person scrolling counts; our own programmatic scrolls (.animating)
                // shouldn't arm the return timer or block re-anchoring.
                let byPerson: Set<ScrollPhase> = [.interacting, .decelerating]
                isScrolling = byPerson.contains(new)
                if isScrolling {
                    returnTask?.cancel()
                    returnTask = nil
                } else if byPerson.contains(old) {
                    scheduleReturn(proxy)
                }
            }
            .onAppear {
                scrollHome(proxy, animated: false)
                // Again once the rows have laid out; the first scroll can land before they exist.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !isScrolling else { return }
                    scrollHome(proxy, animated: false)
                }
            }
            .onChange(of: homeSignal) {
                returnTask?.cancel()
                returnTask = nil
                scrollHome(proxy, animated: true)
            }
            .onChange(of: homeID) {
                // The first upcoming song changed (song ended, a phone moved or added something):
                // keep it in view unless someone is browsing the list. Wait for the list's own
                // reorder animation to settle first; a scroll issued mid-animation gets dropped.
                guard !isScrolling, returnTask == nil else { return }
                // Scroll in the same animation as the reorder, so a song moved to the top lands
                // in view instead of passing above the fold first.
                guard let home = homeID else { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.12)) { proxy.scrollTo(home, anchor: .top) }
                Task {
                    // Safety net: a scroll issued mid-animation can get dropped.
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !isScrolling, returnTask == nil else { return }
                    scrollHome(proxy, animated: true)
                }
            }
        }
    }

    private func loadMoreUpcoming() {
        let list = upcoming, session = session
        Task { await list.loadMore(from: session) }
    }

    private func scheduleReturn(_ proxy: ScrollViewProxy) {
        guard showsHistory else { return }
        returnTask?.cancel()
        returnTask = Task {
            try? await Task.sleep(for: Idle.timeout)
            guard !Task.isCancelled else { return }
            scrollHome(proxy, animated: true)
            returnTask = nil
        }
    }

    private func scrollHome(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let home = homeID else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(home, anchor: .top) }
        } else {
            proxy.scrollTo(home, anchor: .top)
        }
    }
}

private struct UpNextRow: View {
    let item: QueueItem
    let locked: Bool
    /// In Spotify's own queue, not Canopy's.
    var foreign = false
    var nowPlaying = false
    let hidden: Bool
    let onArtworkFrame: (UUID, CGRect) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(track: item.track, cornerRadius: 6)
                .frame(width: 52, height: 52)
                .reportFrame { onArtworkFrame(item.id, $0) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Text(item.track.artist)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if nowPlaying {
                // Who requested it is already shown in the now-playing pane.
                Text("Now Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white.opacity(0.75))
                    .background(.white.opacity(0.14), in: Capsule())
            } else if let requester = item.requester {
                RequesterPill(requester: requester)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityLabel(foreign ? "Queued on Spotify" : "Locked in as next")
            }
        }
        .opacity(hidden ? 0 : 1)
        .contentShape(Rectangle())
    }
}

/// A song from the base playlist past the live queue: read-only, so no pill, lock or handle.
private struct UpcomingRow: View {
    let row: UpcomingPage.Row

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(track: QueueTrack(id: row.trackID, title: row.title, artist: row.artist, thumbnailURL: row.thumbnailURL), cornerRadius: 6)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Text(row.artist)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
        }
    }
}

/// Press-and-hold menu with a single Remove action, only on rows that allow it.
private struct RemoveMenu: ViewModifier {
    let enabled: Bool
    let remove: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button("Remove from queue", systemImage: "trash", role: .destructive, action: remove)
            }
        } else {
            content
        }
    }
}
