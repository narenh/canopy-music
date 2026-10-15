import Foundation
import Testing
@testable import CanopyMusicCore

/// Engines read their players less often mid-song and while paused, and as often as before near
/// a song's end and right after a command. Times are passed in, as from a fake clock.
@Suite struct PollPacingTests {
    let apple = PollPacing.appleMusic(crossfade: false)
    let longAgo: TimeInterval = 60

    @Test func appleMusicMidSongIsOncePerSecond() {
        #expect(apple.interval(playing: true, remaining: 120, sinceCommand: longAgo) == .seconds(1))
    }

    @Test func appleMusicNearTheEndIsAsBefore() {
        #expect(apple.interval(playing: true, remaining: 3.9, sinceCommand: longAgo) == .milliseconds(400))
        // Past the end (the time is extrapolated): still fast, for the end to be seen.
        #expect(apple.interval(playing: true, remaining: -2, sinceCommand: longAgo) == .milliseconds(400))
    }

    @Test func theMidSongWaitEndsWhereTheFastReadsStart() {
        // 4.5 s left, the window is 4 s: the next read comes in 0.5 s, not 1 s.
        #expect(apple.interval(playing: true, remaining: 4.5, sinceCommand: longAgo) == .milliseconds(500))
        // Never quicker than near the end.
        #expect(apple.interval(playing: true, remaining: 4.1, sinceCommand: longAgo) == .milliseconds(400))
    }

    @Test func appleMusicPausedOrIdleIsSlow() {
        #expect(apple.interval(playing: false, remaining: 100, sinceCommand: longAgo) == .seconds(3))
        #expect(apple.interval(playing: false, remaining: nil, sinceCommand: longAgo) == .seconds(3))
    }

    @Test func rightAfterACommandIsAsBefore() {
        #expect(apple.interval(playing: false, remaining: nil, sinceCommand: 0.5) == .milliseconds(400))
        #expect(apple.interval(playing: true, remaining: 100, sinceCommand: 1.9) == .milliseconds(400))
        #expect(apple.interval(playing: true, remaining: 100, sinceCommand: 2.1) == .seconds(1))
    }

    @Test func crossfadeStartsTheFastReadsEarlier() {
        let fading = PollPacing.appleMusic(crossfade: true, crossfadeLength: 6)
        #expect(fading.interval(playing: true, remaining: 9, sinceCommand: longAgo) == .milliseconds(400))
        // The system's own length isn't known: a generous window.
        let system = PollPacing.appleMusic(crossfade: true)
        #expect(system.interval(playing: true, remaining: 15, sinceCommand: longAgo) == .milliseconds(400))
        #expect(apple.interval(playing: true, remaining: 9, sinceCommand: longAgo) == .seconds(1))
    }

    @Test func unknownLengthReadsAtTheMidSongPace() {
        #expect(apple.interval(playing: true, remaining: nil, sinceCommand: longAgo) == .seconds(1))
    }

    @Test func fixedIgnoresEverything() {
        let fixed = PollPacing.fixed(.milliseconds(50))
        #expect(fixed.interval(playing: true, remaining: 1, sinceCommand: 0) == .milliseconds(50))
        #expect(fixed.interval(playing: false, remaining: nil, sinceCommand: longAgo) == .milliseconds(50))
    }
}
