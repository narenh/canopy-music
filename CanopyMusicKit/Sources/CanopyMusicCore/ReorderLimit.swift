import Foundation

/// The host's cap on guests' reordering ("Limit reorders", under "Reorder from phones"). Each
/// person, by client ID, starts with `allowance` reorders and gets one back every
/// `refillMinutes`, up to `allowance` again. Hosts and displays aren't limited. One drag is one
/// reorder however far the song goes, except moving your own song further down, which is free
/// (the app doesn't say so). The hub enforces it (`PartySession.move(_:after:asClient:)`); the
/// web page only reflects it, from the same numbers in snapshots.
public struct ReorderLimit: Codable, Equatable, Sendable {
    /// Off by default, so nothing changes until a host turns it on. The other two are kept while
    /// it's off, so turning it on again brings back the host's last choice.
    public var isOn: Bool
    /// The "Initial balance": how many reorders each person starts with (`allowances`).
    public var allowance: Int
    /// Minutes between refills (`refillChoices`); 0 is never, a fixed number for the whole party.
    public var refillMinutes: Int

    public init(isOn: Bool = false, allowance: Int = 3, refillMinutes: Int = 15) {
        self.isOn = isOn
        self.allowance = allowance
        self.refillMinutes = refillMinutes
    }

    /// Three: one is usually all a guest needs (to pull their own song up); three lets them fix
    /// a mistake or bump a friend's song without one person reshuffling the whole queue. Every
    /// 15 minutes is about four songs: someone who's spent theirs gets one back within a few,
    /// but nobody can drag on every song change.
    public static let standard = ReorderLimit()
    public static let allowances = 1...10
    /// What the Refill picker offers, in order; 0 is never.
    public static let refillChoices = [5, 10, 15, 30, 0]

    /// Within the ranges the settings offer, whatever a page sent.
    public var validated: ReorderLimit {
        var limit = self
        limit.allowance = min(max(allowance, Self.allowances.lowerBound), Self.allowances.upperBound)
        if !Self.refillChoices.contains(refillMinutes) { limit.refillMinutes = Self.standard.refillMinutes }
        return limit
    }

    var refillInterval: TimeInterval? { refillMinutes > 0 ? TimeInterval(refillMinutes) * 60 : nil }

    // MARK: Balances

    /// `spend` with the refills due by `now` taken off, and never more spent than the allowance
    /// (a host who lowers it doesn't leave anyone waiting through refills they can't use).
    public func settled(_ spend: ReorderSpend, at now: Date) -> ReorderSpend {
        var settled = spend
        settled.spent = min(spend.spent, allowance)
        guard let interval = refillInterval, settled.spent > 0 else { return settled }
        let refills = Int((now.timeIntervalSince(spend.since) / interval).rounded(.down))
        guard refills > 0 else { return settled }
        settled.spent = max(0, settled.spent - refills)
        settled.since = spend.since.addingTimeInterval(TimeInterval(refills) * interval)
        return settled
    }

    /// How many reorders someone with `spend` has left at `now` (nil: they haven't spent any).
    public func remaining(_ spend: ReorderSpend?, at now: Date) -> Int {
        guard let spend else { return allowance }
        return allowance - settled(spend, at: now).spent
    }

    /// When the next one comes back; nil when the balance is full, or refills are off.
    public func nextRefill(_ spend: ReorderSpend?, at now: Date) -> Date? {
        guard let spend, let interval = refillInterval else { return nil }
        let settled = settled(spend, at: now)
        return settled.spent > 0 ? settled.since.addingTimeInterval(interval) : nil
    }

    /// `spend` with one more reorder spent at `now`, or nil when there's none left. The refill
    /// clock starts with the first one spent from a full balance, so it's "another every 15
    /// minutes" from then, not from whenever the party started.
    public func spending(_ spend: ReorderSpend?, at now: Date) -> ReorderSpend? {
        var next = spend.map { settled($0, at: now) } ?? ReorderSpend(spent: 0, since: now)
        guard next.spent < allowance else { return nil }
        if next.spent == 0 { next.since = now }
        next.spent += 1
        return next
    }

    // MARK: Copy

    /// What the Refill picker shows for `minutes`.
    public static func refillLabel(_ minutes: Int) -> String {
        minutes > 0 ? "Every \(minutes) min" : "Never"
    }

    /// The settings footer, e.g. "Each person can reorder 3 times and gets another every 15
    /// minutes, up to 3. Hosts and displays aren't limited." (the web page's `reorderLimitNote`
    /// says the same).
    public var summary: String {
        let times = allowance == 1 ? "once" : "\(allowance) times"
        let rule = if refillMinutes <= 0 {
            "Each person can reorder \(times) for the whole party."
        } else if allowance == 1 {
            // "…gets another every 15 minutes, up to 1" says it twice.
            "Each person can reorder once every \(refillMinutes) minutes."
        } else {
            "Each person can reorder \(times) and gets another every \(refillMinutes) minutes, up to \(allowance)."
        }
        return "\(rule) Hosts and displays aren't limited."
    }

    // MARK: Saving

    /// Hubs keep it under one name (the iPad and Apple TV alike), like their other settings.
    static let defaultsKey = "reorderLimit"

    /// The saved setting, or the standard one.
    public init(defaults: UserDefaults) {
        let saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(ReorderLimit.self, from: $0) }
        self = saved?.validated ?? .standard
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// One person's reorders spent: `spent` of them, with one back every refill interval counted
/// from `since`. Only the hub keeps these (for the party, not saved); snapshots carry them so a
/// guest's page can show its own balance and countdown.
public struct ReorderSpend: Codable, Equatable, Sendable {
    public var spent: Int
    public var since: Date

    public init(spent: Int, since: Date) {
        self.spent = spent
        self.since = since
    }
}
