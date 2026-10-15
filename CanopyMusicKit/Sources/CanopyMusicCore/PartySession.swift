import Foundation
import Observation

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    public var position: TimeInterval
    public var capturedAt: Date
}

/// The hub's guest Wi‑Fi, shown as a "Join Wi‑Fi" QR code. Hosts edit it from the web page. Only
/// displays' snapshots carry it (so they can show the code too); guests' phones never receive it.
public struct WifiDetails: Codable, Equatable, Sendable {
    public var ssid: String
    public var password: String
    /// A plain QR code instead of the halftone one with the Wi‑Fi symbol, for phones that struggle.
    public var simpleQR: Bool

    public init(ssid: String = "", password: String = "", simpleQR: Bool = false) {
        self.ssid = ssid
        self.password = password
        self.simpleQR = simpleQR
    }
}

/// Apple TV hubs: whether the TV can play Apple Music, shown to the host setting up its zone so
/// they know why it can't start. `error` covers everything else (not signed in, offline, a token
/// request that failed); the TV logs the actual error in debug builds.
public enum MusicAccess: String, Codable, Sendable {
    case ok
    /// The TV hasn't asked yet (it asks when the host's setup page opens).
    case notDetermined
    /// Turned off for the app (or restricted) in the TV's settings.
    case denied
    /// The TV's Apple Account can't play catalog songs: no Apple Music subscription.
    case noSubscription
    case error
}

/// What phones (and anything else outside the app) see.
public struct PartySnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var playlistName: String?
    public var current: QueueItem?
    public var upNext: [QueueItem]
    public var lockedNextID: UUID?
    public var playback: PlaybackSnapshot
    /// False when the host has turned off reordering from phones.
    public var canReorder: Bool
    /// The friendly address (e.g. `music.local`), which the page moves to when the phone can reach it.
    public var address: String?

    // Zones (docs/multi-device.md). Optional so older pages and clients still decode.
    /// The hub's address by IP (`10.0.1.5` or `10.0.1.5:8080`), which every phone can open.
    public var lanAddress: String?
    public var zoneName: String?
    public var hubKind: HubKind?
    /// Which Mac an `ipad`-kind hub runs on (`MacKind`), for its icon and name on displays and the
    /// web page; nil from iPads, TVs and older hubs.
    public var hubDevice: String?
    /// The hub's music service, e.g. "Apple Music", for search placeholders on displays.
    public var service: String?
    /// Whether displays get play/pause, skip and scrubbing.
    public var displaysCanControl: Bool?
    /// Recently played songs, newest first, for displays' Up next history.
    public var history: [QueueItem]?
    /// False when the host has turned off queueing from guests' phones (hosts and displays still can).
    public var canQueue: Bool?
    /// How many phones have Host Control.
    public var hostPhones: Int?
    /// The hub's device ID, so a phone keeps one host key per hub whatever address it used.
    public var hubID: String?
    /// How many of the base playlist's songs were left out when it loaded, because they can't be
    /// played (e.g. not on Apple Music). nil when none were.
    public var skippedOnLoad: Int?
    /// The first few of those songs' titles.
    public var skippedTitles: [String]?
    /// Apple TV hubs: whether the screensaver may come on while music plays too (it always may
    /// while it's paused), for the hub and TV displays. nil from iPads.
    public var screensaverWhilePlaying: Bool?
    /// The hub's guest Wi‑Fi, in snapshots for displays only (never for guests' phones), so a
    /// display shows the same "Join Wi‑Fi" code. nil from older hubs.
    public var wifi: WifiDetails?
    /// Which session of the hub `version` counts in (`PartySession.epoch`). A page or display
    /// that sees a new epoch takes that snapshot whatever its version, since the counter started
    /// over. nil from older hubs: versions are compared as before.
    public var epoch: String?

    // Follow mode (Spotify zones, docs/multi-device.md). Optional so older peers ignore them.
    /// What the player is actually playing when it isn't one of this queue's songs (another app
    /// or zone on the account, autoplay). Now Playing shows it, with no requester; `current`
    /// stays underneath until the player reaches the queue's next song. nil otherwise.
    public var externalCurrent: QueueItem?
    /// Songs in the player's own queue that Canopy didn't put there and that play before its
    /// next song: read-only, at the top of Up next. nil when there are none.
    public var foreignUpcoming: [QueueItem]?
    /// Something the host should know, e.g. "Couldn't queue the next song on Spotify". nil when fine.
    public var playerIssue: String?

    // Reorder limits (`ReorderLimit`). Optional so older pages and clients still decode.
    /// The hub's "Limit reorders" setting, on or off, for the host's settings sheet and guests'
    /// balances. nil from older hubs and displays.
    public var reorderLimit: ReorderLimit?
    /// Reorders spent, by client ID, while the limit is on: each guest's page works out its own
    /// balance and countdown from its entry (none: a full balance). nil when the limit is off or
    /// nobody has spent one.
    public var reorderSpends: [String: ReorderSpend]?

    /// Apple TV hubs: whether the TV can play Apple Music. Only in snapshots for hosts (a page
    /// whose socket gave a valid Host Control key); nil for everyone else and from other hubs.
    public var musicAccess: MusicAccess?
    /// Apple TV hubs: Spotify's setup (sign-in, devices, the sign-in page). Hosts only, as
    /// `musicAccess`.
    public var spotify: SpotifySetup?
    /// The hub's Sonos rooms: where an Apple TV zone plays (setup), and the party page's volume
    /// row and Devices while it plays through Sonos. Hosts only, as `musicAccess`.
    public var sonos: SonosSetup?
    /// Whether the hub's crossfade is on (on Sonos, Sonos's own), for the party page's Crossfade
    /// button. Hosts only, as `musicAccess`; nil until the hub has set it, and from older hubs.
    public var crossfade: Bool?
}

/// Owns the queue and keeps the player in step with it. Both the iPad UI and the phone server
/// go through this, so every edit follows the same rules.
@MainActor
@Observable
public final class PartySession {
    /// How early to stage the next track on engines that can't replace a staged track.
    static let lateStageLead: TimeInterval = 20

    public private(set) var state: QueueState
    public private(set) var isPlaying = false {
        didSet { if isPlaying { resumeTicker() } }
    }
    /// Set when this session mirrors another device's zone (display mode).
    @ObservationIgnored public let remote: (any ZoneRemote)?
    /// Identifies this session object in its snapshots. `state.version` counts up within it; a
    /// new session (after End, a service change or a relaunch) starts the count over, and
    /// listeners that still hold the old count would drop every snapshot until it caught up.
    /// Fresh per object rather than saved with the queue: a queue restored from disk may be a
    /// save behind what pages saw, so its count must not be trusted against theirs either.
    @ObservationIgnored public let epoch = UUID().uuidString
    /// Display mode: the epoch of the last snapshot taken from the hub.
    @ObservationIgnored private var hubEpoch: String?
    /// Zone details from the hub, for a display; this device's own, for a hub.
    public private(set) var hubKind: HubKind?
    /// Which Mac an `ipad`-kind hub runs on (`MacKind`); nil for iPads, TVs and older hubs.
    public private(set) var hubDevice: String?
    /// The hub device's ID (stable across launches and renames).
    public private(set) var hubID: String?
    /// Hub only: the Spotify account fingerprint this zone announces (set by the app as it
    /// announces the zone; nil for Apple Music). `GET /api/zone` answers it, so a device that sees
    /// the announcement can check the zone is really there before it blocks anything.
    @ObservationIgnored public var announcedSpotifyAccount: String?
    public var zoneName: String? {
        didSet { if zoneName != oldValue, remote == nil { broadcast() } }
    }
    /// The hub's music service title, e.g. "Apple Music".
    public var serviceName: String?
    /// Whether displays get play/pause, skip and scrubbing (a hub setting, on by default).
    public var displaysCanControl = true {
        didSet { if displaysCanControl != oldValue, remote == nil { broadcast() } }
    }
    /// Apple TV hubs: whether the screensaver may come on while music plays too, to protect OLED
    /// screens (a hub setting, off by default). It always may while the music is paused.
    public var screensaverWhilePlaying = false {
        didSet { if screensaverWhilePlaying != oldValue, remote == nil { broadcast() } }
    }

    /// Whether an Apple TV (hub or display) keeps its screen awake: only while music plays, and
    /// not then either if the hub allows the screensaver during music. iPads always stay awake.
    public nonisolated static func tvKeepsScreenAwake(isPlaying: Bool, screensaverWhilePlaying: Bool) -> Bool {
        isPlaying && !screensaverWhilePlaying
    }

    public var tvKeepsScreenAwake: Bool {
        Self.tvKeepsScreenAwake(isPlaying: isPlaying, screensaverWhilePlaying: screensaverWhilePlaying)
    }

