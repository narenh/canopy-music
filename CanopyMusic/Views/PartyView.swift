import CanopyCore
import SwiftUI

/// The locked guest screen: now playing + search on the left, Up Next + phone QR on the right.
struct PartyView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [QueueTrack] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    @FocusState private var searchFocused: Bool
    @State private var searchIdleTask: Task<Void, Never>?
    @State private var listHomeSignal = 0
    /// Height of the on-screen keyboard. With a hardware keyboard iPadOS still reports a short
    /// shortcut bar, which doesn't squeeze the layout.
    @State private var keyboardHeight: CGFloat = 0
    private var softwareKeyboardShown: Bool { keyboardHeight > 150 }

    @State private var flights: [Flight] = []
    @State private var arriving: Set<UUID> = []
    @State private var flashing: Set<UUID> = []
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var listFrame: CGRect = .zero
    @State private var scrollTarget: UUID?

    @State private var toast: Announcement?
    @State private var toastTask: Task<Void, Never>?
    @State private var showUnlock = false
    @State private var showLeave = false

    /// What the search field says it searches: the hub's service on a display.
    private var searchServiceName: String {
        if model.isDisplay { return model.session.serviceName ?? "songs" }
        return model.isDemo ? "demo songs" : model.provider.title
    }
    /// Debug only: a search result to tap Add on automatically (see `-autoSearch`).
    @State private var autoAddTrackID: String?

    private var session: PartySession { model.session }
    private var current: QueueItem? { session.state.current }
    private var searchActive: Bool { searchFocused || !query.isEmpty }

    var body: some View {
        let theme = ArtworkTheme(current?.track.colors)
        GeometryReader { geo in
            HStack(spacing: 0) {
                leftPane
                    .frame(width: geo.size.width * 0.54)
                rightPane
                    .padding(.vertical, 24)
                    .padding(.trailing, 24)
            }
        }
        .background { ThemedBackground(track: current?.track, theme: theme) }
        .overlay { FlightLayer(flights: flights, destinations: rowFrames, fallback: fallbackDestination) }
        .environment(\.artworkTheme, theme)
        .animation(.easeInOut(duration: 1.2), value: theme)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: query) { await search() }
        .onChange(of: query) { noteSearchActivity() }
        .onChange(of: searchFocused) { noteSearchActivity() }
        .onChange(of: searchActive) { _, active in
            if !active { listHomeSignal += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return }
            keyboardHeight = max(0, screen.bounds.maxY - frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onChange(of: session.state.upNext.map(\.id)) { old, new in flashPhoneRequests(old: old, new: new) }
        .sheet(isPresented: $showUnlock) { UnlockView() }
        .confirmationDialog(model.displayedZone?.name ?? "Zone", isPresented: $showLeave, titleVisibility: .visible) {
            Button("Leave \(model.displayedZone?.name ?? "zone")", role: .destructive) { model.leaveZone() }
        } message: {
            Text("Showing \(model.displayedZone?.kind == .tv ? "the Apple TV's" : "an iPad's") zone. Music plays there.")
        }
        .overlay { DisplayConnectionOverlay() }
        #if DEBUG
        .task { await runAutoSearch() }
        #endif
    }

    // MARK: Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                LogoView(height: 34)
                    .onLongPressGesture(minimumDuration: 1.5) {
                        // A display has no host mode; it can only leave the zone.
                        if model.isDisplay { showLeave = true; return }
                        // No PIN set: go straight back to host mode, no keypad.
                        if model.hostPIN.isEmpty { _ = model.unlock(pin: "") } else { showUnlock = true }
                    }
                searchField
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 12)

            ZStack {
                NowPlayingView(item: current, session: session)
                    .opacity(searchActive ? 0 : 1)
                    .scaleEffect(searchActive ? 0.96 : 1)
                if searchActive {
                    SearchResultsView(
                        results: results, isLoading: isSearching, message: searchMessage,
                        status: status(for:), autoAddTrackID: autoAddTrackID, onAdd: add,
                        onInteraction: noteSearchActivity
                    )
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.spring(duration: 0.35), value: searchActive)
        }
    }

    /// While searching, the field shrinks and Done sits beside it, leaving room for a clear button.
    private var searchField: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    TextField("", text: $query, prompt: Text("Search \(searchServiceName) to add a song").foregroundStyle(.white.opacity(0.5)))
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .transition(.opacity)
                    }
                }
                .padding(.leading, 22)
                .padding(.trailing, 18)
                .frame(height: 64)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = true }

                if searchActive {
                    Button(action: closeSearch) {
                        Text("Done")
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glass)
                    .tint(.primary)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.35), value: searchActive)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
    }

    // MARK: Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up next")
                    .font(.system(size: 26, weight: .bold))
                Spacer()
                // Announcements briefly take over the hint, then it fades back.
                Group {
                    if let toast {
                        Text(toast.styled)
                            .foregroundStyle(.white.opacity(0.85))
                    } else if !model.isDisplay || model.session.phonesCanReorder {
                        Text("Drag to reorder")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .lineLimit(1)
                .id(toast?.id ?? "hint")
                .transition(.opacity)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Songs added on the iPad can be removed here (e.g. added by mistake). Phone requests
            // can only be removed from the phone that added them.
            UpNextList(
                session: session, canRemoveByMenu: { !model.isDisplay && $0.requester?.origin == .ipad },
                canReorder: !model.isDisplay || session.phonesCanReorder,
                arriving: arriving, flashing: flashing, scrollTarget: $scrollTarget,
                onArtworkFrame: { id, frame in rowFrames[id] = frame },
                showsHistory: true,
                homeSignal: listHomeSignal
            )
            .reportFrame { listFrame = $0 }

            // The on-screen keyboard squeezes this pane; give the space to the queue instead.
            if model.showsGuestQR, !softwareKeyboardShown {
                GuestQRCard()
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: softwareKeyboardShown)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    // MARK: Adding

    private func status(for track: QueueTrack) -> AddStatus {
        if current?.track.id == track.id { return .playing }
        if session.state.upNext.contains(where: { $0.isRequest && $0.track.id == track.id }) { return .queued }
        return .add
    }

    // MARK: Search idle

    /// Restarts the countdown that closes an abandoned search.
    private func noteSearchActivity() {
        searchIdleTask?.cancel()
        searchIdleTask = nil
        guard searchActive else { return }
        searchIdleTask = Task {
            try? await Task.sleep(for: Idle.timeout)
            guard !Task.isCancelled else { return }
            closeSearch()
        }
    }

    private func closeSearch() {
        searchIdleTask?.cancel()
        searchIdleTask = nil
        query = ""
        results = []
        searchFocused = false
    }

    private func add(_ track: QueueTrack, from frame: CGRect) {
        noteSearchActivity()
        let result = withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            session.add(track, by: Requester(origin: .ipad))
        }
        switch result {
        case .added(let item, let index):
            scrollTarget = item.id
            guard frame != .zero else { flash(item.id); return }
            arriving.insert(item.id)
            flights.append(Flight(id: item.id, track: track, from: frame))
            Task {
                // Give the new row a beat to lay out (and the list to start scrolling) before takeoff.
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.timingCurve(0.35, 0, 0.15, 1, duration: 0.8)) {
                    if let i = flights.firstIndex(where: { $0.id == item.id }) { flights[i].progress = 1 }
                } completion: {
                    arriving.remove(item.id)
                    flights.removeAll { $0.id == item.id }
                    flash(item.id)
                }
            }
        case .alreadyQueued(let item, let index):
            showToast(Announcement(lead: "Already queued · #\(index + 1) in line"))
            scrollTarget = nil
            scrollTarget = item.id
            flash(item.id)
        case .nowPlaying:
            showToast(Announcement(lead: "That's playing right now"))
        }
    }

    private var fallbackDestination: CGRect {
        guard listFrame != .zero else { return CGRect(x: 0, y: 0, width: 52, height: 52) }
        return CGRect(x: listFrame.minX + 12, y: listFrame.minY + 12, width: 52, height: 52)
    }

    private func flash(_ id: UUID) {
        flashing.insert(id)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 1.6)) { _ = flashing.remove(id) }
        }
    }

    private func flashPhoneRequests(old: [UUID], new: [UUID]) {
        let added = Set(new).subtracting(old)
        for item in session.state.upNext where added.contains(item.id) && item.requester?.origin == .phone {
            flash(item.id)
            if let name = item.requester?.name {
                showToast(Announcement(lead: "\(name) added", title: item.track.title))
            } else {
                showToast(Announcement(lead: "Someone added", title: item.track.title))
            }
        }
    }

    // MARK: Search

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            searchMessage = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await session.catalog.searchSongs(term)
            guard !Task.isCancelled else { return }
            results = found
            searchMessage = found.isEmpty ? "No songs found for “\(term)”." : nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchMessage = "Search isn't working right now. Try again in a moment."
        }
    }

    #if DEBUG
    /// `-autoSearch <term>`: types a search and adds the first result, to exercise the flight animation.
    private func runAutoSearch() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-autoSearch"), i + 1 < args.count else { return }
        try? await Task.sleep(for: .seconds(1.5))
        query = args[i + 1]
        try? await Task.sleep(for: .seconds(1.5))
        autoAddTrackID = results.first { status(for: $0) == .add }?.id
    }
    #endif

    // MARK: Chrome

    /// A short message shown in place of the Up next hint: "Naren added" + "Big Stick".
    struct Announcement: Equatable {
        var lead: String
        var title: String?
        var id: String { lead + (title ?? "") }

        /// "Naren added" in medium, the song title in semibold.
        var styled: AttributedString {
            var text = AttributedString(lead)
            text.font = .system(size: 14, weight: .medium)
            if let title {
                var part = AttributedString(" " + title)
                part.font = .system(size: 14, weight: .semibold)
                text += part
            }
            return text
        }
    }

    /// Shows `text` in place of the Up next hint for a moment.
    private func showToast(_ text: Announcement) {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) { toast = nil }
        }
    }
}

