# Canopy

iPad party jukebox on Apple Music. Pick a base playlist, lock the iPad into a now-playing screen, and guests queue songs on the iPad or from their phones (QR code, no Apple Music needed). Requests and playlist songs live in one list that anyone can drag to reorder.

## First run on your iPad

1. **Turn on MusicKit for the App ID.** In the developer portal: Certificates, IDs & Profiles → Identifiers → `com.canopysf.CanopyMusic` → App Services → check **MusicKit**. (Build once with automatic signing first so the identifier exists.) Without this, catalog requests fail with a token error.
2. Open `CanopyMusic.xcodeproj`, pick your iPad, run. The team is set to `UC3Y84QJ83`; change it under Signing if needed.
3. In host mode: **Connect Apple Music** → choose a base playlist → pick speakers with the AirPlay button → optionally set a PIN and Wi-Fi details → **Lock and start the party**.
4. Triple-click the top button to start Guided Access.
5. To get back to host mode, press and hold the Canopy logo.

The simulator can't play Apple Music, so it runs in **Demo mode** (fake songs, 30-second tracks). You can also toggle demo mode on the iPad.

## Phones

The iPad serves a web app on your Wi-Fi. The QR code always uses the iPad's IP address. The app also tries to:

- listen on port 80 so the URL has no `:port` (falls back to 8080)
- announce `canopymusic.local` over Bonjour

Both work from the simulator on this Mac. **Not yet verified on a real iPad.** If the friendly name doesn't show in host mode, it fell back to the IP. Some Android phones don't resolve `.local` names; the QR code covers them.

Guests can add, drag to reorder, and remove their own requests. Names are optional (there's a Skip).

## Layout

```
CanopyKit/                   Swift package (no MusicKit)
  Sources/CanopyCore/        Track, QueueState (all queue rules), PartySession, provider protocols, demo provider
  Sources/CanopyServer/      LAN web server (FlyingFox), mDNS name, web app in Web/
  Sources/CanopyDevServer/   `swift run CanopyDevServer`: phone web app + demo data on your Mac
  Tests/CanopyCoreTests/     queue and session tests
CanopyMusic/                 iPad app (SwiftUI, iOS 26)
  AppleMusic/                MusicKit catalog + ApplicationMusicPlayer engine (the only MusicKit code)
  Views/                     host, party (locked), Up Next, search, fly-in animation
```

```bash
cd CanopyKit && swift test
```

Debug launch arguments (simulator): `-autoParty` starts a demo party and locks; `-autoSearch <term>` searches and adds the first result to exercise the fly-in animation.

## Things to check on the device

- **Swapping the staged next song.** The engine keeps one song staged after the current one and replaces it when the queue changes (`AppleMusicEngine.stage`). It compiles against the SDK, but I couldn't test playback in the simulator. If replacing causes glitches, set `canReplaceStaged = false` and `PartySession` switches to staging 20 s before the end and showing the next song as locked.
- **End-of-queue detection** (`AppleMusicEngine.poll`) is a heuristic.
- **Library playlists** load through the Apple Music API (`/v1/me/library/...`), which needs Sync Library on. Uploaded or unmatched songs are skipped.
- **Local network permission** prompt and `canopymusic.local` registration on iPadOS.
