import Foundation
import Testing
@testable import CanopyMusicCore

/// On tvOS the player never says which library song it's on: `EntrylessTracker` tells from the
/// order the engine queued them and the clock. Driven here by a fake player that plays its songs
/// back to back and is read now and then, as `AppleMusicEngine` reads it.
@Suite struct EntrylessTrackerTests {
    /// Plays `lengths` back to back from the first, as far as the engine has staged them, and
    /// halts at the end of the last staged one: at its end, or at 0 (`resetsAtEnd`).
    struct FakePlayer {
        var lengths: [TimeInterval]
        /// How many of `lengths` the player has: the current one and those staged after it.
        var queued = 1
        var index = 0
        var time: TimeInterval = 0
        var playing = true
        var resetsAtEnd = false
        var clock: TimeInterval = 0

        mutating func run(for seconds: TimeInterval) {
            clock += seconds
            guard playing else { return }
            time += seconds
            while time >= lengths[index] {
                if index + 1 < queued {
                    time -= lengths[index]
                    index += 1
                } else {
                    playing = false
                    time = resetsAtEnd ? 0 : lengths[index]
                    return
                }
            }
        }

        var now: Date { Date(timeIntervalSinceReferenceDate: clock) }
    }

    /// The engine's side: the tracker fed each read, a move on taken as the advance to the
    /// staged song (and the next one staged, while there are more), as `AppleMusicEngine` does.
    struct Engine {
        var player: FakePlayer
        var tracker = EntrylessTracker()
        var current = 0
        var events: [String] = []
        var pausedByUs = false

        init(_ player: FakePlayer) {
            self.player = player
            tracker.start(duration: player.lengths[0], at: player.now)
            stageNext()
        }

        mutating func stageNext() {
            guard current + 1 < player.lengths.count else { return }
            player.queued = current + 2
            tracker.stage(duration: player.lengths[current + 1])
        }

        mutating func read() {
            let activity: EntrylessTracker.Activity = player.playing ? .playing : .halted
            let at = String(format: "%.1f", player.clock)
            switch tracker.read(activity, time: player.time, at: player.now, pausedByUs: pausedByUs) {
            case .movedOn:
                guard tracker.hasStaged else {
                    events.append("reachedEnd at \(at)")
                    return
                }
                current += 1
                tracker.advance(at: player.now)
                events.append("advanced to \(current) at \(at)")
                stageNext()
            case .ended: events.append("ended at \(at)")
            case .stoppedEarly: events.append("stopped early at \(at)")
            case nil: break
            }
        }

        /// Runs the player for `seconds`, reading it every `every` seconds.
        mutating func run(for seconds: TimeInterval, every: TimeInterval = 1) {
            var left = seconds
            while left > 0.0001 {
                let step = min(every, left)
                player.run(for: step)
                read()
                left -= step
            }
        }
    }

    @Test func followsSongsBackToBackAndTheEnd() {
        var engine = Engine(FakePlayer(lengths: [10, 8, 12]))
        engine.run(for: 40, every: 0.5)
        #expect(engine.events == ["advanced to 1 at 10.0", "advanced to 2 at 18.0", "ended at 30.0"])
        #expect(engine.player.index == 2)
    }

    @Test func aLateReadStillSeesTheMoveOn() {
        var engine = Engine(FakePlayer(lengths: [10, 200]))
        engine.run(for: 6)
        // The player doesn't answer for 9 s, across the end.
        engine.player.run(for: 9)
        engine.read()
        #expect(engine.events == ["advanced to 1 at 15.0"])
        #expect(engine.tracker.duration == 200)
    }

    @Test func aScrubBackMidSongIsNotAMoveOn() {
        var engine = Engine(FakePlayer(lengths: [200, 100]))
        engine.run(for: 30)
        engine.player.time = 5
        engine.run(for: 3)
        #expect(engine.events.isEmpty)
        #expect(engine.player.index == 0)
    }

