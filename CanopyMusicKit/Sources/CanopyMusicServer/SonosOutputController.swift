import CanopyMusicCore
import Foundation
import Observation

/// Rooms chosen as the output, and how to reach them (kept, so a relaunch plays there before
/// discovery has run again).
public struct SonosOutput: Codable, Equatable, Sendable {
    /// The first leads the group.
    public var roomIDs: [String]
    public var target: SonosTarget

    public init(roomIDs: [String], target: SonosTarget) {
        self.roomIDs = roomIDs
        self.target = target
    }

    public init(target: SonosTarget) {
        self.init(roomIDs: target.rooms.map(\.id), target: target)
    }
}

/// What a `SonosEngine` needs.
public struct SonosPlayback: Equatable, Sendable {
    public var target: SonosTarget
    public var reference: SonosTrackReference

    public init(target: SonosTarget, reference: SonosTrackReference) {
        self.target = target
        self.reference = reference
    }
}

/// A hub's Sonos output, shared by the iPad (and Mac) and Apple TV apps: which rooms the zone's
/// music plays on and from whose account, kept across launches; the rooms joining and leaving
/// while it plays; their volumes; and what a host's phone is told (`setup()`, `SonosSetup`).
/// Playback itself is the session's `SonosEngine`; the app builds the session (`makeEngine`) and
/// rebuilds it when `onOutputChanged` says the output moved (this device or a Spotify Connect
/// device ⇄ Sonos, or another account).
@MainActor
@Observable
public final class SonosOutputController {
    public let household: SonosHousehold

    /// nil: music plays on the hub itself (AirPlay) or, for Spotify, its Spotify Connect device.
    /// Kept in step with the engine's rooms as they join and leave, so a relaunch plays there.
    public private(set) var output: SonosOutput? {
        didSet {
            guard output != oldValue else { return }
            if let defaults { defaults.set(try? JSONEncoder().encode(output), forKey: Self.outputKey) }
            changed()
        }
    }
    /// The account Sonos streams from, per service (`SonosMusicService.rawValue`), as chosen.
    public private(set) var chosenAccounts: [String: SonosAccount] {
        didSet {
            guard chosenAccounts != oldValue else { return }
            if let defaults { defaults.set(try? JSONEncoder().encode(chosenAccounts), forKey: Self.accountsKey) }
            changed()
        }
    }
    /// Every linked account each Sonos household has shown this hub, or another hub told it of
    /// (`SonosAccountMemory`), kept under `knownAccountsKey`.
    public private(set) var memory: SonosAccountMemory {
        didSet {
            guard memory != oldValue else { return }
            if let defaults { defaults.set(try? JSONEncoder().encode(memory), forKey: Self.knownAccountsKey) }
        }
    }
    /// Services Sonos refused to play from in a household this launch ("household|sid"): the
    /// play with the assumed account (or the last known one) failed, so the service isn't linked
    /// there. No account is assumed for them until one is found.
    public private(set) var unlinked: Set<String> = [] {
        didSet { if unlinked != oldValue { changed() } }
    }
    /// Rooms on their way into the group (a spinner, "Joining…"), until Sonos has them in it.
    public private(set) var joining: Set<String> = [] {
        didSet { if joining != oldValue { changed() } }
    }
    /// The zone's service as Sonos knows it; nil for no service (and the demo). Set by the app.
    public var service: SonosMusicService? {
        didSet { if service != oldValue { changed() } }
    }
    /// The rooms other Canopy Music zones on the network say they play on (`GET /api/zone`,
    /// asked of `peers` while a room list shows), so they read "In use by …" (`claim(on:)`).
    public private(set) var claims: [SonosZoneClaim] = [] {
        didSet { if claims != oldValue { changed() } }
    }
    /// Claims known without asking: a made-up other zone (`-sonosFakeOtherZone`). Set by the app.
    public var standingClaims: [SonosZoneClaim] = [] {
        didSet { if standingClaims != oldValue { changed() } }
    }
    /// Rooms the host took from another zone ("Use", confirmed) while setting this one up: they
    /// stay chosen though that zone still says it plays there (until the first play takes them).
    public private(set) var takenOver: Set<String> = []

