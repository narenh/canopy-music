import Foundation

/// Where a `SonosEngine` plays: a group's coordinator (commands go there), plus any rooms to
/// pull into its group when playback starts.
public struct SonosTarget: Codable, Hashable, Sendable {
    public struct Room: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var host: String
        public init(id: String, name: String, host: String) {
            self.id = id
            self.name = name
            self.host = host
        }
    }

    public var coordinator: Room
    /// Other rooms to join to the coordinator's group (each gets `x-rincon:{coordinator}`).
    public var joining: [Room]
    /// The coordinator room is currently a non-coordinating member of another group, so it
    /// leaves that group first.
    public var leavesGroup: Bool

    public init(coordinator: Room, joining: [Room] = [], leavesGroup: Bool = false) {
        self.coordinator = coordinator
        self.joining = joining
        self.leavesGroup = leavesGroup
    }

    public var name: String { ([coordinator] + joining).map(\.name).joined(separator: " + ") }
}

/// What the engine reads back each poll, turned into what it means for the session.
public enum SonosPlaybackRules {
    public struct Observation: Equatable, Sendable {
        /// 1-based queue position.
        public var trackNumber: Int
        /// Canopy Music's id for the track (`SonosURI.canopyTrackID`); nil when it isn't a
        /// service track (TV, line-in, radio, Spotify Connect).
        public var trackID: String?
        public var state: SonosTransportState?
        public var position: TimeInterval?
        public var duration: TimeInterval?

        public init(trackNumber: Int, trackID: String?, state: SonosTransportState?, position: TimeInterval? = nil, duration: TimeInterval? = nil) {
            self.trackNumber = trackNumber
            self.trackID = trackID
            self.state = state
            self.position = position
            self.duration = duration
        }

        public init(_ info: SonosPositionInfo, state: SonosTransportState?) {
            self.init(trackNumber: info.track, trackID: info.trackURI.flatMap(SonosURI.canopyTrackID(of:)),
                      state: state, position: info.position, duration: info.duration ?? info.item?.duration)
        }
    }

    public struct Context: Equatable, Sendable {
        public var currentID: String?
        public var currentNumber: Int?
        public var stagedID: String?
        public var stagedNumber: Int?
        public var pausedByUs: Bool
        public var reportedEnd: Bool
        /// Our current song has been seen playing (so a stop afterwards is its end, not the
        /// moment before it starts).
        public var sawPlaying: Bool

        public init(currentID: String?, currentNumber: Int?, stagedID: String? = nil, stagedNumber: Int? = nil,
                    pausedByUs: Bool = false, reportedEnd: Bool = false, sawPlaying: Bool = false) {
            self.currentID = currentID
            self.currentNumber = currentNumber
            self.stagedID = stagedID
            self.stagedNumber = stagedNumber
            self.pausedByUs = pausedByUs
            self.reportedEnd = reportedEnd
            self.sawPlaying = sawPlaying
        }
    }

    public enum Step: Equatable, Sendable {
        case nothing
        /// The player moved on to the staged song (`PlaybackEvent.advancedToStaged`).
        case advancedToStaged
        /// Our song ended with nothing after it, or the player went on past our songs
        /// (`PlaybackEvent.reachedEnd`): the session plays its next song.
        case reachedEnd
        /// Something else is playing in the room now (the Sonos app, the TV, AirPlay, Spotify
        /// Connect): the session doesn't fight it, and the next play takes the room back.
        case lostControl
    }

    public static func isPlaying(_ state: SonosTransportState?) -> Bool {
        state == .playing || state == .transitioning
    }

    public static func step(_ o: Observation, _ c: Context) -> Step {
        guard let currentID = c.currentID else { return .nothing }
        guard let trackID = o.trackID else {
            // Not a service track at all: another source has the room.
            return isPlaying(o.state) ? .lostControl : .nothing
        }
        if let stagedID = c.stagedID, trackID == stagedID, o.trackNumber == c.stagedNumber || trackID != currentID {
            return .advancedToStaged
        }
        if trackID == currentID {
            if o.state == .stopped, c.sawPlaying, !c.pausedByUs, !c.reportedEnd { return .reachedEnd }
            return .nothing
        }
        // A service track that's neither ours nor staged.
        guard !c.reportedEnd else { return .nothing }
        // Stopped there: the queue ran out (Sonos goes back to its first entry and stops).
        if o.state == .stopped { return c.sawPlaying && !c.pausedByUs ? .reachedEnd : .nothing }
        // Further down our queue (an entry left behind by a restage): hand back to the session's
        // queue. Anywhere else (the Sonos app replaced the queue, or went back): someone else's choice.
        if let currentNumber = c.currentNumber, o.trackNumber > currentNumber { return .reachedEnd }
        return isPlaying(o.state) ? .lostControl : .nothing
    }
}

