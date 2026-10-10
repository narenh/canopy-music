import CanopyCore
import SwiftUI

/// The single reorderable queue. Always in edit mode so the drag handles are visible to guests.
struct UpNextList: View {
    let session: PartySession
    /// Which rows get the edit-mode delete control (−). Defaults to none.
    var canDelete: (QueueItem) -> Bool = { _ in false }
    /// Which rows get a press-and-hold Remove menu instead (keeps artwork aligned).
    var canRemoveByMenu: (QueueItem) -> Bool = { _ in false }
    /// Items whose row should stay empty while a flying copy is on its way in.
    var arriving: Set<UUID> = []
    var flashing: Set<UUID> = []
    @Binding var scrollTarget: UUID?
    var onArtworkFrame: (UUID, CGRect) -> Void = { _, _ in }
    /// Shows recently played songs, dimmed, above a divider. The list rests at the divider and
    /// drifts back to it after a stretch of no scrolling.
    var showsHistory = false

    @Environment(\.artworkTheme) private var theme
    @State private var returnTask: Task<Void, Never>?
    @State private var isScrolling = false
    private static let fadeHeight: CGFloat = 48
    private static let queueStartID = "queue-start"
    private static let historyLimit = 20
    private static let returnDelay: Duration = .seconds(10)

    var body: some View {
        let items = session.state.upNext
        let played = showsHistory ? Array(session.state.history.prefix(Self.historyLimit).reversed()) : []
        ScrollViewReader { proxy in
            List {
                if !played.isEmpty {
                    ForEach(played) { item in
                        UpNextRow(item: item, locked: false, hidden: false, onArtworkFrame: { _, _ in })
                            .opacity(0.4)
                            .allowsHitTesting(false)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparatorTint(.white.opacity(0.08))
                            .accessibilityLabel("Played: \(item.track.title) by \(item.track.artist)")
                    }
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 2)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .id(Self.queueStartID)
                        .accessibilityHidden(true)
                }
                ForEach(items) { item in
                    let locked = item.id == session.state.lockedNextID
                    UpNextRow(item: item, locked: locked, hidden: arriving.contains(item.id), onArtworkFrame: onArtworkFrame)
                        .modifier(RemoveMenu(enabled: canRemoveByMenu(item) && !locked) {
                            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { _ = session.remove(item.id) }
                        })
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(flashing.contains(item.id) ? theme.accent.opacity(0.32) : .clear)
                                .padding(.horizontal, 4)
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowSeparatorTint(.white.opacity(0.08))
                        .moveDisabled(locked)
                        .deleteDisabled(!canDelete(item) || locked)
                        .id(item.id)
                }
                .onMove { source, destination in
                    guard let from = source.first, items.indices.contains(from) else { return }
                    session.move(items[from].id, to: destination > from ? destination - 1 : destination)
                }
                .onDelete(perform: items.contains(where: canDelete) ? { offsets in
                    for index in offsets where items.indices.contains(index) && canDelete(items[index]) { session.remove(items[index].id) }
                } : nil)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 8)
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
            .animation(.spring(duration: 0.45, bounce: 0.12), value: items.map(\.id))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
            }
            .onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
                if isScrolling {
                    returnTask?.cancel()
                    returnTask = nil
                } else {
                    scheduleReturn(proxy)
                }
            }
            .onAppear { returnToQueue(proxy, animated: false) }
            .onChange(of: played.last?.id) {
                // A song finished: re-anchor unless someone is browsing.
                if !isScrolling, returnTask == nil { returnToQueue(proxy, animated: true) }
            }
        }
    }

    private func scheduleReturn(_ proxy: ScrollViewProxy) {
        guard showsHistory else { return }
        returnTask?.cancel()
        returnTask = Task {
            try? await Task.sleep(for: Self.returnDelay)
            guard !Task.isCancelled else { return }
            returnToQueue(proxy, animated: true)
            returnTask = nil
        }
    }

    private func returnToQueue(_ proxy: ScrollViewProxy, animated: Bool) {
        guard showsHistory, !session.state.history.isEmpty else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(Self.queueStartID, anchor: .top) }
        } else {
            proxy.scrollTo(Self.queueStartID, anchor: .top)
        }
    }
}

private struct UpNextRow: View {
    let item: QueueItem
    let locked: Bool
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
            if let requester = item.requester {
                RequesterPill(requester: requester)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .accessibilityLabel("Locked in as next")
            }
        }
        .opacity(hidden ? 0 : 1)
        .contentShape(Rectangle())
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
