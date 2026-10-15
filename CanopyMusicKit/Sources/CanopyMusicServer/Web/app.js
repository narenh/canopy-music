(async () => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  // Keys were "canopy.*" before the app's name change; reading falls back to them so phones keep
  // their ID, name and host pairing.
  const store = {
    get(key) {
      try { return localStorage.getItem(key) ?? localStorage.getItem(key.replace(/^canopymusic\./, "canopy.")); } catch { return null; }
    },
    set(key, value) { try { localStorage.setItem(key, value); } catch {} },
    remove(key) {
      try { localStorage.removeItem(key); localStorage.removeItem(key.replace(/^canopymusic\./, "canopy.")); } catch {}
    },
  };

  // crypto.randomUUID needs a secure context, and this page is plain http on the LAN.
  function uuid() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === "x" ? r : (r & 3) | 8).toString(16);
    });
  }

  // Debug builds of the hub only (they answer /api/debug/log?probe): what this page did with its
  // splash and first screen, appended to the hub's Library/Caches/web.log. Lines wait until the
  // probe answers; with a release hub, nothing is sent.
  const debugLog = (() => {
    const page = uuid().slice(0, 4);
    let lines = [], on = null, timer = null;
    const flush = () => { clearTimeout(timer); if (on && lines.length) navigator.sendBeacon("/api/debug/log", lines.splice(0).join("\n")); };
    fetch("/api/debug/log?probe").then((r) => { on = r.status === 204; }).catch(() => { on = false; })
      .finally(() => { if (on) flush(); else lines = null; });
    addEventListener("pagehide", (e) => { log(`pagehide persisted=${e.persisted}`); flush(); });
    function log(text) {
      if (on === false) return;
      lines.push(`${page} ${location.host} +${Math.round(performance.now())}ms ${text}`);
      if (on) { clearTimeout(timer); timer = setTimeout(flush, 150); }
    }
    return log;
  })();
  /** Debug log: what's on screen (the splash and setup sheet as styled, the element at the top,
   * middle and bottom, the page background and the viewport). */
  function debugScreen(label) {
    const splash = $("splash"), setup = $("setup"), s = getComputedStyle(splash), u = getComputedStyle(setup);
    const at = (y) => {
      const el = document.elementFromPoint(innerWidth / 2, y), box = el && el.closest("[id]");
      return el ? `${el.tagName.toLowerCase()}${box ? "#" + box.id : ""}` : "-";
    };
    const vv = window.visualViewport, r = setup.getBoundingClientRect();
    debugLog(`${label}: splash hidden=${splash.hidden} class="${splash.className}" display=${s.display} opacity=${s.opacity} visibility=${s.visibility}` +
      ` | setup hidden=${setup.hidden} class="${setup.className}" display=${u.display} opacity=${u.opacity} bg=${u.backgroundColor} top=${Math.round(r.top)} h=${Math.round(r.height)}` +
      ` | at top=${at(4)} mid=${at(innerHeight / 2)} bottom=${at(innerHeight - 4)}` +
      ` | body bg=${getComputedStyle(document.body).backgroundColor} ${getComputedStyle(document.body).backgroundImage} html bg=${getComputedStyle(document.documentElement).backgroundColor}` +
      ` | inner=${innerWidth}x${innerHeight} vv=${vv ? `${Math.round(vv.height)}@${Math.round(vv.offsetTop)}` : "-"} ${document.visibilityState}`);
  }
  debugLog(`start ${location.href} nav=${(performance.getEntriesByType("navigation")[0] || {}).type} ${navigator.userAgent}`);
  debugScreen("splash shown");
  addEventListener("pageshow", (e) => debugLog(`pageshow persisted=${e.persisted}`));
  document.addEventListener("visibilitychange", () => debugLog(`visibility ${document.visibilityState}`));
  addEventListener("error", (e) => debugLog(`error ${e.message} ${e.filename}:${e.lineno}`));
  $("splash").addEventListener("transitionend", (e) => debugScreen(`splash transitionend ${e.propertyName}`));

  const params = new URLSearchParams(location.search);

  // Saved data (name, phone ID, host key) is per address. QR codes use the IP, which every phone
  // can open; if this phone can also reach the friendly address (music.local), continue there
  // before saving anything, so everything lives under that one address.
  let initial = null;
  try { initial = await (await fetch("/api/state")).json(); } catch {}
  debugLog(initial ? `state zone="${initial.zoneName}" kind=${initial.hubKind} address=${initial.address} lan=${initial.lanAddress} playlist="${initial.playlistName || ""}"` : "state failed");
  if (initial && initial.zoneName) $("splash-text").textContent = `Connecting to ${initial.zoneName}`;
  // Which hub this is (older hubs don't say), for keeping host keys per hub.
  const hubID = (initial && initial.hubID) || null;
  // A new Apple TV zone's host sets it up here on the IP address, since renaming the zone in the
  // setup sheet moves its `.local` name. The page continues there once the zone is set up.
  let moveWhenSetUp = false;
  await (async () => {
    const address = initial && initial.address, lan = initial && initial.lanAddress;
    if (!address || !lan || address === location.host) return;
    if (waitingForSetup(initial) && !location.hostname.endsWith(".local")) {
      debugLog("waiting for setup: staying");
      moveWhenSetUp = true;
      return;
    }
    // Only if that name reaches this same hub: another zone can answer at music.local too.
    if (!(await reachable(address, lan))) { debugLog(`${address} not reachable: staying`); return; }
    debugLog(`moving to ${address}`);
    moveTo(address, params, savedHostKey(), location.hash);
    await new Promise(() => {}); // stop here while the browser navigates
  })();

  // Host keys, one per hub (by its device ID), so being a host of one zone never costs the key
  // of another that answered at the same address. `canopymusic.hostKey` is the old single key.
  function hostKeys() {
    try { return JSON.parse(store.get("canopymusic.hostKeys") || "{}") || {}; } catch { return {}; }
  }
  function saveHostKey(key) {
    if (!hubID) { if (key) store.set("canopymusic.hostKey", key); else store.remove("canopymusic.hostKey"); return; }
    const keys = hostKeys();
    if (key) keys[hubID] = key; else delete keys[hubID];
    store.set("canopymusic.hostKeys", JSON.stringify(keys));
  }
  /** This hub's key; else the old single key, which may be this hub's (checked on load). */
  function savedHostKey() {
    return (hubID && hostKeys()[hubID]) || store.get("canopymusic.hostKey");
  }

  // Continues at another address of this hub, taking this phone's ID, name and host key along
  // (each address has its own storage).
  function moveTo(address, params, key, hash = "") {
    const next = new URLSearchParams(params);
    const existing = store.get("canopymusic.clientId");
    if (existing && !next.get("cid")) next.set("cid", existing);
    // An empty name means this phone was asked and skipped it.
    if (store.get("canopymusic.nameAsked") && !next.has("name")) next.set("name", store.get("canopymusic.name") || "");
    if (key && !next.get("host")) next.set("host", key);
    location.replace(`http://${address}/${next.toString() ? `?${next}` : ""}${hash}`);
  }

  /** An Apple TV zone whose host hasn't picked the music yet (as the hub's `isWaitingForSetup`). */
  function waitingForSetup(s) {
    return s.hubKind === "tv" && !s.playlistName && !s.current && !(s.upNext && s.upNext.length);
  }

  // An image loads across addresses where fetch can't; the hub only serves this one if it's the
  // hub at `lan`.
  function reachable(host, lan) {
    return new Promise((resolve) => {
      const image = new Image();
      const timer = setTimeout(() => resolve(false), 1500);
      image.onload = () => { clearTimeout(timer); resolve(true); };
      image.onerror = () => { clearTimeout(timer); resolve(false); };
      image.src = `http://${host}/api/same.png?lan=${encodeURIComponent(lan)}&t=${Date.now()}`;
    });
  }

  // Coming from the IP address, the link carries this phone's existing ID (`cid`), so it's still
  // the same phone here.
  const handedId = params.get("cid") ? params.get("cid").slice(0, 64) : null;
  if (handedId && !store.get("canopymusic.clientId")) store.set("canopymusic.clientId", handedId);
  const clientId = store.get("canopymusic.clientId") || (() => { const id = uuid(); store.set("canopymusic.clientId", id); return id; })();
  // Each address keeps its own storage, so a phone that used the IP address while it already had
  // an ID here has two. Both are this phone: its songs show as "You" and it can remove them.
  let otherIds = [];
  try { otherIds = JSON.parse(store.get("canopymusic.otherIds") || "[]"); } catch {}
  if (handedId && handedId !== clientId && !otherIds.includes(handedId)) {
    otherIds = [...otherIds, handedId].slice(-5);
    store.set("canopymusic.otherIds", JSON.stringify(otherIds));
  }
  const myIds = new Set([clientId, ...otherIds]);
  // A link can carry a name (`?name=Sam`), which skips the name prompt.
  if (params.has("name")) { store.set("canopymusic.name", params.get("name").slice(0, 30)); store.set("canopymusic.nameAsked", "1"); }
  let myName = store.get("canopymusic.name") || null;

  // Host control: a phone that scanned the iPad's Host Control QR code. The key arrives in the
  // link once, is kept on the phone, and is checked with the iPad on every load. Host mode is
  // remembered per phone; the switch next to the name flips between it and the guest view.
  if (params.get("host")) {
    // A new key means a new pairing, so start in host view; the same key (carried along from
    // another address) keeps the view this phone chose.
    if (params.get("host") !== savedHostKey()) store.set("canopymusic.hostMode", "host");
    saveHostKey(params.get("host").slice(0, 64));
  }
  if (params.has("host") || params.has("cid") || params.has("name")) {
    ["host", "cid", "name"].forEach((key) => params.delete(key));
    history.replaceState(null, "", location.pathname + (params.toString() ? `?${params}` : "") + location.hash);
  }
  let hostKey = savedHostKey();
  let hostPaired = false;
  /** Set once the hub has answered whether this phone's host key is good. */
  let hostChecked = !hostKey;
  let hostMode = store.get("canopymusic.hostMode") !== "guest";
  const hosting = () => hostPaired && hostMode;

  let snap = null;
  /** An Apple TV hub's Apple Music access ("ok", "notDetermined", "denied", "noSubscription",
   * "error"), from hosts' snapshots; undefined until one arrives. */
  let musicAccess;
  /** An Apple TV hub's Spotify setup (sign-in, devices, sign-in page), also from hosts' snapshots. */
  let spotify;
  /** The hub's Sonos rooms (where a TV zone plays, the volume row and Devices), hosts' snapshots too. */
  let sonosSetup;
  let firstRender = true;
  let dragging = null;
  let pendingSnap = null;
  const rowEls = new Map();
  const flashIds = new Set();

  // MARK: Theme

  const hexToRgb = (hex) => { const h = hex.replace("#", ""); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
  const rgbToHex = (rgb) => "#" + rgb.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");
  const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  const luminance = (rgb) => {
    const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]);
  };
  const contrast = (a, b) => { const x = luminance(a), y = luminance(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const saturation = (rgb) => (Math.max(...rgb) - Math.min(...rgb)) / 255;

  /** Dark base from the artwork background; accent is the most colorful artwork color that reads on it. */
  function themeFor(colors) {
    if (!colors) return { base: "#141414", accent: "#f2f2f2" };
    const bg = hexToRgb(colors.background);
    let base = bg;
    for (let t = 0.05; luminance(base) > 0.018 && t <= 1; t += 0.05) base = mix(bg, [0, 0, 0], t);
    let best = null;
    for (const hex of [colors.secondary, colors.primary, colors.background]) {
      let c = hexToRgb(hex);
      for (let t = 0.05; contrast(c, base) < 4.5 && t <= 1; t += 0.05) c = mix(hexToRgb(hex), [255, 255, 255], t);
      if (!best || saturation(c) > saturation(best)) best = c;
    }
    if (saturation(best) < 0.12) best = [242, 242, 242];
    return { base: rgbToHex(base), accent: rgbToHex(best) };
  }

  let themedTrackId = null;
  function applyTheme(track) {
    const id = track ? track.id : null;
    if (id === themedTrackId) return;
    themedTrackId = id;
    const { base, accent } = themeFor(track && track.colors);
    document.documentElement.style.setProperty("--base", base);
    document.documentElement.style.setProperty("--accent", accent);
    document.querySelector('meta[name="theme-color"]').setAttribute("content", base);
    // Safari 26 ignores theme-color. The splash keeps its purple bars until it fades.
    if ($("splash").classList.contains("gone")) tintBars();

    const img = $("backdrop-img");
    img.classList.remove("shown");
    const url = track && track.artworkURL;
    if (!url) return;
    const loader = new Image();
    loader.onload = () => { if (themedTrackId === id) { img.src = url; img.classList.add("shown"); } };
    loader.src = url;
  }

  /** Sets Safari's status bar and toolbar to the page's colour: Safari 26 takes it from a fixed
   * element appearing at the screen's edges, and keeps it after (see .bar-tint). */
  function tintBars() {
    const tints = ["top", "bottom"].map((edge) => {
      const tint = document.createElement("div");
      tint.className = "bar-tint";
      tint.style[edge] = "0";
      return document.body.appendChild(tint);
    });
    requestAnimationFrame(() => requestAnimationFrame(() => tints.forEach((tint) => tint.remove())));
  }

  function setArt(el, track, large) {
    const url = large ? track.artworkURL || track.thumbnailURL : track.thumbnailURL || track.artworkURL;
    if (!large) {
      // Row artwork loads lazily: an <img loading="lazy"> (a CSS background loads at once).
      el.style.backgroundImage = !url && track.colors ? `linear-gradient(135deg, ${track.colors.background}, ${track.colors.secondary})` : "";
      let img = el.querySelector("img");
      if (url) {
        if (!img) {
          img = document.createElement("img"); img.loading = "lazy"; img.decoding = "async"; img.alt = "";
          // No broken-image icon where there's no art (a library song the hub has none for).
          img.onerror = () => { img.style.visibility = "hidden"; };
          el.append(img);
        }
        if (img.getAttribute("src") !== url) { img.style.visibility = ""; img.src = url; }
      } else if (img) {
        img.remove();
      }
      return;
    }
    if (url) {
      el.style.backgroundImage = `url("${url}")`;
    } else if (track.colors) {
      el.style.backgroundImage = `linear-gradient(135deg, ${track.colors.background}, ${track.colors.secondary})`;
    } else {
      el.style.backgroundImage = "";
    }
  }

  // MARK: Rendering

  function applySnapshot(next) {
    if (dragging) { pendingSnap = next; return; }
    // A different hub now answers at this address (the old one left and another took the name):
    // start over, so this hub gets its own host key, not the other's.
    if (hubID && next.hubID && next.hubID !== hubID) { location.reload(); return; }
    // The hub started a new session (End, a service change, a relaunch): its version count
    // started over, so this snapshot is taken whatever its number, and compared from here on.
    // Older hubs send no epoch and are compared by version alone, as before.
    const newSession = snap && next.epoch && next.epoch !== snap.epoch;
    if (newSession) { debugLog(`new session on the hub (v${next.version})`); later.version = null; }
    else if (snap && next.version < snap.version) return;
    if (!snap) debugLog(`first snapshot v${next.version} playlist="${next.playlistName || ""}" hostChecked=${hostChecked}`);
    snap = next;
    // Hosts' snapshots only (not `/api/state`'s): kept until one says otherwise.
    if (next.musicAccess !== undefined && next.musicAccess !== musicAccess) {
      debugLog(`music access ${next.musicAccess}`);
      musicAccess = next.musicAccess;
    }
    if (next.spotify !== undefined) spotify = next.spotify;
    if (next.sonos !== undefined) sonosSetup = next.sonos;
    // The Crossfade button showed what was asked; the hub says so now.
    if (crossfadeWanted !== null && next.crossfade === crossfadeWanted) crossfadeWanted = null;
    render();
    openSettingsFromLink();
    hideSplash();
    followRename();
    moveIfSetUp();
  }

  // The page that set up a new Apple TV zone (on the IP address) continues at the zone's `.local`
  // name once it's set up, behind the splash, as a page opened from the QR code does.
  let setupToastUntil = 0;
  async function moveIfSetUp() {
    const address = snap.address;
    if (!moveWhenSetUp || waitingForSetup(snap) || setupStarting || !address || address === location.host) return;
    moveWhenSetUp = false;
    // The setup's note about songs that couldn't load stays up for its time first.
    const wait = setupToastUntil - Date.now();
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    showSplash(`Connecting to ${snap.zoneName || "Canopy Music"}`);
    if (!(await reachableWhenShown(address))) { debugLog(`set up; ${address} not reachable: staying`); hideSplash(); return; }
    debugLog(`set up; moving to ${address}`);
    moveTo(address, new URLSearchParams(location.search), savedHostKey(), settingsOpen() ? "#settings" : "");
  }

  // A renamed zone moves to a new `.local` name; a page on the old one follows it there (if this
  // phone can reach the new name), so it isn't left on a name that no longer answers.
  let followedAddress = null;
  async function followRename() {
    const address = snap.address;
    if (!address || address === location.host || address === followedAddress) return;
    if (!location.hostname.endsWith(".local")) return; // on the IP address, which still works
    followedAddress = address;
    const ok = await reachableWhenShown(address, () => followedAddress === address);
    if (followedAddress !== address) return; // renamed again meanwhile: that name is followed
    if (!ok) { debugLog(`rename: ${address} not reachable: staying`); return; }
    debugLog(`rename: moving to ${address}`);
    moveTo(address, new URLSearchParams(location.search), hostPaired ? hostKey : null, settingsOpen() ? "#settings" : "");
  }

  /** `reachable`, checked while the page is showing: Safari fails a background tab's loads from
   * another address at once, so a hidden page waits until it's shown (again, if it was hidden
   * during the check). Gives up (false) once `wanted()` is false. */
  async function reachableWhenShown(address, wanted = () => true) {
    for (;;) {
      if (document.visibilityState !== "visible") {
        debugLog(`${address}: waiting until shown`);
        await new Promise((resolve) => {
          const shown = () => {
            if (document.visibilityState !== "visible") return;
            document.removeEventListener("visibilitychange", shown);
            resolve();
          };
          document.addEventListener("visibilitychange", shown);
        });
      }
      if (!wanted()) return false;
      if (await reachable(address, snap.lanAddress)) return true;
      if (document.visibilityState === "visible") return false;
    }
  }

  // A link to …/#settings opens the zone settings once this phone is a host and the state has loaded;
  // …/#wifi opens the Wi‑Fi dialog on top of them, once the Wi‑Fi details have loaded.
  const settingsLinked = () => location.hash === "#settings" || location.hash === "#wifi";
  let settingsLinkPending = settingsLinked();
  let wifiLinkPending = location.hash === "#wifi";
  // The same page opened again with #settings only changes the hash.
  window.addEventListener("hashchange", () => {
    settingsLinkPending = settingsLinked();
    wifiLinkPending = location.hash === "#wifi";
    openSettingsFromLink();
  });
  function openSettingsFromLink() {
    if (!settingsLinkPending || !snap || !hosting()) return;
    settingsLinkPending = false;
    $("settings-btn").click();
  }

  /** Fades the splash out onto the first screen, once it's known: a phone with a host key waits
   * for the hub's answer too, so a host doesn't see the guest view first (a new Apple TV zone's
   * host gets the setup sheet). */
  function hideSplash() {
    const splash = $("splash");
    if (!snap || !hostChecked || splash.hidden || splash.classList.contains("gone")) return;
    // A sheet that opened as the first screen is already in place under the splash; it doesn't
    // also slide in while the splash fades.
    for (const sheet of document.querySelectorAll(".sheet")) if (!sheet.hidden) sheet.classList.add("instant");
    tintBars(); // from the splash's purple to the page's colour
    splash.classList.add("gone");
    debugScreen("splash fading");
    setTimeout(() => {
      splash.hidden = true;
      debugScreen("splash hidden");
      setTimeout(() => debugScreen("2s later"), 2000);
    }, 400);
  }

  /** The splash again, over the page (it sets Safari's bars to its purple as it appears). */
  function showSplash(text) {
    const splash = $("splash");
    $("splash-text").textContent = text;
    splash.hidden = false;
    splash.classList.remove("gone");
    debugScreen("splash shown again");
  }

  /** What's actually playing: in a Spotify zone, possibly a track from outside the queue
   * (another app or zone on the account), which has no requester. */
  const nowPlaying = (s) => s.externalCurrent || s.current;
  /** Songs in Spotify's own queue that play before the zone's next song (read-only, first). */
  const foreignItems = (s) => s.foreignUpcoming || [];
  const isForeign = (item) => foreignItems(snap).some((f) => f.id === item.id);

  function render() {
    const current = nowPlaying(snap);
    applyTheme(current && current.track);

    // The host can turn off reordering from phones (host control can always reorder).
    document.querySelector(".list-head .hint").hidden = snap.canReorder === false && !hosting();
    $("transport").hidden = !hosting();
    renderVolumeBar();
    const queueOff = snap.canQueue === false && !hosting();
    $("search-trigger").hidden = queueOff;
    $("queue-off").hidden = !queueOff;
    renderHost();
    if (settingsOpen()) fillSettings();
    // The hub's address can arrive (or change) while a zone name is being edited.
    if (!$("setup").hidden) { setupAddress(); renderSetupMusic(); }
    if (!$("edit-modal").hidden) editAddress();
    const playing = !!(current && snap.playback.isPlaying);
    $("t-play").innerHTML = playing ? icons.pause : icons.play;
    $("t-play").setAttribute("aria-label", playing ? "Pause" : "Play");
    $("zone-device").innerHTML = deviceIcon(snap.hubKind, snap.hubDevice);
    $("zone-name").textContent = snap.zoneName || "";
    document.title = snap.zoneName ? `${snap.zoneName} - Canopy Music` : "Canopy Music";
    $("zone-line").hidden = !snap.zoneName;
    $("playlist-name").textContent = snap.playlistName || "";
    $("playlist-line").hidden = !snap.playlistName;
    $("now-status").textContent = !current ? "Waiting for music" : snap.playback.isPlaying ? "Now playing" : "Paused";
    // Understated: chosen on the Spotify account, not from this queue.
    $("now-from").hidden = !snap.externalCurrent;
    $("now-from").textContent = snap.externalCurrent ? ` · From ${snap.service || "Spotify"}` : "";
    $("now-title").textContent = current ? current.track.title : "Nothing yet";
    $("now-artist").textContent = current ? current.track.artist : "";
    if (current) setArt($("now-art"), current.track, true);
    else $("now-art").style.backgroundImage = "";

    renderQueue();
    updateResultButtons();
    updateProgress();
  }

  function requesterLabel(item) {
    const r = item.requester;
    if (!r) return null;
    if (myIds.has(r.clientID)) return { text: "You", mine: true };
    if (r.name) return { text: r.name, mine: false };
    return { text: r.origin === "ipad" ? hubNoun() : "Guest", mine: false };
  }

  // Which Mac a hub or display is (`hubDevice` in snapshots, `device` in the displays list):
  // what it's called, and its icon. Absent for iPads and Apple TVs, and from older hubs.
  const macNouns = { MacBookAir: "MacBook Air", MacBookPro: "MacBook Pro", iMac: "iMac", Macmini: "Mac mini",
                     MacStudio: "Mac Studio", MacPro: "Mac Pro", Mac: "Mac" };
  function macNoun(device) { return device ? (macNouns[device] || "Mac") : null; }
  /// "Apple TV", "iPad" or the kind of Mac this zone plays from.
  function hubNoun() {
    if (!snap) return "iPad";
    return snap.hubKind === "tv" ? "Apple TV" : macNoun(snap.hubDevice) || "iPad";
  }
  /// "the Apple TV", "the iPad" or "the MacBook Air": whichever this zone plays from.
  function hubName() { return `the ${hubNoun()}`; }
  function deviceIcon(kind, device) {
    if (kind === "tv") return icons.tv;
    switch (device ? (macNouns[device] ? device : "Mac") : null) {
      case "MacBookAir": case "MacBookPro": return icons.laptop;
      case "Macmini": return icons.macmini;
      case "MacStudio": return icons.macstudio;
      case "MacPro": return icons.macpro;
      case "iMac": case "Mac": return icons.desktop;
      default: return icons.ipad;
    }
  }

  const icons = {
    ipad: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="5" width="19" height="14" rx="2.5"/></svg>',
    tv: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8 20.5h8"/></svg>',
    laptop: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M1.5 19h21"/></svg>',
    desktop: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="3.5" width="19" height="13" rx="2"/><path d="M2.5 13h19M9.5 20.5h5M12 16.5v4"/></svg>',
    macmini: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="8" width="18" height="8" rx="1.5"/><path d="M6 12h.01"/></svg>',
    macstudio: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="14" rx="2"/><path d="M8 15h.01M11 15h.01"/></svg>',
    macpro: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="3" width="12" height="18" rx="2"/><path d="M9.5 7.5h5M9.5 11h5M9.5 14.5h5"/></svg>',
    grip: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01" stroke-width="3"/></svg>',
    x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    lock: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
    check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5 9-10"/></svg>',
    warning: '<svg viewBox="0 0 24 24" aria-hidden="true" stroke-linejoin="round"><path d="M12 3.5 2.5 20h19z"/><path d="M12 10v4.5M12 17.5h.01"/></svg>',
    person: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
    play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l10.5-6.5z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>',
    pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6.5" y="5" width="4" height="14" rx="1.2"/><rect x="13.5" y="5" width="4" height="14" rx="1.2"/></svg>',
  };

  function fillRow(li, item) {
    // Spotify's own queue items are locked too: nothing here can move or remove them.
    const foreign = isForeign(item);
    const locked = foreign || snap.lockedNextID === item.id;
    const label = foreign ? null : requesterLabel(item);
    li.classList.add("row");
    li.classList.toggle("locked", locked);
    li.classList.toggle("foreign", foreign);
    li.dataset.id = item.id;
    li.innerHTML = "";

    const art = document.createElement("div");
    art.className = "art";
    setArt(art, item.track, false);

    const meta = document.createElement("div");
    meta.className = "row-meta";
    const title = document.createElement("p");
    title.className = "row-title";
    title.textContent = item.track.title;
    const sub = document.createElement("p");
    sub.className = "row-sub";
    sub.textContent = item.track.artist;
    meta.append(title, sub);
    li.append(art, meta);

    if (label) {
      const pill = document.createElement("span");
      pill.className = "pill" + (label.mine ? " mine" : "");
      pill.textContent = label.text;
      li.append(pill);
    }
    if (!locked && ((label && label.mine) || hosting())) {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "icon-btn remove";
      remove.setAttribute("aria-label", `Remove ${item.track.title}`);
      remove.innerHTML = icons.x;
      li.append(remove);
    }
    if (locked) {
      const lock = document.createElement("span");
      lock.className = "lock";
      lock.title = foreign ? `Queued on ${snap.service || "Spotify"}` : "Up next. Locked in.";
      lock.innerHTML = icons.lock;
      li.append(lock);
    } else if (snap.canReorder !== false || hosting()) {
      const handle = document.createElement("button");
      handle.type = "button";
      handle.className = "icon-btn handle";
      handle.setAttribute("aria-label", `Reorder ${item.track.title}`);
      handle.innerHTML = icons.grip;
      li.append(handle);
    }
  }

  // Live rows (up to 100 per snapshot, and most snapshots change none of them): only rows whose
  // content changed are rebuilt, only rows out of place are moved, and only rows on screen animate.
  const onScreen = new Set();
  const rowObserver = new IntersectionObserver((entries) => {
    for (const e of entries) { if (e.isIntersecting) onScreen.add(e.target); else onScreen.delete(e.target); }
  });

  /** Everything fillRow draws from, so a row is rebuilt only when it would look different. */
  function rowSignature(item) {
    const t = item.track, label = requesterLabel(item);
    return [t.title, t.artist, t.thumbnailURL || t.artworkURL || "", t.colors ? t.colors.background + t.colors.secondary : "",
      snap.lockedNextID === item.id, isForeign(item), label ? `${label.text}${label.mine}` : "", hosting(), snap.canReorder !== false].join("|");
  }

  function renderQueue() {
    const list = $("queue");
    // Spotify's own queue first (it plays first), then the zone's Up next.
    const items = [...foreignItems(snap), ...snap.upNext];
    const rows = list.children;
    const sameOrder = items.length === rows.length && items.every((item, i) => rows[i].dataset.id === item.id);
    // FLIP, first: where the rows on screen are, if any row comes, goes or moves.
    const before = new Map();
    if (!sameOrder && !firstRender) for (const el of onScreen) before.set(el, el.getBoundingClientRect().top);

    const keep = new Set(items.map((item) => item.id));
    for (const [id, el] of rowEls) {
      if (keep.has(id)) continue;
      rowObserver.unobserve(el);
      onScreen.delete(el);
      el.remove();
      rowEls.delete(id);
    }
    const added = [];
    let next = list.firstElementChild;
    for (const item of items) {
      let el = rowEls.get(item.id);
      if (!el) {
        el = document.createElement("li");
        rowEls.set(item.id, el);
        rowObserver.observe(el);
        if (!firstRender) { added.push(el); if (item.requester) flashIds.add(item.id); }
      }
      const signature = rowSignature(item);
      if (el.signature !== signature) { fillRow(el, item); el.signature = signature; }
      if (el === next) next = next.nextElementSibling;
      else list.insertBefore(el, next);
    }

    // FLIP, last and play: rows that were on screen slide from where they were.
    for (const [el, top] of before) {
      if (!el.isConnected) continue;
      const dy = top - el.getBoundingClientRect().top;
      if (Math.abs(dy) > 1) el.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], { duration: 380, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    }
    // New rows fade in where they can be seen (not a whole new playlist's worth).
    if (added.length <= 10) {
      for (const el of added) {
        const r = el.getBoundingClientRect();
        if (r.bottom < 0 || r.top > window.innerHeight) continue;
        el.animate(
          [{ opacity: 0, transform: "translateY(-8px) scale(0.98)" }, { opacity: 1, transform: "none" }],
          { duration: 420, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" }
        );
      }
    }

    for (const id of flashIds) flash(id);
    flashIds.clear();

    $("queue-empty").hidden = items.length > 0;
    firstRender = false;
    laterQueueChanged();
  }

  // MARK: Later (the base playlist past the live Up Next)

  // The same list carries on, read-only (no handle or remove), with the rest of the playlist's
  // cycle, a page at a time as the end comes near. It isn't in snapshots; when the queue moves on,
  // the rows already shown are fetched again so the list stays in step.
  const later = { rows: [], total: null, loading: false, generation: 0, version: null, refetchTimer: null, retryTimer: null, failures: 0 };
  const laterEls = new Map();

  function laterRow(row) {
    const li = document.createElement("li");
    li.className = "row later-row";
    li.dataset.id = row.id;
    const art = document.createElement("div");
    art.className = "art";
    setArt(art, { thumbnailURL: row.thumbnailURL }, false);
    const meta = document.createElement("div");
    meta.className = "row-meta";
    const title = document.createElement("p");
    title.className = "row-title";
    title.textContent = row.title;
    const sub = document.createElement("p");
    sub.className = "row-sub";
    sub.textContent = row.artist;
    meta.append(title, sub);
    li.append(art, meta);
    return li;
  }

  function renderLater() {
    const list = $("later");
    const keep = new Set(later.rows.map((r) => r.id));
    for (const [id, el] of laterEls) if (!keep.has(id)) { el.remove(); laterEls.delete(id); }
    let next = list.firstElementChild;
    for (const row of later.rows) {
      let el = laterEls.get(row.id);
      if (!el) { el = laterRow(row); laterEls.set(row.id, el); }
      if (el === next) next = next.nextElementSibling;
      else list.insertBefore(el, next);
    }
    list.hidden = later.rows.length === 0;
  }

  async function fetchLater(offset, count) {
    const rows = [];
    let page = null;
    while (rows.length < count) {
      page = await api(`/api/upcoming?offset=${offset + rows.length}&limit=${Math.min(100, count - rows.length)}`);
      rows.push(...page.rows);
      if (!page.rows.length) break;
    }
    return { rows, total: page ? page.total : 0, version: page ? page.version : null };
  }

  async function loadMoreLater() {
    clearTimeout(later.retryTimer);
    later.retryTimer = null;
    if (later.loading || (later.total !== null && later.rows.length >= later.total) || !snap || !snap.upNext.length) return;
    later.loading = true;
    const generation = later.generation;
    try {
      const page = await fetchLater(later.rows.length, 50);
      if (generation !== later.generation) return;
      later.rows.push(...page.rows.filter((r) => !laterEls.has(r.id)));
      later.total = page.total;
      later.version = page.version;
      later.failures = 0;
      renderLater();
    } catch {
      // The hub didn't answer (restarting, say): try again later, not straight away, which
      // asked it over and over as fast as each request failed. The socket coming back asks
      // at once.
      if (generation === later.generation) later.retryTimer = setTimeout(loadMoreLater, retryDelay(later.failures++));
      return;
    } finally {
      later.loading = false;
    }
    // Still near the end (a tall screen, or a short page): keep going.
    if (generation === later.generation && laterSentinelNear) loadMoreLater();
  }

  /** Fetches the rows already shown again, so nothing drifts as songs play or get added. */
  async function refetchLater() {
    const generation = ++later.generation;
    const count = Math.max(later.rows.length, 50);
    try {
      const page = await fetchLater(0, count);
      if (generation !== later.generation) return;
      later.rows = page.rows;
      later.total = page.total;
      later.version = page.version;
      renderLater();
    } catch {}
  }

  function laterQueueChanged() {
    if (!snap.upNext.length) { later.generation++; later.rows = []; later.total = null; renderLater(); return; }
    if (later.total === null) { if (laterSentinelNear) loadMoreLater(); return; }
    if (later.version === snap.version) return;
    // A song that just became live (the next one past the window) leaves here at once; the
    // refetch below brings the rest in step.
    const live = new Set(snap.upNext.map((item) => item.track.id));
    if (snap.current) live.add(snap.current.track.id);
    if (later.rows.some((r) => live.has(r.trackID))) {
      later.rows = later.rows.filter((r) => !live.has(r.trackID));
      renderLater();
    }
    // A burst of changes (a song ending, several adds) refetches once.
    clearTimeout(later.refetchTimer);
    later.refetchTimer = setTimeout(refetchLater, 250);
  }

  let laterSentinelNear = false;
  new IntersectionObserver((entries) => {
    laterSentinelNear = entries.some((e) => e.isIntersecting);
    if (laterSentinelNear) loadMoreLater();
  }, { rootMargin: "800px 0px" }).observe($("later-sentinel"));

  function flash(id) {
    const el = rowEls.get(id);
    if (!el) return;
    el.classList.add("flash");
    setTimeout(() => el.classList.remove("flash"), 60);
  }

  function updateProgress() {
    const fill = $("progress");
    const current = snap && nowPlaying(snap);
    if (!current || !current.track.duration) { fill.style.width = "0"; fill.classList.remove("started"); return; }
    const pb = snap.playback;
    const elapsed = pb.position + (pb.isPlaying ? (Date.now() - pb.capturedAt) / 1000 : 0);
    fill.style.width = `${Math.min(100, (elapsed / current.track.duration) * 100)}%`;
    fill.classList.toggle("started", elapsed > 0);
  }
  // Every frame while playing so the bar grows smoothly (a seek just jumps); browsers pause
  // frames in background tabs. Twice a second otherwise, which is plenty while paused.
  function progressLoop() {
    updateProgress();
    if (snap && snap.playback.isPlaying) requestAnimationFrame(progressLoop);
    else setTimeout(progressLoop, 500);
  }
  progressLoop();

  // MARK: Network

  async function api(path, body) {
    const res = await fetch(path, {
      method: body ? "POST" : "GET",
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    // The hub's reason (debug hubs describe the error in full), for the debug log. A refusal the
    // page can show (409, {error}) comes with it as `reason`.
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      const error = new Error(`${path} ${res.status} ${text.slice(0, 600)}`);
      if (res.status === 409) { try { error.reason = JSON.parse(text); } catch {} }
      throw error;
    }
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  /** How long to wait before asking an unreachable hub again, after `failures` tries in a row:
   * doubling from 0.5 s to at most 4 s, each somewhere in its upper half, so a room of phones
   * that lost the hub together don't all ask again at the same moment. */
  function retryDelay(failures) {
    const delay = Math.min(500 * 2 ** failures, 4000);
    return delay / 2 + Math.random() * (delay / 2);
  }

  let socket = null;
  let retries = 0;
  let offlineTimer = null;
  let reconnectTimer = null;
  function connect() {
    if (socket && socket.readyState <= 1) return;
    // One way back at a time: a connect from elsewhere (the page shown again) replaces the
    // waiting one rather than start a second chain of retries.
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    // With the Host Control key, the hub adds what only hosts see (an Apple TV's music access).
    const key = hostKey ? `?key=${encodeURIComponent(hostKey)}` : "";
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws${key}`);
    socket = ws;
    ws.onopen = () => {
      retries = 0;
      clearTimeout(offlineTimer);
      $("offline").hidden = true;
      // The rest of Up next, if it couldn't load while the hub was away.
      if (later.retryTimer) loadMoreLater();
    };
    ws.onmessage = (event) => applySnapshot(JSON.parse(event.data));
    ws.onclose = () => {
      if (ws !== socket) return;
      clearTimeout(offlineTimer);
      offlineTimer = setTimeout(() => { $("offline").hidden = false; }, 1500);
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, retryDelay(retries++));
    };
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) connect(); });
  addEventListener("online", connect);

  // MARK: Queue interactions

  $("queue").addEventListener("click", async (event) => {
    const remove = event.target.closest(".remove");
    if (!remove) return;
    const li = remove.closest(".row");
    const id = li.dataset.id;
    const fade = li.animate([{ opacity: 1 }, { opacity: 0, transform: "translateX(24px)" }], { duration: 200, fill: "forwards" });
    try {
      // Removing your own song: say it with the ID it was added under.
      const item = snap && snap.upNext.find((i) => i.id === id);
      const owner = item && item.requester && myIds.has(item.requester.clientID) ? item.requester.clientID : clientId;
      await api("/api/remove", { id, clientId: owner, key: hosting() ? hostKey : undefined });
    } catch {
      toast("Couldn't remove that one");
      fade.cancel();
    }
  });

  $("queue").addEventListener("pointerdown", (event) => {
    const handle = event.target.closest(".handle");
    if (!handle || !snap || (snap.canReorder === false && !hosting())) return;
    event.preventDefault();
    const list = $("queue");
    const li = handle.closest(".row");
    const rows = [...list.children];
    const from = rows.indexOf(li);
    // Nothing goes above the locked rows at the top: Spotify's own queue, then the locked next song.
    let floor = 0;
    while (rows[floor] && rows[floor].classList.contains("locked")) floor++;
    dragging = {
      li, rows, from, to: from, floor,
      rects: rows.map((r) => r.getBoundingClientRect()),
      startY: event.clientY, lastY: event.clientY, scrollStart: window.scrollY,
      height: li.getBoundingClientRect().height,
    };
    handle.setPointerCapture(event.pointerId);
    li.classList.add("dragging");
    list.classList.add("is-dragging");
    if (navigator.vibrate) navigator.vibrate(8);
    dragging.autoScroll = setInterval(autoScroll, 16);
  });

  function autoScroll() {
    if (!dragging) return;
    const edge = 90, y = dragging.lastY;
    let delta = 0;
    if (y < edge) delta = -Math.ceil((edge - y) / 8);
    else if (y > window.innerHeight - edge) delta = Math.ceil((y - (window.innerHeight - edge)) / 8);
    if (delta) { window.scrollBy(0, delta); positionDrag(); }
  }

  function positionDrag() {
    const d = dragging;
    const dy = d.lastY - d.startY + (window.scrollY - d.scrollStart);
    d.li.style.transform = `translateY(${dy}px)`;
    const center = d.rects[d.from].top + d.height / 2 + dy;
    let to = 0;
    d.rows.forEach((row, i) => {
      if (i === d.from) return;
      if (d.rects[i].top + d.rects[i].height / 2 < center) to++;
    });
    to = Math.max(to, d.floor);
    d.to = to;
    d.rows.forEach((row, i) => {
      if (i === d.from) return;
      const pos = i < d.from ? i : i - 1;
      let shift = 0;
      if (i < d.from && pos >= to) shift = d.height;
      if (i > d.from && pos < to) shift = -d.height;
      row.style.transform = shift ? `translateY(${shift}px)` : "";
    });
  }

  $("queue").addEventListener("pointermove", (event) => {
    if (!dragging) return;
    dragging.lastY = event.clientY;
    positionDrag();
  });

  function endDrag() {
    if (!dragging) return;
    const d = dragging;
    clearInterval(d.autoScroll);
    const list = $("queue");
    const visualTops = new Map(d.rows.map((r) => [r, r.getBoundingClientRect().top]));
    d.rows.forEach((r) => { r.style.transform = ""; });
    d.li.classList.remove("dragging");
    list.classList.remove("is-dragging");

    const order = d.rows.filter((r) => r !== d.li);
    order.splice(d.to, 0, d.li);
    order.forEach((r) => list.appendChild(r));
    for (const [r, top] of visualTops) {
      const dy = top - r.getBoundingClientRect().top;
      if (Math.abs(dy) > 1) r.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], { duration: 220, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    }
    dragging = null;

    const id = d.li.dataset.id;
    if (d.to !== d.from) {
      // Spotify's own queue rows aren't in the zone's Up next: dropped just below them is its top.
      const above = d.to === 0 ? null : order[d.to - 1];
      const after = above && !above.classList.contains("foreign") ? above.dataset.id : null;
      // Optimistic local reorder so an incoming snapshot doesn't bounce the row back.
      const items = snap.upNext.slice();
      const [moved] = items.splice(items.findIndex((i) => i.id === id), 1);
      items.splice(Math.max(0, d.to - foreignItems(snap).length), 0, moved);
      snap = { ...snap, upNext: items };
      api("/api/move", { id, after, key: hosting() ? hostKey : undefined }).catch(() => toast("Couldn't move that one"));
    }
    if (pendingSnap) { const next = pendingSnap; pendingSnap = null; applySnapshot(next); }
  }
  $("queue").addEventListener("pointerup", endDrag);
  $("queue").addEventListener("pointercancel", endDrag);

  // While a sheet is open, it scrolls and the page behind it doesn't (iOS Safari otherwise can
  // hand the scroll to the page underneath).
  const sheets = [...document.querySelectorAll(".sheet")];
  const syncPageLock = () => document.documentElement.classList.toggle("sheet-open", sheets.some((sheet) => !sheet.hidden));
  const sheetWatcher = new MutationObserver(() => {
    // Opened again later, a first-screen sheet slides in like the others.
    for (const sheet of sheets) if (sheet.hidden) sheet.classList.remove("instant");
    syncPageLock();
  });
  for (const sheet of sheets) sheetWatcher.observe(sheet, { attributes: true, attributeFilter: ["hidden"] });
  // Picker sheets fit the part of the screen that's visible, above the keyboard when it's up
  // (iOS Safari then also pans the page, by offsetTop).
  if (window.visualViewport) {
    const fitViewport = () => {
      const root = document.documentElement.style;
      root.setProperty("--vvh", `${Math.round(visualViewport.height)}px`);
      root.setProperty("--vvt", `${Math.max(0, Math.round(visualViewport.offsetTop))}px`);
    };
    visualViewport.addEventListener("resize", fitViewport);
    visualViewport.addEventListener("scroll", fitViewport);
    fitViewport();
  }
  // Setup: the field being typed in (with its label) moves to the top of the sheet, once iOS has
  // opened the keyboard and done its own scrolling; the playlist search then has its results below.
  for (const scroller of [$("setup-zone-scroll"), $("setup-spotify-scroll"), $("setup-scroll")]) scroller.addEventListener("focusin", (event) => {
    const search = event.target.matches('input[type="search"]') ? event.target.closest(".picker-search") : null;
    const field = search || (event.target.matches("input.text-input") ? event.target : null);
    if (!field) return;
    const target = search || field.previousElementSibling || field;
    setTimeout(() => {
      if (document.activeElement !== event.target) return;
      const top = target.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
      const before = scroller.scrollTop;
      scroller.scrollTo({ top: Math.max(0, top - 8), behavior: "smooth" });
      const vv = window.visualViewport;
      setTimeout(() => debugLog(`focus ${event.target.id}: scroll ${Math.round(before)}→${Math.round(top - 8)} now ${Math.round(scroller.scrollTop)} of ${scroller.scrollHeight - scroller.clientHeight} vv=${vv && Math.round(vv.height)}@${vv && Math.round(vv.offsetTop)} inner=${innerHeight} winY=${Math.round(scrollY)}`), 800);
    }, 350);
  });

  // MARK: Search

  let results = [];
  let searchAbort = null;
  let searchTimer = null;

  function openSearch() {
    $("search").hidden = false;
    $("search-input").focus();
    document.body.style.overflow = "hidden";
  }
  // Items added while search was open get flashed when you come back to the queue.
  const addedWhileSearching = [];
  function closeSearch() {
    $("search").hidden = true;
    document.body.style.overflow = "";
    $("search-input").blur();
    // Back to the top of the queue, unless a song added while searching would be out of sight.
    window.scrollTo({ top: 0 });
    const first = addedWhileSearching.map((id) => rowEls.get(id)).find(Boolean);
    if (first && first.getBoundingClientRect().bottom > window.innerHeight) {
      first.scrollIntoView({ block: "center", behavior: "smooth" });
    }
    addedWhileSearching.splice(0).forEach((id) => setTimeout(() => flash(id), 250));
  }
  $("search-trigger").addEventListener("click", openSearch);
  $("search-cancel").addEventListener("click", closeSearch);
  // Inside the field's <label>: stop the click from also focusing through the label.
  $("search-clear").addEventListener("click", (event) => {
    event.preventDefault();
    clearTimeout(searchTimer);
    $("search-input").value = "";
    $("search-clear").hidden = true;
    runSearch();
    $("search-input").focus();
  });

  $("search-input").addEventListener("input", () => {
    $("search-clear").hidden = !$("search-input").value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, 280);
  });
  $("search-input").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); clearTimeout(searchTimer); runSearch(); $("search-input").blur(); }
  });

  async function runSearch() {
    const term = $("search-input").value.trim();
    if (searchAbort) searchAbort.abort();
    if (!term) { results = []; renderResults(); return; }
    searchAbort = new AbortController();
    try {
      // Hosts also find the hub's own library songs.
      const key = hosting() ? `&key=${encodeURIComponent(hostKey)}` : "";
      const res = await fetch(`/api/search?q=${encodeURIComponent(term)}${key}`, { signal: searchAbort.signal });
      if (!res.ok) throw new Error(`${res.status}`);
      results = await res.json();
      renderResults(term);
    } catch (error) {
      if (error.name === "AbortError") return;
      results = [];
      renderResults(term, "Search isn't working right now. Try again in a moment.");
    }
  }

  function renderResults(term, errorText) {
    const list = $("results");
    list.innerHTML = "";
    for (const track of results) {
      const li = document.createElement("li");
      li.className = "row";
      li.dataset.trackId = track.id;
      const art = document.createElement("div");
      art.className = "art";
      setArt(art, track, false);
      const meta = document.createElement("div");
      meta.className = "row-meta";
      const title = document.createElement("p");
      title.className = "row-title";
      title.textContent = track.title;
      if (track.isExplicit) {
        const badge = document.createElement("span");
        badge.className = "explicit";
        badge.textContent = "E";
        badge.title = "Explicit";
        title.append(" ", badge);
      }
      // The hub's own library copy (a host's search): its art and titles are the library's.
      if (track.libraryID) {
        const tag = document.createElement("span");
        tag.className = "library-tag";
        tag.textContent = "Library";
        title.append(" ", tag);
      }
      const sub = document.createElement("p");
      sub.className = "row-sub";
      sub.textContent = track.album ? `${track.artist} · ${track.album}` : track.artist;
      meta.append(title, sub);
      const button = document.createElement("button");
      button.type = "button";
      button.className = "add-btn";
      button.textContent = "Add";
      li.append(art, meta, button);
      list.append(li);
    }
    const empty = $("results-empty");
    empty.hidden = results.length > 0 || !term;
    empty.textContent = errorText || `No songs found for “${term || ""}”.`;
    updateResultButtons();
  }

  function updateResultButtons() {
    if (!snap) return;
    const queued = new Set(snap.upNext.filter((i) => i.requester).map((i) => i.track.id));
    const playing = snap.current && snap.current.track.id;
    for (const li of $("results").children) {
      const button = li.querySelector(".add-btn");
      if (button.dataset.busy) continue;
      const id = li.dataset.trackId;
      if (id === playing) { setButton(button, "Playing", true); }
      else if (queued.has(id)) { setButton(button, "Queued", true); }
      else { setButton(button, "Add", false); }
    }
  }

  function setButton(button, text, done) {
    button.classList.toggle("done", done);
    button.disabled = done;
    button.innerHTML = done && text === "Queued" ? `${icons.check}` : "";
    if (!(done && text === "Queued")) button.textContent = text;
    button.setAttribute("aria-label", text);
  }

  $("results").addEventListener("click", async (event) => {
    const button = event.target.closest(".add-btn");
    if (!button || button.disabled) return;
    const li = button.closest(".row");
    const track = results.find((t) => t.id === li.dataset.trackId);
    if (!track) return;
    button.dataset.busy = "1";
    button.disabled = true;
    button.textContent = "…";
    try {
      const reply = await api("/api/add", { track, name: myName, clientId, key: hosting() ? hostKey : undefined });
      if (reply.result === "added") {
        addedWhileSearching.push(reply.itemId);
        toast(`Added · #${reply.index + 1} in line`);
      } else if (reply.result === "alreadyQueued") {
        toast(`Already queued · #${reply.index + 1} in line`);
      } else {
        toast("That's playing right now");
      }
      delete button.dataset.busy;
      setButton(button, "Queued", true);
    } catch {
      delete button.dataset.busy;
      setButton(button, "Add", false);
      toast("Couldn't add that. Try again.");
    }
  });

  // MARK: Toast

  let toastTimer = null;
  function toast(text, duration = 2200) {
    const el = $("toast");
    el.textContent = text;
    el.classList.add("shown");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("shown"), duration);
  }

  // MARK: Name

  function updateNameChip() {
    // Name first (with the person icon), then the Host/Guest switch on paired phones.
    const name = $("name-chip");
    name.innerHTML = icons.person;
    const label = document.createElement("span");
    label.className = "name-text";
    label.textContent = myName ? myName : "Add your name";
    name.append(label);
    const mode = $("mode-chip");
    mode.hidden = !hostPaired;
    mode.classList.toggle("on", hostMode);
    mode.textContent = hostMode ? "Host" : "Guest";
    mode.setAttribute("aria-label", hostMode ? "Host control on. Switch to guest view" : "Guest view. Switch to host control");
  }
  $("mode-chip").addEventListener("click", () => {
    hostMode = !hostMode;
    store.set("canopymusic.hostMode", hostMode ? "host" : "guest");
    updateNameChip();
    if (snap) render();
  });

  // MARK: Host: base playlist, zone settings, another host, first setup

  let playlistsLoad = null;
  let setupPick = null;
  let setupDismissed = false;
  let setupStarting = false;
  /** Continue was pressed and the TV is checking for another zone on the Spotify account. */
  let checkingConflict = false;
  const keyQuery = () => `key=${encodeURIComponent(hostKey || "")}`;

  function renderHost() {
    const on = hosting();
    $("settings-btn").hidden = !on;
    if (!on) {
      for (const id of ["setup", "settings-modal", "edit-modal", "wifi-modal", "invite-modal", "playlists", "conflict-modal", "devices-modal"]) $(id).hidden = true;
      if (hostChecked) askNameIfNeeded();
      return;
    }
    // A TV zone has no screens of its own for setup: the first host does it here (with their
    // name, instead of the name prompt).
    const needsSetup = snap.hubKind === "tv" && !snap.playlistName && !setupDismissed;
    if (needsSetup && $("setup").hidden) openSetup();
    // Kept open while starting, until the hub answers.
    if (!needsSetup && !setupStarting) $("setup").hidden = true;
    // The setup sheet went away without this phone starting it (another host did): ask now.
    if (!needsSetup) askNameIfNeeded();
  }

  /** The hub's library playlists, loaded once (a load that fails is tried again next time). */
  function loadPlaylists() {
    if (!playlistsLoad) playlistsLoad = api(`/api/host/playlists?${keyQuery()}`).catch((error) => { playlistsLoad = null; throw error; });
    return playlistsLoad;
  }

  // A searchable playlist list (Change base playlist, and a TV zone's first setup). Typing filters
  // the library (ignoring case and accents) and, as on the iPad, searches the music service's
  // playlists, shown below. Rows are built once per load; filtering only hides them.
  const fold = (text) => (text || "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

  /** Song counts the playlist list came without (Apple Music), fetched as rows scroll into view,
   * and counts the hub found on a load (an empty playlist refused). By playlist ID. */
  const songCounts = new Map();
  const countText = (n) => n === 0 ? "No songs" : n === 1 ? "1 song" : `${n.toLocaleString()} songs`;

  /** "24 songs · Updated yesterday" (no count until it's known); an empty playlist is dimmed and
   * can't be picked, but stays listed so nobody thinks it's missing. */
  function showCount(li, p) {
    const count = songCounts.get(p.id) ?? p.songCount;
    li.querySelector(".row-sub").textContent = [count == null ? null : countText(count), p.subtitle].filter(Boolean).join(" · ");
    li.classList.toggle("no-songs", count === 0);
    li.setAttribute("aria-disabled", count === 0 ? "true" : "false");
  }

  function playlistRow(p, onPick) {
    const li = document.createElement("li");
    li.className = "playlist-row";
    li.dataset.id = p.id;
    const art = document.createElement("div");
    art.className = "art";
    setArt(art, { thumbnailURL: p.artworkURL }, false);
    const meta = document.createElement("div");
    const title = document.createElement("p");
    title.textContent = p.name;
    const sub = document.createElement("p");
    sub.className = "row-sub";
    meta.append(title, sub);
    li.append(art, meta);
    li.playlist = p;
    showCount(li, p);
    li.addEventListener("click", () => { if (!li.classList.contains("no-songs")) onPick(p); });
    return li;
  }

  /** Counts library rows that came without one as they scroll into view, a batch at a time
   * (`/api/host/playlists/counts`; the hub counts a few playlists at once). */
  function rowCounter(scroll) {
    const waiting = new Map();
    let timer = null;
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        observer.unobserve(entry.target);
        waiting.set(entry.target.dataset.id, entry.target);
      }
      clearTimeout(timer);
      if (waiting.size) timer = setTimeout(flush, 120);
    }, { root: scroll, rootMargin: "200px 0px" });
    async function flush() {
      const rows = [...waiting.values()].slice(0, 20);
      for (const li of rows) waiting.delete(li.dataset.id);
      try {
        const counts = await api(`/api/host/playlists/counts?${keyQuery()}&ids=${rows.map((li) => encodeURIComponent(li.dataset.id)).join(",")}`);
        for (const li of rows) {
          if (counts[li.dataset.id] == null) continue;
          songCounts.set(li.dataset.id, counts[li.dataset.id]);
          showCount(li, li.playlist);
        }
      } catch {}
      if (waiting.size) flush();
    }
    return {
      watch(li) {
        if (li.playlist.kind === "library" && li.playlist.songCount == null && !songCounts.has(li.dataset.id)) observer.observe(li);
      },
      reset() { observer.disconnect(); waiting.clear(); clearTimeout(timer); },
    };
  }

  function playlistPicker(prefix, listId, emptyId, onPick) {
    const list = $(listId), empty = $(emptyId), search = $(`${prefix}-search`);
    const catalogList = $(`${prefix}-catalog`), catalogHead = $(`${prefix}-catalog-head`);
    const counter = rowCounter($(`${prefix}-scroll`));
    let rows = [], loaded = false, timer = null, generation = 0;

    function showEmpty(text, spinning = false) {
      empty.hidden = !text;
      empty.textContent = text || "";
      if (spinning) { const s = document.createElement("span"); s.className = "spinner"; empty.prepend(s); }
    }

    function filter() {
      const term = fold(search.value.trim());
      let shown = 0;
      for (const li of rows) {
        const hit = !term || li.dataset.name.includes(term);
        if (li.hidden === hit) li.hidden = !hit;
        if (hit) shown++;
      }
      if (loaded) showEmpty(shown ? "" : rows.length ? "No matches in your playlists." : "No playlists in this library.");
      clearTimeout(timer);
      timer = setTimeout(searchCatalog, 300);
    }

    // Spotify's catalog playlists aren't offered (as on the iPad): its Development Mode can't read
    // songs from playlists you don't own.
    async function searchCatalog() {
      const term = search.value.trim();
      const run = ++generation;
      if (!term || (snap && snap.service === "Spotify")) { catalogList.innerHTML = ""; catalogHead.hidden = true; return; }
      try {
        const found = await api(`/api/host/playlists/search?${keyQuery()}&q=${encodeURIComponent(term)}`);
        if (run !== generation) return;
        catalogList.innerHTML = "";
        for (const p of found) catalogList.append(playlistRow(p, onPick));
        catalogHead.hidden = !found.length;
        catalogHead.textContent = `${snap && snap.service ? snap.service : "More"} playlists`;
      } catch {}
    }
    search.addEventListener("input", () => {
      filter();
      // Back to the first match, keeping the search where it is if it's stuck to the top.
      const scroll = $(`${prefix}-scroll`);
      const top = list.offsetTop - search.closest(".picker-search").offsetHeight;
      if (scroll.scrollTop > top) scroll.scrollTop = Math.max(0, top);
    });

    return {
      async open() {
        search.value = "";
        catalogList.innerHTML = "";
        catalogHead.hidden = true;
        $(`${prefix}-scroll`).scrollTop = 0;
        if (!loaded) showEmpty("Loading playlists…", true);
        try {
          const playlists = await loadPlaylists();
          if (!loaded) {
            list.innerHTML = "";
            rows = playlists.map((p) => {
              const li = playlistRow(p, onPick);
              li.dataset.name = fold(p.name);
              return li;
            });
            list.append(...rows);
            for (const li of rows) counter.watch(li);
            loaded = true;
          }
          filter();
        } catch {
          showEmpty("Couldn't load playlists.");
        }
      },
      /** Forgets the loaded playlists (the hub changed service): the next open loads them again. */
      reset() {
        counter.reset();
        loaded = false;
        rows = [];
        list.innerHTML = "";
        catalogList.innerHTML = "";
        catalogHead.hidden = true;
      },
      /** The hub refused `p` (nothing to play in it): unchecked, and dimmed if it's empty. */
      refused(p, reason) {
        if (reason.empty) songCounts.set(p.id, 0);
        for (const li of [...rows, ...catalogList.children]) if (li.dataset.id === p.id) showCount(li, li.playlist);
        this.select(null);
      },
      /** Checks the chosen row (none for null). */
      select(id) {
        for (const li of [...rows, ...catalogList.children]) {
          const on = li.dataset.id === id;
          li.classList.toggle("selected", on);
          const check = li.querySelector(".check");
          if (on && !check) { const c = document.createElement("span"); c.className = "check"; c.innerHTML = icons.check; li.append(c); }
          if (!on && check) check.remove();
        }
      },
    };
  }

  /** "3 songs aren't on Apple Music: “A”, “B” and “C”." when the base playlist loaded without some
   * of its songs (`skippedOnLoad`, `skippedTitles` and `service` as in snapshots); "" otherwise. */
  function skippedNote(s) {
    const n = s.skippedOnLoad || 0;
    if (!n) return "";
    const head = `${n} ${n === 1 ? "song isn't" : "songs aren't"} on ${s.service || "this music service"}`;
    const titles = (s.skippedTitles || []).map((t) => `“${t}”`);
    if (!titles.length) return `${head}.`;
    const list = titles.length === 1 ? titles[0] : `${titles.slice(0, -1).join(", ")} and ${titles[titles.length - 1]}`;
    return n > titles.length ? `${head}, including ${list}.` : `${head}: ${list}.`;
  }

  /** An Apple TV has no screen for it, so its hosts hear once, when they choose the playlist.
   * Returns whether it showed the note. */
  function toastSkipped(reply) {
    if (snap && snap.hubKind === "tv" && reply && reply.skippedOnLoad) {
      toast(skippedNote({ ...reply, service: snap.service }), 6000);
      return true;
    }
    return false;
  }

  /** A picker's footer button: a spinner and `busyLabel` while the hub works, the list and Shuffle dimmed. */
  function pickerBusy(prefix, button, busy, label) {
    button.disabled = busy;
    button.querySelector(".spinner").hidden = !busy;
    button.querySelector(".label").textContent = label;
    $(`${prefix}-shuffle`).disabled = busy;
    $(prefix).classList.toggle("busy", busy);
  }

  // Changing the base playlist from the host page (on top of the settings sheet): a row selects,
  // the button confirms. The sheet stays open, with a spinner in the button, until the hub has
  // loaded it (a big library playlist can take several seconds).
  let changePick = null;
  const changePicker = playlistPicker("playlists", "playlist-list", "playlists-empty", (p) => {
    if ($("playlists").classList.contains("busy")) return;
    changePick = p;
    $("playlists-use").disabled = false;
    changePicker.select(p.id);
  });
  $("playlists-use").addEventListener("click", async () => {
    const sheet = $("playlists"), button = $("playlists-use"), p = changePick;
    if (!p || sheet.classList.contains("busy")) return;
    // Once a song has played, the hub keeps it playing and keeps the requests (only the old
    // playlist's songs go), so there's nothing to ask. Before that, a load starts the queue over.
    const startsOver = !!(snap && !snap.current && snap.upNext.some((item) => item.requester));
    if (startsOver && !confirm(`Switch to "${p.name}"? The queue starts over and requests are cleared.`)) return;
    pickerBusy("playlists", button, true, "Loading…");
    try {
      const reply = await api("/api/host/playlist", {
        key: hostKey, playlist: p, play: !!(snap && snap.playback.isPlaying), shuffle: $("playlists-shuffle").checked,
      });
      sheet.hidden = true;
      toastSkipped(reply);
    } catch (error) {
      // Nothing to play in it (and nothing changed): say so, and stay to choose another.
      if (error.reason) {
        changePick = null;
        changePicker.refused(p, error.reason);
        toast(error.reason.error, 5000);
      } else {
        toast("Couldn't change the playlist");
      }
    }
    finally { pickerBusy("playlists", button, false, "Use this playlist"); button.disabled = !changePick; }
  });
  $("settings-playlist-change").addEventListener("click", () => {
    changePick = null;
    $("playlists-use").disabled = true;
    $("playlists-shuffle").checked = true;
    changePicker.select(null);
    $("playlists").hidden = false;
    changePicker.open();
  });
  $("playlists-done").addEventListener("click", () => { $("playlists").hidden = true; });

  // Setup has two pages: the zone (names, and whether the TV can play Apple Music), then the
  // base playlist with Start the music.
  function openSetup() {
    // The setup sheet asks for this phone's name itself.
    if (!$("name-modal").hidden) { $("name-modal").hidden = true; }
    $("setup").hidden = false;
    showSetupPage("zone", false);
    debugScreen("setup opened");
    $("setup-you").value = myName || "";
    $("setup-name").value = snap.zoneName || "";
    // Back from signing in to Spotify (the page reloaded): what was typed before it left.
    try {
      const draft = JSON.parse(sessionStorage.getItem("canopymusic.setupDraft") || "null");
      sessionStorage.removeItem("canopymusic.setupDraft");
      if (draft) { $("setup-you").value = draft.you || ""; if (draft.name) $("setup-name").value = draft.name; }
    } catch {}
    setupAddress();
    spotifyFieldsFilled = false;
    returnPending = true;
    renderSetupMusic();
  }

  /** Back from Spotify's sign-in (the page reloaded at `/`): signed in, to the zone page with
   * Spotify chosen (it's chosen only now, when the sign-in left from Apple Music); still signed
   * out, to Spotify's page again, which says what to check. Once, when the TV's Spotify state
   * has arrived (hosts' snapshots). */
  let returnPending = false;
  function returnFromSpotify() {
    if (!returnPending || !spotify) return;
    returnPending = false;
    const intent = spotifySignInIntent();
    if (!intent) return;
    if (spotify.account === "signedIn") {
      try { sessionStorage.removeItem("canopymusic.spotifySignIn"); } catch {}
      if (intent === "switch" && !isSpotify()) chooseService("spotify");
    } else {
      showSetupPage("spotify", false);
    }
  }

  /** What was typed on the zone page, kept while the phone visits Spotify's sign-in page. */
  function saveSetupDraft() {
    try { sessionStorage.setItem("canopymusic.setupDraft", JSON.stringify({ you: $("setup-you").value, name: $("setup-name").value })); } catch {}
  }

  /** Setup's pages: the zone; Spotify's setup (from the Music bar); the base playlist. */
  const setupPages = { zone: "setup-zone", spotify: "setup-spotify-page", music: "setup-music-page" };

  /** Shows one of setup's pages; going back to the zone page slides in from the other side. */
  function showSetupPage(page, animated = true) {
    const zone = page === "zone", to = $(setupPages[page]);
    for (const id of Object.values(setupPages)) {
      const from = $(id);
      if (from === to) continue;
      if (document.activeElement && from.contains(document.activeElement)) document.activeElement.blur();
      from.hidden = true;
    }
    closeServiceMenu();
    to.hidden = false;
    to.classList.remove("entering", "back");
    if (animated) {
      void to.offsetWidth; // restarts the animation
      to.classList.add("entering");
      to.classList.toggle("back", zone);
    }
    if (page === "spotify") {
      // Filled again from the TV each time it opens (a sign-in elsewhere may have changed them).
      spotifyFieldsFilled = false;
      $("setup-spotify-scroll").scrollTop = 0;
      renderSpotifySetup();
    }
    if (zone) checkMusicAccess(true);
  }
  for (const page of document.querySelectorAll(".setup-page")) {
    page.addEventListener("animationend", () => page.classList.remove("entering", "back"));
  }

  // While the zone page shows, the TV checks its Apple Music access again every few seconds until
  // it can play (each check also asks for access on the TV if it never has); the answer comes in
  // snapshots. `now`: check even if it's fine (the page just opened, or came back into view).
  // With Spotify the TV reads its sign-in and devices again each time (a device can go to sleep).
  let musicCheckTimer = null;
  function checkMusicAccess(now = false) {
    clearTimeout(musicCheckTimer);
    musicCheckTimer = null;
    if ($("setup").hidden || $("setup-zone").hidden || !hosting()) return;
    if (now || isSpotify() || musicAccess !== "ok") {
      api("/api/host/music-check", { key: hostKey }).catch((error) => debugLog(`music check failed: ${error.message}`));
    }
    // The Sonos rooms too: which are busy or don't answer, and an account linked meanwhile.
    if (sonosSetup) api("/api/host/sonos/read", { key: hostKey }).catch(() => {});
    musicCheckTimer = setTimeout(checkMusicAccess, 4000);
  }

  /** The zone plays Spotify (an Apple TV set up for it on this page). */
  const isSpotify = () => !!snap && snap.service === "Spotify";

  /** What the Music bar says for Spotify: `what` (bold) and `todo`, and whether it can play. */
  function spotifyStatus(s) {
    if (!s) return { state: "checking" };
    if (s.conflictZone) {
      return { state: "problem", what: `${s.conflictZone} is using this Spotify account.`, todo: "End it to start a zone here, or join it as a display." };
    }
    if (s.account === "notSetUp") return { state: "problem", what: "Not connected.", todo: "" };
    if (s.account === "signedOut") {
      if (s.signingIn) return { state: "checking", what: "Signing in…", todo: "Finish on Spotify's page." };
      if (s.signInError) return { state: "problem", what: "Couldn't sign in.", todo: s.signInError };
      return { state: "problem", what: "Not connected.", todo: "" };
    }
    const who = s.displayName ? `Signed in as ${s.displayName}` : "Signed in";
    // On Sonos rooms, Spotify Connect isn't used: the rooms' own readiness shows under Plays on.
    if (outputPlace() === "sonos") return { state: "ok", what: "", todo: who, ready: true };
    if (!s.devices) return { state: "checking", what: `${who}.`, todo: "Looking for devices…" };
    const chosen = s.deviceID && s.devices.find((d) => d.id === s.deviceID);
    if (chosen) return { state: "ok", what: "", todo: who, ready: true };
    if (s.deviceID) {
      return { state: "problem", what: `${s.deviceName || "The chosen device"} isn't available.`, todo: "Open Spotify on it, or choose another device below." };
    }
    if (!s.devices.length) {
      return { state: "problem", what: "No devices found.", todo: "Open Spotify on a speaker, phone, or computer on this Wi‑Fi." };
    }
    return { state: "problem", what: `${who}.`, todo: "Choose where music plays below." };
  }

  /** Spotify is signed in and its chosen device is there (as the TV's `SpotifySetup.isReady`). */
  const spotifyReady = (s) => !!(s && s.account === "signedIn" && s.devices && s.devices.some((d) => d.id === s.deviceID));
  /** Sonos rooms are chosen as where the music plays. */
  const sonosChosen = () => !!(sonosSetup && sonosSetup.chosen && sonosSetup.chosen.length);
  /** Plays on's switch as the host last set it ("sonos" or "own"); null: as the hub says (Sonos
   * while rooms are chosen). Sonos with no room ticked yet shows the rooms, nothing chosen. */
  let placePicked = null;
  /** Where the switch is: "sonos" (the rooms) or "own" (the Spotify device, or This Apple TV). */
  const outputPlace = () => !sonosShown() ? "own" : placePicked || (sonosChosen() ? "sonos" : "own");
  /** Where music plays can play: Sonos rooms found with an account to stream from, or (Spotify)
   * the chosen Connect device listed; this Apple TV always can. */
  const outputReady = () => outputPlace() === "sonos" ? sonosChosen() && !!sonosSetup.ready : !isSpotify() || spotifyReady(spotify);
  /** The zone's music can play: Apple Music ready, or Spotify signed in, and where it plays ready.
   * Another zone on the Spotify account doesn't count here: Continue asks about it. */
  const setupReady = () => (isSpotify() ? spotifySignedIn(spotify) : musicAccess === "ok") && outputReady();
  document.addEventListener("visibilitychange", () => { if (!document.hidden) checkMusicAccess(true); });

  // What the Music bar says when the TV can't play Apple Music: what's wrong, then what to do.
  const musicNotes = {
    notDetermined: ["Allow Apple Music on the TV.", "Choose Allow when the Apple TV asks."],
    denied: ["Apple Music isn't allowed on the TV.",
      "On the Apple TV, go to Settings › General › Privacy & Security › Media & Apple Music and turn on Canopy Music."],
    noSubscription: ["No Apple Music subscription.", "The Apple Account on this Apple TV needs an Apple Music subscription."],
    error: ["Couldn't reach Apple Music.", "Check the Apple TV is signed in and online."],
  };
  /** A zone name the hub can use: something besides spaces and punctuation. */
  const setupNameValid = () => /[\p{L}\p{N}]/u.test($("setup-name").value);

  /** The Music bar (the service, and whether the TV can play it), Spotify's setup under it, and
   * Continue. */
  let shownService;
  function renderSetupMusic() {
    const bar = $("setup-music"), note = $("setup-music-note"), state = $("setup-music-state");
    const spotifyZone = isSpotify();
    // Another service: its playlists, and the one picked, are the old service's; Plays on's
    // switch goes back to what the hub says.
    if (shownService !== undefined && shownService !== snap.service) {
      resetPlaylists();
      placePicked = null;
    }
    shownService = snap.service;

    let status;
    if (spotifyZone) {
      status = spotifyStatus(spotify);
    } else {
      const ok = musicAccess === "ok", checking = musicAccess == null;
      const [what, todo] = ok || checking ? ["", ""] : musicNotes[musicAccess] || musicNotes.error;
      status = { state: ok ? "ok" : checking ? "checking" : "problem", what, todo };
    }
    const shown = JSON.stringify([snap.service, status]);
    if (bar.dataset.shown !== shown) {
      bar.dataset.shown = shown;
      bar.dataset.state = status.state;
      $("setup-music-icon").src = spotifyZone ? "/spotify.png" : "/apple-music.png";
      $("setup-music-icon").classList.toggle("round", spotifyZone);
      $("setup-music-title").textContent = spotifyZone ? "Spotify" : "Apple Music";
      state.innerHTML = status.state === "ok" ? '<span class="dot"></span>Ready'
        : status.state === "checking" ? `<span class="spinner"></span>${status.what ? "" : "Checking…"}` : icons.warning;
      note.textContent = "";
      note.hidden = !status.what && !status.todo;
      if (status.what) {
        const lead = document.createElement("b");
        lead.textContent = status.what;
        note.append(lead, status.todo ? ` ${status.todo}` : "");
      } else if (status.todo) {
        note.textContent = status.todo;
      }
    }
    renderServiceOption();
    // Spotify can't play on the TV itself (its tvOS app is only a Connect device while it's on
    // screen, and Canopy Music is), so the music plays wherever the host chooses.
    // With Sonos speakers on the Wi‑Fi, they're a choice too.
    const sonos = sonosShown();
    $("setup-sub").textContent = spotifyZone
      ? sonos ? "Music plays on Sonos speakers, or on a speaker, phone, or computer with Spotify open, chosen below."
        : "Music plays from a speaker, phone, or computer with Spotify open, chosen below."
      : sonos ? "Music plays from your Apple TV or on Sonos speakers, chosen below."
        : "Music will play from your Apple TV. Use Control Center to change audio output.";
    renderSpotifySetup();
    renderOutput();
    returnFromSpotify();
    const ready = setupReady();
    $("setup-continue").disabled = checkingConflict || !ready || !setupNameValid();
    // Ready: the playlists can load while the host finishes the names.
    if (ready) loadPlaylists().catch(() => {});
    // It stopped being able to play while the playlist page showed: back to say why.
    if (!ready && status.state !== "checking" && !$("setup-music-page").hidden && !setupStarting) showSetupPage("zone");
  }
  $("setup-name").addEventListener("input", renderSetupMusic);

  /** The hub changed service: the playlists loaded so far, and the one picked, were the old one's. */
  function resetPlaylists() {
    playlistsLoad = null;
    setupPicker.reset();
    changePicker.reset();
    setupPick = null;
    $("setup-start").disabled = true;
  }

  // MARK: Setup: the service menu, and Spotify on an Apple TV

  /** The menu's one option: the service that isn't chosen, with its state on a second line. */
  function renderServiceOption() {
    const toSpotify = !isSpotify();
    const icon = $("setup-option-icon");
    icon.src = toSpotify ? "/spotify.png" : "/apple-music.png";
    icon.classList.toggle("round", toSpotify);
    $("setup-option-title").textContent = toSpotify ? "Spotify" : "Apple Music";
    $("setup-option-note").textContent = toSpotify ? spotifyOptionNote(spotify) : appleMusicOptionNote();
  }
  /** Spotify's line in the menu: who's signed in, or that choosing it goes to its setup. */
  function spotifyOptionNote(s) {
    if (!spotifySignedIn(s)) return "Not connected. Tap to sign in.";
    return s.displayName ? `Signed in as ${s.displayName}` : "Signed in";
  }
  /** Apple Music's line in the menu: what's wrong on the TV, if anything (as the bar says it). */
  function appleMusicOptionNote() {
    if (musicAccess == null || musicAccess === "ok") return "";
    return (musicNotes[musicAccess] || musicNotes.error)[0];
  }
  const spotifySignedIn = (s) => !!s && s.account === "signedIn";

  function closeServiceMenu() {
    $("setup-service-menu").hidden = true;
    $("setup-music").setAttribute("aria-expanded", "false");
  }
  $("setup-music").addEventListener("click", (event) => {
    event.stopPropagation();
    const menu = $("setup-service-menu");
    if (menu.hidden) renderServiceOption();
    menu.hidden = !menu.hidden;
    $("setup-music").setAttribute("aria-expanded", String(!menu.hidden));
  });
  document.addEventListener("click", (event) => {
    if (!event.target.closest("#setup-service-menu")) closeServiceMenu();
  });
  addEventListener("keydown", (event) => { if (event.key === "Escape") closeServiceMenu(); });
  // Spotify, not signed in: its setup page first. The service changes only once the sign-in
  // succeeds (`returnFromSpotify`); Back keeps Apple Music.
  $("setup-service-option").addEventListener("click", () => {
    closeServiceMenu();
    if (isSpotify()) chooseService("appleMusic");
    else if (spotifySignedIn(spotify)) chooseService("spotify");
    else showSetupPage("spotify");
  });
  async function chooseService(service) {
    try {
      await api("/api/host/service", { key: hostKey, service });
      checkMusicAccess(true);
    } catch (error) {
      debugLog(`service change failed: ${error.message}`);
      toast("Couldn't change the music service");
    }
  }
  $("spotify-open").addEventListener("click", () => showSetupPage("spotify"));
  $("spotify-change").addEventListener("click", () => showSetupPage("spotify"));
  $("spotify-back").addEventListener("click", () => {
    // Backing out: nothing changes, and a reload stays on the zone page.
    try { sessionStorage.removeItem("canopymusic.spotifySignIn"); } catch {}
    showSetupPage("zone");
  });

  /** The Client ID and sign-in page fields have been filled from the TV since Spotify's page opened. */
  let spotifyFieldsFilled = false;
  /** The sign-in page field's check: "ok", "checking", or another `PageCheck`. */
  let spotifyPageCheck = "ok";
  let spotifyBusy = false;

  /** Under the Music bar (Spotify chosen): Sign in (not signed in) or the link to its page, and
   * where music plays; and Spotify's page itself. */
  function renderSpotifySetup() {
    const s = spotify, chosen = isSpotify() && !!s;
    const signedIn = spotifySignedIn(s);
    $("spotify-open").hidden = !chosen || signedIn || !!s.signingIn;
    $("spotify-change").hidden = !chosen || !signedIn;
    if (!s) return;
    $("spotify-uri").textContent = s.signInPage;
    if (!spotifyFieldsFilled) {
      spotifyFieldsFilled = true;
      $("spotify-client").value = s.clientID || "";
      $("spotify-page").value = s.ownSignInPage || "";
      setAdvanced(!!s.ownSignInPage);
    }
    // Spotify shows "Invalid redirect URI" on its own page, which nothing here can see. If the
    // phone came back without signing in, say what to check (or what the TV was told).
    const hint = $("spotify-hint");
    const cameBack = s.account === "signedOut" && !!spotifySignInIntent();
    hint.hidden = !cameBack && !s.signInError;
    hint.textContent = s.signInError ? `Couldn't sign in. ${s.signInError}`
      : `Did Spotify say “Invalid redirect URI”? Add ${s.signInPage} to your Spotify app's Redirect URIs.`;
    // Not held off while the TV waits: Back from Spotify's page leaves a sign-in pending, and
    // signing in again starts over.
    const button = $("spotify-signin");
    button.disabled = spotifyBusy || !$("spotify-client").value.trim() || spotifyPageCheck !== "ok";
    button.querySelector(".spinner").hidden = !spotifyBusy;
    button.querySelector(".label").textContent = signedIn ? "Sign in again" : "Sign in to Spotify";
  }

  /** Spotify's device types, as the iPad's picker says them. */
  function deviceLabel(type) {
    const labels = { tablet: "Tablet", smartphone: "Phone", computer: "Computer", tv: "TV", castvideo: "Chromecast", stb: "TV box",
                     speaker: "Speaker", castaudio: "Speaker", audiodongle: "Speaker", avr: "Receiver", gameconsole: "Game console", automobile: "Car" };
    return labels[(type || "").toLowerCase()] || type || "Device";
  }

  // MARK: Where music plays (setup), and the rooms in Devices

  /** The Sonos section has something to show: rooms found, or rooms chosen before. */
  const sonosShown = () => !!(sonosSetup && ((sonosSetup.rooms || []).length || sonosChosen()));

  const outputIcons = {
    speaker: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="2.5" width="12" height="19" rx="3"/><circle cx="12" cy="14.5" r="3.2"/><path d="M12 7h.01" stroke-width="2.6"/></svg>',
    soundbar: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="3.5" width="18" height="10" rx="1.5"/><path d="M9 16.5h6"/><rect x="2" y="18" width="20" height="3.5" rx="1.5"/></svg>',
    amp: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="7" width="19" height="10" rx="2"/><circle cx="16.5" cy="12" r="2.2"/><path d="M6 11h5M6 13.5h3"/></svg>',
    phone: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/></svg>',
    quiet: '<svg viewBox="0 0 24 24" aria-hidden="true" stroke-linejoin="round"><path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z" fill="currentColor"/></svg>',
    loud: '<svg viewBox="0 0 24 24" aria-hidden="true" stroke-linejoin="round"><path d="M3 9.5h3.5L11 6v12l-4.5-3.5H3z" fill="currentColor"/><path d="M14.5 9.2a4 4 0 0 1 0 5.6M17.3 6.8a7.5 7.5 0 0 1 0 10.4"/></svg>',
  };
  /** A Sonos room's icon by its model's first word, as the iPad's (`SonosRoomIcon`). */
  function roomIcon(model) {
    const first = (model || "").toLowerCase().split(/[^a-z0-9]+/)[0];
    if (["arc", "beam", "ray", "playbar", "playbase"].includes(first)) return outputIcons.soundbar;
    if (["amp", "port", "connect"].includes(first)) return outputIcons.amp;
    return outputIcons.speaker;
  }
  /** A Spotify Connect device's icon by its type. */
  function spotifyDeviceIcon(type) {
    switch ((type || "").toLowerCase()) {
      case "smartphone": return outputIcons.phone;
      case "tablet": return icons.ipad;
      case "computer": return icons.laptop;
      case "tv": case "castvideo": case "stb": return icons.tv;
      case "avr": return outputIcons.amp;
      default: return outputIcons.speaker;
    }
  }

  /** The mark at a row's end: a check for the one chosen (devices, This Apple TV), a ring or a
   * ticked ring for rooms (several at once), or a spinner while a room changes. */
  function outputMark(mark) {
    switch (mark) {
      case "check": return `<span class="output-mark check">${icons.check}</span>`;
      case "on": return `<span class="output-mark tick on">${icons.check}</span>`;
      case "off": return '<span class="output-mark tick"></span>';
      case "spin": return '<span class="output-mark"><span class="spinner"></span></span>';
      case "use": return '<span class="output-mark use">Use</span>';
      default: return '<span class="output-mark"></span>';
    }
  }

  /** Fills a list of output rows, rebuilt only when what it shows changed (so a tap's highlight
   * isn't lost to a snapshot). Each row: `action`/`id` for the tap, `icon`, `name`, `sub`,
   * `tone` ("busy" orange, "warn"), `mark`, `dim` and `disabled`. */
  function fillOutputList(list, rows) {
    const signature = JSON.stringify(rows);
    if (list.dataset.signature === signature) return;
    list.dataset.signature = signature;
    list.innerHTML = "";
    for (const row of rows) {
      const li = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "output-row" + (row.dim ? " dim" : "");
      button.dataset.action = row.action;
      if (row.id) button.dataset.id = row.id;
      button.disabled = !!row.disabled;
      if (row.mark === "on" || row.mark === "check") button.setAttribute("aria-pressed", "true");
      button.innerHTML = `<span class="output-icon">${row.icon}</span><span class="output-text"><span class="output-name"></span><span class="output-sub"></span></span>${outputMark(row.mark)}`;
      button.querySelector(".output-name").textContent = row.name;
      const sub = button.querySelector(".output-sub");
      sub.textContent = row.sub || "";
      sub.hidden = !row.sub;
      if (row.tone) sub.classList.add(row.tone);
      li.append(button);
      list.append(li);
    }
  }

  /** Rooms whose tick was just tapped: a spinner until the hub has answered. */
  const roomsChanging = new Set();

  /** A Sonos room's row, in setup's Plays on and in Devices (where rooms join and leave as the music plays). */
  function roomRow(room, s) {
    const changing = roomsChanging.has(room.id) || room.state === "joining";
    // Another zone plays on it: "Use" (the sheet asks first) instead of a tick.
    const use = room.state === "inUse" && !room.ticked;
    return {
      action: use ? "use" : "room", id: room.id, icon: roomIcon(room.model), name: room.name, sub: room.status,
      tone: room.state === "busy" || room.state === "inUse" ? "busy" : "",
      mark: changing ? "spin" : use ? "use" : room.ticked ? "on" : "off",
      dim: room.state === "notResponding" || !s.hasAccount,
      disabled: !s.hasAccount || room.state === "joining" || (!room.canTick && !room.ticked && !use),
    };
  }

  /** Under the Music bar: where music plays. With Sonos rooms found, a switch first: Sonos or
   * the Spotify device (This Apple TV). Under the other side, Spotify's Connect devices (signed
   * in) or This Apple TV; under Sonos, the rooms, "Whose account plays" with several accounts,
   * and what to do when the service isn't linked in the Sonos app. */
  function renderOutput() {
    const spotifyZone = isSpotify(), s = sonosSetup, onSonos = sonosChosen();
    const signedIn = spotifyZone && spotifySignedIn(spotify);
    const sonos = sonosShown();
    $("setup-output").hidden = spotifyZone ? !signedIn : !sonos;
    if ($("setup-output").hidden) return;

    const place = outputPlace();
    $("output-switch").hidden = !sonos;
    // "Apple TV": its row underneath is the one that says "This Apple TV".
    $("output-switch-own").textContent = spotifyZone ? "Spotify device" : "Apple TV";
    for (const button of $("output-switch").children) button.setAttribute("aria-checked", String(button.dataset.place === place));
    $("output-own-part").hidden = place === "sonos";

    const own = [];
    if (spotifyZone) {
      const devices = spotify.devices || [];
      for (const d of devices) {
        own.push({ action: "device", id: d.id, icon: spotifyDeviceIcon(d.type), name: d.name, sub: deviceLabel(d.type),
                   mark: !onSonos && d.id === spotify.deviceID ? "check" : "" });
      }
      // Chosen before, not listed now (asleep, or Spotify closed on it).
      if (spotify.deviceID && !devices.some((d) => d.id === spotify.deviceID) && !onSonos) {
        own.push({ action: "device", id: spotify.deviceID, icon: outputIcons.speaker, name: spotify.deviceName || "Chosen device",
                   sub: "Not available. Open Spotify on it.", tone: "warn", mark: "check", dim: true, disabled: true });
      }
      if (!spotify.devices) own.push({ action: "none", icon: outputIcons.speaker, name: "Looking for devices…", dim: true, disabled: true });
      const note = $("spotify-device-note");
      note.hidden = false;
      note.textContent = devices.length
        ? "Only devices with Spotify open show here. Spotify on this Apple TV can't play while Canopy Music is on screen."
        : "Devices show here once Spotify is open on them. Spotify on this Apple TV can't play while Canopy Music is on screen.";
    } else {
      own.push({ action: "tv", icon: icons.tv, name: "This Apple TV", sub: "Use Control Center to change audio output.", mark: onSonos ? "" : "check" });
      $("spotify-device-note").hidden = true;
    }
    fillOutputList($("output-own"), own);

    $("output-sonos").hidden = place !== "sonos";
    if (place !== "sonos") return;
    const rooms = s.rooms || [];
    $("output-rooms-note").hidden = onSonos || !rooms.length || !s.hasAccount;
    const rows = rooms.length ? rooms.map((room) => roomRow(room, s))
      // Chosen before, not found now (asleep, unplugged, another Wi‑Fi): tapping it plays here instead.
      : [{ action: "off", icon: outputIcons.speaker, name: s.chosenName || "Sonos", sub: s.searched ? "Not found on this Wi‑Fi" : "Looking…",
           tone: "warn", mark: "on" }];
    fillOutputList($("output-rooms"), rows);
    // Sonos refused to play the service here (it isn't linked in the Sonos app). Until then the
    // rooms play from the household's account without it having been seen.
    const noAccount = rooms.length > 0 && !s.hasAccount;
    $("output-sonos-note").hidden = !noAccount;
    if (noAccount) {
      $("output-sonos-what").textContent = `Add ${s.service} in the Sonos app`;
      $("output-sonos-todo").textContent = `Sonos couldn't play ${s.service}. Already added? Play any ${s.service} song from the Sonos app once, so Canopy Music can find it.`;
    }
    renderAccounts(s, onSonos);
  }

  /** "Whose account plays": with Sonos rooms chosen and several accounts for the service. */
  function renderAccounts(s, onSonos) {
    const accounts = s.accounts || [];
    $("output-account").hidden = !onSonos || accounts.length < 2;
    if ($("output-account").hidden) return;
    const select = $("output-account-select");
    const signature = JSON.stringify(accounts) + s.accountID;
    if (select.dataset.signature !== signature) {
      select.dataset.signature = signature;
      select.innerHTML = "";
      for (const a of accounts) {
        const option = document.createElement("option");
        option.value = a.id;
        option.textContent = a.label;
        select.append(option);
      }
      select.value = s.accountID || "";
    }
    const chosen = accounts.find((a) => a.id === s.accountID);
    $("output-account-name").textContent = chosen ? chosen.label : "Choose an account";
  }
  $("output-account-select").addEventListener("change", async (event) => {
    try { await api("/api/host/sonos/account", { key: hostKey, id: event.target.value }); } catch { toast("Couldn't choose that account"); }
  });

  /** Ticks or unticks a room on the hub; the spinner shows until it answers. */
  async function tickRoom(id, on) {
    roomsChanging.add(id);
    render();
    try {
      await api("/api/host/sonos/room", { key: hostKey, id, on });
    } catch (error) {
      debugLog(`sonos room failed: ${error.message}`);
      toast(on ? "Couldn't add that speaker" : "Couldn't take that speaker out");
    }
    roomsChanging.delete(id);
    render();
  }

  // Plays on's switch. Off Sonos is one tap: the hub lets go of the rooms and plays on the
  // Spotify device (or this Apple TV). Onto Sonos shows the rooms; nothing moves until one is ticked.
  $("output-switch").addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-place]");
    if (!button || button.dataset.place === outputPlace()) return;
    placePicked = button.dataset.place;
    render();
    if (placePicked === "own" && sonosChosen()) {
      try { await api("/api/host/sonos/off", { key: hostKey }); } catch { toast("Couldn't change where music plays"); }
    }
  });

  $("output-own").addEventListener("click", async (event) => {
    const row = event.target.closest(".output-row");
    if (!row || row.disabled) return;
    if (row.dataset.action === "tv") {
      try { await api("/api/host/sonos/off", { key: hostKey }); } catch { toast("Couldn't change where music plays"); }
    } else if (row.dataset.action === "device") {
      try { await api("/api/host/spotify/device", { key: hostKey, id: row.dataset.id }); } catch { toast("Couldn't choose that device"); }
    }
  });
  $("output-rooms").addEventListener("click", async (event) => {
    const row = event.target.closest(".output-row");
    if (!row || row.disabled) return;
    if (row.dataset.action === "off") {
      try { await api("/api/host/sonos/off", { key: hostKey }); } catch { toast("Couldn't change where music plays"); }
      return;
    }
    const room = sonosSetup && (sonosSetup.rooms || []).find((r) => r.id === row.dataset.id);
    if (!room || roomsChanging.has(room.id)) return;
    if (row.dataset.action === "use") return openTakeover(room);
    tickRoom(room.id, !room.ticked);
  });

  // MARK: Taking rooms from another zone ("Use")

  /** "Bedroom", "Bedroom and Move", "Bedroom, Move, and Kitchen". */
  function roomList(names) {
    if (names.length < 3) return names.join(" and ");
    return `${names.slice(0, -1).join(", ")}, and ${names[names.length - 1]}`;
  }

  /** What the sheet asks, as the iPad's dialog (`SonosTakeoverPrompt`). */
  function takeoverPrompt(room) {
    const byID = new Map(((sonosSetup && sonosSetup.rooms) || []).map((r) => [r.id, r]));
    const together = ((room.inUse && room.inUse.together) || [room.id]).filter((id) => byID.has(id));
    const rooms = together.length > 1 ? together : [room.id];
    const names = rooms.map((id) => byID.get(id).name);
    const zone = room.inUse ? `${room.inUse.zone}'s zone` : "another zone";
    return {
      rooms,
      title: `Use ${roomList(names)}?`,
      text: `${rooms.length > 1 ? "They're" : "It's"} playing ${zone}. Its music stops there and plays here instead.`,
      all: rooms.length > 2 ? `Use All ${rooms.length} Rooms` : rooms.length === 2 ? "Use Both Rooms" : null,
      just: rooms.length > 1 ? `Just ${room.name}` : `Use ${room.name}`,
    };
  }

  let takeover = null;
  function openTakeover(room) {
    const prompt = takeoverPrompt(room);
    takeover = { room: room.id, rooms: prompt.rooms };
    $("takeover-title").textContent = prompt.title;
    $("takeover-text").textContent = prompt.text;
    $("takeover-all").hidden = !prompt.all;
    $("takeover-all").textContent = prompt.all || "";
    $("takeover-just").textContent = prompt.just;
    // With one room, its own button leads.
    $("takeover-just").className = prompt.all ? "action-btn" : "primary-btn wide";
    $("takeover-modal").hidden = false;
  }
  function closeTakeover() {
    takeover = null;
    $("takeover-modal").hidden = true;
  }
  /** Takes the rooms on the hub (the other zone isn't told); spinners until it answers. */
  async function useRooms(ids) {
    closeTakeover();
    for (const id of ids) roomsChanging.add(id);
    placePicked = "sonos";
    render();
    try {
      await api("/api/host/sonos/use", { key: hostKey, ids });
    } catch (error) {
      debugLog(`sonos use failed: ${error.message}`);
      toast(ids.length > 1 ? "Couldn't use those speakers" : "Couldn't use that speaker");
    }
    for (const id of ids) roomsChanging.delete(id);
    render();
  }
  $("takeover-all").addEventListener("click", () => { if (takeover) useRooms(takeover.rooms); });
  $("takeover-just").addEventListener("click", () => { if (takeover) useRooms([takeover.room]); });
  $("takeover-cancel").addEventListener("click", closeTakeover);
  $("takeover-modal").addEventListener("click", (event) => { if (event.target === $("takeover-modal")) closeTakeover(); });

  // MARK: The volume row (Sonos) and Devices

  /** Sends the latest value at most every 150 ms while a slider moves, and the last one on release. */
  function throttle(send, interval = 150) {
    let last = 0, timer = null, pending = null;
    return {
      submit(value) {
        const now = Date.now();
        if (now - last >= interval && !timer) { last = now; send(value); return; }
        pending = value;
        if (!timer) timer = setTimeout(() => { timer = null; last = Date.now(); if (pending != null) { send(pending); pending = null; } }, interval - (now - last));
      },
      finish(value) { clearTimeout(timer); timer = null; pending = null; last = Date.now(); send(value); },
    };
  }

  /** Sets a volume slider (if `value` is given) and its filled part, which ends under the thumb. */
  function showVolume(slider, value) {
    if (value != null) slider.value = value;
    const min = Number(slider.min) || 0, max = Number(slider.max) || 100;
    slider.style.setProperty("--t", String((Number(slider.value) - min) / (max - min)));
  }

  /** Snapshots don't move a slider while it's dragged, nor for a moment after: the hub's next
   * reading of the speakers may not have the new volume yet. */
  const sliderHeld = (slider) => Date.now() < (slider.holdUntil || 0);
  const holdSlider = (slider, ms = 1500) => { slider.holdUntil = Math.max(slider.holdUntil || 0, Date.now() + ms); };

  /** A volume slider (a native range input, styled): `begin()` as a drag or a key press starts,
   * `move(value)` as it moves, and `send(value)` at most every 150 ms, then once more on release.
   * The pointer is followed here rather than left to the browser: iOS Safari only drags a range
   * input whose touch began on its thumb (anywhere else on the track it jumps there and stops),
   * so a drag from the track, or a thumb missed by a few pixels, did nothing. With
   * `touch-action: none` (app.css) the page doesn't scroll instead. Keyboards and VoiceOver
   * still use the input itself. */
  function volumeSlider(slider, { begin, move, send }) {
    const sends = throttle(send);
    let active = false, pointer = null;
    function start() {
      if (active) return;
      active = true;
      slider.holdUntil = Infinity;
      slider.classList.add("dragging");
      if (begin) begin();
    }
    function finish() {
      if (!active) return;
      active = false;
      slider.holdUntil = 0;
      holdSlider(slider);
      slider.classList.remove("dragging");
      sends.finish(Number(slider.value));
    }
    /** The value under the finger, as the browser maps it: the thumb's centre follows it. */
    function valueAt(x) {
      const r = slider.getBoundingClientRect();
      const thumb = parseFloat(getComputedStyle(slider).getPropertyValue("--thumb")) || 0;
      const t = Math.min(1, Math.max(0, (x - r.left - thumb / 2) / Math.max(1, r.width - thumb)));
      const min = Number(slider.min) || 0, max = Number(slider.max) || 100, step = Number(slider.step) || 1;
      return min + Math.round((t * (max - min)) / step) * step;
    }
    function follow(event) {
      const value = valueAt(event.clientX);
      if (Number(slider.value) === value) return;
      slider.value = value;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    }
    slider.addEventListener("input", () => {
      start();
      showVolume(slider);
      if (move) move(Number(slider.value));
      sends.submit(Number(slider.value));
    });
    // A key press, or VoiceOver's swipe, ends with `change`; a drag ends on release.
    slider.addEventListener("change", () => { if (pointer === null) finish(); });
    slider.addEventListener("pointerdown", (event) => {
      if (slider.disabled || (event.pointerType === "mouse" && event.button !== 0)) return;
      event.preventDefault(); // the browser's own drag would fight this one
      pointer = event.pointerId;
      try { slider.setPointerCapture(pointer); } catch {}
      start();
      follow(event); // a tap on the track jumps there
    });
    slider.addEventListener("pointermove", (event) => { if (event.pointerId === pointer) follow(event); });
    const release = (event) => {
      if (event.pointerId !== pointer) return;
      pointer = null;
      finish();
    };
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) slider.addEventListener(type, release);
  }

  const sendVolume = (id, volume) => api("/api/host/sonos/volume", id ? { key: hostKey, id, volume } : { key: hostKey, volume }).catch(() => {});
  const tickedRooms = () => ((sonosSetup && sonosSetup.rooms) || []).filter((r) => r.ticked);
  const average = (values) => Math.round(values.reduce((a, b) => a + b, 0) / values.length);
  const roomSlider = (id) => [...$("speakers-rooms").children].find((li) => li.dataset.id === id)?.querySelector("input");

  /** The group's volume, twice: the volume row's slider and the same one atop Devices. */
  const masterSliders = [$("master-volume"), $("devices-volume")];
  $("devices-volume-quiet").innerHTML = outputIcons.quiet;
  $("devices-volume-loud").innerHTML = outputIcons.loud;

  /** The volume row: under the transport (so for hosts, as it is), while the zone plays through
   * Sonos. The slider is the group's volume, shown as the ticked rooms' average. */
  function renderVolumeBar() {
    const s = sonosSetup, shown = hosting() && !!(s && s.active);
    $("volume-bar").hidden = !shown;
    if (!shown) { $("devices-modal").hidden = true; return; }
    const volumes = tickedRooms().map((r) => r.volume).filter((v) => v != null);
    for (const master of masterSliders) {
      master.disabled = !volumes.length && !sliderHeld(master);
      if (!sliderHeld(master)) showVolume(master, volumes.length ? average(volumes) : 0);
    }
    const on = crossfadeWanted ?? snap.crossfade === true;
    $("crossfade-btn").setAttribute("aria-pressed", String(on));
    if (!$("devices-modal").hidden) renderSpeakers();
    if (!readTimer) readRooms();
  }

  // The group's volume: Sonos snapshots each room's volume as the drag starts, then the group
  // moves, keeping their balance. The rooms' sliders (in Devices) show it at once, and so does
  // the group's other slider.
  let groupStart = null;
  for (const master of masterSliders) volumeSlider(master, {
    begin() {
      groupStart = new Map(tickedRooms().filter((r) => r.volume != null).map((r) => [r.id, r.volume]));
      api("/api/host/sonos/volume", { key: hostKey, begin: true }).catch(() => {});
    },
    move(value) {
      for (const other of masterSliders) {
        if (other === master) continue;
        holdSlider(other);
        showVolume(other, value);
      }
      if (!groupStart || !groupStart.size) return;
      const base = average([...groupStart.values()]);
      for (const [id, start] of groupStart) {
        const slider = roomSlider(id);
        if (!slider || slider.classList.contains("dragging")) continue;
        holdSlider(slider);
        showVolume(slider, Math.min(100, Math.max(0, base > 0 ? Math.round(start * value / base) : value)));
      }
    },
    send: (value) => sendVolume(null, value),
  });

  /** A room's slider moved: the group's show the new average at once. */
  function masterFollowsRooms() {
    if (masterSliders.some((master) => master.classList.contains("dragging"))) return;
    const values = tickedRooms().map((r) => {
      const slider = roomSlider(r.id);
      return slider && sliderHeld(slider) ? Number(slider.value) : r.volume;
    }).filter((v) => v != null);
    if (!values.length) return;
    for (const master of masterSliders) {
      holdSlider(master);
      showVolume(master, average(values));
    }
  }

  // Crossfade: the hub's own setting (on Sonos, Sonos's crossfade). The button shows what was
  // asked until a snapshot says the same (or the hub refused).
  let crossfadeWanted = null;
  $("crossfade-btn").addEventListener("click", async () => {
    if (!hosting() || !snap) return;
    const on = !(crossfadeWanted ?? snap.crossfade === true);
    crossfadeWanted = on;
    renderVolumeBar();
    try {
      await api("/api/host/settings", { key: hostKey, crossfade: on });
    } catch (error) {
      debugLog(`crossfade failed: ${error.message}`);
      crossfadeWanted = null;
      renderVolumeBar();
      toast("Couldn't change crossfade");
    }
  });

  /** One room in Devices: its row (as setup's), and its volume while ticked. Built once per room,
   * then updated in place, so a slider being dragged isn't replaced. */
  function speakerItem(id) {
    const li = document.createElement("li");
    li.className = "speaker";
    li.dataset.id = id;
    li.innerHTML = '<ul class="speaker-head"></ul><div class="volume-row" hidden>'
      + `<span class="volume-icon">${outputIcons.quiet}</span><input type="range" class="volume" min="0" max="100" step="1">`
      + `<span class="volume-icon">${outputIcons.loud}</span></div>`;
    volumeSlider(li.querySelector("input"), { move: masterFollowsRooms, send: (value) => sendVolume(id, value) });
    return li;
  }

  /** Devices: the rooms, while the zone plays through Sonos. Same rules as the iPad's Speakers
   * panel: the last ticked room stays. */
  function renderSpeakers() {
    const s = sonosSetup;
    if (!s) return;
    const rooms = s.rooms || [];
    const ticked = rooms.filter((r) => r.ticked);
    const list = $("speakers-rooms");
    for (const li of [...list.children]) if (!rooms.some((r) => r.id === li.dataset.id)) li.remove();
    rooms.forEach((room, index) => {
      let li = [...list.children].find((each) => each.dataset.id === room.id);
      if (!li) li = speakerItem(room.id);
      if (list.children[index] !== li) list.insertBefore(li, list.children[index] || null);
      const row = roomRow(room, s);
      // The only ticked room stays: its tick is dimmed (leaving Sonos isn't offered mid-party).
      const only = room.ticked && ticked.length === 1;
      fillOutputList(li.querySelector(".speaker-head"), [row]);
      const button = li.querySelector(".output-row");
      button.classList.toggle("last", only);
      const volume = li.querySelector(".volume-row"), slider = volume.querySelector("input");
      volume.hidden = !room.ticked || room.volume == null;
      slider.setAttribute("aria-label", `${room.name} volume`);
      if (!sliderHeld(slider) && room.volume != null) showVolume(slider, room.volume);
    });
  }

  $("devices-btn").addEventListener("click", () => {
    $("devices-modal").hidden = false;
    renderSpeakers();
    readRooms();
  });
  $("devices-close").addEventListener("click", () => { $("devices-modal").hidden = true; });

  $("speakers-rooms").addEventListener("click", (event) => {
    const row = event.target.closest(".output-row");
    if (!row || row.disabled || !sonosSetup) return;
    const room = (sonosSetup.rooms || []).find((r) => r.id === row.dataset.id);
    if (!room || roomsChanging.has(room.id)) return;
    if (row.dataset.action === "use") return openTakeover(room);
    if (room.ticked && sonosSetup.rooms.filter((r) => r.ticked).length === 1) {
      toast("The last speaker stays while the music plays.");
      return;
    }
    if (!room.canTick && !room.ticked) return;
    tickRoom(room.id, !room.ticked);
  });

  // The rooms are read again (every 2 s while Devices is open, every 10 s while just the row
  // shows), so changes made in the Sonos app (volumes, groups, what other rooms play) show up.
  let readTimer = null;
  function readRooms() {
    clearTimeout(readTimer);
    readTimer = null;
    if ($("volume-bar").hidden || document.hidden) return;
    api("/api/host/sonos/read", { key: hostKey }).catch(() => {});
    readTimer = setTimeout(readRooms, $("devices-modal").hidden ? 10000 : 2000);
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden && snap) readRooms(); });

  function setAdvanced(open) {
    $("spotify-advanced").hidden = !open;
    $("spotify-advanced-btn").setAttribute("aria-expanded", String(open));
  }
  $("spotify-advanced-btn").addEventListener("click", () => setAdvanced($("spotify-advanced").hidden));
  $("spotify-client").addEventListener("input", () => renderSpotifySetup());
  // The Client ID is saved on the TV when it's done (changing it signs the TV out of Spotify).
  $("spotify-client").addEventListener("change", saveSpotifyClientID);
  $("spotify-client").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); $("spotify-client").blur(); }
  });
  async function saveSpotifyClientID() {
    const id = $("spotify-client").value.trim();
    if (!spotify || id === (spotify.clientID || "")) return;
    await api("/api/host/spotify/client-id", { key: hostKey, spotifyClientId: id });
  }

  // The sign-in page: checked by the TV as typing pauses (it fetches the page and looks for the
  // marker, so the phone never needs to reach it), and saved there if it passes.
  const pageMessages = {
    notHTTPS: ["bad", "Use an https:// address."],
    invalid: ["bad", "That isn't a web address."],
    unreachable: ["bad", "Couldn't open this page."],
    notRelay: ["bad", "This isn't a Canopy Music sign-in page."],
  };
  let pageTimer = null, pageAsk = 0;
  function showPageNote(kind, text, help) {
    const note = $("spotify-page-note");
    note.textContent = "";
    const lead = document.createElement("span");
    lead.className = kind;
    lead.textContent = text;
    note.append(lead);
    if (help) note.append(" Leave it empty to use the default.");
  }
  $("spotify-page").addEventListener("input", () => {
    clearTimeout(pageTimer);
    spotifyPageCheck = "checking";
    showPageNote("warn", "Checking…", false);
    renderSpotifySetup();
    pageTimer = setTimeout(async () => {
      const typed = $("spotify-page").value.trim(), asking = ++pageAsk;
      let result = "unreachable";
      try { result = (await api("/api/host/spotify/sign-in-page", { key: hostKey, address: typed })).result; } catch {}
      if (asking !== pageAsk) return;
      spotifyPageCheck = result;
      if (result === "ok") showPageNote(typed ? "ok" : "", typed ? "✓ Canopy Music sign-in page found." : "Uses music.canopysf.com.", true);
      else showPageNote(...(pageMessages[result] || pageMessages.unreachable), false);
      renderSpotifySetup();
    }, 600);
  });

  // The address to register, copied. The page is plain http, where the Clipboard API isn't
  // offered, so it's selected and copied the older way.
  $("spotify-copy").addEventListener("click", () => {
    const text = $("spotify-uri").textContent;
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.cssText = "position:fixed;top:0;left:0;opacity:0;font-size:16px";
    document.body.append(field);
    field.select();
    field.setSelectionRange(0, text.length);
    let copied = false;
    try { copied = document.execCommand("copy"); } catch {}
    field.remove();
    $("spotify-copy").textContent = copied ? "Copied" : "Copy";
    if (!copied) toast("Couldn't copy. Press and hold the address to copy it.");
    setTimeout(() => { $("spotify-copy").textContent = "Copy"; }, 1500);
  });

  /** A sign-in left from this page and hasn't come back signed in (kept across the reload):
   * "switch" when it left from Apple Music (Spotify is chosen once it succeeds), else "again". */
  function spotifySignInIntent() {
    try { return sessionStorage.getItem("canopymusic.spotifySignIn"); } catch { return null; }
  }

  // Sign in: the TV makes the sign-in (its verifier and nonce stay there) and answers with
  // Spotify's page, which opens here. Spotify sends the phone to the sign-in page, which sends it
  // back to the TV; the TV finishes and this page comes back, signed in.
  $("spotify-signin").addEventListener("click", async () => {
    if ($("spotify-signin").disabled) return;
    spotifyBusy = true;
    renderSpotifySetup();
    try {
      await saveSpotifyClientID();
      const reply = await api("/api/host/spotify/sign-in", { key: hostKey });
      saveSetupDraft();
      try { sessionStorage.setItem("canopymusic.spotifySignIn", isSpotify() ? "again" : "switch"); } catch {}
      location.href = reply.url;
    } catch (error) {
      debugLog(`spotify sign-in failed: ${error.message}`);
      spotifyBusy = false;
      renderSpotifySetup();
      toast("Couldn't start signing in. Try again.");
    }
  });

  // Back here from Spotify's page with the browser's Back button: the page as it was left.
  addEventListener("pageshow", (event) => {
    if (!event.persisted || !spotifyBusy) return;
    spotifyBusy = false;
    if (snap) renderSpotifySetup();
  });

  // Another zone already plays from this Spotify account: end it first, or join it as a display.
  // The TV asks that zone first (up to about 2 s): one that announced itself but no longer
  // answers (quit without a goodbye) doesn't count. If the TV can't be asked, what it last said.
  let conflictZone = null;
  async function askAboutConflict() {
    if (!isSpotify()) return false;
    try {
      conflictZone = (await api("/api/host/spotify/conflict", { key: hostKey }) || {}).zone || null;
    } catch (error) {
      debugLog(`conflict check failed: ${error.message}`);
      conflictZone = (spotify && spotify.conflictZone) || null;
    }
    if (!conflictZone) return false;
    $("conflict-text").textContent = `End ${conflictZone} to start a new one on this Apple TV, or join it as a display.`;
    $("conflict-modal").hidden = false;
    return true;
  }
  $("conflict-cancel").addEventListener("click", () => { $("conflict-modal").hidden = true; });
  $("conflict-join").addEventListener("click", async () => {
    try {
      const reply = await api("/api/host/spotify/join", { key: hostKey });
      $("conflict-modal").hidden = true;
      // The TV shows that zone now; this phone goes on to its page.
      showSplash(`Connecting to ${conflictZone}`);
      location.replace(`http://${reply.address}/`);
    } catch {
      toast("Couldn't join that zone");
    }
  });
  // Return in Your name goes on to Zone name; in Zone name it closes the keyboard.
  $("setup-you").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); $("setup-name").focus(); }
  });
  $("setup-name").addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); $("setup-name").blur(); }
  });
  $("setup-continue").addEventListener("click", async () => {
    if ($("setup-continue").disabled) return;
    // Disabled while the TV checks for another zone on the Spotify account.
    checkingConflict = true;
    $("setup-continue").disabled = true;
    const asked = await askAboutConflict();
    checkingConflict = false;
    $("setup-continue").disabled = !setupReady() || !setupNameValid();
    if (asked) return;
    showSetupPage("music");
    await setupPicker.open();
    if (setupPick) setupPicker.select(setupPick.id);
  });
  $("setup-back").addEventListener("click", () => showSetupPage("zone"));
  /** Keeps `line` showing the `.local` address that the zone name typed in `input` gives (the
   * hub works it out, as it names itself), or for the saved name, the hub's actual address.
   * Hidden when the name is empty or has no letters or digits. Returns the update function. */
  function addressPreview(input, line, active = () => true) {
    let asked = 0;
    const show = (address) => { line.textContent = address || ""; line.hidden = !address; };
    async function update() {
      const name = input.value.trim(), asking = ++asked;
      if (!name || !active()) { show(null); return; }
      if (snap && name === snap.zoneName && snap.address) { show(snap.address); return; }
      let address = null;
      try { address = (await (await fetch(`/api/local-name?zone=${encodeURIComponent(name)}`)).json()).address; } catch {}
      if (asking === asked) show(address);
    }
    input.addEventListener("input", update);
    return update;
  }
  const setupAddress = addressPreview($("setup-name"), $("setup-address"));

  const setupPicker = playlistPicker("setup", "setup-playlists", "setup-empty", (p) => {
    setupPick = p;
    $("setup-start").disabled = false;
    setupPicker.select(p.id);
  });
  /** Start the music: a spinner and "Starting…" until the hub answers (a big playlist can take a while). */
  function setupBusy(busy) {
    setupStarting = busy;
    pickerBusy("setup", $("setup-start"), busy, busy ? "Starting…" : "Start the music");
  }
  $("setup-start").addEventListener("click", async () => {
    if (!setupPick || setupStarting) return;
    // The spinner shows while the TV checks for another zone on the Spotify account, too.
    setupBusy(true);
    if (await askAboutConflict()) {
      setupBusy(false);
      return;
    }
    // This phone's name, saved as the name prompt saves it.
    saveMyName($("setup-you").value);
    try {
      const name = $("setup-name").value.trim();
      if (name) await api("/api/host/settings", { key: hostKey, zoneName: name });
      const reply = await api("/api/host/playlist", { key: hostKey, playlist: setupPick, play: true, shuffle: $("setup-shuffle").checked });
      setupDismissed = true;
      setupBusy(false);
      $("setup").hidden = true;
      if (toastSkipped(reply)) setupToastUntil = Date.now() + 6000;
      if (snap) moveIfSetUp();
    } catch (error) {
      debugLog(`setup start failed: ${error.message}`);
      setupBusy(false);
      // Nothing to play in it, and nothing started: say so, and stay to choose another.
      if (error.reason) {
        setupPicker.refused(setupPick, error.reason);
        setupPick = null;
        $("setup-start").disabled = true;
        toast(error.reason.error, 5000);
        return;
      }
      toast("Couldn't start. Try again.");
      // In case it's Apple Music: if the TV can't play it now, the zone page comes back to say why.
      api("/api/host/music-check", { key: hostKey }).catch(() => {});
    }
  });

  // Another host: the hub draws the QR code.
  $("settings-invite").addEventListener("click", () => {
    $("invite-img").src = `/api/host/invite.png?${keyQuery()}&t=${Date.now()}`;
    $("invite-modal").hidden = false;
  });
  $("invite-done").addEventListener("click", () => { $("invite-modal").hidden = true; });

  // Zone settings: the admin view for every hub (an Apple TV has no settings screens). Everything
  // saves as it changes: switches at once, text values from the edit dialog on top of the sheet.
  let wifiDetails = null; // host-only (never in snapshots); loaded when the sheet opens
  let partyInfo = null; // "Save as playlist": suggested name, song counts, where it saves
  const settingsOpen = () => !$("settings-modal").hidden;

  /** Shows the hub's current settings (again on every snapshot while the sheet is open). */
  function fillSettings() {
    $("settings-name").textContent = snap.zoneName || "";
    // The `.local` address follows the zone name (briefly missing while a new one is checked).
    $("settings-address-row").hidden = !snap.address;
    $("settings-address").textContent = snap.address || "";
    $("settings-playlist").textContent = snap.playlistName || "None yet";
    const skipped = skippedNote(snap);
    $("settings-playlist-skipped").hidden = !skipped;
    $("settings-playlist-skipped").textContent = skipped;
    // A problem with the player: songs that couldn't play were skipped, or (Spotify) the next
    // song couldn't be queued there.
    $("settings-player-issue").hidden = !snap.playerIssue;
    $("settings-player-issue").textContent = snap.playerIssue || "";
    $("settings-queue").checked = snap.canQueue !== false;
    $("settings-reorder").checked = snap.canReorder !== false;
    $("settings-displays").checked = snap.displaysCanControl !== false;
    // Apple TV hubs only (an iPad never sleeps).
    $("settings-screen").hidden = snap.hubKind !== "tv";
    $("settings-screensaver").checked = snap.screensaverWhilePlaying === true;
    const hosts = snap.hostPhones || 0;
    $("settings-hosts").textContent = hosts === 1 ? "1 phone" : `${hosts} phones`;
    $("settings-forget").hidden = hosts < 2;
    $("settings-stop").textContent = `End ${snap.zoneName || "this zone"}`;
    fillWifi();
    fillPartyRow();
  }

  /** Saving is offered once someone has added a song (played or still in Up next); until then the
   * party is just the base playlist, nothing worth saving. */
  const partyCanSave = () => !!(partyInfo && partyInfo.destination && partyInfo.requestCount > 0);

  function fillPartyRow() {
    $("settings-party-row").hidden = !partyCanSave();
    // The songs guests added, as "Only songs guests added" (on by default) saves.
    if (partyInfo) $("settings-party").textContent = partyInfo.requestCount === 1 ? "1 song added" : `${partyInfo.requestCount} songs added`;
  }

  /** Fetches the host details (Wi‑Fi, displays, the party so far). */
  function loadHostDetails() {
    return api(`/api/host/details?${keyQuery()}`).then((details) => {
      partyInfo = details.party || null;
      fillPartyRow();
      return details;
    });
  }

  function fillWifi() {
    const w = wifiDetails;
    $("settings-wifi-ssid").textContent = !w ? "" : w.ssid || "Not set";
    $("settings-wifi-btn").textContent = w && w.ssid ? "Change" : "Set";
    // Until they've loaded, so a save can't blank the others.
    for (const id of ["settings-wifi-btn", "settings-wifi-simple"]) $(id).disabled = !w;
    if (w) $("settings-wifi-simple").checked = w.simpleQR;
  }

  $("settings-btn").addEventListener("click", () => {
    wifiDetails = null;
    partyInfo = null;
    fillSettings();
    const list = $("settings-display-list");
    list.innerHTML = "";
    loadHostDetails().then((details) => {
      wifiDetails = details.wifi;
      fillWifi();
      if (wifiLinkPending) { wifiLinkPending = false; $("settings-wifi-btn").click(); }
      for (const d of details.displays) {
        const li = document.createElement("li");
        li.innerHTML = deviceIcon(d.kind, d.device);
        li.append(d.name);
        list.append(li);
      }
      if (!details.displays.length) {
        const li = document.createElement("li");
        li.className = "none";
        li.textContent = "No displays connected";
        list.append(li);
      }
    }).catch(() => {});
    $("settings-modal").hidden = false;
  });
  $("settings-done").addEventListener("click", () => { $("settings-modal").hidden = true; });
  $("settings-close").addEventListener("click", () => { $("settings-modal").hidden = true; });

  /** Sends one change; false (after a toast) if the hub didn't take it. */
  async function saveSetting(change) {
    try { await api("/api/host/settings", { key: hostKey, ...change }); return true; }
    catch { toast("Couldn't save that"); return false; }
  }

  // Switches apply as they're flipped, and flip back if the hub didn't take it.
  for (const [id, field] of [["settings-queue", "phonesCanQueue"], ["settings-reorder", "phonesCanReorder"], ["settings-displays", "displaysCanControl"],
    ["settings-screensaver", "screensaverWhilePlaying"]]) {
    $(id).addEventListener("change", async (event) => {
      const on = event.target.checked;
      if (!(await saveSetting({ [field]: on }))) event.target.checked = !on;
    });
  }
  $("settings-wifi-simple").addEventListener("change", async (event) => {
    const next = { ...wifiDetails, simpleQR: event.target.checked };
    if (await saveSetting({ wifi: next })) wifiDetails = next; else event.target.checked = !next.simpleQR;
  });

  // The Wi‑Fi dialog: network and password together, saved as one change. Empty fields clear
  // them (no network: no "Join Wi‑Fi" code; no password: an open network).
  $("settings-wifi-btn").addEventListener("click", () => {
    $("wifi-ssid").value = wifiDetails.ssid;
    $("wifi-password").value = wifiDetails.password;
    $("wifi-modal").hidden = false;
    setTimeout(() => $("wifi-ssid").focus(), 50);
  });
  // Return in the network field goes on to the password.
  $("wifi-ssid").addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    $("wifi-password").focus();
  });
  $("wifi-cancel").addEventListener("click", () => { $("wifi-modal").hidden = true; });
  $("wifi-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const next = { ...wifiDetails, ssid: $("wifi-ssid").value.trim(), password: $("wifi-password").value };
    if (!(await saveSetting({ wifi: next }))) return;
    wifiDetails = next;
    $("wifi-modal").hidden = true;
    fillWifi();
  });

  // The edit dialog: one value at a time, on top of the sheet.
  const editors = {
    name: {
      title: "Zone name", max: 40, value: () => snap.zoneName || "",
      save: (v) => v ? saveSetting({ zoneName: v }) : true,
    },
  };
  let editing = null;
  const editAddress = addressPreview($("edit-input"), $("edit-address"), () => editing === editors.name);
  document.querySelectorAll("[data-edit]").forEach((button) => button.addEventListener("click", () => {
    editing = editors[button.dataset.edit];
    const input = $("edit-input");
    $("edit-title").textContent = editing.title;
    input.maxLength = editing.max;
    input.value = editing.value();
    editAddress();
    $("edit-modal").hidden = false;
    setTimeout(() => input.focus(), 50);
  }));
  $("edit-cancel").addEventListener("click", () => { $("edit-modal").hidden = true; });
  $("edit-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (await editing.save($("edit-input").value.trim())) $("edit-modal").hidden = true;
  });

  $("settings-forget").addEventListener("click", async () => {
    if (!confirm("Forget every other host? Their phones go back to guest view. This phone stays a host.")) return;
    try {
      const reply = await api("/api/host/forget", { key: hostKey });
      hostKey = reply.key;
      saveHostKey(hostKey);
      $("settings-hosts").textContent = "1 phone";
      $("settings-forget").hidden = true;
    } catch { toast("Couldn't forget the other hosts"); }
  });
  // End (with "Save as playlist", on by default) and Save as playlist share one dialog. The name
  // starts as the party's date and a space, for the host to type the rest.
  let partyMode = null; // "end" or "save"
  let partyBusy = false;
  const partySaving = () => partyMode === "save" || $("party-save").checked;
  const partyCount = () => !partyInfo ? 0 : $("party-only").checked ? partyInfo.requestCount : partyInfo.allCount;
  const partyWillSave = () => partyCanSave() && partySaving() && partyCount() > 0;

  function updateParty() {
    // With nothing worth saving, End is a plain confirmation.
    const canSave = partyCanSave();
    $("party-save-row").hidden = partyMode !== "end" || !canSave;
    $("party-fields").hidden = !canSave || !partySaving();
    const n = partyCount();
    $("party-note").textContent = n === 0
      ? ($("party-only").checked ? "Guests haven't added any songs yet." : "No songs have played or been added yet.")
      : `${n === 1 ? "1 song" : `${n} songs`}. ${partyInfo.destination}.`;
    const go = $("party-go");
    go.disabled = partyBusy || (partyMode === "save" && !partyWillSave());
    go.classList.toggle("danger", partyMode === "end");
    if (partyBusy) go.textContent = "Saving…";
    else if (!$("party-error").hidden) go.textContent = "Try again";
    else go.textContent = partyMode === "save" ? "Save" : partyWillSave() ? "Save and end" : "End";
  }

  function openParty(mode) {
    partyMode = mode;
    partyBusy = false;
    // An Apple TV goes back to its zone list; an iPad or Mac to its start screen, unnamed here.
    const back = snap && snap.hubKind === "tv" ? ` The ${hubNoun()} goes back to its zone list.` : "";
    $("party-title").textContent = mode === "end" ? `End ${snap.zoneName || "this zone"}?` : "Save as playlist";
    $("party-sub").textContent = mode === "end"
      ? `The music stops for everyone and the queue is cleared.${back}`
      : "Saves the songs guests added so far, played or still in Up next. The party carries on.";
    $("party-save").checked = true;
    $("party-only").checked = true;
    $("party-error").hidden = true;
    $("party-nosave").hidden = true;
    const today = new Date();
    const pad = (v) => String(v).padStart(2, "0");
    const name = $("party-name");
    name.value = partyInfo ? partyInfo.suggestedName : `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())} `;
    updateParty();
    $("party-modal").hidden = false;
    // Straight away, so phones show the keyboard; the cursor goes after the date.
    if (!$("party-fields").hidden) { name.focus(); name.setSelectionRange(name.value.length, name.value.length); }
    // The counts may have moved on since the settings sheet opened.
    loadHostDetails().then(() => { if (!$("party-modal").hidden) updateParty(); }).catch(() => {});
  }

  function closeParty() { $("party-modal").hidden = true; partyMode = null; }

  async function endZone() {
    closeParty();
    $("settings-modal").hidden = true;
    try { await api("/api/host/stop", { key: hostKey }); } catch { toast("Couldn't end the zone"); }
  }

  $("party-save").addEventListener("change", updateParty);
  $("party-only").addEventListener("change", updateParty);
  $("party-cancel").addEventListener("click", closeParty);
  $("party-nosave").addEventListener("click", endZone);
  $("party-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (partyBusy) return;
    if (!partyWillSave()) { if (partyMode === "end") endZone(); return; }
    partyBusy = true;
    $("party-error").hidden = true;
    updateParty();
    const name = $("party-name").value.trim();
    let error = null;
    try {
      const res = await fetch("/api/host/save-playlist", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ key: hostKey, name, onlyRequests: $("party-only").checked }),
      });
      if (!res.ok) error = (await res.json().catch(() => null))?.error || `No answer from ${hubName()}.`;
    } catch { error = `Couldn't reach ${hubName()}.`; }
    partyBusy = false;
    if (error) {
      // Nothing ends until the host chooses: try again, or end without saving.
      $("party-error").textContent = `Couldn't save the playlist. ${error}`;
      $("party-error").hidden = false;
      $("party-nosave").hidden = partyMode !== "end";
      updateParty();
      return;
    }
    if (partyMode === "end") { endZone(); return; }
    closeParty();
    toast(`Saved “${name || partyInfo.suggestedName.trim()}”`);
  });
  $("settings-party-save").addEventListener("click", () => openParty("save"));
  $("settings-stop").addEventListener("click", () => openParty("end"));

  $("transport").addEventListener("click", (event) => {
    const button = event.target.closest("[data-action]");
    if (!button || !hosting()) return;
    let action = button.dataset.action;
    if (action === "toggle") action = snap && snap.playback.isPlaying ? "pause" : "play";
    api("/api/host/playback", { key: hostKey, action }).catch((error) => {
      debugLog(`playback ${action} failed: ${error.message}`);
      toast(`Couldn't reach ${hubName()}`);
    });
  });
  function askName() {
    $("name-input").value = myName || "";
    $("name-modal").hidden = false;
    setTimeout(() => $("name-input").focus(), 50);
  }
  function closeName() {
    store.set("canopymusic.nameAsked", "1");
    $("name-modal").hidden = true;
    updateNameChip();
  }
  $("name-chip").addEventListener("click", askName);
  $("name-skip").addEventListener("click", closeName);
  function saveMyName(raw) {
    const name = raw.trim().slice(0, 24);
    myName = name || null;
    store.set("canopymusic.name", myName || "");
    store.set("canopymusic.nameAsked", "1");
    updateNameChip();
  }
  $("name-form").addEventListener("submit", (event) => {
    event.preventDefault();
    saveMyName($("name-input").value);
    closeName();
  });
  /** The name prompt, once per phone, unless the setup sheet (which asks itself) is showing. */
  function askNameIfNeeded() {
    if (store.get("canopymusic.nameAsked") || !$("name-modal").hidden || !$("setup").hidden) return;
    askName();
  }

  // MARK: Start

  updateNameChip();
  // A phone with a host key waits to hear from the hub first: a new Apple TV zone's first host
  // gets the setup sheet, which asks for the name itself.
  if (!hostKey) askNameIfNeeded();
  debugLog(`host key ${hostKey ? "yes" : "no"}`);
  if (hostKey) {
    api("/api/host/check", { key: hostKey, clientId })
      .then(() => {
        debugLog(`host check ok, snapshot ${snap ? "in" : "not yet"}`);
        hostPaired = true;
        hostChecked = true;
        // The old single key turned out to be this hub's: keep it under this hub from now on.
        if (hubID && !hostKeys()[hubID]) { saveHostKey(hostKey); store.remove("canopymusic.hostKey"); }
        updateNameChip();
        if (snap) render();
        openSettingsFromLink();
        hideSplash();
      })
      .catch((error) => {
        debugLog(`host check failed ${error.message}`);
        hostChecked = true;
        if (snap) render(); else askNameIfNeeded();
        hideSplash();
        // Only a refusal means the key was revoked; a network hiccup keeps it.
        // Only this hub's key goes; an old single key it refused may be another hub's, so it stays.
        if (error.message === "403") {
          if (hubID && hostKeys()[hubID] === hostKey) saveHostKey(null);
          else if (!hubID) store.remove("canopymusic.hostKey");
          hostKey = null;
        }
      });
  }
  api("/api/state").then(applySnapshot).catch(() => {});
  connect();
})();
