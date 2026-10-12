import Foundation
import Testing
@testable import CanopyMusicCore

func track(_ id: String) -> QueueTrack { QueueTrack(id: id, title: id, artist: "Artist") }
let guest = Requester(name: "Sam", clientID: "phone-1", origin: .phone)

func titles(_ items: [QueueItem]) -> [String] { items.map(\.track.id) }

@Suite struct QueueStateTests {
    func started(_ ids: [String]) -> QueueState {
        var s = QueueState()
        s.load(playlist: ids.map(track), name: "Base")
        s.advance()
        return s
    }

    @Test func playlistLoadsAndAdvances() {
        let s = started(["a", "b", "c"])
        #expect(s.current?.track.id == "a")
        // Short playlist: one copy of each song queued; "a" comes back after "c".
        #expect(titles(s.upNext) == ["b", "c", "a"])
    }

    @Test func shortPlaylistNeverShowsDuplicates() {
        var s = started(["a", "b"])
        #expect(titles(s.upNext) == ["b", "a"])
        s.advance()
        s.advance()
        #expect(s.current?.track.id == "a")
        #expect(titles(s.upNext) == ["b", "a"])
    }

    @Test func longPlaylistQueuesAWindow() {
        let s = started((0..<QueueState.playlistWindow + 40).map { "t\($0)" })
        #expect(s.upNext.filter { !$0.isRequest }.count == QueueState.playlistWindow)
    }

    // MARK: Upcoming (after the live window)

    @Test func upcomingListsTheRestOfTheCycle() {
        let w = QueueState.playlistWindow
        let s = started((0..<w + 40).map { "t\($0)" })
        // t0 is playing, t1…t\(w) are live; then the rest of the cycle, in order.
        let all = s.upcoming()
        #expect(all.total == 39)
        #expect(all.items.first?.track.id == "t\(w + 1)")
        #expect(all.items.last?.track.id == "t\(w + 39)")
        let page = s.upcoming(offset: 10, limit: 5)
        #expect(page.total == 39)
        #expect(page.items.map(\.track.id) == (w + 11...w + 15).map { "t\($0)" })
        #expect(page.items.first?.position == w + 11)
        #expect(s.upcoming(offset: 100, limit: 5).items.isEmpty)
    }

    @Test func upcomingSkipsRequestedPositions() {
        let w = QueueState.playlistWindow
        var s = started((0..<w + 40).map { "t\($0)" })
        s.addRequest(track("t\(w + 5)"), by: guest)
        let ids = s.upcoming().items.map(\.track.id)
        #expect(!ids.contains("t\(w + 5)"))
        #expect(s.upcoming().total == 38)
    }

    @Test func upcomingStopsAtTheEndOfTheCycle() {
        let w = QueueState.playlistWindow
        var s = started((0..<w + 10).map { "t\($0)" })
        #expect(s.upcoming().total == 9)
        // Play into the next cycle: the window wraps; nothing from the next cycle is listed twice.
        for _ in 0..<15 { s.advance() }
        let upcoming = s.upcoming().items.map(\.track.id)
        let live = Set(s.upNext.map(\.track.id))
        #expect(upcoming.allSatisfy { !live.contains($0) })
        #expect(s.upcoming().total + s.upNext.count + 1 <= w + 10)
    }

    @Test func shortPlaylistHasNothingUpcoming() {
        let s = started(["a", "b", "c"])
        #expect(s.upcoming().total == 0)
    }

    @Test func requestsAreFirstComeFirstServed() {
        var s = started(["a", "b", "c", "d"])
        s.addRequest(track("x"), by: guest)
        s.addRequest(track("y"), by: guest)
        s.addRequest(track("z"), by: guest)
        #expect(titles(s.upNext).prefix(4) == ["x", "y", "z", "b"])
    }

    @Test func draggedRequestNoLongerAnchors() {
        var s = started(["a", "b", "c", "d"])
        s.addRequest(track("x"), by: guest)
        s.addRequest(track("y"), by: guest)
        let y = s.upNext[1].id
        s.move(y, to: 4) // x b c d y ...
        s.addRequest(track("z"), by: guest)
        #expect(titles(s.upNext).prefix(6) == ["x", "z", "b", "c", "d", "y"])
    }

