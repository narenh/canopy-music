import Foundation

/// Which of an engine's songs its player is on, when the player plays but won't say. On tvOS,
/// `ApplicationMusicPlayer`'s current entry never arrives while a song only in the library plays
/// (the app can't decode the player service's now-playing reply: `AppleMusicEngine`), though its
/// status and time read fine. The engine knows what it queued: the current song, and at most one
/// staged after it. So the song's end is where its time, run on from the last read, reaches its
/// length, and the move to the next is the time starting over there. A read that came late (the
/// player slow to answer) still counts: it's the clock that says the end has come, not the reads.
///
/// `read` gives a verdict and never moves on by itself: the engine moves it (`advance`) when it
/// reports the move, which an entry that does arrive can say first.
public struct EntrylessTracker: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        case playing
        /// Stopped or paused.
        case halted
        /// Interrupted, or seeking: says nothing about the song.
        case other
    }

    public enum Verdict: Equatable, Sendable {
        /// The time started over at the current song's end: the player moved on (to the staged
        /// song, if there is one; else to something no longer staged).
        case movedOn
        /// Halted at the current song's end with nothing staged: the music ran out.
        case ended
        /// Halted on its own within `earlyStopWindow` of starting, or never started.
        case stoppedEarly
    }

    /// Seconds before the end within which a time that starts over counts as the move on: enough
    /// for a read's wait near the end (`PollPacing`, 0.4 s) and the length a library gives
    /// being a little off, and few enough that a scrub back from the remote isn't taken for it.
    public static let endWindow: TimeInterval = 4
    /// A time that goes back by more than this has started over (or was scrubbed back). Reads
    /// come at least once a second while playing, and one that takes over 5 s stops them
    /// (`AppleMusicEngine.readDeadline`), so even a late read after the move on finds the time
    /// back from where it was.
    public static let jumpBack: TimeInterval = 0.5
    /// A song that halts on its own before playing this far, or that hasn't played this long
    /// after the player moved on to it, "stopped early".
    public static let earlyStopWindow: TimeInterval = 3

    /// The current song's length, if known. Unknown, its end can't be told from a scrub back.
    public private(set) var duration: TimeInterval?
    /// Something is staged after it.
    public private(set) var hasStaged = false
    private var stagedDuration: TimeInterval?

    private struct Sample: Equatable, Sendable {
        var time: TimeInterval
        var at: Date
        var playing: Bool

        /// The time now, if it ran on from this read.
        func projected(to now: Date) -> TimeInterval {
            playing ? time + now.timeIntervalSince(at) : time
        }
    }

    private var startedAt: Date?
    private var last: Sample?
    /// The furthest this song got while playing.
    private var furthest: TimeInterval = 0
    private var sawPlaying = false
    private var reportedEnd = false
    private var reportedEarlyStop = false

    public init() {}

    /// A song was started afresh (`play`), and found playing.
    public mutating func start(duration: TimeInterval?, at now: Date) {
        self = EntrylessTracker()
        self.duration = duration
        startedAt = now
    }

    /// A song was staged after the current one, or the staged one replaced.
    public mutating func stage(duration: TimeInterval?) {
        hasStaged = true
        stagedDuration = duration
    }

    /// Nothing is staged any more.
    public mutating func unstage() {
        hasStaged = false
        stagedDuration = nil
    }

    /// The player is on the staged song now (seen, told, or skipped to). The last read stays, as
    /// the new song's first.
    public mutating func advance(at now: Date) {
        let kept = last
        start(duration: stagedDuration, at: now)
        last = kept
        if let kept, kept.playing {
            sawPlaying = true
            furthest = kept.time
        }
    }

    /// The engine moved the time itself (a seek, a restart): a jump there isn't a move on.
    public mutating func moved(to time: TimeInterval, at now: Date) {
        last = Sample(time: time, at: now, playing: last?.playing ?? false)
    }

    /// One read of the player. `pausedByUs`: the engine paused it, so a halt isn't an end.
    public mutating func read(_ activity: Activity, time: TimeInterval, at now: Date, pausedByUs: Bool) -> Verdict? {
        let previous = last
        last = Sample(time: time, at: now, playing: activity == .playing)
        if activity == .playing {
            sawPlaying = true
            furthest = max(furthest, time)
        }
        guard let previous else { return nil }
        // Where the song would be had it run on from the read before: at or near its end, a
        // time that starts over is the move on.
        let atEnd = duration.map { previous.projected(to: now) >= $0 - Self.endWindow } ?? false

        // Back from anywhere else: a scrub back, a restart, or a halt that reset the time.
        if time < previous.time - Self.jumpBack, atEnd { return .movedOn }

        guard activity == .halted, !pausedByUs else { return nil }
        let atItsEnd: Bool
        if let duration {
            atItsEnd = sawPlaying && (time >= duration - 1.5 || atEnd)
        } else {
            atItsEnd = sawPlaying && time == 0
        }
        if atItsEnd {
            guard !hasStaged, !reportedEnd else { return nil }
            reportedEnd = true
            return .ended
        }
        let early = sawPlaying ? furthest < Self.earlyStopWindow
                               : startedAt.map { now.timeIntervalSince($0) >= Self.earlyStopWindow } ?? false
        guard early, !reportedEarlyStop else { return nil }
        reportedEarlyStop = true
        return .stoppedEarly
    }
}
