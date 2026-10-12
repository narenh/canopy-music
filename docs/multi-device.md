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

## Launch flow (every device, every time)

1. **The zone list:** "Zones on this Wi‑Fi". It always shows, even with one zone or none (with none, the heading hides). There's no auto-join.
2. **Choosing a zone** opens it as a display, straight to the party screen. No PIN: a display can't do anything a guest's phone can't.
3. **Create a new zone** makes this device the hub:
   - **iPad:** name the zone (defaults to the device name), set an optional host PIN ("Skip" allowed), then choose the service if one isn't set up yet, then host mode as today.
   - **Apple TV:** straight to **Scan to host**. The first phone to scan gets Host Control and sets the zone up on the web page: name and base playlist. A TV hub has no settings screens; Menu only offers **Stop <zone>**. Apple Music only.

## Network

- **Discovery:** hubs advertise Bonjour `_canopy._tcp`. The TXT record carries the zone name, the hub kind (ipad/tv), what's playing and the guest address. Displays browse for it; the list updates live.
- **Addresses:** each hub announces its own `.local` name (`music.local`, then `music-2.local`… on a clash). Every QR code points at its own hub.
- **Displays** use the same JSON API and WebSocket snapshots as the guest page, plus a few display endpoints:
  - `POST /api/display/hello`: a heartbeat, so the hub can list connected displays.
  - `POST /api/display/playback`: allowed while *Playback controls on displays* is on.
- **Hosts on the web** get new endpoints, all requiring the host key:
  - `GET /api/host/playlists`: the hub's library.
  - `POST /api/host/playlist`: load a base playlist.
  - `POST /api/host/settings`: zone name, reorder, display controls.
  - `POST /api/host/stop`: TV hubs.
  - `GET /api/host/invite.png`: the "Add another host" QR, rendered by the hub.
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
- **Real Apple Music on an Apple TV.**
- **Pressing Menu and Play/Pause on the Siri Remote.**
- **The web page's setup sheet, settings and invite modals** in a real phone browser (only the API behind them was exercised).