    /// The zone's session, whose engine plays through Sonos when the output is Sonos (`connect`).
    @ObservationIgnored public private(set) weak var session: PartySession?
    /// The output moved (or the account did): the app rebuilds the session's engine.
    @ObservationIgnored public var onOutputChanged: (@MainActor () -> Void)?
    /// Anything a host's phone shows changed (`setup()`).
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// A room couldn't join or leave: what to tell the host.
    @ObservationIgnored public var onError: (@MainActor (String) -> Void)?
    /// Whether a host's phone may move the music between Sonos and the hub's own output, or
    /// change the account (`SonosOutputHandler`): only while the zone is being set up.
    @ObservationIgnored public var canChangeOutput: @MainActor () -> Bool = { false }
    /// The zone's music hasn't started yet (the TV's setup page, the iPad's start screen before
    /// Start): rooms another zone plays on are then never this zone's choice unless taken over,
    /// so a choice kept from an earlier zone lets go of them (`releaseClaimedRooms`).
    @ObservationIgnored public var isSettingUp: @MainActor () -> Bool = { false }
    /// For the engines it makes (`[sonos-engine] …` in debug builds).
    @ObservationIgnored public var engineLog: (@MainActor (String) -> Void)?
    /// nil: nothing is kept (a simulated household).
    @ObservationIgnored private let defaults: UserDefaults?
    /// A host's phone asked for a reading while one was under way: it's skipped.
    @ObservationIgnored private var isReading = false
    /// When the last reading started (`readRooms`).
    @ObservationIgnored private var lastReadAt: Date?
    /// A reading this recent is shared rather than taken again: the iPad's Speakers panel and
    /// every host phone's Devices list each ask every 2 s, and each reading asks every room and
    /// every other hub. Short enough that one list on its own still reads every time it asks.
    @ObservationIgnored var readingFreshness: TimeInterval = 1.5
    /// Other hubs to ask for accounts (`GET /api/sonos/accounts`): the zones on the network
    /// other than this device's own. Set by the app.
    @ObservationIgnored public var peers: @MainActor () -> [ZoneListing] = { [] }
    @ObservationIgnored private let exchange: SonosAccountExchange
    /// The last time other hubs were asked, and which (the same ones aren't asked again sooner
    /// than `askInterval`; a new zone is asked at once).
    @ObservationIgnored private var lastAsked: (key: String, at: Date)?
    @ObservationIgnored private var isAsking = false
    /// How other zones are asked which rooms they play on (tests replace the network).
    @ObservationIgnored private let claimExchange: SonosClaimExchange
    /// Each zone's last answer (by address) and when: a zone that misses one answer keeps its
    /// claim for `claimLifetime`, so a slow reply doesn't make its rooms look free for a moment.
    @ObservationIgnored private var claimAnswers: [String: (claim: SonosZoneClaim?, at: Date)] = [:]
    @ObservationIgnored private var lastClaimsAsked: Date?
    @ObservationIgnored private var isAskingClaims = false

    public static let outputKey = "sonosOutput"
    public static let accountsKey = "sonosAccounts"
    public static let knownAccountsKey = "sonosKnownAccounts"
    /// The serial assumed when no account for the service has been seen. A real S2 household
    /// played a linked service's songs with any serial (1–8) or none: with one account per
    /// service, the serial doesn't matter. It does with several ("Whose account plays").
    public static let assumedSerial = 1
    static let askInterval: TimeInterval = 60
    /// Other zones are asked which rooms they play on at most this often (the lists read the
    /// rooms every 2–4 s) while rooms are being picked (`isSettingUp`); less often otherwise
    /// (the party's own Speakers), where another zone taking a room is rare.
    static let claimInterval: TimeInterval = 3
    static let idleClaimInterval: TimeInterval = 10
    static let claimLifetime: TimeInterval = 15

