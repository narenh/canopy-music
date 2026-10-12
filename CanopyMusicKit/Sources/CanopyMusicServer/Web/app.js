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

  const params = new URLSearchParams(location.search);

  // Saved data (name, phone ID, host key) is per address. QR codes use the IP, which every phone
  // can open; if this phone can also reach the friendly address (music.local), continue there
  // before saving anything, so everything lives under that one address.
  let initial = null;
  try { initial = await (await fetch("/api/state")).json(); } catch {}
  // Which hub this is (older hubs don't say), for keeping host keys per hub.
  const hubID = (initial && initial.hubID) || null;
  await (async () => {
    const address = initial && initial.address, lan = initial && initial.lanAddress;
    if (!address || !lan || address === location.host) return;
    // Only if that name reaches this same hub: another zone can answer at music.local too.
    if (!(await reachable(address, lan))) return;
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

    const img = $("backdrop-img");
    img.classList.remove("shown");
    const url = track && track.artworkURL;
    if (!url) return;
    const loader = new Image();
    loader.onload = () => { if (themedTrackId === id) { img.src = url; img.classList.add("shown"); } };
    loader.src = url;
  }

  function setArt(el, track, large) {
    const url = large ? track.artworkURL || track.thumbnailURL : track.thumbnailURL || track.artworkURL;
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
    if (snap && next.version < snap.version) return;
    snap = next;
    render();
    openSettingsFromLink();
    followRename();
  }

  // A renamed zone moves to a new `.local` name; a page on the old one follows it there (if this
  // phone can reach the new name), so it isn't left on a name that no longer answers.
  let followedAddress = null;
  async function followRename() {
    const address = snap.address;
    if (!address || address === location.host || address === followedAddress) return;
    if (!location.hostname.endsWith(".local")) return; // on the IP address, which still works
    followedAddress = address;
    if (!(await reachable(address, snap.lanAddress))) return;
    moveTo(address, new URLSearchParams(location.search), hostPaired ? hostKey : null);
  }

  // A link to …/#settings opens the zone settings once this phone is a host and the state has loaded.
  let settingsLinkPending = location.hash === "#settings";
  // The same page opened again with #settings only changes the hash.
  window.addEventListener("hashchange", () => {
    settingsLinkPending = location.hash === "#settings";
    openSettingsFromLink();
  });
  function openSettingsFromLink() {
    if (!settingsLinkPending || !snap || !hosting()) return;
    settingsLinkPending = false;
    $("settings-btn").click();
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

  function renderQueue() {
    const list = $("queue");
    const before = new Map();
    if (!firstRender) for (const [id, el] of rowEls) before.set(id, el.getBoundingClientRect().top);

    const seen = new Set();
    for (const item of snap.upNext) {
      let el = rowEls.get(item.id);
      const isNew = !el;
      if (isNew) { el = document.createElement("li"); rowEls.set(item.id, el); }
      fillRow(el, item);
      list.appendChild(el);
      seen.add(item.id);
      if (isNew && !firstRender) {
        el.animate(
          [{ opacity: 0, transform: "translateY(-8px) scale(0.98)" }, { opacity: 1, transform: "none" }],
          { duration: 420, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" }
        );
        if (item.requester) flashIds.add(item.id);
      }
    }
    for (const [id, el] of rowEls) {
      if (!seen.has(id)) { el.remove(); rowEls.delete(id); }
    }

    for (const [id, top] of before) {
      const el = rowEls.get(id);
      if (!el) continue;
      const dy = top - el.getBoundingClientRect().top;
      if (Math.abs(dy) > 1) {
        el.animate([{ transform: `translateY(${dy}px)` }, { transform: "none" }], { duration: 380, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
      }
    }

    for (const id of flashIds) flash(id);
    flashIds.clear();

    $("queue-empty").hidden = snap.upNext.length > 0;
    firstRender = false;
  }

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
    if (!res.ok) throw new Error(`${res.status}`);
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
    li.animate([{ opacity: 1 }, { opacity: 0, transform: "translateX(24px)" }], { duration: 200, fill: "forwards" });
    try {
      // Removing your own song: say it with the ID it was added under.
      const item = snap && snap.upNext.find((i) => i.id === id);
      const owner = item && item.requester && myIds.has(item.requester.clientID) ? item.requester.clientID : clientId;
      await api("/api/remove", { id, clientId: owner, key: hosting() ? hostKey : undefined });
    } catch {
      toast("Couldn't remove that one");
      if (snap) render();
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
  const keyQuery = () => `key=${encodeURIComponent(hostKey || "")}`;

  function renderHost() {
    const on = hosting();
    $("settings-btn").hidden = !on;
    if (!on) { $("setup").hidden = true; $("settings-modal").hidden = true; return; }
    // A TV zone has no screens of its own for setup: the first host does it here.
    const needsSetup = snap.hubKind === "tv" && !snap.playlistName && !setupDismissed;
    if (needsSetup && $("setup").hidden) openSetup();
    if (!needsSetup) $("setup").hidden = true;
  }

  async function loadPlaylists() {
    if (playlistsCache) return playlistsCache;
    playlistsCache = await api(`/api/host/playlists?${keyQuery()}`);
    return playlistsCache;
  }

  function fillPlaylists(list, emptyEl, playlists, selectedId, onPick) {
    list.innerHTML = "";
    emptyEl.hidden = playlists.length > 0;
    emptyEl.textContent = "No playlists in this library.";
    for (const p of playlists) {
      const li = document.createElement("li");
      li.className = "playlist-row" + (p.id === selectedId ? " selected" : "");
      const art = document.createElement("div");
      art.className = "art";
      if (p.artworkURL) art.style.backgroundImage = `url("${p.artworkURL}")`;
      const meta = document.createElement("div");
      const title = document.createElement("p");
      title.textContent = p.name;
      const sub = document.createElement("p");
      sub.className = "row-sub";
      sub.textContent = p.subtitle || "";
      meta.append(title, sub);
      li.append(art, meta);
      if (p.id === selectedId) {
        const check = document.createElement("span");
        check.className = "check";
        check.innerHTML = icons.check;
        li.append(check);
      }
      li.addEventListener("click", () => onPick(p));
      list.append(li);
    }
  }

  // Changing the base playlist from the host page.
  $("settings-playlist-change").addEventListener("click", async () => {
    $("settings-modal").hidden = true;
    $("playlists").hidden = false;
    $("playlists-empty").hidden = false;
    $("playlists-empty").textContent = "Loading playlists…";
    try {
      const playlists = await loadPlaylists();
      fillPlaylists($("playlist-list"), $("playlists-empty"), playlists, null, async (p) => {
        if (!confirm(`Switch to "${p.name}"? The queue starts over and requests are cleared.`)) return;
        $("playlists").hidden = true;
        try {
          await api("/api/host/playlist", { key: hostKey, playlist: p, play: !!(snap && snap.playback.isPlaying) });
        } catch { toast("Couldn't change the playlist"); }
      });
    } catch {
      $("playlists-empty").textContent = "Couldn't load playlists.";
    }
  });
  $("playlists-done").addEventListener("click", () => { $("playlists").hidden = true; });

  async function openSetup() {
    $("setup").hidden = false;
    $("setup-name").value = snap.zoneName || "";
    $("setup-sub").textContent = `You're hosting ${snap.hubKind === "tv" ? "the Apple TV" : "this zone"}. Guests can join once music is playing.`;
    $("setup-empty").hidden = false;
    $("setup-empty").textContent = "Loading playlists…";
    const redraw = (playlists) => fillPlaylists($("setup-playlists"), $("setup-empty"), playlists, setupPick && setupPick.id, (p) => {
      setupPick = p;
      $("setup-start").disabled = false;
      redraw(playlists);
    });
    try { redraw(await loadPlaylists()); } catch { $("setup-empty").textContent = "Couldn't load playlists."; }
  }
  $("setup-start").addEventListener("click", async () => {
    if (!setupPick) return;
    $("setup-start").disabled = true;
    try {
      const name = $("setup-name").value.trim();
      if (name) await api("/api/host/settings", { key: hostKey, zoneName: name });
      await api("/api/host/playlist", { key: hostKey, playlist: setupPick, play: true });
      setupDismissed = true;
      $("setup").hidden = true;
    } catch {
      toast("Couldn't start. Try again.");
      $("setup-start").disabled = false;
    }
  });

  // Another host: the hub draws the QR code.
  $("settings-invite").addEventListener("click", () => {
    $("invite-img").src = `/api/host/invite.png?${keyQuery()}&t=${Date.now()}`;
    $("invite-modal").hidden = false;
  });
  $("invite-done").addEventListener("click", () => { $("invite-modal").hidden = true; });

  // Zone settings: the admin view for every hub (an Apple TV has no settings screens).
  $("settings-btn").addEventListener("click", () => {
    $("settings-name").value = snap.zoneName || "";
    // The `.local` address follows the zone name.
    $("settings-address").hidden = !snap.address;
    $("settings-address").textContent = `Phones can also go to ${snap.address}. It follows the zone name.`;
    // Only hubs with something to unlock (iPads) have a PIN. It's never sent here, only whether it's set.
    const pinBlock = $("settings-pin-block");
    pinBlock.hidden = snap.hasPIN == null;
    $("settings-pin").value = "";
    $("settings-pin").placeholder = snap.hasPIN ? "Set (type a new one to change it)" : "Not set";
    $("settings-pin-remove").hidden = !snap.hasPIN;
    $("settings-playlist").textContent = snap.playlistName || "None yet";
    $("settings-queue").checked = snap.canQueue !== false;
    $("settings-reorder").checked = snap.canReorder !== false;
    $("settings-displays").checked = snap.displaysCanControl !== false;
    const hosts = snap.hostPhones || 0;
    $("settings-hosts").textContent = hosts === 1 ? "1 phone" : `${hosts} phones`;
    $("settings-forget").hidden = hosts < 2;
    const stop = $("settings-stop");
    stop.textContent = `Stop ${snap.zoneName || "this zone"}`;
    // Host-only details: the Wi‑Fi (never in the snapshot guests get) and connected displays.
    settingsWifiLoaded = false;
    for (const id of ["settings-wifi-ssid", "settings-wifi-password"]) { $(id).value = ""; $(id).disabled = true; }
    const list = $("settings-display-list");
    list.innerHTML = "";
    api(`/api/host/details?${keyQuery()}`).then((details) => {
      $("settings-wifi-ssid").value = details.wifi.ssid;
      $("settings-wifi-password").value = details.wifi.password;
      $("settings-wifi-simple").checked = details.wifi.simpleQR;
      for (const id of ["settings-wifi-ssid", "settings-wifi-password"]) $(id).disabled = false;
      settingsWifiLoaded = true;
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
  let settingsWifiLoaded = false;
  $("settings-pin-remove").addEventListener("click", async () => {
    if (!confirm("Remove the unlock PIN?")) return;
    try { await api("/api/host/settings", { key: hostKey, pin: "" }); $("settings-pin-remove").hidden = true; $("settings-pin").placeholder = "Not set"; }
    catch { toast("Couldn't remove the PIN"); }
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
  $("settings-cancel").addEventListener("click", () => { $("settings-modal").hidden = true; });
  $("settings-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    $("settings-modal").hidden = true;
    try {
      await api("/api/host/settings", {
        key: hostKey,
        zoneName: $("settings-name").value.trim() || undefined,
        pin: $("settings-pin").value.trim() || undefined,
        // Only if the current values loaded, so a slow load can't blank the Wi‑Fi.
        wifi: settingsWifiLoaded ? {
          ssid: $("settings-wifi-ssid").value.trim(),
          password: $("settings-wifi-password").value,
          simpleQR: $("settings-wifi-simple").checked,
        } : undefined,
        phonesCanQueue: $("settings-queue").checked,
        phonesCanReorder: $("settings-reorder").checked,
        displaysCanControl: $("settings-displays").checked,
      });
    } catch { toast("Couldn't save settings"); }
  });
  $("settings-stop").addEventListener("click", async () => {
    const device = snap.hubKind === "tv" ? "Apple TV" : "iPad";
    if (!confirm(`Stop ${snap.zoneName || "this zone"}? The music stops for everyone, and the ${device} goes back to its zone list.`)) return;
    $("settings-modal").hidden = true;
    try { await api("/api/host/stop", { key: hostKey }); } catch { toast("Couldn't stop the zone"); }
  });

  $("transport").addEventListener("click", (event) => {
    const button = event.target.closest("[data-action]");
    if (!button || !hosting()) return;
    let action = button.dataset.action;
    if (action === "toggle") action = snap && snap.playback.isPlaying ? "pause" : "play";
    api("/api/host/playback", { key: hostKey, action }).catch(() => toast(`Couldn't reach ${hubName()}`));
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
  $("name-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const name = $("name-input").value.trim().slice(0, 24);
    myName = name || null;
    store.set("canopymusic.name", myName || "");
    closeName();
  });

  // MARK: Start

  updateNameChip();
  if (!store.get("canopymusic.nameAsked")) askName();
  if (hostKey) {
    api("/api/host/check", { key: hostKey, clientId })
      .then(() => {
        hostPaired = true;
        // The old single key turned out to be this hub's: keep it under this hub from now on.
        if (hubID && !hostKeys()[hubID]) { saveHostKey(hostKey); store.remove("canopymusic.hostKey"); }
        updateNameChip();
        if (snap) render();
        openSettingsFromLink();
      })
      .catch((error) => {
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
