import Foundation
import Observation

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    public var position: TimeInterval
    public var capturedAt: Date
}

/// What phones (and anything else outside the app) see.
public struct PartySnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var playlistName: String?
    public var current: QueueItem?
    public var upNext: [QueueItem]
    public var lockedNextID: UUID?
    public var playback: PlaybackSnapshot
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
    public let catalog: any MusicCatalog
    @ObservationIgnored public let engine: any PlaybackEngine

    @ObservationIgnored private var stagedItemID: UUID?
    /// The queue item the engine currently has loaded as its current track.
    @ObservationIgnored private var loadedItemID: UUID?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var listeners: [UUID: AsyncStream<PartySnapshot>.Continuation] = [:]
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    public init(catalog: any MusicCatalog, engine: any PlaybackEngine, storeURL: URL? = nil) {
        self.catalog = catalog
        self.engine = engine
        self.storeURL = storeURL
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

    public var hasParty: Bool { state.current != nil || !state.upNext.isEmpty }

    // MARK: Host actions

    /// Loads a base playlist without starting playback. If nothing is current yet, the first song
    /// becomes current (ready to play). Whatever is playing keeps playing.
    public func load(playlist: PlaylistSummary, shuffle: Bool) async throws {
        let tracks = try await catalog.tracks(in: playlist)
        mutate { $0.load(playlist: tracks, name: playlist.name, shuffle: shuffle) }
        if state.current == nil {
            mutate { $0.advance() }
        }
    }

    /// Plays the current song, loading it into the engine first if needed (e.g. after a relaunch).
    public func play() async throws {
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
        engine.pause()
        isPlaying = engine.isPlaying
        broadcast()
    }

    public func togglePlayPause() async {
        if engine.isPlaying {
            pause()
        } else {
            try? await play()
        }
    }

    /// "Previous" only ever goes back to the start of the current song.
    public func restartCurrentSong() {
        engine.restartCurrent()
        broadcast()
    }

    public func skip() async {
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
    public func add(_ track: Track, by requester: Requester) -> AddResult {
        mutate { $0.addRequest(track, by: requester) }
    }

    @discardableResult
    public func move(_ id: UUID, to index: Int) -> Bool {
        mutate { $0.move(id, to: index) }
    }

    @discardableResult
    public func move(_ id: UUID, after anchor: UUID?) -> Bool {
        mutate { $0.move(id, after: anchor) }
    }

    /// Removes an item. When `clientID` is given (a phone), only that phone's own requests can be removed.
    @discardableResult
    public func remove(_ id: UUID, asClient clientID: String? = nil) -> Bool {
        if let clientID {
            guard let item = state.upNext.first(where: { $0.id == id }),
                  item.requester?.clientID == clientID else { return false }
        }
        return mutate { $0.remove(id) } != nil
    }

    // MARK: Snapshots

    public func snapshot() -> PartySnapshot {
        PartySnapshot(
            version: state.version,
            playlistName: state.playlistName,
            current: state.current,
            upNext: state.upNext,
            lockedNextID: state.lockedNextID,
            playback: PlaybackSnapshot(isPlaying: engine.isPlaying, position: engine.currentTime, capturedAt: Date())
        )
    }

    /// Emits the current snapshot immediately, then again after every change.
    public func snapshots() -> AsyncStream<PartySnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: PartySnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.yield(snapshot())
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
        try await engine.play(item.track)
        isPlaying = engine.isPlaying
        broadcast()
        await syncStaging()
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
                Task { try? await play(current) }
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
            // Only stage behind a song the engine actually has loaded.
            guard let current = state.current, loadedItemID == current.id else { continue }
            let desired: QueueItem?
            if engine.canReplaceStaged {
                desired = state.upNext.first
            } else {
                // Late staging: only stage once the ticker has locked the next item.
                guard stagedItemID == nil, let locked = state.lockedNextID,
                      let first = state.upNext.first, first.id == locked else { continue }
                desired = first
            }
            guard desired?.id != stagedItemID else { continue }
            do {
                try await engine.stage(desired?.track)
                stagedItemID = desired?.id
            } catch {
                // Leave stagedItemID alone; the next change retries, and `.reachedEnd` covers a miss.
            }
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
        for continuation in listeners.values { continuation.yield(snap) }
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
