import AVFoundation
import CanopyCore
import MusicKit
import SwiftUI

/// Host mode: connect Apple Music, pick the base playlist and speakers, manage the queue, then lock.
struct HostView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var scrollTarget: UUID?

    private var session: PartySession { model.session }

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
                    if model.isDemo {
                        Label("Demo mode: fake songs, no audio", systemImage: "theatermasks")
                    } else if model.authorization == .authorized {
                        Label("Apple Music connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
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
                    Toggle("Crossfade", isOn: $model.crossfade)
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
                        Text("Connect the iPad to Wi-Fi so guests can queue from their phones.")
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
                        Label(session.isPlaying ? "Back to party" : "Start", systemImage: session.isPlaying ? "lock.fill" : "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .disabled(session.state.current == nil && session.state.upNext.isEmpty)
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

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Queue from phones", isOn: $model.phoneQueueEnabled)
                } footer: {
                    Text("Runs a small web page on your Wi-Fi at music.local so guests can search and queue from their phones. Turning it off stops the page and hides the QR code.")
                }
                .listRowBackground(Color.white.opacity(0.08))
                Section {
                    TextField("Network name", text: $model.wifiSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.wifiPassword)
                } header: {
                    Text("Guest Wi-Fi")
                } footer: {
                    Text("Shows a second QR code on the party screen that joins this network. Leave the name empty to hide it.")
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
                Section {
                    Toggle("Demo mode", isOn: Binding(get: { model.isDemo }, set: { model.setDemoMode($0) }))
                } footer: {
                    Text("Fake songs and no audio, for trying things out without Apple Music.")
                }
                .listRowBackground(Color.white.opacity(0.08))
            }
            .scrollContentBackground(.hidden)
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

    enum Source: String, CaseIterable { case library = "Your playlists", catalog = "Apple Music" }

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
                TextField(source == .library ? "Filter your playlists" : "Search Apple Music playlists", text: $query)
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
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
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
        .onAppear {
            if model.hostPIN.isEmpty, model.unlock(pin: "") { dismiss() }
        }
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
