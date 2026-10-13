import SwiftUI
import UIKit

/// Host Music section rows for Spotify: who's signed in, and where music plays with a live status.
/// On the start screen (`switchService` set) the first row, and its chevron, open the service menu.
struct SpotifyStatusRows: View {
    @Environment(AppModel.self) private var model
    let switchService: ((AppModel.Provider) -> Void)?

    var body: some View {
        @Bindable var model = model
        if model.spotifyClientID.isEmpty || !model.spotifyAuth.isSignedIn {
            HStack(spacing: 12) {
                Button {
                    Task { await model.signInToSpotify() }
                } label: {
                    Label("Sign in to Spotify", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(model.spotifyClientID.isEmpty)
                Spacer(minLength: 8)
                if let switchService {
                    ServiceMenu(choose: switchService) { ServiceChevron() }
                }
            }
        } else {
            HStack(spacing: 12) {
                ServiceMenu(choose: switchService) {
                    HStack(spacing: 12) {
                        Image("SpotifyIcon")
                            .resizable()
                            .frame(width: 28, height: 28)
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
                if let switchService {
                    ServiceMenu(choose: switchService) { ServiceChevron() }
                }
            }
            .task {
                if model.spotifyDisplayName == nil || model.spotifyAuth.accountFingerprint == nil {
                    await model.refreshSpotifyProfile()
                }
            }

            Button {
                model.isPickingSpotifyDevice = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: SpotifyDeviceKind.icon(model.spotifyDeviceType))
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.spotifyDeviceName.map { "Plays on \($0)" } ?? "Choose where music plays")
                        status
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The picker itself is presented by host mode (`HostView`).
            // Keep the status current while host mode is open (one request every 10 s).
            .task {
                while !Task.isCancelled {
                    await model.refreshSpotifyDevices()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.spotifyDeviceID == nil {
            EmptyView()
        } else if !model.spotifyDevicesLoaded {
            Text("Checking…").font(.footnote).foregroundStyle(.secondary)
        } else if model.spotifyDeviceAvailable {
            StatusDot(color: .green, text: "Ready")
        } else {
            StatusDot(color: .orange, text: "Not available. Open Spotify on it.")
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
        .spotifyDevicePicker()
        .task {
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

extension View {
    func spotifyDevicePicker() -> some View {
        modifier(SpotifyDevicePickerPresenter())
    }
}

private struct SpotifyDevicePickerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.sheet(isPresented: $model.isPickingSpotifyDevice) {
            SpotifyDevicePicker()
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        }
    }
}


/// "Where should music play?" Lists Spotify Connect devices and keeps looking while open.
struct SpotifyDevicePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let intro = "Open Spotify on this \(DeviceKind.noun) or another device in your home. That's where music will play from."

    @State private var nearby = SpotifyNearbyBrowser()

    /// Speakers on the network that Spotify doesn't list yet (by device id, else by name).
    private var unavailableNearby: [SpotifyNearbyBrowser.Speaker] {
        nearby.speakers
            .filter { speaker in !model.spotifyDevices.contains { speaker.isListed(id: $0.id ?? "", name: $0.name) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.spotifyDevices.isEmpty && unavailableNearby.isEmpty {
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
        .tint(AppModel.Provider.spotify.accent)
        .task {
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
    }

    /// Spotify Connect speakers on the network that Spotify's device list doesn't include yet.
    @ViewBuilder private var nearbySection: some View {
        if !unavailableNearby.isEmpty {
            Section {
                ForEach(unavailableNearby) { speaker in
                    HStack(spacing: 12) {
                        Image(systemName: SpotifyDeviceKind.icon(speaker.type))
                            .font(.system(size: 17))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speaker.name)
                            if let type = speaker.type {
                                Text(SpotifyDeviceKind.label(type)).font(.footnote)
                            }
                        }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Not available yet")
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("To use one of these, play something to it once from the Spotify app. It appears above after that.")
            }
            .listRowBackground(Color.white.opacity(0.04))
        }
    }

    private var list: some View {
        Form {
            Section {
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
                            if device.id == model.spotifyDeviceID {
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
                Searching(text: "Looking for more devices…")
            }
            .listRowBackground(Color.white.opacity(0.08))

            nearbySection

            Section {
                OpenSpotifyButton(prominent: false)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
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

private struct Searching: View {
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

private struct OpenSpotifyButton: View {
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
