import CanopyMusicCore
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
    /// Now Playing's song change (`NowPlayingView`); the background changes evenly from the
    /// moment its slide starts, settling after it, as on the TV.
    @State private var slider = SongSlider()

    /// What the search field says it searches: the hub's service on a display.
    private var searchServiceName: String {
        if model.isDisplay { return model.session.serviceName ?? "songs" }
        return model.isDemo ? "demo songs" : model.provider.title
    }
    /// Debug only: a search result to tap Add on automatically (see `-autoSearch`).
    @State private var autoAddTrackID: String?

    private var session: PartySession { model.session }
    private var searchActive: Bool { searchFocused || !query.isEmpty }

    var body: some View {
        // What's playing (in a Spotify zone it can be a track from outside the queue,
        // `PartySession.externalCurrent`), once it has slid in.
        let shown = slider.current(in: session)
        let theme = ArtworkTheme(shown?.track.colors)
        ContentCap {
            GeometryReader { geo in
                // Within the Mac cap (ContentCap), windows wider than 16:10 (short Mac windows) keep
                // the columns together in the middle, and Up next stops growing past its width on a
                // 13" iPad; Now Playing takes the rest. Measured against the height without the
                // on-screen keyboard: it shortens this view, and would squeeze everything into a
                // narrow column while searching.
                let fullHeight = geo.size.height + (softwareKeyboardShown ? keyboardHeight : 0)
                let width = min(geo.size.width, fullHeight * 1.6)
                let right = min(width * 0.46, 640)
                HStack(spacing: 0) {
                    leftPane
                        .frame(width: width - right)
                    // Narrower than on an 11" iPad in landscape, the QR card stacks its codes.
                    rightPane(compactQR: right < 540)
                        .padding(.vertical, 24)
                        .padding(.trailing, 24)
                }
                .frame(width: width)
                .frame(maxWidth: .infinity)
            }
        }
        .background { ThemedBackground(track: shown?.track, theme: theme) }
        .overlay { FlightLayer(flights: flights, destinations: rowFrames, fallback: fallbackDestination) }
        .environment(\.artworkTheme, theme)
        // The song's colours change with the background, over the same 2 s.
        .animation(.linear(duration: 2), value: theme)
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
        .sheet(isPresented: $showUnlock) { UnlockView().environment(model) }
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
                        // A display has no host mode: it leaves the zone (nothing is lost, so no
                        // confirmation; the zone carries on on its hub).
                        if model.isDisplay { model.leaveZone(); return }
                        // No PIN set: go straight back to host mode, no keypad.
                        if model.hostPIN.isEmpty { _ = model.unlock(pin: "") } else { showUnlock = true }
                    }
                searchField
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 12)

            ZStack {
                NowPlayingView(session: session, slider: slider)
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

    private func rightPane(compactQR: Bool) -> some View {
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

            // Songs that couldn't play were skipped, or (Spotify) the next song couldn't be queued.
            if let issue = session.playerIssue {
                PlayerIssueLine(text: issue)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

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
                GuestQRCard(compact: compactQR)
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: softwareKeyboardShown)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    // MARK: Adding

    private func status(for track: QueueTrack) -> AddStatus {
        if session.state.current?.track.id == track.id { return .playing }
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
            // Unnamed songs added here show as "iPad" everywhere; a Mac names itself instead.
            session.add(track, by: Requester(name: DeviceKind.isMac ? DeviceKind.noun : nil, origin: .ipad))
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
    let session: PartySession
    /// The song change: the art, text and progress slide to the next song's, as on the Apple TV;
    /// the controls below stay where they are. `PartyView`'s, so the background goes with it.
    let slider: SongSlider
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    /// The song shown: the one playing, once it has slid in.
    private var item: QueueItem? { slider.current(in: session) }

    var body: some View {
        GeometryReader { geo in
            // The controls are 400 pt wide at their usual spacing. Narrower columns (an iPad mini
            // in portrait) get slimmer margins and closer controls.
            let narrow = geo.size.width < 464
            let inset: CGFloat = narrow ? 20 : 32
            let width = geo.size.width - inset * 2
            let widthSide = width * 0.85
            let side = max(200, min(widthSide, geo.size.height - reserved))
            // Always in the middle of the column's height, whatever the window's shape.
            VStack(spacing: Self.spacing) {
                SongPages(
                    slider: slider, session: session, columnWidth: geo.size.width,
                    artBucket: ArtworkSizing.bucket(points: Double(side), scale: Double(displayScale))
                ) { item in
                    page(item, side: side, width: width)
                }
                .frame(maxWidth: .infinity)
                // The slide shows from the screen's left edge to the edge of Up next. Only the
                // pages: under a mask the AirPlay button (a UIKit view) can't keep its popover open.
                .mask {
                    Rectangle()
                        .padding(.leading, -2000)
                        .padding(.trailing, -inset)
                        .padding(.vertical, -300)
                }
                if item != nil {
                    if model.isDisplay { DisplayZoneLine().frame(maxWidth: side) }
                    // Displays: transport only while the hub allows it (no AirPlay or crossfade).
                    if showsTransport {
                        TransportControls(session: session, spacing: narrow ? 6 : 20)
                    }
                } else {
                    if model.isDisplay { DisplayZoneLine().frame(maxWidth: side) }
                    if startsUpNext {
                        // Nothing current but songs waiting (the queue ran dry, then a guest added
                        // one): Play starts Up next, so the party is never stuck.
                        StartUpNextButton()
                    }
                }
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The slide's timing, not the background's 2 s (`PartyView`), which changes with it;
            // also for what moves with the song (the controls arriving with the first one).
            .animation(SongSlider.animation, value: item?.id)
        }
        // The right pane's 24 pt vertical padding, so a column that's full stops where Up next does.
        .padding(.bottom, 24)
    }

    /// The song's art, title, artist line and progress: one page of the slide.
    private func page(_ item: QueueItem?, side: CGFloat, width: CGFloat) -> some View {
        // Only the song playing has its video playing; the page going out stops its own (easing
        // to a stop as it leaves), and the one coming in starts its video once it's in place.
        let live = item != nil && item?.id == session.nowPlaying?.id
        return VStack(spacing: Self.spacing) {
            ArtworkView(track: item?.track, large: true, cornerRadius: 18)
                // Animated album artwork, where there is some (experimental: `MotionArtwork`).
                .overlay {
                    MotionArtworkView(
                        track: item?.track, catalog: session.catalog, isPlaying: session.isPlaying && live,
                        waits: !live || slider.isSliding, cornerRadius: 18
                    )
                }
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
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
                    Text(item?.track.artist ?? (startsUpNext ? "Press play to start Up next" : "Search for a song to get things going"))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    if let requester = item?.requester {
                        RequesterPill(requester: requester)
                    } else if let item, item.id == session.externalCurrent?.id {
                        // Not from this queue: someone else on the Spotify account chose it.
                        FromServiceLabel(service: session.serviceName)
                    }
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(maxWidth: min(side + 120, width))
            if let item {
                // While disconnected the bar means nothing; say why the controls are off instead.
                ProgressBar(itemID: item.id, duration: item.track.duration, session: session)
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
            }
        }
    }

    /// Between the artwork, the song's text, the progress bar, the zone line and the controls.
    private static let spacing: CGFloat = 20
    /// The play/pause row's height: its 64 pt glass buttons, with the glass around them.
    private static let transportHeight: CGFloat = 78

    /// The column's height that isn't artwork: the song's text, then the progress bar and the
    /// controls (or the lone Play), then on a display the zone line, each with the spacing above
    /// it. The artwork gets the rest, so it shrinks to make room where the column is short (a
    /// small or short window, an 11" iPad in landscape). The hub's numbers (284, 194 and 110)
    /// include some breathing room below the controls.
    private var reserved: CGFloat {
        var height: CGFloat = item != nil ? 284 : startsUpNext ? 194 : 110
        // A display the hub doesn't let control has no transport row.
        if item != nil, !showsTransport { height -= Self.transportHeight + Self.spacing }
        if model.isDisplay { height += DisplayZoneLine.height + Self.spacing }
        return height
    }

    /// Displays get play/pause, skip and scrubbing only while the hub allows it.
    private var showsTransport: Bool { !model.isDisplay || session.displaysCanControl }

    /// Nothing playing but Up next has songs: a lone Play button starts it.
    private var startsUpNext: Bool { item == nil && showsTransport && !session.state.upNext.isEmpty }
}

/// Play, alone, for when nothing is current but Up next has songs: plays its first song.
private struct StartUpNextButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.play() }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.glass)
        .tint(.primary)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .disabled(model.spotifyDisconnected)
        .opacity(model.spotifyDisconnected ? 0.35 : 1)
        .accessibilityLabel("Play")
    }
}

