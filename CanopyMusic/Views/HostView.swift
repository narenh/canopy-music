import AVFoundation
import CanopyMusicCore
import MusicKit
import SwiftUI

/// Host mode: connect Apple Music, pick the base playlist and speakers, manage the queue, then lock.
struct HostView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showSubscriptionOffer = false
    @State private var showSkipped = false
    @State private var confirmingEnd = false
    @State private var scrollTarget: UUID?

    private var session: PartySession { model.session }

    private var canStart: Bool {
        model.isReady && (session.state.current != nil || !session.state.upNext.isEmpty)
    }

    var body: some View {
        @Bindable var model = model
        let theme = ArtworkTheme(session.state.current?.track.colors)
        HStack(spacing: 0) {
            settings
                .frame(width: 440)
            queuePanel
                .padding(.vertical, 24)
                .padding(.trailing, 24)
        }
        .background { ThemedBackground(track: session.state.current?.track, theme: theme) }
        .environment(\.artworkTheme, theme)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPicker) { PlaylistPickerView() }
        .modifier(AppleMusicOffer(enabled: model.provider == .appleMusic, isPresented: $showSubscriptionOffer))
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains(where: ["-showSettings", "-showSave"].contains) { showSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-showPicker") { showPicker = true }
            if ProcessInfo.processInfo.arguments.contains("-confirmEnd") { confirmingEnd = true }
            if ProcessInfo.processInfo.arguments.contains("-showSkipped") {
                Task { try? await Task.sleep(for: .seconds(2)); showSkipped = true }
            }
        }
        #endif
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Settings column

    private var settings: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack {
                LogoView(height: 36)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .tint(.primary)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Form {
                Section("Music") {
                    if model.provider == .spotify {
                        SpotifyStatusRows()
                    } else if model.isDemo {
                        Label("Demo mode: fake songs, no audio", systemImage: "theatermasks")
                    } else {
                        AppleMusicStatusRow(showOffer: $showSubscriptionOffer)
                    }
                }
                .listRowBackground(Color.white.opacity(0.08))

                // When Spotify plays on another device (a TV, a speaker), the iPad's AirPlay choice
                // doesn't apply.
                if model.provider != .spotify || model.spotifyPlaysOnThisIPad {
                    Section("Speakers") {
                        SpeakersRow()
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }

                Section("Guests") {
                    if !model.phoneQueueEnabled {
                        Text("Queueing from phones is off. Turn it on in Settings.")
                            .foregroundStyle(.secondary)
                    } else if let url = model.guestURL {
                        LabeledContent("Phone link", value: GuestQRCard.display(model.friendlyURL ?? url))
                        if model.friendlyURL != nil {
                            LabeledContent("Also at", value: GuestQRCard.display(url))
                        }
                    } else {
                        Text("Connect the iPad to Wi\u{2011}Fi so guests can queue from their phones.")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.white.opacity(0.08))

                // Other Canopy devices showing this zone (docs/multi-device.md).
                if !model.session.displays.isEmpty {
                    Section("Connected") {
                        ForEach(model.session.displays) { display in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                    Text("Display").font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: display.kind == .tv ? "tv" : "ipad.landscape")
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }

                Section {
                    Button {
                        Task {
                            if !session.isPlaying { await model.play() }
                            model.lock()
                        }
                    } label: {
                        Text(session.isPlaying ? "Back to party" : "Start")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    // Dimmed rather than `.disabled`, which swaps the prominent glass for a gray style.
                    .opacity(canStart ? 1 : 0.45)
                    .allowsHitTesting(canStart)
                    .accessibilityHint(canStart ? "" : "Choose a playlist first")
                } footer: {
                    Text("To unlock later, press and hold the logo. Turn on Guided Access (triple-click the top button) so guests can't leave the app.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingEnd = true
                    } label: {
                        Text("End Zone")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .overlay { Capsule().strokeBorder(.red, lineWidth: 1.5) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    // Set apart from Start so it isn't hit by mistake.
                    .padding(.top, 28)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .listSectionSpacing(.compact)
        }
        .endZoneConfirmation(isPresented: $confirmingEnd)
    }

    // MARK: Queue column

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            playlistBar
            HStack {
                Text("Up next").font(.system(size: 22, weight: .bold))
                Spacer()
                if session.state.upNext.contains(where: \.isRequest) {
                    Button("Clear requests", role: .destructive) { session.clearRequests() }
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .controlSize(.small)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
            if session.state.upNext.isEmpty {
                ContentUnavailableView {
                    Label("Pick a playlist to start", systemImage: "music.note.list")
                } description: {
                    Text("Songs from it, plus anything guests add, show up here.")
                } actions: {
                    Button("Choose playlist") { showPicker = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!model.isReady)
                }
                .foregroundStyle(.white)
            } else {
                UpNextList(session: session, canDelete: { _ in true }, scrollTarget: $scrollTarget)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

/// Wi‑Fi password with a show/hide button. Marked as a one-time code so iOS and password
/// managers don't offer to save it as an account password.
private struct WifiPasswordField: View {
    @Binding var password: String
    @State private var visible = false

    var body: some View {
        HStack {
            Group {
                if visible {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                visible.toggle()
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visible ? "Hide password" : "Show password")
        }
    }
}

// MARK: - Apple Music

/// The service with a one-line status; problem states carry their fix in the row.
private struct AppleMusicStatusRow: View {
    @Environment(AppModel.self) private var model
    @Binding var showOffer: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image("AppleMusicIcon")
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .saturation(model.authorization == .authorized ? 1 : 0)
                .opacity(model.authorization == .authorized ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music")
                status
            }
            Spacer(minLength: 8)
            action
        }
    }

    @ViewBuilder private var status: some View {
        switch model.authorization {
        case .authorized:
            if !model.canPlayAppleMusic {
                StatusDot(color: .orange, text: "No subscription")
            } else if !model.appleMusicLibrarySynced {
                StatusDot(color: .orange, text: "Your library isn't synced, so your playlists won't show. Turn on Sync Library in Settings › Apps › Music.")
            } else {
                StatusDot(color: .green, text: "Ready")
            }
        case .denied, .restricted:
            Text("Access is off").font(.footnote).foregroundStyle(.secondary)
        default:
            Text("Not connected").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        switch model.authorization {
        case .authorized:
            if !model.canPlayAppleMusic, model.canBecomeAppleMusicSubscriber {
                Button("See offer") { showOffer = true }
                    .buttonStyle(.glassProminent)
            }
        case .denied, .restricted:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.glass)
            .tint(.primary)
        default:
            Button("Connect") { Task { await model.requestAuthorization() } }
                .buttonStyle(.glassProminent)
        }
    }
}

// MARK: - Speakers

/// Current audio output (AirPlay speakers, or the iPad) with the system AirPlay picker.
private struct SpeakersRow: View {
    @State private var outputs: [AVAudioSessionPortDescription] = []
    @State private var trigger = RoutePickerTrigger()

    var body: some View {
        Button {
            trigger.present()
        } label: {
            HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(outputs.isEmpty ? "This iPad" : outputs.map(\.portName).joined(separator: ", "))
                    .lineLimit(2)
                if outputs.contains(where: { $0.portType == .airPlay }) {
                    Text("AirPlay").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            RoutePicker(tint: .white, trigger: trigger)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose speakers")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refresh()
        }
    }

    private func refresh() {
        outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    }
}

// MARK: - Spotify


// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Edited locally and applied on return or when the sheet closes, so the zone (and its
    /// `.local` address) isn't re-announced on every keystroke.
    @State private var zoneNameDraft = ""
    @State private var confirmingEnd = false
    @State private var savingPlaylist = false

    private func commitZoneName() {
        let name = zoneNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { zoneNameDraft = model.zoneName } else if name != model.zoneName { model.zoneName = String(name.prefix(40)) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Queue from phones", isOn: $model.phoneQueueEnabled)
                    Toggle("Reorder from phones", isOn: $model.phoneReorderEnabled)
                    LabeledContent("Address", value: model.localAddress)
                } footer: {
                    Text("Guests search and queue from their phones at \(model.localAddress), which follows the zone name. Turning it off hides the QR code; Host Control and displays keep working.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                if let hostURL = model.hostControlURL {
                    Section("Host Control") {
                        HStack(spacing: 16) {
                            QRCodeView(payload: hostURL.absoluteString)
                                .padding(8)
                                .frame(width: 120, height: 120)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text("Play/pause, skip, reorder, and delete from your phone. Everyone who scans this gets host control.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        HStack {
                            Text(model.hostControl.phones.count == 1 ? "1 phone" : "\(model.hostControl.phones.count) phones")
                            Spacer()
                            Button("Forget All", role: .destructive) { model.forgetHostPhones() }
                                .disabled(model.hostControl.phones.isEmpty)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                Section {
                    TextField("Network name", text: $model.wifiSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                    WifiPasswordField(password: $model.wifiPassword)
                    Toggle("Simple QR Code", isOn: $model.wifiSimpleQR)
                } header: {
                    Text("Wi\u{2011}Fi Information")
                } footer: {
                    Text("Shows a “Join Wi\u{2011}Fi” QR code. Turn on Simple QR Code if a phone has trouble scanning it.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    HStack {
                        Text("Zone name")
                        Spacer(minLength: 16)
                        TextField(UIDevice.current.name, text: $zoneNameDraft)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit { commitZoneName() }
                    }
                    SecureField("Unlock PIN (optional)", text: $model.hostPIN)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Zone")
                } footer: {
                    Text("Other Canopy Music devices on the Wi\u{2011}Fi see this zone by name. The PIN is asked for when you press and hold the logo on the party screen.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    Toggle("Playback controls on displays", isOn: $model.displaysCanControl)
                } header: {
                    Text("Displays")
                } footer: {
                    Text("Play/pause, skip and scrubbing on other iPads and Apple TVs showing this zone. Reordering follows Reorder from phones.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    Picker("Crossfade length", selection: $model.crossfadeSeconds) {
                        Text("Automatic").tag(0.0)
                        ForEach([3.0, 6.0, 10.0, 12.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Used when crossfade is on. Apple Music's AutoMix isn't available to other apps.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    Button {
                        dismiss()
                        model.changeService()
                    } label: {
                        HStack {
                            Text(model.provider.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("Change Service")
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if model.provider == .spotify {
                        LabeledContent("Spotify requests", value: "\(model.spotifyAPI.requestCount) (\(Int(model.spotifyAPI.requestsPerMinute.rounded()))/min)")
                        if model.spotifyAPI.rateLimitedCount > 0 {
                            LabeledContent("Rate limited", value: "\(model.spotifyAPI.rateLimitedCount)×")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Music Service")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    Button("Save as Playlist") { savingPlaylist = true }
                } footer: {
                    Text("Saves the songs that have played so far. The party carries on.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    Button("End Zone", role: .destructive) { confirmingEnd = true }
                } footer: {
                    Text("Stops the music and the phone page, clears the queue, and goes back to the zone list. Your settings stay for the next zone.")
                }
                .listRowBackground(Color.white.opacity(0.08))
            }
            .scrollContentBackground(.hidden)
            .endZoneConfirmation(isPresented: $confirmingEnd) { dismiss() }
            .sheet(isPresented: $savingPlaylist) { PartyPlaylistSheet(purpose: .save) }
            #if DEBUG
            .onAppear { if ProcessInfo.processInfo.arguments.contains("-showSave") { savingPlaylist = true } }
            #endif
            .onAppear { zoneNameDraft = model.zoneName }
            .onDisappear { commitZoneName() }
            .onChange(of: model.zoneName) { _, name in zoneNameDraft = name }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary) }
            }
        }
    }
}

// MARK: - Ending the zone

private extension View {
    /// Asks before ending the zone (hosts can also end it from the web page, which asks too), then
    /// goes back to the zone list. `before` runs first, e.g. to close a sheet.
    func endZoneConfirmation(isPresented: Binding<Bool>, before: @escaping () -> Void = {}) -> some View {
        modifier(EndZoneConfirmation(isPresented: isPresented, before: before))
    }
}

/// A small sheet rather than an alert, for "Save as playlist" and its name field.
private struct EndZoneConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let before: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            PartyPlaylistSheet(purpose: .end, beforeEnding: before)
        }
    }
}

// MARK: - Playlist bar

private extension HostView {
    var playlistBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text("Base playlist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(session.state.playlistName ?? "None yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !session.skippedOnLoad.isEmpty {
                    skippedNote
                }
                if let current = session.state.current {
                    Text("Playing \(current.track.title) · \(current.track.artist)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.state.playlistName != nil {
                Button {
                    withAnimation(.spring(duration: 0.45, bounce: 0.12)) { session.shufflePlaylist() }
                } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .tint(.primary)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Shuffle playlist")
            }
            Button(session.state.playlistName == nil ? "Choose playlist" : "Change") { showPicker = true }
                .buttonStyle(.glass)
                .tint(.primary)
                .disabled(!model.isReady)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// "3 songs aren't on Apple Music": the base playlist loaded without them. Tap for the list.
    var skippedNote: some View {
        let count = session.skippedOnLoad.count
        let service = session.serviceName ?? model.provider.title
        return Button { showSkipped = true } label: {
            Label(count == 1 ? "1 song isn't on \(service)" : "\(count) songs aren't on \(service)",
                  systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSkipped, arrowEdge: .top) {
            SkippedSongsView(songs: session.skippedOnLoad, service: service)
                .preferredColorScheme(.dark)
        }
    }
}

/// The songs a base playlist loaded without.
private struct SkippedSongsView: View {
    let songs: [QueueTrack]
    let service: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Not on \(service), so they won't play.")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 15))
                                .lineLimit(1)
                            Text(song.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        // Popovers don't size to a scroll view's content: about 46 points a song, up to 420.
        .frame(width: 340, height: min(420, 62 + CGFloat(songs.count) * 46))
    }
}

// MARK: - Playlist picker

struct PlaylistPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Source: CaseIterable { case library, catalog }

    /// Spotify's Development Mode can't read songs from playlists you don't own, so searching
    /// its catalog for playlists isn't offered.
    private var offersCatalogSearch: Bool { model.provider != .spotify }

    private func title(_ source: Source) -> String {
        switch source {
        case .library: "Your playlists"
        case .catalog: model.isDemo ? "Search" : model.provider.title
        }
    }

    @State private var source: Source = .library
    @State private var library: [PlaylistSummary] = []
    @State private var catalogResults: [PlaylistSummary] = []
    @State private var query = ""
    @State private var loading = false
    @State private var errorText: String?
    @State private var starting: PlaylistSummary?

    var body: some View {
        NavigationStack {
            List {
                ForEach(source == .library ? filteredLibrary : catalogResults) { playlist in
                    Button {
                        choose(playlist)
                    } label: {
                        HStack(spacing: 14) {
                            AsyncImage(url: playlist.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(playlist.name).foregroundStyle(.primary)
                                if let subtitle = playlist.subtitle {
                                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if starting == playlist { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain, so names and subtitles aren't tinted like buttons.
                    .buttonStyle(.plain)
                    .disabled(starting != nil)
                }
            }
            // Our own field rather than `.searchable`, whose spacing can't be adjusted.
            .safeAreaInset(edge: .top, spacing: 0) {
                SearchField(prompt: source == .library ? "Filter your playlists" : "Search \(title(.catalog)) playlists", text: $query)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
            .contentMargins(.top, 8, for: .scrollContent)
            .overlay {
                if loading { ProgressView() }
                else if let errorText { ContentUnavailableView("Couldn't load playlists", systemImage: "exclamationmark.triangle", description: Text(errorText)) }
            }
            .navigationTitle("Base playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if offersCatalogSearch {
                        Picker("Source", selection: $source) {
                            ForEach(Source.allCases, id: \.self) { Text(title($0)) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                    } else {
                        Text("Your playlists").font(.headline)
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(.primary) }
            }
            .task { await loadLibrary() }
            .task(id: "\(source)-\(query)") { await searchCatalog() }
        }
    }

    private var filteredLibrary: [PlaylistSummary] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return library }
        return library.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private func loadLibrary() async {
        // Show the last list right away and refresh behind it.
        if library.isEmpty { library = model.libraryPlaylistsCache }
        loading = library.isEmpty
        defer { loading = false }
        do {
            library = try await model.session.catalog.libraryPlaylists()
            model.libraryPlaylistsCache = library
        } catch {
            if library.isEmpty { errorText = error.localizedDescription }
        }
    }

    private func searchCatalog() async {
        guard source == .catalog else { return }
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { catalogResults = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        catalogResults = (try? await model.session.catalog.searchPlaylists(term)) ?? []
    }

    private func choose(_ playlist: PlaylistSummary) {
        starting = playlist
        Task {
            await model.load(playlist)
            starting = nil
            dismiss()
        }
    }
}

/// A capsule search field: magnifying glass, text, and a clear button while there's text.
private struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

// MARK: - Unlock

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Enter host PIN")
                .font(.title2.bold())
            HStack(spacing: 14) {
                ForEach(0..<max(model.hostPIN.count, 4), id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            .offset(x: wrong ? -10 : 0)
            .animation(.spring(duration: 0.2, bounce: 0.8), value: wrong)
            GlassEffectContainer {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 18), count: 3), spacing: 18) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 84)
                    } else {
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 30, weight: .medium))
                                .frame(width: 84, height: 84)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            }
            Button("Cancel") { dismiss() }
                .padding(.top, 8)
        }
        .padding(40)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)

    }

    private func press(_ key: String) {
        wrong = false
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        pin.append(key)
        guard pin.count >= model.hostPIN.count else { return }
        if model.unlock(pin: pin) {
            dismiss()
        } else {
            wrong = true
            pin = ""
        }
    }
}

/// Apple's subscription offer sheet, attached only in Apple Music mode so nothing Apple
/// Music-related runs (or prompts) while using Spotify.
private struct AppleMusicOffer: ViewModifier {
    let enabled: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.musicSubscriptionOffer(isPresented: $isPresented)
        } else {
            content
        }
    }
}