/// Plays through a Sonos group: Canopy Music keeps choosing the songs, and Sonos streams each
/// one from a music-service account linked in the Sonos app (`SonosTrackReference`). It owns the
/// group's Sonos queue while it plays: the current song, then the staged one after it.
///
/// Events come from polling `GetPositionInfo` and `GetTransportInfo` (about once a second while
/// playing, every few seconds paused). UPnP event subscriptions aren't used.
@MainActor
public final class SonosEngine: PlaybackEngine {
    public let canReplaceStaged = true
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    public let target: SonosTarget
    public let reference: SonosTrackReference
    private let client: SonosClient
    private let transport: any SonosTransport

    private var currentTrack: QueueTrack?
    private var currentNumber: Int?
    private var stagedTrack: QueueTrack?
    private var stagedNumber: Int?
    private var pausedByUs = false
    private var reportedEnd = false
    private var sawPlaying = false
    /// Another source took the room over; the next play or resume starts our song again.
    private var lostControl = false
    /// No pause or setting is sent before this engine has played something: the room may be
    /// playing someone else's music, and dropping an unused engine pauses it.
    public private(set) var hasStarted = false
    private var hasGrouped = false
    private var crossfade: Bool?
    /// Commands in flight: polls wait, so they don't read a half-built queue.
    private var busy = 0
    private var settleUntil = Date.distantPast
    private var lastPlaying: Bool?
    private var poller: Task<Void, Never>?

    private var cachedPlaying = false
    private var cachedTime: TimeInterval = 0
    private var cachedAt = Date()

    /// Poll spacing. Tests shorten it.
    public var pollInterval: (playing: Duration, paused: Duration) = (.seconds(1), .seconds(3))
    /// Debug output (`[sonos-engine] …`); nil is silent.
    public var log: (@MainActor (String) -> Void)?

    public init(target: SonosTarget, reference: SonosTrackReference, transport: any SonosTransport = URLSessionSonosTransport()) {
        self.target = target
        self.reference = reference
        self.transport = transport
        client = SonosClient(transport: transport, host: target.coordinator.host)
    }

    public var isPlaying: Bool { cachedPlaying }
    public var currentTime: TimeInterval {
        cachedPlaying ? cachedTime + Date().timeIntervalSince(cachedAt) : cachedTime
    }

    private func cache(playing: Bool, time: TimeInterval) {
        cachedPlaying = playing
        cachedTime = time
        cachedAt = Date()
    }

    // MARK: PlaybackEngine

    /// Empties the group's Sonos queue, puts `track` in it and plays it.
    public func play(_ track: QueueTrack) async throws {
        let uri = try reference.uri(for: track.id)
        let metadata = try reference.metadata(for: track)
        busy += 1
        defer { busy -= 1 }
        settleUntil = Date().addingTimeInterval(1.5)
        reportedEnd = false
        pausedByUs = false
        sawPlaying = false
        lostControl = false
        stagedTrack = nil
        stagedNumber = nil
        hasStarted = true
        try await groupRoomsIfNeeded()
        try await client.clearQueue()
        let number = try await client.addToQueue(uri: uri, metadata: metadata, position: 0, asNext: false)
        try await client.setTransportURI(SonosURI.queue(of: target.coordinator.id))
        // Shuffle or repeat in the Sonos app would play the queue out of order.
        try? await client.setPlayModeNormal()
        if let crossfade { try? await client.setCrossfade(crossfade) }
        try await client.seek(trackNumber: number)
        try await client.play()
        currentTrack = track
        currentNumber = number
        cache(playing: true, time: 0)
        log?("play \(track.title) at #\(number)")
        startPolling()
    }

    /// Puts `track` right after the current song in the Sonos queue, then removes the song
    /// staged before it (now one further down). Inserting first means a failed removal still
    /// plays the right song next.
    public func stage(_ track: QueueTrack?) async throws {
        guard let current = currentNumber else {
            stagedTrack = nil
            stagedNumber = nil
            return
        }
        let uri = try track.map { try reference.uri(for: $0.id) }
        let metadata = try track.map { try reference.metadata(for: $0) }
        busy += 1
        defer { busy -= 1 }
        // The player may already be on the staged song (a restage as a song ends): take that
        // first. This stage is then stale; the session stages again behind the new song.
        if try await applyLatestObservation() { throw CancellationError() }
        let previous = stagedNumber
        if let track, let uri, let metadata {
            let number = try await client.addToQueue(uri: uri, metadata: metadata, position: current + 1, asNext: true)
            stagedTrack = track
            stagedNumber = number
            if previous != nil {
                do {
                    try await client.removeFromQueue(trackNumber: number + 1)
                } catch {
                    log?("couldn't remove the previously staged song: \(error)")
                }
            }
            log?("staged \(track.title) at #\(number)")
        } else {
            stagedTrack = nil
            stagedNumber = nil
            if let previous { try await client.removeFromQueue(trackNumber: previous) }
            log?("unstaged")
        }
    }

