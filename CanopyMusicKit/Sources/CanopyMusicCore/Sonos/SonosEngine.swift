import Foundation

/// Where a `SonosEngine` plays: a group's coordinator (commands go there), plus any rooms to
/// pull into its group when playback starts. Which room leads is settled from the live group
/// layout at the first play (`SonosGroupingPlan`), so the coordinator here can change then.
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
    /// The coordinator room was a non-coordinating member of another group when the household
    /// was last read, so it leaves that group first. Only a fallback: the first play reads the
    /// layout live and decides from that; this is used when the layout can't be read.
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

/// How the engine takes its rooms over, decided from the group layout the speakers report right
/// before the first play (the household's cached layout, or a target saved at an earlier launch,
/// can be out of date: grouping in the Sonos app, an earlier session's grouping, or Sonos moving
/// coordination itself).
///
/// - A chosen room that already leads other chosen rooms keeps the lead (the one leading the most,
///   the target's own coordinator on a tie): nothing it leads is regrouped.
/// - Otherwise the target's coordinator leads; if it's a member of another group it leaves that
///   first. A chosen room in a group led by a room that isn't chosen is taken out of it (it joins
///   ours, or leaves if it's the coordinator); the room that isn't chosen plays on as it was.
/// - The other chosen rooms join, unless they're in the group already.
/// - Rooms that aren't chosen but are in the coordinator's group leave it, so the music plays in
///   exactly the chosen rooms.
struct SonosGroupingPlan: Equatable {
    /// The rooms as chosen, led by the room that leads; `leavesGroup` false.
    var target: SonosTarget
    /// The coordinator leaves the group it's a member of first.
    var leaves: Bool
    /// Rooms to join to the coordinator (`x-rincon:`).
    var joining: [SonosTarget.Room]
    /// Rooms in the coordinator's group that weren't chosen: each leaves it.
    var dropping: [SonosTarget.Room]

    /// nil when `groups` doesn't list the target's coordinator (the layout wasn't read).
    init?(_ target: SonosTarget, groups: [SonosGroup]) {
        func group(of id: String) -> SonosGroup? { groups.first { $0.members.contains { $0.id == id } } }
        guard group(of: target.coordinator.id) != nil else { return nil }
        let chosen = target.rooms
        let ids = Set(chosen.map(\.id))
        // Chosen rooms leading other chosen rooms, most first, then in the order chosen.
        let leaders = chosen.enumerated().compactMap { index, room -> (room: SonosTarget.Room, count: Int, index: Int)? in
            guard let led = groups.first(where: { $0.coordinatorID == room.id }) else { return nil }
            let count = led.rooms.filter { ids.contains($0.id) }.count
            return count > 1 ? (room, count, index) : nil
        }
        let coordinator = leaders.min { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }?.room ?? target.coordinator
        let current = group(of: coordinator.id)
        leaves = current.map { $0.coordinatorID != coordinator.id } ?? false
        let members = leaves ? [] : current?.rooms ?? []
        let others = chosen.filter { $0.id != coordinator.id }
        self.target = SonosTarget(coordinator: coordinator, joining: others)
        joining = others.filter { room in !members.contains { $0.id == room.id } }
        dropping = members.filter { !ids.contains($0.id) }.compactMap { member in
            member.host.map { SonosTarget.Room(id: member.id, name: member.roomName, host: $0) }
        }
    }
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
        /// The room read is a member of this coordinator's group, not a coordinator (its track
        /// URI is `x-rincon:{coordinator}`).
        public var memberOf: String?

        public init(trackNumber: Int, trackID: String?, state: SonosTransportState?, position: TimeInterval? = nil, duration: TimeInterval? = nil,
                    memberOf: String? = nil) {
            self.trackNumber = trackNumber
            self.trackID = trackID
            self.state = state
            self.position = position
            self.duration = duration
            self.memberOf = memberOf
        }

