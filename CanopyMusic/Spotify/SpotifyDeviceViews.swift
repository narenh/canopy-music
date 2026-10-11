import SwiftUI
import UIKit

/// Host Music section rows for Spotify: who's signed in, and where music plays with a live status.
struct SpotifyStatusRows: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        if model.spotifyClientID.isEmpty || !model.spotifyAuth.isSignedIn {
            Button {
                Task { await model.signInToSpotify() }
            } label: {
                Label("Sign in to Spotify", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(model.spotifyClientID.isEmpty)
        } else {
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
            }
            .task { if model.spotifyDisplayName == nil { await model.refreshSpotifyProfile() } }

            Button {
                showPicker = true
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
            .sheet(isPresented: $showPicker) {
                SpotifyDevicePicker()
                    .presentationBackground(.ultraThinMaterial)
                    .preferredColorScheme(.dark)
            }
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

private struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// "Where should music play?" Lists Spotify Connect devices and keeps looking while open.
struct SpotifyDevicePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let intro = "Open Spotify on this iPad or another device in your home. That's where music will play from."

    var body: some View {
        NavigationStack {
            Group {
                if model.spotifyDevices.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("Where should music play?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(AppModel.Provider.spotify.accent)
        .task {
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(3))
            }
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
        let button = Button("Open Spotify on this iPad") {
            if let url = URL(string: "spotify:") { UIApplication.shared.open(url) }
        }
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
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
