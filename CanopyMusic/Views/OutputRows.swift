import AVFoundation
import CanopyMusicCore
import SwiftUI

/// The start screen's "Plays on …" row in the Music section: where the zone's music plays (a
/// Spotify Connect device, this device, or Sonos rooms), with a live status. Tapping it opens
/// "Where should music play?" (`OutputPicker`). While music plays on this device, the AirPlay
/// row under it picks its speakers (`AirPlayRow`).
struct OutputRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        playsOn
        // Keep the Spotify device's status current while host mode is open (one request every 10 s).
        .task(id: model.provider) {
            guard model.provider == .spotify else { return }
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // AirPlay speakers apply: music plays from this device (Apple Music, or Spotify's app
        // here), not Sonos rooms.
        if model.sonosOutput == nil, model.showsSpeakerChoice {
            AirPlayRow()
        }
    }

    private var playsOn: some View {
        Button {
            model.isPickingSpotifyDevice = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2)
                    status
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Chooses where music plays")
    }

    private var icon: String {
        if let output = model.sonosOutput {
            return output.target.rooms.count > 1 ? "hifispeaker.2.fill" : SonosRoomIcon.symbol(model.sonos.player(output.target.coordinator.id)?.displayName)
        }
        if model.provider == .spotify { return SpotifyDeviceKind.icon(model.spotifyDeviceType) }
        return ThisDeviceRow.symbol
    }

    private var title: String {
        if let output = model.sonosOutput { return "Plays on \(output.target.name)" }
        if model.provider == .spotify { return model.spotifyDeviceName.map { "Plays on \($0)" } ?? "Choose where music plays" }
        return "This \(DeviceKind.noun)"
    }

    @ViewBuilder private var status: some View {
        if model.sonosOutput != nil {
            if model.sonos.rooms.isEmpty {
                StatusDot(color: .orange, text: model.sonos.hasSearched ? "Not found on this Wi\u{2011}Fi" : "Looking…")
            } else if model.sonosAccount == nil, let service = model.sonosService {
                StatusDot(color: .orange, text: "Add \(service.sonosName) in the Sonos app")
            } else {
                StatusDot(color: .green, text: "Sonos")
            }
        } else if model.provider == .spotify {
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
}

/// The Music section's AirPlay row, under "Plays on" while music plays from this device: the
/// whole row opens the system AirPlay picker, anchored on its icon. The trailing text is the
/// current AirPlay route ("Living Room, Kitchen"), or nothing on the device's own speakers.
struct AirPlayRow: View {
    @State private var outputs: [AVAudioSessionPortDescription] = []
    @State private var trigger = RoutePickerTrigger()

    private var routeNames: String? {
        let airPlay = outputs.filter { $0.portType == .airPlay }
        return airPlay.isEmpty ? nil : airPlay.map(\.portName).joined(separator: ", ")
    }

    var body: some View {
        Button {
            trigger.present()
        } label: {
            HStack(spacing: 12) {
                RoutePicker(tint: .secondaryLabel, trigger: trigger)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("AirPlay")
                Spacer(minLength: 8)
                if let routeNames {
                    Text(routeNames)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AirPlay")
        .accessibilityValue(routeNames ?? "\(DeviceKind.noun) speakers")
        .accessibilityHint("Chooses AirPlay speakers")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refresh()
        }
    }

    private func refresh() {
        outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    }
}

/// "Where should music play?" for Apple Music: this device, which plays over AirPlay as before
/// (its button picks the speakers). Choosing it leaves Sonos.
struct ThisDeviceRow: View {
    @Environment(AppModel.self) private var model

    static var symbol: String { DeviceKind.isMac ? "laptopcomputer" : "ipad.landscape" }

    private var chosen: Bool { model.sonosOutput == nil }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.useThisDevice()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This \(DeviceKind.noun)")
                        Text("Device speakers or AirPlay 2")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if chosen {
                RoutePicker(tint: .white)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("AirPlay speakers")
            }
        }
    }
}
