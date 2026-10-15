import Foundation

/// How often an engine reads its player (Apple Music, Sonos, Spotify): often near a song's end,
/// where staging and end detection need it, and for a moment after a command, so its result
/// shows as quickly as ever; less often mid-song; seldom while paused or idle. Each read is an
/// out-of-process call or a network request, so this sets most of an engine's wakeups.
public struct PollPacing: Equatable, Sendable {
    public var midSong: Duration
    public var nearEnd: Duration
    /// Seconds before the end that count as near it. More with crossfade, which moves on early.
    public var nearEndWindow: TimeInterval
    public var afterCommand: Duration
    /// Seconds after a command that the player is read at `afterCommand`.
    public var afterCommandWindow: TimeInterval
    /// Paused, stopped, or nothing loaded.
    public var idle: Duration

    public init(midSong: Duration, nearEnd: Duration, nearEndWindow: TimeInterval,
                afterCommand: Duration, afterCommandWindow: TimeInterval, idle: Duration) {
        self.midSong = midSong
        self.nearEnd = nearEnd
        self.nearEndWindow = nearEndWindow
        self.afterCommand = afterCommand
        self.afterCommandWindow = afterCommandWindow
        self.idle = idle
    }

    /// The same interval whatever happens (tests).
    public static func fixed(_ interval: Duration) -> PollPacing {
        PollPacing(midSong: interval, nearEnd: interval, nearEndWindow: 0, afterCommand: interval, afterCommandWindow: 0, idle: interval)
    }

    /// Crossfade's length when the system picks it, as far as pacing goes.
    static let defaultCrossfade: TimeInterval = 12

    /// `ApplicationMusicPlayer`: near the end and after a command, as often as it always was.
    /// `crossfadeLength` nil is the system's default length.
    public static func appleMusic(crossfade: Bool, crossfadeLength: TimeInterval? = nil) -> PollPacing {
        let fade = crossfade ? crossfadeLength ?? defaultCrossfade : 0
        return PollPacing(midSong: .seconds(1), nearEnd: .milliseconds(400), nearEndWindow: 4 + fade,
                          afterCommand: .milliseconds(400), afterCommandWindow: 2, idle: .seconds(3))
    }

    /// `ApplicationMusicPlayer` when a link plays next (`LinkHandoffEngine`): the end is the
    /// moment the link starts, so it's read for more often in the last seconds.
    public static let appleMusicIntoLink = PollPacing(midSong: .seconds(1), nearEnd: .milliseconds(100), nearEndWindow: 3,
                                                      afterCommand: .milliseconds(400), afterCommandWindow: 2, idle: .seconds(3))

    /// A Sonos group (two SOAP requests a read): near the end and after a command, as often as
    /// it always was while playing. Sonos's crossfade has a length of its own.
    public static func sonos(crossfade: Bool) -> PollPacing {
        PollPacing(midSong: .milliseconds(2500), nearEnd: .seconds(1), nearEndWindow: 6 + (crossfade ? defaultCrossfade : 0),
                   afterCommand: .seconds(1), afterCommandWindow: 3, idle: .seconds(10))
    }

    /// Spotify's `/me/player` (one Web API request a read): near the end as often as it always
    /// was, a little more often after a command. Spotify's crossfade is set in its own app and
    /// isn't known here, so the window allows for one. Other apps on the account change what
    /// plays mid-song too; they're seen within 6 s (3 s before), or 10 s while paused.
    public static let spotify = PollPacing(midSong: .seconds(6), nearEnd: .seconds(3), nearEndWindow: 4 + defaultCrossfade,
                                           afterCommand: .seconds(2), afterCommandWindow: 6, idle: .seconds(10))

    /// The wait before the next read. `remaining`: seconds left in the song (nil when unknown);
    /// `sinceCommand`: seconds since the last command sent to the player. Mid-song, the wait
    /// ends as the song comes within `nearEndWindow` of its end, so the fast reads start on time.
    public func interval(playing: Bool, remaining: TimeInterval?, sinceCommand: TimeInterval) -> Duration {
        var interval = idle
        if playing {
            interval = midSong
            if let remaining {
                let untilNearEnd = remaining - nearEndWindow
                interval = untilNearEnd <= 0 ? min(midSong, nearEnd) : min(midSong, max(nearEnd, .seconds(untilNearEnd)))
            }
        }
        if sinceCommand < afterCommandWindow { interval = min(interval, afterCommand) }
        return interval
    }
}
