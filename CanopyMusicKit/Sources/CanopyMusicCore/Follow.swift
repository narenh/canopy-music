import Foundation

/// Follow mode (docs/multi-device.md): Spotify's player belongs to the account, so other apps and
/// zones on it can change what plays. Canopy Music follows the player instead of fighting it: a
/// track it didn't start or stage is "foreign" and is shown, not overruled. These are the rules,
/// apart from the network so they can be tested; `SpotifyEngine` applies them to each poll.
public enum FollowRules {
    /// After asking the player for a track, how long a mismatch can still mean "it didn't take
    /// yet" (and earn one retry) rather than someone else's choice.
    public static let playRequestWindow: TimeInterval = 10
    /// The most of the player's own queue shown above Up next.
    public static let foreignLimit = 20

    /// One read of the player.
    public struct Observation: Equatable, Sendable {
        /// The track it's on (a URI); nil when nothing is loaded.
        public var trackID: String?
        public var isPlaying: Bool
        public var position: TimeInterval
        public var duration: TimeInterval?

        public init(trackID: String?, isPlaying: Bool, position: TimeInterval = 0, duration: TimeInterval? = nil) {
            self.trackID = trackID
            self.isPlaying = isPlaying
            self.position = position
            self.duration = duration
        }
    }

    /// What the engine knows of its own requests when it reads the player.
    public struct Context: Equatable, Sendable {
        /// The song this session started, or the player advanced to from our stage.
        public var ours: String?
        /// The song handed to the player's queue as our next.
        public var staged: String?
        /// The song we had before the last play request: the player sometimes stays on it.
        public var previous: String?
        /// Seconds since we last asked the player to play `ours`.
        public var sincePlayRequest: TimeInterval
        public var retriedPlay: Bool
        public var pausedByUs: Bool
        public var reportedEnd: Bool
        /// The foreign track already reported, if one is playing.
        public var reportedForeign: String?

        public init(ours: String?, staged: String? = nil, previous: String? = nil, sincePlayRequest: TimeInterval = .infinity,
                    retriedPlay: Bool = false, pausedByUs: Bool = false, reportedEnd: Bool = false, reportedForeign: String? = nil) {
            self.ours = ours
            self.staged = staged
            self.previous = previous
            self.sincePlayRequest = sincePlayRequest
            self.retriedPlay = retriedPlay
            self.pausedByUs = pausedByUs
            self.reportedEnd = reportedEnd
            self.reportedForeign = reportedForeign
        }
    }

    public enum Step: Equatable, Sendable {
        /// Nothing to report.
        case nothing
        /// Send our track again: the player is idle, or still on the previous track we started.
        case retryPlay
        /// The player reached our staged song.
        case advancedToStaged
        /// The player is on a track that isn't ours (report the observed track).
        case foreign
        /// The player is back on our song after a foreign track.
        case backToOurs
        /// The player stopped at the end of our song with nothing of ours queued.
        case reachedEnd
    }

    /// Decides what one read of the player means. `observation` nil: no player state at all (no
    /// active device, or nothing has played on the account).
    public static func step(_ observation: Observation?, _ context: Context) -> Step {
        guard let ours = context.ours else { return .nothing }
        let uri = observation?.trackID
        // Right after asking for our track, a mismatch may mean the player hasn't taken it yet.
        // Retry once, but only if the player is idle or still on the track we had before: an
        // unfamiliar track playing is someone else's choice, and is followed. Never once we've
        // paused since: a retry would start the music we just stopped (e.g. on the old output
        // after the music moved to another one).
        if uri != ours, context.sincePlayRequest < playRequestWindow {
            let idle = observation == nil || uri == nil || observation?.isPlaying == false
            if idle || (uri != nil && uri == context.previous) {
                return context.retriedPlay || context.pausedByUs ? .nothing : .retryPlay
            }
        }
        guard let observation, let uri else { return .nothing }
        if uri == ours {
            if context.reportedForeign != nil { return .backToOurs }
            // Stopped at the end of our song with nothing queued: the player is idle, ours to drive.
            let atEnd = observation.position == 0 || observation.duration.map { observation.position >= $0 - 1.5 } == true
            if !observation.isPlaying, !context.pausedByUs, !context.reportedEnd, context.staged == nil, atEnd {
                return .reachedEnd
            }
            return .nothing
        }
        if uri == context.staged { return .advancedToStaged }
        return uri == context.reportedForeign ? .nothing : .foreign
    }

    /// The player's queue as Up next shows it: the items that will play before our staged song
    /// (all of them when nothing of ours is in it), and whether our staged song is in it. Our song
    /// shows once, as Canopy's locked next item, at its first place in the queue; anything after
    /// it isn't shown (Canopy queues its following song before the player gets there).
    ///
    /// `ours` is what Canopy itself has played or is playing. Spotify lists the queue first, then
    /// what it would play after it, which with repeat on is Canopy's own one-song "context" over
    /// and over (seen on a real account: the previous song ten times). A song of ours is never
    /// someone else's request, so the list stops at the first one; back-to-back repeats collapse.
    public static func foreignUpcoming(in queue: [QueueTrack], staged: String?, ours: Set<String> = []) -> (items: [QueueTrack], stagedQueued: Bool) {
        let stagedIndex = staged.flatMap { staged in queue.firstIndex { $0.id == staged } }
        var foreign: [QueueTrack] = []
        for track in queue[..<(stagedIndex ?? queue.endIndex)] {
            if ours.contains(track.id) { break }
            if foreign.last?.id == track.id { continue }
            foreign.append(track)
            if foreign.count == foreignLimit { break }
        }
        return (foreign, stagedIndex != nil)
    }
}

/// How the follow-mode staging runs (`PartySession`): lock and stage the next song `lead`
/// seconds before the playing track ends, retry a failed stage after each of `retryDelays`, and
/// confirm it's in the player's queue by `confirmBy` seconds before the end, else try the song
/// after it and confirm that by `fallbackConfirmBy`. Tests shrink these.
public struct FollowTiming: Sendable {
    public var lead: TimeInterval = 20
    public var confirmBy: TimeInterval = 10
    public var fallbackConfirmBy: TimeInterval = 5
    public var retryDelays: [TimeInterval] = [1, 2]
    public var tick: TimeInterval = 1

    public init() {}
}

/// Why follow-mode staging stopped, for the error log.
public struct FollowStagingError: Error, LocalizedError, Equatable {
    public var titles: [String]
    public var errorDescription: String? { "Couldn't queue \(titles.joined(separator: " or ")) on the player." }
}
