import AVFoundation
import CanopyMusicCore
import SwiftUI

/// The start screen's "Plays on …" row in the Music section: where the zone's music plays (a
/// Spotify Connect device, this device and its AirPlay speakers, or Sonos rooms), with a live
/// status. Tapping it opens "Where should music play?" (`OutputPicker`). While music plays on
/// this device, the AirPlay button picks its speakers, as the Speakers section's row did.
struct OutputRow: View {
    @Environment(AppModel.self) private var model
    @State private var outputs: [AVAudioSessionPortDescription] = []
    @State private var trigger = RoutePickerTrigger()

    var body: some View {
        HStack(spacing: 12) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if airPlayApplies {
                RoutePicker(tint: .white, trigger: trigger)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("AirPlay speakers")
            }
            Button {
                model.isPickingSpotifyDevice = true
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Where music plays")
        }
        .onAppear(perform: refreshRoute)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshRoute()
        }
        // Keep the Spotify device's status current while host mode is open (one request every 10 s).
        .task(id: model.provider) {
            guard model.provider == .spotify else { return }
            while !Task.isCancelled {
                await model.refreshSpotifyDevices()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func refreshRoute() {
        outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    }

    /// AirPlay speakers apply: music plays from this device (Apple Music, or Spotify's app here).
    private var airPlayApplies: Bool {
        model.sonosOutput == nil && model.showsSpeakerChoice
    }

    private var airPlayNames: String? {
        let airPlay = outputs.filter { $0.portType == .airPlay }
        return airPlay.isEmpty ? nil : airPlay.map(\.portName).joined(separator: ", ")
    }

    private var icon: String {
        if let output = model.sonosOutput {
            return output.target.rooms.count > 1 ? "hifispeaker.2.fill" : SonosRoomIcon.symbol(model.sonos.player(output.target.coordinator.id)?.displayName)
        }
        if model.provider == .spotify { return SpotifyDeviceKind.icon(model.spotifyDeviceType) }
        return airPlayNames != nil ? "airplay.audio" : ThisDeviceRow.symbol
    }

    private var title: String {
        if let output = model.sonosOutput { return "Plays on \(output.target.name)" }
        if model.provider == .spotify { return model.spotifyDeviceName.map { "Plays on \($0)" } ?? "Choose where music plays" }
        return "Plays on \(airPlayNames ?? "this \(DeviceKind.noun)")"
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
        } else if airPlayNames != nil {
            Text("AirPlay").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// "Where should music play?" for Apple Music: this device, which plays over AirPlay as before
/// (its button picks the speakers). Choosing it leaves Sonos.
struct ThisDeviceRow: View {
    @Environment(AppModel.self) private var model
    @State private var outputs: [AVAudioSessionPortDescription] = []
    @State private var trigger = RoutePickerTrigger()

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
                        Text(subtitle)
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
                RoutePicker(tint: .white, trigger: trigger)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("AirPlay speakers")
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            refresh()
        }
    }

    private var subtitle: String {
        let airPlay = outputs.filter { $0.portType == .airPlay }.map(\.portName)
        return airPlay.isEmpty ? "Its speakers, or AirPlay" : "AirPlay: \(airPlay.joined(separator: ", "))"
    }

    private func refresh() {
        outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    }
}