    /// `defaults`: where the rooms and accounts are kept (nil keeps nothing, for a simulated household).
    /// `exchange`, `claimExchange`: how other hubs are asked for accounts, and which rooms they
    /// play on (tests replace the network).
    public init(household: SonosHousehold, defaults: UserDefaults? = .standard, exchange: SonosAccountExchange = SonosAccountExchange(),
                claimExchange: SonosClaimExchange = SonosClaimExchange()) {
        self.household = household
        self.defaults = defaults
        self.exchange = exchange
        self.claimExchange = claimExchange
        output = defaults?.data(forKey: Self.outputKey).flatMap { try? JSONDecoder().decode(SonosOutput.self, from: $0) }
        chosenAccounts = defaults?.data(forKey: Self.accountsKey).flatMap { try? JSONDecoder().decode([String: SonosAccount].self, from: $0) } ?? [:]
        memory = defaults?.data(forKey: Self.knownAccountsKey).flatMap { try? JSONDecoder().decode(SonosAccountMemory.self, from: $0) } ?? SonosAccountMemory()
    }

    private func changed() {
        onChange?()
    }

    // MARK: What plays

    /// The household accounts are kept under: the one discovery read, else the one this hub last read.
    public var householdKey: String? { household.householdID ?? memory.lastHousehold }

    /// Sonos's id for a service in this household (`ListAvailableServices`, else the usual one).
    func serviceID(_ service: SonosMusicService) -> Int {
        SonosParse.serviceID(for: service, in: household.services)
    }

    /// Linked accounts known for a service: found live, merged with those remembered for this
    /// household (seen here before, or told by another hub). Live readings win.
    public func knownAccounts(for service: SonosMusicService) -> [SonosAccount] {
        let sid = serviceID(service)
        return SonosParse.merge([household.accounts, memory.accounts(in: householdKey)]).filter { $0.serviceID == sid }
    }

    /// Linked accounts known for the zone's service (never the assumed one).
    public var accounts: [SonosAccount] {
        service.map(knownAccounts(for:)) ?? []
    }

    /// Sonos refused the service in this household this launch.
    public func isUnlinked(_ service: SonosMusicService) -> Bool {
        unlinked.contains(Self.unlinkedKey(householdKey, serviceID(service)))
    }

    static func unlinkedKey(_ household: String?, _ sid: Int) -> String { "\(household ?? "")|\(sid)" }

    /// What streams when no account for the service is known: serial `assumedSerial`, which plays
    /// from the household's account as long as the service is linked there. None once Sonos has
    /// refused the service (`unlinked`): the "Add … in the Sonos app" note shows instead.
    public var assumedAccount: SonosAccount? {
        guard let service, !isUnlinked(service) else { return nil }
        return SonosAccount(serviceID: serviceID(service), serialNumber: Self.assumedSerial)
    }

    /// The account that streams the zone's songs: the one chosen for the service, else the first
    /// known, else the assumed one (so the rooms can be chosen before any account has been seen).
    public var account: SonosAccount? {
        guard let service else { return nil }
        let known = accounts
        guard let pick = chosenAccounts[service.rawValue] else { return known.first ?? assumedAccount }
        // A newer reading of the same account (its token) wins.
        return known.first { $0.id == pick.id } ?? pick
    }

    /// Rooms and an account to stream from: the session plays through Sonos.
    public var playback: SonosPlayback? {
        guard let output, let service, let account else { return nil }
        return SonosPlayback(target: output.target, reference: SonosTrackReference(service: service, accountSerial: account.serialNumber, token: account.token))
    }

    /// The zone's songs play on Sonos rooms.
    public var usesSonos: Bool { playback != nil }

    /// The session's engine when it plays through Sonos.
    public var engine: SonosEngine? { session?.engine as? SonosEngine }

    /// The zone's music is playing through Sonos rooms right now (the party has started there),
    /// so ticked rooms say "Playing Canopy Music".
    public var isLive: Bool { engine?.isGrouped == true }

    /// Live, and the rooms are still this zone's: no other source (another zone that took them
    /// over, the Sonos app) has them.
    public var ownsRooms: Bool { isLive && engine?.hasLostControl != true }

    // MARK: Other zones' rooms

    /// The claims that count here: other zones', in this household (or one not read yet).
    private var otherClaims: [SonosZoneClaim] {
        let mine = householdKey
        return (claims + standingClaims).filter { claim in claim.household == nil || mine == nil || claim.household == mine }
    }

    /// The other zone playing on `roomID`: one that says it plays there, whose rooms lead the
    /// room's group in the live layout (a room moved into another group since isn't its). Never
    /// for this zone's own rooms while it plays there. A room playing another hub's songs that
    /// no zone claims reads as any busy room does ("Playing …").
    public func claim(on roomID: String) -> SonosZoneClaim? {
        if ownsRooms, engine?.target.rooms.contains(where: { $0.id == roomID }) == true { return nil }
        return SonosZoneClaim.playing(on: roomID, coordinatorID: household.group(containing: roomID)?.coordinatorID, in: otherClaims)
    }

