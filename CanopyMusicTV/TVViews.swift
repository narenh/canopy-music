import CanopyMusicCore
import CanopyMusicServer
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct TVRootView: View {
    @Environment(TVModel.self) private var model
    @State private var confirming = false
    /// Menu › End once songs guests added have played: the sheet that saves them first.
    @State private var endingWithSave = false
    @State private var easterEgg = LyricsEasterEgg()
    /// The song the party screen shows, while it's there (`TVShownSongKey`).
    @State private var partySong: TVShownSong?

    /// `-capture` (debug builds, as on the iPad): screenshots for the App Store and the README,
    /// so the lyrics takeover never shows in them.
    private static var capturing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-capture")
        #else
        false
        #endif
    }

    /// At a zone (hub, or display following its hub's setting): see `PartySession.tvKeepsScreenAwake`.
    private var keepsScreenAwake: Bool {
        model.role != .choosing && model.session.tvKeepsScreenAwake
    }

    var body: some View {
        let current = model.session.state.current
        // The same takeover as the iPad's, as a hub or a display (a display's time comes from
        // its hub's snapshots).
        let takeover = model.role == .choosing || Self.capturing ? nil : easterEgg.takeover(for: current)
        // The party screen's song while it's showing, which changes as its slide starts.
        let backgroundItem = partySong.map(\.item) ?? current
        ZStack {
            TVBackground(track: backgroundItem?.track, theme: ArtworkTheme(backgroundItem?.track.colors))
                // Changes evenly to the new song's, starting with the party screen's slide and
                // settling after it (`TVPartyView.showCurrent`).
                .animation(.linear(duration: 3), value: backgroundItem?.id)
            switch model.role {
            case .choosing:
                TVZoneListView()
                    .transition(.opacity)
            case .hub:
                // Straight to the party once a host has picked the music.
                if model.session.isWaitingForSetup {
                    TVStartView().transition(.opacity)
                } else {
                    TVPartyView().transition(.opacity)
                }
            case .display:
                TVPartyView()
                    // Blurred behind the connection message so it reads.
                    .blur(radius: model.isWaitingForHub ? 28 : 0)
                    .overlay { TVConnectionOverlay() }
                    .animation(.easeInOut(duration: 0.4), value: model.isWaitingForHub)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.role)
        .onPreferenceChange(TVShownSongKey.self) { partySong = $0 }
        // A zone (hub or display) keeps the screen awake while music plays, unless its hub allows
        // the screensaver then too; paused, and at the zone list, tvOS's screensaver takes over.
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
            model.debugLog("idle timer \(awake ? "off: stays awake" : "on: screensaver allowed")")
        }
        .onChange(of: current?.id) { model.advertise() }
        // A hub's zone is announced once a host has picked the music.
        .onChange(of: model.session.isWaitingForSetup) { model.advertise() }
        .overlay {
            if let (item, lines) = takeover {
                TakeoverView(lines: lines, track: item.track, session: model.session, scale: 1.4) {
                    easterEgg.dismissedItemID = item.id
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: takeover?.item.id)
        .task(id: current?.id) {
            if let current, easterEgg.matches(current.track) { await easterEgg.loadIfNeeded() }
        }
        // Menu: closes the takeover while it's showing (for this play, as press and hold does on
        // the iPad); otherwise a hub can only end its zone and a display can only leave.
        .onExitCommand(perform: model.role == .choosing ? nil : {
            if let (item, lines) = takeover, TakeoverView.isShowing(lines, at: model.session.engine.currentTime) {
                easterEgg.dismissedItemID = item.id
            } else if model.canSaveParty {
                endingWithSave = true
            } else {
                confirming = true
            }
        })
        .onPlayPauseCommand(perform: model.role == .choosing ? nil : { model.playPause() })
        // Nothing worth saving yet (or a display leaving): a plain confirmation.
        .confirmationDialog("", isPresented: $confirming, titleVisibility: .hidden) {
            if model.role == .hub {
                Button("End \(model.zoneName)", role: .destructive) { model.stopZone() }
            } else {
                Button("Leave \(model.shownZone?.name ?? "zone")", role: .destructive) { model.leave() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $endingWithSave) { TVEndZoneSheet() }
        #if DEBUG
        // `-confirmEnd`: opens Menu › End 12 s after hosting starts; with `-autoEnd`, presses End
        // 8 s later (the save sheet presses Save and End itself). For the simulator.
        .task(id: model.role) {
            let args = ProcessInfo.processInfo.arguments
            guard model.role == .hub, args.contains("-confirmEnd") else { return }
            try? await Task.sleep(for: .seconds(12))
            if model.canSaveParty { endingWithSave = true; return }
            confirming = true
            guard args.contains("-autoEnd") else { return }
            try? await Task.sleep(for: .seconds(8))
            confirming = false
            model.stopZone()
        }
        #endif
        #if DEBUG
        // `-autoLeave`: leaves a shown zone after 6 s (testing the way back without a remote).
        .task(id: model.role) {
            guard model.role == .display, ProcessInfo.processInfo.arguments.contains("-autoLeave") else { return }
            try? await Task.sleep(for: .seconds(6))
            model.leave()
        }
        // `-autoParty`: a new hub loads the first demo playlist and plays, as if a host had
        // picked it on their phone.
        .task(id: model.role) {
            let session = model.session
            guard model.role == .hub, ProcessInfo.processInfo.arguments.contains("-autoParty"), session.isWaitingForSetup,
                  let first = try? await session.catalog.libraryPlaylists().first else { return }
            try? await session.load(playlist: first)
            try? await session.play()
        }
        #endif
    }

}

// MARK: - Ending the zone

/// Menu › End once someone has added a song (played or still in Up next): saves the songs guests
/// added as a playlist, then ends the zone.
/// The name starts as the party's date and a space; the host can finish it with the Siri Remote,
/// dictation, or the keyboard tvOS offers on a nearby iPhone, or leave it as the date (then it's
/// "<date> <zone>"). Menu cancels.
struct TVEndZoneSheet: View {
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var errorText: String?
    private enum Focus: Hashable { case name, save, end }
    @FocusState private var focus: Focus?

    var body: some View {
        let info = model.session.partySaveInfo
        let songs = info.requestCount == 1 ? "the song a guest added" : "the \(info.requestCount) songs guests added"
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text("End \(model.zoneName)?")
                    .font(.system(size: 52, weight: .bold))
                Text("The music stops and the queue is cleared. Save \(songs) as a playlist first?")
                    .font(.system(size: 29))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Playlist name", text: $name)
                    .focused($focus, equals: .name)
                    .submitLabel(.done)
                if let destination = info.destination {
                    Text(destination + ".")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 30) {
                Button {
                    save()
                } label: {
                    HStack(spacing: 14) {
                        if saving { ProgressView() }
                        Text(saving ? "Saving playlist…" : errorText == nil ? "Save and End" : "Try Again")
                    }
                    .frame(minWidth: 380)
                }
                .focused($focus, equals: .save)
                Button("End Without Saving", role: .destructive) { end() }
                    .focused($focus, equals: .end)
            }
            .disabled(saving)
        }
        .frame(width: 1100, alignment: .leading)
        .padding(70)
        // Starts on Save and End, so a quick press saves under the date and zone; the name field
        // is one swipe up.
        .defaultFocus($focus, .save)
        // Menu cancels (the sheet's own dismissal), except while saving.
        .interactiveDismissDisabled(saving)
        // Play/Pause would otherwise act on the focused button here; the music keeps its state.
        .onPlayPauseCommand {}
        .onAppear { name = info.suggestedName }
        #if DEBUG
        // `-partyName <text>`: types the rest of the name. `-autoEnd`: presses Save and End 8 s
        // after the sheet opens (with `-failSave`, the demo library fails it). `-focusEnd`: focuses
        // End Without Saving after 2 s (and again 3 s after a failed save). For the simulator.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-partyName"), i + 1 < args.count { name += args[i + 1] }
            if args.contains("-focusEnd") {
                try? await Task.sleep(for: .seconds(2))
                focus = .end
            }
            guard args.contains("-autoEnd") else { return }
            try? await Task.sleep(for: .seconds(8))
            save()
            guard args.contains("-focusEnd") else { return }
            try? await Task.sleep(for: .seconds(3))
            focus = .end
        }
        #endif
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorText = nil
        Task {
            do {
                try await model.saveParty(typedName: name)
                saving = false
                end()
            } catch {
                saving = false
                errorText = "Couldn't save the playlist. \(error.localizedDescription)"
                focus = .save
            }
        }
    }

    private func end() {
        dismiss()
        model.stopZone()
    }
}

private extension View {
    /// The remote's Menu and Play/Pause only reach the app while something has focus, and the
    /// party and start screens have nothing to focus; without this, Menu leaves the app. Put it on
    /// one piece of text per screen: it looks the same, it just holds focus.
    func holdsRemoteFocus() -> some View {
        focusable().focusEffectDisabled()
    }
}

// MARK: - Zone list

/// Every launch starts here (docs/multi-device.md).
struct TVZoneListView: View {
    #if DEBUG
    @MainActor static var didAutoShow = false
    @MainActor static var didAutoCreate = false
    #endif
    @Environment(TVModel.self) private var model
    /// A zone's id, "resume" or "create".
    @FocusState private var focused: String?
    /// "Create a new zone" while this TV still has a zone: it would end it, so ask first.
    @State private var confirmingCreate = false

    /// Where focus starts: this TV's own zone, else the first zone (joining is the usual case).
    private func firstFocus(_ zones: [ZoneListing]) -> String {
        model.canResumeZone ? "resume" : zones.first?.id ?? "create"
    }

    var body: some View {
        let zones = model.browser.zones.filter { $0.hubID != model.deviceID }
        VStack(spacing: 34) {
            Image("CanopyLogo").resizable().scaledToFit().frame(height: 70)
            VStack(spacing: 16) {
                // This TV's own zone from last time comes first.
                if model.canResumeZone {
                    Button {
                        Task { await model.resumeZone() }
                    } label: {
                        TVZoneRow(icon: "tv", title: model.zoneName, subtitle: "Resume on this TV")
                    }
                    .focused($focused, equals: "resume")
                }
                ForEach(zones) { zone in
                    Button {
                        model.show(zone)
                    } label: {
                        TVZoneRow(
                            icon: zone.kind == .tv ? "tv" : "ipad.landscape",
                            // The icon says what kind of device it is.
                            title: zone.name,
                            subtitle: zone.nowPlaying.map { "Playing \($0)" }
                        )
                    }
                    .focused($focused, equals: zone.id)
                }
                Button {
                    if model.canResumeZone { confirmingCreate = true } else { Task { await model.createZone() } }
                } label: {
                    TVZoneRow(icon: "plus", title: "Create a new zone", subtitle: "Music plays from this TV")
                }
                .focused($focused, equals: "create")
            }
            .frame(width: 900)
            if model.authorizationDenied {
                Text("Canopy Music needs Apple Music access to play here. Turn it on in Settings › Apps › Canopy Music.")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                    .frame(width: 900)
            }
        }
        // No forced white here: a focused button turns light and needs its dark text.
        .onAppear { model.browser.start() }
        // Coming back from a zone, focus doesn't find its way here by itself.
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            if focused == nil { focused = firstFocus(zones) }
        }
        // Joining is the usual case (a second zone in one house is rare), so start on the first
        // zone. Zones turn up a moment after launch, when focus is already on Create.
        .defaultFocus($focused, firstFocus(zones))
        .onChange(of: zones.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty, focused == "create" || focused == nil { focused = firstFocus(zones) }
        }
        .confirmationDialog("This ends \(model.zoneName) and clears its queue.", isPresented: $confirmingCreate, titleVisibility: .visible) {
            Button("Create a new zone", role: .destructive) { Task { await model.createZone() } }
            Button("Cancel", role: .cancel) {}
        }
        #if DEBUG
        // `-createZone` / `-showZone <name>`: act without the remote, for the simulator. Once per
        // launch, so ending the zone comes back to this list.
        .task {
            guard !Self.didAutoCreate, ProcessInfo.processInfo.arguments.contains("-createZone") else { return }
            Self.didAutoCreate = true
            await model.createZone()
        }
        // `-confirmCreate`: asks before creating over this TV's zone; with `-autoCreate`, presses
        // Create 8 s later.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard !Self.didAutoCreate, args.contains("-confirmCreate"), model.canResumeZone else { return }
            Self.didAutoCreate = true
            confirmingCreate = true
            guard args.contains("-autoCreate") else { return }
            try? await Task.sleep(for: .seconds(8))
            confirmingCreate = false
            await model.createZone()
        }
        .onChange(of: zones.map(\.id), initial: true) {
            let args = ProcessInfo.processInfo.arguments
            guard !Self.didAutoShow, let i = args.firstIndex(of: "-showZone"), i + 1 < args.count,
                  let zone = zones.first(where: { $0.name == args[i + 1] }) else { return }
            Self.didAutoShow = true
            model.show(zone)
        }
        #endif
    }
}

