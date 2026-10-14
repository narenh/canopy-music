import Foundation

/// A hub's Sonos rooms as a host's phone shows them: where an Apple TV zone's music plays (its
/// setup page), and the party page's volume row and Devices while the zone plays through Sonos.
/// Only in hosts' snapshots (`PartySnapshot.sonos`), as `musicAccess` and `spotify` are. The
/// wording is the iPad's (`SonosRoomStatus`), worked out on the hub so both say the same.
public struct SonosSetup: Codable, Equatable, Sendable {
    public struct Room: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// The model's short name ("Beam"), for its icon.
        public var model: String
        public var ticked: Bool
        /// The room's second line, as the iPad's lists say it.
        public var status: String
        /// What the line means, for how it's drawn: "ours", "joining", "idle", "busy" (orange)
        /// or "notResponding" (dimmed).
        public var state: String
        public var canTick: Bool
        /// 0–100, once read; nil for a room that doesn't answer.
        public var volume: Int?

        public init(id: String, name: String, model: String, ticked: Bool, status: String, state: String, canTick: Bool, volume: Int? = nil) {
            self.id = id
            self.name = name
            self.model = model
            self.ticked = ticked
            self.status = status
            self.state = state
            self.canTick = canTick
            self.volume = volume
        }
    }

    public struct Account: Codable, Equatable, Sendable {
        public var id: String
        /// "Account 1, played “Ribs”": Sonos names no accounts.
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// The service Sonos streams, as the Sonos app names it ("Apple Music", "Spotify").
    public var service: String
    /// Discovery has had time to find the household (or found nothing).
    public var searched: Bool
    /// The household's rooms, by name.
    public var rooms: [SonosSetup.Room]
    /// The rooms chosen as the output, the first leading; empty when the music plays elsewhere
    /// (the hub itself, or a Spotify Connect device).
    public var chosen: [String]
    /// The chosen rooms by name ("Bedroom + Move"), for when they aren't found now.
    public var chosenName: String?
    /// There's an account to stream from: one seen (here, remembered, or from another hub), or
    /// the assumed one. False only once Sonos has refused the service: "Add … in the Sonos app".
    public var hasAccount: Bool
    /// Every account found for the service; "Whose account plays" when there's more than one.
    public var accounts: [SonosSetup.Account]
    public var accountID: String?
    /// The zone's session plays through these rooms (its engine is Sonos's).
    public var active: Bool
    /// The music has started there: ticked rooms are playing it, and join and leave live.
    public var live: Bool
    /// The output can play: rooms chosen, at least one of them found, and an account to stream from.
    public var ready: Bool

    public init(service: String, searched: Bool, rooms: [SonosSetup.Room], chosen: [String], chosenName: String? = nil, hasAccount: Bool,
                accounts: [SonosSetup.Account] = [], accountID: String? = nil, active: Bool = false, live: Bool = false, ready: Bool = false) {
        self.service = service
        self.searched = searched
        self.rooms = rooms
        self.chosen = chosen
        self.chosenName = chosenName
        self.hasAccount = hasAccount
        self.accounts = accounts
        self.accountID = accountID
        self.active = active
        self.live = live
        self.ready = ready
    }
}

/// What a hub does for a host's phone about its Sonos rooms (the app's `SonosOutputController`).
/// Each answers whether it could.
@MainActor
public protocol SonosOutputHandler: AnyObject, Sendable {
    /// Ticks (`on`) or unticks a room. Before the music has started this only changes the choice
    /// (unticking the last room goes back to the hub's own output); once it plays, the room
    /// joins or leaves the group without the song restarting, and the last room stays.
    func setSonosRoom(_ roomID: String, on: Bool) -> Bool
    /// Back to the hub's own output (the Apple TV, or the Spotify Connect device). Setup only.
    func leaveSonos() -> Bool
    /// "Whose account plays". Setup only.
    func chooseSonosAccount(_ accountID: String) -> Bool
    /// One room's volume, or (`roomID` nil) the group's, each room in proportion.
    func setSonosVolume(_ volume: Int, room roomID: String?)
    /// Before the group's volume moves: Sonos remembers each room's, so the balance is kept.
    func beginSonosGroupVolume()
    /// Reads the rooms again (volumes, groups, what each plays); snapshots follow.
    func readSonosRooms() async
    /// The linked accounts this hub knows for a Sonos household (`GET /api/sonos/accounts`), for
    /// another hub that hasn't seen them.
    func sonosAccounts(household: String) -> [SonosSharedAccount]
}

/// A linked account as one hub tells another (`GET /api/sonos/accounts?household=<id>`): only
/// what any Sonos queue on the network shows anyway, the service id and the account's serial,
/// and a song it played to tell accounts apart. No token.
public struct SonosSharedAccount: Codable, Equatable, Sendable {
    public var serviceID: Int
    public var serialNumber: Int
    /// A song title it played ("Account 1, played “Ribs”"), if one was seen.
    public var label: String?

    public init(serviceID: Int, serialNumber: Int, label: String? = nil) {
        self.serviceID = serviceID
        self.serialNumber = serialNumber
        self.label = label
    }

    public init(_ account: SonosAccount) {
        self.init(serviceID: account.serviceID, serialNumber: account.serialNumber, label: account.example)
    }

    public var account: SonosAccount { SonosAccount(serviceID: serviceID, serialNumber: serialNumber, example: label) }
}

public extension SonosAccount {
    /// How "Whose account plays" names it: Sonos names no accounts, so each is told apart by a
    /// song it played ("Account 1, played “Ribs”").
    func label(index: Int) -> String {
        guard let example else { return "Account \(index + 1)" }
        return "Account \(index + 1), played “\(example)”"
    }
}

public extension SonosRoomStatus {
    /// For a host's phone (`SonosSetup.Room.state`).
    var kind: String {
        switch self {
        case .ours: "ours"
        case .joining: "joining"
        case .idle: "idle"
        case .busy: "busy"
        case .notResponding: "notResponding"
        }
    }
}
