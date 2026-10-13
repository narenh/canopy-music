import Foundation

/// What a hub (iPad or Apple TV) remembers about its own zone between launches, so that after a
/// crash or a quit by the system it can go straight back in. Only ending the zone clears it, or
/// a launch finding music never started in it (docs/multi-device.md). The queue itself is saved
/// by `PartySession`.
@MainActor
public final class ZoneRecord {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A zone was started on this device and hasn't been ended: the zone list offers to resume
    /// it, and creating a new zone asks first.
    public var hasZone: Bool { defaults.bool(forKey: Keys.hasZone) }

    /// This device was hosting its zone when the app last quit (rather than showing another zone
    /// or the zone list).
    public var wasHosting: Bool { defaults.bool(forKey: Keys.hosting) }

    /// Music has actually started playing in this zone at least once (not just a playlist loaded).
    /// A zone recorded by a build from before this was kept counts as started, unless
    /// `settleStarted` finds otherwise.
    public var hasStarted: Bool { defaults.object(forKey: Keys.started) as? Bool ?? true }

    /// The next launch goes straight back into the zone. Only a zone where music had started.
    public var restoresOnLaunch: Bool { hasZone && wasHosting && hasStarted }

    /// The next launch ends the zone, as End does: music never started in it, so there's nothing
    /// to come back to, and the device starts at the zone list with nothing to resume.
    public var endsOnLaunch: Bool { hasZone && !hasStarted }

    /// The player started a song in this zone.
    public func started() {
        guard hasZone else { return }
        defaults.set(true, forKey: Keys.started)
    }

    /// Launch: a zone recorded by a build from before `hasStarted` was kept gets it now, from
    /// whether any song played in it (the party log in its saved queue). Read only if needed.
    public func settleStarted(songsPlayed: @autoclosure () -> Bool) {
        guard hasZone, defaults.object(forKey: Keys.started) == nil else { return }
        defaults.set(songsPlayed(), forKey: Keys.started)
    }

    /// iPad: the party screen was locked, so host mode was behind press and hold (and the PIN).
    /// Unknown counts as locked: coming back in host mode would skip the PIN.
    public var wasLocked: Bool {
        get { defaults.object(forKey: Keys.locked) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.locked) }
    }

    /// Apple TV: a phone had taken Host Control, so the TV was past "Scan to host".
    public var hostJoined: Bool {
        get { defaults.bool(forKey: Keys.hostJoined) }
        set { defaults.set(newValue, forKey: Keys.hostJoined) }
    }

    /// This device is hosting its zone: a new one (`fresh`), or the one it had.
    public func hosting(fresh: Bool) {
        defaults.set(true, forKey: Keys.hasZone)
        defaults.set(true, forKey: Keys.hosting)
        if fresh {
            wasLocked = false
            hostJoined = false
            defaults.set(false, forKey: Keys.started)
        }
    }

    /// Showing the zone list or another device's zone: the zone is kept, but the next launch
    /// starts at the zone list.
    public func stoppedHosting() {
        defaults.set(false, forKey: Keys.hosting)
    }

    /// The zone was ended: nothing to resume.
    public func ended() {
        for key in [Keys.hasZone, Keys.hosting, Keys.locked, Keys.hostJoined, Keys.started] {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        /// The name earlier builds used for "a zone is running here".
        static let hasZone = "wasHub"
        static let hosting = "zoneWasHosting"
        static let locked = "zoneWasLocked"
        static let hostJoined = "zoneHostJoined"
        static let started = "zoneStarted"
    }
}
