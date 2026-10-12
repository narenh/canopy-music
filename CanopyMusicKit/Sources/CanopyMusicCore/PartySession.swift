import Foundation
import Observation

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    public var position: TimeInterval
    public var capturedAt: Date
}

/// The hub's guest Wi‑Fi, shown as a "Join Wi‑Fi" QR code. Hosts edit it from the web page; it's
/// never part of a snapshot, so guests' phones don't receive the password.
public struct WifiDetails: Codable, Equatable, Sendable {
    public var ssid: String
    public var password: String
    /// A plain QR code instead of the halftone one with the Wi‑Fi symbol, for phones that struggle.
    public var simpleQR: Bool

    public init(ssid: String = "", password: String = "", simpleQR: Bool = false) {
        self.ssid = ssid
        self.password = password
        self.simpleQR = simpleQR
    }
}

/// What phones (and anything else outside the app) see.
public struct PartySnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var playlistName: String?
    public var current: QueueItem?
    public var upNext: [QueueItem]
    public var lockedNextID: UUID?
    public var playback: PlaybackSnapshot
    /// False when the host has turned off reordering from phones.
    public var canReorder: Bool
    /// The friendly address (e.g. `music.local`), which the page moves to when the phone can reach it.
    public var address: String?

    // Zones (docs/multi-device.md). Optional so older pages and clients still decode.
    /// The hub's address by IP (`10.0.1.5` or `10.0.1.5:8080`), which every phone can open.
    public var lanAddress: String?
    public var zoneName: String?
    public var hubKind: HubKind?
    /// The hub's music service, e.g. "Apple Music", for search placeholders on displays.
    public var service: String?
    /// Whether displays get play/pause, skip and scrubbing.
    public var displaysCanControl: Bool?
    /// Recently played songs, newest first, for displays' Up next history.
    public var history: [QueueItem]?
    /// False when the host has turned off queueing from guests' phones (hosts and displays still can).
    public var canQueue: Bool?
    /// Whether the hub has an unlock PIN (iPad hubs; nil elsewhere). The PIN itself never leaves it.
    public var hasPIN: Bool?
    /// How many phones have Host Control.
    public var hostPhones: Int?
    /// The hub's device ID, so a phone keeps one host key per hub whatever address it used.
    public var hubID: String?
}

/// Owns the queue and keeps the player in step with it. Both the iPad UI and the phone server
/// go through this, so every edit follows the same rules.
@MainActor
@Observable
public final class PartySession {
    /// How early to stage the next track on engines that can't replace a staged track.
    static let lateStageLead: TimeInterval = 20

    public private(set) var state: QueueState
    public private(set) var isPlaying = false
    /// Set when this session mirrors another device's zone (display mode).
    @ObservationIgnored public let remote: (any ZoneRemote)?
    /// Zone details from the hub, for a display; this device's own, for a hub.
    public private(set) var hubKind: HubKind?
    /// The hub device's ID (stable across launches and renames).
    public private(set) var hubID: String?
    public var zoneName: String? {
        didSet { if zoneName != oldValue, remote == nil { broadcast() } }
    }
    /// The hub's music service title, e.g. "Apple Music".
    public var serviceName: String?
    /// Whether displays get play/pause, skip and scrubbing (a hub setting, on by default).
    public var displaysCanControl = true {
        didSet { if displaysCanControl != oldValue, remote == nil { broadcast() } }
    }
    /// Whether guests can add songs from their phones (a hub setting, on by default). Hosts and
    /// displays always can.
    public var phonesCanQueue = true {
        didSet { if phonesCanQueue != oldValue, remote == nil { broadcast() } }
    }
    /// Whether the hub has an unlock PIN (set by an iPad hub; nil on a TV, which has nothing to unlock).
    public var hasPIN: Bool? {
        didSet { if hasPIN != oldValue, remote == nil { broadcast() } }
    }
    /// Phones with Host Control (set by the hub).
    public var hostPhoneCount = 0 {
        didSet { if hostPhoneCount != oldValue, remote == nil { broadcast() } }
    }
    /// The hub's guest Wi‑Fi (hub only; not in snapshots).
    public var wifi = WifiDetails()
    /// A host set (non-empty) or removed (empty) the unlock PIN from the web page.
    @ObservationIgnored public var onPINChanged: (@MainActor (String) -> Void)?
    /// A host revoked every other phone's Host Control; returns the new key for that host.
    @ObservationIgnored public var onForgetHostPhones: (@MainActor () -> String?)?
    /// The hub's guest address by IP, from the hub (display) or set by the app (hub).
    public var lanAddress: String?
    /// Displays that have checked in recently (hub only).
    public private(set) var displays: [ZoneDisplay] = []
    /// Called when a host changes settings from the web page, so the app can save them.
    @ObservationIgnored public var onSettingsChanged: (@MainActor () -> Void)?
    /// Called when a host stops the zone from the web page (TV hubs).
    @ObservationIgnored public var onStopRequested: (@MainActor () -> Void)?
    public let catalog: any MusicCatalog
    @ObservationIgnored public let engine: any PlaybackEngine

