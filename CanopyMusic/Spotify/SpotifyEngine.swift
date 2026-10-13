import CanopyMusicCore
import Foundation

/// Controls playback on a Spotify Connect device (the iPad's Spotify app, an Apple TV…) through
/// the Web API. Spotify's player belongs to the account, so this engine follows it rather than
/// drives it (follow mode, docs/multi-device.md): a track it didn't start or stage is reported as
/// foreign (`FollowRules`), never treated as "our song ended" and never played over. Spotify's
/// queue can be added to but not edited, so `PartySession` stages late, confirms the song is in
/// the queue, and shows the next song as locked.
@MainActor
final class SpotifyEngine: FollowingPlaybackEngine {
    static let deviceDefaultsKey = "spotifyDeviceID"

    let canReplaceStaged = false
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    private let api: SpotifyAPI
    /// Our song: the one we started, or the staged one Spotify advanced to.
    private var currentURI: String?
    /// Our song before the last play request; Spotify sometimes stays on it.
    private var previousURI: String?
    private var stagedURI: String?
    /// The foreign track reported as playing, if one is.
    private var foreignURI: String?
    private var pausedByUs = false
    private var reportedEnd = false
    private var lastPlaying: Bool?
    private var poller: Task<Void, Never>?
    /// This engine has started playback. Spotify plays one stream per account, so one that
    /// hasn't must not pause it: what's playing is another zone's (or the Spotify app's), and
    /// dropping an unused session (`PartySession.shutdown`, e.g. joining that zone) pauses.
    private var hasStartedPlayback = false
    /// Skip polling while a command we sent is still settling on Spotify's side.
    private var settleUntil = Date.distantPast
    /// When we last asked Spotify to play a specific track, and whether we've retried it.
    private var playRequestedAt = Date.distantPast
    private var retriedPlay = false

    /// Watching after a relaunch (`attach`): the next reading decides whether the music is still
    /// ours and playing, and a paused player stays paused (no "song ended" from it).
    private var attachedAwaitingFirstReading = false

    private var cachedPlaying = false
    private var cachedTime: TimeInterval = 0
    private var cachedAt = Date()
    /// What Spotify is on as last seen (ours or not), and its length.
    private(set) var playerTrackID: String?
    private(set) var playerDuration: TimeInterval?

    /// Each poll is one Web API request, so this sets most of the request rate.
    private static let pollInterval: Duration = .seconds(3)

