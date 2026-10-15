import AVFoundation
import CanopyMusicCore
import CanopyMusicServer
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
    /// Switching to Spotify from the Music row before it's signed in: setup's sign-in step.
    @State private var signingInToSpotify = false
    @State private var signedInToSpotify = false

    private var session: PartySession { model.session }

    /// The Music row's service menu: only on the start screen (nil in a live zone).
    private var switchService: ((AppModel.Provider) -> Void)? {
        model.isLive ? nil : { next in chooseService(next) }
    }

    /// Spotify signs in first if it isn't yet, on its setup page (backing out keeps the current
    /// service), then asks where music plays (`AppModel.switchService`).
    private func chooseService(_ next: AppModel.Provider) {
        guard next != model.provider else { return }
        if next == .spotify, !model.spotifyAuth.isSignedIn || model.spotifyClientID.isEmpty {
            openSpotifySetup()
        } else {
            model.switchService(to: next)
        }
    }

    /// Spotify's setup page, full screen: from the menu, or the Music row's Sign in when Spotify
    /// is chosen but signed out.
    private func openSpotifySetup() {
        signedInToSpotify = false
        signingInToSpotify = true
    }

    /// Start on the start screen; Back to party (just locking) in a live zone.
    private var canPressStart: Bool {
        model.isLive || model.canStartZone
    }

    var body: some View {
        @Bindable var model = model
        let theme = ArtworkTheme(session.nowPlaying?.track.colors)
        ContentCap {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Narrower in narrow windows (an iPad mini in portrait), so the queue keeps room.
                    settings
                        .frame(width: min(440, max(340, geo.size.width * 0.45)))
                    // Past a 13" iPad's width (a Mac window, up to ContentCap's width) the queue stops
                    // growing and both columns stay together in the middle.
                    queuePanel
                        .frame(maxWidth: 900)
                        .padding(.vertical, 24)
                        .padding(.trailing, 24)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background {
            // The song's colours once there's a song (a playlist loaded, or playing); Dusk on the
            // empty start screen, cross-fading as the song's background does. The art drifts,
            // paused too, but never under Dusk.
            ZStack {
                ThemedBackground(track: session.nowPlaying?.track, theme: theme, moves: session.nowPlaying != nil)
                DuskBackground()
                    .opacity(session.nowPlaying == nil ? 1 : 0)
                    .animation(.linear(duration: 2), value: session.nowPlaying == nil)
            }
        }
        .environment(\.artworkTheme, theme)
        .preferredColorScheme(.dark)
        // Presented views get the model explicitly: on a Mac, a sheet's view was seen without it
        // ("No Observable object of type AppModel found" on End Zone).
        .sheet(isPresented: $showPicker) { PlaylistPickerView().environment(model) }
        .modifier(AppleMusicOffer(enabled: model.provider == .appleMusic, isPresented: $showSubscriptionOffer))
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(model)
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        }
        // "Where should music play?": the Music section's output row, Start finding no Spotify
        // device, or switching to Spotify. With the Sonos rooms.
        .outputPicker(includesSonos: true)
        .fullScreenCover(isPresented: $signingInToSpotify, onDismiss: {
            guard signedInToSpotify else { return }
            // Signed in: Spotify is chosen now, then "Where should music play?" (already
            // chosen: signed in again, the device is asked for if there isn't one).
            if model.provider != .spotify {
                model.switchService(to: .spotify)
            } else if model.spotifyDeviceID == nil {
                model.isPickingSpotifyDevice = true
            }
        }) {
            ZStack {
                DuskBackground()
                SpotifySetupStep(back: { signingInToSpotify = false }) {
                    signedInToSpotify = true
                    signingInToSpotify = false
                }
            }
            .tint(AppModel.Provider.spotify.accent)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .environment(model)
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains(where: ["-showSettings", "-showSave"].contains) { showSettings = true }
            if ProcessInfo.processInfo.arguments.contains("-showPicker") { showPicker = true }
            if ProcessInfo.processInfo.arguments.contains("-confirmEnd") { confirmingEnd = true }
            if ProcessInfo.processInfo.arguments.contains("-showSkipped") {
                Task { try? await Task.sleep(for: .seconds(2)); showSkipped = true }
            }
            // `-switchService appleMusic|spotify`: picks that service from the Music row's menu
            // 2 s in (the simulator can't be tapped from here).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-switchService"), i + 1 < args.count,
               let next = AppModel.Provider(rawValue: args[i + 1]), let switchService {
                Task { try? await Task.sleep(for: .seconds(2)); switchService(next) }
            }
            if args.contains("-openServiceMenu") {
                Task { try? await Task.sleep(for: .seconds(2)); DebugMenuOpener.openWidestMenu() }
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
            // The logo is centred in the column, whatever buttons are either side of it.
            ZStack {
                LogoView(height: 36)
                HStack {
                    // The start screen (nothing live) goes back to the zone list; a live zone
                    // ends with End Zone instead.
                    if !model.isLive {
                        Button {
                            model.leaveStartScreen()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .buttonBorderShape(.circle)
                        .disabled(model.isStartingZone)
                        .accessibilityLabel("Back to zones")
                    }
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Form {
                // The service row switches services on the start screen only (its chevron menu);
                // in a live zone it just shows the service.
                Section("Music") {
                    if model.provider == .spotify {
                        SpotifyStatusRows(switchService: switchService, openSetup: openSpotifySetup)
                    } else if model.isDemo {
                        HStack(spacing: 12) {
                            ServiceMenu(choose: switchService) {
                                Label("Demo mode: fake songs, no audio", systemImage: "theatermasks")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let switchService {
                                ServiceMenu(choose: switchService) { ServiceChevron() }
                            }
                        }
                    } else {
                        AppleMusicStatusRow(showOffer: $showSubscriptionOffer, switchService: switchService)
                        // This iPad, with its AirPlay row, or Sonos rooms.
                        OutputRow()
                    }
                }
                .listRowBackground(Color.white.opacity(0.08))

                ZoneSection()
                    .listRowBackground(Color.white.opacity(0.08))

                // The phone page runs only in a live zone.
                if model.isLive {
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
                            Text("Connect the \(DeviceKind.noun) to Wi\u{2011}Fi so guests can queue from their phones.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }

                // Other Canopy devices showing this zone (docs/multi-device.md).
                if model.isLive, !model.session.displays.isEmpty {
                    Section("Connected") {
                        ForEach(model.session.displays) { display in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                    Text("Display").font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: DeviceSymbol.name(kind: display.kind, device: display.device))
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }

                Section {
                    // Start makes the zone live (`AppModel.startZone`); in a live zone this just
                    // goes back to the party screen, with End Zone beside it (in the same row, so
                    // it's on screen without scrolling).
                    HStack(spacing: 12) {
                        if model.isLive {
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
                        }
                        Button {
                            if model.isLive {
                                model.lock()
                            } else {
                                Task { await model.startZone() }
                            }
                        } label: {
                            ZStack {
                                Text(model.isLive ? "Back to party" : "Start")
                                    .opacity(model.isStartingZone ? 0 : 1)
                                if model.isStartingZone { ProgressView() }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        // Dimmed rather than `.disabled`, which swaps the prominent glass for a gray style.
                        .opacity(canPressStart ? 1 : 0.45)
                        .allowsHitTesting(canPressStart && !model.isStartingZone)
                        .accessibilityHint(canPressStart ? "" : "Choose a playlist first")
                    }
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Press and hold the Canopy logo to return to this screen. PIN required if set. Turn on Guided Access (triple-click the top button) so guests can’t leave the app.")
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

/// The service with a one-line status; problem states carry their fix in the row. On the start
/// screen the row (and its chevron) opens the service menu.
private struct AppleMusicStatusRow: View {
    @Environment(AppModel.self) private var model
    @Binding var showOffer: Bool
    let switchService: ((AppModel.Provider) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ServiceMenu(choose: switchService) {
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
                }
            }
            action
            if let switchService {
                ServiceMenu(choose: switchService) { ServiceChevron() }
            }
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

// MARK: - Switching services

/// The start screen's service switcher: the Music row is a full-width dropdown. The row, and its
/// down chevron, open a menu offering only the other service, with that service's state on a
/// second line. In a live zone (`choose` is nil) it's just the row: the service changes only by
/// ending the zone.
struct ServiceMenu<Content: View>: View {
    @Environment(AppModel.self) private var model
    let choose: ((AppModel.Provider) -> Void)?
    @ViewBuilder let label: Content

    var body: some View {
        if let choose {
            Menu {
                ForEach([AppModel.Provider.appleMusic, .spotify].filter { $0 != model.provider }, id: \.self) { provider in
                    Button {
                        choose(provider)
                    } label: {
                        Text(provider.title)
                        if let detail = model.serviceDetail(provider) { Text(detail) }
                        Image(provider == .spotify ? "SpotifyIcon" : "AppleMusicIcon")
                    }
                }
            } label: {
                label.contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityHint("Switches the music service")
        } else {
            label
        }
    }
}

extension AppModel {
    /// A service's state in a line, as the service menu and setup's service step say it:
    /// Spotify's sign-in (choosing it when it isn't connected opens its setup page), and Apple
    /// Music's access when something's in the way.
    func serviceDetail(_ provider: Provider) -> String? {
        switch provider {
        case .spotify:
            guard spotifyAuth.isSignedIn, !spotifyClientID.isEmpty else { return "Not connected. Tap to sign in." }
            return spotifyDisplayName.map { "Signed in as \($0)" } ?? "Signed in"
        case .appleMusic:
            switch authorization {
            case .authorized: return canPlayAppleMusic ? nil : "No subscription"
            case .denied, .restricted: return "Access is off"
            default: return "Not connected"
            }
        default:
            return nil
        }
    }
}

#if DEBUG
/// `-openServiceMenu`: opens the start screen's Music menu, for screenshots (the simulator can't
/// be tapped from here). Finds the widest menu button on screen (the Music row's) and presents its
/// menu through UIKit's private `_presentMenuAtLocation:`. Debug builds only.
@MainActor
enum DebugMenuOpener {
    static func openWidestMenu() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var found: [(view: UIView, interaction: UIContextMenuInteraction)] = []
        func walk(_ view: UIView) {
            if view is UIButton {
                for case let interaction as UIContextMenuInteraction in view.interactions { found.append((view, interaction)) }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let target = found.max(by: { $0.view.bounds.width < $1.view.bounds.width }) else { return }
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let method = class_getInstanceMethod(type(of: target.interaction), selector) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(method_getImplementation(method), to: Present.self)
        present(target.interaction, selector, CGPoint(x: target.view.bounds.midX, y: target.view.bounds.maxY))
    }
}
#endif

/// The down chevron at the end of the Music row.
struct ServiceChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel("Music service")
    }
}

// MARK: - Zone

/// The Zone section: its name and PIN, prefilled from setup or the last zone and editable here
/// and in a live zone. The `.local` address the name gives sits on the header's right, following
/// the name as it's typed. The name is applied on return or when the field loses focus, so the
/// zone (and its address) isn't re-announced on every keystroke. The PIN only guards a live
/// zone's host mode.
private struct ZoneSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// The zone's address for the saved name, else the one the typed name gives. nil when the
    /// name is empty or has no letters or digits.
    private var address: String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == model.zoneName { return model.localAddress }
        return FriendlyHostname.typedLocalName(forZone: name).map { "\($0).local" }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { draft = model.zoneName } else if name != model.zoneName { model.zoneName = String(name.prefix(40)) }
    }

    var body: some View {
        Section {
            HStack {
                Text("Name")
                Spacer(minLength: 16)
                TextField(DeviceKind.name, text: $draft)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(commit)
            }
            .onAppear { draft = model.zoneName }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            // Renamed elsewhere (a host on the web page).
            .onChange(of: model.zoneName) { _, name in if !focused { draft = name } }
            ZonePINRow()
        } header: {
            HStack {
                Text("Zone")
                Spacer(minLength: 16)
                if let address {
                    Text(address)
                        .font(.system(.footnote, design: .monospaced).weight(.regular))
                        .textCase(nil)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The host PIN: a navigation-style row ("None ›", or a dot per digit once there is one); tapping
/// anywhere on it opens the keypad (`PINSheet`). Empty unlocks without asking.
private struct ZonePINRow: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack {
                Text("PIN")
                Spacer(minLength: 16)
                Text(model.hostPIN.isEmpty ? "None" : String(repeating: "•", count: model.hostPIN.count))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(model.hostPIN.isEmpty ? "None" : "Set")
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(model.hostPIN.isEmpty ? "Sets a host PIN" : "Changes or turns off the host PIN")
        .sheet(isPresented: $editing) { PINSheet().environment(model) }
        #if DEBUG
        // `-showPINSheet`: opens the keypad at launch, for screenshots.
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-showPINSheet") { editing = true } }
        #endif
    }
}

/// Setting or changing the host PIN on a keypad like the party screen's unlock: digits only
/// (the unlock pad has nothing else), up to 8. Done saves it, Cancel leaves it as it was, and
/// Turn Off PIN (once one is set) removes it.
private struct PINSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 24) {
            Text(model.hostPIN.isEmpty ? "Set host PIN" : "Change host PIN")
                .font(.title2.bold())
            HStack(spacing: 14) {
                ForEach(0..<max(pin.count, 4), id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            PINPad(pin: $pin, length: 8, keySize: 84, spacing: 18)
            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .tint(.primary)
                Button("Done") {
                    model.hostPIN = pin
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(pin.isEmpty)
            }
            .controlSize(.large)
            .padding(.top, 8)
            if !model.hostPIN.isEmpty {
                Button("Turn Off PIN", role: .destructive) {
                    model.hostPIN = ""
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .padding(40)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Spotify


// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEnd = false
    @State private var savingPlaylist = false
    #if DEBUG
    @State private var debugSignInPage = false
    @State private var debugLibraryTest = false
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                // Spotify zones (the service is switched on the start screen's Music row, before Start).
                if model.provider == .spotify {
                    Section {
                        if model.spotifyAuth.isSignedIn, let name = model.spotifyDisplayName {
                            LabeledContent("Signed in as", value: name)
                        }
                        NavigationLink {
                            SpotifySignInPageSettings()
                                .environment(model)
                        } label: {
                            LabeledContent("Sign-in page", value: model.spotifyOwnSignInPage == nil ? "Default" : "Your own")
                        }
                        LabeledContent("Spotify requests", value: "\(model.spotifyAPI.requestCount) (\(Int(model.spotifyAPI.requestsPerMinute.rounded()))/min)")
                        if model.spotifyAPI.rateLimitedCount > 0 {
                            LabeledContent("Rate limited", value: "\(model.spotifyAPI.rateLimitedCount)×")
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Spotify")
                    } footer: {
                        Text("The sign-in page is only used when you sign in. Changing it doesn't sign you out.")
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                Section {
                    Toggle("Queue from phones", isOn: $model.phoneQueueEnabled)
                    Toggle("Reorder from phones", isOn: $model.phoneReorderEnabled)
                    // Only meaningful while guests can reorder at all.
                    if model.phoneReorderEnabled {
                        Toggle("Limit reorders", isOn: $model.reorderLimit.isOn)
                        if model.reorderLimit.isOn {
                            Stepper(value: $model.reorderLimit.allowance, in: ReorderLimit.allowances) {
                                LabeledContent("Initial balance", value: "\(model.reorderLimit.allowance)")
                            }
                            Picker("Refill", selection: $model.reorderLimit.refillMinutes) {
                                ForEach(ReorderLimit.refillChoices, id: \.self) { Text(ReorderLimit.refillLabel($0)).tag($0) }
                            }
                        }
                    }
                    LabeledContent("Address", value: model.localAddress)
                } footer: {
                    // The limit's rule first, while it's on: it's what just changed.
                    let limit = model.phoneReorderEnabled && model.reorderLimit.isOn ? "\(model.reorderLimit.summary) " : ""
                    Text("\(limit)Guests search and queue from their phones at \(model.localAddress), which follows the zone name. Turning it off hides the QR code; Host Control and displays keep working.")
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
                // The zone's name and PIN are on the host screen's Zone section.
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
                // A party to save, or a zone to end, only once it's live.
                if model.isLive, model.session.partySaveInfo.offersSave {
                    Section {
                        Button("Save as Playlist") { savingPlaylist = true }
                    } footer: {
                        Text("Saves the songs guests added so far, played or still in Up Next. The party carries on.")
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                if model.isLive {
                    Section {
                        Button("End Zone", role: .destructive) { confirmingEnd = true }
                    } footer: {
                        Text("Stops the music and the phone page and clears the queue. Your settings stay for the next zone.")
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
                #if DEBUG
                Section("Debug") {
                    NavigationLink("Library test") { LibraryTestView().environment(model) }
                }
                .listRowBackground(Color.white.opacity(0.08))
                #endif
            }
            .scrollContentBackground(.hidden)
            .endZoneConfirmation(isPresented: $confirmingEnd) { dismiss() }
            .sheet(isPresented: $savingPlaylist) { PartyPlaylistSheet(purpose: .save).environment(model) }
            #if DEBUG
            .onAppear { if ProcessInfo.processInfo.arguments.contains("-showSave") { savingPlaylist = true } }
            // `-showSignInPage`: Settings › Spotify › Sign-in page, for screenshots.
            .navigationDestination(isPresented: $debugSignInPage) { SpotifySignInPageSettings().environment(model) }
            // `-showLibraryTest`: Settings › Debug › Library test, for screenshots (it only reads
            // until a button is tapped).
            .navigationDestination(isPresented: $debugLibraryTest) { LibraryTestView().environment(model) }
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard args.contains("-showSignInPage") || args.contains("-showLibraryTest") else { return }
                // Once the sheet has finished coming up (a push during it is dropped).
                try? await Task.sleep(for: .seconds(2.5))
                if args.contains("-showSignInPage") { debugSignInPage = true } else { debugLibraryTest = true }
            }
            #endif
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
    /// goes back to the start screen. `before` runs first, e.g. to close a sheet.
    func endZoneConfirmation(isPresented: Binding<Bool>, before: @escaping () -> Void = {}) -> some View {
        modifier(EndZoneConfirmation(isPresented: isPresented, before: before))
    }
}

/// A small sheet with "Save as playlist" and its name field once someone has added a song (played
/// or still waiting); until then a plain alert (the party is just the base playlist, nothing worth
/// saving).
private struct EndZoneConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    let before: () -> Void
    /// Decided when it opens, so a song starting meanwhile doesn't swap the alert for the sheet.
    @State private var showingSheet = false
    @State private var showingAlert = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, presented in
                guard presented else { showingSheet = false; showingAlert = false; return }
                let offersSave = model.session.partySaveInfo.offersSave
                showingSheet = offersSave
                showingAlert = !offersSave
            }
            .sheet(isPresented: Binding(get: { showingSheet }, set: { showingSheet = $0; if !$0 { isPresented = false } })) {
                PartyPlaylistSheet(purpose: .end, beforeEnding: before)
                    .environment(model)
            }
            .alert("End \(model.zoneName)?", isPresented: Binding(get: { showingAlert }, set: { showingAlert = $0; if !$0 { isPresented = false } })) {
                Button("End", role: .destructive, action: end)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The music stops for everyone and the queue is cleared.")
            }
            #if DEBUG
            // `-autoEnd` (with `-confirmEnd`): presses End 10 s after the alert opens (the sheet
            // presses its own button).
            .task(id: showingAlert) {
                guard showingAlert, ProcessInfo.processInfo.arguments.contains("-autoEnd") else { return }
                try? await Task.sleep(for: .seconds(10))
                showingAlert = false
                isPresented = false
                end()
            }
            #endif
    }

    private func end() {
        before()
        model.endZone()
    }
}

// MARK: - Playlist bar

private extension HostView {
    /// One row; when the queue column is too narrow to leave the name some room beside the buttons
    /// (an iPad mini in portrait, narrow windows), the buttons go on a second row.
    var playlistBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                playlistIcon
                // The ideal width only decides when to switch to two rows: below it, the name
                // would be cut short.
                playlistInfo
                    .frame(minWidth: 160, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
                playlistButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    playlistIcon
                    playlistInfo
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    playlistButtons
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    var playlistIcon: some View {
        Image(systemName: "music.note.list")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
    }

    var playlistInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Base playlist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(session.state.playlistName ?? "None yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !session.skippedOnLoad.isEmpty {
                skippedNote
            }
            if let current = session.nowPlaying {
                Text("Playing \(current.track.title) · \(current.track.artist)\(current.id == session.externalCurrent?.id ? " · From \(session.serviceName ?? "Spotify")" : "")")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            if let issue = session.playerIssue {
                PlayerIssueLine(text: issue)
            }
        }
    }

    @ViewBuilder var playlistButtons: some View {
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
            .fixedSize()
            .buttonStyle(.glass)
            .tint(.primary)
            .disabled(!model.isReady)
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
    /// Song counts the list came without (Apple Music), fetched as rows appear, and counts a
    /// load found (an empty playlist refused).
    @State private var counts: [String: Int] = [:]
    /// The playlist chosen had nothing to play: said in an alert, and the picker stays open.
    @State private var refusal: PlaylistLoadError?

    var body: some View {
        NavigationStack {
            List {
                ForEach(source == .library ? filteredLibrary : catalogResults) { playlist in
                    let count = counts[playlist.id] ?? playlist.songCount
                    Button {
                        choose(playlist)
                    } label: {
                        HStack(spacing: 14) {
                            AsyncImage(url: playlist.artworkURL) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(playlist.name).foregroundStyle(.primary)
                                // "24 songs · Updated yesterday"; no count until it's known.
                                let details = [count.map(PlaylistSummary.countText), playlist.subtitle].compactMap { $0 }
                                if !details.isEmpty {
                                    Text(details.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if starting == playlist { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain, so names and subtitles aren't tinted like buttons.
                    .buttonStyle(.plain)
                    // Empty playlists are shown, dimmed, so nobody thinks they're missing.
                    .disabled(starting != nil || count == 0)
                    .opacity(count == 0 ? 0.4 : 1)
                    .task(id: playlist.id) {
                        guard count == nil, let found = await PlaylistSongCounts.shared.count(of: playlist, in: model.session.catalog) else { return }
                        counts[playlist.id] = found
                    }
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
            .task {
                await loadLibrary()
                #if DEBUG
                // `-autoPick <id>` (with `-showPicker`): taps that playlist's row 2 s in, as the
                // simulator can't be tapped from here (`-staleCounts`' "demo-empty" is refused).
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-autoPick"), i + 1 < args.count, let playlist = library.first(where: { $0.id == args[i + 1] }) {
                    try? await Task.sleep(for: .seconds(2))
                    choose(playlist)
                }
                #endif
            }
            .task(id: "\(source)-\(query)") { await searchCatalog() }
            .alert(refusal?.headline ?? "", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Choose another playlist.")
            }
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
            let refused = await model.load(playlist)
            starting = nil
            guard let refused else { return dismiss() }
            // Nothing changed: say why and stay, with the row dimmed if it's empty.
            if case .noSongs = refused { counts[playlist.id] = 0 }
            refusal = refused
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
