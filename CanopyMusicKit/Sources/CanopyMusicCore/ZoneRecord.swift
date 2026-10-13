import Foundation

/// What a hub (iPad or Apple TV) remembers about its own zone between launches, so that after a
/// crash or a quit by the system it can go straight back in. A zone is recorded only once music
/// has started in it (Start on an iPad or Mac, a phone's "Start the music" on an Apple TV), and
/// only ending it clears it (docs/multi-device.md). The queue itself is saved by `PartySession`.
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

    /// Music has actually started playing in this zone. Always true for a zone this build
    /// recorded (it's recorded when music starts). Older builds recorded a zone as soon as it was
    /// created: theirs say false if music never started, or nothing (unknown, counted as started
    /// unless `settleStarted` finds otherwise).
    public var hasStarted: Bool { defaults.object(forKey: Keys.started) as? Bool ?? true }

    /// The next launch goes straight back into the zone.
    public var restoresOnLaunch: Bool { hasZone && wasHosting && hasStarted }

    /// The next launch ends the zone, as End does. Only a zone recorded by an older build where
    /// music never started: there's nothing to come back to, so the device starts at the zone
    /// list with nothing to resume.
    public var endsOnLaunch: Bool { hasZone && !hasStarted }

    /// Launch: a zone recorded by an older build that didn't say whether music started gets it
    /// now, from whether any song played in it (the party log in its saved queue). Read only if
    /// needed.
    public func settleStarted(songsPlayed: @autoclosure () -> Bool) {
        guard hasZone, defaults.object(forKey: Keys.started) == nil else { return }
        defaults.set(songsPlayed(), forKey: Keys.started)
    }

    /// iPad: the party screen was locked, so host mode was behind press and hold (and the PIN).
    /// Unknown counts as locked: coming back in host mode would skip the PIN. Kept only while
    /// there's a zone.
    public var wasLocked: Bool {
        get { defaults.object(forKey: Keys.locked) as? Bool ?? true }
        set { if hasZone { defaults.set(newValue, forKey: Keys.locked) } }
    }

    /// Apple TV: a phone had taken Host Control, so the TV was past "Scan to host". Kept only
    /// while there's a zone (`began` takes it for a new one).
    public var hostJoined: Bool {
        get { defaults.bool(forKey: Keys.hostJoined) }
        set { if hasZone { defaults.set(newValue, forKey: Keys.hostJoined) } }
    }

    /// Music started in a new zone on this device: from now on it's this device's zone, hosted,
    /// unlocked, and comes back after a crash. `hostJoined`: a phone has Host Control (TV).
    public func began(hostJoined: Bool = false) {
        defaults.set(true, forKey: Keys.hasZone)
        defaults.set(true, forKey: Keys.hosting)
        defaults.set(true, forKey: Keys.started)
        defaults.set(false, forKey: Keys.locked)
        defaults.set(hostJoined, forKey: Keys.hostJoined)
    }

    /// The player started a song (Apple TV): the zone begins with its first song, after a phone's
    /// "Start the music". A zone already recorded (resumed, or restored) is left as it is.
    public func songStarted(hostJoined: Bool) {
        guard !hasZone else { return }
        began(hostJoined: hostJoined)
    }

    /// Hosting the zone it had again (Resume, or back by itself at launch), keeping its lock and host.
    public func resumedHosting() {
        guard hasZone else { return }
        defaults.set(true, forKey: Keys.hosting)
    }

    /// Showing the zone list or another device's zone: the zone is kept, but the next launch
    /// starts at the zone list.
    public func stoppedHosting() {
        guard hasZone else { return }
        defaults.set(false, forKey: Keys.hosting)
    }

    /// Apple TV, until it records its zone at the first song: a zone recorded at Create.
    public func hosting(fresh: Bool) {
        defaults.set(true, forKey: Keys.hasZone)
        defaults.set(true, forKey: Keys.hosting)
        if fresh {
            defaults.set(false, forKey: Keys.locked)
            defaults.set(false, forKey: Keys.hostJoined)
            defaults.set(false, forKey: Keys.started)
        }
    }

    /// Apple TV, until it records its zone at the first song.
    public func started() {
        guard hasZone else { return }
        defaults.set(true, forKey: Keys.started)
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