    /// The rooms "Use" on `roomID` offers together: the same zone's, in the same group now, in
    /// the list's order (just `roomID` when it plays there alone).
    public func takenTogether(with roomID: String) -> [String] {
        guard let theirs = claim(on: roomID) else { return [roomID] }
        let coordinator = household.group(containing: roomID)?.coordinatorID
        let together = household.rooms.map(\.id).filter { id in
            claim(on: id) == theirs && (coordinator == nil || household.group(containing: id)?.coordinatorID == coordinator)
        }
        return together.contains(roomID) ? together : [roomID]
    }

    /// A room's second line in the lists (start screen, Speakers, the phone page). `live`: the
    /// party screen's Speakers, where ticked rooms play the zone's music (by default, whether
    /// they do: `ownsRooms`).
    public func status(of player: SonosPlayer, live: Bool? = nil) -> SonosRoomStatus {
        SonosRoomStatus.of(roomID: player.id, model: player.displayName, ticked: isTicked(player.id), joining: joining.contains(player.id),
                           live: live.map { $0 && engine?.hasLostControl != true } ?? ownsRooms,
                           reading: household.readings[player.id], claim: claim(on: player.id))
    }

    /// An engine for the current output, or nil when the music doesn't play through Sonos.
    public func makeEngine() -> SonosEngine? {
        guard let playback else { return nil }
        let engine = SonosEngine(target: playback.target, reference: playback.reference, transport: household.transport)
        engine.log = engineLog
        engine.onAccountRejected = { [weak self] reference in self?.accountRejected(reference) }
        return engine
    }

    /// The session (or its engine) is new: a Sonos engine's rooms, as they change (joining,
    /// leaving, a new coordinator), are the output from now on.
    public func connect(_ session: PartySession) {
        self.session = session
        defer { changed() }
        guard let engine else { return }
        engine.restoredTrackID = session.state.current?.track.id
        engine.onTargetChanged = { [weak self, weak engine] target in
            guard let self, let engine, self.engine === engine else { return }
            self.output = SonosOutput(target: target)
            self.household.preferredHost = target.coordinator.host
        }
        household.preferredHost = engine.target.coordinator.host
    }

    // MARK: Choosing rooms

    public func isTicked(_ roomID: String) -> Bool {
        output?.roomIDs.contains(roomID) == true
    }

    /// Switches the zone's music to these rooms (the first leads; the others join its group when
    /// music starts), from this device or a Spotify Connect device: the session is rebuilt, with
    /// a gap. Picks the first account found for the service if none is chosen yet.
    public func select(rooms roomIDs: [String]) {
        guard !roomIDs.isEmpty, let target = household.target(rooms: roomIDs) else { return leave() }
        if let service, chosenAccounts[service.rawValue] == nil, let first = accounts.first {
            chosenAccounts[service.rawValue] = first
        }
        output = SonosOutput(target: target)
        onOutputChanged?()
    }

    /// Back to this device (AirPlay), or for Spotify its Spotify Connect device.
    public func leave() {
        takenOver = []
        guard output != nil else { return }
        output = nil
        onOutputChanged?()
    }

    /// "Use", confirmed: rooms another zone plays on become this zone's too, with any already
    /// chosen. Not on Sonos yet: the music moves there. Before it has played there: only the
    /// choice changes, and the grouping at the first play takes them (`SonosGroupingPlan`: out
    /// of the other zone's group, or leading it). Playing: they join without a restart. The
    /// other zone isn't told; its engine finds another source on them and leaves them alone.
    public func takeOver(_ roomIDs: [String]) {
        let ids = roomIDs.filter { household.player($0) != nil && !isTicked($0) }
        guard !ids.isEmpty else { return }
        takenOver.formUnion(ids)
        engineLog?("taking over \(ids.compactMap { household.player($0)?.roomName }.joined(separator: ", ")) from \(ids.compactMap { claim(on: $0)?.zone }.first ?? "another zone")")
        guard output != nil else { return select(rooms: ids) }
        for id in ids { add(id) }
    }

