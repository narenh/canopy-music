import CanopyMusicCore
import SwiftUI

/// A copy of a song's artwork flying from a search result into its new slot in Up Next.
struct Flight: Identifiable {
    let id: UUID
    let track: QueueTrack
    let from: CGRect
    var progress: CGFloat = 0
}

struct FlightLayer: View {
    let flights: [Flight]
    let destinations: [UUID: CGRect]
    /// Used when the destination row hasn't laid out yet.
    let fallback: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(flights) { flight in
                ArtworkView(track: flight.track, cornerRadius: 8)
                    .modifier(FlightPath(progress: flight.progress, from: flight.from, to: destinations[flight.id] ?? fallback))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Moves along a curve that arcs above both endpoints, growing slightly and casting a shadow mid-flight.
private struct FlightPath: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGRect
    let to: CGRect

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: to.midX, y: to.midY)
        let control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 180)
        let q = 1 - p
        let point = CGPoint(
            x: q * q * start.x + 2 * q * p * control.x + p * p * end.x,
            y: q * q * start.y + 2 * q * p * control.y + p * p * end.y
        )
        let width = from.width + (to.width - from.width) * p
        let height = from.height + (to.height - from.height) * p
        let lift = sin(p * .pi)

        content
            .frame(width: width, height: height)
            .scaleEffect(1 + 0.35 * lift)
            .rotationEffect(.degrees(-6 * lift))
            .shadow(color: .black.opacity(0.45 * lift), radius: 28 * lift, y: 16 * lift)
            .position(point)
    }
}
