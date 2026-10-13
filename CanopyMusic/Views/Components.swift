import AVKit
import CanopyMusicCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ArtworkView: View {
    let track: QueueTrack?
    var large = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            placeholder
            // Decoded at the size it's drawn, from the thumbnail for rows (`ArtworkCache`). In an
            // overlay so a filled image can't grow the view past the size it's given.
            Color.clear.overlay {
                if let url = ArtworkURL.url(for: track, large: large) {
                    ArtworkImage(url: url, fadesIn: true).id(url)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        let colors = track?.colors
        return LinearGradient(
            colors: [
                colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// Full-bleed blurred artwork over the theme's base color, drifting slowly as on the Apple TV
/// (`ArtworkBackground`, shared with it). Song changes cross-fade over 1.2 s.
struct ThemedBackground: View {
    let track: QueueTrack?
    let theme: ArtworkTheme

    var body: some View {
        ArtworkBackground(
            track: track, artworkURL: ArtworkURL.url(for: track, large: true),
            theme: theme, source: ArtworkCache.shared
        )
        .animation(.easeInOut(duration: 1.2), value: track?.id)
    }
}

/// The system AirPlay picker, which lets you pick several AirPlay 2 speakers at once.
struct RoutePicker: UIViewRepresentable {
    var tint: UIColor = .white
    /// Lets a larger tap target (a whole row) open this picker.
    var trigger: RoutePickerTrigger?

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tint
        view.activeTintColor = tint
        trigger?.view = view
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        trigger?.view = view
    }
}

/// Opens an `AVRoutePickerView` from elsewhere by tapping its internal button, so the popover
/// still anchors on the picker's icon.
@MainActor
final class RoutePickerTrigger {
    weak var view: AVRoutePickerView?

    func present() {
        guard let view else { return }
        func findButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton { return button }
            return view.subviews.lazy.compactMap(findButton).first
        }
        findButton(in: view)?.sendActions(for: .touchUpInside)
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.8))
            .frame(width: 15, height: 15)
            .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Explicit")
    }
}

struct RequesterPill: View {
    let requester: Requester
    @Environment(\.artworkTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if requester.origin == .phone {
                Image(systemName: "iphone").font(.system(size: 10, weight: .semibold))
            }
            Text(requester.name ?? (requester.origin == .phone ? "Guest" : "iPad"))
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(.white.opacity(0.75))
        .background(.white.opacity(0.14), in: Capsule())
    }
}

struct LogoView: View {
    var height: CGFloat = 28

    var body: some View {
        Image("CanopyLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("Canopy Music")
    }
}

extension View {
    /// Reports this view's frame in global coordinates.
    func reportFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
    }
}

/// How long the party screen waits without interaction before tidying up (closing search,
/// scrolling Up next back to the queue).
enum Idle {
    static let timeout: Duration = .seconds(12)
}

/// A colored status dot and footnote text. Wrapped lines indent past the dot.
struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        // The dot sits on the first line's baseline (its bottom is its baseline), so wrapped
        // lines hang under the text rather than under the dot.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
