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
        if (!img) { img = document.createElement("img"); img.loading = "lazy"; img.decoding = "async"; img.alt = ""; el.append(img); }
        if (img.getAttribute("src") !== url) img.src = url;
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

  function render() {
    const current = snap.current;
    applyTheme(current && current.track);

    // The host can turn off reordering from phones (host control can always reorder).
    document.querySelector(".list-head .hint").hidden = snap.canReorder === false && !hosting();
    $("transport").hidden = !hosting();
    const queueOff = snap.canQueue === false && !hosting();
    $("search-trigger").hidden = queueOff;
    $("queue-off").hidden = !queueOff;
    renderHost();
    if (settingsOpen()) fillSettings();
    // The hub's address can arrive (or change) while a zone name is being edited.
    if (!$("setup").hidden) setupAddress();
    if (!$("edit-modal").hidden) editAddress();
    const playing = !!(current && snap.playback.isPlaying);
    $("t-play").innerHTML = playing ? icons.pause : icons.play;
    $("t-play").setAttribute("aria-label", playing ? "Pause" : "Play");
    $("zone-device").innerHTML = snap.hubKind === "tv" ? icons.tv : icons.ipad;
    $("zone-name").textContent = snap.zoneName || "";
    document.title = snap.zoneName ? `${snap.zoneName} - Canopy Music` : "Canopy Music";
    $("zone-line").hidden = !snap.zoneName;
    $("playlist-name").textContent = snap.playlistName || "";
    $("playlist-line").hidden = !snap.playlistName;
    $("now-status").textContent = !current ? "Waiting for music" : snap.playback.isPlaying ? "Now playing" : "Paused";
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
    return { text: r.origin === "ipad" ? "iPad" : "Guest", mine: false };
  }

  /// "the Apple TV" or "the iPad": whichever this zone plays from.
  function hubName() { return snap && snap.hubKind === "tv" ? "the Apple TV" : "the iPad"; }

  const icons = {
    ipad: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="5" width="19" height="14" rx="2.5"/></svg>',
    tv: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8 20.5h8"/></svg>',
    grip: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01" stroke-width="3"/></svg>',
    x: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    lock: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
    check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 5 5 9-10"/></svg>',
    person: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
    play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l10.5-6.5z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>',
    pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6.5" y="5" width="4" height="14" rx="1.2"/><rect x="13.5" y="5" width="4" height="14" rx="1.2"/></svg>',
  };

  function fillRow(li, item) {
    const locked = snap.lockedNextID === item.id;
    const label = requesterLabel(item);
    li.classList.add("row");
    li.classList.toggle("locked", locked);
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
      lock.title = "Up next. Locked in.";
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
      snap.lockedNextID === item.id, label ? `${label.text}${label.mine}` : "", hosting(), snap.canReorder !== false].join("|");
  }

  function renderQueue() {
    const list = $("queue");
    const items = snap.upNext;
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

    $("queue-empty").hidden = snap.upNext.length > 0;
    firstRender = false;
    laterQueueChanged();
  }

  // MARK: Later (the base playlist past the live Up Next)

  // The same list carries on, read-only (no handle or remove), with the rest of the playlist's
  // cycle, a page at a time as the end comes near. It isn't in snapshots; when the queue moves on,
  // the rows already shown are fetched again so the list stays in step.
  const later = { rows: [], total: null, loading: false, generation: 0, version: null, refetchTimer: null };
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
    if (later.loading || (later.total !== null && later.rows.length >= later.total) || !snap || !snap.upNext.length) return;
    later.loading = true;
    const generation = later.generation;
    try {
      const page = await fetchLater(later.rows.length, 50);
      if (generation !== later.generation) return;
      later.rows.push(...page.rows.filter((r) => !laterEls.has(r.id)));
      later.total = page.total;
      later.version = page.version;
      renderLater();
    } catch {} finally {
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
    if (!snap || !snap.current || !snap.current.track.duration) { fill.style.width = "0"; return; }
    const pb = snap.playback;
    const elapsed = pb.position + (pb.isPlaying ? (Date.now() - pb.capturedAt) / 1000 : 0);
    fill.style.width = `${Math.min(100, (elapsed / snap.current.track.duration) * 100)}%`;
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
    // The hub's reason (debug hubs describe the error in full), for the debug log.
    if (!res.ok) throw new Error(`${path} ${res.status} ${(await res.text().catch(() => "")).slice(0, 600)}`);
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  let socket = null;
  let retries = 0;
  let offlineTimer = null;
  function connect() {
    if (socket && socket.readyState <= 1) return;
    socket = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
    socket.onopen = () => {
      retries = 0;
      clearTimeout(offlineTimer);
      $("offline").hidden = true;
    };
    socket.onmessage = (event) => applySnapshot(JSON.parse(event.data));
    socket.onclose = () => {
      clearTimeout(offlineTimer);
      offlineTimer = setTimeout(() => { $("offline").hidden = false; }, 1500);
      setTimeout(connect, Math.min(1000 * 2 ** retries++, 8000));
    };
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) connect(); });

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
    const floor = rows[0] && rows[0].classList.contains("locked") ? 1 : 0;
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
      const after = d.to === 0 ? null : order[d.to - 1].dataset.id;
      // Optimistic local reorder so an incoming snapshot doesn't bounce the row back.
      const items = snap.upNext.slice();
      const [moved] = items.splice(items.findIndex((i) => i.id === id), 1);
      items.splice(d.to, 0, moved);
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
  $("setup-scroll").addEventListener("focusin", (event) => {
    const search = event.target.closest(".picker-search");
    const field = search || (event.target.matches("input.text-input") ? event.target : null);
    if (!field) return;
    const target = search || field.previousElementSibling || field;
    setTimeout(() => {
      if (document.activeElement !== event.target) return;
      const scroller = $("setup-scroll");
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
      const res = await fetch(`/api/search?q=${encodeURIComponent(term)}`, { signal: searchAbort.signal });
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

  let playlistsCache = null;
  let setupPick = null;
  let setupDismissed = false;
  let setupStarting = false;
  const keyQuery = () => `key=${encodeURIComponent(hostKey || "")}`;

  function renderHost() {
    const on = hosting();
    $("settings-btn").hidden = !on;
    if (!on) {
      for (const id of ["setup", "settings-modal", "edit-modal", "wifi-modal", "invite-modal", "playlists"]) $(id).hidden = true;
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

  async function loadPlaylists() {
    if (playlistsCache) return playlistsCache;
    playlistsCache = await api(`/api/host/playlists?${keyQuery()}`);
    return playlistsCache;
  }

  // A searchable playlist list (Change base playlist, and a TV zone's first setup). Typing filters
  // the library (ignoring case and accents) and, as on the iPad, searches the music service's
  // playlists, shown below. Rows are built once per load; filtering only hides them.
  const fold = (text) => (text || "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

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
    sub.textContent = p.subtitle || "";
    meta.append(title, sub);
    li.append(art, meta);
    li.addEventListener("click", () => onPick(p));
    return li;
  }

  function playlistPicker(prefix, listId, emptyId, onPick) {
    const list = $(listId), empty = $(emptyId), search = $(`${prefix}-search`);
    const catalogList = $(`${prefix}-catalog`), catalogHead = $(`${prefix}-catalog-head`);
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
            loaded = true;
          }
          filter();
        } catch {
          showEmpty("Couldn't load playlists.");
        }
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
    const hasQueue = !!(snap && (snap.current || snap.upNext.length));
    if (hasQueue && !confirm(`Switch to "${p.name}"? The queue starts over and requests are cleared.`)) return;
    pickerBusy("playlists", button, true, "Loading…");
    try {
      const reply = await api("/api/host/playlist", {
        key: hostKey, playlist: p, play: !!(snap && snap.playback.isPlaying), shuffle: $("playlists-shuffle").checked,
      });
      sheet.hidden = true;
      toastSkipped(reply);
    } catch { toast("Couldn't change the playlist"); }
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

  async function openSetup() {
    // The setup sheet asks for this phone's name itself.
    if (!$("name-modal").hidden) { $("name-modal").hidden = true; }
    $("setup").hidden = false;
    debugScreen("setup opened");
    $("setup-you").value = myName || "";
    $("setup-name").value = snap.zoneName || "";
    setupAddress();
    $("setup-sub").textContent = snap.hubKind === "tv"
      ? "Music will play from your Apple TV. Use Control Center to change audio output."
      : "You're hosting this zone. Guests can join once music is playing.";
    await setupPicker.open();
    if (setupPick) setupPicker.select(setupPick.id);
  }
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
    setupBusy(true);
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
      toast("Couldn't start. Try again.");
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
        li.innerHTML = d.kind === "tv" ? icons.tv : icons.ipad;
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
    const device = snap.hubKind === "tv" ? "Apple TV" : "iPad";
    $("party-title").textContent = mode === "end" ? `End ${snap.zoneName || "this zone"}?` : "Save as playlist";
    $("party-sub").textContent = mode === "end"
      ? `The music stops for everyone and the queue is cleared. The ${device} goes back to its zone list.`
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
