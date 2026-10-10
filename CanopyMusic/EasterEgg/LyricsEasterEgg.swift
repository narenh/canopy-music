import CanopyCore
import Foundation
import Observation

/// One song gets a full-screen lyrics takeover when it plays. Lyrics come from `big-stick.lrc` in
/// the app bundle (hand-corrected, gitignored because the repo is public), falling back to LRCLIB.
@MainActor
@Observable
final class LyricsEasterEgg {
    struct Line: Equatable {
        var time: TimeInterval
        var text: String
    }

    private(set) var lines: [Line]?
    /// The queue item whose takeover was dismissed, so tapping out sticks for that play.
    var dismissedItemID: UUID?

    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private let cacheURL = URL.applicationSupportDirectory.appending(path: "easter-egg.lrc")

    /// LRCLIB record for "Big Stick" by MUNA.
    private static let lrclibID = 33573170

    func matches(_ track: Track) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-easterEggPreview") { return true }
        #endif
        return track.title.lowercased().hasPrefix("big stick") && track.artist.lowercased().contains("muna")
    }

    func loadIfNeeded() async {
        guard lines == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-easterEggPreview") {
            lines = Self.parse(Self.placeholderLRC)
            return
        }
        #endif

        if let bundled = Bundle.main.url(forResource: "big-stick", withExtension: "lrc"),
           let text = try? String(contentsOf: bundled, encoding: .utf8) {
            lines = Self.parse(text)
            return
        }
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8) {
            lines = Self.parse(cached)
            return
        }
        guard let url = URL(string: "https://lrclib.net/api/get/\(Self.lrclibID)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Canopy (https://github.com/narenh/canopy-music)", forHTTPHeaderField: "User-Agent")
        struct Record: Decodable { var syncedLyrics: String? }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let synced = (try? JSONDecoder().decode(Record.self, from: data))?.syncedLyrics,
              !synced.isEmpty else { return }
        try? synced.write(to: cacheURL, atomically: true, encoding: .utf8)
        lines = Self.parse(synced)
    }

    /// Parses LRC: `[mm:ss.xx] text`, possibly several timestamps per line.
    static func parse(_ lrc: String) -> [Line] {
        let stamp = /\[(\d+):(\d+(?:\.\d+)?)\]/
        var result: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let raw = String(raw)
            let stamps = raw.matches(of: stamp)
            guard let last = stamps.last else { continue }
            let text = raw[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in stamps {
                guard let minutes = Double(match.output.1), let seconds = Double(match.output.2) else { continue }
                result.append(Line(time: minutes * 60 + seconds, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    #if DEBUG
    /// Placeholder timings for simulator previews (no real lyrics).
    static let placeholderLRC = """
    [00:00.50] This is the takeover
    [00:03.50] Big chunky words punch in
    [00:06.50] One at a time
    [00:09.00]
    [00:11.00] Tap anywhere to get out
    [00:14.00] And the party carries on
    [00:18.00] Louder now
    [00:21.00] Every word lands on the beat
    [00:25.00] Okay that's enough
    """
    #endif
}