    public func resume() async throws {
        pausedByUs = false
        guard !lostControl, currentNumber != nil else {
            // The room is on something else now (or was never ours): start our song again.
            guard let currentTrack else { throw SonosError.badResponse(action: "Play") }
            let position = cachedTime
            try await play(currentTrack)
            if position > 1 { seek(to: position) }
            return
        }
        busy += 1
        defer { busy -= 1 }
        settleUntil = Date().addingTimeInterval(1)
        try await client.play()
        cache(playing: true, time: cachedTime)
    }

    public func pause() {
        pausedByUs = true
        cache(playing: false, time: currentTime)
        guard hasStarted, !lostControl else { return }
        settleUntil = Date().addingTimeInterval(1)
        Task { [client] in try? await client.pause() }
    }

    public func skipToStaged() async throws {
        guard let stagedNumber else { throw CancellationError() }
        busy += 1
        defer { busy -= 1 }
        try await client.seek(trackNumber: stagedNumber)
        try await client.play()
        // Picked up at once rather than at the next poll.
        _ = try? await applyLatestObservation()
    }

    public func restartCurrent() { seek(to: 0) }

    public func seek(to time: TimeInterval) {
        cache(playing: cachedPlaying, time: time)
        guard hasStarted, !lostControl else { return }
        settleUntil = Date().addingTimeInterval(1)
        Task { [client] in try? await client.seek(to: time) }
    }

    /// Sonos's own crossfade (its length is Sonos's), set on the group when playback starts.
    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        crossfade = enabled
        guard hasStarted, !lostControl else { return }
        Task { [client] in try? await client.setCrossfade(enabled) }
    }

    // MARK: Grouping

    private func groupRoomsIfNeeded() async throws {
        guard !hasGrouped else { return }
        if target.leavesGroup { try await client.leaveGroup() }
        for room in target.joining {
            // A room that can't join doesn't stop the music in the others.
            do {
                try await SonosClient(transport: transport, host: room.host).setTransportURI(SonosURI.joinGroup(of: target.coordinator.id))
            } catch {
                log?("\(room.name) couldn't join: \(error)")
            }
        }
        hasGrouped = true
    }

    // MARK: Polling

    private func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self.map { $0.cachedPlaying ? $0.pollInterval.playing : $0.pollInterval.paused } ?? .seconds(1)
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.poll()
            }
        }
    }

    /// Stops polling for good (the session dropped this engine).
    public func stop() {
        poller?.cancel()
        poller = nil
    }

    func poll() async {
        guard busy == 0, Date() > settleUntil, currentTrack != nil else { return }
        do {
            _ = try await applyLatestObservation()
        } catch {
            log?("poll failed: \(error)")
        }
    }

    /// Reads the player and acts on it. True when it moved on to the staged song.
    @discardableResult
    func applyLatestObservation() async throws -> Bool {
        let info = try await client.positionInfo()
        let state = try await client.transportState()
        return apply(SonosPlaybackRules.Observation(info, state: state))
    }

    @discardableResult
    func apply(_ observation: SonosPlaybackRules.Observation) -> Bool {
        let context = SonosPlaybackRules.Context(
            currentID: currentTrack?.id, currentNumber: currentNumber,
            stagedID: stagedTrack?.id, stagedNumber: stagedNumber,
            pausedByUs: pausedByUs, reportedEnd: reportedEnd, sawPlaying: sawPlaying
        )
        let step = SonosPlaybackRules.step(observation, context)
        let ours = observation.trackID != nil && (observation.trackID == currentTrack?.id || observation.trackID == stagedTrack?.id)
        let playing = !lostControl && step != .lostControl && SonosPlaybackRules.isPlaying(observation.state)
        // Before any event: the session snapshots the time as it handles them.
        cache(playing: playing, time: ours ? (observation.position ?? 0) : cachedTime)
        if observation.state == .playing, observation.trackID == currentTrack?.id { sawPlaying = true }

        var advanced = false
        switch step {
        case .nothing:
            break
        case .advancedToStaged:
            log?("advanced to \(stagedTrack?.title ?? "?")")
            currentTrack = stagedTrack
            currentNumber = observation.trackNumber
            stagedTrack = nil
            stagedNumber = nil
            reportedEnd = false
            sawPlaying = observation.state == .playing
            advanced = true
            onEvent?(.advancedToStaged)
        case .reachedEnd:
            log?("reached end (on #\(observation.trackNumber), \(observation.state?.rawValue ?? "?"))")
            reportedEnd = true
            onEvent?(.reachedEnd)
        case .lostControl:
            log?("another source has the room")
            lostControl = true
            reportedEnd = true
        }
        if playing != lastPlaying {
            lastPlaying = playing
            onEvent?(.statusChanged)
        }
        return advanced
    }
}
