import CanopyMusicCore
import CanopyMusicServer
import SwiftUI

/// "Where should music play?"'s Sonos section (start screen): the household's rooms, several
/// at once. Ticking one moves the music there from this device or a Spotify Connect device (a
/// gap while it switches); once on Sonos, more rooms join and leave without a restart. Each
/// row's second line is its model, or what it's busy playing (orange), or that it doesn't
/// answer. Several linked accounts for the zone's service get a "Whose account plays" picker.
struct SonosPickerSection: View {
    @Environment(AppModel.self) private var model

    private var household: SonosHousehold { model.sonos }
    private var hasAccount: Bool { model.sonosAccount != nil }

    var body: some View {
        if let service = model.sonosService {
            Section {
                if household.rooms.isEmpty, let output = model.sonosOutput {
                    // Chosen before, not found now (asleep, unplugged, another Wi‑Fi).
                    Button {
                        model.useThisDevice()
                    } label: {
                        HStack(spacing: 12) {
                            SonosRoomIcon(model: nil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(output.target.name)
                                StatusDot(color: .orange, text: household.hasSearched ? "Not found on this Wi\u{2011}Fi" : "Looking…")
                            }
                            Spacer(minLength: 8)
                            SonosCheck(ticked: true, joining: false)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays on this \(DeviceKind.noun) instead")
                } else {
                    ForEach(household.rooms) { room in
                        row(room)
                    }
                }
                if !household.rooms.isEmpty, !hasAccount {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusDot(color: .orange, text: "Add \(service.sonosName) in the Sonos app")
                        Text("Already added? Play any \(service.sonosName) song on a Sonos speaker from the Sonos app once, so Canopy Music can find the account.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if model.sonosOutput != nil, model.sonosAccountsForZone.count > 1 {
                    accountPicker
                }
            } header: {
                Text("Sonos")
            }
            .listRowBackground(Color.white.opacity(0.08))
            .task {
                // Busy rooms and ones that don't answer, kept current while the list shows.
                while !Task.isCancelled {
                    await model.readSonosRooms()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func row(_ room: SonosPlayer) -> some View {
        let ticked = model.isSonosRoomTicked(room.id)
        let joining = model.sonosJoining.contains(room.id)
        let status = SonosRoomStatus.of(roomID: room.id, model: room.displayName, ticked: ticked, joining: joining,
                                        live: model.sonosIsLive, reading: household.readings[room.id])
        return Button {
            guard status.canTick else { return }
            model.toggleSonosRoom(room.id)
        } label: {
            HStack(spacing: 12) {
                // Secondary, ticked or not, as This iPad's and the Music section's icons are.
                SonosRoomIcon(model: room.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.roomName).lineLimit(2)
                    SonosStatusText(status: status)
                }
                Spacer(minLength: 8)
                SonosCheck(ticked: ticked, joining: joining)
            }
            .contentShape(Rectangle())
            .opacity(status == .notResponding || !hasAccount ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!hasAccount || status == .notResponding)
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }

    /// "Whose account plays": Sonos names no accounts, so each is told apart by a song it played.
    private var accountPicker: some View {
        let accounts = model.sonosAccountsForZone
        return Picker("Whose account plays", selection: Binding(
            get: { model.sonosAccount?.id ?? "" },
            set: { id in if let account = accounts.first(where: { $0.id == id }) { model.chooseSonosAccount(account) } }
        )) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                Text(Self.label(account, index: index)).tag(account.id)
            }
        }
        .pickerStyle(.menu)
    }

    static func label(_ account: SonosAccount, index: Int) -> String {
        guard let example = account.example else { return "Account \(index + 1)" }
        return "Account \(index + 1), played “\(example)”"
    }
}

/// A room's second line: orange when it's playing something else.
struct SonosStatusText: View {
    let status: SonosRoomStatus

    var body: some View {
        Text(status.text)
            .font(.footnote)
            .foregroundStyle(isBusy ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(2)
    }

    private var isBusy: Bool {
        if case .busy = status { return true }
        return false
    }
}

/// The tick at the end of a room's row, as the system's selection checks: a white check on
/// green when ticked, a quiet ring when not, a spinner while it joins.
struct SonosCheck: View {
    let ticked: Bool
    let joining: Bool

    /// The system green as Increase Contrast draws it in light mode (#248A3D): dark enough for
    /// the white check to read, on dark glass and the start screen's dark list alike. The
    /// usual dark-mode green is too light for a white check.
    static let green = Color(UIColor.systemGreen.resolvedColor(with: UITraitCollection { traits in
        traits.userInterfaceStyle = .light
        traits.accessibilityContrast = .high
    }))

    var body: some View {
        Group {
            if joining {
                ProgressView().controlSize(.small)
            } else if ticked {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Self.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 22))
        .frame(width: 26, height: 26)
    }
}

/// A room's symbol, by the kind of speaker it is: the glyph on its own, secondary (primary for
/// a ticked room in the Speakers panel); the row dims it further when the room doesn't answer.
struct SonosRoomIcon: View {
    /// The model's short name ("Beam"); nil for a room not found.
    let model: String?
    var ticked = false

    var body: some View {
        Image(systemName: Self.symbol(model))
            .font(.system(size: 18))
            .foregroundStyle(ticked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: 28)
    }

    /// By the model's first word, as Sonos names them ("Arc Ultra", "Era 100", "Connect:Amp",
    /// "Play:5"). SF Symbols has no soundbar, subwoofer, or portable speaker, and the HomePod
    /// and Apple TV symbols may only stand for those, so the rest are all speakers.
    static func symbol(_ model: String?) -> String {
        let first = model?.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        switch first {
        // Soundbars sit under a TV.
        case "arc", "beam", "ray", "playbar", "playbase": return "tv.and.hifispeaker.fill"
        // Amps drive other speakers, as a receiver does.
        case "amp", "port", "connect": return "hifireceiver.fill"
        // One, Era 100 and 300, Five, Play:1, 3, and 5, Move, Roam, Sub, and anything new.
        default: return "hifispeaker.fill"
        }
    }
}