// MARK: - Now playing

struct NowPlayingView: View {
    let item: QueueItem?
    let session: PartySession
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            // Artwork takes whatever height is left after the title, progress and controls.
            let reserved: CGFloat = item == nil ? 110 : 284
            let side = max(200, min(geo.size.width * 0.85, geo.size.height - reserved))
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                ArtworkView(track: item?.track, large: true, cornerRadius: 18)
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                    .id(item?.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if item != nil {
                            EqualizerBars(isAnimating: session.isPlaying)
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                        }
                        Text(item?.track.title ?? "Nothing playing yet")
                            .font(.system(size: 36, weight: .bold))
                    }
                    // The requester badge shares the artist line so it never adds height.
                    HStack(spacing: 10) {
                        Text(item?.track.artist ?? "Search for a song to get things going")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                        if let requester = item?.requester {
                            RequesterPill(requester: requester)
                        }
                    }
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: side + 120)
                if let item {
                    // While disconnected the bar means nothing; say why the controls are off instead.
                    ProgressBar(duration: item.track.duration, session: session)
                        .frame(width: side)
                        .opacity(model.spotifyDisconnected ? 0 : 1)
                        .allowsHitTesting(!model.spotifyDisconnected && (!model.isDisplay || session.displaysCanControl))
                        .overlay {
                            if model.spotifyDisconnected {
                                Label("Playback device disconnected", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                    // Displays: transport only while the hub allows it (no AirPlay or crossfade).
                    if !model.isDisplay || session.displaysCanControl {
                        TransportControls(session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.6, bounce: 0.15), value: item?.id)
        }
        .padding(.horizontal, 32)
        // Bottom-aligned so the controls line up with the Up next panel's bottom edge
        // (the right pane's 24 pt vertical padding).
        .padding(.bottom, Self.bottomInset)
    }

    static let bottomInset: CGFloat = 24
}

private struct TransportControls: View {
    let session: PartySession
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 20) {
                if model.isDisplay {
                    // Speakers are chosen on the hub; keep the controls centered.
                    Color.clear.frame(width: 44, height: 44)
                } else {
                // Open AirPlay picker: AirPlay sessions sometimes drop and need re-picking.
                // Disabled (but kept for balance) when Spotify plays on another device.
                if airPlayApplies {
                    RoutePicker(tint: .white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Choose speakers")
                } else {
                    // The AirPlay control ignores SwiftUI's disabled/opacity, so show a plain
                    // dimmed icon instead (kept for balance).
                    Image(systemName: "airplay.audio")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                        .accessibilityLabel("Speakers")
                        .accessibilityValue("Not used: music plays on \(model.spotifyDeviceName ?? "another device")")
                }
                }
                Group {
                    Button {
                        Task { await session.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Previous")
                    Button {
                        Task { session.isPlaying ? session.pause() : await model.play() }
                    } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                    Button {
                        Task { await session.skip() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Skip")
                }
                .buttonStyle(.glass)
                .tint(.primary)
                .buttonBorderShape(.circle)
                .disabled(model.spotifyDisconnected)
                .opacity(model.spotifyDisconnected ? 0.35 : 1)
                if model.isDisplay {
                    Color.clear.frame(width: 44, height: 44)
                } else if model.provider == .spotify {
                    // Spotify's crossfade lives in the Spotify app; this spot picks where music plays.
                    SpotifyDeviceButton()
                } else {
                Button {
                    model.crossfade.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                        Circle()
                            .frame(width: 4, height: 4)
                            .opacity(model.crossfade ? 1 : 0)
                    }
                    .frame(width: 44, height: 44)
                    .offset(y: 2)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Crossfade")
                .accessibilityValue(model.crossfade ? "On" : "Off")
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var airPlayApplies: Bool { model.provider != .spotify || model.spotifyPlaysOnThisIPad }
}

/// Four bars bouncing at different rates; they settle low when paused.
struct EqualizerBars: View {
    let isAnimating: Bool
    private let speeds: [Double] = [5.1, 7.3, 4.2, 6.4]
    private let phases: [Double] = [0, 1.7, 3.1, 0.8]

    var body: some View {
        TimelineView(.animation(paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: geo.size.width * 0.12) {
                    ForEach(speeds.indices, id: \.self) { i in
                        let wave = (sin(t * speeds[i] + phases[i]) + 1) / 2
                        let level = isAnimating ? 0.25 + 0.75 * wave : 0.25
                        Capsule()
                            .frame(height: max(2, geo.size.height * level))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ProgressBar: View {
    let duration: TimeInterval?
    let session: PartySession

    /// Where the finger is while scrubbing (0...1); nil when not dragging.
    @State private var scrub: Double?
    /// Drives the bar thickening, animated separately from the per-frame scrub position.
    @State private var isScrubbing = false

    var body: some View {
        // Every frame while playing so the bar grows smoothly (a seek just jumps); twice a second
        // while paused, to catch seeks.
        TimelineView(.animation(minimumInterval: session.isPlaying ? nil : 0.5)) { _ in
            let total = max(duration ?? 0, 1)
            let elapsed = scrub.map { $0 * total } ?? session.engine.currentTime
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white).frame(width: geo.size.width * min(elapsed / total, 1))
                    }
                    .frame(height: isScrubbing ? 12 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                                // After updating `scrub`: the last change in the update decides
                                // whether it animates.
                                if !isScrubbing {
                                    withAnimation(.spring(duration: 0.3, bounce: 0.3)) { isScrubbing = true }
                                }
                            }
                            .onEnded { _ in
                                if let scrub { session.seek(to: scrub * total) }
                                scrub = nil
                                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { isScrubbing = false }
                            }
                    )
                }
                .frame(height: 28)
                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(max(total - elapsed, 0)))
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(isScrubbing ? 0.9 : 0.5))
            }
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Self.format(elapsed)) of \(Self.format(total))")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 10 : -10
                session.seek(to: min(max(session.engine.currentTime + step, 0), total))
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - QR card

struct GuestQRCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            if let url = model.guestURL {
                qr(url.absoluteString)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queue from your phone")
                        .font(.system(size: 19, weight: .bold))
                    Text("Scan with your camera, or go to")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(Self.display(model.friendlyURL ?? url))
                        .font(.system(size: 16, weight: .semibold).monospaced())
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let wifi = model.wifiJoinPayload {
                    if model.wifiSimpleQR {
                        VStack(spacing: 4) {
                            QRCodeView(payload: wifi, inverted: true)
                                .frame(width: 64, height: 64)
                                .opacity(0.75)
                            Text("Join Wi\u{2011}Fi")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        // The Wi‑Fi symbol says what it is, so no caption; it takes the caption's room.
                        HalftoneQRCode(payload: wifi, symbol: "wifi", symbolScale: 0.6, dotScale: 0.7)
                            .frame(width: 80, height: 80)
                            .opacity(0.75)
                            .accessibilityLabel("Join Wi\u{2011}Fi QR code")
                    }
                }
            } else {
                Label("Phone queueing is off. Connect the iPad to Wi\u{2011}Fi.", systemImage: "wifi.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func qr(_ payload: String, size: CGFloat = 108) -> some View {
        QRCodeView(payload: payload)
            .padding(8)
            .frame(width: size, height: size)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func display(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
}

/// On a display: "Connecting…" until the hub's first update, "Lost connection" if it drops.
private struct DisplayConnectionOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isDisplay, let connection = model.displayConnection, !connection.isConnected {
            let name = model.displayedZone?.name ?? "the zone"
            ZStack {
                Rectangle().fill(.black.opacity(connection.hasSnapshot ? 0.55 : 0.85))
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(connection.hasSnapshot ? "Lost connection to \(name)" : "Connecting to \(name)…")
                        .font(.system(size: 22, weight: .bold))
                    if connection.hasSnapshot {
                        Text("Reconnecting. Make sure \(model.displayedZone?.kind == .tv ? "the Apple TV is on" : "the iPad is awake") and Canopy is open.")
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    Button("Leave \(name)") { model.leaveZone() }
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .padding(.top, 6)
                }
                .padding(28)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .foregroundStyle(.white)
            }
            .transition(.opacity)
        }
    }
}
