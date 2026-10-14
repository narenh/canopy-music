import CanopyMusicCore
import Foundation

/// A linked account a hub has seen, and when: discovery (favourites, a queue, what's playing) or
/// another hub that saw it (`learnedFrom`).
public struct SonosKnownAccount: Codable, Equatable, Sendable {
    public var account: SonosAccount
    /// The last time discovery here (or the hub it was learned from) showed it.
    public var lastSeen: Date
    /// The zone it was learned from (`GET /api/sonos/accounts`); nil once seen on the household here.
    public var learnedFrom: String?

    public init(account: SonosAccount, lastSeen: Date, learnedFrom: String? = nil) {
        self.account = account
        self.lastSeen = lastSeen
        self.learnedFrom = learnedFrom
    }
}

/// Every linked account each Sonos household has shown this hub, by household id (`Sonos_…`),
/// kept across launches (`SonosOutputController.knownAccountsKey`). S2 firmware lists no linked
/// accounts: they show only in items played or saved (a queue, favourites, what's playing), and
/// the queue that showed one is replaced as soon as anything else plays. Remembered, an account
/// stays usable after that, and after a relaunch. Dropped only when Sonos refuses to play from it.
public struct SonosAccountMemory: Codable, Equatable, Sendable {
    public var households: [String: [SonosKnownAccount]] = [:]
    /// The household this hub last read, for the accounts at launch before discovery has read it again.
    public var lastHousehold: String?

    public init() {}

    public func accounts(in household: String?) -> [SonosAccount] {
        household.flatMap { households[$0] }?.map(\.account) ?? []
    }

    /// Notes `accounts` as seen in `household` now: new ones are added, known ones get the newer
    /// reading's details (a token, an example) and time. `learnedFrom` nil: seen here; a zone's
    /// name: told by that hub, which never replaces what this hub saw itself.
    public mutating func remember(_ accounts: [SonosAccount], in household: String, at now: Date = Date(), learnedFrom: String? = nil) {
        var known = households[household] ?? []
        for account in accounts {
            guard let index = known.firstIndex(where: { $0.account.id == account.id }) else {
                known.append(SonosKnownAccount(account: account, lastSeen: now, learnedFrom: learnedFrom))
                continue
            }
            if learnedFrom == nil {
                var merged = account
                if merged.token == nil { merged.token = known[index].account.token }
                if merged.example == nil { merged.example = known[index].account.example; merged.seenIn = known[index].account.seenIn }
                known[index] = SonosKnownAccount(account: merged, lastSeen: now)
            } else if known[index].learnedFrom != nil {
                known[index].lastSeen = now
                if known[index].account.example == nil { known[index].account.example = account.example }
            }
        }
        households[household] = known.sorted { ($0.account.serviceID, $0.account.serialNumber) < ($1.account.serviceID, $1.account.serialNumber) }
    }

    /// Sonos refused the account: forgotten in that household.
    public mutating func forget(_ accountID: String, in household: String) {
        households[household]?.removeAll { $0.account.id == accountID }
    }
}

/// Asks other hubs on the network (`ZoneBrowser`'s zones) for the accounts they know in this
/// household (`GET /api/sonos/accounts?household=<id>`), all at once, each with a short timeout.
/// A zone that doesn't answer, or answers anything but a list, adds nothing.
public struct SonosAccountExchange: Sendable {
    public let timeout: Duration
    private let fetch: ZoneProbe.Fetch

    /// `fetch` replaces the network (tests); by default an ephemeral `URLSession`.
    public init(timeout: Duration = .seconds(2), fetch: ZoneProbe.Fetch? = nil) {
        self.timeout = timeout
        if let fetch {
            self.fetch = fetch
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Double(timeout.components.seconds) + 1
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config)
            self.fetch = { url in
                let (data, response) = try await session.data(from: url)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    public static func url(for zone: ZoneListing, household: String) -> URL? {
        guard let base = zone.baseURL, var components = URLComponents(url: base.appending(path: "api/sonos/accounts"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "household", value: household)]
        return components.url
    }

    /// What each zone answered (only zones that did), within about `timeout` in all.
    public func ask(_ zones: [ZoneListing], household: String) async -> [(zone: ZoneListing, accounts: [SonosSharedAccount])] {
        await withTaskGroup(of: (ZoneListing, [SonosSharedAccount])?.self) { group in
            for zone in zones {
                guard let url = Self.url(for: zone, household: household) else { continue }
                group.addTask { await self.answer(url, zone: zone) }
            }
            var answers: [(zone: ZoneListing, accounts: [SonosSharedAccount])] = []
            for await answer in group {
                if let answer, !answer.1.isEmpty { answers.append((answer.0, answer.1)) }
            }
            return answers
        }
    }

    private func answer(_ url: URL, zone: ZoneListing) async -> (ZoneListing, [SonosSharedAccount])? {
        await withTaskGroup(of: (ZoneListing, [SonosSharedAccount])?.self) { group in
            group.addTask {
                guard let (data, status) = try? await fetch(url), status == 200,
                      let accounts = try? JSONDecoder.api.decode([SonosSharedAccount].self, from: data) else { return nil }
                return (zone, accounts)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