        public init(_ info: SonosPositionInfo, state: SonosTransportState?) {
            self.init(trackNumber: info.track, trackID: info.trackURI.flatMap(SonosURI.canopyTrackID(of:)),
                      state: state, position: info.position, duration: info.duration ?? info.item?.duration,
                      memberOf: info.trackURI.flatMap(SonosURI.coordinator(ofMemberURI:)))
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
        /// Every song the engine has put in the group's queue since it last emptied it; nil when
        /// that isn't known (a queue found after a relaunch that couldn't be read). A song that
        /// isn't one of them is someone else's queue, never "further on in ours".
        public var queued: Set<String>?

        public init(currentID: String?, currentNumber: Int?, stagedID: String? = nil, stagedNumber: Int? = nil,
                    pausedByUs: Bool = false, reportedEnd: Bool = false, sawPlaying: Bool = false, queued: Set<String>? = nil) {
            self.currentID = currentID
            self.currentNumber = currentNumber
            self.stagedID = stagedID
            self.stagedNumber = stagedNumber
            self.pausedByUs = pausedByUs
            self.reportedEnd = reportedEnd
            self.sawPlaying = sawPlaying
            self.queued = queued
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
        // Our coordinator went into another group (the engine follows a group led by one of our
        // own rooms before this): whatever that group plays, the room isn't ours, playing or not.
        if o.memberOf != nil { return .lostControl }
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
        // A song the engine never queued: someone else replaced the queue (another Canopy Music
        // zone took the room, or the Sonos app), playing or about to. Not the end of ours: the
        // session mustn't play its next song over it.
        if let queued = c.queued, !queued.contains(trackID) { return .lostControl }
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
/// Events come from polling `GetPositionInfo` and `GetTransportInfo` (`PollPacing.sonos`: once a
/// second near a song's end and after a command, every 2.5 s mid-song, every 10 s paused). UPnP
/// event subscriptions aren't used.
@MainActor
public final class SonosEngine: PlaybackEngine {
    public let canReplaceStaged = true
    /// A link's audio goes in the group's queue as its plain https address, for Apple Music
    /// and Spotify zones alike (`SonosTrackReference.uri(for:)`).
    public var canPlayLinks: Bool { true }
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
    /// Sonos refused the account (or the service) this engine streams from: the first song's
    /// `AddURIToQueue` (the first command carrying the service URI) or its `Play` came back with
    /// a UPnP fault, right after the same coordinator took `RemoveAllTracksFromQueue`. An 800
    /// counts only once the live layout confirms the room leads its group: otherwise it's the
    /// usual "not the coordinator", and the engine follows the group as before. Never once a
    /// song from it has played: a later refusal is that song's, not the account's.
    ///
    /// What's known (a real S2 household): a service that isn't linked (Tidal) answered
    /// `SetAVTransportURI` with 800 on the real coordinator, then `Play` with 701; a linked
    /// service played with any serial (1–8) or none. That `AddURIToQueue` refuses an unlinked
    /// service the same way is assumed, not seen. A refusal that shows only as the transport
    /// stopping isn't caught.
    public var onAccountRejected: (@MainActor (SonosTrackReference) -> Void)?
    /// A song from `reference` has played (or `attach` found ours playing): Sonos takes the account.
    private var accountPlayed = false
    /// The session's current song as restored at launch: the group may still be playing it from
    /// before (Sonos plays on while the app is gone), and then it's ours to pause on `shutDown`
    /// (if `attach` hasn't taken it over by then).
    public var restoredTrackID: String?
    private var isShutDown = false
    /// `attach` reading the speakers (tests wait on it).
    private(set) var attachTask: Task<Void, Never>?
    /// `attach` took the group's song over, and nothing has been played since.
    private var attached = false

    private var currentTrack: QueueTrack?
    private var currentNumber: Int?
    private var stagedTrack: QueueTrack?
    private var stagedNumber: Int?
    private var pausedByUs = false
    private var reportedEnd = false
    private var sawPlaying = false
    /// Another source took the room over; the next play or resume starts our song again.
    private var lostControl = false
    /// The songs put in the group's queue since it was last emptied (`SonosPlaybackRules.Context.queued`);
    /// nil when a queue found after a relaunch couldn't be read.
    private var queued: Set<String>? = []
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
    /// A poll is reading the speakers: a command doesn't start the loop over under it.
    private var isPolling = false
    private var lastCommandAt = Date.distantPast

    private var cachedPlaying = false
    private var cachedTime: TimeInterval = 0
    private var cachedAt = Date()
    /// The song's length as last read, for pacing.
    private var cachedDuration: TimeInterval?

    /// Fixed poll spacing instead of `PollPacing.sonos` (tests).
    public var pollInterval: (playing: Duration, paused: Duration)?
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

    /// Empties the group's Sonos queue, puts `track` in it and plays it. The first play (and one
    /// taking the rooms back from another source) first sets the group up from the live layout.
    public func play(_ track: QueueTrack) async throws {
        let uri: String
        let metadata: String
        do {
            uri = try reference.uri(for: track)
            metadata = try reference.metadata(for: track)
        } catch {
            log?("can't play \(track.title) on Sonos: \(error)")
            throw error
        }
        busy += 1
        defer { busy -= 1 }
        settleUntil = Date().addingTimeInterval(1.5)
        let retaking = lostControl
        reportedEnd = false
        pausedByUs = false
        sawPlaying = false
        lostControl = false
        stagedTrack = nil
        stagedNumber = nil
        hasStarted = true
        attached = false
        // The steps whose refusal, on the first song from the account, is the account's. A
        // link's audio isn't the account's: its refusal says nothing of it.
        let fromAccount = track.link == nil
        var accountStep = false
        do {
            try await groupRoomsIfNeeded(retaking: retaking)
            try await reporting("RemoveAllTracksFromQueue") { try await client.clearQueue() }
            queued = [track.id]
            accountStep = fromAccount
            let number = try await reporting("AddURIToQueue") { try await client.addToQueue(uri: uri, metadata: metadata, position: 0, asNext: false) }
            accountStep = false
            try await reporting("SetAVTransportURI") { try await client.setTransportURI(SonosURI.queue(of: target.coordinator.id)) }
            // Shuffle or repeat in the Sonos app would play the queue out of order.
            try? await client.setPlayModeNormal()
            if let crossfade { try? await client.setCrossfade(crossfade) }
            try await reporting("Seek") { try await client.seek(trackNumber: number) }
            accountStep = fromAccount
            try await reporting("Play") { try await client.play() }
            accountStep = false
            if fromAccount { accountPlayed = true }
            currentTrack = track
            currentNumber = number
        } catch {
            // The queue is being replaced anyway: nothing to take over from a new coordinator.
            let refusal = await noteRefusal(error, adoptQueue: false)
            if accountStep, !accountPlayed, Self.isAccountRefusal(error, refusal) {
                log?("Sonos refused the first song from account \(reference.accountSerial) (\(reference.service.rawValue)): the account counts as rejected")
                onAccountRejected?(reference)
            }
            throw error
        }
        cache(playing: true, time: 0)
        cachedDuration = track.duration
        log?("play \(track.title) at #\(currentNumber ?? 0) in \(target.name)")
        startPolling()
        noteCommand()
    }

    /// A refused account step: 800 only once the live layout has confirmed the room leads its
    /// group (else it's grouping, followed as before); any other UPnP fault as it is.
    static func isAccountRefusal(_ error: any Error, _ refusal: Refusal) -> Bool {
        guard case .upnp(_, let code)? = error as? SonosError else { return false }
        return code == 800 ? refusal == .coordinator : true
    }

    /// One command to the coordinator; a failure is logged with the action, the room and the error.
    private func reporting<T>(_ action: String, _ command: () async throws -> T) async throws -> T {
        do {
            return try await command()
        } catch {
            log?("\(action) to \(target.coordinator.name) (\(target.coordinator.host)) failed: \(error)")
            throw error
        }
    }

    /// A command came back 800 (not the group's coordinator): the group changed hands outside
    /// Canopy Music since the last poll. The coordinator is read now rather than at the next
    /// poll: a group now led by one of our rooms is followed; any other group has taken the room,
    /// and the next play takes it back (`lostControl`). The refused command isn't retried.
    /// What it found: `.regrouped` when the room reads as a member of another group;
    /// `.coordinator` when the live layout says the room still leads its group (an 800 that isn't
    /// about grouping: a real player answers a service that isn't linked with 800); `.unknown`
    /// otherwise (another error, or nothing could be read). Each is read once; nothing is retried.
    enum Refusal { case regrouped, coordinator, unknown }

    @discardableResult
    private func noteRefusal(_ error: any Error, adoptQueue: Bool = true) async -> Refusal {
        guard case .upnp(_, let code)? = error as? SonosError, code == 800,
              let info = try? await client.positionInfo() else { return .unknown }
        guard let leaderID = info.trackURI.flatMap(SonosURI.coordinator(ofMemberURI:)) else {
            let coordinator = target.coordinator.id
            let leads = await liveGroups()?.first { $0.members.contains { $0.id == coordinator } }?.coordinatorID == coordinator
            return leads ? .coordinator : .unknown
        }
        if let leader = target.rooms.first(where: { $0.id == leaderID }) {
            await follow(to: leader, adoptQueue: adoptQueue)
        } else {
            log?("\(target.coordinator.name) is in another group (led by \(leaderID)): the next play takes it back")
            lostControl = true
        }
        return .regrouped
    }

    /// Our coordinator reads as a member of `leader`'s group, and `leader` is one of our rooms:
    /// the group changed hands outside Canopy Music (the Sonos app, or Sonos moving coordination
    /// itself). Commands and polls follow it, as after `removeRoom`'s handoff, and the queue
    /// that moved with the group is taken over. The rooms stay as chosen.
    private func follow(to leader: SonosTarget.Room, adoptQueue: Bool = true) async {
        log?("\(target.coordinator.name) is a member of \(leader.name)'s group now: following it")
        busy += 1
        defer { busy -= 1 }
        target = SonosTarget(coordinator: leader, joining: target.rooms.filter { $0.id != leader.id })
        if adoptQueue { await adoptQueueAfterHandoff() }
    }

    /// Puts `track` right after the current song in the Sonos queue, then removes the song
    /// staged before it (now one further down). Inserting first means a failed removal still
    /// plays the right song next.
    public func stage(_ track: QueueTrack?) async throws {
        guard currentNumber != nil else {
            stagedTrack = nil
            stagedNumber = nil
            return
        }
        // Already right after the current song (found there by `attach`, say): nothing to send.
        if let track, track.id == stagedTrack?.id, stagedNumber != nil { return }
        let uri = try track.map { try reference.uri(for: $0) }
        let metadata = try track.map { try reference.metadata(for: $0) }
        busy += 1
        defer { busy -= 1 }
        // The player may already be on the staged song (a restage as a song ends): take that
        // first. This stage is then stale; the session stages again behind the new song.
        if try await applyLatestObservation() { throw CancellationError() }
        // Another source has the rooms (another zone took them over, say): its queue isn't ours
        // to add to. The next play starts our song again; what follows is staged then.
        guard !lostControl else {
            stagedTrack = nil
            stagedNumber = nil
            log?("not staging \(track?.title ?? "nothing"): another source has the rooms")
            return
        }
        // Read after the observation, which may have followed the group to a new coordinator.
        guard let current = currentNumber else { throw CancellationError() }
        let previous = stagedNumber
        if let track, let uri, let metadata {
            let number: Int
            do {
                number = try await reporting("AddURIToQueue") { try await client.addToQueue(uri: uri, metadata: metadata, position: current + 1, asNext: true) }
            } catch {
                await noteRefusal(error)
                throw error
            }
            stagedTrack = track
            stagedNumber = number
            queued?.insert(track.id)
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
        do {
            try await reporting("Play") { try await client.play() }
        } catch {
            await noteRefusal(error)
            throw error
        }
        cache(playing: true, time: cachedTime)
        noteCommand()
    }

    public func pause() {
        pausedByUs = true
        cache(playing: false, time: currentTime)
        guard hasStarted else { return }
        settleUntil = Date().addingTimeInterval(1)
        noteCommand()
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
        do {
            try await reporting("Seek") { try await client.seek(trackNumber: stagedNumber) }
            try await reporting("Play") { try await client.play() }
        } catch {
            await noteRefusal(error)
            throw error
        }
        // Picked up at once rather than at the next poll.
        _ = try? await applyLatestObservation()
        noteCommand()
    }

    public func restartCurrent() { seek(to: 0) }

    public func seek(to time: TimeInterval) {
        cache(playing: cachedPlaying, time: time)
        guard hasStarted, !lostControl else { return }
        settleUntil = Date().addingTimeInterval(1)
        noteCommand()
        Task { [client] in try? await client.seek(to: time) }
    }

    /// Sonos's own crossfade (its length is Sonos's), set on the group when playback starts.
    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        crossfade = enabled
        guard hasStarted, !lostControl else { return }
        Task { [client] in try? await client.setCrossfade(enabled) }
    }

    // MARK: Grouping

    /// Sets the group up on the speakers at the first play, and again when taking the rooms back
    /// from another source (they may have been regrouped meanwhile), from the layout the speakers
    /// report now (`SonosGroupingPlan`). If no room answers with it, as last known
    /// (`target.leavesGroup`, then every other room joins).
    private func groupRoomsIfNeeded(retaking: Bool) async throws {
        guard !hasGrouped || retaking else { return }
        let joining: [SonosTarget.Room]
        if let groups = await liveGroups(), let plan = SonosGroupingPlan(target, groups: groups) {
            if plan.target.coordinator.id != target.coordinator.id {
                log?("\(plan.target.coordinator.name) already leads \(plan.target.name): it leads, nothing is regrouped")
            }
            target = plan.target
            if plan.leaves {
                log?("\(target.coordinator.name) leaves its group first")
                try await reporting("BecomeCoordinatorOfStandaloneGroup") { try await client.leaveGroup() }
            }
            for room in plan.dropping {
                // Not chosen, but in the group: out of it, so the music plays only where chosen.
                do {
                    try await SonosClient(transport: transport, host: room.host).leaveGroup()
                    log?("\(room.name) isn't chosen: it left the group")
                } catch {
                    log?("\(room.name) isn't chosen and couldn't leave the group: \(error)")
                }
            }
            joining = plan.joining
        } else {
            log?("couldn't read the group layout: grouping as last known")
            if target.leavesGroup {
                try await reporting("BecomeCoordinatorOfStandaloneGroup") { try await client.leaveGroup() }
            }
            joining = target.joining
        }
        for room in joining {
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

    /// The group layout as the speakers report it now, from the first of our rooms that answers.
    /// At most two are asked, so rooms that are off don't hold the start up for long (each try
    /// is bounded by the transport's timeout). nil if neither answers.
    private func liveGroups() async -> [SonosGroup]? {
        for room in target.rooms.prefix(2) {
            if let groups = try? await SonosClient(transport: transport, host: room.host).zoneGroups(), !groups.isEmpty {
                return groups
            }
        }
        return nil
    }

    /// The group is set up on the speakers (the first play did it): rooms join and leave it for
    /// real from now on. Before that, they only change `target`.
    public var isGrouped: Bool { hasGrouped }

    /// Another source has the rooms now (the Sonos app, the TV, another Canopy Music zone that
    /// took them over): the engine leaves them alone, shows paused, and only a play from this
    /// zone (or a resume) takes them back.
    public var hasLostControl: Bool { lostControl }

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
        // Not after another source took the rooms: the coordinator's group is someone else's
        // now. It's only noted; the next play takes the rooms (this one too) back.
        if hasGrouped, !lostControl {
            busy += 1
            defer { busy -= 1 }
            try await SonosClient(transport: transport, host: room.host).setTransportURI(SonosURI.joinGroup(of: target.coordinator.id))
            log?("\(room.name) joining \(target.coordinator.name)")
            noteCommand()
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
        guard hasGrouped, !lostControl else {
            // Nothing set up on the speakers yet, or another source has them now (another
            // zone's group isn't ours to take rooms out of).
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
        noteCommand()
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

    // MARK: Reattaching after a relaunch

    public var attachedTrackID: String? { attached ? currentTrack?.id : nil }

    /// After a relaunch: Sonos plays on while the app is gone, so the group may still be on the
    /// restored session's song. Reads the live group layout, then from each group one of our
    /// rooms leads (the one leading the most of them first, as `SonosGroupingPlan` picks) its
    /// position, transport state and queue, sending nothing. A group on `current`, from its
    /// queue, is taken over as it is (`adopt`). Anything else (another source, nothing of ours,
    /// no answer) is left alone: the session stays paused, and Play takes the rooms back as usual.
    public func attach(expecting current: QueueTrack, next: QueueTrack?) {
        guard !hasStarted, currentTrack == nil, attachTask == nil, !isShutDown else { return }
        restoredTrackID = current.id
        attachTask = Task { [weak self] in await self?.reattach(current, next: next) }
    }

    private func reattach(_ current: QueueTrack, next: QueueTrack?) async {
        let chosen = target
        guard let groups = await liveGroups() else {
            log?("attach: couldn't read the group layout: leaving the speakers alone")
            return
        }
        let led = Self.groups(ledBy: chosen, in: groups)
        if led.isEmpty { log?("attach: none of \(chosen.name) leads a group: leaving the speakers alone") }
        for group in led {
            guard let member = group.coordinator,
                  let host = member.host ?? chosen.rooms.first(where: { $0.id == member.id })?.host else { continue }
            let leader = SonosTarget.Room(id: member.id, name: chosen.rooms.first { $0.id == member.id }?.name ?? member.roomName, host: host)
            let client = SonosClient(transport: transport, host: host)
            guard let info = try? await client.positionInfo() else {
                log?("attach: \(group.name) didn't answer")
                continue
            }
            guard info.trackURI.flatMap(SonosURI.canopyTrackID(of:)) == current.id else {
                log?("attach: \(group.name) is on something else (\(info.trackURI.map { $0.isEmpty ? "nothing" : $0 } ?? "nothing")): leaving it alone")
                continue
            }
            guard let media = try? await client.mediaInfo(), media["CurrentURI"] == SonosURI.queue(of: leader.id),
                  let state = try? await client.transportState() else {
                log?("attach: \(group.name) has \(current.title), but not from its queue: leaving it alone")
                continue
            }
            let queue = try? await client.browse("Q:0")
            // Played, dropped or given other rooms while the speakers were read: that decides.
            guard !isShutDown, !hasStarted, target == chosen else {
                log?("attach: the session moved on while reading \(group.name): leaving it")
                return
            }
            adopt(group, leader: leader, info: info, state: state, queue: queue, current: current, next: next)
            return
        }
    }

    /// The group is on the restored song: it's this engine's, as it is. The rooms become the
    /// group's own (`onTargetChanged`); the song is current at its queue position, playing or
    /// paused where it is; and the queue's next entry is the staged song if it's the session's
    /// next one (otherwise the session stages its own after it). Nothing is sent.
    private func adopt(_ group: SonosGroup, leader: SonosTarget.Room, info: SonosPositionInfo, state: SonosTransportState?,
                       queue: [SonosItem]?, current: QueueTrack, next: QueueTrack?) {
        // Our song is in its queue: Sonos took the account.
        accountPlayed = true
        let known = target.rooms
        let members = group.rooms.filter { $0.id != leader.id }.compactMap { member -> SonosTarget.Room? in
            let chosen = known.first { $0.id == member.id }
            guard let host = member.host ?? chosen?.host else { return nil }
            return SonosTarget.Room(id: member.id, name: chosen?.name ?? member.roomName, host: host)
        }
        target = SonosTarget(coordinator: leader, joining: members)
        client = SonosClient(transport: transport, host: leader.host)
        hasStarted = true
        hasGrouped = true
        attached = true
        currentTrack = current
        currentNumber = info.track
        let following = queue?.first { $0.id == "Q:0/\(info.track + 1)" }?.uri.flatMap(SonosURI.canopyTrackID(of:))
        // The queue as it is, all ours (it's the restored song's); unread, unknown.
        queued = queue.map { Set($0.compactMap { $0.uri.flatMap(SonosURI.canopyTrackID(of:)) } + [current.id]) }
        if let next, following == next.id {
            stagedTrack = next
            stagedNumber = info.track + 1
        }
        pausedByUs = false
        reportedEnd = false
        lostControl = false
        sawPlaying = state == .playing
        let playing = SonosPlaybackRules.isPlaying(state)
        let position = info.position ?? 0
        cache(playing: playing, time: position)
        lastPlaying = playing
        let staged = stagedTrack.map { "\($0.title) staged at #\(info.track + 1)" }
            ?? (queue == nil ? "the queue unread: the next song is staged afresh" : "the next entry isn't the next song: it's staged afresh")
        log?("attach: \(target.name) is \(playing ? "playing" : "paused on") \(current.title) at #\(info.track), \(SonosTime.string(position)) in; \(staged)")
        startPolling()
        onEvent?(.statusChanged)
    }

    /// The groups one of `target`'s rooms leads, the one leading the most of its rooms first,
    /// then in the order the rooms were chosen.
    static func groups(ledBy target: SonosTarget, in groups: [SonosGroup]) -> [SonosGroup] {
        let ids = Set(target.rooms.map(\.id))
        return target.rooms.enumerated().compactMap { index, room -> (group: SonosGroup, count: Int, index: Int)? in
            guard let led = groups.first(where: { $0.coordinatorID == room.id }) else { return nil }
            return (led, led.rooms.filter { ids.contains($0.id) }.count, index)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
        .map(\.group)
    }

    // MARK: Polling

    private func startPolling() {
        guard poller == nil, !isShutDown else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.nextPollInterval() else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.isPolling = true
                await self.poll()
                self.isPolling = false
            }
        }
    }

    /// The wait before the next poll (`PollPacing.sonos`, or `pollInterval` in tests).
    func nextPollInterval(now: Date = Date()) -> Duration {
        if let pollInterval { return cachedPlaying ? pollInterval.playing : pollInterval.paused }
        let elapsed = cachedPlaying ? cachedTime + now.timeIntervalSince(cachedAt) : cachedTime
        let remaining = (cachedDuration ?? currentTrack?.duration).map { $0 - elapsed }
        return PollPacing.sonos(crossfade: crossfade == true)
            .interval(playing: cachedPlaying, remaining: remaining, sinceCommand: now.timeIntervalSince(lastCommandAt))
    }

    /// A command went to the speakers: the next polls come at the quick pace, the first of them
    /// without waiting out a long paused-state wait. Not under a poll that's reading.
    private func noteCommand() {
        lastCommandAt = Date()
        guard poller != nil, !isPolling else { return }
        poller?.cancel()
        poller = nil
        startPolling()
    }

    /// Stops polling for good (the session dropped this engine).
    public func stop() {
        poller?.cancel()
        poller = nil
    }

    /// The session dropped this engine (after pausing it, which reaches the speakers only if this
    /// engine played there). One that never played, restored after a relaunch, may find the group
    /// still playing the session's song from before: that's ours, so it's paused. Anything else
    /// in the room is left alone. One that took the song over at `attach` has started, so the
    /// session's pause has already reached it; an `attach` still reading stops at `isShutDown`.
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
        // Only the length is wanted from the track's metadata, and only when Sonos doesn't say it.
        var info = try await client.positionInfo(withItem: false)
        // Our coordinator is a member of a group led by another of our rooms: the group changed
        // hands outside Canopy Music, and the rest goes to the new coordinator.
        if let leaderID = info.trackURI.flatMap(SonosURI.coordinator(ofMemberURI:)), leaderID != target.coordinator.id,
           let leader = target.rooms.first(where: { $0.id == leaderID }) {
            await follow(to: leader)
            info = try await client.positionInfo(withItem: false)
        }
        let state = try await client.transportState()
        return apply(SonosPlaybackRules.Observation(info, state: state))
    }

    @discardableResult
    func apply(_ observation: SonosPlaybackRules.Observation) -> Bool {
        let context = SonosPlaybackRules.Context(
            currentID: currentTrack?.id, currentNumber: currentNumber,
            stagedID: stagedTrack?.id, stagedNumber: stagedNumber,
            pausedByUs: pausedByUs, reportedEnd: reportedEnd, sawPlaying: sawPlaying, queued: queued
        )
        let step = SonosPlaybackRules.step(observation, context)
        let ours = observation.trackID != nil && (observation.trackID == currentTrack?.id || observation.trackID == stagedTrack?.id)
        let playing = !lostControl && step != .lostControl && SonosPlaybackRules.isPlaying(observation.state)
        // Before any event: the session snapshots the time as it handles them.
        cache(playing: playing, time: ours ? (observation.position ?? 0) : cachedTime)
        if ours { cachedDuration = observation.duration }
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
            if !lostControl {
                log?(observation.memberOf.map { "\(target.coordinator.name) is in another group (led by \($0))" } ?? "another source has the room")
            }
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
