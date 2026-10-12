import CanopyCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct TVRootView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        let current = model.session.state.current
        ZStack {
            TVBackground(track: current?.track, theme: ArtworkTheme(current?.track.colors))
            if model.hostJoined {
                TVPartyView()
                    .transition(.opacity)
            } else {
                TVStartView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: current?.id)
    }
}

// MARK: - Start: take host control

/// TV-led parties start here: the first phone to scan becomes the host (and can add more hosts
/// later from its own page).
struct TVStartView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 28) {
                Image("CanopyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 70)
                Text("Scan to host")
                    .font(.system(size: 76, weight: .bold))
                Text("Your phone becomes the remote: pick the playlist, play, pause, skip and reorder. Guests can join after.")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 820, alignment: .leading)
            }
            TVQRCode(payload: model.hostURL?.absoluteString)
                .frame(width: 440, height: 440)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Party

struct TVPartyView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        let session = model.session
        let current = session.state.current
        HStack(alignment: .top, spacing: 70) {
            // Now playing.
            VStack(alignment: .leading, spacing: 0) {
                Image("CanopyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 46)
                    .padding(.bottom, 36)
                TVArtwork(track: current?.track, cornerRadius: 22)
                    .frame(width: 500, height: 500)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                    .padding(.bottom, 34)
                Text(current?.track.title ?? "Nothing playing")
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(1)
                Text(current?.track.artist ?? "")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .padding(.bottom, 26)
                TVProgress(session: session)
                    .frame(width: 500)
            }
            .frame(width: 540, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)

            // Up next + how to join.
            VStack(alignment: .leading, spacing: 18) {
                Text("Up next")
                    .font(.system(size: 44, weight: .bold))
                // Takes whatever height is left above the join card and fades out at the bottom.
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Rows are a fixed height, so show as many as fit (plus one to fade out).
                        ForEach(Array(session.state.upNext.prefix(Int(geo.size.height / TVQueueRow.height) + 1))) { item in
                            TVQueueRow(item: item)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                }
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                    }
                }
                TVJoinCard()
            }
            .padding(32)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        }
        .foregroundStyle(.white)
    }
}

struct TVQueueRow: View {
    let item: QueueItem
    static let height: CGFloat = 82

    var body: some View {
        HStack(spacing: 22) {
            TVArtwork(track: item.track, cornerRadius: 8)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.track.title)
                    .font(.system(size: 30, weight: .medium))
                Text(item.track.artist)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            if let requester = item.requester {
                Text(requester.name ?? (requester.origin == .ipad ? "iPad" : "Guest"))
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .frame(height: Self.height)
    }
}

struct TVJoinCard: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 30) {
            TVQRCode(payload: model.guestURL?.absoluteString)
                .frame(width: 170, height: 170)
            VStack(alignment: .leading, spacing: 8) {
                Text("Queue from your phone")
                    .font(.system(size: 36, weight: .bold))
                Text("Scan with your camera, or go to")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.6))
                Text(Self.display(model.friendlyURL ?? model.guestURL))
                    .font(.system(size: 30, weight: .semibold).monospaced())
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
}

struct TVProgress: View {
    let session: PartySession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = session.state.current?.track.duration ?? 0
            let time = min(session.engine.currentTime, duration)
            VStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: duration > 0 ? geo.size.width * time / duration : 0)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(Self.format(time))
                    Spacer()
                    Text("-" + Self.format(max(duration - time, 0)))
                }
                .font(.system(size: 22).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Shared pieces (TV copies of the iPad app's)

struct TVArtwork: View {
    let track: QueueTrack?
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    track?.colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                    track?.colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let url = track?.artworkURL ?? track?.thumbnailURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct TVBackground: View {
    let track: QueueTrack?
    let theme: ArtworkTheme

    var body: some View {
        ZStack {
            theme.base
            TVArtwork(track: track, cornerRadius: 0)
                .blur(radius: 120)
                .saturation(1.4)
                .opacity(0.5)
                .scaleEffect(1.3)
            LinearGradient(colors: [theme.base.opacity(0.1), theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct TVQRCode: View {
    let payload: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
            if let payload, let image = Self.render(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            } else {
                ProgressView().tint(.black)
            }
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
