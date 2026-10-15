import SwiftUI
import UIKit

/// Host Music section rows for Spotify: who's signed in, and where music plays with a live status.
/// On the start screen (`switchService` set) the first row, and its chevron, open the service
/// dropdown (`ServiceDropdown`, floating under it). Signed out, its Sign in opens Spotify's
/// setup page (`openSetup`).
struct SpotifyStatusRows: View {
    @Environment(AppModel.self) private var model
    let switchService: ((AppModel.Provider) -> Void)?
    @Binding var choosingService: Bool
    let openSetup: () -> Void

    var body: some View {
        @Bindable var model = model
        if model.spotifyClientID.isEmpty || !model.spotifyAuth.isSignedIn {
            HStack(spacing: 12) {
                ServiceMenu(isOpen: $choosingService, choose: switchService) {
                    HStack(spacing: 12) {
                        ServiceIcon(provider: .spotify)
                            .saturation(0)
                            .opacity(0.5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spotify")
                            Text("Not connected").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                }
                Button("Sign in", action: openSetup)
                    .buttonStyle(.glassProminent)
                if switchService != nil {
                    ServiceMenu(isOpen: $choosingService, choose: switchService) { ServiceChevron(isOpen: choosingService) }
                }
            }
            .serviceRow()
            // Spotify's "Invalid redirect URI" page can't be seen from here: say what to check.
            if model.spotifySignInClosed {
                Text("Add \(model.spotifyRedirectURI) to your Spotify app's Redirect URIs.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else {
            HStack(spacing: 12) {
                ServiceMenu(isOpen: $choosingService, choose: switchService) {
                    HStack(spacing: 12) {
                        ServiceIcon(provider: .spotify)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spotify")
                            if let name = model.spotifyDisplayName {
                                Text("Signed in as \(name)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                }
                if switchService != nil {
                    ServiceMenu(isOpen: $choosingService, choose: switchService) { ServiceChevron(isOpen: choosingService) }
                }
            }
            .serviceRow()
            .task {
                if model.spotifyDisplayName == nil || model.spotifyAuth.accountFingerprint == nil {
                    await model.refreshSpotifyProfile()
                }
            }

            // Where music plays: a Spotify Connect device, or Sonos rooms (`OutputRow`).
            OutputRow()
        }
    }
}

/// Party screen button (where crossfade sits for Apple Music): shows the device type, with an
/// orange dot when it isn't available. Opens the device picker.
struct SpotifyDeviceButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unavailable = model.spotifyDevicesLoaded && !model.spotifyDeviceAvailable
        Button {
            model.isPickingSpotifyDevice = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: SpotifyDeviceKind.icon(model.spotifyDeviceType))
                    .font(.system(size: 15, weight: .semibold))
                Circle()
                    .fill(.orange)
                    .frame(width: 4, height: 4)
                    .opacity(unavailable ? 1 : 0)
            }
            .frame(width: 44, height: 44)
            .offset(y: 2)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Where music plays")
        .accessibilityValue(model.spotifyDeviceName.map { unavailable ? "\($0), not available" : $0 } ?? "Not chosen")
        // Spotify Connect devices only: the music moves to Sonos from the start screen.
        .outputPicker(includesSonos: false)
        // Read again when it may have changed, else once a minute (`refreshSpotifyDevicesIfNeeded`).
        .task {
            while !Task.isCancelled {
                await model.refreshSpotifyDevicesIfNeeded()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

extension View {
    /// Presents "Where should music play?" (`AppModel.isPickingSpotifyDevice`). `includesSonos`:
    /// with its Sonos section (the start screen); setup and the party screen's Spotify device
    /// button list only the Spotify Connect devices.
    func outputPicker(includesSonos: Bool) -> some View {
        modifier(OutputPickerPresenter(includesSonos: includesSonos))
    }
}

private struct OutputPickerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let includesSonos: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.sheet(isPresented: $model.isPickingSpotifyDevice) {
            OutputPicker(includesSonos: includesSonos)
                .environment(model)
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        }
    }
}

/// "Where should music play?" For Spotify: the Spotify Connect devices, kept current while open.
/// For Apple Music: this device (and its AirPlay speakers). On the start screen, with Sonos rooms
/// on the Wi‑Fi, the Sonos rooms (`SonosPickerSection`) are stacked below, all on one page: the
/// iPad has the room, so there's no switch as on the phone's setup page. Choosing a device (or
/// This iPad) lets go of the rooms in one tap (the music moves back, with a gap if it's playing);
/// ticking a room leaves this device or the Connect device (the session is rebuilt,
/// `AppModel.rebuildSessionForOutput`, and a song playing carries on there, from where it was).
struct OutputPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let includesSonos: Bool

    private static let intro = "Open Spotify on this \(DeviceKind.noun) or another device in your home. That's where music will play from."

    private var showsSonos: Bool {
        includesSonos && model.sonosService != nil && (!model.sonos.rooms.isEmpty || model.sonosOutput != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.provider == .spotify, model.spotifyDevices.isEmpty, !showsSonos {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("Where should music play?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary) }
            }
        }
        .tint(model.provider.accent)
        .task {
            guard model.provider == .spotify else { return }
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var list: some View {
        Form {
            // Devices first, then Sonos, stacked.
            if model.provider == .spotify {
                spotifySection
                if model.spotifyDevices.isEmpty {
                    Section {
                        OpenSpotifyButton(prominent: false)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
            } else {
                Section {
                    ThisDeviceRow()
                }
                .listRowBackground(Color.white.opacity(0.08))
            }
            if showsSonos {
                SonosPickerSection()
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var spotifySection: some View {
        Section {
            if model.spotifyDevices.isEmpty {
                Searching(text: "Looking for devices…")
            }
            ForEach(model.spotifyDevices) { device in
                    Button {
                        model.selectSpotifyDevice(device)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: SpotifyDeviceKind.icon(device.type))
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(SpotifyDeviceKind.label(device.type))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Not while Sonos rooms play the music.
                            if device.id == model.spotifyDeviceID, model.sonosOutput == nil {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(Self.intro)
                    .textCase(nil)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            } footer: {
                if !model.spotifyDevices.isEmpty {
                    Searching(text: "Looking for more devices…")
                }
            }
            .listRowBackground(Color.white.opacity(0.08))
    }

    private var empty: some View {
        VStack(spacing: 20) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(Self.intro)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            OpenSpotifyButton(prominent: true)
            Searching(text: "Looking for devices…")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Searching: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct OpenSpotifyButton: View {
    let prominent: Bool

    var body: some View {
        let button = Button("Open Spotify on this \(DeviceKind.noun)") {
            if let url = URL(string: "spotify:") { UIApplication.shared.open(url) }
        }
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass).tint(.primary)
        }
    }
}

/// Icons and labels for Spotify Connect device types.
enum SpotifyDeviceKind {
    static func icon(_ type: String?) -> String {
        switch type?.lowercased() {
        case "tablet": "ipad.landscape"
        case "smartphone": "iphone"
        case "computer": "desktopcomputer"
        case "tv", "castvideo": "tv"
        case "stb": "tv.and.mediabox"
        case "speaker", "castaudio", "audiodongle": "hifispeaker.fill"
        case "avr": "hifireceiver"
        case "gameconsole": "gamecontroller"
        case "automobile": "car"
        case nil: "hifispeaker"
        default: "hifispeaker"
        }
    }

    static func label(_ type: String) -> String {
        switch type.lowercased() {
        case "tablet": "Tablet"
        case "smartphone": "Phone"
        case "computer": "Computer"
        case "tv": "TV"
        case "castvideo": "Chromecast"
        case "stb": "TV box"
        case "speaker": "Speaker"
        case "castaudio", "audiodongle": "Speaker"
        case "avr": "Receiver"
        case "gameconsole": "Game console"
        case "automobile": "Car"
        default: type
        }
    }
}
