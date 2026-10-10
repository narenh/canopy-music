# CanopyMusic — Plan

iPad party jukebox built on MusicKit. Runs in Guided Access at home. Guests search all of Apple Music and queue songs on top of a host-chosen base playlist, either on the iPad or from their own phones via QR code.

## Decisions

| Topic | Decision |
|---|---|
| Player | `ApplicationMusicPlayer` (app-owned queue). Fallback: `SystemMusicPlayer` if multi-speaker AirPlay fails (spike 2). |
| Catalog | Full Apple Music catalog for guests (iPad's subscription does the work). |
| Queue model | One list. Requests and playlist songs are tagged items, not separate sections. Anything can be dragged anywhere. |
| Who reorders | Everyone: host, guests on iPad, guests on phones. |
| Request placement | First come, first served, ahead of the remaining playlist (see placement rule below). |
| End of playlist | Loop (same order, or the same shuffled order if shuffle is on). |
| Orientation | Landscape only. |
| Abuse controls | None. Home use. |
| Phone queueing | HTTP + WebSocket server on the iPad, LAN only. No cloud. |
| Platform | iPadOS 26+, Liquid Glass UI, dark theme tinted from the current album art (iPad and phones). Canopy logo. |
| Phone identity | Optional name prompt with Skip. Phones can remove only their own requests. |
| Phone URL | QR code uses the IP. Also tries port 80 and `canopymusic.local` (mDNS) for a typeable URL. |
| Staging | `ApplicationMusicPlayer.Queue.entries` is mutable in the SDK, so Apple Music stages early and swaps the staged song. Late staging + lock remains as the fallback path. |
| Providers | Apple Music only for now. Code sits behind a provider seam so Spotify can be added later, chosen once at setup. Never mixed. |

## Queue engine

The app's own model is the source of truth. The player only holds **current + one staged next item**.

```
history:  [played items…]
current:  Item
upNext:   [Item]            // single ordered list, what the UI shows
Item { id: UUID, song: Song, source: .playlist | .request(origin: .ipad | .phone), autoPlaced: Bool }
```

**Request placement rule:** a new request goes immediately after the last request with `autoPlaced == true`, or at the top of `upNext` if there isn't one. Dragging an item sets `autoPlaced = false`, so it stays where someone put it and no longer acts as the anchor. This keeps requests FIFO while letting manual moves stick.

**Dedupe:** when a request matches a playlist item later in `upNext` (same song ID), remove that playlist item.

**Loop:** playlist items are added to `upNext` one cycle at a time. When fewer than about 10 playlist items are left, append the next cycle.

**Staging:** on every `currentEntry` change, stage `upNext[0]`. If an edit changes `upNext[0]` while something is already staged, replace the staged entry. Spike 1 decides how:
- If in-place queue mutation works: remove the staged entry and insert the new one.
- Otherwise, stage late (about 15–20 s before the current track ends) and show the next item as locked once it's staged.

**Edits are operations on IDs, not indices:** `add(song, origin)`, `move(id, after: id?)`, `remove(id)`, `skip`. The iPad applies them one at a time, bumps `version`, and broadcasts the full state. This handles a phone and the iPad dragging at the same moment without index drift.

**Persistence:** save the queue state to disk on every change and restore it on launch.

## Provider seam (Spotify-ready, not Spotify-built)

The queue engine, UI, and phone server never import MusicKit. They only see:

```swift
struct Track { let id: ProviderTrackID; let title, artist, album: String
               let artworkURL: URL?; let duration: TimeInterval; let isExplicit: Bool }

protocol MusicCatalog {          // search + playlists
  func authorize() async throws
  func search(_ query: String) async throws -> [Track]
  func playlists() async throws -> [PlaylistSummary]
  func tracks(in: PlaylistSummary) async throws -> [Track]
}

protocol PlaybackEngine {        // owns *when* to stage; pulls from the queue model
  var events: AsyncStream<PlaybackEvent> { get }   // started(id), progress, ended, paused
  var canReplaceStaged: Bool { get }
  func play(_ track: Track) async throws           // start immediately
  func stage(_ track: Track) async throws          // set the one "next" item
  func pause() async; func resume() async; func skip() async
}
```

- The engine decides when to stage and calls `queue.lockNext()` when it commits. Engines that can replace the staged item stage early and never lock. Others stage late and show a lock in the UI. The queue model doesn't care which.
- The lowest common denominator the queue needs from any provider: play a track now, add one track after the current one, and report progress/track changes. Spotify has all three.
- Each provider supplies its own speaker picker: `AVRoutePickerView` for Apple Music, likely a Spotify Connect device list for Spotify.
- Saved queue state records the provider. Switching providers clears the queue.

**Spotify risks (for later, not solved now):**
- Playback happens in Spotify's app or a Connect device, not in-process. Their queue API can add but not remove or reorder, so Spotify always stages late.
- The App Remote SDK connects by switching to the Spotify app, which Guided Access blocks, and it's known to drop connections. Driving playback through the Web API with polling for position avoids that.
- Multi-speaker AirPlay 2 from Spotify on iOS has historically been poor. Spotify Connect speakers may be the realistic route.
- Requires Premium. Spotify's developer-mode/quota rules have tightened, though a personal-use app should be fine. Re-check when the time comes.

## Host mode

1. Request MusicKit authorization.
2. Pick the base playlist (library playlists via `MusicLibraryRequest<Playlist>`, plus Apple Music playlist search). Shuffle toggle.
3. Pick speakers with `AVRoutePickerView`. Apps can't select specific speakers programmatically, so this is the system sheet.
4. Press Lock: host controls are hidden, and the app prompts you to triple-click for Guided Access (checked with `UIAccessibility.isGuidedAccessEnabled`).
5. Unlock: hidden gesture plus PIN gives back host controls (skip, change playlist, speakers).

## Locked UI (landscape)

```
┌───────────────────────────────┬─────────────────────┐
│ 🔍  Search Apple Music…       │  Up Next            │
├───────────────────────────────┤  1. Song X  ★       │
│                               │  2. Song 15         │
│        [ album art ]          │  3. Song Y  ★       │
│                               │  …  (drag to move)  │
│   Title — Artist   ━━━━○──    │  ┌───────┐ Queue    │
│                               │  │  QR   │ from     │
│                               │  └───────┘ phone    │
└───────────────────────────────┴─────────────────────┘
```

- Search results cover the left pane. The Up Next column stays visible the whole time.
- `isIdleTimerDisabled = true`.

### "Add" animation (iPad)

1. Tapping Add captures the result row's frame (anchor preference) and computes the target slot from the placement rule.
2. If the slot is off-screen, scroll Up Next to it first (`ScrollViewReader.scrollTo`).
3. Up Next opens a gap at the slot with a spring animation. At the same time, a floating copy of the row (artwork + title) lifts slightly, shrinks, and flies along a curved path into the gap.
4. On arrival the copy cross-fades into the real row, which pulses once with a highlight.
5. Search stays open for more adds. A small "Added · #3 in queue" confirmation appears.
6. Adds from a phone: the row slides into its slot with the same highlight pulse and a small phone badge.
7. Reduce Motion: skip the flight and use a cross-fade plus highlight.

Implementation note: SwiftUI `List` gives built-in reordering but little control over insert animations. A `ScrollView` + `LazyVStack` with custom drag-to-reorder gives full control. Decide during the UI phase, likely the custom approach.

## Phone queueing (QR)

- The iPad runs a small server (FlyingFox: async/await, WebSockets) on the LAN. The QR code encodes `http://<ipad-ip>:<port>`, regenerated when the IP changes.
- A second QR code joins the Wi-Fi: `WIFI:T:WPA;S:<ssid>;P:<pass>;;` (entered in host mode).
- API: `GET /search?q=` (the iPad proxies `MusicCatalogSearchRequest`), plus the queue operations above. A WebSocket pushes `{version, current, upNext}`.
- Web page: search, add, live now-playing + queue, drag to reorder (SortableJS or similar). Album art loads directly from Apple's artwork URLs.
- Needs `NSLocalNetworkUsageDescription`.
- Limitation: guests must be on home Wi-Fi.

## Build order

1. **Spikes on device, throwaway code:**
   1. Queue mutation: can a staged `ApplicationMusicPlayer` entry be removed or replaced reliably?
   2. Multi-speaker AirPlay 2 with `ApplicationMusicPlayer` (2–3 speakers). **Do this first; it's the most likely to force a change.**
   3. LAN server on the iPad reachable from a phone, with search proxy working.
2. Queue engine as a plain Swift model on `Track`, unit-tested with a fake `PlaybackEngine`, no audio needed.
3. Host mode.
4. Locked UI + add animation + reordering.
5. Phone web app + live sync.
