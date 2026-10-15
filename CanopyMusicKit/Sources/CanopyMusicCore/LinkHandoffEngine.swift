import Foundation

/// A link track a player can't start: it has no audio address (links join the queue only once
/// they're ready, so this is a player's guard, not a song's turn).
public enum LinkPlaybackError: Error, Equatable, LocalizedError {
    case notReady

    public var errorDescription: String? { "It has no audio to play." }
}

/// One side of a `LinkHandoffEngine`: Apple Music's player, or the link player (an AVPlayer).
/// Either can get a song ready while the other plays, and get out of the way when the other
/// takes over.
@MainActor
public protocol HandoffSide: PlaybackEngine {
    /// Gets `track` ready, so that `play(track)` starts at once: nothing plays, and the other
    /// side's music isn't disturbed. nil lets go of what was prepared.
    func prepare(_ track: QueueTrack?) async throws
    /// The other side takes over now: this one stops, and the link player lets the audio session
    /// go, so Apple Music's player starts without an interruption (found on a real iPad).
    func handOff()
    /// Whether the next song plays on the other side, so this one's end must be noticed promptly
    /// (Apple Music's engine reads its player more often near the end).
    func setEndsIntoHandoff(_ value: Bool)
}

public extension HandoffSide {
    func setEndsIntoHandoff(_ value: Bool) {}
}

/// Apple Music on the device (iPad, Mac, Apple TV), with songs from links: catalog and library
/// songs play in Apple Music's player (`music`), link tracks in an AVPlayer (`links`), and the
/// engine hands over between them at song boundaries. To the session it's one engine that can
/// replace its staged song.
///
/// - Within a side, staging goes to that side, which moves on by itself (gapless, crossfade as set).
/// - Across a switch, the side playing is told nothing comes next, so it runs out and reports the
///   end; meanwhile the other side gets the next song ready (the link's item loads, or Apple
///   Music `prepareToPlay`s), and the session's `play` of it then starts at once. No crossfade
///   across a switch.
/// - With links on, an Apple Music song is lined up in its player only in the last
///   `musicStageLead` seconds of the one before: an entry lined up earlier can't be taken back
///   without a dropout, so a link queued after it would play after a moment of the wrong song.
/// - Only the side playing reports events to the session.
@MainActor
public final class LinkHandoffEngine: PlaybackEngine {
    public enum Side: Sendable { case music, link }

    public let canReplaceStaged = true
    public var canPlayLinks: Bool { true }
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    public let music: any HandoffSide
    public let links: any HandoffSide
    /// Whether the hub takes links now (set by the app, from the session). Until it does, this is
    /// Apple Music's engine as it is.
    public var linksEnabled: @MainActor () -> Bool = { false }
    public var musicStageLead: TimeInterval = 25
    /// Debug output: the handoffs and how long each took. nil is silent.
    public var log: (@MainActor (String) -> Void)?

    public private(set) var active: Side = .music
    private var currentTrack: QueueTrack?
    /// What the session staged, on either side.
    private var stagedTrack: QueueTrack?
    /// What's staged in the side playing (an Apple Music song held back isn't, yet).
    private var linedUp: QueueTrack?
    /// An Apple Music song staged but not yet lined up in its player (`musicStageLead`).
    private var heldTrack: QueueTrack?
    private var holdTask: Task<Void, Never>?
    /// When the side playing ran out into a switch, for timing the handoff.
    private var switchEndedAt: ContinuousClock.Instant?
    /// The engine's own calls one at a time: a held song lined up by its timer mustn't overlap a
    /// session call (overlapping calls can wedge Apple's player).
    private var chain: Task<Void, Never>?

    public init(music: any HandoffSide, links: any HandoffSide) {
        self.music = music
        self.links = links
        music.onEvent = { [weak self] event in self?.handle(event, from: .music) }
        links.onEvent = { [weak self] event in self?.handle(event, from: .link) }
    }

    public static func side(of track: QueueTrack) -> Side { track.link == nil ? .music : .link }

    private func engine(_ side: Side) -> any HandoffSide { side == .music ? music : links }
    private var other: Side { active == .music ? .link : .music }

    public var isPlaying: Bool { engine(active).isPlaying }
    public var currentTime: TimeInterval { engine(active).currentTime }
    public var attachedTrackID: String? { active == .music ? music.attachedTrackID : nil }

    /// Seconds left in the Apple Music song playing; nil on a link or when its length isn't known.
    private var musicRemaining: TimeInterval? {
        guard active == .music, let duration = currentTrack?.duration else { return nil }
        return duration - music.currentTime
    }

    // MARK: PlaybackEngine

    public func play(_ track: QueueTrack) async throws {
        try await serially { try await self.start(track) }
    }

