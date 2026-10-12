import CanopyMusicCore
import SwiftUI

enum AddStatus {
    case add, queued, playing
}

struct SearchResultsView: View {
    let results: [QueueTrack]
    let isLoading: Bool
    let message: String?
    let status: (QueueTrack) -> AddStatus
    var autoAddTrackID: String?
    /// Called with the track and its artwork's global frame, which the flight animation starts from.
    let onAdd: (QueueTrack, CGRect) -> Void
    /// Called whenever someone scrolls the results, to keep search open.
    var onInteraction: () -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { track in
                    ResultRow(track: track, status: status(track), autoAdd: autoAddTrackID == track.id, onAdd: onAdd)
                    Divider().overlay(.white.opacity(0.08)).padding(.leading, 82)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, _ in onInteraction() }
        .overlay {
            if isLoading && results.isEmpty {
                ProgressView().tint(.white)
            } else if let message {
                Text(message)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
    }
}

private struct ResultRow: View {
    let track: QueueTrack
    let status: AddStatus
    let autoAdd: Bool
    let onAdd: (QueueTrack, CGRect) -> Void

    @State private var artworkFrame: CGRect = .zero
    @Environment(\.artworkTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(track: track, cornerRadius: 6)
                .frame(width: 56, height: 56)
                .reportFrame { artworkFrame = $0 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                    if track.isExplicit { ExplicitBadge() }
                }
                Text(track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            button
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if status == .add { onAdd(track, artworkFrame) } }
        .task(id: autoAdd) {
            guard autoAdd, status == .add else { return }
            try? await Task.sleep(for: .milliseconds(400))
            onAdd(track, artworkFrame)
        }
    }

    @ViewBuilder private var button: some View {
        switch status {
        case .add:
            Button {
                onAdd(track, artworkFrame)
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.base)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.accent)
        case .queued:
            Label("Queued", systemImage: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
        case .playing:
            Label("Playing", systemImage: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 12)
        }
    }
}
