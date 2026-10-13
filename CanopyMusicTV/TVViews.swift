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
        // What's actually playing (a Spotify hub's can be a track from outside its queue).
        let current = model.session.nowPlaying
        // The same takeover as the iPad's, as a hub or a display (a display's time comes from
        // its hub's snapshots).
        let takeover = model.role == .choosing || Self.capturing ? nil : easterEgg.takeover(for: current)
        // The party screen's song while it's showing, which changes as its slide starts.
        let backgroundItem = partySong.map(\.item) ?? current
        ZStack {
            ArtworkBackground(
                track: backgroundItem?.track, artworkURL: ArtworkURL.url(for: backgroundItem?.track, large: true),
                theme: ArtworkTheme(backgroundItem?.track.colors), source: ArtworkCache.shared, colorsUntilLoaded: true
            )
                // Changes evenly to the new song's, starting with the party screen's slide and
                // settling after it (`TVPartyView.showCurrent`).
                .animation(.linear(duration: 2), value: backgroundItem?.id)
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
        // Unnamed requests from a Mac hub are labelled with the kind of Mac, not "iPad".
        .environment(\.hubDeviceNoun, MacKind(wire: model.session.hubDevice)?.noun ?? "iPad")
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
                            icon: DeviceSymbol.name(kind: zone.kind, device: zone.device),
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
                Image(systemName: zone.kind == .tv ? "tv.fill" : DeviceSymbol.name(kind: zone.kind, device: zone.device))
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
                        let hub = model.shownZone.map { $0.kind == .tv ? "the Apple TV is on" : "the \(MacKind(wire: $0.device)?.noun ?? "iPad") is awake" } ?? "the hub is awake"
                        Text("Reconnecting. Make sure \(hub) and Canopy Music is open.\nPress Menu to leave.")
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
    /// The Now Playing art's side as laid out, for the size its images are decoded at.
    @State private var artSide: CGFloat = 600
    @Environment(\.displayScale) private var displayScale
    static let slide = 0.5
    /// Fast at first, then slowing to a stop: the pages arrive and settle (an ease-out quint).
    static let slideAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: slide)
    /// The logo's visible top and left margin from the screen edges, level with the capitals in
    /// "Up next". The image has 6.5pt of empty space above the arc and 1pt to its left.
    static let logoInset: CGFloat = 71

    var body: some View {
        let session = model.session
        // What's actually playing: a Spotify hub's can be a track from outside its queue.
        let live = session.nowPlaying
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
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { artSide = $0 }
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
                    // A Spotify hub's next song couldn't be queued on Spotify (quiet, for the host).
                    if let issue = session.playerIssue {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    // Takes whatever height is left above the join card and fades out at the bottom.
                    GeometryReader { geo in
                        // Songs in Spotify's own queue (a Spotify hub's) play first, so they're
                        // listed first; they have no requester.
                        let items = session.foreignUpcoming + session.state.upNext
                        VStack(spacing: 0) {
                            // Rows are a fixed height, so show as many as fit (plus one to fade out).
                            ForEach(Array(items.prefix(Int(geo.size.height / TVQueueRow.height) + 1))) { item in
                                TVQueueRow(item: item)
                            }
                        }
                        .animation(.easeInOut(duration: 0.4), value: items.map(\.id))
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
        .task(id: model.session.nowPlaying?.id) { await showCurrent() }
        // The next song or two's art at Now Playing size, loaded ahead so the slide to it has it
        // (`showCurrent` waits only a moment). Just those: every row's would cost as much again
        // as the whole list of rows many times over, and most of them get skipped or reordered.
        .task(id: prewarm) { ArtworkCache.shared.prewarm(prewarm.urls, bucket: prewarm.bucket) }
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

    /// The size bucket the Now Playing art decodes at (`ArtworkImage` works out the same from its frame).
    private var artBucket: Int {
        ArtworkSizing.bucket(points: Double(artSide), scale: Double(displayScale))
    }

    private struct Prewarm: Equatable {
        let urls: [URL]
        let bucket: Int
    }

    /// The first two Up next songs' big images, at the Now Playing size.
    private var prewarm: Prewarm {
        Prewarm(urls: model.session.state.upNext.prefix(2).compactMap { ArtworkURL.url(for: $0.track, large: true) }, bucket: artBucket)
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
                    } else if let item, item.id == model.session.externalCurrent?.id {
                        // Not from the queue: someone else on the hub's Spotify account chose it.
                        Text("From \(model.session.serviceName ?? "Spotify")")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .fixedSize()
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
            shown = session.nowPlaying
            started = true
            return
        }
        if let slideEnds {
            do { try await Task.sleep(until: slideEnds, clock: .continuous) } catch { return }
        }
        guard shown?.id != session.nowPlaying?.id else { return }
        // The new song's art is loaded before it slides in (the pre-warm of the next songs' has
        // usually loaded it already); after a moment it slides anyway, and the art shows when
        // it's loaded.
        if let url = ArtworkURL.url(for: session.nowPlaying?.track, large: true) {
            let start = ContinuousClock.now
            let ready = await ArtworkCache.shared.ready(url, bucket: artBucket, within: .milliseconds(300))
            model.debugLog("artwork \(ready ? "ready" : "not ready") after \(ContinuousClock.now - start) (\(artBucket) px)")
            if Task.isCancelled { return }
        }
        let goingForward = slidesForward(from: shown)
        slideEnds = .now + .seconds(Self.slide)
        // Both pages move in this one animation, so they stay together.
        withAnimation(Self.slideAnimation) {
            forward = goingForward
            shown = session.nowPlaying
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
            TVArtwork(track: item.track, large: false, cornerRadius: 8)
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

extension EnvironmentValues {
    /// What an unnamed request from the hub itself is labelled: "iPad", or the kind of Mac the
    /// hub is when its snapshots say (`PartySession.hubDevice`). Set at the root.
    @Entry var hubDeviceNoun: String = "iPad"
}

/// Who requested a song (the iPad's RequesterPill at TV size).
struct TVRequesterPill: View {
    let requester: Requester
    @Environment(\.hubDeviceNoun) private var hubDeviceNoun

    var body: some View {
        HStack(spacing: 7) {
            if requester.origin == .phone {
                Image(systemName: "iphone").font(.system(size: 16, weight: .semibold))
            }
            Text(requester.name ?? (requester.origin == .phone ? "Guest" : hubDeviceNoun))
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
            let live = itemID == session.nowPlaying?.id
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
    /// Now Playing shows the big image; a row shows the thumbnail (`ArtworkURL`).
    var large = true
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    track?.colors.flatMap { Color(hex: $0.background) } ?? .white.opacity(0.1),
                    track?.colors.flatMap { Color(hex: $0.secondary) } ?? .white.opacity(0.18),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Decoded at the size it's drawn, from `ArtworkCache` (shared with the iPad app). In an
            // overlay so a filled image can't grow the view past the size it's given.
            Color.clear.overlay {
                if let url = ArtworkURL.url(for: track, large: large) {
                    ArtworkImage(url: url).id(url)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