    /// Whether guests can add songs from their phones (a hub setting, on by default). Hosts and
    /// displays always can.
    public var phonesCanQueue = true {
        didSet { if phonesCanQueue != oldValue, remote == nil { broadcast() } }
    }
    /// Phones with Host Control (set by the hub).
    public var hostPhoneCount = 0 {
        didSet { if hostPhoneCount != oldValue, remote == nil { broadcast() } }
    }
    /// The hub's guest Wi‑Fi: this hub's own, or (display) its hub's. In displays' snapshots only.
    public var wifi = WifiDetails() {
        didSet { if wifi != oldValue, remote == nil { broadcast() } }
    }
    /// Apple TV hubs: whether the TV can play Apple Music (set by the app). Hosts' snapshots carry it.
    public var musicAccess: MusicAccess? {
        didSet { if musicAccess != oldValue, remote == nil { broadcast() } }
    }
    /// A host's page asked the hub to check its music access again (and, if the TV has never
    /// asked for Apple Music access, to ask now; with Spotify, to read its devices again).
    @ObservationIgnored public var onMusicAccessCheck: (@MainActor () -> Void)?
    /// Apple TV hubs: Spotify's setup, for hosts' snapshots (set by the app).
    public var spotifySetup: SpotifySetup? {
        didSet { if spotifySetup != oldValue, remote == nil { broadcast() } }
    }
    /// Apple TV hubs: the Spotify sign-in a host's phone runs, whose answer comes back to
    /// `/spotify/callback` (set by the app).
    @ObservationIgnored public var spotifySignIn: SpotifyHubSignIn?
    /// Apple TV hubs: the music service and Spotify's settings, for the host's setup page.
    @ObservationIgnored public weak var setupHandler: (any HubSetupHandler)?
    /// The hub's Sonos rooms, for hosts' snapshots (set by the app).
    public var sonosSetup: SonosSetup? {
        didSet { if sonosSetup != oldValue, remote == nil { broadcast() } }
    }
    /// Chooses Sonos rooms, and sets their volumes, for a host's phone (set by the app).
    @ObservationIgnored public weak var sonosHandler: (any SonosOutputHandler)?
    /// A host revoked every other phone's Host Control; returns the new key for that host.
    @ObservationIgnored public var onForgetHostPhones: (@MainActor () -> String?)?
    /// The hub's guest address by IP, from the hub (display) or set by the app (hub).
    public var lanAddress: String?
    /// Songs of the base playlist left out when it loaded because they can't be played (hub only).
    /// Replaced by the next playlist's.
    public private(set) var skippedOnLoad: [QueueTrack] = []
    /// How many of their titles snapshots carry.
    public static let skippedTitlesInSnapshots = 3
    /// Displays that have checked in recently (hub only).
    public private(set) var displays: [ZoneDisplay] = []
    /// Called when a host changes settings from the web page, so the app can save them.
    @ObservationIgnored public var onSettingsChanged: (@MainActor () -> Void)?
    /// Called when a host stops the zone from the web page (after the page asked them to confirm).
    @ObservationIgnored public var onStopRequested: (@MainActor () -> Void)?
    /// Called each time the player actually starts a song (hub only), so the app can record that
    /// music has started in this zone. Not called for a loaded playlist or a failed start.
    @ObservationIgnored public var onSongStarted: (@MainActor () -> Void)?
    public private(set) var catalog: any MusicCatalog
    /// Replaced only by `replaceService`, while nothing has been loaded.
    @ObservationIgnored public private(set) var engine: any PlaybackEngine

    // MARK: Follow mode state (docs/multi-device.md)

    /// Follow mode: what the player is playing when it isn't one of this queue's songs. Canopy's
    /// own `state.current` stays underneath, unchanged, until the player reaches our next song.
    public private(set) var externalCurrent: QueueItem?
    /// Follow mode: songs in the player's own queue that will play before Canopy's next song.
    public private(set) var foreignUpcoming: [QueueItem] = []
    /// Something the host should see, e.g. "Couldn't queue the next song on Spotify".
    public private(set) var playerIssue: String?
    /// What Now Playing shows: what the player is actually playing.
    public var nowPlaying: QueueItem? { externalCurrent ?? state.current }
    /// The engine, when it's one this session follows rather than drives (hub only).
    private var follower: (any FollowingPlaybackEngine)? {
        remote == nil ? engine as? any FollowingPlaybackEngine : nil
    }
    @ObservationIgnored var followTiming = FollowTiming()
    /// Counts up to call off the staging run in flight (the track changed, the zone ended).
    @ObservationIgnored private var stagingRun = 0
    @ObservationIgnored private var stagingTask: Task<Void, Never>?
    /// The staged item was seen in the player's queue (or the player took it without error and
    /// its queue couldn't be read).
    @ObservationIgnored private var stagedConfirmed = false
    /// Staging gave up for this track: nothing more is tried until our next song plays.
    @ObservationIgnored private var gaveUpStaging = false

    @ObservationIgnored private var stagedItemID: UUID?
    /// The music has started in this session (a song actually began playing, or the queue came
    /// back from disk with one under way) and the session hasn't started over since (`end`, or a
    /// `load` before anything played). A new base playlist then keeps the party going.
    @ObservationIgnored private var isUnderWay = false
    /// Tail of the serial chain of engine operations (see `serially`).
    @ObservationIgnored private var engineChain: Task<Void, Never>?
    /// Operations waiting in or running on the chain.
    @ObservationIgnored private var pendingOperations = 0
    /// Counts up each time the session starts over (`end`, `load`) or is dropped (`shutdown`).
    /// An engine call that was in flight across one of those (a song change as the zone ended)
    /// belongs to the session that was: when it returns, the music is paused and nothing is
    /// recorded, saved or staged from it.
    @ObservationIgnored private var generation = 0
    /// The queue item the engine currently has loaded as its current track.
    @ObservationIgnored private var loadedItemID: UUID?
    /// A skip or previous moved the queue on without the player, which is still on the song
    /// before: playing it until the taps settle (`landNow`), or paused on it, where it was.
    @ObservationIgnored private var playerOnOldSong = false
    /// How long skips and previouses must pause before the player is told where they landed.
    /// Each tap moves the queue at once; the player gets only the song the burst ends on.
    public static let defaultLandingDelay: TimeInterval = 0.35
    @ObservationIgnored var landingDelay = PartySession.defaultLandingDelay
    /// The wait for the taps to settle (cancelled by each new tap).
    @ObservationIgnored private var landingTimer: Task<Void, any Error>?
    /// Whether the song landed on should play: the music was playing when the burst began, or a
    /// play since. nil when no landing is waiting.
    @ObservationIgnored private var landingPlays: Bool?
    /// The landing moved the player to its staged song (this item), which the queue is already
    /// on: the player's `.advancedToStaged` confirms it rather than moving the queue on again.
    @ObservationIgnored private var skippedToStagedID: UUID?
    /// How many songs in a row may fail to play before the session stops moving on: by then it's
    /// the player or the service, not the songs, and skipping on would empty the queue.
    static let maxSongsFailingInARow = 3
    /// `playerIssue` is about songs that couldn't play (`playMovingOn`). It stays while the song
    /// after them plays (`songFailureShownWith`; nil once a run of failures stopped the music),
    /// and goes when another song starts.
    @ObservationIgnored private var showsSongFailure = false
    @ObservationIgnored private var songFailureShownWith: UUID?

    /// Where the current song is. The engine's time, except after a skip or previous the player
    /// hasn't followed yet: that's the song before's, and the new song is at 0:00 until it plays.
    public var position: TimeInterval { playerOnOldSong ? 0 : engine.currentTime }
    /// A restored session whose engine (not a followed one) was asked to `attach`, and hasn't
    /// yet reported the player on the restored song, nor been given a song since.
    @ObservationIgnored private var awaitingAttach = false
    /// `syncStaging` is running (one at a time; later calls fold into it).
    @ObservationIgnored private(set) var isSyncing = false
    @ObservationIgnored private var needsSync = false
    /// How long one engine call (play, stage, resume, skip to staged) may take before it counts
    /// as failed and the chain moves on. Apple's out-of-process player can stop answering;
    /// without a deadline every later command waited behind it for good.
    public static let defaultEngineCallTimeout: TimeInterval = 12
    @ObservationIgnored var engineCallTimeout = PartySession.defaultEngineCallTimeout
    /// Snapshot listeners, whether each gets the Wi‑Fi details (displays do, phones don't), and
    /// the Host Control key it connected with (hosts also get `musicAccess`).
    @ObservationIgnored private var listeners: [UUID: (continuation: AsyncStream<PartySnapshot>.Continuation, withWifi: Bool, hostKey: String?)] = [:]
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// The engine stages late, so the ticker runs whenever music plays (`resumeTicker`).
    @ObservationIgnored private var wantsTicker = false
    /// For tests: the late-staging ticker is running.
    var isTicking: Bool { tickTask != nil }
    /// Drops displays that stopped checking in (`noteDisplay`), while any are listed.
    @ObservationIgnored private var displayExpiry: Task<Void, Never>?
    /// Playback as last sent to listeners, and the loop that resends it if the player drifts.
    @ObservationIgnored private var lastSentPlayback: PlaybackSnapshot?
    @ObservationIgnored private var driftTask: Task<Void, Never>?
    /// How far listeners' idea of the playback time may be off before it's resent.
    static let driftTolerance: TimeInterval = 1

