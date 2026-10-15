import Foundation
import Testing
@testable import CanopyMusicCore

/// "Limit reorders": balances, refills, who's exempt, and the free move (your own song down).
@MainActor
@Suite struct ReorderLimitTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    // MARK: The rules on their own

    @Test func eachPersonStartsWithTheInitialBalance() {
        let limit = ReorderLimit(isOn: true, allowance: 3, refillMinutes: 15)
        #expect(limit.remaining(nil, at: start) == 3)
        var spend: ReorderSpend?
        for left in [2, 1, 0] {
            spend = limit.spending(spend, at: start)
            #expect(spend != nil)
            #expect(limit.remaining(spend, at: start) == left)
        }
        #expect(limit.spending(spend, at: start) == nil)
    }

    /// One back each interval, counted from the first one spent, never past the initial balance.
    @Test func refillsOneEachIntervalUpToTheBalance() {
        let limit = ReorderLimit(isOn: true, allowance: 3, refillMinutes: 15)
        var spend = limit.spending(nil, at: minutes(0))
        spend = limit.spending(spend, at: minutes(1))
        spend = limit.spending(spend, at: minutes(2))
        #expect(limit.remaining(spend, at: minutes(14)) == 0)
        #expect(limit.nextRefill(spend, at: minutes(14)) == minutes(15))
        #expect(limit.remaining(spend, at: minutes(15)) == 1)
        #expect(limit.nextRefill(spend, at: minutes(15)) == minutes(30))
        #expect(limit.remaining(spend, at: minutes(44)) == 2)
        #expect(limit.remaining(spend, at: minutes(45)) == 3)
        #expect(limit.nextRefill(spend, at: minutes(45)) == nil)
        #expect(limit.remaining(spend, at: minutes(500)) == 3)
    }

    /// Spending from a full balance starts the clock then, not when the last one came back.
    @Test func theRefillClockStartsWithTheFirstOneSpent() {
        let limit = ReorderLimit(isOn: true, allowance: 1, refillMinutes: 10)
        var spend = limit.spending(nil, at: minutes(0))
        #expect(limit.remaining(spend, at: minutes(10)) == 1)
        spend = limit.spending(spend, at: minutes(25))
        #expect(limit.remaining(spend, at: minutes(34)) == 0)
        #expect(limit.nextRefill(spend, at: minutes(26)) == minutes(35))
        #expect(limit.remaining(spend, at: minutes(35)) == 1)
    }

    /// Partly spent, a refill keeps its place: spending another doesn't restart the clock.
    @Test func spendingAgainKeepsTheNextRefill() {
        let limit = ReorderLimit(isOn: true, allowance: 3, refillMinutes: 15)
        var spend = limit.spending(nil, at: minutes(0))
        spend = limit.spending(spend, at: minutes(10))
        #expect(limit.nextRefill(spend, at: minutes(10)) == minutes(15))
        spend = limit.spending(spend, at: minutes(20)) // one came back at 15
        #expect(limit.remaining(spend, at: minutes(20)) == 1)
        #expect(limit.nextRefill(spend, at: minutes(20)) == minutes(30))
    }

    @Test func neverRefillsIsAFixedNumberForTheParty() {
        let limit = ReorderLimit(isOn: true, allowance: 2, refillMinutes: 0)
        var spend = limit.spending(nil, at: minutes(0))
        spend = limit.spending(spend, at: minutes(1))
        #expect(limit.remaining(spend, at: minutes(10_000)) == 0)
        #expect(limit.nextRefill(spend, at: minutes(1)) == nil)
        #expect(limit.spending(spend, at: minutes(10_000)) == nil)
    }

    /// The host changing the balance mid-party applies to what everyone has already spent.
    @Test func changingTheBalanceAppliesToWhatsSpent() {
        var limit = ReorderLimit(isOn: true, allowance: 3, refillMinutes: 15)
        var spend = limit.spending(nil, at: minutes(0))
        spend = limit.spending(spend, at: minutes(0))
        limit.allowance = 5
        #expect(limit.remaining(spend, at: minutes(1)) == 3)
        limit.allowance = 1
        #expect(limit.remaining(spend, at: minutes(1)) == 0)
        // Not two refills to wait for: one is back at 15 minutes.
        #expect(limit.remaining(spend, at: minutes(15)) == 1)
    }

    @Test func pagesCantSetValuesTheSettingsDontOffer() {
        #expect(ReorderLimit(isOn: true, allowance: 50, refillMinutes: 15).validated.allowance == 10)
        #expect(ReorderLimit(isOn: true, allowance: 0, refillMinutes: 15).validated.allowance == 1)
        #expect(ReorderLimit(isOn: true, allowance: 3, refillMinutes: 7).validated.refillMinutes == 15)
        #expect(ReorderLimit(isOn: true, allowance: 3, refillMinutes: 0).validated.refillMinutes == 0)
    }

    @Test func offByDefaultWithThreeEveryFifteenMinutes() {
        let defaults = UserDefaults(suiteName: "ReorderLimitTests")!
        defaults.removePersistentDomain(forName: "ReorderLimitTests")
        #expect(ReorderLimit(defaults: defaults) == ReorderLimit(isOn: false, allowance: 3, refillMinutes: 15))
        ReorderLimit(isOn: true, allowance: 5, refillMinutes: 0).save(to: defaults)
        #expect(ReorderLimit(defaults: defaults) == ReorderLimit(isOn: true, allowance: 5, refillMinutes: 0))
        defaults.removePersistentDomain(forName: "ReorderLimitTests")
    }

    @Test func footerCopy() {
        #expect(ReorderLimit(isOn: true, allowance: 3, refillMinutes: 15).summary
                == "Each person can reorder 3 times and gets another every 15 minutes, up to 3. Hosts and displays aren't limited.")
        #expect(ReorderLimit(isOn: true, allowance: 1, refillMinutes: 5).summary
                == "Each person can reorder once every 5 minutes. Hosts and displays aren't limited.")
        #expect(ReorderLimit(isOn: true, allowance: 4, refillMinutes: 0).summary
                == "Each person can reorder 4 times for the whole party. Hosts and displays aren't limited.")
        #expect(ReorderLimit.refillLabel(30) == "Every 30 min")
        #expect(ReorderLimit.refillLabel(0) == "Never")
    }

    // MARK: On the hub

    /// A hub with a few guests' songs in Up Next, the limit on at `allowance` and never refilling.
    func makeHub(allowance: Int = 2, storeURL: URL? = nil) async throws -> PartySession {
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b", "c", "d", "e"]), engine: FakeEngine(), storeURL: storeURL)
        try await session.load(playlist: base)
        try await session.play()
        for (id, owner) in [("x", "sam"), ("y", "alex"), ("z", "sam")] {
            session.add(track(id), by: Requester(name: owner, clientID: owner, origin: .phone))
        }
        session.reorderLimit = ReorderLimit(isOn: true, allowance: allowance, refillMinutes: 0)
        return session
    }

    func id(_ trackID: String, in session: PartySession) throws -> UUID {
        try #require(session.state.upNext.first { $0.track.id == trackID }).id
    }

    /// The last song in Up Next, to move something to the bottom.
    func last(_ session: PartySession) -> UUID? {
        session.state.upNext.last?.id
    }

    @Test func eachDragSpendsOneUntilNoneAreLeft() async throws {
        let session = try await makeHub(allowance: 2)
        let alexs = try id("y", in: session)
        #expect(session.move(alexs, after: nil, asClient: "sam") == .moved)
        #expect(session.reorderSpends["sam"]?.spent == 1)
        // However far it goes, it's one.
        let last = try #require(session.state.upNext.last?.id)
        #expect(session.move(alexs, after: last, asClient: "sam") == .moved)
        #expect(session.reorderSpends["sam"]?.spent == 2)
        let before = session.state.upNext.map(\.id)
        #expect(session.move(alexs, after: nil, asClient: "sam") == .outOfReorders)
        #expect(session.state.upNext.map(\.id) == before)
        // Counted per person: Alex still has theirs.
        #expect(session.move(alexs, after: nil, asClient: "alex") == .moved)
    }

    /// Moving your own song further down is free; up costs one, as does moving anyone else's down.
    @Test func movingYourOwnSongDownIsFree() async throws {
        let session = try await makeHub(allowance: 1)
        let samsFirst = try id("x", in: session)
        let last = try #require(session.state.upNext.last?.id)
        #expect(session.move(samsFirst, after: last, asClient: "sam") == .moved)
        #expect(session.state.upNext.last?.id == samsFirst)
        #expect(session.reorderSpends["sam"] == nil)
        // Someone else's song down isn't free.
        let alexs = try id("y", in: session)
        #expect(session.move(alexs, after: samsFirst, asClient: "sam") == .moved)
        #expect(session.reorderSpends["sam"]?.spent == 1)
        // Out of reorders, their own song down still moves; up doesn't.
        let samsSecond = try id("z", in: session)
        #expect(session.move(samsSecond, after: alexs, asClient: "sam") == .moved)
        #expect(session.move(samsSecond, after: nil, asClient: "sam") == .outOfReorders)
    }

    @Test func hostsAndDisplaysArentLimited() async throws {
        let session = try await makeHub(allowance: 1)
        let song = try id("y", in: session)
        for _ in 0..<3 {
            #expect(session.move(song, after: nil, asClient: nil) == .moved) // a host
            #expect(session.move(song, after: last(session), asClient: nil) == .moved)
        }
        session.noteDisplay(ZoneDisplay(id: "kitchen", name: "Kitchen iPad", kind: .ipad))
        for _ in 0..<3 {
            #expect(session.move(song, after: nil, asClient: "kitchen") == .moved)
            #expect(session.move(song, after: last(session), asClient: "kitchen") == .moved)
        }
        #expect(session.reorderSpends.isEmpty)
    }

    @Test func offMeansUnlimitedAndForgetsWhatWasSpent() async throws {
        let session = try await makeHub(allowance: 1)
        let song = try id("y", in: session)
        #expect(session.move(song, after: nil, asClient: "sam") == .moved)
        #expect(session.move(song, after: last(session), asClient: "sam") == .outOfReorders)
        session.reorderLimit.isOn = false
        #expect(session.reorderSpends.isEmpty)
        #expect(session.move(song, after: last(session), asClient: "sam") == .moved)
        #expect(session.move(song, after: nil, asClient: "sam") == .moved)
        session.reorderLimit.isOn = true
        #expect(session.move(song, after: last(session), asClient: "sam") == .moved)
    }

    /// A hub relaunched mid-party (a crash, an update) keeps what guests had spent, as it keeps
    /// the queue; ending the party forgets it.
    @Test func whatsSpentSurvivesARelaunchAndEndClearsIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: url.deletingPathExtension().lastPathComponent + "-reorders.json"))
        }
        let first = try await makeHub(allowance: 2, storeURL: url)
        #expect(first.move(try id("y", in: first), after: nil, asClient: "sam") == .moved)
        // The queue's save is debounced.
        try await Task.sleep(for: .milliseconds(800))

        let restored = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(restored.reorderSpends["sam"]?.spent == 1)
        restored.end()
        let next = PartySession(catalog: StubCatalog(ids: []), engine: FakeEngine(), storeURL: url)
        #expect(next.reorderSpends.isEmpty)
    }

    /// Guests' pages work out their balance from the snapshot; the setting rides along for the
    /// host's sheet, on or off.
    @Test func snapshotsCarryTheLimitAndWhatsSpent() async throws {
        let session = try await makeHub(allowance: 3)
        #expect(session.snapshot().reorderLimit == ReorderLimit(isOn: true, allowance: 3, refillMinutes: 0))
        #expect(session.snapshot().reorderSpends == nil)
        #expect(session.move(try id("y", in: session), after: nil, asClient: "sam") == .moved)
        let sent = try JSONDecoder().decode(PartySnapshot.self, from: JSONEncoder().encode(session.snapshot()))
        #expect(sent.reorderSpends?["sam"]?.spent == 1)
        session.reorderLimit.isOn = false
        #expect(session.snapshot().reorderLimit?.isOn == false)
        #expect(session.snapshot().reorderSpends == nil)
    }

    @Test func hostSettingsFromTheWebAreKeptInRange() async throws {
        let session = PartySession(catalog: StubCatalog(ids: ["a"]), engine: FakeEngine())
        session.applyHostSettings(zoneName: nil, phonesCanReorder: nil,
                                  reorderLimit: ReorderLimit(isOn: true, allowance: 99, refillMinutes: 30), displaysCanControl: nil)
        #expect(session.reorderLimit == ReorderLimit(isOn: true, allowance: 10, refillMinutes: 30))
    }
}