    @ObservationIgnored private var stagedItemID: UUID?
    /// Tail of the serial chain of engine operations (see `serially`).
    @ObservationIgnored private var engineChain: Task<Void, Never>?
    /// The queue item the engine currently has loaded as its current track.
    @ObservationIgnored private var loadedItemID: UUID?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var listeners: [UUID: AsyncStream<PartySnapshot>.Continuation] = [:]
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Playback as last sent to listeners, and the loop that resends it if the player drifts.
    @ObservationIgnored private var lastSentPlayback: PlaybackSnapshot?
    @ObservationIgnored private var driftTask: Task<Void, Never>?
    /// How far listeners' idea of the playback time may be off before it's resent.
    static let driftTolerance: TimeInterval = 1

    public init(catalog: any MusicCatalog, engine: any PlaybackEngine, storeURL: URL? = nil) {
        self.catalog = catalog
        self.engine = engine
        self.storeURL = storeURL
        self.remote = nil
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           var restored = try? JSONDecoder().decode(QueueState.self, from: data) {
            // Nothing is staged in a fresh player.
            restored.unlockNext()
            state = restored
        } else {
            state = QueueState()
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        if !engine.canReplaceStaged { startLateStagingTicker() }
    }

    /// A display's session: mirrors the hub's queue from snapshots and sends edits to the hub.
    public init(remote: any ZoneRemote) {
        self.remote = remote
        self.catalog = RemoteCatalog { [weak remote] term in
            guard let remote else { return [] }
            return try await remote.search(term)
        }
        self.engine = MirrorEngine()
        self.storeURL = nil
        state = QueueState()
    }

    /// The hub's latest snapshot (display mode). A snapshot older than an optimistic local edit
    /// is skipped, so the edit doesn't flicker back; `force` takes it anyway (after a refused edit).
    public func apply(_ snapshot: PartySnapshot, force: Bool = false) {
        guard remote != nil else { return }
        if force || snapshot.version >= state.version {
            state = QueueState(mirroring: snapshot)
        }
        var playback = snapshot.playback
        // The hub's clock may differ from ours; time it from when it arrived.
        playback.capturedAt = Date()
        (engine as? MirrorEngine)?.playback = playback
        isPlaying = playback.isPlaying
        hubKind = snapshot.hubKind
        hubID = snapshot.hubID
        zoneName = snapshot.zoneName
        serviceName = snapshot.service
        phonesCanReorder = snapshot.canReorder
        displaysCanControl = snapshot.displaysCanControl ?? true
        phonesCanQueue = snapshot.canQueue ?? true
        guestAddress = snapshot.address
        lanAddress = snapshot.lanAddress
    }

    /// This device's own zone (hub).
    public func configureHub(kind: HubKind, id: String? = nil, zoneName: String, serviceName: String?) {
        hubKind = kind
        hubID = id
        self.zoneName = zoneName
        self.serviceName = serviceName
        broadcast()
    }

    /// A display checked in. Displays not heard from for 30 s drop off the list.
    public func noteDisplay(_ display: ZoneDisplay) {
        displays.removeAll { $0.id == display.id || Date().timeIntervalSince($0.lastSeen) > 30 }
        displays.append(display)
        displays.sort { $0.name < $1.name }
    }

    /// Applies settings sent by a host from the web page. `pin`: a new PIN, or "" to remove it.
    public func applyHostSettings(zoneName: String?, phonesCanQueue: Bool? = nil, phonesCanReorder: Bool?,
                                  displaysCanControl: Bool?, pin: String? = nil, wifi: WifiDetails? = nil) {
        if let wifi { self.wifi = wifi }
        if let zoneName, !zoneName.isEmpty { self.zoneName = zoneName }
        if let phonesCanQueue { self.phonesCanQueue = phonesCanQueue }
        if let phonesCanReorder { self.phonesCanReorder = phonesCanReorder }
        if let displaysCanControl { self.displaysCanControl = displaysCanControl }
        if let pin, hasPIN != nil { onPINChanged?(pin) }
        onSettingsChanged?()
    }

    /// Revokes Host Control from every phone but the one asking; returns its new key.
    public func forgetOtherHostPhones() -> String? {
        onForgetHostPhones?()
    }

    public func requestStop() {
        onStopRequested?()
    }

    public var hasParty: Bool { state.current != nil || !state.upNext.isEmpty }

    // MARK: Host actions

    /// Starts over with a new base playlist: stops playback and clears the queue and requests.
    /// Nothing plays until `play()`.
    public func load(playlist: PlaylistSummary) async throws {
        guard remote == nil else { return }
        let tracks = try await catalog.tracks(in: playlist)
        if engine.isPlaying { engine.pause() }
        stagedItemID = nil
        loadedItemID = nil
        isPlaying = false
        mutate { $0.load(playlist: tracks, name: playlist.name) }
    }

    public func shufflePlaylist() {
        guard remote == nil else { return }
        mutate { $0.shufflePlaylist() }
    }

    /// Plays the current song, loading it into the engine first if needed (e.g. after a relaunch).
    public func play() async throws {
        if let remote {
            isPlaying = true
            try await remote.send(.play)
            return
        }
        let result: Result<Void, any Error> = await serially {
            do {
                try await self.playNow()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    private func playNow() async throws {
        if state.current == nil { mutate { $0.advance() } }
        guard let current = state.current else { return }
        if loadedItemID == current.id {
            try await engine.resume()
            isPlaying = engine.isPlaying
            broadcast()
        } else {
            try await play(current)
        }
    }

    public func pause() {
        if let remote {
            isPlaying = false
            Task { try? await remote.send(.pause) }
            return
        }
        engine.pause()
        isPlaying = engine.isPlaying
        broadcast()
    }

    public func togglePlayPause() async {
        if engine.isPlaying || (remote != nil && isPlaying) {
            pause()
        } else {
            try? await play()
        }
    }

    /// Like the Music app: restarts the song if it's more than a few seconds in, otherwise goes
    /// to the previous song (and keeps playing or paused as it was).
    public func previous() async {
        if let remote {
            try? await remote.send(.previous)
            return
        }
        await serially { await self.previousNow() }
    }

    private func previousNow() async {
        guard engine.currentTime <= 3, !state.history.isEmpty else {
            engine.restartCurrent()
            broadcast()
            return
        }
        let wasPlaying = engine.isPlaying
        stagedItemID = nil
        mutate { $0.goBack() }
        if wasPlaying, let current = state.current {
            try? await play(current)
        } else {
            loadedItemID = nil
        }
    }

    public func seek(to time: TimeInterval) {
        if let remote {
            if let mirror = engine as? MirrorEngine {
                mirror.playback = PlaybackSnapshot(isPlaying: mirror.isPlaying, position: max(0, time), capturedAt: Date())
            }
            Task { try? await remote.send(.seek(max(0, time))) }
            return
        }
        engine.seek(to: max(0, time))
        broadcast()
    }

    public func skip() async {
        if let remote {
            try? await remote.send(.next)
            return
        }
        await serially { await self.skipNow() }
    }

    private func skipNow() async {
        let wasPlaying = engine.isPlaying
        if wasPlaying, stagedItemID != nil, (try? await engine.skipToStaged()) != nil { return }
        mutate { $0.advance() }
        if wasPlaying, let current = state.current { try? await play(current) }
    }

    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        engine.setCrossfade(enabled: enabled, duration: duration)
    }

    public func clearRequests() {
        mutate { $0.clearRequests() }
    }

    // MARK: Guest actions

    @discardableResult
    public func add(_ track: QueueTrack, by requester: Requester) -> AddResult {
        if let remote {
            // Show it right away (with the ID the hub will use), then send it.
            let id = UUID()
            let result = state.addRequest(track, by: requester, id: id)
            if case .added = result { Task { try? await remote.send(.add(track, itemID: id)) } }
            return result
        }
        return mutate { $0.addRequest(track, by: requester) }
    }

    /// Adds a request with an ID chosen by a display, so its optimistic copy matches.
    @discardableResult
    public func add(_ track: QueueTrack, by requester: Requester, id: UUID) -> AddResult {
        mutate { $0.addRequest(track, by: requester, id: id) }
    }

    @discardableResult
    public func move(_ id: UUID, to index: Int) -> Bool {
        if remote != nil {
            // Displays send moves as "after this item", like the web page.
            guard let from = state.upNext.firstIndex(where: { $0.id == id }) else { return false }
            var others = state.upNext.map(\.id)
            others.remove(at: from)
            let to = min(max(index, 0), others.count)
            return move(id, after: to == 0 ? nil : others[to - 1])
        }
        return mutate { $0.move(id, to: index) }
    }

    @discardableResult
    public func move(_ id: UUID, after anchor: UUID?) -> Bool {
        if let remote {
            let ok = state.move(id, after: anchor)
            if ok { Task { try? await remote.send(.move(id, after: anchor)) } }
            return ok
        }
        return mutate { $0.move(id, after: anchor) }
    }

    /// Removes an item. When `clientID` is given (a phone), only that phone's own requests can be removed.
    @discardableResult
    public func remove(_ id: UUID, asClient clientID: String? = nil) -> Bool {
        // Displays can't delete.
        guard remote == nil else { return false }
        if let clientID {
            guard let item = state.upNext.first(where: { $0.id == id }),
                  item.requester?.clientID == clientID else { return false }
        }
        return mutate { $0.remove(id) } != nil
    }

    /// Random key that gives a phone host control (scanned from the iPad's Settings). Phones with it
    /// can play, pause, skip, reorder and remove anything. nil turns host control off.
    public var hostKey: String?
    /// Called with a phone's client ID each time it shows a valid host key.
    public var onHostPhone: (@MainActor (String) -> Void)?

    public func isHost(key: String?, clientID: String? = nil) -> Bool {
        guard let hostKey, let key, !key.isEmpty, key == hostKey else { return false }
        if let clientID { onHostPhone?(clientID) }
        return true
    }

    /// The guest page's friendly address (`music.local`, plus `:port` if not 80). Sent as it
    /// changes, so a page on the old name can follow a renamed zone to its new one.
    public var guestAddress: String? {
        didSet { if guestAddress != oldValue, remote == nil { broadcast() } }
    }

    /// Whether phones may drag songs around. The iPad can always reorder.
    public var phonesCanReorder = true {
        didSet { if phonesCanReorder != oldValue { broadcast() } }
    }

    // MARK: Snapshots

    public func snapshot() -> PartySnapshot {
        PartySnapshot(
            version: state.version,
            playlistName: state.playlistName,
            current: state.current,
            upNext: state.upNext,
            lockedNextID: state.lockedNextID,
            playback: PlaybackSnapshot(isPlaying: engine.isPlaying, position: engine.currentTime, capturedAt: Date()),
            canReorder: phonesCanReorder,
            address: guestAddress,
            lanAddress: lanAddress,
            zoneName: zoneName,
            hubKind: hubKind,
            service: serviceName,
            displaysCanControl: displaysCanControl,
            history: Array(state.history.prefix(20)),
            canQueue: phonesCanQueue,
            hasPIN: hasPIN,
            hostPhones: hostPhoneCount,
            hubID: hubID
        )
    }

    /// Emits the current snapshot immediately, then again after every change.
    public func snapshots() -> AsyncStream<PartySnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: PartySnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        let snap = snapshot()
        lastSentPlayback = snap.playback
        continuation.yield(snap)
        if remote == nil { startDriftCheck() }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    // MARK: Internals

    @discardableResult
    private func mutate<Result>(_ body: (inout QueueState) -> Result) -> Result {
        let result = body(&state)
        broadcast()
        scheduleSave()
        Task { await syncStaging() }
        return result
    }

    private func play(_ item: QueueItem) async throws {
        stagedItemID = nil
        loadedItemID = item.id
        do {
            try await engine.play(item.track)
        } catch {
            // Nothing is loaded, so nothing gets staged behind it. Staging onto a player whose
            // play just failed can hang (Apple Music on tvOS reconnects on the main thread).
            loadedItemID = nil
            throw error
        }
        isPlaying = engine.isPlaying
        broadcast()
        Task { await syncStaging() }
    }

    /// Runs engine operations one at a time, in order. Overlapping operations (two quick backs,
    /// a skip while the next song is being staged) can wedge Apple's out-of-process player,
    /// which hangs the main thread. Never call this from inside an operation it's running.
    private func serially<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = engineChain
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        engineChain = Task { _ = await task.value }
        return await task.value
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .advancedToStaged:
            let id = stagedItemID
            stagedItemID = nil
            mutate { $0.advance(to: id) }
            loadedItemID = state.current?.id
        case .reachedEnd:
            stagedItemID = nil
            loadedItemID = nil
            mutate { $0.advance() }
            if let current = state.current {
                Task { await serially { try? await self.play(current) } }
            }
        case .statusChanged:
            isPlaying = engine.isPlaying
            broadcast()
        }
    }

    /// Makes the engine's staged track match the queue. Calls are coalesced so only one runs at a time.
    func syncStaging() async {
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while needsSync {
            needsSync = false
            await serially { await self.stageIfNeeded() }
        }
    }

    /// Makes the engine's staged track match `upNext.first` (or the locked item).
    private func stageIfNeeded() async {
        // Only stage behind a song the engine actually has loaded.
        guard let current = state.current, loadedItemID == current.id else { return }
        let desired: QueueItem?
        if engine.canReplaceStaged {
            desired = state.upNext.first
        } else {
            // Late staging: only stage once the ticker has locked the next item.
            guard stagedItemID == nil, let locked = state.lockedNextID,
                  let first = state.upNext.first, first.id == locked else { return }
            desired = first
        }
        guard desired?.id != stagedItemID else { return }
        do {
            try await engine.stage(desired?.track)
            stagedItemID = desired?.id
        } catch {
            // Leave stagedItemID alone; the next change retries, and `.reachedEnd` covers a miss.
        }
    }

    private func startLateStagingTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.stagedItemID == nil, let duration = self.state.current?.track.duration,
                      duration - self.engine.currentTime < Self.lateStageLead,
                      !self.state.upNext.isEmpty else { continue }
                self.mutate { $0.lockNext() }
            }
        }
    }

    private func broadcast() {
        guard !listeners.isEmpty else { return }
        let snap = snapshot()
        lastSentPlayback = snap.playback
        for continuation in listeners.values { continuation.yield(snap) }
    }

    /// Listeners work out the playback time from the last snapshot, but the player's time also
    /// moves without an event: a song starts only once it has buffered, a seek lands late, or the
    /// system seeks. So while anyone is listening, resend when the real time has drifted.
    private func startDriftCheck() {
        guard driftTask == nil else { return }
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard !self.listeners.isEmpty, let sent = self.lastSentPlayback else { continue }
                let expected = sent.isPlaying ? sent.position + Date().timeIntervalSince(sent.capturedAt) : sent.position
                if sent.isPlaying != self.engine.isPlaying || abs(self.engine.currentTime - expected) > Self.driftTolerance {
                    self.broadcast()
                }
            }
        }
    }

    private func scheduleSave() {
        guard let storeURL else { return }
        saveTask?.cancel()
        saveTask = Task { [state] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