    @Test func ourSeekBackNearTheEndIsNotAMoveOn() {
        var engine = Engine(FakePlayer(lengths: [100, 100]))
        engine.run(for: 98)
        engine.player.time = 10
        engine.tracker.moved(to: 10, at: engine.player.now)
        engine.run(for: 3)
        #expect(engine.events.isEmpty)
        // Its real end later is.
        engine.run(for: 90)
        #expect(engine.events == ["advanced to 1 at 188.0"])
    }

    @Test func anUnknownLengthNeverMovesOn() {
        var player = FakePlayer(lengths: [10, 10])
        player.queued = 2
        var tracker = EntrylessTracker()
        tracker.start(duration: nil, at: player.now)
        tracker.stage(duration: 10)
        var verdicts: [EntrylessTracker.Verdict?] = []
        for _ in 0..<15 {
            player.run(for: 1)
            verdicts.append(tracker.read(.playing, time: player.time, at: player.now, pausedByUs: false))
        }
        #expect(verdicts.allSatisfy { $0 == nil })
    }

    @Test func endsOnceWhenTheMusicRunsOut() {
        var engine = Engine(FakePlayer(lengths: [10]))
        engine.run(for: 20)
        #expect(engine.events == ["ended at 10.0"])
    }

    /// The player at the end of its queue with its time back at 0: a move on with nothing staged,
    /// which the engine takes for the end.
    @Test func aTimeBackAtZeroAtTheEndIsTheEndToo() {
        var player = FakePlayer(lengths: [10])
        player.resetsAtEnd = true
        var engine = Engine(player)
        engine.run(for: 20)
        #expect(engine.events == ["reachedEnd at 10.0"])
    }

    /// Something no longer staged (the player never drops what was staged) plays after the end.
    @Test func aMoveOnWithNothingStagedIsTheEnd() {
        var engine = Engine(FakePlayer(lengths: [10, 50]))
        engine.tracker.unstage()
        engine.run(for: 15)
        #expect(engine.events == ["reachedEnd at 10.0"])
    }

    @Test func pausedByUsIsNoEnd() {
        var engine = Engine(FakePlayer(lengths: [10, 10]))
        engine.run(for: 9.5, every: 0.5)
        engine.player.playing = false
        engine.pausedByUs = true
        engine.run(for: 5)
        #expect(engine.events.isEmpty)
    }

    @Test func aStopInTheFirstSecondsIsAnEarlyStop() {
        var engine = Engine(FakePlayer(lengths: [200, 100]))
        engine.run(for: 1, every: 0.5)
        engine.player.playing = false
        engine.player.time = 0
        engine.run(for: 5)
        #expect(engine.events == ["stopped early at 2.0"])
    }

    @Test func aPauseMidSongIsNothing() {
        var engine = Engine(FakePlayer(lengths: [200, 100]))
        engine.run(for: 60)
        engine.player.playing = false
        engine.run(for: 10)
        #expect(engine.events.isEmpty)
    }

    /// The player moves on to the staged song, and it never plays.
    @Test func aStagedSongThatNeverStartsStoppedEarly() {
        var engine = Engine(FakePlayer(lengths: [10, 100]))
        engine.run(for: 9.5, every: 0.5)
        // At the end the player halts with its time at 0, on the next song.
        engine.player.playing = false
        engine.player.time = 0
        engine.player.index = 1
        engine.run(for: 6)
        #expect(engine.events == ["advanced to 1 at 10.5", "stopped early at 13.5"])
    }

    @Test func theNextSongsLengthComesWithTheMove() {
        var tracker = EntrylessTracker()
        let now = Date()
        tracker.start(duration: 100, at: now)
        tracker.stage(duration: 42)
        tracker.advance(at: now)
        #expect(tracker.duration == 42)
        #expect(!tracker.hasStaged)
        tracker.stage(duration: 7)
        tracker.unstage()
        tracker.advance(at: now)
        #expect(tracker.duration == nil)
    }
}
