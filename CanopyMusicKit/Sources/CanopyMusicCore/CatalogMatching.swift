import Foundation

/// Finds the catalog song for a library track that doesn't say which one it is (iTunes Match and
/// uploaded copies come with no catalog id). Only accepts a search result that is clearly the same
/// recording: same title, artist and album, and about the same length. A live version, a remaster
/// or the same song on another album is a different recording, so it's left out.
public enum CatalogMatching {
    /// How far apart the lengths can be, in seconds, when both are known.
    public static let durationTolerance: TimeInterval = 3

    /// Whether `candidate` (a catalog song) is the same recording as `wanted` (a library track).
    public static func accepts(_ candidate: QueueTrack, for wanted: QueueTrack) -> Bool {
        guard normalized(candidate.title) == normalized(wanted.title),
              normalized(candidate.artist) == normalized(wanted.artist),
              normalized(candidate.album) == normalized(wanted.album) else { return false }
        if let a = candidate.duration, let b = wanted.duration, abs(a - b) > durationTolerance { return false }
        return true
    }

    /// The acceptable candidate closest in length (the earliest on a tie), or nil.
    public static func bestMatch(among candidates: [QueueTrack], for wanted: QueueTrack) -> QueueTrack? {
        let accepted = candidates.enumerated().filter { accepts($0.element, for: wanted) }
        func gap(_ track: QueueTrack) -> TimeInterval {
            guard let a = track.duration, let b = wanted.duration else { return .infinity }
            return abs(a - b)
        }
        return accepted.min { (gap($0.element), $0.offset) < (gap($1.element), $1.offset) }?.element
    }

    /// What to search the catalog for.
    public static func searchTerm(for wanted: QueueTrack) -> String {
        "\(wanted.title) \(wanted.artist)"
    }

    /// Lowercased words without accents or punctuation, single-spaced, "&" read as "and":
    /// "Prologue:  One Ring To Rule Them All" → "prologue one ring to rule them all".
    /// Text that is nothing but punctuation is kept as it is (just lowercased) so it still has to match.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.isEmpty ? folded.trimmingCharacters(in: .whitespacesAndNewlines) : words.joined(separator: " ")
    }
}

/// Remembers, across launches, which catalog song each unlabelled library track turned out to be,
/// so a playlist's second load needs no searches. Misses are remembered for a day so tracks that
/// aren't on Apple Music don't search on every load, but get another chance later.
public actor CatalogMatchMemory {
    public enum Recall: Equatable, Sendable {
        case match(String)
        case recentMiss
        case unknown
    }

    private struct Stored: Codable {
        var matches: [String: String] = [:]
        var misses: [String: Date] = [:]
    }

    public static let missLifetime: TimeInterval = 24 * 60 * 60

    private let url: URL?
    private let now: @Sendable () -> Date
    private var stored: Stored

    /// Kept in Application Support/catalog-matches.json; in Caches on Apple TV, which doesn't let
    /// apps write Application Support.
    public static let shared = CatalogMatchMemory(
        url: CatalogMatchMemory.directory.appending(path: "catalog-matches.json")
    )

    private static var directory: URL {
        #if os(tvOS)
        URL.cachesDirectory
        #else
        URL.applicationSupportDirectory
        #endif
    }

    /// `url` nil keeps everything in memory only.
    public init(url: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
        stored = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public func recall(_ libraryID: String) -> Recall {
        if let catalogID = stored.matches[libraryID] { return .match(catalogID) }
        if let date = stored.misses[libraryID], now().timeIntervalSince(date) < Self.missLifetime { return .recentMiss }
        return .unknown
    }

    public func remember(_ catalogID: String?, for libraryID: String) {
        if let catalogID {
            stored.matches[libraryID] = catalogID
            stored.misses[libraryID] = nil
        } else {
            stored.matches[libraryID] = nil
            stored.misses[libraryID] = now()
        }
    }

    /// Drops what's known about a track, e.g. when its remembered catalog song has disappeared.
    public func forget(_ libraryID: String) {
        stored.matches[libraryID] = nil
        stored.misses[libraryID] = nil
    }

    public func forgetEverything() {
        stored = Stored()
    }

    /// Writes to disk (call once after a batch of changes). Expired misses are dropped.
    public func save() {
        guard let url else { return }
        let cutoff = now().addingTimeInterval(-Self.missLifetime)
        stored.misses = stored.misses.filter { $0.value > cutoff }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("[match] couldn't save \(url.lastPathComponent): \(error)")
            #endif
        }
    }
}

/// How loading a library playlist went: how each track was mapped to a catalog song, and which
/// couldn't be (they're left out of the loaded playlist).
public struct PlaylistLoadReport: Sendable, Equatable {
    public var playlistID: String
    /// Tracks in the library playlist.
    public var total = 0
    /// Tracks that came with their catalog song attached.
    public var withCatalogSong = 0
    /// Tracks that came with a catalog id only.
    public var withCatalogIDOnly = 0
    /// Tracks with neither (iTunes Match / uploaded copies), which have to be found by searching.
    public var unlabelled = 0
    /// Unlabelled tracks found from a remembered earlier search.
    public var matchedFromMemory = 0
    /// Unlabelled tracks found by searching this time.
    public var matchedBySearch = 0
    /// Unlabelled tracks skipped because a search within the last day found nothing.
    public var recentlyUnmatched = 0
    /// Catalog searches run (one per track looked up, however many tries it took).
    public var searches = 0
    /// Requests made for those searches, including retries.
    public var searchAttempts = 0
    /// Retries after a search errored.
    public var searchRetries = 0
    /// Searches that found their song after at least one error.
    public var resolvedAfterRetry = 0
    /// Searches that errored on every try (not remembered, so they're tried again next load).
    public var searchesFailed = 0
    /// Each error a search hit, described by status/code/domain.
    public var searchErrors: [String] = []
    /// How many searches could run at once by the end of the load (lowered after errors).
    public var searchConcurrency = 0
    /// Tracks that couldn't be loaded, as they appear in the library (id is the library id).
    public var skipped: [QueueTrack] = []
    /// Songs actually loaded.
    public var loaded = 0

    public var skippedCount: Int { skipped.count }

    public init(playlistID: String) {
        self.playlistID = playlistID
    }
}

/// The latest `PlaylistLoadReport` per playlist, and the very latest.
public actor PlaylistLoadReports {
    public private(set) var last: PlaylistLoadReport?
    private var byPlaylist: [String: PlaylistLoadReport] = [:]

    public init() {}

    public func record(_ report: PlaylistLoadReport) {
        last = report
        byPlaylist[report.playlistID] = report
    }

    public func report(for playlistID: String) -> PlaylistLoadReport? {
        byPlaylist[playlistID]
    }
}