private struct TransportControls: View {
    let session: PartySession
    var spacing: CGFloat = 20
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                if model.isDisplay {
                    // Speakers are chosen on the hub; keep the controls centered.
                    Color.clear.frame(width: 44, height: 44)
                } else if model.usesSonos {
                    // Sonos rooms play the music: their own panel, in AirPlay's place.
                    SonosSpeakersButton()
                } else {
                // Open AirPlay picker: AirPlay sessions sometimes drop and need re-picking.
                // Disabled (but kept for balance) when Spotify plays on another device, or on a Mac.
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
                        .accessibilityValue(DeviceKind.isMac ? "Not available on a Mac" : "Not used: music plays on \(model.spotifyDeviceName ?? "another device")")
                        .help(DeviceKind.isMac ? AirPlayRow.macNote : "")
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
                } else if model.provider == .spotify, !model.usesSonos {
                    // Spotify's crossfade lives in the Spotify app; this spot picks where music plays.
                    // (On Sonos, it's Sonos's crossfade, as for Apple Music.)
                    SpotifyDeviceButton()
                } else {
                Button {
                    model.crossfade.toggle()
                } label: {
                    VStack(spacing: 3) {
                        // At 20, its strokes (1.8) are as thick as the 15-point semibold
                        // symbol it replaced, and it's as big to the eye.
                        CrossfadeGlyph()
                            .frame(width: 20, height: 20)
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

    /// Not on a Mac, where the music ignores the app's AirPlay choice (`AirPlayRow.macNote`).
    private var airPlayApplies: Bool {
        !DeviceKind.isMac && !model.usesSonos && (model.provider != .spotify || model.spotifyPlaysOnThisDevice)
    }
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
    /// The page's song, which can still be the last one while it slides out (the engine has
    /// moved on): its bar holds where it was (`HeldSongTime`).
    let itemID: QueueItem.ID
    let duration: TimeInterval?
    let session: PartySession
    @State private var held = HeldSongTime()

    /// Where the finger is while scrubbing (0...1); nil when not dragging.
    @State private var scrub: Double?
    /// Drives the bar thickening, animated separately from the per-frame scrub position.
    @State private var isScrubbing = false

    var body: some View {
        // Every frame while playing so the bar grows smoothly (a seek just jumps); twice a second
        // while paused, to catch seeks.
        TimelineView(.animation(minimumInterval: session.isPlaying ? nil : 0.5)) { _ in
            let total = max(duration ?? 0, 1)
            let live = itemID == session.nowPlaying?.id
            let elapsed = scrub.map { $0 * total } ?? held.show(live ? session.position : nil)
            let thickness: CGFloat = isScrubbing ? 12 : 5
            // Never narrower than a circle (a thinner capsule squashes into a sliver): at 0:00
            // there's none, and from the first moment past it a dot, which grows. At once, not
            // with the scrubbing's spring.
            let started = duration != nil && elapsed > 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white)
                            .frame(width: max(geo.size.width * min(elapsed / total, 1), thickness))
                            .opacity(started ? 1 : 0)
                            .animation(nil, value: started)
                    }
                    .frame(height: thickness)
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
                session.seek(to: min(max(session.position + step, 0), total))
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
    /// Too narrow for both codes side by side (portrait, small windows): the Wi‑Fi code goes
    /// below the phone code, so the text keeps its room.
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            if let url = model.guestURL {
                if compact {
                    VStack(spacing: 14) {
                        qr(url.absoluteString)
                        if let wifi = model.wifiJoinPayload { wifiQR(wifi) }
                    }
                } else {
                    qr(url.absoluteString)
                }
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
                if !compact, let wifi = model.wifiJoinPayload { wifiQR(wifi) }
            } else {
                Label("Phone queueing is off. Connect the \(DeviceKind.noun) to Wi\u{2011}Fi.", systemImage: "wifi.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private func wifiQR(_ wifi: String) -> some View {
        if model.shownWifi.simpleQR {
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

/// On a display, under the progress bar: the zone it's showing ("Playing from Living Room") with
/// its hub's icon, as on the Apple TV. Plain text, not a capsule, so it can't be mistaken for a
/// requester pill.
private struct DisplayZoneLine: View {
    /// Its height, which the artwork leaves room for (`NowPlayingView.reserved`).
    static let height: CGFloat = 18
    @Environment(AppModel.self) private var model

    var body: some View {
        // What the hub says in its snapshots (it follows renames), else what it announced when
        // this display joined.
        let session = model.session
        let listing = model.displayedZone
        let name = session.zoneName.flatMap { $0.isEmpty ? nil : $0 } ?? listing?.name
        let kind = session.hubKind ?? listing?.kind ?? .ipad
        let device = session.hubKind != nil ? session.hubDevice : listing?.device
        HStack(spacing: 7) {
            Image(systemName: kind == .tv ? "tv.fill" : DeviceSymbol.name(kind: kind, device: device))
                .font(.system(size: 13, weight: .medium))
            Text("Playing from \(name ?? "another device")")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white.opacity(0.5))
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
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
                        let hub = model.displayedZone.map { $0.kind == .tv ? "the Apple TV is on" : "the \(MacKind(wire: $0.device)?.noun ?? "iPad") is awake" } ?? "the hub is awake"
                        Text("Reconnecting. Make sure \(hub) and Canopy Music is open.")
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
