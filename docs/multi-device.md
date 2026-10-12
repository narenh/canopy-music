# Multi-device Canopy Music: zones

Status: built on the `tvos-spike` branch (see "Build status" at the end). Screens: [multi-device-mockups.html](multi-device-mockups.html).

## Model

- A **zone** is one queue playing in one place. Usually a home has one zone; a big house might have Upstairs and Downstairs.
- Each zone has exactly one **hub**: the iPad or Apple TV that plays the music. The hub owns the queue, the base playlist, the speakers, the settings and the guest web server.
- Every other Canopy Music device that opens the zone is a **display**.
- Phones use the web page: guests always, hosts with Host Control.

### Who can do what

| | Hub (iPad) | Web page, Host Control | Web page, guest | Display iPad | Display TV |
|---|---|---|---|---|---|
| Search and add | ✓ | ✓ | ✓ | ✓ | |
| Reorder | ✓ | ✓ | if *Reorder from phones* | if *Reorder from phones* | |
| Play/pause, skip, scrub | ✓ | ✓ (no scrub) | | if *Playback controls on displays* | remote play/pause if that setting is on |
| Delete anything | ✓ | ✓ | own requests | | |
| Base playlist, settings | ✓ (host mode) | ✓ | | | |

- *Playback controls on displays* is a new hub setting, on by default.
- Displays have no admin at all. Long-pressing the logo (iPad), or Menu (TV), only offers **Leave**.

## What each hub can do

"Web" is the host page on a phone with Host Control: the admin view for every hub, and the only one an Apple TV has.

