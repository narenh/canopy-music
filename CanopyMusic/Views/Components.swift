import AVKit
import CanopyCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ArtworkView: View {
    let track: Track?
    var large = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        let url = large ? (track?.artworkURL ?? track?.thumbnailURL) : (track?.thumbnailURL ?? track?.artworkURL)
        ZStack {
            placeholder
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
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

/// Full-bleed blurred artwork over the theme's base color.
struct ThemedBackground: View {
    let track: Track?
    let theme: ArtworkTheme

    var body: some View {
        ZStack {
            theme.base
            if let url = track?.artworkURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 1.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .blur(radius: 90)
                            .saturation(1.4)
                            .opacity(0.5)
                            .scaleEffect(1.3)
                    }
                }
                .id(url)
                .transition(.opacity)
            }
            LinearGradient(colors: [theme.base.opacity(0.1), theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 1.2), value: track?.id)
        .ignoresSafeArea()
    }
}

struct QRCodeView: View {
    let payload: String

    var body: some View {
        if let image = Self.render(payload) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    static func render(_ payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The system AirPlay picker, which lets you pick several AirPlay 2 speakers at once.
struct RoutePicker: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
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
            .accessibilityLabel("Canopy")
    }
}

extension View {
    /// Reports this view's frame in global coordinates.
    func reportFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
    }
}