    private func start(_ track: QueueTrack) async throws {
        releaseHeld()
        let side = Self.side(of: track)
        let switching = side != active
        let preparedHere = switching && stagedTrack?.id == track.id
        if switching {
            engine(active).setEndsIntoHandoff(false)
            engine(active).handOff()
            active = side
        } else if let staged = stagedTrack, Self.side(of: staged) != side {
            // The other side got a song ready that isn't the one playing now.
            try? await engine(other).prepare(nil)
        }
        stagedTrack = nil
        linedUp = nil
        currentTrack = nil
        let started = ContinuousClock.now
        try await engine(side).play(track)
        currentTrack = track
        guard switching else { return }
        let call = (ContinuousClock.now - started).milliseconds
        let after = switchEndedAt.map { " (\((ContinuousClock.now - $0).milliseconds) after the end)" } ?? ""
        switchEndedAt = nil
        log?("\(side == .link ? "Apple Music → link" : "link → Apple Music"): \(track.title) started in \(call)\(after)\(preparedHere ? ", prepared" : "")")
    }

    public func stage(_ track: QueueTrack?) async throws {
        try await serially { try await self.lineUp(track) }
    }

    private func lineUp(_ track: QueueTrack?) async throws {
        releaseHeld()
        let here = engine(active)
        let wasAcross = stagedTrack.map { Self.side(of: $0) != active } ?? false
        stagedTrack = track
        guard let track, Self.side(of: track) == active else {
            // Nothing next, or the next song plays on the other side: this side runs out.
            if linedUp != nil {
                try await here.stage(nil)
                linedUp = nil
            }
            guard let track else {
                here.setEndsIntoHandoff(false)
                if wasAcross { try? await engine(other).prepare(nil) }
                return
            }
            here.setEndsIntoHandoff(true)
            try await engine(other).prepare(track)
            return
        }
        here.setEndsIntoHandoff(false)
        if wasAcross { try? await engine(other).prepare(nil) }
        if active == .music, linksEnabled(), let remaining = musicRemaining, remaining > musicStageLead {
            if linedUp != nil {
                try await here.stage(nil)
                linedUp = nil
            }
            hold(track)
            return
        }
        try await here.stage(track)
        linedUp = track
    }

    /// Lines `track` up in Apple Music's player once the song playing is within `musicStageLead`
    /// of its end (it waits while paused: the time stands still).
    private func hold(_ track: QueueTrack) {
        heldTrack = track
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.holdWait() else { return }
                if wait <= 0 {
                    await self?.lineUpHeld()
                    return
                }
                try? await Task.sleep(for: .seconds(min(wait, 5)))
            }
        }
    }

    /// Seconds until the held song is lined up; nil once nothing is held.
    private func holdWait() -> TimeInterval? {
        guard heldTrack != nil else { return nil }
        return max(0, (musicRemaining ?? 0) - musicStageLead)
    }

    private func lineUpHeld() async {
        _ = try? await serially {
            guard let track = self.heldTrack, self.active == .music, self.stagedTrack?.id == track.id else { return }
            self.heldTrack = nil
            self.holdTask = nil
            do {
                try await self.music.stage(track)
                self.linedUp = track
            } catch {
                // The session plays it itself when the song before ends.
                self.log?("couldn't line \(track.title) up: \(error)")
            }
        }
    }

    private func releaseHeld() {
        holdTask?.cancel()
        holdTask = nil
        heldTrack = nil
    }

    public func resume() async throws {
        try await serially { try await self.engine(self.active).resume() }
    }

    public func pause() {
        engine(active).pause()
    }

    /// Only within a side, to a song lined up there; anything else throws, and the session
    /// plays the song itself (the other side has it ready).
    public func skipToStaged() async throws {
        try await serially {
            guard let staged = self.stagedTrack, Self.side(of: staged) == self.active, self.linedUp?.id == staged.id else {
                throw CancellationError()
            }
            try await self.engine(self.active).skipToStaged()
        }
    }

    public func restartCurrent() { engine(active).restartCurrent() }
    public func seek(to time: TimeInterval) { engine(active).seek(to: time) }

    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        music.setCrossfade(enabled: enabled, duration: duration)
        links.setCrossfade(enabled: enabled, duration: duration)
    }

    public func shutDown() {
        releaseHeld()
        music.shutDown()
        links.shutDown()
    }

    public func attach(expecting current: QueueTrack, next: QueueTrack?) {
        guard current.link == nil else { return }
        music.attach(expecting: current, next: next)
    }

    // MARK: Events

    private func handle(_ event: PlaybackEvent, from side: Side) {
        // The side not playing has nothing to tell the session (Apple Music's player getting a
        // prepared song ready, the link player let go).
        guard side == active else { return }
        switch event {
        case .advancedToStaged:
            currentTrack = linedUp ?? stagedTrack
            stagedTrack = nil
            linedUp = nil
        case .reachedEnd:
            if let stagedTrack, Self.side(of: stagedTrack) != side { switchEndedAt = .now }
        default:
            break
        }
        onEvent?(event)
    }

    private func serially<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        chain = Task { _ = try? await task.value }
        return try await task.value
    }
}

extension Duration {
    /// "412 ms", for debug logs.
    var milliseconds: String { "\(Int(self / .milliseconds(1))) ms" }
}
