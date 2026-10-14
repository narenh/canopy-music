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
    /// Rooms on their way into the group (a spinner, "Joining…"), until Sonos has them in it.
    public private(set) var joining: Set<String> = [] {
        didSet { if joining != oldValue { changed() } }
    }
    /// The zone's service as Sonos knows it; nil for no service (and the demo). Set by the app.
    public var service: SonosMusicService? {
        didSet { if service != oldValue { changed() } }
    }

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
    /// For the engines it makes (`[sonos-engine] …` in debug builds).
    @ObservationIgnored public var engineLog: (@MainActor (String) -> Void)?
    /// nil: nothing is kept (a simulated household).
    @ObservationIgnored private let defaults: UserDefaults?
    /// A host's phone asked for a reading while one was under way: it's skipped.
    @ObservationIgnored private var isReading = false

    public static let outputKey = "sonosOutput"
    public static let accountsKey = "sonosAccounts"

    /// `defaults`: where the rooms and accounts are kept (nil keeps nothing, for a simulated household).
    public init(household: SonosHousehold, defaults: UserDefaults? = .standard) {
        self.household = household
        self.defaults = defaults
        output = defaults?.data(forKey: Self.outputKey).flatMap { try? JSONDecoder().decode(SonosOutput.self, from: $0) }
        chosenAccounts = defaults?.data(forKey: Self.accountsKey).flatMap { try? JSONDecoder().decode([String: SonosAccount].self, from: $0) } ?? [:]
    }

    private func changed() {
        onChange?()
    }

    // MARK: What plays

    /// Linked accounts found for the zone's service.
    public var accounts: [SonosAccount] {
        service.map(household.accounts(for:)) ?? []
    }

    /// The account that streams the zone's songs: the one chosen for the service, else the first found.
    public var account: SonosAccount? {
        guard let service else { return nil }
        guard let pick = chosenAccounts[service.rawValue] else { return accounts.first }
        // A newer reading of the same account (its token) wins.
        return accounts.first { $0.id == pick.id } ?? pick
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

    /// An engine for the current output, or nil when the music doesn't play through Sonos.
    public func makeEngine() -> SonosEngine? {
        guard let playback else { return nil }
        let engine = SonosEngine(target: playback.target, reference: playback.reference, transport: household.transport)
        engine.log = engineLog
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
        guard output != nil else { return }
        output = nil
        onOutputChanged?()
    }

    /// A room's row was tapped.
    public func toggle(_ roomID: String) {
        if isTicked(roomID) { remove(roomID) } else { add(roomID) }
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
    /// time: a reading asked for while one is under way is skipped.
    public func readRooms() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        await household.readRooms(ourCoordinatorID: isLive ? engine?.target.coordinator.id : nil)
        changed()
    }

    // MARK: Discovery

    /// Discovery has news: rooms may have new addresses, accounts may have turned up. New
    /// addresses go into the output (and an engine that hasn't played yet); the session is
    /// rebuilt (`onOutputChanged`) if the account it streams from changed, unless it's playing
    /// right now.
    public func householdRefreshed() {
        defer { changed() }
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
        let current = engine.map { SonosPlayback(target: $0.target, reference: $0.reference) }
        guard current != playback, session?.isPlaying != true else { return }
        onOutputChanged?()
    }

    // MARK: What a host's phone sees

    /// The rooms and choices for hosts' snapshots; nil without a service Sonos can stream.
    public func setup() -> SonosSetup? {
        guard let service else { return nil }
        let live = isLive
        let rooms = household.rooms.map { player -> SonosSetup.Room in
            let ticked = isTicked(player.id)
            let reading = household.readings[player.id]
            let status = SonosRoomStatus.of(roomID: player.id, model: player.displayName, ticked: ticked, joining: joining.contains(player.id),
                                            live: live, reading: reading)
            return SonosSetup.Room(id: player.id, name: player.roomName, model: player.displayName, ticked: ticked,
                                   status: status.text, state: status.kind, canTick: status.canTick,
                                   volume: reading?.responding == false ? nil : reading?.volume)
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
}
