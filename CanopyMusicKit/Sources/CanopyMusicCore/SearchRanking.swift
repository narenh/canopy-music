import Foundation

/// Puts the results that match what was typed first. Catalog services rank by popularity, so an
/// exact match for an obscure song in your own library can land below popular near-misses.
public enum SearchRanking {
    /// In order: titles exactly as typed; then songs where every typed word starts a word of the
    /// title, artist or album (your library first); then the rest, each group in its given order.
    public static func rank(_ tracks: [QueueTrack], for term: String, library: Set<String> = []) -> [QueueTrack] {
        let query = words(term)
        guard !query.isEmpty else { return tracks }
        func tier(_ track: QueueTrack) -> Int {
            if words(track.title) == query { return 0 }
            let haystack = words("\(track.title) \(track.artist) \(track.album)")
            guard query.allSatisfy({ word in haystack.contains { $0.hasPrefix(word) } }) else { return 3 }
            return library.contains(track.id) ? 1 : 2
        }
        // Stable: sort by (tier, original position).
        return tracks.enumerated()
            .map { (tier: tier($0.element), index: $0.offset, track: $0.element) }
            .sorted { ($0.tier, $0.index) < ($1.tier, $1.index) }
            .map(\.track)
    }

    /// Lowercased words without accents or punctuation: "Beyoncé's" → ["beyonces"].
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
