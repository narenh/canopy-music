import CanopyMusicCore
import SwiftUI

/// Full-screen lyrics takeover: the album's color floods the screen and each line's words punch
/// in one at a time, spread across the line's duration.
struct TakeoverView: View {
    let lines: [LyricsEasterEgg.Line]
    let track: QueueTrack
    let session: PartySession
    /// Bigger words on a TV, read from across the room.
    var scale: CGFloat = 1
    /// Told when it comes on screen and goes, so what's under it can stop (`screenCovered`).
    var onShowingChange: (Bool) -> Void = { _ in }
    let onDismiss: () -> Void

    /// On screen: while lyrics are being sung, not during the intro or outro (`watch`).
    @State private var showing = false
    /// Frames are drawn while it shows and for its fade out.
    @State private var drawing = false
    /// The beat's clock, which stands still while the music's paused: when it paused, and how
    /// long it has stood still before.
    @State private var beatPausedAt: Date?
    @State private var beatPaused: TimeInterval = 0

    var body: some View {
        let flood = Color(rgb: Self.floodColor(for: track))
        let window = Self.lyricWindow(lines)
        // Every frame, but only while it's on screen and the music plays.
        TimelineView(.animation(paused: !drawing || !session.isPlaying)) { context in
            let time = session.position
            // Only on screen while lyrics are being sung, not during the intro or outro.
            let active = showing
            let (line, progress) = currentLine(at: time)
            let words = line?.text.split(separator: " ").map(String.init) ?? []
            // Finish revealing a bit before the next line so the full line gets a moment on screen.
            let revealed = min(words.count, Int((progress / 0.75) * Double(words.count)) + 1)
            let beatTime = (beatPausedAt ?? context.date).timeIntervalSinceReferenceDate - beatPaused
            let beat = (sin(beatTime * .pi * 2 / 0.95) + 1) / 2

            ZStack {
                flood
                Color.black.opacity(0.25 + 0.2 * beat)
                if let line, !words.isEmpty {
                    WordStack(words: words, revealed: revealed, scale: scale)
                        .id(line.time)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 1.15).combined(with: .opacity)))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.4), value: revealed)
            .animation(.easeOut(duration: 0.25), value: line?.time)
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: active)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.6, perform: onDismiss)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .accessibilityLabel("Lyrics")
            .accessibilityAction(named: "Close lyrics", onDismiss)
        }
        .ignoresSafeArea()
        .task(id: session.isPlaying) { await watch(window) }
        .task(id: showing) {
            // Drawn on through the fade out, so the last line leaves as it did.
            if showing { drawing = true; return }
            try? await Task.sleep(for: .seconds(0.7))
            if !Task.isCancelled { drawing = false }
        }
        .onChange(of: showing, initial: true) { onShowingChange(showing) }
        .onDisappear { onShowingChange(false) }
        .onChange(of: session.isPlaying, initial: true) { _, playing in
            if playing, let pausedAt = beatPausedAt {
                beatPaused += Date().timeIntervalSince(pausedAt)
                beatPausedAt = nil
            } else if !playing, beatPausedAt == nil {
                beatPausedAt = Date()
            }
        }
    }

    /// Keeps `showing` up to date without drawing frames: right at the moment the lyrics start or
    /// end, and a few times a second in between (twice while paused) to catch seeks.
    private func watch(_ window: Range<TimeInterval>) async {
        while !Task.isCancelled {
            let time = session.position
            let now = window.contains(time)
            if now != showing { showing = now }
            var wait: TimeInterval = 0.5
            if session.isPlaying {
                let edge = time < window.lowerBound ? window.lowerBound : time < window.upperBound ? window.upperBound : .infinity
                wait = min(0.25, max(edge - time, 0.01))
            }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// Whether the takeover is on screen at `time` (it hides for the intro and outro).
    static func isShowing(_ lines: [LyricsEasterEgg.Line], at time: TimeInterval) -> Bool {
        lyricWindow(lines).contains(time)
    }

    /// From just before the first sung line to the end of the last one (the next timestamp, often
    /// an empty line marking the outro).
    static func lyricWindow(_ lines: [LyricsEasterEgg.Line]) -> Range<TimeInterval> {
        guard let first = lines.firstIndex(where: { !$0.text.isEmpty }),
              let last = lines.lastIndex(where: { !$0.text.isEmpty }) else { return 0..<0 }
        let end = last + 1 < lines.count ? lines[last + 1].time : lines[last].time + 4
        return (lines[first].time - 0.4)..<end
    }

    /// The album's background color, darkened just enough for white text to read on it.
    static func floodColor(for track: QueueTrack) -> RGB {
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
    var scale: CGFloat = 1

    var body: some View {
        let size = Self.fontSize(for: words.joined(separator: " ").count) * scale
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
        .padding(.horizontal, 60 * scale)
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
