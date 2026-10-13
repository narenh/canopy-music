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
        #expect(!record.endsOnLaunch)
    }

    /// A zone is recorded when music starts in it, so it always comes back.
    @Test func aStartedZoneRestoresUnlockedUntilLocked() {
        let (record, defaults) = makeRecord()
        record.began()
        let next = ZoneRecord(defaults: defaults)
        #expect(next.hasZone)
        #expect(next.hasStarted)
        #expect(next.restoresOnLaunch)
        #expect(!next.endsOnLaunch)
        #expect(!next.wasLocked)
        record.wasLocked = true
        #expect(ZoneRecord(defaults: defaults).wasLocked)
    }

    /// The start screen (iPad) and Scan to host (TV) record nothing: the lock and the host only
    /// stick once there's a zone.
    @Test func nothingIsRecordedBeforeMusicStarts() {
        let (record, defaults) = makeRecord()
        record.wasLocked = false
        record.hostJoined = true
        record.resumedHosting()
        record.stoppedHosting()
        #expect(!record.hasZone)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("zone") || $0 == "wasHub" }.isEmpty)
    }

    @Test func resumingKeepsTheLockAndHost() {
        let (record, _) = makeRecord()
        record.began(hostJoined: true)
        record.wasLocked = true
        record.stoppedHosting()
        record.resumedHosting()
        #expect(record.restoresOnLaunch)
        #expect(record.wasLocked)
        #expect(record.hostJoined)
    }

    @Test func aNewZoneForgetsTheOldOnesLockAndHost() {
        let (record, _) = makeRecord()
        record.began(hostJoined: true)
        record.wasLocked = true
        record.ended()
        record.began()
        #expect(!record.wasLocked)
        #expect(!record.hostJoined)
    }

    @Test func leavingKeepsTheZoneButStartsAtTheList() {
        let (record, _) = makeRecord()
        record.began()
        record.stoppedHosting()
        #expect(record.hasZone)
        #expect(!record.restoresOnLaunch)
        #expect(!record.endsOnLaunch)
    }

    /// Apple TV: the first song records the zone, with whether a phone had taken Host Control.
    /// Later songs, or songs in a zone it resumed, change nothing.
    @Test func theFirstSongRecordsATVZone() {
        let (record, _) = makeRecord()
        record.songStarted(hostJoined: true)
        #expect(record.restoresOnLaunch)
        #expect(record.hostJoined)
        record.hostJoined = false
        record.songStarted(hostJoined: true)
        #expect(!record.hostJoined)
    }

    @Test func endingClearsEverything() {
        let (record, defaults) = makeRecord()
        record.began(hostJoined: true)
        record.wasLocked = false
        record.ended()
        let next = ZoneRecord(defaults: defaults)
        #expect(!next.hasZone)
        #expect(!next.restoresOnLaunch)
        #expect(!next.endsOnLaunch)
        #expect(!next.hostJoined)
        #expect(defaults.object(forKey: "zoneStarted") == nil)
    }

    // MARK: Zones recorded by older builds (recorded at Create)

    /// Older builds recorded `zoneStarted = false` at Create: music never started, so the zone is
    /// ended at launch (hosting or not when the app quit).
    @Test func anOlderBuildsZoneWhereMusicNeverStartedIsEnded() {
        for hosting in [true, false] {
            let (record, defaults) = makeRecord()
            defaults.set(true, forKey: "wasHub")
            defaults.set(hosting, forKey: "zoneWasHosting")
            defaults.set(false, forKey: "zoneStarted")
            record.settleStarted(songsPlayed: { Issue.record("read the queue"); return true }())
            #expect(!record.restoresOnLaunch)
            #expect(record.endsOnLaunch)
        }
    }

    @Test func anOlderBuildsZoneWhereMusicStartedRestores() {
        let (record, defaults) = makeRecord()
        defaults.set(true, forKey: "wasHub")
        defaults.set(true, forKey: "zoneWasHosting")
        defaults.set(true, forKey: "zoneStarted")
        #expect(record.restoresOnLaunch)
        #expect(!record.endsOnLaunch)
    }

    /// From a build that didn't record whether music started: it had if songs played (the party
    /// log in its saved queue), so it keeps coming back; otherwise it's ended at launch.
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

    /// Settling never overrides what was recorded, and doesn't look at the queue to do so.
    @Test func settlingOnlyFillsInAnUnknown() {
        let (record, _) = makeRecord()
        record.began()
        record.settleStarted(songsPlayed: { Issue.record("read the queue"); return false }())
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

/// An Apple TV zone is recorded when the player actually starts its first song, as the TV app
/// wires it up (`ZoneRecord.songStarted`).
@MainActor
struct ZoneStartTests {
    private func makeZone(storeURL: URL? = nil) -> (PartySession, FakeEngine, ZoneRecord) {
        let record = ZoneRecord(defaults: UserDefaults(suiteName: "zone-start-\(UUID())")!)
        let engine = FakeEngine()
        let session = PartySession(catalog: StubCatalog(ids: ["a", "b"]), engine: engine, storeURL: storeURL)
        session.configureHub(kind: .tv, zoneName: "Den", serviceName: "Demo")
        session.onSongStarted = { record.songStarted(hostJoined: true) }
        return (session, engine, record)
    }

    @Test func aLoadedPlaylistIsNotAZone() async throws {
        let (session, _, record) = makeZone()
        try await session.load(playlist: base)
        await settle()
        #expect(!record.hasZone)
    }

    @Test func playingMakesItAZone() async throws {
        let (session, _, record) = makeZone()
        try await session.load(playlist: base)
        try await session.play()
        #expect(record.hasZone)
        #expect(record.restoresOnLaunch)
        #expect(record.hostJoined)
    }

    /// Seen on an Apple TV: set up from a phone, but Start failed. It mustn't come back.
    @Test func aFailedStartIsNotAZone() async throws {
        let (session, engine, record) = makeZone()
        try await session.load(playlist: base)
        engine.playError = URLError(.cannotConnectToHost)
        await #expect(throws: (any Error).self) { try await session.play() }
        #expect(session.state.current != nil) // the queue moved on, but nothing played
        #expect(!record.hasZone)
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
