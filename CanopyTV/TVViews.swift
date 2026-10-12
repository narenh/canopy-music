import CanopyCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct TVRootView: View {
    @Environment(TVModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let current = model.session.state.current
        ZStack {
            TVBackground(track: current?.track, theme: ArtworkTheme(current?.track.colors))
            switch model.role {
            case .choosing:
                TVZoneListView()
                    .transition(.opacity)
            case .hub:
                if model.hostJoined {
                    TVPartyView().transition(.opacity)
                } else {
                    TVStartView().transition(.opacity)
                }
            case .display:
                TVPartyView()
                    // Blurred behind the connection message so it reads.
                    .blur(radius: model.isWaitingForHub ? 28 : 0)
                    .overlay { TVConnectionOverlay() }
                    .animation(.easeInOut(duration: 0.4), value: model.isWaitingForHub)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: current?.id)
        .animation(.easeInOut(duration: 0.5), value: model.role)
        .onChange(of: current?.id) { model.advertise() }
        // Menu: a hub can only stop its zone, a display can only leave (no settings on the TV).
        .onExitCommand(perform: model.role == .choosing ? nil : { confirming = true })
        .onPlayPauseCommand(perform: model.role == .choosing ? nil : { model.playPause() })
        .alert(menuTitle, isPresented: $confirming) {
            if model.role == .hub {
                Button("Stop \(model.zoneName)", role: .destructive) { model.stopZone() }
            } else {
                Button("Leave \(model.shownZone?.name ?? "zone")", role: .destructive) { model.leave() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.role == .hub
                 ? "This TV is playing the music. Settings are on your phone's host page."
                 : "Showing \(model.shownZone?.kind == .tv ? "another Apple TV's" : "an iPad's") zone.")
        }
    }

    private var menuTitle: String {
        model.role == .hub ? model.zoneName : (model.shownZone?.name ?? "Zone")
    }
}

// MARK: - Zone list

/// Every launch starts here (docs/multi-device.md).
struct TVZoneListView: View {
    @Environment(TVModel.self) private var model
    /// A zone's id, or "create".
    @FocusState private var focused: String?

    var body: some View {
        let zones = model.browser.zones.filter { $0.hubID != model.deviceID }
        VStack(spacing: 34) {
            Image("CanopyLogo").resizable().scaledToFit().frame(height: 70)
            VStack(spacing: 16) {
                ForEach(zones) { zone in
                    Button {
                        model.show(zone)
                    } label: {
                        TVZoneRow(
                            icon: zone.kind == .tv ? "appletv" : "ipad.landscape",
                            title: "Show \(zone.name)",
                            subtitle: [zone.kind == .tv ? "Apple TV" : "iPad", zone.nowPlaying.map { "playing \($0)" }]
                                .compactMap(\.self).joined(separator: " · ")
                        )
                    }
                    .focused($focused, equals: zone.id)
                }
                Button {
                    Task { await model.createZone() }
                } label: {
                    TVZoneRow(icon: "plus", title: "Create a new zone", subtitle: "This TV plays the music")
                }
                .focused($focused, equals: "create")
            }
            .frame(width: 900)
            if model.authorizationDenied {
                Text("Canopy Music needs Apple Music access to play here. Turn it on in Settings › Apps › Canopy Music.")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                    .frame(width: 900)
            }
        }
        // No forced white here: a focused button turns light and needs its dark text.
        .onAppear { model.browser.start() }
        // Joining is the usual case (a second zone in one house is rare), so start on the first
        // zone. Zones turn up a moment after launch, when focus is already on Create.
        .defaultFocus($focused, zones.first?.id ?? "create")
        .onChange(of: zones.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty, focused == "create" || focused == nil { focused = zones.first?.id }
        }
        #if DEBUG
        // `-createZone` / `-showZone <name>`: act without the remote, for the simulator.
        .task {
            if ProcessInfo.processInfo.arguments.contains("-createZone") { await model.createZone() }
        }
        .onChange(of: zones.map(\.id), initial: true) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-showZone"), i + 1 < args.count,
                  let zone = zones.first(where: { $0.name == args[i + 1] }) else { return }
            model.show(zone)
        }
        #endif
    }
}

private struct TVZoneRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 32, weight: .semibold))
                Text(subtitle).font(.system(size: 22)).opacity(0.65).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Which zone a display is showing.
