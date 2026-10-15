import Foundation

/// One song, once, in a host's search of the library and the catalog together. A library copy of
/// a catalog song has that song's catalog id as its `id` (`QueueTrack.libraryCopy`), so a copy
/// and the catalog result for it share an id, as do two library copies of the same song (an
/// album that's in the library twice: the matched copy and the Apple Music one added later).
/// Each id keeps its best result, where its first result was:
/// - a library copy over the catalog's, so the host's own art and titles win;
/// - among library copies, a matched or uploaded one over a copy added from Apple Music;
/// - then one with its own artwork over one without.
/// Songs only in the library (`isLibraryOnly`) have their library id as `id`, so they collapse
/// only with themselves.
public enum LibraryDuplicates {
    public enum Result: Sendable {
        case catalog(QueueTrack)
        case library(LibraryResult)

        var track: QueueTrack {
            switch self {
            case .catalog(let track): track
            case .library(let result): result.track
            }
        }
    }

    public struct LibraryResult: Sendable {
        /// `libraryID` set; `id` the catalog id, or the library id when it has none.
        public var track: QueueTrack
        /// Added to the library from Apple Music (it came with its catalog song or id), rather
        /// than matched (iTunes Match) or uploaded.
        public var isAppleMusicCopy: Bool
        /// The library has its own artwork for it.
        public var hasArtwork: Bool

        public init(track: QueueTrack, isAppleMusicCopy: Bool, hasArtwork: Bool) {
            self.track = track
            self.isAppleMusicCopy = isAppleMusicCopy
            self.hasArtwork = hasArtwork
        }
    }

    /// `results` with one per `id`, in the order each id first appears.
    public static func collapse(_ results: [Result]) -> [QueueTrack] {
        var order: [String] = []
        var best: [String: Result] = [:]
        for result in results {
            let id = result.track.id
            guard let kept = best[id] else {
                order.append(id)
                best[id] = result
                continue
            }
            if rank(result) > rank(kept) { best[id] = result }
        }
        return order.compactMap { best[$0]?.track }
    }

    /// Higher is preferred; equal keeps the first.
    private static func rank(_ result: Result) -> Int {
        switch result {
        case .catalog: 0
        case .library(let copy): 1 + (copy.isAppleMusicCopy ? 0 : 2) + (copy.hasArtwork ? 1 : 0)
        }
    }
}