private struct TVZoneRow: View {
    let icon: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 32, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 22)).opacity(0.65).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Which zone a display is showing.
struct TVZoneBadge: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        if let zone = model.shownZone {
            // Plain text, not a capsule, so it can't be mistaken for a requester pill.
            HStack(spacing: 12) {
                Image(systemName: zone.kind == .tv ? "tv.fill" : "ipad.landscape")
                    .font(.system(size: 22, weight: .medium))
                Text("Playing from \(zone.name)")
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// "Connecting…" until the hub's first update; "Lost connection" if it drops.
struct TVConnectionOverlay: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        if let connection = model.connection, model.isWaitingForHub {
            let name = model.shownZone?.name ?? "the zone"
            ZStack {
                Rectangle().fill(.black.opacity(connection.hasSnapshot ? 0.45 : 0.9)).ignoresSafeArea()
                VStack(spacing: 22) {
                    ProgressView()
                    Text(connection.hasSnapshot ? "Lost connection to \(name)" : "Connecting to \(name)…")
                        .font(.system(size: 40, weight: .bold))
                    if connection.hasSnapshot {
                        Text("Reconnecting. Make sure \(model.shownZone?.kind == .tv ? "the Apple TV is on" : "the iPad is awake") and Canopy Music is open.\nPress Menu to leave.")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .frame(width: 1000)
                    }
                }
                .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Start: take host control

/// TV-led parties start here: the first phone to scan becomes the host (and can add more hosts
/// later from its own page). Once it has, the code goes (its space stays, so the text doesn't
/// move) while they set the zone up on the phone.
struct TVStartView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 28) {
                Image("CanopyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 70)
                Text(model.hostJoined ? "Continue on your phone" : "Scan to host")
                    .font(.system(size: 76, weight: .bold))
                    .holdsRemoteFocus()
                Text("Use your phone to set up this zone. Other devices on this network with Canopy Music can join it.")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 820, alignment: .leading)
            }
            // Big enough to carry a symbol through it (the iPad's Wi‑Fi code does the same).
            Group {
                if model.hostJoined {
                    Color.clear
                } else if let host = model.hostURL?.absoluteString {
                    HalftoneQRCode(payload: host, image: Image("MusicNote"), symbolScale: 0.5, dotScale: 0.7)
                } else {
                    // The server is still starting.
                    ProgressView()
                        .scaleEffect(2)
                }
            }
            .frame(width: 440, height: 440)
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.4), value: model.hostJoined)
    }
}

