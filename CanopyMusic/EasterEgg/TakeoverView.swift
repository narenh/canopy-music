import CanopyCore
import SwiftUI

/// Full-screen lyrics takeover: the album's color floods the screen and each line's words punch
/// in one at a time, spread across the line's duration.
struct TakeoverView: View {
    let lines: [LyricsEasterEgg.Line]
    let track: Track
    let session: PartySession
    let onDismiss: () -> Void

    var body: some View {
        let flood = Color(rgb: Self.floodColor(for: track))
        TimelineView(.animation) { context in
            let time = session.engine.currentTime
            let (line, progress) = currentLine(at: time)
            let words = line?.text.split(separator: " ").map(String.init) ?? []
            // Finish revealing a bit before the next line so the full line gets a moment on screen.
            let revealed = min(words.count, Int((progress / 0.75) * Double(words.count)) + 1)
            let beat = (sin(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 0.95) + 1) / 2

            ZStack {
                flood
                Color.black.opacity(0.25 + 0.2 * beat)
                if let line, !words.isEmpty {
                    WordStack(words: words, revealed: revealed)
                        .id(line.time)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 1.15).combined(with: .opacity)))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.4), value: revealed)
            .animation(.easeOut(duration: 0.25), value: line?.time)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.6, perform: onDismiss)
        .accessibilityLabel("Lyrics")
        .accessibilityAction(named: "Close lyrics", onDismiss)
    }

    /// The album's background color, darkened just enough for white text to read on it.
    static func floodColor(for track: Track) -> RGB {
        let base = track.colors.flatMap { RGB(hex: $0.background) } ?? RGB(127, 79, 176)
        var color = base
        var t = 0.0
        while color.contrast(with: .white) < 4.5, t < 1 {
            t += 0.05
            color = base.mixed(with: .black, by: t)
        }
        return color
    }

    /// The line playing at `time`, and how far through it we are (0...1).
    private func currentLine(at time: TimeInterval) -> (LyricsEasterEgg.Line?, Double) {
        guard let index = lines.lastIndex(where: { $0.time <= time }) else { return (nil, 0) }
        let line = lines[index]
        let end = index + 1 < lines.count ? lines[index + 1].time : line.time + 4
        let progress = (time - line.time) / max(end - line.time, 0.1)
        return (line, min(max(progress, 0), 1))
    }
}

private struct WordStack: View {
    let words: [String]
    let revealed: Int

    var body: some View {
        let size = Self.fontSize(for: words.joined(separator: " ").count)
        FlowLayout(spacing: size * 0.22, lineSpacing: -size * 0.08) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word.uppercased())
                    .font(.system(size: size, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    .scaleEffect(index < revealed ? 1 : 0.4)
                    .opacity(index < revealed ? 1 : 0)
            }
        }
        .padding(.horizontal, 60)
    }

    static func fontSize(for characters: Int) -> CGFloat {
        min(150, max(70, 190 - CGFloat(characters) * 3.2))
    }
}

/// Centered wrapping layout for the words of a line.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, width: bounds.width)
        let total = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        var y = bounds.midY - total / 2
        for row in rows {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
