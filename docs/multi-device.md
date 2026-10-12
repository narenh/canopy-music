# Multi-device Canopy Music: zones

Status: being built on the `tvos-spike` branch. Screens: [multi-device-mockups.html](multi-device-mockups.html).

## Model

- A **zone** is one queue playing in one place. Usually a home has one zone; a big house might have Upstairs and Downstairs.
- Each zone has exactly one **hub**: the iPad or Apple TV that plays the music. The hub owns the queue, the base playlist, the speakers, the settings and the guest web server.
- Every other Canopy device that opens the zone is a **display**.
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
