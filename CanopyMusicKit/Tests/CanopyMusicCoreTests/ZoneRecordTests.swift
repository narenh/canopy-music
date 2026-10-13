import Foundation
import Testing
@testable import CanopyMusicCore

@MainActor
struct ZoneRecordTests {
    private func makeRecord() -> (ZoneRecord, UserDefaults) {
        let defaults = UserDefaults(suiteName: "zone-record-\(UUID())")!
        return (ZoneRecord(defaults: defaults), defaults)
    }

    @Test func nothingToRestoreOnAFreshInstall() {
        let (record, _) = makeRecord()
        #expect(!record.hasZone)
        #expect(!record.restoresOnLaunch)
    }

    @Test func aNewZoneRestoresUnlockedUntilLocked() {
        let (record, defaults) = makeRecord()
        record.hosting(fresh: true)
        record.started()
        #expect(record.restoresOnLaunch)
        #expect(!record.wasLocked)
        record.wasLocked = true
        #expect(ZoneRecord(defaults: defaults).wasLocked)
    }

    @Test func resumingKeepsTheLockAndHost() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.wasLocked = true
        record.hostJoined = true
        record.hosting(fresh: false)
        #expect(record.wasLocked)
        #expect(record.hostJoined)
    }

    @Test func aNewZoneForgetsTheOldOnesLockAndHost() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.wasLocked = true
        record.hostJoined = true
        record.hosting(fresh: true)
        #expect(!record.wasLocked)
        #expect(!record.hostJoined)
    }

    @Test func leavingKeepsTheZoneButStartsAtTheList() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.started()
        record.stoppedHosting()
        #expect(record.hasZone)
        #expect(!record.restoresOnLaunch)
        #expect(!record.endsOnLaunch)
    }

    /// The rule: no music yet, no restore. The zone is ended at the next launch instead.
    @Test func aZoneWhereMusicNeverStartedIsEndedAtLaunch() {
        let (record, defaults) = makeRecord()
        record.hosting(fresh: true)
        let next = ZoneRecord(defaults: defaults)
        #expect(!next.hasStarted)
        #expect(!next.restoresOnLaunch)
        #expect(next.endsOnLaunch)
    }

    /// Even if it was left for the list (or another zone) first: nothing to resume either.
    @Test func aZoneLeftBeforeMusicStartedIsEndedAtLaunch() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.stoppedHosting()
        #expect(record.endsOnLaunch)
    }

    @Test func onceMusicStartsTheZoneRestores() {
        let (record, defaults) = makeRecord()
        record.hosting(fresh: true)
        record.started()
        let next = ZoneRecord(defaults: defaults)
        #expect(next.hasStarted)
        #expect(next.restoresOnLaunch)
        #expect(!next.endsOnLaunch)
    }

    @Test func resumingKeepsStartedButANewZoneStartsOver() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.started()
        record.hosting(fresh: false)
        #expect(record.hasStarted)
        record.hosting(fresh: true)
        #expect(!record.hasStarted)
        #expect(record.endsOnLaunch)
    }

    /// Music playing with no zone (nothing to come back to) records nothing.
    @Test func startedWithoutAZoneIsIgnored() {
        let (record, defaults) = makeRecord()
        record.started()
        #expect(defaults.object(forKey: "zoneStarted") == nil)
        #expect(!record.restoresOnLaunch)
        #expect(!record.endsOnLaunch)
    }

    @Test func endingClearsEverything() {
        let (record, defaults) = makeRecord()
        record.hosting(fresh: true)
        record.started()
        record.wasLocked = false
        record.hostJoined = true
        record.ended()
        let next = ZoneRecord(defaults: defaults)
        #expect(!next.hasZone)
        #expect(!next.restoresOnLaunch)
        #expect(!next.endsOnLaunch)
        #expect(!next.hostJoined)
        #expect(defaults.object(forKey: "zoneStarted") == nil)
    }

    /// A zone from a build that didn't record whether music started: it had if songs played (the
    /// party log in its saved queue), so it keeps coming back; otherwise it's ended at launch.
    @Test func anOlderBuildsZoneIsSettledFromItsPartyLog() {
        let (played, playedDefaults) = makeRecord()
        playedDefaults.set(true, forKey: "wasHub")
        playedDefaults.set(true, forKey: "zoneWasHosting")
        played.settleStarted(songsPlayed: true)
        #expect(played.restoresOnLaunch)

        let (unplayed, unplayedDefaults) = makeRecord()
        unplayedDefaults.set(true, forKey: "wasHub")
        unplayedDefaults.set(true, forKey: "zoneWasHosting")
        unplayed.settleStarted(songsPlayed: false)
        #expect(!unplayed.restoresOnLaunch)
        #expect(unplayed.endsOnLaunch)
    }

    /// Settling never overrides what this build recorded, and doesn't look at the queue to do so.
    @Test func settlingOnlyFillsInAnUnknown() {
        let (record, _) = makeRecord()
        record.hosting(fresh: true)
        record.settleStarted(songsPlayed: { Issue.record("read the queue"); return true }())
        #expect(!record.hasStarted)
        record.started()
        record.settleStarted(songsPlayed: false)
        #expect(record.hasStarted)
        record.ended()
        record.settleStarted(songsPlayed: { Issue.record("read the queue"); return true }())
        #expect(!record.hasZone)
    }

    /// A zone from a build that didn't record the lock comes back locked, never in host mode.
    @Test func anUnknownLockCountsAsLocked() {
        let (record, defaults) = makeRecord()
        defaults.set(true, forKey: "wasHub")
        defaults.set(true, forKey: "zoneWasHosting")
        #expect(record.restoresOnLaunch)
        #expect(record.wasLocked)
    }

    /// Earlier builds' "wasHub" still offers Resume, but doesn't go straight back in.
    @Test func anOlderBuildsZoneIsOfferedNotRestored() {
        let (record, defaults) = makeRecord()
        defaults.set(true, forKey: "wasHub")
        #expect(record.hasZone)
        #expect(!record.restoresOnLaunch)
    }
}