    /// A new zone is being set up on this hub (the TV's Create, the iPad's start screen after
    /// End): rooms taken over for an earlier one are just rooms again, and a kept choice lets go
    /// of those another zone plays on.
    public func beginSetup() {
        takenOver = []
        releaseClaimedRooms()
    }

    /// While the zone is set up: chosen rooms another zone plays on (and that the host didn't
    /// take over) aren't this zone's choice. A choice kept from an earlier zone was ticking them
    /// on the TV's page while the iPad's zone played there, and getting off them took unticking
    /// each. With none left, the music plays on the hub's own output.
    func releaseClaimedRooms() {
        guard isSettingUp(), !isLive, let output else { return }
        let claimed = output.roomIDs.filter { !takenOver.contains($0) && claim(on: $0) != nil }
        guard !claimed.isEmpty else { return }
        engineLog?("\(claimed.compactMap { household.player($0)?.roomName }.joined(separator: ", ")): another zone plays there; not chosen")
        let rest = output.roomIDs.filter { !claimed.contains($0) }
        guard !rest.isEmpty, let target = household.target(rooms: rest) else { return leave() }
        engine?.retarget(target)
        self.output = SonosOutput(roomIDs: rest, target: target)
    }

    /// A room's row was tapped. Not another zone's room: that's "Use" (`takeOver`), confirmed.
    public func toggle(_ roomID: String) {
        if isTicked(roomID) { remove(roomID) } else if claim(on: roomID) == nil { add(roomID) }
    }

    /// Adds a room. Not on Sonos yet: the music moves there (a rebuild, with a gap). On Sonos and
    /// playing: it joins the group without a restart, and shows "Joining…" until it's in it.
    /// Before the music has started there: it's just added to the rooms.
    public func add(_ roomID: String) {
        guard let player = household.player(roomID), !joining.contains(roomID) else { return }
        guard let output else { return select(rooms: [roomID]) }
        guard let engine else {
            // No account to stream from yet: only the choice changes.
            if let target = household.target(rooms: output.roomIDs + [roomID]) { self.output = SonosOutput(target: target) }
            return
        }
        let room = SonosHousehold.room(player)
        // Another source has the rooms now: nothing is sent to its group; the room is only
        // noted, and the next play takes them all back.
        guard !engine.hasLostControl else {
            Task { try? await engine.addRoom(room) }
            return
        }
        guard engine.isGrouped else {
            if let target = household.target(rooms: output.roomIDs + [roomID]) {
                engine.retarget(target)
                self.output = SonosOutput(target: target)
            }
            return
        }
        joining.insert(roomID)
        let session = session
        Task {
            defer { joining.remove(roomID) }
            do {
                if let session {
                    try await session.withEngine { try await engine.addRoom(room) }
                } else {
                    try await engine.addRoom(room)
                }
                if !(await engine.waitUntilGrouped(roomID)) {
                    onError?("\(room.name) didn't join. Check it's on and on this Wi\u{2011}Fi.")
                }
            } catch {
                onError?("Couldn't add \(room.name). \(error.localizedDescription)")
            }
            await household.readRooms(ourCoordinatorID: engine.target.coordinator.id)
            changed()
        }
    }

    /// Takes a room out, the music playing on in the others without a restart (the coordinator
    /// first hands the group to another room). The last room goes back to this device (or the
    /// Spotify Connect device); the Speakers lists don't offer that.
    public func remove(_ roomID: String) {
        guard let output, output.roomIDs.contains(roomID) else { return }
        guard output.roomIDs.count > 1 else { return leave() }
        if let engine, engine.hasLostControl {
            // Another source has the rooms: only the choice changes (nothing is sent to them).
            Task { try? await engine.removeRoom(roomID) }
            return
        }
        guard let engine, engine.isGrouped else {
            // Nothing set up on the speakers yet: only the choice changes.
            let rest = output.roomIDs.filter { $0 != roomID }
            if let target = household.target(rooms: rest) {
                engine?.retarget(target)
                self.output = SonosOutput(roomIDs: rest, target: target)
            }
            return
        }
        let session = session
        Task {
            do {
                if let session {
                    try await session.withEngine { try await engine.removeRoom(roomID) }
                } else {
                    try await engine.removeRoom(roomID)
                }
            } catch {
                onError?("Couldn't take \(household.player(roomID)?.roomName ?? "the room") out. \(error.localizedDescription)")
            }
            await household.readRooms(ourCoordinatorID: engine.target.coordinator.id)
            changed()
        }
    }