    init(api: SpotifyAPI) {
        self.api = api
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                // A dropped engine (a service change) stops polling.
                guard let self else { return }
                await self.poll()
            }
        }
    }

    var isPlaying: Bool { cachedPlaying }
    var currentTime: TimeInterval { cachedPlaying ? cachedTime + Date().timeIntervalSince(cachedAt) : cachedTime }

    private var deviceID: String? { UserDefaults.standard.string(forKey: Self.deviceDefaultsKey) }
    private var deviceQuery: [String: String] { deviceID.map { ["device_id": $0] } ?? [:] }

    /// After a relaunch the music may still be playing on Spotify: watch it, expecting the
    /// restored current song, without sending anything.
    func attach(expecting trackID: String?) {
        guard currentURI == nil, !hasStartedPlayback, let trackID else { return }
        currentURI = trackID
        previousURI = nil
        lastPlaying = nil
        reportedEnd = false
        attachedAwaitingFirstReading = true
        log("attached: expecting \(trackID)")
    }

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
        hasStartedPlayback = true
        do {
            try await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [track.id]))
        } catch SpotifyError.noDevice {
            // The device exists but isn't active yet: transfer to it, then play.
            try await transferToDevice()
            try await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [track.id]))
        }
        previousURI = currentURI
        currentURI = track.id
        foreignURI = nil
        playerTrackID = track.id
        playerDuration = track.duration
        playRequestedAt = Date()
        retriedPlay = false
        cache(playing: true, time: 0)
    }

    func stage(_ track: QueueTrack?) async throws {
        // Spotify can't remove queued items; a nil stage just means we stop expecting ours.
        guard let track else { stagedURI = nil; return }
        if api.isBackingOff { throw SpotifyError.rateLimited(retryAfter: api.secondsUntilRetry) }
        // Expected from now on, even if the request fails: a request that reached Spotify but
        // whose answer didn't reach us still lands, and is then ours when it plays.
        stagedURI = track.id
        try await api.send("POST", "/me/player/queue", query: deviceQuery.merging(["uri": track.id]) { $1 })
    }

    func fetchPlayerQueue() async throws -> [QueueTrack] {
        if api.isBackingOff { throw SpotifyError.rateLimited(retryAfter: api.secondsUntilRetry) }
        guard let reply = try await api.get("/me/player/queue", as: SpotifyQueueReply.self) else { return [] }
        return reply.queue.map(\.queueTrack)
    }

    func skipInPlayer() async throws {
        settleUntil = Date().addingTimeInterval(1.5)
        try await api.send("POST", "/me/player/next", query: deviceQuery)
    }

    func resume() async throws {
        pausedByUs = false
        hasStartedPlayback = true
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
        guard hasStartedPlayback else { return }
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
        // While Spotify has asked us to hold off (a 429's Retry-After), don't read at all.
        guard api.auth.isSignedIn, currentURI != nil, Date() > settleUntil, !api.isBackingOff else { return }
        let state: SpotifyPlayerState?
        do {
            state = try await api.get("/me/player", as: SpotifyPlayerState.self)
        } catch {
            log("poll failed: \(error)")
            return
        }
        guard Date() > settleUntil else { return }
        log("poll: \(state?.item?.name ?? "nil") \(state?.item?.uri ?? "") playing=\(state?.is_playing ?? false) t=\((state?.progress_ms ?? 0) / 1000) | ours=\(currentURI ?? "nil") staged=\(stagedURI ?? "nil") foreign=\(foreignURI ?? "nil")")

        var observation: FollowRules.Observation?
        if let state {
            if attachedAwaitingFirstReading {
                // First reading after a relaunch: if Spotify is still playing our song, it's ours
                // again (and ours to pause later); if it's paused, it stays paused rather than
                // counting as a song that ended.
                attachedAwaitingFirstReading = false
                let ours = state.item?.uri == currentURI
                if ours, state.is_playing { hasStartedPlayback = true }
                pausedByUs = !state.is_playing
                log("attached: Spotify is \(state.is_playing ? "playing" : "paused") on \(ours ? "our song" : state.item?.uri ?? "nothing")")
            }
            let duration = state.item?.duration_ms.map { Double($0) / 1000 }
            cache(playing: state.is_playing, time: Double(state.progress_ms ?? 0) / 1000)
            playerTrackID = state.item?.uri
            playerDuration = duration
            observation = FollowRules.Observation(trackID: state.item?.uri, isPlaying: state.is_playing,
                                                  position: Double(state.progress_ms ?? 0) / 1000, duration: duration)
            if state.is_playing != lastPlaying {
                lastPlaying = state.is_playing
                onEvent?(.statusChanged)
            }
        }

        let context = FollowRules.Context(
            ours: currentURI, staged: stagedURI, previous: previousURI,
            sincePlayRequest: Date().timeIntervalSince(playRequestedAt), retriedPlay: retriedPlay,
            pausedByUs: pausedByUs, reportedEnd: reportedEnd, reportedForeign: foreignURI
        )
        switch FollowRules.step(observation, context) {
        case .nothing:
            break
        case .retryPlay:
            // Spotify sometimes ignores a play request (e.g. its app was just waking up), and is
            // idle or still on our previous song: ask once more. Never over someone else's track.
            guard let expected = currentURI else { return }
            retriedPlay = true
            log("Spotify is on \(state?.item?.uri ?? "nothing") instead of \(expected); retrying")
            struct Body: Encodable { var uris: [String] }
            settleUntil = Date().addingTimeInterval(2)
            _ = try? await api.send("PUT", "/me/player/play", query: deviceQuery, body: Body(uris: [expected]))
        case .advancedToStaged:
            currentURI = state?.item?.uri
            stagedURI = nil
            foreignURI = nil
            reportedEnd = false
            onEvent?(.advancedToStaged)
        case .foreign:
            // Someone else's choice (another zone or app on the account, autoplay): follow it.
            guard let item = state?.item else { return }
            log("following \(item.name ?? item.uri): not ours")
            foreignURI = item.uri
            onEvent?(.externalTrack(item.queueTrack))
        case .backToOurs:
            foreignURI = nil
            onEvent?(.externalTrack(nil))
        case .reachedEnd:
            reportedEnd = true
            onEvent?(.reachedEnd)
        }
    }
}
