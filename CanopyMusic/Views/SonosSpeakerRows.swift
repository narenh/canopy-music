import CanopyMusicCore
import CanopyMusicServer
import SwiftUI

/// "Where should music play?"'s Sonos section (start screen), under its Sonos segment: the
/// household's rooms, several at once. Ticking one moves the music there from this device or a
/// Spotify Connect device (a gap while it switches); once on Sonos, more rooms join and leave
/// without a restart. Each row's second line is its model, what it's busy playing (orange),
/// that another Canopy Music zone plays there (orange, with "Use" instead of a tick), or that it
/// doesn't answer. Several linked accounts for the zone's service get a "Whose account plays"
/// picker.
struct SonosPickerSection: View {
    @Environment(AppModel.self) private var model
    /// "Use" was tapped on this room: the dialog asks first.
    @State private var takingOver: String?

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
                // Only once Sonos has refused to play the service here: until then the rooms play
                // from the household's account without it having been seen.
                if !household.rooms.isEmpty, !hasAccount {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusDot(color: .orange, text: "Add \(service.sonosName) in the Sonos app")
                        Text("Sonos couldn't play \(service.sonosName). Already added? Play any \(service.sonosName) song from the Sonos app once, so Canopy Music can find it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if model.sonosOutput != nil, model.sonosAccountsForZone.count > 1 {
                    accountPicker
                }
            }
            .listRowBackground(Color.white.opacity(0.08))
            .task {
                #if DEBUG
                // `-sonosAskUse <room name>`: taps that room's "Use" once it's listed (screenshots).
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-sonosAskUse"), i + 1 < args.count {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        takingOver = household.rooms.first { $0.roomName == args[i + 1] }?.id
                    }
                }
                #endif
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
        let status = model.sonosStatus(of: room)
        // Another zone's: "Use" (asked first), never a tick.
        let offersUse = status.isInUse && !ticked
        return Button {
            if offersUse {
                takingOver = room.id
            } else if ticked || status.canTick {
                model.toggleSonosRoom(room.id)
            }
        } label: {
            HStack(spacing: 12) {
                // Secondary, ticked or not, as This iPad's and the Music section's icons are.
                SonosRoomIcon(model: room.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.roomName).lineLimit(2)
                    SonosStatusText(status: status)
                }
                Spacer(minLength: 8)
                if offersUse {
                    SonosUseLabel()
                } else {
                    SonosCheck(ticked: ticked, joining: joining)
                }
            }
            .contentShape(Rectangle())
            .opacity(status == .notResponding || !hasAccount ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!hasAccount || status == .notResponding)
        .accessibilityAddTraits(ticked ? .isSelected : [])
        .accessibilityHint(offersUse ? "Asks before taking it from the other zone" : "")
        .sonosTakeoverDialog(for: room.id, asking: $takingOver)
    }

    /// "Whose account plays": Sonos names no accounts, so each is told apart by a song it played.
    private var accountPicker: some View {
        let accounts = model.sonosAccountsForZone
        return Picker("Whose account plays", selection: Binding(
            get: { model.sonosAccount?.id ?? "" },
            set: { id in if let account = accounts.first(where: { $0.id == id }) { model.chooseSonosAccount(account) } }
        )) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                Text(account.label(index: index)).tag(account.id)
            }
        }
        .pickerStyle(.menu)
    }
}

/// A room's second line: orange when it's playing something else.
struct SonosStatusText: View {
    let status: SonosRoomStatus

    var body: some View {
        Text(status.text)
            .font(.footnote)
            .foregroundStyle(status.isBusy ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(2)
    }
}

/// "Use", where a tick would be, on a room another Canopy Music zone plays on. The whole row is
/// the button; this is its label.
struct SonosUseLabel: View {
    var body: some View {
        Text("Use")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.14), in: Capsule())
    }
}

extension View {
    /// Asks before "Use" takes rooms another zone plays on, from `roomID`'s row, while
    /// `asking` is that room (cleared when it closes): "Use Bedroom and Move?", with Use Both
    /// Rooms, Just Bedroom and Cancel. The other zone isn't told.
    func sonosTakeoverDialog(for roomID: String, asking: Binding<String?>) -> some View {
        modifier(SonosTakeoverDialog(roomID: roomID, asking: asking))
    }
}

private struct SonosTakeoverDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    let roomID: String
    @Binding var asking: String?

    private struct Question {
        var together: [String]
        var prompt: SonosTakeoverPrompt
    }

    private var question: Question? {
        guard asking == roomID, let room = model.sonos.player(roomID), let claim = model.sonosController.claim(on: roomID) else { return nil }
        let together = model.sonosTakenTogether(with: roomID)
        let names = together.compactMap { model.sonos.player($0)?.roomName }
        return Question(together: together, prompt: SonosTakeoverPrompt(room: room.roomName, together: names, zone: claim.zone))
    }

    func body(content: Content) -> some View {
        let question = question
        content.confirmationDialog(question?.prompt.title ?? "", isPresented: Binding(get: { question != nil }, set: { if !$0 { asking = nil } }),
                                   titleVisibility: .visible, presenting: question) { asking in
            if let all = asking.prompt.all {
                Button(all) { model.takeOverSonosRooms(asking.together) }
            }
            Button(asking.prompt.just) { model.takeOverSonosRooms([roomID]) }
            Button("Cancel", role: .cancel) {}
        } message: { asking in
            Text(asking.prompt.message)
        }
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