    /// "Whose account plays".
    public func chooseAccount(_ account: SonosAccount) {
        guard let service else { return }
        chosenAccounts[service.rawValue] = account
        onOutputChanged?()
    }

    /// Sets the rooms and account outright, with no rebuild (a debug party that builds its own session).
    public func use(_ output: SonosOutput, account: SonosAccount, for service: SonosMusicService) {
        chosenAccounts[service.rawValue] = account
        self.output = output
    }

    // MARK: Volume

    /// Sets one room's volume (the sliders send at most every ~150 ms).
    public func setVolume(_ volume: Int, room roomID: String) {
        guard let player = household.player(roomID) else { return }
        let volume = min(100, max(0, volume))
        household.noteVolume(volume, for: roomID)
        changed()
        let client = SonosClient(transport: household.transport, host: player.host)
        Task { try? await client.setVolume(volume) }
    }

    /// Before the All Speakers slider moves: Sonos remembers each room's volume, so the group
    /// volume keeps their balance.
    public func beginGroupVolume() {
        guard let engine else { return }
        let client = SonosClient(transport: household.transport, host: engine.target.coordinator.host)
        Task { try? await client.snapshotGroupVolume() }
    }

    /// The group's volume (the average of its rooms'), each room moved in proportion.
    public func setGroupVolume(_ volume: Int) {
        guard let engine else { return }
        let client = SonosClient(transport: household.transport, host: engine.target.coordinator.host)
        let volume = min(100, max(0, volume))
        Task { try? await client.setGroupVolume(volume) }
    }

    /// Reads volumes, groups and what each room is playing (while a speaker list shows). One at a
    /// time: a reading asked for while one is under way, or within `readingFreshness` of the last
    /// one, is skipped (all the lists showing share the readings).
    public func readRooms(now: Date = Date()) async {
        // What's known now still goes out (the music may have started since the last reading).
        guard !isReading else { return changed() }
        if let lastReadAt, now.timeIntervalSince(lastReadAt) < readingFreshness { return changed() }
        lastReadAt = now
        isReading = true
        defer { isReading = false }
        // Which rooms other zones play on, asked while the rooms are read.
        async let asked: Void = refreshClaims()
        await household.readRooms(ourCoordinatorID: ownsRooms ? engine?.target.coordinator.id : nil)
        await asked
        releaseClaimedRooms()
        changed()
        // While a room list shows: other hubs may know an account this one hasn't seen.
        Task { await askPeersIfMissing() }
    }

    // MARK: Discovery

    /// Discovery has news: rooms may have new addresses, accounts may have turned up. New
    /// addresses go into the output (and an engine that hasn't played yet); the session is
    /// rebuilt (`onOutputChanged`) if the account it streams from changed, unless it's playing
    /// right now.
    public func householdRefreshed() {
        defer {
            releaseClaimedRooms()
            changed()
            Task { await askPeersIfMissing() }
            Task {
                await refreshClaims()
                releaseClaimedRooms()
            }
        }
        // Every account discovery shows is remembered for this household, so it stays usable
        // once the queue (or favourite, or song playing) that showed it is gone.
        if let id = household.householdID {
            memory.lastHousehold = id
            if !household.accounts.isEmpty { memory.remember(household.accounts, in: id) }
        }
        if let output {
            var target = output.target
            target.coordinator.host = household.player(target.coordinator.id)?.host ?? target.coordinator.host
            for index in target.joining.indices {
                target.joining[index].host = household.player(target.joining[index].id)?.host ?? target.joining[index].host
            }
            // The fallback for a first play that can't read the layout (it's read live then),
            // kept current rather than as saved. Not once the engine has grouped: it owns that.
            if engine?.isGrouped != true, let group = household.group(containing: target.coordinator.id) {
                target.leavesGroup = group.coordinatorID != target.coordinator.id
            }
            if target != output.target {
                self.output = SonosOutput(target: target)
                if let engine, !engine.isGrouped { engine.retarget(target) }
            }
        }
        rebuildIfAccountChanged()
    }

