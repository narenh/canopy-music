import CanopyMusicCore
import CanopyMusicServer
import SwiftUI

/// The party screen's Speakers button, in AirPlay's place while the zone plays through Sonos
/// (never on displays). It opens `SonosSpeakersPanel`.
struct SonosSpeakersButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Speakers")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // Passed on, as every sheet here does: on a Mac the popover doesn't inherit it.
            SonosSpeakersPanel()
                .environment(model)
                .presentationCompactAdaptation(.popover)
        }
        #if DEBUG
        .task {
            // `-sonosPanel`: opens the panel once the party screen is up (for screenshots).
            if ProcessInfo.processInfo.arguments.contains("-sonosPanel") {
                try? await Task.sleep(for: .seconds(2))
                isPresented = true
            }
        }
        #endif
    }
}

/// "Speakers": the household's Sonos rooms, as the system AirPlay panel lists speakers. Tick
/// rooms to play in them (they join without the song restarting; untick and they leave). Each
/// ticked room has its own volume; with two or more, All Speakers moves them together, keeping
/// their balance. Volumes and what the other rooms are doing are read while it's open, so
/// changes made in the Sonos app show up. Leaving Sonos altogether is on the start screen, so
/// the last ticked room can't be unticked here.
struct SonosSpeakersPanel: View {
    @Environment(AppModel.self) private var model

    private var household: SonosHousehold { model.sonos }
    private var ticked: [SonosPlayer] { household.rooms.filter { model.isSonosRoomTicked($0.id) } }

    var body: some View {
        // As tall as the rooms need, so the popover fits them as rooms are ticked and readings
        // arrive. Only a household with more rooms than the popover has room for scrolls (from
        // the top, so the header and All Speakers are in view).
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 340)
        .background(FollowPopoverSize())
        .preferredColorScheme(.dark)
        .tint(.white)
        .task {
            while !Task.isCancelled {
                await model.readSonosRooms()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speakers").font(.headline)
                Spacer()
                Text("Sonos").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            if ticked.count > 1 {
                GroupVolume(rooms: ticked)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            ForEach(household.rooms) { room in
                SonosPanelRow(room: room, onlyTicked: ticked.count == 1 && model.isSonosRoomTicked(room.id))
            }
        }
        // The last row brings 6 of its own below it (and a slider a little more), so the bottom
        // needs less than the top for the two to look even.
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

/// Keeps the popover's content the size of the popover. On the iPadOS 27 betas (24A5355), when
/// the content's size changes while the popover is open, the popover's glass grows or shrinks to
/// fit, but the view SwiftUI presents the panel in stays the size the popover opened at (it has no
/// autoresizing mask, and the beta's popover doesn't resize it itself, as 26 and the 27.0 release
/// do). The panel, centred in that stale frame, sat half the difference too high: the header cut
/// off above the glass and an empty band below. Giving that view a flexible autoresizing mask
/// makes it follow the popover; elsewhere the popover already sizes it, so this changes nothing.
private struct FollowPopoverSize: UIViewRepresentable {
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Marker, context: Context) {}

    final class Marker: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The nearest view controller is the one presenting the panel in the popover.
            var responder: UIResponder? = next
            while let current = responder, !(current is UIViewController) { responder = current.next }
            (responder as? UIViewController)?.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }
}

/// One room: icon, name, what it's doing, the tick; and its volume while ticked.
private struct SonosPanelRow: View {
    @Environment(AppModel.self) private var model
    let room: SonosPlayer
    /// The only ticked room: it stays (leaving Sonos is on the start screen).
    let onlyTicked: Bool
    /// "Use" was tapped: the dialog asks first.
    @State private var takingOver: String?