// MARK: - Party

struct TVPartyView: View {
    @Environment(TVModel.self) private var model
    /// Heights of what's in the now-playing column under the artwork (the song's text and progress,
    /// and a display's zone badge); the artwork takes the rest.
    @State private var songTextHeight: CGFloat = 200
    @State private var badgeHeight: CGFloat = 0
    /// The remote's left and right, one at a time.
    @State private var stepper = RemoteStepper()
    /// The song the now-playing column shows. When the song changes (remote, a phone, or the song
    /// ending) the new song's art and text push the old one's out sideways, like turning a page
    /// (`showCurrent`); the background changes evenly from the same moment, settling after it.
    @State private var shown: QueueItem?
    @State private var started = false
    /// Which way the last slide went: forward brings the new song in from the right.
    @State private var forward = true
    /// When the slide under way finishes.
    @State private var slideEnds: ContinuousClock.Instant?
    /// Width of the now-playing column, edge to edge (the slide's clip).
    @State private var columnWidth: CGFloat = 1000
    static let slide = 0.5
    /// Fast at first, then slowing to a stop: the pages arrive and settle (an ease-out quint).
    static let slideAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: slide)
    /// The logo's visible top and left margin from the screen edges, level with the capitals in
    /// "Up next". The image has 6.5pt of empty space above the arc and 1pt to its left.
    static let logoInset: CGFloat = 71

    var body: some View {
        let session = model.session
        let live = session.state.current
        // The live item while it's the one shown, so its changes (a requester's name) show.
        let current = !started || shown?.id == live?.id ? live : shown
        // The song shown leaves the way the change to the live one goes, so that's set while it's
        // still shown; the song coming in arrives the way `showCurrent` set.
        let goesForward = started && shown?.id != live?.id ? slidesForward(from: shown) : forward
        let footerHeight = songTextHeight + (model.role == .display ? badgeHeight : 0)
        GeometryReader { geo in
            // As big as fits, up to a size that leaves room around the corner logo.
            let art = min(600, max(300, (geo.size.height - footerHeight).rounded(.down)))
            HStack(alignment: .top, spacing: 70) {
                // Now playing.
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        nowPlaying(current, art: art)
                            .id(current?.id)
                            // Far enough that the song going out ends past the screen's left edge
                            // (shadow and all), and the one coming in starts behind Up next.
                            .transition(SongSlide(offset: (columnWidth + 160) * (goesForward ? 1 : -1)))
                    }
                    if model.role == .display {
                        TVZoneBadge()
                            .padding(.top, 24)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { badgeHeight = $0 }
                    }
                }
                .frame(width: art, alignment: .leading)
                // Centered in whatever the sidebar leaves.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { columnWidth = $0 }
                // The slide shows from the screen's left edge to the edge of Up next.
                .mask {
                    Rectangle()
                        .padding(.leading, -300)
                        .padding(.trailing, -70)
                        .padding(.vertical, -300)
                }

                // Up next + how to join.
                VStack(alignment: .leading, spacing: 18) {
                    Text("Up next")
                        .font(.system(size: 44, weight: .bold))
                        .holdsRemoteFocus()
                    // Takes whatever height is left above the join card and fades out at the bottom.
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            // Rows are a fixed height, so show as many as fit (plus one to fade out).
                            ForEach(Array(session.state.upNext.prefix(Int(geo.size.height / TVQueueRow.height) + 1))) { item in
                                TVQueueRow(item: item)
                            }
                        }
                        .animation(.easeInOut(duration: 0.4), value: session.state.upNext.map(\.id))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                    }
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                        }
                    }
                    // Hidden while the host has queueing from phones off, and while there's no server
                    // to scan to (starting, restarting after the background, or failed).
                    if session.phonesCanQueue, model.shownGuestURL != nil {
                        TVJoinCard()
                    }
                }
                .frame(width: 660)
                .padding(.leading, 56)
                .frame(maxHeight: .infinity)
                // A sidebar running off the top, bottom and right edges.
                .background {
                    Color.black.opacity(0.22).ignoresSafeArea(edges: [.top, .bottom, .trailing])
                }
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            Image("CanopyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 46)
                .padding(.top, Self.logoInset - 6.5)
                .padding(.leading, Self.logoInset - 1)
                .ignoresSafeArea()
        }
        // Left and right on the remote: previous and skip. They reach here through "Up next",
        // which holds focus (it's the only focusable view, so they can't move focus instead).
        .onMoveCommand(perform: move)
        // A newer change cancels this one part way, and `showCurrent` goes on to the newest song.
        .task(id: model.session.state.current?.id) { await showCurrent() }
        .preference(key: TVShownSongKey.self, value: TVShownSong(item: current))
        #if DEBUG
        // `-autoStep`: 6 s after the party shows, presses right three times at once, then left
        // 2 s later (simctl can't press the remote's buttons). Only the first right should go,
        // and the left goes back to the song before.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-autoStep") else { return }
            try? await Task.sleep(for: .seconds(6))
            move(.right)
            move(.right)
            move(.left)
            try? await Task.sleep(for: .seconds(2))
            move(.left)
        }
        #endif
    }

    /// The song's art, title, artist line and progress: one page of the slide.
    private func nowPlaying(_ item: QueueItem?, art: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TVArtwork(track: item?.track, cornerRadius: 22)
                // Its video, if it has one, goes with this page (`TVMotionArtworkView`).
                .overlay { TVMotionArtworkView(track: item?.track, catalog: model.session.catalog, isPlaying: model.session.isPlaying, cornerRadius: 22) }
                .frame(width: art, height: art)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
            VStack(alignment: .leading, spacing: 0) {
                // Long titles shrink before they truncate, on the same baseline in a
                // full-size line, so the art's size and everything's position never change.
                Text(verbatim: " ")
                    .font(.system(size: 56, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .overlay(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {
                        Text(item?.track.title ?? "Nothing playing")
                            .font(.system(size: 56, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                // Who requested it shares the artist line, as on the iPad.
                HStack(spacing: 16) {
                    Text(item?.track.artist ?? " ")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    if let requester = item?.requester {
                        TVRequesterPill(requester: requester).fixedSize()
                    }
                }
                .padding(.bottom, 26)
                TVProgress(session: model.session, itemID: item?.id, duration: item?.track.duration ?? 0)
            }
            .padding(.top, 34)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { songTextHeight = $0 }
        }
        .frame(width: art, alignment: .leading)
    }

    /// Whether going from `item` to the session's current song is a step forward. Going back puts
    /// the song that was playing at the top of Up next; anything else (a skip, the song ending, a
    /// jump in the queue) counts as forward.
    private func slidesForward(from item: QueueItem?) -> Bool {
        guard let item else { return true }
        return model.session.state.upNext.first?.id != item.id
    }

    /// Slides from the shown song to the session's current one. A change during a slide waits for
    /// it to finish (a moment), then slides once straight to the newest song: never two slides at
    /// once, and songs skipped past in between never show.
    private func showCurrent() async {
        let session = model.session
        guard started else {
            shown = session.state.current
            started = true
            return
        }
        if let slideEnds {
            do { try await Task.sleep(until: slideEnds, clock: .continuous) } catch { return }
        }
        guard shown?.id != session.state.current?.id else { return }
        // The new song's art is loaded before it slides in (Up next has usually loaded it
        // already); after a moment it slides anyway, and the art shows when it's loaded.
        if let url = TVArtwork.url(for: session.state.current?.track) {
            let start = ContinuousClock.now
            let ready = await TVArtworkCache.shared.ready(url, within: .milliseconds(300))
            model.debugLog("artwork \(ready ? "ready" : "not ready") after \(ContinuousClock.now - start)")
            if Task.isCancelled { return }
        }
        let goingForward = slidesForward(from: shown)
        slideEnds = .now + .seconds(Self.slide)
        // Both pages move in this one animation, so they stay together.
        withAnimation(Self.slideAnimation) {
            forward = goingForward
            shown = session.state.current
        }
    }

    /// Previous or skip, as the back and skip buttons elsewhere; ignored while one is still going,
    /// and on a display while its hub doesn't let displays control playback (`RemoteStepper`).
    private func move(_ direction: MoveCommandDirection) {
        guard direction == .left || direction == .right else { return }
        let forward = direction == .right
        let session = model.session
        Task {
            let went = await stepper.step(session, forward: forward)
            model.debugLog("remote \(forward ? "right" : "left"): \(went ? "now \(session.state.current?.track.title ?? "-")" : "ignored")")
        }
    }
}

/// The song the party screen shows (its `nil` is "Nothing playing"), for the background to follow.
struct TVShownSong: Equatable {
    let item: QueueItem?
}

/// Set by the party screen; nil while it isn't showing.
struct TVShownSongKey: PreferenceKey {
    static let defaultValue: TVShownSong? = nil

    static func reduce(value: inout TVShownSong?, nextValue: () -> TVShownSong?) {
        value = value ?? nextValue()
    }
}

/// The now-playing page turn: the new song comes in from `offset` (right when it's positive)
/// while the old one goes out the other way, the same distance.
private struct SongSlide: Transition {
    let offset: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.offset(x: phase == .willAppear ? offset : phase == .didDisappear ? -offset : 0)
    }
}

struct TVQueueRow: View {
    let item: QueueItem
    static let height: CGFloat = 70

    var body: some View {
        HStack(spacing: 18) {
            TVArtwork(track: item.track, cornerRadius: 8)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(.system(size: 26, weight: .medium))
                Text(item.track.artist)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            if let requester = item.requester {
                TVRequesterPill(requester: requester)
            }
        }
        .frame(height: Self.height)
    }
}

/// Who requested a song (the iPad's RequesterPill at TV size).
struct TVRequesterPill: View {
    let requester: Requester

    var body: some View {
        HStack(spacing: 7) {
            if requester.origin == .phone {
                Image(systemName: "iphone").font(.system(size: 16, weight: .semibold))
            }
            Text(requester.name ?? (requester.origin == .phone ? "Guest" : "iPad"))
                .lineLimit(1)
        }
        .font(.system(size: 19, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .foregroundStyle(.white.opacity(0.8))
        .background(.white.opacity(0.16), in: Capsule())
    }
}

struct TVJoinCard: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 24) {
            TVQRCode(payload: model.shownGuestURL?.absoluteString)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text("Queue from your phone")
                    .font(.system(size: 30, weight: .bold))
                Text("Scan with your camera, or go to")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                // Long zone names make long addresses (it follows the zone name); shrink like the iPad's.
                Text(Self.display(model.shownFriendlyURL ?? model.shownGuestURL))
                    .font(.system(size: 25, weight: .semibold).monospaced())
                    .minimumScaleFactor(0.7)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let wifi = model.wifiPayload {
                // Same as the iPad's: the Wi‑Fi symbol says what it is, unless the host chose a plain
                // code for phones that struggle with it.
                if model.session.wifi.simpleQR {
                    VStack(spacing: 6) {
                        QRCodeView(payload: wifi, inverted: true)
                            .frame(width: 74, height: 74)
                            .opacity(0.75)
                        Text("Join Wi\u{2011}Fi")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    HalftoneQRCode(payload: wifi, symbol: "wifi", symbolScale: 0.6, dotScale: 0.7)
                        .frame(width: 88, height: 88)
                        .opacity(0.75)
                }
            }
        }
        .padding(22)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
}

struct TVProgress: View {
    let session: PartySession
    /// The song shown, which can still be the last one while it slides out (the engine has moved
    /// on): its bar holds where it was, and the next song's starts from its own time.
    let itemID: QueueItem.ID?
    let duration: TimeInterval
    @State private var held = HeldTime()

    private final class HeldTime {
        var time: TimeInterval = 0

        func show(_ live: TimeInterval?) -> TimeInterval {
            if let live { time = live }
            return time
        }
    }

    var body: some View {
        // Every frame while playing so the bar grows smoothly (a seek just jumps); twice a second
        // while paused, to catch seeks.
        TimelineView(.animation(minimumInterval: session.isPlaying ? nil : 0.5)) { _ in
            let live = itemID == session.state.current?.id
            let time = held.show(live ? min(session.engine.currentTime, duration) : nil)
            VStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: duration > 0 ? geo.size.width * time / duration : 0)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(Self.format(time))
                    Spacer()
                    Text("-" + Self.format(max(duration - time, 0)))
                }
                .font(.system(size: 22).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Shared pieces (TV copies of the iPad app's)

struct TVArtwork: View {
    let track: QueueTrack?
    var cornerRadius: CGFloat = 8

    /// The image a track shows.
    static func url(for track: QueueTrack?) -> URL? {
        #if DEBUG
        // `-demoArtworkURLs`: demo tracks (which have none) get a remote image each, to try the
        // artwork's loading in the simulator.
        if track?.artworkURL == nil, track?.thumbnailURL == nil, let id = track?.id,
           ProcessInfo.processInfo.arguments.contains("-demoArtworkURLs") {
            return URL(string: "https://picsum.photos/seed/\(id)/600")
        }
        #endif
        return track?.artworkURL ?? track?.thumbnailURL
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    track?.colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                    track?.colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // In an overlay so a filled image can't grow the view past the size it's given.
            Color.clear.overlay {
                if let url = Self.url(for: track) {
                    TVArtworkImage(url: url).id(url)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Artwork from `TVArtworkCache`: an image already loaded shows from the first frame (so a page
/// sliding in or out has its real art), and one that isn't loads and then shows.
private struct TVArtworkImage: View {
    let url: URL
    @State private var loaded: UIImage?

    var body: some View {
        if let image = loaded ?? TVArtworkCache.shared.image(for: url) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.clear.task { loaded = await TVArtworkCache.shared.load(url) }
        }
    }
}

/// Decoded artwork in memory, by URL, shared by every artwork on the TV (the party screen loads
/// a song's before sliding to it, and Up next's rows load the songs coming up).
@MainActor
final class TVArtworkCache {
    static let shared = TVArtworkCache()
    private let images = NSCache<NSURL, UIImage>()
    private let blurredImages = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 80
        blurredImages.countLimit = 80
    }

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    /// The background's blurred copy of the image at `url` (`blurred(_:)`), once it's loaded.
    func blurredImage(for url: URL) -> UIImage? {
        blurredImages.object(forKey: url as NSURL)
    }

    /// The image at `url`, loaded and decoded (and its blurred copy made) once however many ask;
    /// nil if it fails.
    func load(_ url: URL) async -> UIImage? {
        if let image = image(for: url) { return image }
        if let task = loading[url] { return await task.value }
        // The task caches what it made before anyone waiting on it carries on.
        let task = Task<UIImage?, Never> {
            defer { loading[url] = nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = await UIImage(data: data)?.byPreparingForDisplay() else { return nil }
            let blurred = await Task.detached(priority: .userInitiated) { Self.blurred(image) }.value
            images.setObject(image, forKey: url as NSURL)
            if let blurred { blurredImages.setObject(blurred, forKey: url as NSURL) }
            return image
        }
        loading[url] = task
        return await task.value
    }

    /// Side of the background's blurred copy: blurred this much, it looks the same drawn
    /// screen-size as the full image blurred there, and the background never blurs per frame.
    nonisolated static let blurSide: CGFloat = 64
    nonisolated private static let context = CIContext()
    /// The background's art: `image` shrunk to `blurSide` square, blurred to look like the full
    /// image under SwiftUI's `blur(radius: 120)` across a 1920-point screen (Core Image's radius
    /// needs about 1.5× that to match, side by side), and saturated 1.4×.
    nonisolated static func blurred(_ image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: blurSide, height: blurSide)
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let input = CIImage(image: small) else { return nil }
        let blur = CIFilter.gaussianBlur()
        // Clamped so the edges don't fade: they're off screen in the original too.
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(180 * blurSide / 1920)
        let color = CIFilter.colorControls()
        color.inputImage = blur.outputImage?.cropped(to: input.extent)
        color.saturation = 1.4
        color.brightness = 0
        color.contrast = 1
        guard let output = color.outputImage,
              let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Waits until the image at `url` is ready, or `limit` has passed (it keeps loading then).
    /// Returns whether it's ready.
    func ready(_ url: URL, within limit: Duration) async -> Bool {
        if image(for: url) != nil { return true }
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { @MainActor in
                _ = await self.load(url)
                once.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume()
            }
        }
        return image(for: url) != nil
    }

    /// Resumes a wait once, whichever finishes first.
    @MainActor private final class Once {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

struct TVBackground: View {
    let track: QueueTrack?
    let theme: ArtworkTheme

    var body: some View {
        ZStack {
            // The base colour animates from song to song; the blurred art cross-fades over it
            // while it drifts (one drift for every song, so a change doesn't jolt it), and the
            // shade cross-fades over that, still.
            Rectangle().fill(theme.base)
            TVDrift {
                TVBlurredArt(track: track)
                    .opacity(0.5)
                    .id(track?.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [theme.base.opacity(0.1), theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .id(track?.id)
                .transition(.opacity)
        }
        .ignoresSafeArea()
    }
}

/// A song's art for the background, blurred once (`TVArtworkCache.blurred`), then drawn as big
/// as the screen's width. Before it's loaded, or with no art, its colours' gradient.
private struct TVBlurredArt: View {
    let track: QueueTrack?
    @State private var loaded: UIImage?

    var body: some View {
        let url = TVArtwork.url(for: track)
        if let image = loaded ?? url.flatMap({ TVArtworkCache.shared.blurredImage(for: $0) }) {
            // Square art, as wide as the screen: taller than it, so drifting never shows an edge.
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [
                    track?.colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                    track?.colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .saturation(1.4)
            .task(id: url) {
                guard let url else { return }
                _ = await TVArtworkCache.shared.load(url)
                loaded = TVArtworkCache.shared.blurredImage(for: url)
            }
        }
    }
}

/// The background art's slow drift: scale, offset and rotation each follow two or three sines
/// with periods of 40–90 s that never line up, so it doesn't visibly repeat. It keeps going
/// while paused and through song changes; Reduce Motion stops it.
private struct TVDrift<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far it drifts: 1 normally. Debug builds: `-driftStrength <multiplier>` (0 is off).
    private static var strength: Double {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-driftStrength"), i + 1 < args.count, let value = Double(args[i + 1]) {
            return max(0, value)
        }
        #endif
        return 1
    }

    var body: some View {
        let strength = reduceMotion ? 0 : Self.strength
        GeometryReader { geo in
            // 30 frames a second is smooth at these speeds (a few points a second).
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: strength == 0)) { timeline in
                let pose = Self.pose(at: timeline.date.timeIntervalSinceReferenceDate, strength: strength, size: geo.size)
                content
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.degrees))
                    .offset(pose.offset)
            }
        }
    }

    private struct Pose {
        var scale: CGFloat
        var degrees: Double
        var offset: CGSize
    }

    private static func wave(_ t: Double, _ terms: [(amplitude: Double, period: Double, phase: Double)]) -> Double {
        terms.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * t / $1.period + $1.phase) }
    }

    /// At strength 1 (8× the first, too-subtle tuning, chosen on a real TV): scale about 1.3 ± 0.6
    /// (never small enough to show an edge), up to about 29% of the screen off centre, and up to
    /// 16° turned. The blur hides small moves, so it takes this much to read as drifting.
    private static func pose(at t: Double, strength s: Double, size: CGSize) -> Pose {
        let dx = s * size.width * wave(t, [(0.144, 47, 0.3), (0.096, 79, 2.1), (0.048, 61, 4.0)])
        let dy = s * size.height * wave(t, [(0.144, 59, 1.2), (0.096, 89, 3.4), (0.048, 43, 5.1)])
        let degrees = s * wave(t, [(9.6, 67, 0.7), (6.4, 41, 2.9)])
        var scale = 1.3 + s * wave(t, [(0.36, 53, 1.9), (0.24, 83, 0.4)])
        // Never so small that the art's left or right edge shows (it's square, as wide as the
        // screen, so top and bottom have room to spare).
        let turn = abs(sin(degrees * .pi / 180))
        let needed = 1 + 2 * (abs(dx) + turn * size.width / 2) / size.width
        scale = max(scale, needed)
        return Pose(scale: scale, degrees: degrees, offset: CGSize(width: dx, height: dy))
    }
}

struct TVQRCode: View {
    let payload: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
            if let payload {
                QRCodeView(payload: payload)
                    .padding(14)
            } else {
                ProgressView().tint(.black)
            }
        }
    }
}