| Feature | iPad hub | Apple TV hub |
|---|---|---|
| **Music** | | |
| Apple Music | ✓ | ✓ |
| Spotify | ✓ | — |
| Crossfade | ✓ (Apple Music) | — (not on tvOS) |
| Choose speakers (AirPlay) | ✓ | — (the TV's own audio settings) |
| Spotify playback device | ✓ | — |
| **Zone setup** | | |
| Create a zone | iPad: name, PIN, service | TV: Scan to host, then web: name, playlist |
| Zone name | iPad, web | web |
| Base playlist | iPad, web | web |
| Unlock PIN | iPad settings (only on the iPad, not the web) | — |
| `.local` address | follows the zone name | follows the zone name |
| End the zone | iPad host mode (top, and in settings), web (both ask first) | Menu on the remote, web (web asks first) |
| Resume after relaunch | Resume row | create again (the queue is restored) |
| **Guests** | | |
| Guest QR code on the party screen | ✓ | ✓ |
| Queue from phones | iPad, web | web |
| Reorder from phones | iPad, web | web |
| Wi‑Fi join QR code | iPad, web | web |
| **Hosts** | | |
| Host Control QR code | iPad settings | Scan to host screen |
| Add another host | iPad settings, web | web |
| Forget other hosts | iPad, web | web |
| Play/pause, skip | iPad, web | web, remote's Play/Pause |
| Scrub | iPad | — |
| Reorder, delete anything | iPad, web | web |
| Search and add on the hub itself | ✓ | — (no keyboard UI) |
| **Displays** | | |
| Playback controls on displays | iPad, web | web |
| List of connected displays | iPad host mode, web | web |
| **Other** | | |
| Lock the party screen | press and hold the logo (+ Guided Access) | — |
| Keeps the screen awake | ✓ | ✓ |

## Launch flow (every device, every time)

1. **The zone list:** "Zones on this Wi‑Fi". It always shows, even with one zone or none (with none, the heading hides). There's no auto-join.
2. **Choosing a zone** opens it as a display, straight to the party screen. No PIN: a display can't do anything a guest's phone can't.
3. **Create a new zone** makes this device the hub:
   - **iPad:** name the zone (defaults to the device name), set an optional host PIN ("Skip" allowed), then choose the service if one isn't set up yet, then host mode as today.
   - **Apple TV:** straight to **Scan to host**. The first phone to scan gets Host Control and sets the zone up on the web page: name and base playlist. A TV hub has no settings screens; Menu only offers **End <zone>**. Apple Music only.

## Network

- **Discovery:** hubs advertise Bonjour `_canopymusic._tcp`. The TXT record carries the zone name, the hub kind (ipad/tv), what's playing and the guest address. Displays browse for it; the list updates live.
- **Addresses:** each hub announces a `.local` name made from its zone name ("Living Room" is `living-room.local`; `music.local` if nothing's left), then `living-room-2.local`… on a clash. A clash with the device's own name doesn't count: an Apple TV called "Living Room" is already `Living-Room.local`, so when the taken name resolves to one of this device's own addresses, the zone uses it as it is. It's handed out only once mDNS confirms it. Renaming the zone (iPad or web) announces the new name, and a web page on the old name moves to the new one, keeping the phone's ID, name and Host Control. Simulator builds use `canopytest-<zone>.local`, so tests never take real names. Every QR code points at its own hub.
- **Displays** use the same JSON API and WebSocket snapshots as the guest page, plus a few display endpoints:
  - `POST /api/display/hello`: a heartbeat, so the hub can list connected displays.
  - `POST /api/display/playback`: allowed while *Playback controls on displays* is on.
- **Up next** has 100 live songs (in snapshots: draggable, removable). Below them the same list carries on, read-only (no handle or remove, nothing can be dropped there), with the rest of the base playlist's current cycle, from `GET /api/upcoming?offset=&limit=` (compact rows, 100 at most per page). The web page and iPads (hub or display) load 50 more as the end comes into view, and fetch the rows shown again when the queue moves on, so a song simply gains its handle when it becomes live. The Apple TV shows only the rows that fit. The web page only rebuilds rows that changed, animates only rows on screen, and loads row artwork lazily.
- **Hosts on the web** get new endpoints, all requiring the host key:
  - `GET /api/host/playlists`: the hub's library. The web picker (Change base playlist, and a TV zone's first setup) filters it as you type, ignoring case and accents.
  - `GET /api/host/playlists/search?q=`: the music service's playlists, shown below the library matches while typing (as on the iPad; not for Spotify).
  - `POST /api/host/playlist`: load a base playlist. Answers with how many of its songs were left out (not on the music service, e.g. iTunes Match uploads with no catalog match) and the first few titles. Snapshots carry the same (`skippedOnLoad`, `skippedTitles`) until another playlist loads: the iPad shows "3 songs aren't on Apple Music" under the base playlist (tap for the list), the web settings sheet shows it under Base playlist, and an Apple TV's host also gets it once as a toast. Debug builds' demo library has "Road trip", which leaves 4 out.
  - `POST /api/host/settings`: zone name, queue and reorder from phones, display controls, Wi‑Fi; any subset (the web sheet saves each change as it's made). Not the iPad's unlock PIN, which is set only on the iPad.
  - `GET /api/host/details`: the Wi‑Fi details and the connected displays. The Wi‑Fi password is never in the snapshots guests get.
  - `POST /api/host/stop`: ends the zone (any hub). The page asks first.
  - `GET /api/host/invite.png`: the "Add another host" QR, rendered by the hub.
- **Host keys are kept per hub:** snapshots carry the hub's device ID (`hubID`), and the page keeps one key per hub. A hub that refuses a key only drops its own, so a phone that's a host of two zones (or of a zone whose address another hub later takes) stays a host of both. Keys move along with the phone's ID and name when the page moves to the friendly address.
- **If a hub disappears,** displays show "Lost connection to <zone>" and keep retrying. The queue is saved on the hub.

## Decisions taken while building (review)

- **"Resume" row:** an iPad that was a hub last time shows its own zone first in the list ("Resume Upstairs"), so relaunching after a crash is one tap.
- **"Queue from phones" isn't offered on a TV hub,** since the web page is how a TV zone is run.
- **Displays add songs as "<zone display name>"** (e.g. "Kitchen iPad"), so the requester pill shows where a song came from. Displays can't delete, including songs they added.
- **The device-name default needs Apple's user-assigned-device-name entitlement** on iOS 16 and later. Until it's granted, the default is "iPad" / "Apple TV".

- **TV hubs use demo songs in the simulator,** since the simulator can't play Apple Music. On a real Apple TV they use Apple Music and ask for access when you create a zone.
- **The TV's zone name defaults to the Apple TV's device name.** The first host can change it on the setup page.

## Build status

**Working and checked (two iPad simulators, an Apple TV simulator, an iPhone simulator's Safari):**
- **iPad:** the zone list; an iPad hub announcing its zone; another iPad joining as a display, with the hub's live queue and progress, prev/play/next without AirPlay or crossfade, and its QR pointing at the hub.
- **Apple TV:** the zone list finding the iPad's zone; showing it as a display with the zone badge; creating a zone; "Scan to host"; first-host setup from the web API (name and playlist), after which the TV plays and announces the renamed zone.
- **Web:** the host page with the base playlist row; the invite QR (rendered by the hub); the playlists endpoint.
- **Package tests:** display mirroring, adding with the display's ID, refused moves undone, display controls following the hub setting, port fallback.

**Not tested yet:**
- **The iPad's "Create a new zone" screens** (name, PIN): built, but not tapped through. The simulator can't be tapped from here.
- **Leaving a zone and the lost-connection overlay** (iPad and TV): built, but not seen.
- **Moving to `music-2.local` on a name clash:** simulators share the Mac's IP address, which mDNS doesn't treat as a clash. Needs two real devices.
- **Pressing Menu and Play/Pause on the Siri Remote** (now handled; not yet confirmed on the remote).

**Apple TV and Apple Music (found on a real Apple TV, 12 Oct 2026):**
- The TV app shares the iPad's bundle ID (`com.canopysf.CanopyMusic`). That's required for one App Store listing across iPad and Apple TV, and the separate `com.canopysf.CanopyTV` ID had no MusicKit service, so every Apple Music request failed.
- Library playlists' songs are fetched fresh from the catalog on tvOS. The catalog songs that come with library tracks can't start a fresh player there: the player connection drops and the app hangs. Verified on Living Room with two playlists.
- **A failed play no longer freezes the app.** After a failed play the session still counted the song as loaded, so it staged the next song onto the broken player, and Apple's player then blocked the main thread for 30 seconds or more (2 of 5 runs). A failed play now leaves nothing loaded. Verified on Living Room: 8 of 8 forced failures stayed responsive.
- The TV's debug-only `-playTest` screen plays Apple Music without the rest of the app, for telling Apple bugs from ours.
- **The web page's setup sheet, settings and invite modals** in a real phone browser (only the API behind them was exercised).
