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

    public var name: String { rooms.map(\.name).joined(separator: " + ") }

    /// Every room it plays in, coordinator first.
    public var rooms: [Room] { [coordinator] + joining }
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
            // Not a service track at all, and playing: another source has the room. Not while
            // it's transitioning: between songs the player can have no track URI for a moment.
            return o.state == .playing ? .lostControl : .nothing
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

    /// Where it plays now. Rooms join and leave while it plays (`addRoom`, `removeRoom`), and the
    /// coordinator can change hands; commands and polls follow it.
    public private(set) var target: SonosTarget {
        didSet {
            if target.coordinator.id != oldValue.coordinator.id { client = SonosClient(transport: transport, host: target.coordinator.host) }
            if target != oldValue { onTargetChanged?(target) }
        }
    }
    public let reference: SonosTrackReference
    private var client: SonosClient
    private let transport: any SonosTransport
    /// After each change of `target`, so the app can remember the rooms for the next launch.
    public var onTargetChanged: (@MainActor (SonosTarget) -> Void)?
    /// The session's current song as restored at launch: the group may still be playing it from
    /// before (Sonos plays on while the app is gone), and then it's ours to pause on `shutDown`.
    public var restoredTrackID: String?
    private var isShutDown = false

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
    /// Commands in flight: polls wait, so they don't read a half-built queue (or a group that's
    /// changing hands).
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
        guard hasStarted else { return }
        settleUntil = Date().addingTimeInterval(1)
        guard lostControl else {
            Task { [client] in try? await client.pause() }
            return
        }
        // Another source seemed to have the room: it's left alone, unless the group is on our
        // songs after all (a misread), which mustn't play on under the next output.
        let ours = Set([currentTrack?.id, stagedTrack?.id].compactMap { $0 })
        Task { [client] in
            guard let info = try? await client.positionInfo(), let id = info.trackURI.flatMap(SonosURI.canopyTrackID(of:)), ours.contains(id),
                  let state = try? await client.transportState(), SonosPlaybackRules.isPlaying(state) else { return }
            try? await client.pause()
        }
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
        target.leavesGroup = false
    }

    /// The group is set up on the speakers (the first play did it): rooms join and leave it for
    /// real from now on. Before that, they only change `target`.
    public var isGrouped: Bool { hasGrouped }

    /// Before anything has played: a new target outright (the rooms are grouped at the first play).
    public func retarget(_ next: SonosTarget) {
        guard !hasGrouped else { return }
        target = next
    }

    /// Adds a room while the music plays: it joins the coordinator's group (`x-rincon:`) and
    /// plays in sync, from wherever the group is, without the song restarting. A room that's
    /// busy with something else leaves that for this. Before the first play it's only noted.
    /// `waitUntilGrouped` says when Sonos has it in the group.
    public func addRoom(_ room: SonosTarget.Room) async throws {
        guard !target.rooms.contains(where: { $0.id == room.id }) else { return }
        if hasGrouped {
            busy += 1
            defer { busy -= 1 }
            try await SonosClient(transport: transport, host: room.host).setTransportURI(SonosURI.joinGroup(of: target.coordinator.id))
            log?("\(room.name) joining \(target.coordinator.name)")
        }
        target.joining.append(room)
    }

    /// Reads the group's topology until `roomID` is in the coordinator's group, for up to
    /// `timeout`. True once it is.
    public func waitUntilGrouped(_ roomID: String, timeout: Duration = .seconds(10), every interval: Duration = .milliseconds(500)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            if let groups = try? await client.zoneGroups(),
               groups.contains(where: { $0.coordinatorID == target.coordinator.id && $0.members.contains { $0.id == roomID } }) {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return false
    }

    /// Takes a room out while the music plays on in the others, without a restart. A member
    /// leaves the group (`BecomeCoordinatorOfStandaloneGroup`). The coordinator first hands the
    /// group to the next room (`DelegateGroupCoordinationTo`, not rejoining), which takes the
    /// queue and what's playing with it; commands and polls then go to the new coordinator. If
    /// the new coordinator turns out not to be on our queue, the song is put back there at the
    /// same place (a short gap rather than silence). Either way the room that left is stopped if
    /// it plays on by itself. The last room can't be removed.
    public func removeRoom(_ roomID: String) async throws {
        guard target.rooms.count > 1, let room = target.rooms.first(where: { $0.id == roomID }) else { throw SonosError.lastRoom }
        guard hasGrouped else {
            // Nothing set up on the speakers yet.
            if roomID == target.coordinator.id {
                target = SonosTarget(coordinator: target.joining[0], joining: Array(target.joining.dropFirst()))
            } else {
                target.joining.removeAll { $0.id == roomID }
            }
            return
        }
        busy += 1
        defer { busy -= 1 }
        settleUntil = Date().addingTimeInterval(2)
        let leaving = SonosClient(transport: transport, host: room.host)
        if roomID != target.coordinator.id {
            try await leaving.leaveGroup()
            target.joining.removeAll { $0.id == roomID }
            log?("\(room.name) left the group")
        } else {
            let next = target.joining[0]
            try await leaving.delegateCoordination(to: next.id, rejoin: false)
            target = SonosTarget(coordinator: next, joining: Array(target.joining.dropFirst()))
            log?("\(room.name) handed the group to \(next.name)")
            await adoptQueueAfterHandoff()
        }
        await silence(leaving, name: room.name)
    }

    /// After a handoff: the new coordinator should be playing our queue (the group's queue moves
    /// with coordination). Its position tells us the track numbers from here on. If it isn't on
    /// our song, the song goes back on, on this coordinator, where it was.
    private func adoptQueueAfterHandoff() async {
        guard let currentTrack else { return }
        let wasPlaying = cachedPlaying
        let position = currentTime
        // Sonos takes a moment to hand over.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard let media = try? await client.mediaInfo(), let info = try? await client.positionInfo() else { continue }
            let onQueue = media["CurrentURI"] == SonosURI.queue(of: target.coordinator.id)
            let trackID = info.trackURI.flatMap(SonosURI.canopyTrackID(of:))
            if onQueue, trackID == currentTrack.id {
                // The queue came over whole, so the staged song is where it was relative to ours.
                if let old = currentNumber, let staged = stagedNumber { stagedNumber = staged + info.track - old }
                currentNumber = info.track
                log?("\(target.coordinator.name) took over our queue at #\(info.track)")
                return
            }
        }
        log?("\(target.coordinator.name) isn't on our queue after the handoff: putting the song back")
        let staged = stagedTrack
        do {
            try await play(currentTrack)
            if position > 1 { try await client.seek(to: position) }
            if !wasPlaying {
                pausedByUs = true
                try await client.pause()
                cache(playing: false, time: position)
            } else {
                cache(playing: true, time: position)
            }
            if let staged { try await stage(staged) }
        } catch {
            log?("couldn't put the song back on \(target.coordinator.name): \(error)")
        }
    }

    /// A room that left the group mustn't carry on with our music by itself.
    private func silence(_ room: SonosClient, name: String) async {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let state = try? await room.transportState() else { return }
            if SonosPlaybackRules.isPlaying(state) {
                log?("\(name) plays on by itself: pausing it")
                try? await room.pause()
                return
            }
        }
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

    /// The session dropped this engine (after pausing it, which reaches the speakers only if this
    /// engine played there). One that never played, restored after a relaunch, may find the group
    /// still playing the session's song from before: that's ours, so it's paused. Anything else
    /// in the room is left alone.
    public func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        stop()
        guard !hasStarted, let expected = restoredTrackID else { return }
        Task { [client, log] in
            guard let info = try? await client.positionInfo(),
                  info.trackURI.flatMap(SonosURI.canopyTrackID(of:)) == expected,
                  let state = try? await client.transportState(), SonosPlaybackRules.isPlaying(state) else { return }
            log?("still playing our song from before: pausing it")
            try? await client.pause()
        }
    }

    func poll() async {
        guard !isShutDown, busy == 0, Date() > settleUntil, currentTrack != nil else { return }
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