/// "Started" comes from the player actually starting a song, as the apps wire it up.
@MainActor
struct ZoneStartTests {
    private func makeZone(storeURL: URL? = nil) -> (PartySession, FakeEngine, ZoneRecord) {
        let record = ZoneRecord(defaults: UserDefaults(suiteName: "zone-start-\(UUID())")!)
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine, storeURL: storeURL)
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Demo")
        session.onSongStarted = { record.started() }
        record.hosting(fresh: true)
        return (session, engine, record)
    }

    @Test func aLoadedPlaylistIsNotAStart() async throws {
        let (session, _, record) = makeZone()
        try await session.load(playlist: base)
        await settle()
        #expect(!record.hasStarted)
        #expect(record.endsOnLaunch)
    }

    @Test func playingIsAStart() async throws {
        let (session, _, record) = makeZone()
        try await session.load(playlist: base)
        try await session.play()
        #expect(record.hasStarted)
        #expect(record.restoresOnLaunch)
    }

    /// Seen on an Apple TV: set up from a phone, but Start failed. It mustn't come back.
    @Test func aFailedStartIsNotAStart() async throws {
        let (session, engine, record) = makeZone()
        try await session.load(playlist: base)
        engine.playError = URLError(.cannotConnectToHost)
        await #expect(throws: (any Error).self) { try await session.play() }
        #expect(session.state.current != nil) // the queue moved on, but nothing played
        #expect(!record.hasStarted)
        #expect(record.endsOnLaunch)
    }

    /// What the apps read to settle an older build's zone: the saved queue's party log.
    @Test func theSavedQueueSaysWhetherSongsPlayed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(QueueState.saved(at: url) == nil)
        let (session, _, _) = makeZone(storeURL: url)
        try await session.load(playlist: base)
        try await Task.sleep(for: .milliseconds(800))
        #expect(QueueState.saved(at: url)?.log.isEmpty == true)
        try await session.play()
        try await Task.sleep(for: .milliseconds(800))
        #expect(QueueState.saved(at: url)?.log.isEmpty == false)
    }
}