    @Test func playlistSongCanMoveAboveRequests() {
        var s = started(["a", "b", "c", "d"])
        s.addRequest(track("x"), by: guest)
        let d = s.upNext.first { $0.track.id == "d" }!.id
        s.move(d, to: 0)
        #expect(titles(s.upNext).prefix(4) == ["d", "x", "b", "c"])
    }

    @Test func moveAfterAnchor() {
        var s = started(["a", "b", "c", "d"])
        let b = s.upNext[0].id, d = s.upNext[2].id
        s.move(b, after: d) // c d b
        #expect(titles(s.upNext).prefix(3) == ["c", "d", "b"])
        s.move(b, after: nil)
        #expect(titles(s.upNext).prefix(3) == ["b", "c", "d"])
    }

    @Test func requestRemovesMaterializedPlaylistDuplicate() {
        var s = started(["a", "b", "c", "d"])
        s.addRequest(track("c"), by: guest)
        #expect(titles(s.upNext).prefix(4) == ["c", "b", "d", "a"])
    }

    @Test func requestSkipsUnmaterializedPlaylistPosition() {
        let count = QueueState.playlistWindow + 15
        let ids = (0..<count).map { "t\($0)" }
        var s = started(ids)
        let late = "t\(count - 5)"
        // It hasn't been materialized yet (it's past the window).
        #expect(!s.upNext.contains { $0.track.id == late })
        s.addRequest(track(late), by: guest)
        // Play through the rest of the first cycle: it should appear once (the request).
        var seen: [String] = []
        for _ in 0..<count { if let c = s.advance() { seen.append(c.track.id) } }
        #expect(seen.filter { $0 == late }.count == 1)
        #expect(seen.last == "t0") // looped back around
    }

    @Test func duplicateRequestIsReported() {
        var s = started(["a", "b"])
        s.addRequest(track("x"), by: guest)
        if case .alreadyQueued(_, let index) = s.addRequest(track("x"), by: guest) {
            #expect(index == 0)
        } else {
            Issue.record("expected alreadyQueued")
        }
        #expect(s.addRequest(track("a"), by: guest) == .nowPlaying)
    }

    @Test func lockedNextCannotBeDisplaced() {
        var s = started(["a", "b", "c"])
        s.lockNext()
        let locked = s.upNext[0].id
        s.addRequest(track("x"), by: guest)
        #expect(titles(s.upNext).prefix(2) == ["b", "x"])
        let moved = s.move(locked, to: 3)
        #expect(!moved)
        let removed = s.remove(locked)
        #expect(removed == nil)
        let x = s.upNext[1].id
        s.move(x, to: 0)
        #expect(s.upNext[0].id == locked)
        s.advance()
        #expect(s.lockedNextID == nil)
    }

    @Test func advanceToSpecificItem() {
        var s = started(["a", "b", "c"])
        let c = s.upNext[1].id
        s.advance(to: c)
        #expect(s.current?.track.id == "c")
        #expect(s.history.first?.track.id == "a")
    }

    @Test func reloadingPlaylistClearsEverything() {
        var s = started(["a", "b"])
        s.addRequest(track("x"), by: guest)
        s.load(playlist: ["m", "n"].map(track), name: "Other")
        #expect(s.current == nil)
        #expect(titles(s.upNext).prefix(2) == ["m", "n"])
        #expect(!s.upNext.contains { $0.isRequest })
    }

    @Test func shuffleKeepsRequestsAndAllSongs() {
        let ids = (0..<20).map { "t\($0)" }
        var s = started(ids)
        s.addRequest(track("x"), by: guest)
        s.shufflePlaylist()
        #expect(s.upNext.first?.track.id == "x")
        #expect(Set(s.playlist.map(\.id)) == Set(ids))
        #expect(s.upNext.filter { !$0.isRequest }.count == ids.count)
    }

    @Test func goBackRestoresPreviousSong() {
        var s = started(["a", "b", "c"])
        s.advance() // b playing, a in history
        let wentBack = s.goBack()
        #expect(wentBack)
        #expect(s.current?.track.id == "a")
        #expect(s.upNext.first?.track.id == "b")
        #expect(s.history.isEmpty)
        let wentBackAgain = s.goBack()
        #expect(!wentBackAgain)
    }

    @Test func roundTripsThroughJSON() throws {
        var s = started(["a", "b"])
        s.addRequest(track("x"), by: guest)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(QueueState.self, from: data) == s)
    }
}