    var body: some View {
        let ticked = model.isSonosRoomTicked(room.id)
        let joining = model.sonosJoining.contains(room.id)
        let reading = model.sonos.readings[room.id]
        let status = model.sonosStatus(of: room, live: true)
        // Another zone's: "Use" (asked first; it joins this group), never a tick.
        let offersUse = status.isInUse && !ticked
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if offersUse {
                    takingOver = room.id
                    return
                }
                // The last room stays; only its tick is dimmed (not the whole row, as disabling would).
                guard !onlyTicked, ticked || status.canTick else { return }
                model.toggleSonosRoom(room.id)
            } label: {
                HStack(spacing: 12) {
                    SonosRoomIcon(model: room.displayName, ticked: ticked)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.roomName).font(.subheadline.weight(.semibold))
                        SonosStatusText(status: status)
                    }
                    Spacer(minLength: 8)
                    if offersUse {
                        SonosUseLabel()
                    } else {
                        SonosCheck(ticked: ticked, joining: joining)
                            .opacity(onlyTicked ? 0.55 : 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .sonosTakeoverDialog(for: room.id, asking: $takingOver)
            .buttonStyle(.plain)
            .disabled(status == .notResponding)
            .opacity(status == .notResponding ? 0.45 : 1)
            .accessibilityAddTraits(ticked ? .isSelected : [])
            .accessibilityHint(onlyTicked ? "The last speaker stays. To stop playing on Sonos, use the start screen." : "")
            if ticked, let volume = reading?.volume {
                VolumeSlider(value: volume) { model.setSonosVolume($0, room: room.id) }
                    .padding(.leading, 40)
                    .accessibilityLabel("\(room.roomName) volume")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

/// All Speakers: the ticked rooms' volume together (their average), each moved in proportion.
private struct GroupVolume: View {
    @Environment(AppModel.self) private var model
    let rooms: [SonosPlayer]
    /// The rooms' volumes when the drag began, for showing them move in proportion meanwhile.
    @State private var snapshot: [String: Int] = [:]

    private var average: Int? {
        let volumes = rooms.compactMap { model.sonos.readings[$0.id]?.volume }
        guard !volumes.isEmpty else { return nil }
        return Int((Double(volumes.reduce(0, +)) / Double(volumes.count)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All Speakers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let average {
                VolumeSlider(value: average, onBegin: {
                    snapshot = Dictionary(uniqueKeysWithValues: rooms.compactMap { room in model.sonos.readings[room.id]?.volume.map { (room.id, $0) } })
                    model.beginSonosGroupVolume()
                }, onChanging: { value in
                    // Shown at once, as Sonos will set them.
                    let base = Double(snapshot.values.reduce(0, +)) / Double(max(1, snapshot.count))
                    for (id, volume) in snapshot {
                        model.sonos.noteVolume(min(100, max(0, base > 0 ? Int((Double(volume) * Double(value) / base).rounded()) : value)), for: id)
                    }
                }) { model.setSonosGroupVolume($0) }
                .accessibilityLabel("All speakers volume")
            }
        }
        // With the panel's 10 outside, its label and slider line up with the rooms' (18 in).
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// A volume slider that sends to Sonos as it moves, at most every 150 ms (the latest value),
/// and the final value on release. While it's held, readings from the speakers don't move it.
private struct VolumeSlider: View {
    let value: Int
    var onBegin: () -> Void = {}
    var onChanging: (Int) -> Void = { _ in }
    let send: (Int) -> Void

    @State private var dragging: Double?
    @State private var throttle = Throttle(interval: .milliseconds(150))

    /// The system's own slider, drawn as it draws volume (Control Center, AirPlay, Now Playing):
    /// thumbless, the track itself dragged, with the quiet and loud speakers at its ends.
    var body: some View {
        Slider(value: Binding(get: { dragging ?? Double(value) }, set: { new in
            dragging = new
            let volume = Int(new.rounded())
            onChanging(volume)
            throttle.submit(volume, send: send)
        }), in: 0...100) {
            Text("Volume")
        } minimumValueLabel: {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        } onEditingChanged: { editing in
            if editing {
                dragging = Double(value)
                onBegin()
            } else {
                if let dragging { throttle.finish(Int(dragging.rounded()), send: send) }
                dragging = nil
            }
        }
        .sliderThumbVisibility(.hidden)
        .font(.footnote)
    }
}

/// Sends the latest value at most every `interval`; `finish` sends the last one at once.
@MainActor
final class Throttle {
    private let interval: Duration
    private var lastSent: ContinuousClock.Instant?
    private var pending: Int?
    private var timer: Task<Void, Never>?

    init(interval: Duration) {
        self.interval = interval
    }

    func submit(_ value: Int, send: @escaping (Int) -> Void) {
        let now = ContinuousClock.now
        if let lastSent, now - lastSent < interval {
            pending = value
            guard timer == nil else { return }
            let wait = interval - (now - lastSent)
            timer = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.timer = nil
                if let pending = self.pending {
                    self.pending = nil
                    self.lastSent = .now
                    send(pending)
                }
            }
        } else {
            lastSent = now
            send(value)
        }
    }

    func finish(_ value: Int, send: (Int) -> Void) {
        timer?.cancel()
        timer = nil
        pending = nil
        lastSent = .now
        send(value)
    }
}