struct TVZoneBadge: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        if let zone = model.shownZone {
            // Plain text, not a capsule, so it can't be mistaken for a requester pill.
            HStack(spacing: 12) {
                Image(systemName: zone.kind == .tv ? "appletv.fill" : "ipad.landscape")
                    .font(.system(size: 22, weight: .medium))
                Text("Playing from \(zone.name)")
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// "Connecting…" until the hub's first update; "Lost connection" if it drops.
struct TVConnectionOverlay: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        if let connection = model.connection, model.isWaitingForHub {
            let name = model.shownZone?.name ?? "the zone"
            ZStack {
                Rectangle().fill(.black.opacity(connection.hasSnapshot ? 0.45 : 0.9)).ignoresSafeArea()
                VStack(spacing: 22) {
                    ProgressView()
                    Text(connection.hasSnapshot ? "Lost connection to \(name)" : "Connecting to \(name)…")
                        .font(.system(size: 40, weight: .bold))
                    if connection.hasSnapshot {
                        Text("Reconnecting. Make sure \(model.shownZone?.kind == .tv ? "the Apple TV is on" : "the iPad is awake") and Canopy Music is open.\nPress Menu to leave.")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .frame(width: 1000)
                    }
                }
                .foregroundStyle(.white)
            }
        }
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
                Text("Your phone becomes the remote: pick a playlist, play, pause, skip and reorder. iPads with Canopy Music on this Wi\u{2011}Fi can show this zone too.")
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
    /// Height of everything in the now-playing column under the artwork, which takes the rest.
    @State private var footerHeight: CGFloat = 200
    /// The logo's visible top and left margin from the screen edges, level with the capitals in
    /// "Up next". The image has 6.5pt of empty space above the arc and 1pt to its left.
    static let logoInset: CGFloat = 71

    var body: some View {
        let session = model.session
        let current = session.state.current
        GeometryReader { geo in
            // As big as fits, up to a size that leaves room around the corner logo.
            let art = min(600, max(300, (geo.size.height - footerHeight).rounded(.down)))
            HStack(alignment: .top, spacing: 70) {
                // Now playing.
                VStack(alignment: .leading, spacing: 0) {
                    TVArtwork(track: current?.track, cornerRadius: 22)
                        .frame(width: art, height: art)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        // Long titles shrink before they truncate, on the same baseline in a
                        // full-size line, so the art's size and everything's position never change.
                        Text(verbatim: " ")
                            .font(.system(size: 56, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hidden()
                            .overlay(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {
                                Text(current?.track.title ?? "Nothing playing")
                                    .font(.system(size: 56, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        // Who requested it shares the artist line, as on the iPad.
                        HStack(spacing: 16) {
                            Text(current?.track.artist ?? " ")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                            if let requester = current?.requester {
                                TVRequesterPill(requester: requester).fixedSize()
                            }
                        }
                        .padding(.bottom, 26)
                        TVProgress(session: session)
                        if model.role == .display {
                            TVZoneBadge().padding(.top, 24)
                        }
                    }
                    .padding(.top, 34)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0 }
                }
                .frame(width: art, alignment: .leading)
                // Centered in whatever the sidebar leaves.
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                        .animation(.easeInOut(duration: 0.4), value: session.state.upNext.map(\.id))
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
                .frame(width: 660)
                .padding(.leading, 56)
                .frame(maxHeight: .infinity)
                // A sidebar running off the top, bottom and right edges.
                .background {
                    Color.black.opacity(0.22).ignoresSafeArea(edges: [.top, .bottom, .trailing])
                }
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            Image("CanopyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 46)
                .padding(.top, Self.logoInset - 6.5)
                .padding(.leading, Self.logoInset - 1)
                .ignoresSafeArea()
        }
    }
}

struct TVQueueRow: View {
    let item: QueueItem
    static let height: CGFloat = 70

    var body: some View {
        HStack(spacing: 18) {
            TVArtwork(track: item.track, cornerRadius: 8)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(.system(size: 26, weight: .medium))
                Text(item.track.artist)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            if let requester = item.requester {
                TVRequesterPill(requester: requester)
            }
        }
        .frame(height: Self.height)
    }
}

/// Who requested a song (the iPad's RequesterPill at TV size).
struct TVRequesterPill: View {
    let requester: Requester

    var body: some View {
        HStack(spacing: 7) {
            if requester.origin == .phone {
                Image(systemName: "iphone").font(.system(size: 16, weight: .semibold))
            }
            Text(requester.name ?? (requester.origin == .phone ? "Guest" : "iPad"))
                .lineLimit(1)
        }
        .font(.system(size: 19, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .foregroundStyle(.white.opacity(0.8))
        .background(.white.opacity(0.16), in: Capsule())
    }
}

struct TVJoinCard: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 24) {
            TVQRCode(payload: model.shownGuestURL?.absoluteString)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text("Queue from your phone")
                    .font(.system(size: 30, weight: .bold))
                Text("Scan with your camera, or go to")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                Text(Self.display(model.shownFriendlyURL ?? model.shownGuestURL))
                    .font(.system(size: 25, weight: .semibold).monospaced())
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let wifi = model.wifiPayload {
                // Same as the iPad's: the Wi‑Fi symbol says what it is.
                HalftoneQRCode(payload: wifi, symbol: "wifi", symbolScale: 0.6, dotScale: 0.7)
                    .frame(width: 88, height: 88)
                    .opacity(0.75)
            }
        }
        .padding(22)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
}

struct TVProgress: View {
    let session: PartySession

    var body: some View {
        // Every frame while playing so the bar grows smoothly (a seek just jumps); twice a second
        // while paused, to catch seeks.
        TimelineView(.animation(minimumInterval: session.isPlaying ? nil : 0.5)) { _ in
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
            // In an overlay so a filled image can't grow the view past the size it's given.
            Color.clear.overlay {
                if let url = track?.artworkURL ?? track?.thumbnailURL {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
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
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
            if let payload, let image = Self.render(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
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
