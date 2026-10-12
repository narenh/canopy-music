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
        record.stoppedHosting()
        #expect(record.hasZone)
        #expect(!record.restoresOnLaunch)
    }

    @Test func endingClearsEverything() {
        let (record, defaults) = makeRecord()
        record.hosting(fresh: true)
        record.wasLocked = false
        record.hostJoined = true
        record.ended()
        let next = ZoneRecord(defaults: defaults)
        #expect(!next.hasZone)
        #expect(!next.restoresOnLaunch)
        #expect(!next.hostJoined)
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
