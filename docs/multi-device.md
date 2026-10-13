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
| Save the party as a playlist | when ending (iPad, web), iPad settings, web settings | Menu › End, web |
| Back after a crash or a quit by the system (no End) | by itself, locked if it was | by itself |
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
| Keeps the screen awake | ✓ (always) | while music plays (hub and TV displays); the screensaver may come on when paused, and with *Allow screensaver while playing* (web, off by default) during music too, for OLED screens |

## Launch flow

0. **A hub whose zone wasn't ended** (the app crashed, or the system quit it) goes straight back into its zone: the queue, the guest server, the Bonjour announcement and the `.local` name come back, so displays and phones reconnect by themselves. The music stays paused until someone presses play. An iPad comes back in the mode it was in: locked if the party screen was locked (so host mode stays behind the PIN), host mode if it was in host mode. An Apple TV comes back to its party screen, with the same Host Control key, if its zone was set up (a playlist was loaded). A TV zone that was never set up (even if a phone had scanned) is ended at launch, as End does, and the TV starts at the zone list: its code had gone, so nothing could have controlled it. Resumed from the list instead (when it couldn't come back by itself), such a zone goes back to Scan to host, with its code. A device that was showing someone else's zone starts at the zone list. If the zone can't come back (no Apple Music access, Spotify signed out, no network), the zone list shows it as a Resume row.
1. **The zone list:** "Zones on this Wi‑Fi". It always shows otherwise, even with one zone or none (with none, the heading hides). There's no auto-join.
2. **Choosing a zone** opens it as a display, straight to the party screen. No PIN: a display can't do anything a guest's phone can't.
3. **Create a new zone** makes this device the hub:
   - **iPad:** name the zone (defaults to the device name), set an optional host PIN ("Skip" allowed), then choose the service if one isn't set up yet, then host mode as today.
   - A new zone always starts empty. If this device still has a zone (the Resume row), it asks first ("This ends Upstairs and clears its queue."), and ends it, as End does, once the new zone is created. Resume is the way back to the old one.
   - **Apple TV:** straight to **Scan to host**. The first phone to scan gets Host Control and sets the zone up on the web page, in one sheet: their own name (optional, in place of the usual name prompt), the zone name and the base playlist. If another host starts the zone first, the usual name prompt shows then. Once a phone has scanned, the TV says "Continue on your phone" (nothing where the code was), and goes straight to the party screen when a playlist is picked. Until then the zone isn't announced over Bonjour, so it isn't in any device's zone list (and no guest is shown an empty zone); the web server and the host's QR link work all along. It's announced as soon as a playlist is loaded. A TV hub has no settings screens; Menu only offers **End <zone>** (and saving the party, below). Apple Music only.

## Network

