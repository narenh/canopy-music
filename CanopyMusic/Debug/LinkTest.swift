#if DEBUG
import AVFoundation
import CanopyMusicCore
import CanopyMusicServer
@preconcurrency import MusicKit
import QuartzCore
import Security
import SwiftUI
import UIKit

/// Settings › Debug › Link test: before link tracks are built, can this iPad hand off between
/// MusicKit's ApplicationMusicPlayer and an AVPlayer playing a canopy-cmdlp `audioUrl`, and back?
/// How long is the gap each way, and does Apple Music start again after AVPlayer had the audio
/// session? Also queues A → link → B in one Sonos queue. Nothing plays until a button is tapped.
/// Every line also goes to Library/Caches/link-test.log and stdout. Debug builds only.
struct LinkTestView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("debugLinkTestBaseURL") private var baseURL = LinkTestLab.defaultBaseURL
    @AppStorage("debugLinkTestLink") private var link = ""
    @State private var tokenDraft = ""
    private let lab = LinkTestLab.shared

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                cmdlpSection
                linkSection
                songsSection
                deviceSection.id("device")
                sonosSection
                logSection
            }
            .task {
                // `-linkTestScrolled` (with `-showLinkTest`): down to the buttons, for screenshots.
                guard ProcessInfo.processInfo.arguments.contains("-linkTestScrolled") else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo("device", anchor: .top)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Link test")
        .navigationBarTitleDisplayMode(.inline)
        .task { await lab.opened() }
    }

    // MARK: cmdlp

    private var cmdlpSection: some View {
        Section {
            TextField("Base URL", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(nil)
            HStack {
                SecureField("Paste API token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(nil)
                Button("Save") {
                    lab.saveToken(tokenDraft)
                    tokenDraft = ""
                }
                .buttonStyle(.borderless)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                LabeledContent("Saved token", value: lab.tokenHint.map { "…\($0)" } ?? "None")
                Spacer()
                Button("Forget", role: .destructive) { lab.forgetToken() }
                    .buttonStyle(.borderless)
                    .disabled(lab.tokenHint == nil)
            }
            LabeledContent("Test zone", value: lab.zone)
        } header: {
            Text("cmdlp")
        } footer: {
            Text("The token stays in this device's Keychain under a debug-only key. Only its last four characters are shown, and it's never logged.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    // MARK: Link

    private var linkSection: some View {
        Section {
            HStack {
                TextField("YouTube, SoundCloud, Bandcamp, Mixcloud, or archive.org link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(nil)
                    .onSubmit { lab.resolve(baseURL: baseURL, link: link) }
                Button("Resolve") { lab.resolve(baseURL: baseURL, link: link) }
                    .buttonStyle(.borderless)
                    .disabled(lab.isResolving || lab.tokenHint == nil || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let track = lab.track {
                LinkTrackRow(track: track)
            }
            if let error = lab.linkError {
                Text(error).foregroundStyle(.orange)
            }
            Button("Delete test zone", role: .destructive) { lab.deleteZone(baseURL: baseURL) }
                .disabled(lab.isResolving || lab.tokenHint == nil)
        } header: {
            Text("Link")
        } footer: {
            Text("POST /resolve in the test zone, then GET /tracks/{id} once a second until it's ready or failed.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    // MARK: Songs

    private var songsSection: some View {
        @Bindable var lab = lab
        return Section {
            HStack {
                TextField("Search Apple Music", text: $lab.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await lab.search() } }
                Button("Search") { Task { await lab.search() } }
                    .buttonStyle(.borderless)
                    .disabled(lab.isSearching || lab.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            songRow("A", lab.songA)
            songRow("B", lab.songB)
            ForEach(lab.results) { song in
                HStack(spacing: 12) {
                    songLabel(song)
                    Spacer()
                    Button("A") { lab.pick(song, slot: .a) }
                        .buttonStyle(.bordered)
                        .tint(lab.songA?.id == song.id ? Color.accentColor : Color.secondary)
                    Button("B") { lab.pick(song, slot: .b) }
                        .buttonStyle(.bordered)
                        .tint(lab.songB?.id == song.id ? Color.accentColor : Color.secondary)
                }
            }
        } header: {
            Text("Apple Music songs")
        } footer: {
            Text("A plays before the link, B after it. Catalog songs only, so Sonos can stream them too.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    private func songRow(_ slot: String, _ song: Song?) -> some View {
        HStack(spacing: 12) {
            Text(slot)
                .font(.headline.monospaced())
                .frame(width: 22)
            if let song {
                songLabel(song)
            } else {
                Text("Pick one below").foregroundStyle(.secondary)
            }
        }
    }

    private func songLabel(_ song: Song) -> some View {
        HStack(spacing: 10) {
            if let url = song.artwork?.url(width: 120, height: 120) {
                ArtworkImage(url: url)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text("\(song.artistName) · \(LinkTestLab.minutes(song.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: This device

    private var deviceSection: some View {
        let blocked = !lab.canRunHandoff || lab.running != nil || model.isLive
        return Section {
            Button("Run handoff on this \(DeviceKind.noun)") { lab.runHandoff(.plain) }
                .disabled(blocked)
            Button("Handoff, deactivate session between") { lab.runHandoff(.deactivate) }
                .disabled(blocked)
            Button("Handoff with prepareToPlay") { lab.runHandoff(.prepare) }
                .disabled(blocked)
            Button("Stop all", role: .destructive) { lab.stopAll() }
            if let running = lab.running {
                LabeledContent("Now", value: running)
            }
            ForEach(lab.lastResults, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("This \(DeviceKind.noun)")
        } footer: {
            Text(deviceFooter)
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    private var deviceFooter: String {
        if model.isLive { return "End the zone first: its player is the same ApplicationMusicPlayer." }
        if !lab.canRunHandoff { return "Needs A, B, and a link that's ready." }
        return "Plays A for 10 s, pauses it and plays the link in an AVPlayer for 10 s, seeks to 8 s before the link's end, then plays B when the link ends. The variants deactivate the audio session before B, or prepare B while the link plays."
    }

    // MARK: Sonos

    @ViewBuilder
    private var sonosSection: some View {
        @Bindable var lab = lab
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
                Picker("Room", selection: $lab.roomID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(rooms) { room in
                        Text(roomLabel(room)).tag(Optional(room.id))
                    }
                }
            }
            LabeledContent("Apple Music account", value: accountLabel)
            Button("Run on Sonos room") {
                guard let room = selectedRoom else { return }
                lab.runSonos(household: model.sonos, reference: sonosReference, room: room)
            }
            .disabled(!lab.canRunHandoff || selectedRoom == nil || lab.sonosBusy || model.isLive)
            Button("Jump to near end") {
                guard let room = selectedRoom else { return }
                lab.sonosJumpNearEnd(household: model.sonos, room: room)
            }
            .disabled(selectedRoom == nil || model.isLive)
            Button("Stop Sonos room", role: .destructive) {
                guard let room = selectedRoom else { return }
                lab.stopSonos(household: model.sonos, room: room)
            }
            .disabled(selectedRoom == nil || model.isLive)
            if let reading = lab.sonosReading {
                LabeledContent("Position", value: reading)
            }
        } header: {
            Text("Sonos")
        } footer: {
            Text("Empties the room's queue and fills it with A, the link (its audioUrl, as a plain https URI), and B, then plays from A. Reads the position back every 2 s. Jump to near end seeks the current track to 10 s before its end. This changes what's playing in that room.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }

    private var selectedRoom: SonosPlayer? {
        model.sonos.rooms.first { $0.id == lab.roomID }
    }

    private func roomLabel(_ room: SonosPlayer) -> String {
        guard let group = model.sonos.group(containing: room.id), group.coordinatorID != room.id else { return room.roomName }
        let leader = group.coordinator?.roomName ?? group.coordinatorID
        return "\(room.roomName) (in \(leader)'s group)"
    }

    /// The Apple Music account the Sonos engine would stream from: the one chosen for it, else the
    /// first known, else none (the engine then assumes `SonosOutputController.assumedSerial`).
    private var sonosAccount: SonosAccount? {
        let controller = model.sonosController
        let known = controller.knownAccounts(for: .appleMusic)
        guard let pick = controller.chosenAccounts[SonosMusicService.appleMusic.rawValue] else { return known.first }
        return known.first { $0.id == pick.id } ?? pick
    }

    private var sonosReference: SonosTrackReference {
        let account = sonosAccount
        return SonosTrackReference(service: .appleMusic, accountSerial: account?.serialNumber ?? SonosOutputController.assumedSerial, token: account?.token)
    }

    private var accountLabel: String {
        guard let account = sonosAccount else { return "sn \(SonosOutputController.assumedSerial) (assumed)" }
        return "sn \(account.serialNumber)\(account.example.map { " (seen on “\($0)”)" } ?? "")"
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            HStack {
                Button("Copy") { UIPasteboard.general.string = lab.lines.joined(separator: "\n") }
                Spacer()
                Button("Clear", role: .destructive) { lab.clearLog() }
            }
            .buttonStyle(.borderless)
            if lab.lines.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                Text(lab.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Log")
        } footer: {
            Text("Also appended to Library/Caches/link-test.log, and printed as [link-test] lines.")
        }
        .listRowBackground(Color.white.opacity(0.08))
    }
}

/// The resolved link: art, title, artist, length, and where its download is.
private struct LinkTrackRow: View {
    let track: CmdlpTrack

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: track.artwork.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title ?? "No title").font(.headline)
                Text("\(track.artist ?? "No artist") · \(LinkTestLab.minutes(track.duration))\(track.service.map { " · \($0)" } ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(LinkTestLab.statusLine(track))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(track.status == "failed" ? .orange : .secondary)
                if track.status == "pending" {
                    if let percent = track.progress?.percent {
                        ProgressView(value: percent, total: 100)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - cmdlp

/// A track as canopy-cmdlp answers `POST /resolve` and `GET /tracks/{id}`.
struct CmdlpTrack: Decodable, Equatable, Sendable {
    struct Progress: Decodable, Equatable, Sendable {
        var percent: Double?
        var downloadedBytes: Int?
        var totalBytes: Int?
        var speed: Double?
        var eta: Double?
    }

    var id: String
    var status: String
    var title: String?
    var artist: String?
    var duration: Double?
    var artwork: String?
    var service: String?
    var stage: String?
    var progress: Progress?
    var audioUrl: String
    var size: Int?
    var codec: String?
    var transcoded: Bool?
    var error: String?
}

private struct CmdlpErrorBody: Decodable {
    var error: String
    var reason: String
}

struct LinkTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The cmdlp API token, in the Keychain under a key only debug builds use.
private enum LinkTestKeychain {
    static let service = "com.canopysf.CanopyMusic.debug.cmdlpToken"

    static func save(_ token: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

// MARK: - The lab

/// The test's state and runs. One for the app's life, so a run carries on (and its log stays)
/// when the screen is left.
@MainActor
@Observable
final class LinkTestLab {
    static let shared = LinkTestLab()
    static let defaultBaseURL = "https://cmdlp.canopysf.com"
    static var logURL: URL { URL.cachesDirectory.appending(path: "link-test.log") }

    enum Slot { case a, b }

    enum HandoffVariant {
        case plain, deactivate, prepare

        var title: String {
            switch self {
            case .plain: "plain"
            case .deactivate: "deactivate session between"
            case .prepare: "prepareToPlay B during the link"
            }
        }
    }

    /// When each step of a handoff happened (`CACurrentMediaTime`).
    private struct Marks {
        var aPlayCall: CFTimeInterval?
        var aAdvance: CFTimeInterval?
        var aPause: CFTimeInterval?
        var linkReady: CFTimeInterval?
        var linkPlaying: CFTimeInterval?
        var linkAdvance: CFTimeInterval?
        var linkStartEstimate: CFTimeInterval?
        var linkEnd: CFTimeInterval?
        var bPlayCall: CFTimeInterval?
        var bPlayReturned: CFTimeInterval?
        var bAdvance: CFTimeInterval?
        var bStartEstimate: CFTimeInterval?
    }

    /// The first reading of a playing clock that moved on from the one before.
    private struct Advance {
        var at: CFTimeInterval
        var value: TimeInterval
        /// When the item began at 0: when it started, from how far it had got.
        var startEstimate: CFTimeInterval? { value < 2 ? at - value : nil }
    }

    // cmdlp
    private(set) var tokenHint: String?
    private(set) var track: CmdlpTrack?
    private(set) var linkError: String?
    private(set) var isResolving = false
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    let zone: String

    // Songs
    var query = "Fleetwood Mac"
    private(set) var results: [Song] = []
    private(set) var songA: Song?
    private(set) var songB: Song?
    private(set) var isSearching = false

    // Handoff
    private(set) var running: String?
    private(set) var lastResults: [String] = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runCount = 0
    @ObservationIgnored private var runStart: CFTimeInterval?
    @ObservationIgnored private var marks = Marks()
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var sessionEvents: [String] = []
    @ObservationIgnored private var routeChanges = 0
    @ObservationIgnored private var lastTimeControl: AVPlayer.TimeControlStatus?

    // Sonos
    var roomID: String?
    private(set) var sonosBusy = false
    private(set) var sonosReading: String?
    @ObservationIgnored private var sonosTask: Task<Void, Never>?
    @ObservationIgnored private var sonosWatch: Task<Void, Never>?
    @ObservationIgnored private var sonosLabels: [Int: String] = [:]
    @ObservationIgnored private var sonosStart: CFTimeInterval?

    // Log
    private(set) var lines: [String] = []
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var loadedSongs = false

    private enum Keys {
        static let songA = "debugLinkTestSongA"
        static let songB = "debugLinkTestSongB"
    }

    private init() {
        tokenHint = LinkTestKeychain.load().map { String($0.suffix(4)) }
        zone = Self.makeZone()
    }

    /// `linktest-<device name>-<vendor id>`, within cmdlp's 64 letters, digits, `-`, or `_`.
    private static func makeZone() -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let name = String(DeviceKind.name.map { allowed.contains($0) ? $0 : "-" }).lowercased()
        let vendor = UIDevice.current.identifierForVendor?.uuidString.prefix(8).lowercased() ?? "0"
        return String("linktest-\(name)-\(vendor)".prefix(64))
    }

    var canRunHandoff: Bool {
        songA != nil && songB != nil && track?.status == "ready" && track.flatMap { URL(string: $0.audioUrl) } != nil
    }

    func opened() async {
        log("— Link test opened (zone \(zone)) —")
        if !observing {
            observing = true
            observeAudioSession()
        }
        logSession("now")
        guard !loadedSongs else { return }
        loadedSongs = true
        guard await musicAuthorized() else { return }
        do {
            let subscription = try await MusicSubscription.current
            log("Apple Music subscription: canPlayCatalogContent=\(subscription.canPlayCatalogContent)")
        } catch {
            log("Apple Music subscription error: \(error)")
        }
        await loadSongs()
    }

    // MARK: Token

    func saveToken(_ draft: String) {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        LinkTestKeychain.save(token)
        tokenHint = String(token.suffix(4))
        log("API token saved")
    }

    func forgetToken() {
        LinkTestKeychain.delete()
        tokenHint = nil
        log("API token forgotten")
    }

    // MARK: cmdlp

    func resolve(baseURL: String, link: String) {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isResolving else { return }
        guard let token = LinkTestKeychain.load() else {
            linkError = "Save an API token first."
            return
        }
        resolveTask?.cancel()
        isResolving = true
        linkError = nil
        track = nil
        resolveTask = Task {
            defer { isResolving = false }
            log("— Resolve \(url) in zone \(zone) —")
            let started = now()
            do {
                let resolved: CmdlpTrack = try await cmdlp("POST", "/resolve", base: baseURL, token: token, body: ["url": url, "zone": zone])
                track = resolved
                log("resolved in \(Self.seconds(now() - started)): \(Self.describe(resolved))")
                var lastLine = ""
                while track?.status == "pending" {
                    try await Task.sleep(for: .seconds(1))
                    let next: CmdlpTrack = try await cmdlp("GET", "/tracks/\(resolved.id)", base: baseURL, token: token)
                    track = next
                    let line = Self.progressLogLine(next)
                    if line != lastLine {
                        log(line)
                        lastLine = line
                    }
                }
                if let track {
                    log("\(track.status) after \(Self.seconds(now() - started)): \(Self.describe(track))")
                    if track.status == "failed" { linkError = track.error ?? "The download failed." }
                }
            } catch is CancellationError {
                log("resolve cancelled")
            } catch {
                linkError = "\(error)"
                log("cmdlp: \(error)")
            }
        }
    }

    func deleteZone(baseURL: String) {
        guard let token = LinkTestKeychain.load() else {
            linkError = "Save an API token first."
            return
        }
        struct Deleted: Decodable { var deleted: Int }
        Task {
            do {
                let reply: Deleted = try await cmdlp("DELETE", "/zones/\(zone)", base: baseURL, token: token)
                log("DELETE /zones/\(zone): \(reply.deleted) tracks")
                if !runningUsesLink { track = nil }
            } catch {
                log("DELETE /zones/\(zone): \(error)")
            }
        }
    }

    private var runningUsesLink: Bool { running != nil || sonosBusy }

    /// One cmdlp call. The token goes only in the Authorization header; nothing here logs it.
    private func cmdlp<T: Decodable>(_ method: String, _ path: String, base: String, token: String, body: [String: String]? = nil) async throws -> T {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + path), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            throw LinkTestFailure("Not a base URL: \(base)")
        }
        // A lookup can take up to 90 s on cmdlp's side.
        var request = URLRequest(url: url, timeoutInterval: method == "POST" ? 120 : 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let error = try? JSONDecoder().decode(CmdlpErrorBody.self, from: data) {
                throw LinkTestFailure("\(method) \(path): HTTP \(status) \(error.reason): \(error.error)")
            }
            throw LinkTestFailure("\(method) \(path): HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Songs

    private func musicAuthorized() async -> Bool {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        if status != .authorized { log("MusicKit authorization: \(status)") }
        return status == .authorized
    }

    /// The songs picked last time, else the first two a search finds.
    private func loadSongs() async {
        let ids = [Keys.songA, Keys.songB].compactMap { UserDefaults.standard.string(forKey: $0) }.map { MusicItemID($0) }
        if ids.count == 2 {
            do {
                let response = try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids).response()
                songA = response.items.first { $0.id == ids[0] }
                songB = response.items.first { $0.id == ids[1] }
            } catch {
                log("loading A and B: \(error)")
            }
        }
        if songA == nil || songB == nil {
            await search()
            if songA == nil, let first = results.first { pick(first, slot: .a) }
            if songB == nil, let second = results.first(where: { $0.id != songA?.id }) { pick(second, slot: .b) }
        }
        log("A: \(songA.map(Self.describe) ?? "none"); B: \(songB.map(Self.describe) ?? "none")")
    }

    func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !isSearching, await musicAuthorized() else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 12
            results = Array(try await request.response().songs)
            log("catalog search \"\(term)\": \(results.count)")
        } catch {
            log("catalog search \"\(term)\" error: \(error)")
        }
    }

    func pick(_ song: Song, slot: Slot) {
        switch slot {
        case .a:
            songA = song
            UserDefaults.standard.set(song.id.rawValue, forKey: Keys.songA)
        case .b:
            songB = song
            UserDefaults.standard.set(song.id.rawValue, forKey: Keys.songB)
        }
    }

    // MARK: Handoff

    func runHandoff(_ variant: HandoffVariant) {
        guard runTask == nil, let a = songA, let b = songB, let track, track.status == "ready", let url = URL(string: track.audioUrl) else { return }
        runCount += 1
        let run = runCount
        running = "Handoff #\(run) starting"
        runTask = Task {
            await handoff(run: run, variant: variant, a: a, b: b, track: track, audioURL: url)
            runTask = nil
            running = nil
            runStart = nil
        }
    }

    func stopAll() {
        runTask?.cancel()
        tearDownAVPlayer(log: true)
        ApplicationMusicPlayer.shared.pause()
        log("Stop all: AVPlayer gone, MusicKit paused")
    }

    private func handoff(run: Int, variant: HandoffVariant, a: Song, b: Song, track: CmdlpTrack, audioURL: URL) async {
        marks = Marks()
        sessionEvents = []
        routeChanges = 0
        lastTimeControl = nil
        tearDownAVPlayer(log: false)
        runStart = now()
        log("===== Handoff #\(run) (\(variant.title)) =====")
        log("A \(Self.describe(a)) | link \(track.title ?? "?") – \(track.artist ?? "?") (\(Self.minutes(track.duration)), \(track.codec ?? "?")) | B \(Self.describe(b))")
        guard await musicAuthorized() else { return }
        logSession("start")
        let player = ApplicationMusicPlayer.shared
        let statusWatch = Task { await watchMusicKitStatus() }
        defer { statusWatch.cancel() }

        // 1. A, about 10 s.
        phase(run, "playing A")
        player.stop()
        player.queue = ApplicationMusicPlayer.Queue(for: [a])
        let aWatch = Task { await waitForAdvance(timeout: 20, every: .milliseconds(20)) { ApplicationMusicPlayer.shared.playbackTime } }
        marks.aPlayCall = now()
        log("A: play() called")
        do {
            try await player.play()
            log("A: play() returned (\(since(marks.aPlayCall)) after the call)")
        } catch {
            log("A: play() threw: \(error)")
            aWatch.cancel()
            return finish(run, variant, why: "A didn't play")
        }
        guard let aAdvance = await result(of: aWatch) else { return finish(run, variant, why: "A's playbackTime never moved") }
        marks.aAdvance = aAdvance.at
        log("A: playbackTime advancing (\(Self.seconds(aAdvance.at - marks.aPlayCall!)) after play() was called, t=\(Self.time(aAdvance.value)))", at: aAdvance.at)
        logSession("A playing")
        guard await hold(10) else { return finish(run, variant, why: "stopped") }

        // 2. Handoff to the link.
        phase(run, "handing off to the link")
        logSession("before pause")
        let pauseCall = now()
        marks.aPause = pauseCall
        player.pause()
        log("A: pause() called (returned in \(since(pauseCall)); status now \(player.state.playbackStatus), t=\(Self.time(player.playbackTime)))", at: pauseCall)
        let item = AVPlayerItem(url: audioURL)
        let av = AVPlayer(playerItem: item)
        avPlayer = av
        observe(av, item)
        let linkWatch = Task { await waitForAdvance(timeout: 30, every: .milliseconds(10)) { self.avPlayer?.currentTime().seconds ?? 0 } }
        av.play()
        log("link: AVPlayer created and play() called (\(since(pauseCall)) after pause())")
        guard let linkAdvance = await result(of: linkWatch) else { return finish(run, variant, why: "the link's time never moved") }
        marks.linkAdvance = linkAdvance.at
        marks.linkStartEstimate = linkAdvance.startEstimate
        log("link: currentTime advancing (\(Self.seconds(linkAdvance.at - pauseCall)) after A's pause(), t=\(Self.time(linkAdvance.value)))", at: linkAdvance.at)
        logSession("link playing")
        log("MusicKit with the link playing: status \(player.state.playbackStatus), t=\(Self.time(player.playbackTime))")

        // 3. About 10 s, then to 8 s before the end.
        phase(run, "playing the link")
        guard await hold(10) else { return finish(run, variant, why: "stopped") }
        let itemDuration = item.duration.isNumeric ? item.duration.seconds : nil
        let duration = itemDuration ?? track.duration ?? 0
        if duration > 30 {
            let target = duration - 8
            let seekCall = now()
            let finished = await av.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            log("link: seek to \(Self.time(target)) of \(Self.time(duration)) (\(itemDuration == nil ? "cmdlp's length" : "item's length")) finished=\(finished) in \(since(seekCall))")
        } else {
            log("link: \(Self.time(duration)) long, no seek")
        }
        if variant == .prepare {
            phase(run, "preparing B")
            player.queue = ApplicationMusicPlayer.Queue(for: [b])
            log("B: queue set while the link plays (status \(player.state.playbackStatus))")
            let prepareCall = now()
            do {
                try await player.prepareToPlay()
                log("B: prepareToPlay() returned in \(since(prepareCall))")
            } catch {
                log("B: prepareToPlay() threw after \(since(prepareCall)): \(error)")
            }
            log("link after B's prepareToPlay: timeControlStatus \(Self.name(av.timeControlStatus)), t=\(Self.time(av.currentTime().seconds))")
            logSession("B prepared")
        }

        // 4. At the link's end, back to MusicKit with B.
        phase(run, "waiting for the link's end")
        let remaining = max(0, duration - av.currentTime().seconds)
        guard await waitForLinkEnd(timeout: remaining + 20) else {
            return finish(run, variant, why: Task.isCancelled ? "stopped" : "the link's end never came")
        }
        let end = marks.linkEnd!
        log("link: handling its end (\(since(end)) after didPlayToEndTime)")
        phase(run, "handing back to B")
        tearDownAVPlayer(log: true)
        if variant == .deactivate {
            let call = now()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                log("session: setActive(false, .notifyOthersOnDeactivation) succeeded in \(since(call))")
            } catch {
                log("session: setActive(false, .notifyOthersOnDeactivation) threw after \(since(call)): \(error)")
            }
        }
        if variant != .prepare {
            player.queue = ApplicationMusicPlayer.Queue(for: [b])
            log("B: queue set (\(since(end)) after the link's end)")
        }
        let bWatch = Task { await waitForAdvance(timeout: 20, every: .milliseconds(20)) { ApplicationMusicPlayer.shared.playbackTime } }
        let bCall = now()
        marks.bPlayCall = bCall
        log("B: play() called (\(since(end)) after the link's end)")
        do {
            try await player.play()
            marks.bPlayReturned = now()
            log("B: play() returned (\(since(bCall)) after the call)")
        } catch {
            log("B: play() threw after \(since(bCall)): \(error)")
        }
        if let bAdvance = await result(of: bWatch) {
            marks.bAdvance = bAdvance.at
            marks.bStartEstimate = bAdvance.startEstimate
            log("B: playbackTime advancing (\(Self.seconds(bAdvance.at - end)) after the link's end, t=\(Self.time(bAdvance.value)))", at: bAdvance.at)
        } else if !Task.isCancelled {
            log("B: playbackTime never moved in 20 s (status \(player.state.playbackStatus))")
        }

        // 5. Is B still going a few seconds on?
        phase(run, "checking B")
        guard await hold(6) else { return finish(run, variant, why: "stopped") }
        logSession("B playing")
        finish(run, variant, why: nil)
    }

    private func phase(_ run: Int, _ text: String) {
        running = "Handoff #\(run): \(text)"
    }

    /// Logs the run's results, whole or as far as it got.
    private func finish(_ run: Int, _ variant: HandoffVariant, why: String?) {
        if let why { log("Handoff #\(run) ended early: \(why)") }
        tearDownAVPlayer(log: why != nil)
        let m = marks
        func gap(_ to: CFTimeInterval?, _ from: CFTimeInterval?) -> String {
            guard let to, let from else { return "—" }
            return Self.seconds(to - from)
        }
        let player = ApplicationMusicPlayer.shared
        let status = player.state.playbackStatus
        let time = player.playbackTime
        let entry = player.queue.currentEntry?.title ?? "none"
        let resumed = m.bAdvance != nil && status == .playing && time > 3
        let results = [
            "RESULT #\(run) [\(variant.title)] A play() → A audible \(gap(m.aAdvance, m.aPlayCall))",
            "RESULT #\(run) A pause → link audible \(gap(m.linkAdvance, m.aPause)) (readyToPlay \(gap(m.linkReady, m.aPause)), .playing \(gap(m.linkPlaying, m.aPause)), est. start \(gap(m.linkStartEstimate, m.aPause)))",
            "RESULT #\(run) link end → B audible \(gap(m.bAdvance, m.linkEnd)) (play() called \(gap(m.bPlayCall, m.linkEnd)), returned \(gap(m.bPlayReturned, m.linkEnd)), est. start \(gap(m.bStartEstimate, m.linkEnd)))",
            "RESULT #\(run) Apple Music resumed: \(resumed ? "yes" : "NO") (status \(status), t=\(Self.time(time)), entry \(entry)); interruptions \(sessionEvents.isEmpty ? "none" : sessionEvents.joined(separator: ", ")); route changes \(routeChanges)",
        ]
        results.forEach { log($0) }
        lastResults = results
    }

    /// Waits, unless the run is stopped.
    private func hold(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    /// Reads a playing clock until it moves on from the reading before (a stale time left from
    /// the previous item doesn't move, so it can't count), as the proxy for "audible".
    private func waitForAdvance(timeout: TimeInterval, every interval: Duration, read: @MainActor () -> TimeInterval) async -> Advance? {
        let start = now()
        var previous = read()
        while now() - start < timeout {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return nil }
            let value = read()
            if value > previous + 0.001 { return Advance(at: now(), value: value) }
            previous = value
        }
        return nil
    }

    /// A watch's result; stopping the run stops the watch too (it's a task of its own, so it can
    /// read while `play()` is awaited).
    private func result(of watch: Task<Advance?, Never>) async -> Advance? {
        await withTaskCancellationHandler {
            await watch.value
        } onCancel: {
            watch.cancel()
        }
    }

    private func waitForLinkEnd(timeout: TimeInterval) async -> Bool {
        let start = now()
        while marks.linkEnd == nil, now() - start < timeout {
            try? await Task.sleep(for: .milliseconds(5))
            if Task.isCancelled { return false }
        }
        return marks.linkEnd != nil
    }

    /// MusicKit's status, every 50 ms while a run lasts; each change is logged.
    private func watchMusicKitStatus() async {
        var last: MusicKit.MusicPlayer.PlaybackStatus?
        while !Task.isCancelled {
            let player = ApplicationMusicPlayer.shared
            let status = player.state.playbackStatus
            if status != last {
                log("MusicKit status \(last.map { "\($0)" } ?? "—") → \(status) (t=\(Self.time(player.playbackTime)))")
                last = status
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: AVPlayer

    private func observe(_ player: AVPlayer, _ item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let at = CACurrentMediaTime()
                let status = item.status
                let error = item.error.map { "\($0)" }
                guard let self else { return }
                Task { @MainActor in self.linkItemStatus(status, error: error, at: at) }
            },
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let at = CACurrentMediaTime()
                let status = player.timeControlStatus
                let reason = player.reasonForWaitingToPlay?.rawValue
                guard let self else { return }
                Task { @MainActor in self.linkTimeControl(status, reason: reason, at: at) }
            },
        ]
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                let at = CACurrentMediaTime()
                MainActor.assumeIsolated { self?.linkEnded(at: at) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]).map { "\($0)" } ?? "no error"
                MainActor.assumeIsolated { self?.log("link: failed to play to its end: \(error)") }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.log("link: playback stalled") }
            },
        ]
    }

    private func linkItemStatus(_ status: AVPlayerItem.Status, error: String?, at: CFTimeInterval) {
        switch status {
        case .readyToPlay:
            if marks.linkReady == nil { marks.linkReady = at }
            log("link: item readyToPlay\(marks.aPause.map { " (\(Self.seconds(at - $0)) after A's pause())" } ?? "")", at: at)
        case .failed:
            log("link: item failed: \(error ?? "no error")", at: at)
        case .unknown:
            log("link: item status unknown", at: at)
        @unknown default:
            log("link: item status \(status.rawValue)", at: at)
        }
    }

    private func linkTimeControl(_ status: AVPlayer.TimeControlStatus, reason: String?, at: CFTimeInterval) {
        guard status != lastTimeControl else { return }
        lastTimeControl = status
        if status == .playing, marks.linkPlaying == nil { marks.linkPlaying = at }
        let after = marks.aPause.map { " (\(Self.seconds(at - $0)) after A's pause())" } ?? ""
        log("link: timeControlStatus \(Self.name(status))\(reason.map { " waiting: \($0)" } ?? "")\(after)", at: at)
    }

    private func linkEnded(at: CFTimeInterval) {
        guard marks.linkEnd == nil else { return }
        marks.linkEnd = at
        log("link: AVPlayerItemDidPlayToEndTime", at: at)
    }

    private func tearDownAVPlayer(log logging: Bool) {
        guard let player = avPlayer else { return }
        let call = now()
        player.pause()
        player.replaceCurrentItem(with: nil)
        observations.forEach { $0.invalidate() }
        observations = []
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        avPlayer = nil
        if logging { log("link: AVPlayer paused and torn down in \(since(call))") }
    }

    // MARK: Audio session

    /// Every interruption and route change, for the app's life once the screen has opened.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let at = CACurrentMediaTime()
            MainActor.assumeIsolated { self?.interrupted(type: type, options: options, reason: reason, at: at) }
        }
        _ = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let reason = (info[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription).map(Self.outputs) ?? "?"
            let at = CACurrentMediaTime()
            MainActor.assumeIsolated { self?.routeChanged(reason: reason, previous: previous, at: at) }
        }
        _ = center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt).flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:))
            let text = switch type {
            case .begin?: "begin"
            case .end?: "end"
            default: "?"
            }
            MainActor.assumeIsolated { self?.log("session: silenceSecondaryAudioHint \(text)") }
        }
        _ = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("session: media services were reset") }
        }
        _ = center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log("session: media services were lost") }
        }
    }

    private func interrupted(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?, reason: UInt?, at: CFTimeInterval) {
        let kind = switch type {
        case .began?: "began"
        case .ended?: "ended"
        default: "type ?"
        }
        var text = "interruption \(kind)"
        if let options { text += options.contains(.shouldResume) ? " shouldResume" : " options \(options.rawValue)" }
        if let reason { text += " reason \(Self.interruptionReason(reason))" }
        log("session: \(text)", at: at)
        if let runStart { sessionEvents.append("\(kind)@\(String(format: "%+.2f", at - runStart))s") }
    }

    private func routeChanged(reason: AVAudioSession.RouteChangeReason?, previous: String, at: CFTimeInterval) {
        if runStart != nil { routeChanges += 1 }
        let current = Self.outputs(AVAudioSession.sharedInstance().currentRoute)
        log("session: route change \(reason.map(Self.name) ?? "?") from [\(previous)] to [\(current)]", at: at)
    }

    private func logSession(_ when: String) {
        let session = AVAudioSession.sharedInstance()
        log("session (\(when)): \(session.category.rawValue) mode \(session.mode.rawValue) policy \(session.routeSharingPolicy.rawValue) otherAudioPlaying=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint) outputs [\(Self.outputs(session.currentRoute))]")
    }

    // MARK: Sonos

    func runSonos(household: SonosHousehold, reference: SonosTrackReference, room: SonosPlayer) {
        guard !sonosBusy, let a = songA, let b = songB, let track, track.status == "ready" else { return }
        sonosWatch?.cancel()
        sonosBusy = true
        sonosTask = Task {
            await sonosQueue(household: household, reference: reference, room: room, a: a, b: b, track: track)
            sonosBusy = false
            sonosTask = nil
        }
    }

    private func sonosQueue(household: SonosHousehold, reference: SonosTrackReference, room: SonosPlayer, a: Song, b: Song, track: CmdlpTrack) async {
        sonosStart = now()
        log("===== Sonos: A → link → B on \(room.roomName) (\(room.host)) =====")
        if let group = household.group(containing: room.id), group.coordinatorID != room.id {
            log("note: \(room.roomName) isn't its group's coordinator, so Sonos may answer 800 for that reason")
        }
        let client = SonosClient(transport: household.transport, host: room.host)
        let trackA = QueueTrack(id: a.id.rawValue, title: a.title, artist: a.artistName, album: a.albumTitle ?? "", duration: a.duration)
        let trackB = QueueTrack(id: b.id.rawValue, title: b.title, artist: b.artistName, album: b.albumTitle ?? "", duration: b.duration)
        do {
            let uriA = try reference.uri(for: trackA.id)
            let uriB = try reference.uri(for: trackB.id)
            let metadataA = try reference.metadata(for: trackA)
            let metadataB = try reference.metadata(for: trackB)
            let metadataLink = Self.linkMetadata(track)
            log("A URI \(uriA)")
            log("link URI \(Self.redacted(track.audioUrl))")
            log("link DIDL \(metadataLink)")
            log("B URI \(uriB)")
            try await sonosStep("RemoveAllTracksFromQueue") { try await client.clearQueue() }
            let numberA = try await sonosStep("AddURIToQueue A") { try await client.addToQueue(uri: uriA, metadata: metadataA, position: 0, asNext: false) }
            let numberLink = try await sonosStep("AddURIToQueue link") { try await client.addToQueue(uri: track.audioUrl, metadata: metadataLink, position: 0, asNext: false) }
            let numberB = try await sonosStep("AddURIToQueue B") { try await client.addToQueue(uri: uriB, metadata: metadataB, position: 0, asNext: false) }
            sonosLabels = [numberA: "A", numberLink: "link", numberB: "B"]
            log("queue: A #\(numberA), link #\(numberLink), B #\(numberB)")
            try await sonosStep("SetAVTransportURI") { try await client.setTransportURI(SonosURI.queue(of: room.id)) }
            do {
                try await client.setPlayModeNormal()
            } catch {
                log("SetPlayMode failed (carrying on): \(Self.describe(error))")
            }
            try await sonosStep("Seek TRACK_NR \(numberA)") { try await client.seek(trackNumber: numberA) }
            try await sonosStep("Play") { try await client.play() }
            log("Sonos: queued and playing from A, no fault")
        } catch {
            // Already logged by `sonosStep` (or a song Sonos can't take).
            if !(error is SonosError) { log("Sonos: \(error)") }
            return
        }
        startSonosWatch(client: client)
    }

    func sonosJumpNearEnd(household: SonosHousehold, room: SonosPlayer) {
        let client = SonosClient(transport: household.transport, host: room.host)
        Task {
            do {
                let position = try await client.positionInfo(withItem: false)
                guard let duration = position.duration, duration > 15 else {
                    log("Jump: track #\(position.track)'s length isn't known (or is under 15 s)")
                    return
                }
                let target = duration - 10
                try await sonosStep("Seek REL_TIME \(SonosTime.string(target))") { try await client.seek(to: target) }
                log("Jump: track #\(position.track) (\(sonosLabels[position.track] ?? "?")) to \(SonosTime.string(target)) of \(SonosTime.string(duration))")
                if sonosWatch == nil { startSonosWatch(client: client) }
            } catch {
                if !(error is SonosError) { log("Jump: \(Self.describe(error))") }
            }
        }
    }

    func stopSonos(household: SonosHousehold, room: SonosPlayer) {
        sonosTask?.cancel()
        sonosWatch?.cancel()
        sonosWatch = nil
        let client = SonosClient(transport: household.transport, host: room.host)
        Task {
            do {
                try await sonosStep("Pause") { try await client.pause() }
                log("Sonos: \(room.roomName) paused; stopped watching")
            } catch {}
        }
    }

    /// `GetPositionInfo` (and the transport state) every 2 s, until the room has been stopped
    /// for 10 s, the watch is stopped, or 20 minutes pass.
    private func startSonosWatch(client: SonosClient) {
        sonosWatch?.cancel()
        sonosWatch = Task {
            let started = now()
            var lastTrack: Int?
            var failures = 0
            var stoppedReads = 0
            let instance = [SonosRequest.Argument("InstanceID", "0")]
            while !Task.isCancelled, now() - started < 20 * 60 {
                do {
                    let reply = try await client.transport.send(SonosRequest(host: client.host, service: .avTransport, action: "GetPositionInfo", arguments: instance))
                    let state = try await client.transportState()
                    failures = 0
                    let number = reply["Track"].flatMap { Int($0) }
                    let label = number.flatMap { sonosLabels[$0] } ?? "?"
                    let relTime = reply["RelTime"] ?? "?"
                    let duration = reply["TrackDuration"] ?? "?"
                    let stateName = state?.rawValue ?? "?"
                    if number != lastTrack {
                        log("Sonos: now on track #\(number.map(String.init) ?? "?") (\(label))\(sonosStart.map { " at \(String(format: "%+.1f", now() - $0)) s" } ?? "")")
                        lastTrack = number
                    }
                    log("GetPositionInfo #\(number.map(String.init) ?? "?") \(label) \(relTime)/\(duration) \(stateName) \(Self.redacted(reply["TrackURI"] ?? "no URI"))")
                    sonosReading = "#\(number.map(String.init) ?? "?") \(label) · \(relTime) / \(duration) · \(stateName)"
                    stoppedReads = state == .stopped ? stoppedReads + 1 : 0
                    if stoppedReads >= 5 {
                        log("Sonos: stopped for 10 s; stopped watching")
                        break
                    }
                } catch {
                    failures += 1
                    log("GetPositionInfo failed: \(Self.describe(error))")
                    if failures >= 5 {
                        log("Sonos: 5 reads in a row failed; stopped watching")
                        break
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
            sonosWatch = nil
        }
    }

    /// One Sonos command; a failure is logged with its SOAP fault code and rethrown.
    private func sonosStep<T>(_ action: String, _ command: () async throws -> T) async throws -> T {
        do {
            let result = try await command()
            log("\(action): ok")
            return result
        } catch {
            log("\(action) failed: \(Self.describe(error))")
            throw error
        }
    }

    /// DIDL-Lite for the link's plain https URI: title, artist, art, and the music-track class.
    static func linkMetadata(_ track: CmdlpTrack) -> String {
        let e = SonosXMLEscape.escape
        var item = "<item id=\"\(e("linktest-\(track.id)"))\" parentID=\"-1\" restricted=\"true\">"
        item += "<dc:title>\(e(track.title ?? "Link"))</dc:title>"
        if let artist = track.artist, !artist.isEmpty { item += "<dc:creator>\(e(artist))</dc:creator>" }
        if let artwork = track.artwork, !artwork.isEmpty { item += "<upnp:albumArtURI>\(e(artwork))</upnp:albumArtURI>" }
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        item += "</item>"
        return didlOpen + item + "</DIDL-Lite>"
    }

    /// As `SonosTrackReference.didlOpen`.
    static let didlOpen = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"

    // MARK: Log

    func clearLog() {
        lines = []
        try? FileManager.default.removeItem(at: Self.logURL)
    }

    /// A line on screen, in link-test.log, and on stdout. `at`: when it happened, if earlier than
    /// now (a KVO change logged from the main actor a moment later).
    private func log(_ line: String, at: CFTimeInterval? = nil) {
        let offset = runStart.map { " [\(String(format: "%+8.3f", (at ?? now()) - $0))]" } ?? ""
        let stamped = "\(Self.clock.string(from: Date()))\(offset) \(line)"
        print("[link-test]\(offset) \(line)")
        lines.append(stamped)
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
        let data = Data((stamped + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: Formatting

    private func now() -> CFTimeInterval { CACurrentMediaTime() }

    private func since(_ start: CFTimeInterval?) -> String {
        guard let start else { return "—" }
        return Self.seconds(now() - start)
    }

    static func seconds(_ interval: CFTimeInterval) -> String { String(format: "%.3f s", interval) }

    static func time(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds) }

    static func minutes(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "?:??" }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The `audioUrl` without its key: it opens the file, so it stays off the log.
    static func redacted(_ url: String) -> String {
        guard let range = url.range(of: "sig=") else { return url }
        let rest = url[range.upperBound...]
        let tail = rest.firstIndex(of: "&").map { String(rest[$0...]) } ?? ""
        return String(url[..<range.upperBound]) + "…" + tail
    }

    static func describe(_ song: Song) -> String {
        "\(song.title) – \(song.artistName) (\(song.id.rawValue), \(minutes(song.duration)))"
    }

    static func describe(_ track: CmdlpTrack) -> String {
        "\(track.id) \(track.status) “\(track.title ?? "?")” – \(track.artist ?? "?") \(minutes(track.duration)) \(track.service ?? "?")"
            + (track.codec.map { " \($0)\(track.transcoded == true ? " re-encoded" : " copied")" } ?? "")
            + (track.size.map { " \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "")
            + (track.error.map { " error: \($0)" } ?? "")
    }

    static func statusLine(_ track: CmdlpTrack) -> String {
        switch track.status {
        case "pending":
            var parts = ["pending", track.stage ?? "starting"]
            if let percent = track.progress?.percent { parts.append(String(format: "%.0f%%", percent)) }
            if let bytes = track.progress?.downloadedBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            if let eta = track.progress?.eta { parts.append("\(Int(eta)) s left") }
            return parts.joined(separator: " · ")
        case "ready":
            var parts = ["ready"]
            if let codec = track.codec { parts.append("\(codec) \(track.transcoded == true ? "re-encoded" : "copied")") }
            if let size = track.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            return parts.joined(separator: " · ")
        default:
            return "\(track.status)\(track.error.map { ": \($0)" } ?? "")"
        }
    }

    /// A progress line for the log, in steps of 10% so it isn't one a second.
    static func progressLogLine(_ track: CmdlpTrack) -> String {
        guard track.status == "pending" else { return statusLine(track) }
        let step = track.progress?.percent.map { " \(Int($0 / 10) * 10)%+" } ?? ""
        return "pending \(track.stage ?? "starting")\(step)"
    }

    nonisolated static func outputs(_ route: AVAudioSessionRouteDescription) -> String {
        route.outputs.map { "\($0.portType.rawValue) “\($0.portName)”" }.joined(separator: ", ")
    }

    static func name(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waitingToPlayAtSpecifiedRate"
        case .playing: "playing"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "reason \(reason.rawValue)"
        }
    }

    static func interruptionReason(_ raw: UInt) -> String {
        switch AVAudioSession.InterruptionReason(rawValue: raw) {
        case .default?: "default"
        case .builtInMicMuted?: "builtInMicMuted"
        default: "\(raw)"
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case .upnp(let action, let code)? = error as? SonosError {
            let meaning = switch code {
            case 800: " (not linked, or not the group's coordinator)"
            case 701: " (refused: transition not available)"
            case 714: " (illegal MIME type)"
            default: ""
            }
            return "SOAP fault \(code.map(String.init) ?? "with no code") on \(action)\(meaning)"
        }
        return "\(error)"
    }
}
#endif
