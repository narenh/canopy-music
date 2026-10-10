import CanopyCore
import SwiftUI

/// The single reorderable queue. Always in edit mode so the drag handles are visible to guests.
struct UpNextList: View {
    let session: PartySession
    /// Which rows get the edit-mode delete control (−). Defaults to none.
    var canDelete: (QueueItem) -> Bool = { _ in false }
    /// Which rows get an inline × button instead, which keeps artwork aligned.
    var canRemoveInline: (QueueItem) -> Bool = { _ in false }
    /// Items whose row should stay empty while a flying copy is on its way in.
    var arriving: Set<UUID> = []
    var flashing: Set<UUID> = []
    @Binding var scrollTarget: UUID?
    var onArtworkFrame: (UUID, CGRect) -> Void = { _, _ in }

    @Environment(\.artworkTheme) private var theme

    var body: some View {
        let items = session.state.upNext
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    let locked = item.id == session.state.lockedNextID
                    UpNextRow(
                        item: item, locked: locked, hidden: arriving.contains(item.id),
                        onRemove: canRemoveInline(item) && !locked ? {
                            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { _ = session.remove(item.id) }
                        } : nil,
                        onArtworkFrame: onArtworkFrame
                    )
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
            .environment(\.editMode, .constant(.active))
            .animation(.spring(duration: 0.45, bounce: 0.12), value: items.map(\.id))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

private struct UpNextRow: View {
    let item: QueueItem
    let locked: Bool
    let hidden: Bool
    let onRemove: (() -> Void)?
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
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(item.track.title)")
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
