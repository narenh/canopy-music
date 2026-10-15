#if DEBUG
import CanopyMusicCore
import CanopyMusicServer
import MediaPlayer
@preconcurrency import MusicKit
import SwiftUI

/// Settings › Debug › Library test: can Canopy Music play a song that's only in the user's iCloud
/// Music Library (an upload with no catalog entry)? Finds it with MusicKit, then plays it on
/// demand with ApplicationMusicPlayer, MediaPlayer's applicationQueuePlayer, or a Sonos room
/// (the library URI form the Sonos app uses). Nothing plays until a button is tapped. Every line
/// also goes to Library/Caches/library-test.log. Debug builds only.
struct LibraryTestView: View {
    @Environment(AppModel.self) private var model
    @State private var query = "Chip the Glasses"
    @State private var results: [Song] = []
    @State private var selected: Song?
    @State private var lines: [String] = []
    @State private var busy = false
    @State private var roomID: String?
    @State private var sonosMode: LibraryTrackOnSonos.Mode = .queue

    static var logURL: URL { URL.cachesDirectory.appending(path: "library-test.log") }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Song title", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }
                        .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Your library")
            } footer: {
                Text("MusicLibraryRequest<Song>, title contains the text (then any field, if nothing matches).")
            }
            .listRowBackground(Color.white.opacity(0.08))

            if !results.isEmpty {
                Section("Results (\(results.count))") {
                    ForEach(results) { song in
                        Button { selected = song } label: { row(song) }
                            .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.white.opacity(0.08))
            }

            Section {
                Button("Play here (MusicKit)") { run { await playWithMusicKit($0) } }
                Button("Play here (MediaPlayer)") { run { await playWithMediaPlayer($0) } }
                Button("Stop both players", role: .destructive) { stopLocalPlayers(log: true) }
            } header: {
                Text("This device")
            } footer: {
                Text(selected.map { "Plays “\($0.title)”. Each stops the other player first." } ?? "Pick a song above first.")
            }
            .listRowBackground(Color.white.opacity(0.08))
            .disabled(busy || selected == nil)

            sonosSection

            Section {
                HStack {
                    Button("Copy log") { UIPasteboard.general.string = lines.joined(separator: "\n") }
                    Spacer()
                    Button("Clear", role: .destructive) { lines = [] }
                }
                .buttonStyle(.borderless)
                if lines.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Log")
            } footer: {
                Text("Also appended to Library/Caches/library-test.log.")
            }
            .listRowBackground(Color.white.opacity(0.08))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Library test")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
    }

    // MARK: Rows

    private func row(_ song: Song) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected?.id == song.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected?.id == song.id ? Color.accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.headline)
                Text("\(song.artistName) · \(song.albumTitle ?? "no album") · \(Self.minutes(song.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Group {
                    Text("id \(song.id.rawValue)")
                    Text(Self.catalogSummary(song))
                    Text("playParameters \(Self.playParametersJSON(song))")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sonosSection: some View {
        let rooms = model.sonos.rooms
        Section {
            if rooms.isEmpty {
                HStack {
                    Text(model.sonos.hasSearched ? "No Sonos rooms found." : "Looking for Sonos rooms…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { model.sonos.refresh() }
                        .buttonStyle(.borderless)
                }
            } else {
                Picker("Room", selection: $roomID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(rooms) { room in
                        Text(roomLabel(room)).tag(Optional(room.id))
                    }
                }
            }
            Picker("Send", selection: $sonosMode) {
                ForEach(LibraryTrackOnSonos.Mode.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Apple Music account", value: accountLabel)
            Button("Play on Sonos room") {
                guard let room = rooms.first(where: { $0.id == roomID }) else { return }
                run { await playOnSonos($0, room: room) }
            }
            .disabled(busy || selected == nil || roomID == nil)
        } header: {
            Text("Sonos")
        } footer: {
            Text("Queue: clears the room's queue, adds the song, plays the queue (the steps the Sonos engine takes for a catalog song). Direct: sets the song itself as the room's transport URI. Either changes what's playing in that room.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    private func roomLabel(_ room: SonosPlayer) -> String {
        guard let group = model.sonos.group(containing: room.id), group.coordinatorID != room.id else { return room.roomName }
        let leader = group.coordinator?.roomName ?? group.coordinatorID
        return "\(room.roomName) (in \(leader)'s group)"
    }

    // MARK: Running

    /// One test at a time, on the selected song.
    private func run(_ test: @escaping @MainActor (Song) async -> Void) {
        guard let song = selected, !busy else { return }
        busy = true
        Task {
            await test(song)
            busy = false
        }
    }

    private func start() async {
        log("— Library test opened —")
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        log("MusicKit authorization: \(status)")
        log("MediaPlayer library authorization: \(Self.name(MPMediaLibrary.authorizationStatus()))")
        do {
            let subscription = try await MusicSubscription.current
            log("subscription: canPlayCatalogContent=\(subscription.canPlayCatalogContent) hasCloudLibraryEnabled=\(subscription.hasCloudLibraryEnabled)")
        } catch {
            log("subscription error: \(error)")
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.title, contains: term)
            request.limit = 25
            var songs = Array(try await request.response().items)
            log("library search title contains \"\(term)\": \(songs.count)")
            if songs.isEmpty {
                var any = MusicLibraryRequest<Song>()
                any.filter(text: term)
                any.limit = 25
                songs = Array(try await any.response().items)
                log("library search any field \"\(term)\": \(songs.count)")
            }
            for song in songs {
                log("  \(song.title) – \(song.artistName) – \(song.albumTitle ?? "-") – \(Self.minutes(song.duration)) | id \(song.id.rawValue) | \(Self.catalogSummary(song)) | playParameters \(Self.playParametersJSON(song))")
            }
            results = songs
            if let selected, !songs.contains(where: { $0.id == selected.id }) { self.selected = nil }
            if selected == nil { selected = songs.first }
        } catch {
            log("library search error: \(error)")
        }
    }

    // MARK: MusicKit

    private func playWithMusicKit(_ song: Song) async {
        log("— MusicKit: \(song.title) (\(song.id.rawValue)) —")
        MPMusicPlayerController.applicationQueuePlayer.stop()
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        do {
            try await player.play()
            log("play() returned")
        } catch {
            log("play() threw: \(error)")
            log("  localized: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .seconds(3))
        let entry = player.queue.currentEntry
        log("status=\(player.state.playbackStatus) playbackTime=\(String(format: "%.1f", player.playbackTime))")
        log("currentEntry: \(entry.map { "\($0.title) – \($0.subtitle ?? "-") | item \(String(describing: $0.item))" } ?? "nil")")
    }

    // MARK: MediaPlayer

    private func playWithMediaPlayer(_ song: Song) async {
        log("— MediaPlayer: \(song.title) – \(song.artistName) —")
        ApplicationMusicPlayer.shared.stop()
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
            log("MediaPlayer library authorization: \(Self.name(status))")
        }
        let titleOnly = MPMediaQuery.songs()
        titleOnly.addFilterPredicate(MPMediaPropertyPredicate(value: song.title, forProperty: MPMediaItemPropertyTitle, comparisonType: .equalTo))
        let withArtist = MPMediaQuery.songs()
        withArtist.addFilterPredicate(MPMediaPropertyPredicate(value: song.title, forProperty: MPMediaItemPropertyTitle, comparisonType: .equalTo))
        withArtist.addFilterPredicate(MPMediaPropertyPredicate(value: song.artistName, forProperty: MPMediaItemPropertyArtist, comparisonType: .equalTo))
        let byArtist = withArtist.items
        let byTitle = titleOnly.items
        log("MPMediaQuery title+artist: \(byArtist.map { "\($0.count)" } ?? "nil (error)"); title only: \(byTitle.map { "\($0.count)" } ?? "nil (error)")")
        let items = (byArtist?.isEmpty == false ? byArtist : byTitle) ?? []
        for item in items {
            log("  \(item.title ?? "-") – \(item.artist ?? "-") – \(item.albumTitle ?? "-") | persistentID \(item.persistentID) | cloud \(item.isCloudItem) | assetURL \(item.assetURL.map { $0.absoluteString } ?? "nil") | protected \(item.hasProtectedAsset) | playbackStoreID \(item.playbackStoreID)")
        }
        guard let item = items.first else {
            log("nothing to play")
            return
        }
        let player = MPMusicPlayerController.applicationQueuePlayer
        player.setQueue(with: MPMediaItemCollection(items: [item]))
        do {
            try await player.prepareToPlay()
            log("prepareToPlay returned")
        } catch {
            log("prepareToPlay threw: \(error)")
            log("  localized: \(error.localizedDescription)")
        }
        player.play()
        log("play() called")
        try? await Task.sleep(for: .seconds(3))
        log("state=\(Self.name(player.playbackState)) currentPlaybackTime=\(String(format: "%.1f", player.currentPlaybackTime))")
        log("nowPlayingItem: \(player.nowPlayingItem.map { "\($0.title ?? "-") (persistentID \($0.persistentID))" } ?? "nil")")
    }

    private func stopLocalPlayers(log logging: Bool) {
        ApplicationMusicPlayer.shared.stop()
        MPMusicPlayerController.applicationQueuePlayer.stop()
        if logging { log("stopped both players") }
    }

    // MARK: Sonos

    /// The Apple Music account the Sonos engine would stream from: the one chosen for it, else the
    /// first known, else none (the engine then assumes `SonosOutputController.assumedSerial`).
    private var sonosAccount: SonosAccount? {
        let controller = model.sonosController
        let known = controller.knownAccounts(for: .appleMusic)
        guard let pick = controller.chosenAccounts[SonosMusicService.appleMusic.rawValue] else { return known.first }
        return known.first { $0.id == pick.id } ?? pick
    }

    private var accountLabel: String {
        guard let account = sonosAccount else { return "sn \(SonosOutputController.assumedSerial) (assumed)" }
        return "sn \(account.serialNumber)\(account.example.map { " (seen on “\($0)”)" } ?? "")"
    }

    private func playOnSonos(_ song: Song, room: SonosPlayer) async {
        let household = model.sonos
        let sid = SonosParse.serviceID(for: .appleMusic, in: household.services)
        let account = sonosAccount
        let serial = account?.serialNumber ?? SonosOutputController.assumedSerial
        let token = account?.token ?? SonosTrackReference.genericToken(serviceType: SonosMusicService.serviceType(forServiceID: sid))
        let uri = LibraryTrackOnSonos.uri(libraryID: song.id.rawValue, serviceID: sid, serial: serial)
        let metadata = LibraryTrackOnSonos.metadata(song: song, uri: uri, token: token)
        log("— Sonos (\(sonosMode.title)): \(song.title) on \(room.roomName) (\(room.host)) —")
        if let group = household.group(containing: room.id), group.coordinatorID != room.id {
            log("note: \(room.roomName) isn't its group's coordinator, so Sonos may answer 800 for that reason")
        }
        log("URI: \(uri)")
        log("DIDL: \(metadata)")
        let client = SonosClient(transport: household.transport, host: room.host)
        do {
            switch sonosMode {
            case .queue:
                try await step("RemoveAllTracksFromQueue") { try await client.clearQueue() }
                let number = try await step("AddURIToQueue") { try await client.addToQueue(uri: uri, metadata: metadata, position: 0, asNext: false) }
                log("AddURIToQueue: track #\(number)")
                try await step("SetAVTransportURI") { try await client.setTransportURI(SonosURI.queue(of: room.id)) }
                try? await client.setPlayModeNormal()
                try await step("Seek") { try await client.seek(trackNumber: number) }
                try await step("Play") { try await client.play() }
            case .direct:
                try await step("SetAVTransportURI") { try await client.setTransportURI(uri, metadata: metadata) }
                try await step("Play") { try await client.play() }
            }
            log("sent: no fault")
        } catch {
            // Already logged by `step`.
        }
        try? await Task.sleep(for: .seconds(4))
        let instance = [SonosRequest.Argument("InstanceID", "0")]
        do {
            let position = try await household.transport.send(SonosRequest(host: room.host, service: .avTransport, action: "GetPositionInfo", arguments: instance))
            log("GetPositionInfo: TrackURI=\(position["TrackURI"] ?? "nil") RelTime=\(position["RelTime"] ?? "nil") TrackDuration=\(position["TrackDuration"] ?? "nil") Track=\(position["Track"] ?? "nil")")
            log("  TrackMetaData: \(position["TrackMetaData"] ?? "nil")")
            let transport = try await household.transport.send(SonosRequest(host: room.host, service: .avTransport, action: "GetTransportInfo", arguments: instance))
            log("GetTransportInfo: \(transport["CurrentTransportState"] ?? "nil") status \(transport["CurrentTransportStatus"] ?? "nil")")
        } catch {
            log("reading the room back failed: \(Self.describe(error))")
        }
    }

    /// One Sonos command; a failure is logged with its SOAP fault code and rethrown.
    private func step<T>(_ action: String, _ command: () async throws -> T) async throws -> T {
        do {
            return try await command()
        } catch {
            log("\(action) failed: \(Self.describe(error))")
            throw error
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case .upnp(let action, let code)? = error as? SonosError {
            let meaning = switch code {
            case 800: " (not linked, or not the group's coordinator)"
            case 701: " (refused: transition not available)"
            default: ""
            }
            return "SOAP fault \(code.map(String.init) ?? "with no code") on \(action)\(meaning)"
        }
        return "\(error)"
    }

    // MARK: Log

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)"
        print("[library-test] \(line)")
        lines.append(stamped)
        let data = Data((stamped + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    // MARK: Formatting

    private static func minutes(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "?:??" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The play parameters MusicKit holds for the song, as JSON (opaque otherwise). A library song
    /// that matches the catalog carries its catalog id there.
    private static func playParametersJSON(_ song: Song) -> String {
        guard let parameters = song.playParameters else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? "(can't encode)"
    }

    private static func catalogSummary(_ song: Song) -> String {
        var parts: [String] = []
        if let data = playParametersJSON(song).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ids = object.filter { $0.key.lowercased().contains("catalog") || $0.key.lowercased().contains("purchased") }
            parts.append(ids.isEmpty ? "no catalog id in playParameters" : ids.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        parts.append("isrc \(song.isrc ?? "nil")")
        parts.append("url \(song.url?.absoluteString ?? "nil")")
        return parts.joined(separator: " | ")
    }

    private static func name(_ status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    private static func name(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .stopped: "stopped"
        case .playing: "playing"
        case .paused: "paused"
        case .interrupted: "interrupted"
        case .seekingForward: "seekingForward"
        case .seekingBackward: "seekingBackward"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }
}

/// The Sonos app's form for an Apple Music library track, read off a real speaker's queue and
/// `GetPositionInfo`: `x-sonos-http:librarytrack%3a{libraryID}.unknown?sid=204&flags=0&sn={serial}`,
/// with a `res` of protocolInfo `sonos.com-http:*:application/octet-stream:*`. The item id and
/// `desc` follow `SonosTrackReference`'s catalog DIDL (a real queue drops both, so the capture
/// can't show them). Debug builds only.
enum LibraryTrackOnSonos {
    enum Mode: CaseIterable {
        /// The Sonos engine's catalog steps: empty the queue, add the song, play the queue.
        case queue
        /// `SetAVTransportURI` with the song itself.
        case direct

        var title: String {
            switch self {
            case .queue: "Queue"
            case .direct: "Direct"
            }
        }
    }

    static func encodedObject(_ libraryID: String) -> String { "librarytrack%3a\(libraryID)" }

    static func uri(libraryID: String, serviceID: Int, serial: Int) -> String {
        "x-sonos-http:\(encodedObject(libraryID)).unknown?sid=\(serviceID)&flags=0&sn=\(serial)"
    }

    static func metadata(song: Song, uri: String, token: String) -> String {
        let e = SonosXMLEscape.escape
        var item = "<item id=\"\(e("10032020" + encodedObject(song.id.rawValue)))\" parentID=\"-1\" restricted=\"true\">"
        let duration = song.duration.map { " duration=\"\(SonosTime.string($0))\"" } ?? ""
        item += "<res protocolInfo=\"sonos.com-http:*:application/octet-stream:*\"\(duration)>\(e(uri))</res>"
        item += "<dc:title>\(e(song.title))</dc:title>"
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        if !song.artistName.isEmpty { item += "<dc:creator>\(e(song.artistName))</dc:creator>" }
        if let album = song.albumTitle, !album.isEmpty { item += "<upnp:album>\(e(album))</upnp:album>" }
        item += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(e(token))</desc>"
        item += "</item>"
        return didlOpen + item + "</DIDL-Lite>"
    }

    /// As `SonosTrackReference.didlOpen`.
    static let didlOpen = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
}
#endif