    /// The account the session should stream from changed (found, learned, or refused): the
    /// session is rebuilt (`onOutputChanged`), unless it's playing right now.
    private func rebuildIfAccountChanged() {
        let current = engine.map { SonosPlayback(target: $0.target, reference: $0.reference) }
        guard current != playback, session?.isPlaying != true else { return }
        onOutputChanged?()
    }

    /// Sonos refused the first song from `reference`'s account (`SonosEngine.onAccountRejected`):
    /// the account is forgotten (here, in what discovery holds, and as the choice). With no other
    /// account known for the service, the service counts as not linked in this household: no
    /// account is assumed, and the "Add … in the Sonos app" note shows (`setup().hasAccount`).
    func accountRejected(_ reference: SonosTrackReference) {
        let sid = serviceID(reference.service)
        let id = SonosAccount(serviceID: sid, serialNumber: reference.accountSerial).id
        household.forgetAccount(id)
        if let key = householdKey { memory.forget(id, in: key) }
        if chosenAccounts[reference.service.rawValue]?.id == id { chosenAccounts[reference.service.rawValue] = nil }
        if knownAccounts(for: reference.service).isEmpty { unlinked.insert(Self.unlinkedKey(householdKey, sid)) }
        engineLog?("Sonos refused account \(id): forgotten\(isUnlinked(reference.service) ? "; \(reference.service.sonosName) isn't linked here" : "")")
        changed()
        // After the engine's play has finished failing, not under it.
        Task { self.rebuildIfAccountChanged() }
    }

    // MARK: Other hubs

    /// No account known for the zone's service: asks the other hubs on the network
    /// (`peers`) what they know for this household, and remembers what they say. Only with
    /// rooms listed and the household's id read; the same hubs at most every `askInterval`
    /// (a new zone at once); each answers within the exchange's timeout or adds nothing.
    func askPeersIfMissing(now: Date = Date()) async {
        guard let service, let householdID = household.householdID, !household.rooms.isEmpty,
              knownAccounts(for: service).isEmpty, !isAsking else { return }
        let zones = peers()
        guard !zones.isEmpty else { return }
        let key = "\(householdID)|\(service.rawValue)|" + zones.map(\.address).sorted().joined(separator: ",")
        if let lastAsked, lastAsked.key == key, now.timeIntervalSince(lastAsked.at) < Self.askInterval { return }
        lastAsked = (key, now)
        isAsking = true
        defer { isAsking = false }
        let before = Set(memory.accounts(in: householdID).map(\.id))
        for answer in await exchange.ask(zones, household: householdID) {
            memory.remember(answer.accounts.map(\.account), in: householdID, learnedFrom: answer.zone.name)
        }
        let learned = memory.accounts(in: householdID).filter { !before.contains($0.id) }
        guard !learned.isEmpty else { return }
        engineLog?("learned from other hubs: \(learned.map(\.id).joined(separator: ", "))")
        changed()
        rebuildIfAccountChanged()
    }

    /// Asks the other zones (`peers`) which rooms they play on (`GET /api/zone`), at most every
    /// `claimInterval` (`idleClaimInterval` once the zone is set up), all at once, each within
    /// the exchange's timeout. A zone that misses an answer keeps its last claim for
    /// `claimLifetime`; a zone no longer listed loses it.
    func refreshClaims(now: Date = Date()) async {
        guard !isAskingClaims else { return }
        let interval = isSettingUp() ? Self.claimInterval : Self.idleClaimInterval
        if let lastClaimsAsked, now.timeIntervalSince(lastClaimsAsked) < interval { return }
        lastClaimsAsked = now
        let zones = peers()
        let listed = Set(zones.map(\.address))
        claimAnswers = claimAnswers.filter { listed.contains($0.key) && now.timeIntervalSince($0.value.at) < Self.claimLifetime }
        if !zones.isEmpty {
            isAskingClaims = true
            for answer in await claimExchange.ask(zones) {
                // The zone's name as it says it now, else as announced.
                let claim = answer.claim.map { claim in
                    var claim = claim
                    if claim.zone.isEmpty { claim.zone = answer.zone.name }
                    return claim
                }
                claimAnswers[answer.zone.address] = (claim, now)
            }
            isAskingClaims = false
        }
        claims = claimAnswers.sorted { $0.key < $1.key }.compactMap(\.value.claim)
    }

    // MARK: What a host's phone sees

    /// The rooms and choices for hosts' snapshots; nil without a service Sonos can stream.
    public func setup() -> SonosSetup? {
        guard let service else { return nil }
        let live = isLive
        let rooms = household.rooms.map { player -> SonosSetup.Room in
            let reading = household.readings[player.id]
            let status = status(of: player)
            let inUse = claim(on: player.id).map { SonosSetup.InUse(zone: $0.zone, service: $0.service, together: takenTogether(with: player.id)) }
            return SonosSetup.Room(id: player.id, name: player.roomName, model: player.displayName, ticked: isTicked(player.id),
                                   status: status.text, state: status.kind, canTick: status.canTick,
                                   volume: reading?.responding == false ? nil : reading?.volume,
                                   inUse: status.isInUse ? inUse : nil)
        }
        let found = accounts
        let chosen = output?.roomIDs ?? []
        let ready = playback != nil && chosen.contains { id in household.rooms.contains { $0.id == id } }
        return SonosSetup(
            service: service.sonosName, searched: household.hasSearched, rooms: rooms, chosen: chosen, chosenName: output?.target.name,
            hasAccount: account != nil,
            accounts: found.enumerated().map { SonosSetup.Account(id: $0.element.id, label: $0.element.label(index: $0.offset)) },
            accountID: account?.id, active: engine != nil, live: live, ready: ready
        )
    }
}

/// A host's phone, through the hub's web server.
extension SonosOutputController: SonosOutputHandler {
    public func setSonosRoom(_ roomID: String, on: Bool) -> Bool {
        if on {
            guard !isTicked(roomID), let player = household.player(roomID), account != nil,
                  household.readings[player.id]?.responding != false, !joining.contains(roomID) else { return false }
            // Another zone's: "Use" asks first (`useSonosRooms`).
            guard claim(on: roomID) == nil else { return false }
            // Moving the music onto Sonos rebuilds the session: setup only.
            guard output != nil || canChangeOutput() else { return false }
            add(roomID)
            return true
        }
        guard let output, output.roomIDs.contains(roomID) else { return false }
        // The last room: back to the hub's own output, which only setup offers.
        guard output.roomIDs.count > 1 || canChangeOutput() else { return false }
        remove(roomID)
        return true
    }