    public init(catalog: any MusicCatalog, engine: any PlaybackEngine, storeURL: URL? = nil) {
        self.catalog = catalog
        self.engine = engine
        self.storeURL = storeURL
        self.remote = nil
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           var restored = try? JSONDecoder().decode(QueueState.self, from: data) {
            // Nothing is staged in a fresh player.
            restored.unlockNext()
            state = restored
            // A zone coming back after a relaunch: its music had started.
            isUnderWay = restored.current != nil || !restored.history.isEmpty
            // And what its guests had spent of their reorders.
            if let data = try? Data(contentsOf: Self.spendsURL(beside: storeURL)),
               let spends = try? JSONDecoder().decode([String: ReorderSpend].self, from: data) {
                reorderSpends = spends
            }
        } else {
            state = QueueState()
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        if !engine.canReplaceStaged { startLateStagingTicker() }
        // A followed player (Spotify) or a Sonos group keeps playing while the app is gone: after
        // a relaunch, the engine looks so the restored song shows as it really is (playing, and
        // where). Engines whose player stopped with the app ignore it.
        if let current = state.current {
            awaitingAttach = follower == nil
            engine.attach(expecting: current.track, next: state.upNext.first?.track)
        }
    }

    /// A display's session: mirrors the hub's queue from snapshots and sends edits to the hub.
    public init(remote: any ZoneRemote) {
        self.remote = remote
        self.catalog = RemoteCatalog { [weak remote] term in
            guard let remote else { return [] }
            return try await remote.search(term)
        }
        self.engine = MirrorEngine()
        self.storeURL = nil
        state = QueueState()
    }

    /// The hub's latest snapshot (display mode). A snapshot older than an optimistic local edit
    /// is skipped, so the edit doesn't flicker back; `force` takes it anyway (after a refused edit).
    /// The first snapshot of a new session on the hub (a new `epoch`) is taken whatever its
    /// version, since the hub's count started over; versions are compared from there on.
    public func apply(_ snapshot: PartySnapshot, force: Bool = false) {
        guard remote != nil else { return }
        let newEpoch = snapshot.epoch != nil && snapshot.epoch != hubEpoch
        if force || newEpoch || snapshot.version >= state.version {
            state = QueueState(mirroring: snapshot)
            hubEpoch = snapshot.epoch
        }
        var playback = snapshot.playback
        // The hub's clock may differ from ours; time it from when it arrived.
        playback.capturedAt = Date()
        (engine as? MirrorEngine)?.playback = playback
        isPlaying = playback.isPlaying
        hubKind = snapshot.hubKind
        hubDevice = snapshot.hubDevice
        hubID = snapshot.hubID
        zoneName = snapshot.zoneName
        serviceName = snapshot.service
        phonesCanReorder = snapshot.canReorder
        displaysCanControl = snapshot.displaysCanControl ?? true
        phonesCanQueue = snapshot.canQueue ?? true
        screensaverWhilePlaying = snapshot.screensaverWhilePlaying ?? false
        guestAddress = snapshot.address
        lanAddress = snapshot.lanAddress
        externalCurrent = snapshot.externalCurrent
        foreignUpcoming = snapshot.foreignUpcoming ?? []
        playerIssue = snapshot.playerIssue
        // Only displays' snapshots carry it (not `/api/state`, read after a refused edit).
        if let hubWifi = snapshot.wifi { wifi = hubWifi }
    }

    /// This device's own zone (hub). `device` is which Mac this is (`MacKind`), if any.
    public func configureHub(kind: HubKind, device: String? = nil, id: String? = nil, zoneName: String, serviceName: String?) {
        hubKind = kind
        hubDevice = device
        hubID = id
        self.zoneName = zoneName
        self.serviceName = serviceName
        broadcast()
    }

    /// How long a display stays listed without checking in (they check in every 10 s).
    public static let displayTimeout: TimeInterval = 30

    /// A display checked in. Displays not heard from for `displayTimeout` drop off the list, on
    /// a timer of their own: a display that's the only one, and then goes quiet (unplugged, off
    /// the Wi‑Fi), has nobody else's check-in to clear it.
    public func noteDisplay(_ display: ZoneDisplay) {
        displays.removeAll { $0.id == display.id }
        displays.append(display)
        displays.sort { $0.name < $1.name }
        expireDisplays()
        guard displayExpiry == nil else { return }
        displayExpiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.expireDisplays()
                if self.displays.isEmpty { self.displayExpiry = nil; return }
            }
        }
    }

    /// A display said it's leaving (it stopped showing this zone): off the list at once.
    public func forgetDisplay(id: String) {
        displays.removeAll { $0.id == id }
    }

    private func expireDisplays() {
        let now = Date()
        let fresh = displays.filter { now.timeIntervalSince($0.lastSeen) <= Self.displayTimeout }
        if fresh.count != displays.count { displays = fresh }
    }

    /// Applies settings sent by a host from the web page. (The iPad's unlock PIN isn't one: it's
    /// set only on the iPad.)
    public func applyHostSettings(zoneName: String?, phonesCanQueue: Bool? = nil, phonesCanReorder: Bool?,
                                  reorderLimit: ReorderLimit? = nil, displaysCanControl: Bool?, wifi: WifiDetails? = nil,
                                  screensaverWhilePlaying: Bool? = nil, crossfade: Bool? = nil) {
        if let wifi { self.wifi = wifi }
        // The party page's Crossfade button: the length stays the hub's.
        if let crossfade { setCrossfade(enabled: crossfade, duration: crossfadeDuration) }
        if let screensaverWhilePlaying, hubKind == .tv { self.screensaverWhilePlaying = screensaverWhilePlaying }
        if let zoneName, !zoneName.isEmpty { self.zoneName = zoneName }
        if let phonesCanQueue { self.phonesCanQueue = phonesCanQueue }
        if let phonesCanReorder { self.phonesCanReorder = phonesCanReorder }
        if let reorderLimit { self.reorderLimit = reorderLimit.validated }
        if let displaysCanControl { self.displaysCanControl = displaysCanControl }
        onSettingsChanged?()
    }

    /// The base playlist past the live Up Next, a page at a time: the hub's own, or (display) its hub's.
    public func upcoming(offset: Int, limit: Int) async throws -> UpcomingPage {
        if let remote { return try await remote.upcoming(offset: offset, limit: limit) }
        return state.upcomingPage(offset: offset, limit: limit)
    }

    /// Revokes Host Control from every phone but the one asking; returns its new key.
    public func forgetOtherHostPhones() -> String? {
        onForgetHostPhones?()
    }

    public func requestStop() {
        onStopRequested?()
    }

    /// A host's page asks for the hub's music access to be checked again.
    public func checkMusicAccess() {
        onMusicAccessCheck?()
    }

    /// Apple TV hubs, while the host sets the zone up: changes the music service under this same
    /// session, so the phone server and the pages connected to it carry on. Only while nothing
    /// has been loaded (no base playlist, no songs); false otherwise.
    @discardableResult
    public func replaceService(catalog: any MusicCatalog, engine: any PlaybackEngine, serviceName: String?) -> Bool {
        guard remote == nil, state.playlistName == nil, !hasParty, state.history.isEmpty else { return false }
        generation += 1
        callOffLanding()
        stagingRun += 1
        stagingTask = nil
        stagedItemID = nil
        loadedItemID = nil
        isPlaying = false
        self.engine.onEvent = nil
        wantsTicker = false
        tickTask?.cancel()
        tickTask = nil
        resetFollow(keepPlayerQueue: false)
        self.catalog = catalog
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.handle(event) }
        if !engine.canReplaceStaged { startLateStagingTicker() }
        // The new engine plays with the hub's crossfade too (a TV that moved onto Sonos rooms).
        if let crossfade { engine.setCrossfade(enabled: crossfade, duration: crossfadeDuration) }
        self.serviceName = serviceName
        broadcast()
        return true
    }

    /// Ends the zone's session (hub only): stops playback, empties the queue, history and base
    /// playlist, and deletes the saved queue, so the next zone on this device starts empty.
    /// Settings (zone name, Wi‑Fi, toggles, Host Control) aren't the session's to clear.
    public func end() {
        guard remote == nil else { return }
        generation += 1
        callOffLanding()
        if engine.isPlaying { engine.pause() }
        saveTask?.cancel()
        saveTask = nil
        stagedItemID = nil
        loadedItemID = nil
        awaitingAttach = false
        isPlaying = false
        isUnderWay = false
        skippedOnLoad = []
        displays = []
        reorderSpends = [:]
        displayExpiry?.cancel()
        displayExpiry = nil
        resetFollow(keepPlayerQueue: false)
        state.clear()
        broadcast()
        if let storeURL { try? FileManager.default.removeItem(at: storeURL) }
    }

    /// The app is dropping this session (joining a zone as a display, changing service, leaving
    /// a zone): stops the music and the session's own loops, and writes a save still pending, so
    /// a chained engine call that finishes later changes nothing, and nothing outlives it.
    public func shutdown() {
        generation += 1
        callOffLanding()
        stagingRun += 1
        stagingTask = nil
        if remote == nil {
            engine.pause()
            isPlaying = false
            // No loop of the old engine may start its player again (a play retry) once it's dropped.
            engine.shutDown()
        }
        engine.onEvent = nil
        if let saveTask, let storeURL {
            saveTask.cancel()
            self.saveTask = nil
            if let data = try? JSONEncoder().encode(state) { try? data.write(to: storeURL, options: .atomic) }
        }
        wantsTicker = false
        tickTask?.cancel()
        tickTask = nil
        driftTask?.cancel()
        driftTask = nil
        displayExpiry?.cancel()
        displayExpiry = nil
    }

    public var hasParty: Bool { state.current != nil || !state.upNext.isEmpty }

    /// An Apple TV zone whose host hasn't picked the music yet: no base playlist and nothing queued.
    /// The TV shows "Scan to host" or "Continue on your phone", and doesn't announce the zone yet.
    public var isWaitingForSetup: Bool {
        hubKind == .tv && state.playlistName == nil && !hasParty
    }

    // MARK: Saving the party

    /// Every song that has played in this zone (hub only), for saving it as a playlist.
    public var partyLog: PartyLog { state.log }

    /// The queue's songs that haven't played yet, in queue order: the current item (unless it
    /// has started) and Up next. Their requests are saved with the songs that played.
    private var waitingItems: [QueueItem] { [state.current].compactMap { $0 } + state.upNext }

    /// What saving would do right now (hub only).
    public var partySaveInfo: PartySaveInfo {
        let log = state.log, waiting = waitingItems
        return PartySaveInfo(suggestedName: log.suggestedName(),
                             allCount: log.songs(onlyRequests: false, waiting: waiting).count,
                             requestCount: log.songs(onlyRequests: true, waiting: waiting).count,
                             destination: catalog.playlistDestination)
    }

    /// Saves the party as a playlist in the hub's account, crediting the guests who queued its
    /// songs: the songs that played and the requests still waiting (`PartyLog.songs`). A blank
    /// name gets the suggested one. Returns how many songs it saved.
    @discardableResult
    public func savePartyPlaylist(name: String, onlyRequests: Bool) async throws -> Int {
        guard remote == nil else { throw PartySaveError.unsupported }
        let log = state.log, waiting = waitingItems
        let tracks = log.tracks(onlyRequests: onlyRequests, waiting: waiting)
        guard !tracks.isEmpty else { throw PartySaveError.nothingToSave(onlyRequests: onlyRequests) }
        var name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if name.isEmpty { name = log.suggestedName().trimmingCharacters(in: .whitespaces) }
        let description = log.playlistDescription(onlyRequests: onlyRequests, waiting: waiting)
        try await catalog.savePlaylist(name: name, description: description, tracks: tracks)
        return tracks.count
    }

    /// The player started `item`: it goes in the party log.
    private func recordPlayed(_ item: QueueItem?) {
        guard remote == nil, let item, state.recordPlayed(item) else { return }
        scheduleSave()
    }

    // MARK: Host actions

    /// Sets the base playlist. `shuffled` shuffles it in the same change, so the first song is
    /// random too and nobody sees it in its original order first.
    ///
    /// - Before the music has started (`isUnderWay` false: setup, before Start, or after a Start
    ///   that failed): starts over. Clears the queue and requests; nothing plays until `play()`.
    /// - Once it has (a live zone, playing or paused): the song playing goes on, untouched, and
    ///   the new playlist takes over after it. Guests' requests stay at the top of Up next, and
    ///   only the old playlist's songs are replaced (`QueueState.replacePlaylist`). A next song
    ///   already handed to a player that can't take it back (Spotify) stays first, locked; an
    ///   engine that can swap its staged song (Apple Music) is restaged with the new next song.
    ///
    /// A playlist with nothing to play (empty, or none of its songs can play here) throws a
    /// `PlaylistLoadError` and changes nothing: no half-started party, and a live one plays on.
    public func load(playlist: PlaylistSummary, shuffled: Bool = false) async throws {
        guard remote == nil else { return }
        let tracks = try await catalog.tracks(in: playlist)
        let skipped = await catalog.loadReport(for: playlist)?.skipped ?? []
        // The pickers show the count it was found to have (and an empty one dimmed).
        await PlaylistSongCounts.shared.record(tracks.count + skipped.count, for: playlist.id)
        guard !tracks.isEmpty else {
            throw skipped.isEmpty ? PlaylistLoadError.noSongs(playlist: playlist.name) : .noPlayableSongs(playlist: playlist.name)
        }
        if isUnderWay {
            // Not a new session: nothing in flight (a song change, follow mode's staging) is
            // called off, and `mutate` restages behind the current song.
            skippedOnLoad = skipped
            mutate { $0.replacePlaylist(shuffled ? tracks.shuffled() : tracks, name: playlist.name) }
            return
        }
        generation += 1
        callOffLanding()
        if engine.isPlaying { engine.pause() }
        stagedItemID = nil
        loadedItemID = nil
        isPlaying = false
        skippedOnLoad = skipped
        // The player's own queue is still there and plays first; the rest starts over.
        resetFollow(keepPlayerQueue: true)
        mutate {
            $0.load(playlist: tracks, name: playlist.name)
            if shuffled { $0.shufflePlaylist() }
        }
    }

    public func shufflePlaylist() {
        guard remote == nil else { return }
        mutate { $0.shufflePlaylist() }
    }

    /// Plays the current song, loading it into the engine first if needed (e.g. after a relaunch).
    public func play() async throws {
        if let remote {
            isPlaying = true
            try await remote.send(.play)
            return
        }
        if let landingTimer {
            // Skips still settling: the song they land on plays, once they have.
            landingPlays = true
            _ = try? await Self.value(of: landingTimer)
            return
        }
        let result: Result<Void, any Error> = try await serially {
            do {
                try await self.playNow()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    private func playNow() async throws {
        if state.current == nil { mutate { $0.advance() } }
        guard let current = state.current else { return }
        if loadedItemID == current.id {
            let generation = generation
            do {
                try await timed("resume") { try await self.engine.resume() }
            } catch let error as PlaybackEngineError {
                // The player didn't answer: the next play loads the song again rather than resume.
                loadedItemID = nil
                throw error
            }
            guard generation == self.generation else { engine.pause(); return }
            isPlaying = engine.isPlaying
            broadcast()
        } else {
            try await play(current)
        }
    }

    /// Pauses at once. A song change still in flight on the chain (a skip's play, say) would
    /// start the music again when it lands, so the pause is repeated after it, in its turn: a
    /// play pressed in between is queued behind that and wins, as the order of presses says.
    /// Skips still settling land paused.
    public func pause() {
        if let remote {
            isPlaying = false
            Task { try? await remote.send(.pause) }
            return
        }
        engine.pause()
        isPlaying = engine.isPlaying
        if landingPlays != nil { landingPlays = false }
        broadcast()
        guard pendingOperations > 0 else { return }
        Task {
            try? await serially {
                self.engine.pause()
                self.isPlaying = self.engine.isPlaying
                self.broadcast()
            }
        }
    }

    public func togglePlayPause() async {
        if engine.isPlaying || (remote != nil && isPlaying) {
            pause()
        } else {
            try? await play()
        }
    }

    /// Like the Music app: restarts the song if it's more than a few seconds in, otherwise goes
    /// to the previous song (and keeps playing or paused as it was). Goes back as `skip` goes on.
    public func previous() async {
        if let remote {
            try? await remote.send(.previous)
            return
        }
        guard position <= 3, !state.history.isEmpty else {
            // A song the player hasn't started yet starts from its beginning anyway.
            guard !playerOnOldSong else { return }
            try? await serially {
                self.engine.restartCurrent()
                self.broadcast()
            }
            return
        }
        await step { $0.goBack() }
    }

    public func seek(to time: TimeInterval) {
        if let remote {
            if let mirror = engine as? MirrorEngine {
                mirror.playback = PlaybackSnapshot(isPlaying: mirror.isPlaying, position: max(0, time), capturedAt: Date())
            }
            Task { try? await remote.send(.seek(max(0, time))) }
            return
        }
        // Not during a song change: the position belongs to the song going away, and a seek on
        // a player mid-call is the kind of overlap that wedges it (see `serially`).
        guard pendingOperations == 0, !playerOnOldSong else { return }
        engine.seek(to: max(0, time))
        broadcast()
    }

    public func skip() async {
        if let remote {
            try? await remote.send(.next)
            return
        }
        // Follow mode: the player's own queue is what Up next shows first, so skip goes there,
        // one press at a time (it isn't Canopy's queue to move ahead of the player). With
        // nothing of the player's queued, skip moves Canopy's queue on as usual (which also
        // takes back a player that's been following someone else).
        if landingPlays == nil, engine.isPlaying, follower != nil, !foreignUpcoming.isEmpty {
            try? await serially {
                let generation = self.generation
                _ = try? await self.timed("skipInPlayer") { try await self.follower?.skipInPlayer() }
                guard generation == self.generation else { self.engine.pause(); return }
            }
            return
        }
        await step { $0.advance() }
    }

    /// A skip or previous: the queue (and everyone's screen) moves at once, and the player
    /// follows once the taps settle, with only the song they landed on (`landNow`). Telling
    /// the player every tap kept it loading songs that were skipped straight away, and its
    /// skips to the staged song could outrun the polls that report them. Returns once the
    /// player has followed, or a later tap has taken over.
    private func step(_ change: (inout QueueState) -> Void) async {
        if landingPlays == nil { landingPlays = engine.isPlaying }
        cancelStaging()
        // The player stays on the song before (playing or paused) until the landing.
        playerOnOldSong = true
        loadedItemID = nil
        mutate(change)
        landingTimer?.cancel()
        let delay = landingDelay
        let timer = Task<Void, any Error> { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.landingTimer = nil
            try await self.serially { await self.landNow() }
        }
        landingTimer = timer
        _ = try? await Self.value(of: timer)
    }

    /// The taps have settled: the player gets the song they landed on, in turn with its other
    /// commands, so one in flight finishes first and the newest song is sent after it.
    private func landNow() async {
        // Another burst has begun since: its own landing follows.
        guard landingTimer == nil, let plays = landingPlays else { return }
        landingPlays = nil
        // Playing then, or now that the commands before have run (a Play still in flight as the
        // taps began). Paused: the player stays where it was, and Play starts the new song.
        guard plays || engine.isPlaying, let current = state.current, loadedItemID != current.id else { return }
        if stagedItemID == current.id {
            // The song staged behind the old one: the player has it ready, gapless. Sent once;
            // its `.advancedToStaged` then confirms it (`skippedToStagedID`).
            stagedItemID = nil
            skippedToStagedID = current.id
            let generation = generation
            let skipped = (try? await timed("skipToStaged") { try await self.engine.skipToStaged() }) != nil
            guard generation == self.generation else { engine.pause(); return }
            if skipped { return }
            skippedToStagedID = nil
        }
        await playMovingOn(current)
    }

    /// Ends a burst of skips without the player following (the session is starting over).
    private func callOffLanding() {
        landingTimer?.cancel()
        landingTimer = nil
        landingPlays = nil
        skippedToStagedID = nil
        playerOnOldSong = false
    }

    /// Crossfade as the hub last set it (nil until it has), kept so a host's page can show it and
    /// an engine swapped in by `replaceService` gets it too.
    public private(set) var crossfade: Bool? {
        didSet { if crossfade != oldValue, remote == nil { broadcast() } }
    }
    /// The length that goes with it; nil is the engine's default.
    @ObservationIgnored private var crossfadeDuration: TimeInterval?

    public func setCrossfade(enabled: Bool, duration: TimeInterval?) {
        crossfade = enabled
        crossfadeDuration = duration
        engine.setCrossfade(enabled: enabled, duration: duration)
    }

    public func clearRequests() {
        mutate { $0.clearRequests() }
    }

    // MARK: Guest actions

    @discardableResult
    public func add(_ track: QueueTrack, by requester: Requester) -> AddResult {
        if let remote {
            // Show it right away (with the ID the hub will use), then send it. It carries this
            // display's client ID, as the hub's copy will, so it can be removed straight away.
            let id = UUID()
            var requester = requester
            requester.clientID = remote.clientID
            let result = state.addRequest(track, by: requester, id: id)
            if case .added = result { Task { try? await remote.send(.add(track, itemID: id)) } }
            return result
        }
        return mutate { $0.addRequest(track, by: requester) }
    }

    /// Adds a request with an ID chosen by a display, so its optimistic copy matches.
    @discardableResult
    public func add(_ track: QueueTrack, by requester: Requester, id: UUID) -> AddResult {
        mutate { $0.addRequest(track, by: requester, id: id) }
    }

    @discardableResult
    public func move(_ id: UUID, to index: Int) -> Bool {
        if remote != nil {
            // Displays send moves as "after this item", like the web page.
            guard let from = state.upNext.firstIndex(where: { $0.id == id }) else { return false }
            var others = state.upNext.map(\.id)
            others.remove(at: from)
            let to = min(max(index, 0), others.count)
            return move(id, after: to == 0 ? nil : others[to - 1])
        }
        return mutate { $0.move(id, to: index) }
    }

    @discardableResult
    public func move(_ id: UUID, after anchor: UUID?) -> Bool {
        if let remote {
            let ok = state.move(id, after: anchor)
            if ok { Task { try? await remote.send(.move(id, after: anchor)) } }
            return ok
        }
        return mutate { $0.move(id, after: anchor) }
    }

    /// What became of a move from the web page or a display (`move(_:after:asClient:)`).
    public enum ClientMove: Equatable, Sendable {
        case moved
        /// Not possible: the song isn't in Up Next, or it's the locked next song.
        case refused
        /// The guest has no reorders left (`reorderLimit`); nothing moved.
        case outOfReorders
    }

    /// A move from the web page or a display (hub only). With `reorderLimit` on, a guest's move
    /// spends one of their reorders, unless it takes their own song further down (or leaves it
    /// where it was); with none left it's refused. Hosts (`clientID` nil) and displays checked in
    /// as `clientID` aren't limited.
    public func move(_ id: UUID, after anchor: UUID?, asClient clientID: String?) -> ClientMove {
        guard remote == nil, reorderLimit.isOn, let clientID, !displays.contains(where: { $0.id == clientID }) else {
            return move(id, after: anchor) ? .moved : .refused
        }
        // Where it would land, so a move that costs nothing can be told from one that does.
        var trial = state
        guard let from = state.upNext.firstIndex(where: { $0.id == id }), trial.move(id, after: anchor),
              let to = trial.upNext.firstIndex(where: { $0.id == id }) else { return .refused }
        let ownSong = state.upNext[from].requester?.clientID == clientID
        if to < from || (to > from && !ownSong) {
            let now = Date()
            guard let spend = reorderLimit.spending(reorderSpends[clientID], at: now) else { return .outOfReorders }
            // Balances back to full aren't kept (or sent to every page) any longer.
            reorderSpends = reorderSpends.filter { reorderLimit.settled($0.value, at: now).spent > 0 }
            reorderSpends[clientID] = spend
        }
        return move(id, after: anchor) ? .moved : .refused
    }

    /// Removes an item. When `clientID` is given (a phone), only that phone's own requests can be removed.
    /// A display removes only its own requests (`isOwnRequest`): at once, then on the hub, which
    /// checks again and is followed if it refuses.
    @discardableResult
    public func remove(_ id: UUID, asClient clientID: String? = nil) -> Bool {
        if let remote {
            guard let item = state.upNext.first(where: { $0.id == id }), isOwnRequest(item),
                  state.remove(id) != nil else { return false }
            Task { try? await remote.send(.remove(id)) }
            return true
        }
        if let clientID {
            guard let item = state.upNext.first(where: { $0.id == id }),
                  item.requester?.clientID == clientID else { return false }
        }
        return mutate { $0.remove(id) } != nil
    }

    /// Whether this display added `item` (the hub records a display's client ID on its requests,
    /// as it does a phone's), so it may remove it, as a guest can remove theirs. False on a hub.
    public func isOwnRequest(_ item: QueueItem) -> Bool {
        guard let remote, let owner = item.requester?.clientID else { return false }
        return owner == remote.clientID
    }

    /// Random key that gives a phone host control (scanned from the iPad's Settings). Phones with it
    /// can play, pause, skip, reorder and remove anything. nil turns host control off.
    public var hostKey: String?
    /// Called with a phone's client ID each time it shows a valid host key.
    public var onHostPhone: (@MainActor (String) -> Void)?

    public func isHost(key: String?, clientID: String? = nil) -> Bool {
        guard let hostKey, let key, !key.isEmpty, key == hostKey else { return false }
        if let clientID { onHostPhone?(clientID) }
        return true
    }

    /// The guest page's friendly address (`music.local`, plus `:port` if not 80). Sent as it
    /// changes, so a page on the old name can follow a renamed zone to its new one.
    public var guestAddress: String? {
        didSet { if guestAddress != oldValue, remote == nil { broadcast() } }
    }

    /// Whether phones may drag songs around. The iPad can always reorder.
    public var phonesCanReorder = true {
        didSet { if phonesCanReorder != oldValue { broadcast() } }
    }

    /// "Limit reorders" (a hub setting, off by default): how often each guest may reorder while
    /// phones can. Hub only; displays aren't limited, so they don't follow it.
    public var reorderLimit = ReorderLimit.standard {
        didSet {
            guard reorderLimit != oldValue else { return }
            // Off forgets what everyone spent, so turned on again everyone starts with a full balance.
            if !reorderLimit.isOn { reorderSpends = [:] }
            if remote == nil { broadcast() }
        }
    }
    /// Reorders each guest has spent, by client ID, while `reorderLimit` is on (hub only). Saved
    /// beside the queue, so a hub relaunched mid-party (a crash, an update) doesn't hand everyone
    /// a full balance again. The app hands them on to a session it rebuilds mid-party.
    public var reorderSpends: [String: ReorderSpend] = [:] {
        didSet { if reorderSpends != oldValue { saveReorderSpends() } }
    }

    /// Where `reorderSpends` is saved: beside the queue's file.
    private static func spendsURL(beside storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: storeURL.deletingPathExtension().lastPathComponent + "-reorders.json")
    }

    /// Small and written only when someone reorders, so at once rather than debounced as the queue is.
    private func saveReorderSpends() {
        guard let storeURL else { return }
        let url = Self.spendsURL(beside: storeURL)
        if reorderSpends.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(reorderSpends) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Snapshots

    /// What phones see; `includingWifi` adds the guest Wi‑Fi, for displays, and a valid Host
    /// Control `hostKey` adds what only hosts see (`musicAccess`).
    public func snapshot(includingWifi: Bool = false, hostKey key: String? = nil) -> PartySnapshot {
        var snap = PartySnapshot(
            version: state.version,
            playlistName: state.playlistName,
            current: state.current,
            upNext: state.upNext,
            lockedNextID: state.lockedNextID,
            playback: PlaybackSnapshot(isPlaying: engine.isPlaying, position: position, capturedAt: Date()),
            canReorder: phonesCanReorder,
            address: guestAddress,
            lanAddress: lanAddress,
            zoneName: zoneName,
            hubKind: hubKind,
            hubDevice: hubDevice,
            service: serviceName,
            displaysCanControl: displaysCanControl,
            history: Array(state.history.prefix(20)),
            canQueue: phonesCanQueue,
            hostPhones: hostPhoneCount,
            hubID: hubID,
            skippedOnLoad: skippedOnLoad.isEmpty ? nil : skippedOnLoad.count,
            skippedTitles: skippedOnLoad.isEmpty ? nil : skippedOnLoad.prefix(Self.skippedTitlesInSnapshots).map(\.title),
            screensaverWhilePlaying: hubKind == .tv ? screensaverWhilePlaying : nil,
            wifi: includingWifi ? wifi : nil,
            epoch: epoch,
            externalCurrent: externalCurrent,
            foreignUpcoming: foreignUpcoming.isEmpty ? nil : foreignUpcoming,
            playerIssue: playerIssue
        )
        if remote == nil {
            snap.reorderLimit = reorderLimit
            if reorderLimit.isOn, !reorderSpends.isEmpty { snap.reorderSpends = reorderSpends }
        }
        if isHostKey(key) { addHostDetails(to: &snap) }
        return snap
    }

    /// Whether `key` is the current Host Control key (checked on every snapshot, so a phone whose
    /// key was revoked stops getting hosts' details without reconnecting).
    private func isHostKey(_ key: String?) -> Bool {
        guard let hostKey, let key, !key.isEmpty else { return false }
        return key == hostKey
    }

    /// What only hosts see: an Apple TV's Apple Music access and Spotify setup, the hub's Sonos
    /// rooms, and its crossfade.
    private func addHostDetails(to snap: inout PartySnapshot) {
        snap.musicAccess = musicAccess
        snap.spotify = spotifySetup
        snap.sonos = sonosSetup
        snap.crossfade = crossfade
    }

    /// Emits the current snapshot immediately, then again after every change. `includingWifi`
    /// adds the guest Wi‑Fi, for displays; `hostKey` adds hosts' details while it's valid.
    public func snapshots(includingWifi: Bool = false, hostKey: String? = nil) -> AsyncStream<PartySnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: PartySnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = (continuation, includingWifi, hostKey)
        let snap = snapshot(includingWifi: includingWifi, hostKey: hostKey)
        lastSentPlayback = snap.playback
        continuation.yield(snap)
        if remote == nil { startDriftCheck() }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeListener(id) }
        }
        return stream
    }

    /// With the last listener gone, so is the drift check (it starts again with the next).
    private func removeListener(_ id: UUID) {
        listeners[id] = nil
        guard listeners.isEmpty else { return }
        driftTask?.cancel()
        driftTask = nil
    }

    /// For tests: the drift check is running.
    var isCheckingDrift: Bool { driftTask != nil }

    // MARK: Internals

    /// Every real change counts the version up; one that changed nothing (a move to where the
    /// song already is, a lock already in place) isn't sent or saved. Staging is still checked:
    /// a stage that failed is retried on the next change, however small.
    @discardableResult
    private func mutate<Result>(_ body: (inout QueueState) -> Result) -> Result {
        let version = state.version
        let result = body(&state)
        if state.version != version {
            broadcast()
            scheduleSave()
        }
        Task { await syncStaging() }
        return result
    }

    private func play(_ item: QueueItem) async throws {
        stagedItemID = nil
        loadedItemID = item.id
        playerOnOldSong = false
        skippedToStagedID = nil
        awaitingAttach = false
        // A new song of ours: any staging for the old one is off.
        cancelStaging()
        let generation = generation
        do {
            try await timed("play") { try await self.engine.play(item.track) }
        } catch {
            // Nothing is loaded, so nothing gets staged behind it. Staging onto a player whose
            // play just failed can hang (Apple Music on tvOS reconnects on the main thread).
            loadedItemID = nil
            throw error
        }
        guard generation == self.generation else {
            // The zone ended, or a new playlist loaded, while the player was starting this song:
            // it isn't this session's to play, record, save or stage behind.
            engine.pause()
            if loadedItemID == item.id { loadedItemID = nil }
            return
        }
        isUnderWay = true
        onSongStarted?()
        recordPlayed(item)
        songStarted(item.id)
        isPlaying = engine.isPlaying
        if follower != nil {
            // The player is on our song now.
            externalCurrent = nil
            playerIssue = nil
            readPlayerQueueSoon()
        }
        broadcast()
        Task { await syncStaging() }
    }

    /// Plays `item` when nobody pressed Play (a skip's landing, the song before ending): if the
    /// player can't play it (unavailable, refused), the queue moves on to the next song rather
    /// than go quiet, and the host is told which were skipped. After `maxSongsFailingInARow` in
    /// a row the music stops, with an issue, until Play. Runs on the chain (`serially`).
    private func playMovingOn(_ item: QueueItem) async {
        var item = item
        var skipped: [QueueItem] = []
        let generation = generation
        while true {
            do {
                try await play(item)
                guard !skipped.isEmpty, generation == self.generation else { return }
                showSongFailure(skipped.count == 1 ? "Skipped “\(skipped[0].track.title)”, which couldn't play"
                                                   : "Skipped \(skipped.count) songs that couldn't play", until: item.id)
                return
            } catch {
                ErrorReport.log(error, context: "couldn't play \(item.track.title); moving on")
                // The session started over, or a tap moved the queue meanwhile: its landing plays.
                guard generation == self.generation, landingTimer == nil, landingPlays == nil,
                      state.current?.id == item.id else { return }
                skipped.append(item)
                guard skipped.count < Self.maxSongsFailingInARow else {
                    if engine.isPlaying { engine.pause() }
                    isPlaying = engine.isPlaying
                    showSongFailure("Stopped after \(skipped.count) songs in a row couldn't play", until: nil)
                    return
                }
                mutate { $0.advance() }
                guard let next = state.current else {
                    isPlaying = engine.isPlaying
                    broadcast()
                    return
                }
                item = next
            }
        }
    }

    private func showSongFailure(_ notice: String, until songID: UUID?) {
        playerIssue = notice
        showsSongFailure = true
        songFailureShownWith = songID
        broadcast()
    }

    /// A song started: a notice about songs that couldn't play before another one goes.
    private func songStarted(_ id: UUID) {
        guard showsSongFailure, id != songFailureShownWith else { return }
        showsSongFailure = false
        songFailureShownWith = nil
        playerIssue = nil
        broadcast()
    }

    /// Runs an operation on the engine in turn with the session's own (play, stage, skip), so
    /// neither sees the other half done: e.g. handing a Sonos group to another room while the
    /// next song is being queued. Hub only. No deadline: keep it to the player's own commands.
    public func withEngine<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let result: Result<T, any Error> = try await serially {
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Runs engine operations one at a time, in order. Overlapping operations (two quick backs,
    /// a skip while the next song is being staged) can wedge Apple's out-of-process player,
    /// which hangs the main thread. Never call this from inside an operation it's running.
    ///
    /// Throws only `CancellationError`, when the caller is cancelled while waiting (an HTTP
    /// handler past its timeout): it stops waiting, the operation still runs in its turn.
    private func serially<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async -> T) async throws -> T {
        let previous = engineChain
        pendingOperations += 1
        let task = Task<T, any Error> { @MainActor in
            await previous?.value
            defer { self.pendingOperations -= 1 }
            return await operation()
        }
        engineChain = Task { _ = try? await task.value }
        return try await Self.value(of: task)
    }

    /// One engine call with a deadline (`engineCallTimeout`). Past it the call counts as failed
    /// (`PlaybackEngineError.timedOut`): nothing is taken as staged any more (and the callers
    /// that play or resume forget the loaded song too), so the next command starts the player
    /// afresh rather than build on a call that never answered. The call itself is cancelled and
    /// left to finish on its own; its result no longer counts.
    private func timed<T: Sendable>(_ name: String, _ call: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let work = Task<T, any Error> { @MainActor in try await call() }
        let timeout = engineCallTimeout
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await Self.value(of: work) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw PlaybackEngineError.timedOut(operation: name)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as PlaybackEngineError {
            work.cancel()
            stagedItemID = nil
            ErrorReport.log(error, context: "engine.\(name) gave no answer in \(Int(timeout)) s")
            throw error
        }
    }

    /// `task.value`, except that a cancelled waiter stops waiting (`CancellationError`) while
    /// the task runs on. `Task.value` itself ignores cancellation, which kept HTTP handlers
    /// waiting on a stuck engine past their timeout (and the server's stop behind them).
    nonisolated static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let waiter = Waiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.begin(continuation)
                Task { waiter.finish(await task.result) }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private func handle(_ event: PlaybackEvent) {
        // The player may be playing again without the session having pressed Play.
        if engine.isPlaying { resumeTicker() }
        switch event {
        case .advancedToStaged:
            var id = skippedToStagedID ?? stagedItemID
            skippedToStagedID = nil
            if id == nil, let follower {
                // Staged but not yet confirmed (or confirmation failed and the song got there
                // anyway): the item the player is actually on.
                let playing = follower.playerTrackID
                id = (state.upNext.first { $0.id == state.lockedNextID && $0.track.id == playing }
                      ?? state.upNext.first { $0.track.id == playing })?.id
            }
            stagedItemID = nil
            if follower != nil {
                cancelStaging()
                externalCurrent = nil
                playerIssue = nil
            }
            if playerOnOldSong {
                // A skip or previous has already moved the queue. The player has caught up
                // with it (the landing's skip to the staged song), or the song before ended
                // into one the queue has left, and the landing plays the right one.
                guard let id, id == state.current?.id else {
                    loadedItemID = nil
                    return
                }
                playerOnOldSong = false
                broadcast()
                Task { await syncStaging() }
            } else {
                mutate { $0.advance(to: id) }
            }
            loadedItemID = state.current?.id
            if follower != nil { readPlayerQueueSoon() }
            // Nothing current (the zone ended as the player moved on): nothing started.
            guard let current = state.current else { return }
            isUnderWay = true
            onSongStarted?()
            recordPlayed(current)
            songStarted(current.id)
        case .reachedEnd:
            stagedItemID = nil
            loadedItemID = nil
            if follower != nil {
                cancelStaging()
                externalCurrent = nil
            }
            // The song before a skip or previous ended: the queue has already moved on, and
            // the landing plays its song.
            guard !playerOnOldSong else { return }
            mutate { $0.advance() }
            if let current = state.current {
                Task { try? await serially { await self.playMovingOn(current) } }
            }
        case .statusChanged:
            // After a relaunch, the followed player is found still on the restored song: it's
            // loaded, so Play resumes it rather than starting it over. Not a song a skip and a
            // previous came back to: that one starts over.
            if let follower, loadedItemID == nil, !playerOnOldSong, let current = state.current,
               follower.playerTrackID == current.track.id {
                loadedItemID = current.id
            }
            // Likewise an engine that attached to the restored song (a Sonos group still on it).
            // Its next song is then staged as usual (or found already there).
            if follower == nil, awaitingAttach, loadedItemID == nil, !playerOnOldSong, let current = state.current,
               engine.attachedTrackID == current.track.id {
                awaitingAttach = false
                loadedItemID = current.id
                Task { await syncStaging() }
            }
            isPlaying = engine.isPlaying
            broadcast()
        case .externalTrack(let track):
            guard follower != nil else { return }
            followExternal(track)
        }
    }

    // MARK: Follow mode (docs/multi-device.md)

    /// The player moved to a track that isn't ours (or back to ours, `nil`). Canopy's queue stays
    /// where it is: no advance, no play. A foreign track that plays goes in the party log with
    /// no requester.
    private func followExternal(_ track: QueueTrack?) {
        guard let track else {
            guard externalCurrent != nil else { return }
            externalCurrent = nil
            broadcast()
            readPlayerQueueSoon()
            return
        }
        guard externalCurrent?.track.id != track.id else { return }
        // The row it had in the player's queue becomes Now Playing.
        let item = foreignUpcoming.first { $0.track.id == track.id } ?? QueueItem(track: track, requester: nil)
        foreignUpcoming.removeAll { $0.id == item.id }
        externalCurrent = item
        recordPlayed(item)
        broadcast()
        readPlayerQueueSoon()
    }

    /// Calls off the staging run in flight (our song changed, the zone ended or started over).
    private func cancelStaging() {
        stagingRun += 1
        stagingTask = nil
        stagedConfirmed = false
        gaveUpStaging = false
    }

    private func resetFollow(keepPlayerQueue: Bool) {
        cancelStaging()
        externalCurrent = nil
        playerIssue = nil
        showsSongFailure = false
        if !keepPlayerQueue { foreignUpcoming = [] }
    }

    private func followLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[follow] \(message())")
        #endif
    }

    /// Reads the player's queue, updates the foreign songs shown above Up next, and says whether
    /// `confirming` (default: the staged item) is in it; nil when the queue couldn't be read.
    /// Called when the track changes, right after staging, and for the confirmation before the
    /// end; never on a timer. A staged song that has gone from the queue (someone cleared it, a
    /// new context) is staged again, under the same rules.
    @discardableResult
    private func refreshPlayerQueue(confirming: QueueItem? = nil) async -> Bool? {
        guard let follower else { return nil }
        let generation = generation
        let queue: [QueueTrack]
        do {
            queue = try await follower.fetchPlayerQueue()
        } catch {
            followLog("couldn't read the player's queue: \(error)")
            return nil
        }
        guard generation == self.generation else { return nil }
        let target = confirming ?? state.upNext.first { $0.id == stagedItemID }
            ?? state.upNext.first { $0.id == state.lockedNextID }
        // Songs Canopy played or is playing: Spotify replays them after its queue (repeat).
        var ours = Set(state.history.map(\.track.id))
        if let current = state.current { ours.insert(current.track.id) }
        let (foreign, queued) = FollowRules.foreignUpcoming(in: queue, staged: target?.track.id, ours: ours)
        setForeignUpcoming(foreign)
        if confirming == nil, stagedConfirmed, !queued, let staged = target, stagingTask == nil,
           follower.playerTrackID != staged.track.id {
            followLog("\(staged.track.title) has gone from the player's queue; staging it again")
            stagedItemID = nil
            stagedConfirmed = false
            startStaging(staged.id)
        }
        return queued
    }

    private func readPlayerQueueSoon() {
        Task { await refreshPlayerQueue(confirming: nil) }
    }

    /// The player's foreign songs, keeping each one's row ID while it stays (so rows don't
    /// rebuild or jump on every read).
    private func setForeignUpcoming(_ tracks: [QueueTrack]) {
        var pool = foreignUpcoming
        let items = tracks.map { track in
            if let index = pool.firstIndex(where: { $0.track.id == track.id }) { return pool.remove(at: index) }
            return QueueItem(track: track, requester: nil)
        }
        guard items != foreignUpcoming else { return }
        foreignUpcoming = items
        broadcast()
    }

    /// Seconds left in what the player is playing (ours or not); nil when unknown.
    private var playerRemaining: TimeInterval? {
        guard let duration = follower?.playerDuration else { return nil }
        return duration - engine.currentTime
    }

    /// Once a second: lock and stage the next song `lead` seconds before our song ends. Only while
    /// the player is on our current song (its URI, not just the session's idea of it), timed by
    /// the player's own position and length: right after a song change the position can still
    /// be the last song's, which locked the next song at the start of a track.
    private func followTick() {
        guard let follower, stagingTask == nil, !gaveUpStaging, stagedItemID == nil, externalCurrent == nil,
              let current = state.current, loadedItemID == current.id,
              follower.playerTrackID == current.track.id,
              let duration = follower.playerDuration ?? current.track.duration,
              duration - engine.currentTime < followTiming.lead,
              let first = state.upNext.first else { return }
        startStaging(first.id)
    }

    private func startStaging(_ id: UUID) {
        stagingRun += 1
        let run = stagingRun
        if state.lockedNextID != id, state.upNext.first?.id == id { mutate { $0.lockNext() } }
        stagingTask = Task { [weak self] in
            await self?.runStaging(firstID: id, run: run)
            if let self, self.stagingRun == run { self.stagingTask = nil }
        }
    }

    private func isCurrent(_ run: Int, _ generation: Int) -> Bool {
        stagingRun == run && self.generation == generation
    }

    /// The staging state machine: stage the locked song (retrying), confirm it's in the player's
    /// queue by `confirmBy` seconds before the end; else lock the song below it and do the same
    /// (by `fallbackConfirmBy`); else give up for this track and say so.
    private func runStaging(firstID: UUID, run: Int) async {
        let generation = generation
        guard let first = state.upNext.first(where: { $0.id == firstID }) else { return }
        if await attempt(first, confirmBy: followTiming.confirmBy, run: run, generation: generation) { return }
        guard isCurrent(run, generation) else { return }
        guard let next = mutate({ $0.lockInstead(of: firstID) }) else {
            giveUpStaging([first])
            return
        }
        followLog("\(first.track.title) isn't in the player's queue; trying \(next.track.title) instead")
        if await attempt(next, confirmBy: followTiming.fallbackConfirmBy, run: run, generation: generation) { return }
        guard isCurrent(run, generation) else { return }
        giveUpStaging([first, next])
    }

    /// Stages `item` and confirms it. True once it's confirmed.
    private func attempt(_ item: QueueItem, confirmBy: TimeInterval, run: Int, generation: Int) async -> Bool {
        let posted = await stageWithRetries(item, run: run, generation: generation)
        guard isCurrent(run, generation) else { return false }
        if posted, await refreshPlayerQueue(confirming: item) ?? true {
            // Seen in the queue (or the player took it and its queue couldn't be read).
            return confirmStaged(item, run: run, generation: generation)
        }
        guard isCurrent(run, generation) else { return false }
        // Not seen yet: look again by `confirmBy` seconds before the end.
        while isCurrent(run, generation), let remaining = playerRemaining, remaining > confirmBy {
            try? await Task.sleep(for: .seconds(followTiming.tick))
        }
        guard isCurrent(run, generation) else { return false }
        if await refreshPlayerQueue(confirming: item) ?? posted {
            return confirmStaged(item, run: run, generation: generation)
        }
        followLog("\(item.track.title) isn't in the player's queue \(Int(confirmBy)) s before the end")
        return false
    }

    private func confirmStaged(_ item: QueueItem, run: Int, generation: Int) -> Bool {
        guard isCurrent(run, generation) else { return false }
        stagedItemID = item.id
        stagedConfirmed = true
        // Not the notice about songs that couldn't play: it lasts the song.
        if playerIssue != nil, !showsSongFailure { playerIssue = nil; broadcast() }
        followLog("\(item.track.title) is in the player's queue")
        return true
    }

    /// Hands `item` to the player, retrying after each of `retryDelays`. True when it took it.
    private func stageWithRetries(_ item: QueueItem, run: Int, generation: Int) async -> Bool {
        for (attempt, delay) in ([0] + followTiming.retryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard isCurrent(run, generation) else { return false }
            let took = (try? await serially { () -> Bool in
                guard self.isCurrent(run, generation) else { return false }
                do {
                    try await self.timed("stage") { try await self.engine.stage(item.track) }
                    return true
                } catch {
                    self.followLog("stage \(item.track.title) failed (try \(attempt + 1)): \(error)")
                    return false
                }
            }) ?? false
            if took { return true }
        }
        return false
    }

    /// Neither song could be queued on the player: stop trying for this track, log it, and tell
    /// the host. The player then does whatever it does next, and is followed.
    private func giveUpStaging(_ tried: [QueueItem]) {
        gaveUpStaging = true
        stagedItemID = nil
        stagedConfirmed = false
        mutate { $0.unlockNext() }
        showsSongFailure = false
        playerIssue = "Couldn't queue the next song on \(serviceName ?? "the player")"
        let error = FollowStagingError(titles: tried.map(\.track.title))
        ErrorReport.log(error, context: "follow: gave up staging; the player picks what plays next")
        followLog("gave up: \(error.localizedDescription)")
        broadcast()
        // The player keeps what it has; we just stop expecting our song there.
        Task { try? await serially { try? await self.timed("stage") { try await self.engine.stage(nil) } } }
    }

    #if DEBUG
    /// `-fakeSpotifyFollow` (debug builds): poses follow mode's state on any engine, so the UI can
    /// be seen without Spotify: a foreign track playing, the player's own queue, and our next song
    /// locked; or, with `issue`, the host's issue line (and nothing locked, as after giving up).
    /// `-fakeSpotifyFollow` on an iPad or Apple TV hub: a track from outside the queue playing
    /// ("From Spotify"), two songs in Spotify's own queue, and the next song locked; `issue` shows
    /// the host's "Couldn't queue" line instead of the lock.
    public func debugPoseSpotifyFollow(issue: Bool) {
        let colors = { (bg: String, sec: String) in ArtworkColors(background: bg, primary: "#FFFFFF", secondary: sec) }
        let external = QueueTrack(id: "spotify:track:fake-external", title: "Espresso", artist: "Sabrina Carpenter",
                                  album: "Short n' Sweet", duration: 175, colors: colors("#5A3A1E", "#E8B07A"))
        let foreign = [
            QueueTrack(id: "spotify:track:fake-q1", title: "Good Luck, Babe!", artist: "Chappell Roan", duration: 218, colors: colors("#7A1F3D", "#F29BB8")),
            QueueTrack(id: "spotify:track:fake-q2", title: "Birds of a Feather", artist: "Billie Eilish", duration: 210, colors: colors("#1E3A5A", "#8CB8E8")),
        ]
        serviceName = "Spotify"
        debugPoseFollow(external: external, foreign: foreign, issue: issue ? "Couldn't queue the next song on Spotify" : nil)
    }

    public func debugPoseFollow(external: QueueTrack?, foreign: [QueueTrack], issue: String? = nil) {
        guard remote == nil else { return }
        if externalCurrent?.track.id != external?.id {
            externalCurrent = external.map { QueueItem(track: $0, requester: nil) }
        }
        setForeignUpcoming(foreign)
        playerIssue = issue
        if issue == nil, state.lockedNextID == nil, !state.upNext.isEmpty { mutate { $0.lockNext() } } else { broadcast() }
    }
    #endif

    /// Makes the engine's staged track match the queue. Calls are coalesced so only one runs at a time.
    func syncStaging() async {
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while needsSync {
            needsSync = false
            try? await serially { await self.stageIfNeeded() }
        }
    }

    /// Makes the engine's staged track match `upNext.first` (or the locked item).
    private func stageIfNeeded() async {
        // Only stage behind a song the engine actually has loaded. A followed player is staged
        // by its own state machine (`followTick`).
        guard follower == nil, let current = state.current, loadedItemID == current.id else { return }
        let desired: QueueItem?
        if engine.canReplaceStaged {
            desired = state.upNext.first
        } else {
            // Late staging: only stage once the ticker has locked the next item.
            guard stagedItemID == nil, let locked = state.lockedNextID,
                  let first = state.upNext.first, first.id == locked else { return }
            desired = first
        }
        guard desired?.id != stagedItemID else { return }
        let generation = generation
        do {
            try await timed("stage") { try await self.engine.stage(desired?.track) }
            // Staged into a session that has since started over: not this queue's next song.
            guard generation == self.generation else { return }
            stagedItemID = desired?.id
        } catch {
            // Leave stagedItemID alone (a timeout has cleared it); the next change retries, and
            // `.reachedEnd` covers a miss.
        }
    }

    /// The engine stages late (it can't replace a staged song): the ticker runs while music plays.
    private func startLateStagingTicker() {
        wantsTicker = true
        tickTask?.cancel()
        tickTask = nil
        resumeTicker()
    }

    /// Starts the ticker if it's wanted and stopped. Paused, nothing it watches moves (the
    /// position stands still), so it stops then; it starts again with the music, or with any
    /// news from the player (another app on the account playing).
    private func resumeTicker() {
        guard wantsTicker, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.followTiming.tick ?? 1))
                guard !Task.isCancelled, let self else { return }
                guard self.isPlaying || self.engine.isPlaying else {
                    self.tickTask = nil
                    return
                }
                if self.follower != nil {
                    self.followTick()
                    continue
                }
                // `position`: not the time of a song the player hasn't left yet.
                guard self.stagedItemID == nil, let duration = self.state.current?.track.duration,
                      duration - self.position < Self.lateStageLead,
                      !self.state.upNext.isEmpty else { continue }
                self.mutate { $0.lockNext() }
            }
        }
    }

    private func broadcast() {
        guard !listeners.isEmpty else { return }
        let snap = snapshot()
        lastSentPlayback = snap.playback
        for listener in listeners.values {
            var sent = snap
            if listener.withWifi { sent.wifi = wifi }
            if isHostKey(listener.hostKey) { addHostDetails(to: &sent) }
            listener.continuation.yield(sent)
        }
    }

    /// Listeners work out the playback time from the last snapshot, but the player's time also
    /// moves without an event: a song starts only once it has buffered, a seek lands late, or the
    /// system seeks. So while anyone is listening, resend when the real time has drifted. With
    /// nobody listening it stops (`removeListener`), and the next listener starts it again.
    private func startDriftCheck() {
        guard driftTask == nil else { return }
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard !self.listeners.isEmpty else {
                    self.driftTask = nil
                    return
                }
                guard let sent = self.lastSentPlayback else { continue }
                let expected = sent.isPlaying ? sent.position + Date().timeIntervalSince(sent.capturedAt) : sent.position
                if sent.isPlaying != self.engine.isPlaying || abs(self.position - expected) > Self.driftTolerance {
                    self.broadcast()
                }
            }
        }
    }

    private func scheduleSave() {
        guard let storeURL else { return }
        saveTask?.cancel()
        saveTask = Task { [state] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

/// A continuation resumed exactly once, by whichever comes first: the task's result or the
/// waiter's cancellation (`PartySession.value(of:)`).
private final class Waiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?

    func begin(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