- **Discovery:** hubs advertise Bonjour `_canopymusic._tcp` (an Apple TV once its zone has a playlist). The TXT record carries the zone name, the hub kind (ipad/tv), what's playing and the guest address. Displays browse for it; the list updates live.
- **Addresses:** each hub announces a `.local` name made from its zone name ("Living Room" is `living-room.local`; `music.local` if nothing's left), then `living-room-2.local`… on a clash. A clash with the device's own name doesn't count: an Apple TV called "Living Room" is already `Living-Room.local`, so when the taken name resolves to one of this device's own addresses, the zone uses it as it is. It's handed out only once mDNS confirms it. Renaming the zone (iPad or web) announces the new name, and a web page on the old name moves to the new one, keeping the phone's ID, name and Host Control. Simulator builds use `canopytest-<zone>.local`, so tests never take real names. Every QR code points at its own hub.
- **Displays** use the same JSON API and WebSocket snapshots as the guest page, plus a few display endpoints:
  - `POST /api/display/hello`: a heartbeat, so the hub can list connected displays.
  - `POST /api/display/playback`: allowed while *Playback controls on displays* is on.
- **Up next** has 100 live songs (in snapshots: draggable, removable). Below them the same list carries on, read-only (no handle or remove, nothing can be dropped there), with the rest of the base playlist's current cycle, from `GET /api/upcoming?offset=&limit=` (compact rows, 100 at most per page). The web page and iPads (hub or display) load 50 more as the end comes into view, and fetch the rows shown again when the queue moves on, so a song simply gains its handle when it becomes live. The Apple TV shows only the rows that fit. The web page only rebuilds rows that changed, animates only rows on screen, and loads row artwork lazily.
- **Hosts on the web** get new endpoints, all requiring the host key:
  - `GET /api/host/playlists`: the hub's library. The web picker (Change base playlist, and a TV zone's first setup) filters it as you type, ignoring case and accents. Both pickers scroll as one sheet (heading, fields, search, list), so the list gets the whole screen; the search sticks to the top once the rest has scrolled off, and a fixed footer has a **Shuffle** switch (on by default) and the button (**Start the music**, or **Use this playlist**: in Change, a row selects and the button confirms, asking first if there's a queue to start over). There's no shuffle in the web settings mid-party (the iPad keeps its shuffle button).
  - `GET /api/host/playlists/search?q=`: the music service's playlists, shown below the library matches while typing (as on the iPad; not for Spotify).
  - `POST /api/host/playlist`: load a base playlist (`shuffle: true` shuffles it as it loads, before anything plays, so the first song is random too). Answers with how many of its songs were left out (not on the music service, e.g. iTunes Match uploads with no catalog match) and the first few titles. Snapshots carry the same (`skippedOnLoad`, `skippedTitles`) until another playlist loads: the iPad shows "3 songs aren't on Apple Music" under the base playlist (tap for the list), the web settings sheet shows it under Base playlist, and an Apple TV's host also gets it once as a toast. Debug builds' demo library has "Road trip", which leaves 4 out.
  - `POST /api/host/settings`: zone name, queue and reorder from phones, display controls, Wi‑Fi; any subset (the web sheet saves each change as it's made). Not the iPad's unlock PIN, which is set only on the iPad.
  - `GET /api/host/details`: the Wi‑Fi details and the connected displays. The Wi‑Fi password is never in the snapshots guests get; displays' socket (`/ws?display=1`) carries the Wi‑Fi details, so they show the hub's Join Wi‑Fi code and follow changes live.
  - `POST /api/host/stop`: ends the zone (any hub), exactly as ending it on the hub does. The page asks first.
  - `POST /api/host/save-playlist`: saves the party as a playlist (`name`, `onlyRequests`). Answers `{saved: n}`, or an error with `{error: "…"}` (409 when there's nothing matching to save, 502 when the service failed). `GET /api/host/details` also carries `party`: the suggested name, how many songs would be saved either way, and where it saves.
  - `GET /api/host/invite.png`: the "Add another host" QR, rendered by the hub.
- **Host keys are kept per hub:** snapshots carry the hub's device ID (`hubID`), and the page keeps one key per hub. A hub that refuses a key only drops its own, so a phone that's a host of two zones (or of a zone whose address another hub later takes) stays a host of both. Keys move along with the phone's ID and name when the page moves to the friendly address.
- **The web page's splash:** until the page has settled on its address (the hop from the IP to the `.local` name included) and has the zone's first snapshot, it shows the "canopy music" lockup on the Venus background with "Connecting to <zone>" ("Connecting…" before the name is known), never the empty party screen. If the connection drops later, a slim "Reconnecting…" bar sits over what was showing. The lockup (`logo-music.png`) is rendered from the app's logo and Montserrat Bold to match the marketing header, since only a flattened copy of it existed. The splash's background colour (under the image) is the page's base grey, not the image's purple: Safari 26 tints its status bar and toolbar with that colour as the page loads and keeps it after the splash has gone, which left a purple frame around the setup sheet.
- **Debug builds' web log:** a debug hub answers `GET /api/debug/log?probe`, and the page then posts what it did with its splash and first screen (timestamps, the redirect, the host check, the first snapshot, the setup sheet opening, and what's on screen: the splash's and setup sheet's computed styles, the element at the top, middle and bottom, the page background, the viewport) to `Library/Caches/web.log` in the hub app's container. `GET /api/debug/log` reads it back. Release builds have neither route, and the page sends nothing.
- **If a hub disappears,** displays show "Lost connection to <zone>" and keep retrying. The queue is saved on the hub.

## Decisions taken while building (review)

- **"Resume" row:** a hub whose zone wasn't ended but didn't come back by itself (see Launch flow, or it was left to show another zone) shows it first in the list ("Resume on this iPad", "Resume on this TV"). Resume comes back locked if the iPad was locked. Ending the zone removes the row. The Apple TV has the row too, so creating over its zone has something to point back to.
- **Saving the party as a playlist:** the hub keeps a log of every song that played in the zone, in order, with who added it. Unlike Up next's history it isn't capped, it's saved with the queue (so a crash keeps it), and End clears it. A song counts as played once the player has started it: songs skipped before they played, and songs that failed to play, don't; going back to a song doesn't count it twice.
  - **What's saved:** the guests' requests are the point, played or not. At save time the hub takes the log's songs, in the order they played, then the requests still waiting (the current song if it hasn't started, then Up next, in queue order). "Only songs guests added" (on by default) keeps the songs anyone added from a phone, the hub or a display; off adds the base playlist songs that played (base songs that never played stay out). A request removed from the queue, or skipped, before it played isn't saved. Each song is saved once, however often it was requested or played.
  - **Offered as soon as someone has added a song** (the count "Only songs guests added" saves): until then the party is just the base playlist, nothing worth saving, so End is a plain confirmation everywhere (iPad alert, web dialog, TV) and the settings leave out Save as playlist.
  - **Ending** (iPad sheet, web dialog) offers "Save as playlist", on by default, with a name field that starts as the party's date ("2026-10-12 ", the day the first song played, or today) for the host to finish, and "Only songs guests added", on by default. If saving fails the zone keeps going: the host can try again or end without saving.
  - **Mid-party:** iPad Settings › Save as Playlist, and the web settings sheet's "Save as playlist" row, save the same way without ending.
  - **Apple TV:** Menu › End opens an "End <zone>?" sheet that saves the songs guests added: a name field starting as the party's date (type with the remote, dictate, or use the keyboard tvOS offers on a nearby iPhone), then **Save and End** (focused first) or **End Without Saving** (destructive, so red; white on red when focused, red on red when not); Menu cancels. Left as just the date, it's saved as the date and the zone ("2026-10-12 Attic"). "Saving playlist…" while it works; on failure "Couldn't save the playlist" with **Try Again** or **End Without Saving**. Every song (not just guests') from the web page.
  - **Where it saves:** the hub's signed-in account. Apple Music: a library playlist (Apple Music API, so the TV can too). Spotify (iPad): a private playlist; sign-ins from before this need to sign in again once, since Spotify only grants the new permission (`playlist-modify-private`) through its sign-in page. Debug builds' demo service saves to a demo library that shows up in the playlist pickers; `-failSave` makes it fail.
  - **The description** credits the people who queued from their phones and gave a name, most songs first: "Queued by Sam, Phil and 6 others · Canopy Music". The hub, displays and unnamed phones aren't credited; with nobody to credit it's just "Canopy Music". It counts the saved songs, so requests still waiting are credited too.
- **Ending a zone** (iPad, TV or web, all the same) stops the music, the guest server, the Bonjour announcement and the `.local` name, so the zone leaves every device's list at once. It clears the queue, history and base playlist and deletes the saved queue, so the next zone on that device starts empty. Settings stay: zone name, Wi‑Fi, the toggles, Host Control and its phones, and the service sign-in.
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
- **Ending a zone** (simulators, 12 Oct 2026): from the iPad's End alert, the web endpoint on an iPad hub and on a TV hub, the zone leaves `dns-sd -B _canopymusic._tcp`, the server and `.local` name go, the saved queue is deleted, there's no Resume row, and a relaunch starts empty.
- **Saving the party** (simulators with the demo service, 12 Oct 2026): requests from named, unnamed, "Guest" and display requesters, skipped through; `/api/host/details` counts them; saving from the web API, iPad Settings, the iPad's End sheet (and its failure with `-failSave`, keeping the zone), the web End dialog (and its failure, then End without saving) and the TV's Menu › End all put the playlist in the demo library with the right name and credit; a crash keeps the log; End clears it. Not checked: saving to real Apple Music or Spotify (the simulators can't), and Spotify's re-sign-in. Requests that haven't played (simulators, 12 Oct 2026): a TV zone and an iPad zone with a playlist loaded, nothing played and one phone request offer saving with 1 song (`/api/host/details`, the TV's Menu › End sheet, the iPad's End sheet); the TV's Save and End and the web API (either switch setting) save just that song.
- **Coming back after a crash** (simulators, 12 Oct 2026, killed while hosting, relaunched without debug flags): an iPad comes back locked when it was locked and in host mode when it wasn't, paused, announced, and `/api/state` has the queue; an Apple TV with a playlist comes back to its party screen, paused and announced, with the same Host Control key. A TV zone that a host had joined but never set up, killed with `kill -9` and relaunched, is ended instead: the TV starts at the zone list with no Resume row, the zone record is cleared, nothing listens on its port, and its `.local` name and Bonjour service are gone (`dns-sd`). With the restore made to fail (`-noRestore`), the list shows the Resume row and nothing is announced. An iPad killed while showing another zone starts at the list. "Create a new zone" with a zone to resume asks first and starts empty (iPad and TV, via `-confirmCreate -autoCreate`).
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
