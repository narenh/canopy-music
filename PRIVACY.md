# Canopy Music Privacy Policy

_Effective October 11, 2026_

Canopy Music ("Canopy") is an iPad app for running a party jukebox. This policy explains what information the app handles and where it goes.

**The short version:** Canopy has no servers, accounts, analytics, advertising or tracking. The developer doesn't receive any information about you or your guests. Everything Canopy keeps stays on the iPad it runs on.

## Information that stays on the iPad

Canopy stores the following on the iPad only, and never sends it to the developer:

- **The party queue:** the songs in it, who requested each song (an optional name and a random identifier, see below), and recently played songs. It's saved so a party survives the app restarting.
- **Settings:** your music service choice, crossfade, the `.local` address name, the host PIN, and Wi‑Fi details you enter so guests can scan a "Join Wi‑Fi" code.
- **Spotify sign-in:** if you use Spotify, your Spotify Client ID, account tokens (stored in the iOS Keychain), display name, and the device music plays on.

Deleting the app deletes this information, except Keychain items, which iOS may keep until the device is erased.

## Guests' phones

When "Queue from phones" is on, Canopy runs a small web server on your local Wi‑Fi network so guests can open a web page and queue songs. Guests don't need an app or an account. The page:

- Asks for an **optional name**, shown next to the songs that guest adds. It's visible to everyone at the party.
- Creates a **random identifier** in the guest's browser, so the guest can remove their own requests. It isn't linked to anything else.
- Sends the guest's **searches and song choices** to the iPad, which looks them up with your music service.

This information travels only over your local network to the iPad. Guests' browsers load album artwork directly from Apple's or Spotify's image servers.

## Third-party services

Canopy talks to these services to do its job. Their own privacy policies apply to that information:

- **Apple Music** (when you choose Apple Music): searches, playlists and playback go through Apple's MusicKit and Apple Music API under your Apple Account. See [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).
- **Spotify** (when you choose Spotify): sign-in, searches, playlists, your display name, your available devices and playback control go through Spotify's Web API under your Spotify account. See [Spotify's Privacy Policy](https://www.spotify.com/legal/privacy-policy/).
- **LRCLIB** ([lrclib.net](https://lrclib.net)): for a particular song, Canopy may download publicly available synced lyrics. The request identifies the song, not you.

Canopy doesn't sell, share or use any information for advertising or tracking.

## Permissions

- **Apple Music and media library:** to search and play Apple Music, if you choose it.
- **Local Network:** to run the guest web page and announce its address (for example `music.local`) on your Wi‑Fi.

## Children

Canopy isn't directed at children. The developer doesn't collect information from anyone, children included.

## Changes

If this policy changes, the new version will be posted here with a new effective date.

## Contact

Questions or requests: [open an issue on GitHub](https://github.com/narenh/canopy-music/issues).
