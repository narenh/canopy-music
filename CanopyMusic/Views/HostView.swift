import AVFoundation
import CanopyCore
import MusicKit
import SwiftUI

/// Host mode: connect Apple Music, pick the base playlist and speakers, manage the queue, then lock.
struct HostView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showSubscriptionOffer = false
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
        .musicSubscriptionOffer(isPresented: $showSubscriptionOffer)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-showSettings") { showSettings = true } }
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
                    } else if model.authorization == .authorized, !model.canPlayAppleMusic {
                        Label("An Apple Music subscription is needed to play songs", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if model.canBecomeAppleMusicSubscriber {
                            Button("See Apple Music offer") { showSubscriptionOffer = true }
                        }
                    } else if model.authorization == .authorized {
                        Label("Apple Music connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Button {
                            Task { await model.requestAuthorization() }
                        } label: {
                            Label("Connect Apple Music", systemImage: "music.note")
                        }
                        if model.authorization == .denied {
                            Text("Apple Music access is off. Turn it on in Settings › Privacy › Media & Apple Music.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.provider != .spotify {
                        Toggle("Crossfade", isOn: $model.crossfade)
                    }
                }
                .listRowBackground(Color.white.opacity(0.08))

                Section("Speakers") {
                    SpeakersRow()
                }
                .listRowBackground(Color.white.opacity(0.08))

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
                    Text("To unlock later, press and hold the Canopy logo. Turn on Guided Access (triple-click the top button) so guests can't leave the app.")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .listSectionSpacing(.compact)
        }
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

/// Sign-in and Spotify Connect device choice for the host Music section.
private struct SpotifyStatusRows: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [SpotifyDevice] = []
    @State private var loading = false

    var body: some View {
        if model.spotifyClientID.isEmpty {
            Label("Add your Spotify Client ID in Settings (gear)", systemImage: "key")
                .foregroundStyle(.secondary)
        } else if !model.spotifyAuth.isSignedIn {
            Button {
                Task { await model.signInToSpotify() }
            } label: {
                Label("Sign in to Spotify", systemImage: "person.crop.circle.badge.plus")
            }
        } else {
            Menu {
                ForEach(devices.filter { $0.id != nil }) { device in
                    Button {
                        model.spotifyDeviceID = device.id
                        model.spotifyDeviceName = device.name
                    } label: {
                        Label(device.name, systemImage: device.id == model.spotifyDeviceID ? "checkmark" : Self.icon(for: device.type))
                    }
                }
                Divider()
                Button("Refresh devices", systemImage: "arrow.clockwise") { Task { await reload() } }
            } label: {
                LabeledContent {
                    Text(model.spotifyDeviceName ?? "Choose…")
                } label: {
                    Label("Spotify device", systemImage: "hifispeaker")
                }
            }
            .task { await reload() }
            if devices.isEmpty, !loading {
                Text("No devices. Open Spotify on this iPad (or an Apple TV), then refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        loading = true
        devices = await model.spotifyDevices()
        loading = false
    }

    static func icon(for type: String) -> String {
        switch type.lowercased() {
        case "tablet", "smartphone": "ipad"
        case "tv": "appletv"
        case "computer": "laptopcomputer"
        default: "hifispeaker"
        }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Edited locally and applied on return or when the sheet closes, so the network name isn't
    /// re-announced on every keystroke.
    @State private var localNameDraft = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
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
                    Toggle("Queue from phones", isOn: $model.phoneQueueEnabled)
                    if model.phoneQueueEnabled {
                        HStack(spacing: 0) {
                            Text("Address")
                            Spacer(minLength: 16)
                            TextField("music", text: $localNameDraft)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                                .submitLabel(.done)
                                .onSubmit { model.setLocalName(localNameDraft) }
                            Text(".local")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Runs a small local web server at \(model.localName).local so guests can search and queue from their phones. Turning it off stops the server and hides the QR code.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    TextField("Network name", text: $model.wifiSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.wifiPassword)
                } header: {
                    Text("Wi\u{2011}Fi Information")
                } footer: {
                    Text("Shows a “Join Wi\u{2011}Fi” QR code.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    SecureField("Unlock PIN (optional)", text: $model.hostPIN)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Host")
                } footer: {
                    Text("Asked for when you press and hold the Canopy logo on the party screen.")
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
            }
            .scrollContentBackground(.hidden)
            .onAppear { localNameDraft = model.localName }
            .onDisappear { model.setLocalName(localNameDraft) }
            .onChange(of: model.localName) { _, name in localNameDraft = name }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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
                .buttonBorderShape(.circle)
                .accessibilityLabel("Shuffle playlist")
            }
            Button(session.state.playlistName == nil ? "Choose playlist" : "Change") { showPicker = true }
                .buttonStyle(.glass)
                .disabled(!model.isReady)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                TextField(source == .library ? "Filter your playlists" : "Search \(title(.catalog)) playlists", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                    }
                    .disabled(starting != nil)
                }
            }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        loading = true
        defer { loading = false }
        do {
            library = try await model.session.catalog.libraryPlaylists()
        } catch {
            errorText = error.localizedDescription
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
