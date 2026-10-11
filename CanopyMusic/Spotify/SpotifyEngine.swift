import CanopyCore
import Foundation

/// Controls playback on a Spotify Connect device (the iPad's Spotify app, an Apple TV…) through
/// the Web API. Spotify's queue can be added to but not edited, so this engine can't replace a
/// staged track; `PartySession` stages late and shows the next song as locked.
@MainActor
final class SpotifyEngine: PlaybackEngine {
    static let deviceDefaultsKey = "spotifyDeviceID"

    let canReplaceStaged = false
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    private let api: SpotifyAPI
    private var currentURI: String?
    private var stagedURI: String?
    private var pausedByUs = false
    private var reportedEnd = false
    private var lastPlaying: Bool?
    private var poller: Task<Void, Never>?
    /// Skip polling while a command we sent is still settling on Spotify's side.
    private var settleUntil = Date.distantPast
    /// When we last asked Spotify to play a specific track, and whether we've retried it.
    private var playRequestedAt = Date.distantPast
    private var retriedPlay = false

    private var cachedPlaying = false
    private var cachedTime: TimeInterval = 0
    private var cachedAt = Date()

    /// Each poll is one Web API request, so this sets most of the request rate.
    private static let pollInterval: Duration = .seconds(3)

    init(api: SpotifyAPI) {
        self.api = api
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.poll()
            }
        }
    }

    var isPlaying: Bool { cachedPlaying }
    var currentTime: TimeInterval { cachedPlaying ? cachedTime + Date().timeIntervalSince(cachedAt) : cachedTime }

    private var deviceID: String? { UserDefaults.standard.string(forKey: Self.deviceDefaultsKey) }
    private var deviceQuery: [String: String] { deviceID.map { ["device_id": $0] } ?? [:] }

    private func cache(playing: Bool, time: TimeInterval) {
        cachedPlaying = playing
        cachedTime = time
        cachedAt = Date()
    }

    func play(_ track: QueueTrack) async throws {
        struct Body: Encodable { var uris: [String] }
        settleUntil = Date().addingTimeInterval(2)
        stagedURI = nil
        reportedEnd = false
        pausedByUs = false
        do {
            try await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [track.id]))
        } catch SpotifyError.noDevice {
            // The device exists but isn't active yet: transfer to it, then play.
            try await transferToDevice()
            try await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [track.id]))
        }
        currentURI = track.id
        playRequestedAt = Date()
        retriedPlay = false
        cache(playing: true, time: 0)
    }

    func stage(_ track: QueueTrack?) async throws {
        // Spotify can't remove queued items; a nil stage just means nothing new is queued.
        guard let track else { return }
        try await api.send("POST", "/me/player/queue", query: deviceQuery.merging(["uri": track.id]) { $1 })
        stagedURI = track.id
    }

    func resume() async throws {
        pausedByUs = false
        settleUntil = Date().addingTimeInterval(1.5)
        do {
            try await api.send("PUT", "/me/player/play", query: deviceQuery)
        } catch SpotifyError.noDevice {
            do {
                try await transferToDevice()
                try await api.send("PUT", "/me/player/play", query: deviceQuery)
            } catch {
                // Spotify lost the playback state along with the old device: start the current
                // song again on this one where it left off.
                guard let currentURI else { throw error }
                struct Body: Encodable { var uris: [String]; var position_ms: Int }
                try await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [currentURI], position_ms: Int(cachedTime * 1000)))
            }
        }
        cache(playing: true, time: cachedTime)
    }

    func pause() {
        pausedByUs = true
        settleUntil = Date().addingTimeInterval(1.5)
        cache(playing: false, time: currentTime)
        Task { try? await api.send("PUT", "/me/player/pause", query: deviceQuery) }
    }

    func skipToStaged() async throws {
        guard stagedURI != nil else { throw CancellationError() }
        try await api.send("POST", "/me/player/next", query: deviceQuery)
    }

    func restartCurrent() { seek(to: 0) }

    func seek(to time: TimeInterval) {
        settleUntil = Date().addingTimeInterval(1.5)
        cache(playing: cachedPlaying, time: time)
        Task { try? await api.send("PUT", "/me/player/seek", query: deviceQuery.merging(["position_ms": "\(Int(time * 1000))"]) { $1 }) }
    }

    /// Spotify's crossfade is a setting in the Spotify app itself.
    func setCrossfade(enabled: Bool, duration: TimeInterval?) {}

    private func transferToDevice() async throws {
        struct Body: Encodable { var device_ids: [String]; var play: Bool }
        guard let deviceID else { throw SpotifyError.noDevice }
        try await api.send("PUT", "/me/player", body: Body(device_ids: [deviceID], play: false))
        try await Task.sleep(for: .milliseconds(600))
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[spotify-engine] \(message())")
        #endif
    }

    private func poll() async {
        guard api.auth.isSignedIn, currentURI != nil, Date() > settleUntil else { return }
        let state: SpotifyPlayerState
        do {
            guard let fetched = try await api.get("/me/player", as: SpotifyPlayerState.self) else {
                log("poll: no player state (204)")
                return
            }
            state = fetched
        } catch {
            log("poll failed: \(error)")
            return
        }
        guard Date() > settleUntil else { return }
        log("poll: \(state.item?.name ?? "nil") \(state.item?.uri ?? "") playing=\(state.is_playing) t=\((state.progress_ms ?? 0) / 1000) | canopy current=\(currentURI ?? "nil") staged=\(stagedURI ?? "nil")")
        cache(playing: state.is_playing, time: Double(state.progress_ms ?? 0) / 1000)

        if state.is_playing != lastPlaying {
            lastPlaying = state.is_playing
            onEvent?(.statusChanged)
        }

        let uri = state.item?.uri
        // Spotify sometimes ignores a play request (e.g. its app was just waking up). Right
        // after asking for a track, a mismatch means "retry", not "the song ended".
        if uri != currentURI, let expected = currentURI, Date().timeIntervalSince(playRequestedAt) < 10 {
            guard !retriedPlay else { return }
            retriedPlay = true
            log("Spotify is playing \(uri ?? "nothing") instead of \(expected); retrying")
            struct Body: Encodable { var uris: [String] }
            settleUntil = Date().addingTimeInterval(2)
            _ = try? await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [expected]))
            return
        }
        if uri != currentURI {
            let previous = currentURI
            currentURI = uri
            if let uri, uri == stagedURI {
                stagedURI = nil
                reportedEnd = false
                onEvent?(.advancedToStaged)
            } else if previous != nil, !reportedEnd {
                // Spotify moved on to something Canopy didn't stage (autoplay, a stale queue
                // item, or another controller). Hand control back to Canopy's queue.
                reportedEnd = true
                onEvent?(.reachedEnd)
            }
            return
        }

        // Stopped at the end with nothing queued.
        if !state.is_playing, !pausedByUs, !reportedEnd, stagedURI == nil, let item = state.item,
           (state.progress_ms ?? 0) == 0 || Double(state.progress_ms ?? 0) >= Double(item.duration_ms ?? 0) - 1500 {
            reportedEnd = true
            onEvent?(.reachedEnd)
        }
    }
}
