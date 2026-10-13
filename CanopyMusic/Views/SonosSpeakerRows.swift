import CanopyMusicCore
import CanopyMusicServer
import SwiftUI

/// The Speakers section's Sonos rows: rooms and existing groups found on the network. Choosing
/// one plays the zone's songs there, streamed by Sonos from an account linked in the Sonos app;
/// with a room chosen, other rooms can join it. Several linked accounts for the zone's service
/// get a "Whose account plays" picker.
struct SonosSpeakerRows: View {
    @Environment(AppModel.self) private var model

    private var household: SonosHousehold { model.sonos }
    private var chosen: [String] { model.sonosOutput?.roomIDs ?? [] }

    /// The zone's service has an account Sonos can stream from.
    private var hasAccount: Bool { model.sonosAccount != nil }

    var body: some View {
        if let service = model.sonosService {
            if household.rooms.isEmpty {
                // Chosen before, not found now (asleep, unplugged, another Wi‑Fi).
                if let output = model.sonosOutput {
                    Button {
                        model.useThisDevice()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hifispeaker.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(output.target.name)
                                StatusDot(color: .orange, text: household.hasSearched ? "Not found on this Wi\u{2011}Fi" : "Looking…")
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays on this \(DeviceKind.noun) instead")
                }
            } else {
                ForEach(multiRoomGroups) { group in
                    groupRow(group)
                }
                ForEach(household.rooms) { room in
                    roomRow(room)
                }
                if !hasAccount {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusDot(color: .orange, text: "Add \(service.sonosName) in the Sonos app")
                        Text("Already added? Play any \(service.sonosName) song on a Sonos speaker from the Sonos app once, so Canopy Music can find the account.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if !chosen.isEmpty, model.sonosAccountsForZone.count > 1 {
                    accountPicker(service)
                }
            }
        }
    }

    /// Groups of more than one room, as the Sonos app has them now.
    private var multiRoomGroups: [SonosGroup] {
        household.groups.filter { $0.rooms.count > 1 }
    }

    private func groupRow(_ group: SonosGroup) -> some View {
        let ids = group.rooms.map(\.id)
        let selected = chosen == ids
        return Button {
            selected ? model.useThisDevice() : model.selectSonos(rooms: ids)
        } label: {
            row(icon: "hifispeaker.2.fill", title: group.name, subtitle: "Sonos group", selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(!hasAccount)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func roomRow(_ room: SonosPlayer) -> some View {
        let leads = chosen.first == room.id
        let joined = !leads && chosen.contains(room.id)
        HStack(spacing: 12) {
            Button {
                // Tapping the only chosen room again goes back to this device.
                if leads, chosen.count == 1 { model.useThisDevice() } else { model.selectSonos(rooms: [room.id]) }
            } label: {
                row(icon: "hifispeaker.fill", title: room.roomName, subtitle: "Sonos \(room.displayName)", selected: leads || joined)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(leads || joined ? .isSelected : [])
            // With a room chosen, the others can join it.
            if !chosen.isEmpty, !leads {
                Button {
                    var rooms = chosen
                    if joined { rooms.removeAll { $0 == room.id } } else { rooms.append(room.id) }
                    model.selectSonos(rooms: rooms)
                } label: {
                    Image(systemName: joined ? "minus.circle" : "plus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(joined ? "Stop playing in \(room.roomName)" : "Also play in \(room.roomName)")
            }
        }
        .disabled(!hasAccount)
    }

    private func row(icon: String, title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .opacity(hasAccount ? 1 : 0.5)
    }

    /// "Whose account plays": Sonos names no accounts, so each is told apart by a song it played.
    private func accountPicker(_ service: SonosMusicService) -> some View {
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