    public func useSonosRooms(_ roomIDs: [String]) -> Bool {
        let ids = roomIDs.filter { !isTicked($0) }
        guard !ids.isEmpty, account != nil else { return false }
        for id in ids {
            guard household.player(id) != nil, household.readings[id]?.responding != false, !joining.contains(id) else { return false }
        }
        // Moving the music onto Sonos rebuilds the session: setup only, as a tick.
        guard output != nil || canChangeOutput() else { return false }
        takeOver(ids)
        return true
    }

    public func sonosClaim() -> SonosZoneClaim? {
        guard let engine, let service, !engine.hasLostControl else { return nil }
        return SonosZoneClaim(zone: session?.zoneName ?? "", service: service.sonosName, household: household.householdID,
                              rooms: engine.target.rooms.map(\.id))
    }

    public func leaveSonos() -> Bool {
        guard canChangeOutput() else { return false }
        leave()
        return true
    }

    public func chooseSonosAccount(_ accountID: String) -> Bool {
        guard canChangeOutput(), let pick = accounts.first(where: { $0.id == accountID }) else { return false }
        chooseAccount(pick)
        return true
    }

    public func setSonosVolume(_ volume: Int, room roomID: String?) {
        if let roomID { setVolume(volume, room: roomID) } else { setGroupVolume(volume) }
    }

    public func beginSonosGroupVolume() {
        beginGroupVolume()
    }

    public func readSonosRooms() async {
        await readRooms()
    }

    /// What this hub knows of `id`'s accounts, live and remembered (never the assumed one).
    public func sonosAccounts(household id: String) -> [SonosSharedAccount] {
        let live = household.householdID == id ? household.accounts : []
        return SonosParse.merge([live, memory.accounts(in: id)]).map(SonosSharedAccount.init)
    }
}
