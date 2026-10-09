// Runs in the Apple Music page's MAIN world so it can use MusicKit.
// Publishes the player state to the bar and executes commands from it.
// All parsing/validation rules live in core.js (unit-tested).
(() => {
  const TAG = "omarchy-apple-music";
  const C = globalThis.__omarchyAppleMusicCore;
  if (!C) return;
  const API = "https://amp-api.music.apple.com";

  let mk = null;
  let last = "";
  let facts = { catalogId: "", rating: 0, inLibrary: null };   // current song's rating/library state

  const post = (msg) => window.postMessage(Object.assign({ source: TAG }, msg), location.origin);
  const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms || 8000))]);

  // MusicKit's api.music() helper only issues GETs, so writes (ratings,
  // library) go straight to Apple's API with the page's own tokens. The
  // tokens never leave the page: only results are published to the bar.
  async function amp(method, path, body) {
    const r = await withTimeout(fetch(API + path, {
      method,
      headers: { Authorization: "Bearer " + mk.developerToken, "Music-User-Token": mk.musicUserToken,
                 "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined
    }), 10000);
    if (r.status >= 400) throw new Error("HTTP " + r.status);
    const t = await r.text();
    return t ? JSON.parse(t) : null;
  }
  const sf = () => mk.storefrontId || "us";

  // ---- rating + library membership of the current song -------------------
  let factsFor = "";
  async function loadFacts(cid) {
    if (!cid || cid === factsFor) return;
    factsFor = cid;
    const f = { catalogId: cid, rating: 0, inLibrary: null };
    try {
      const r = await amp("GET", "/v1/me/ratings/songs?ids=" + encodeURIComponent(cid));
      const d = r && r.data && r.data[0];
      f.rating = d && d.attributes ? d.attributes.value : 0;
    } catch (e) {}
    try {
      const r = await amp("GET", "/v1/catalog/" + sf() + "/songs/" + encodeURIComponent(cid) + "?relate=library");
      const rel = r && r.data && r.data[0] && r.data[0].relationships && r.data[0].relationships.library;
      f.inLibrary = !!(rel && rel.data && rel.data.length);
    } catch (e) {}
    if (cid === factsFor) { facts = f; publish(true); }
  }

  async function rate(value) {
    const cid = C.catalogIdOf(mk.queue.currentItem);
    if (!cid) throw new Error("not a catalog song");
    if (value === 0) await amp("DELETE", "/v1/me/ratings/songs/" + encodeURIComponent(cid));
    else await amp("PUT", "/v1/me/ratings/songs/" + encodeURIComponent(cid), { type: "rating", attributes: { value } });
    facts = Object.assign({}, facts, { catalogId: cid, rating: value });
  }

  async function addToLibrary() {
    const cid = C.catalogIdOf(mk.queue.currentItem);
    if (!cid) throw new Error("not a catalog song");
    await amp("POST", "/v1/me/library?ids[songs]=" + encodeURIComponent(cid));
    // Apple indexes the add asynchronously (seconds); show it immediately.
    facts = Object.assign({}, facts, { catalogId: cid, inLibrary: true });
  }

  // ---- search --------------------------------------------------------------
  async function search(term, id) {
    const q = encodeURIComponent(term);
    const [cat, lib] = await Promise.all([
      amp("GET", "/v1/catalog/" + sf() + "/search?types=songs,albums,playlists&limit=8&term=" + q).catch(() => null),
      amp("GET", "/v1/me/library/search?types=library-songs,library-albums,library-playlists&limit=4&term=" + q).catch(() => null)
    ]);
    const results = C.normalizeSearch(cat, lib);
    post({ type: "search", results: { id, term, ok: !!(cat || lib), sections: results } });
  }

  async function playItem(kind, id, mode) {
    const desc = C.queueDescriptor(kind, id);
    if (!desc) throw new Error("bad item");
    if (mode === "now") {
      mk.shuffleMode = 0;
      await withTimeout(mk.setQueue(Object.assign({ startPlaying: true }, desc)), 15000);
    } else if (mode === "next") {
      await withTimeout(mk.playNext(desc), 15000);
    } else {
      await withTimeout(mk.playLater(desc), 15000);
    }
  }

  // ---- whole-library random mix -------------------------------------------
  // Each request gets a generation number. A newer mix always wins: an older
  // one that is still fetching (or still appending its background songs)
  // notices it is stale and stops, instead of the new request being dropped.
  let mixGen = 0;
  async function shuffleLibrary() {
    const gen = ++mixGen;
    const PAGE = 5, PAGES = 40, FIRST = 25;
    const head = await mk.api.music("/v1/me/library/songs", { limit: 1 });
    const total = (head.data.meta && head.data.meta.total) || 0;
    if (total <= 0) throw new Error("empty library");
    const pages = await Promise.all(C.pickOffsets(total, PAGE, PAGES).map(o =>
      mk.api.music("/v1/me/library/songs", { limit: PAGE, offset: o }).catch(() => null)));
    if (gen !== mixGen) return;            // superseded while fetching
    const ids = C.shuffleInPlace([...new Set(pages.filter(Boolean).flatMap(p => p.data.data.map(s => s.id)))]);
    mk.shuffleMode = 0;                    // already random
    await mk.setQueue({ songs: ids.slice(0, FIRST), startPlaying: true });
    publish(true);
    if (gen !== mixGen || ids.length <= FIRST) return;
    await mk.playLater({ songs: ids.slice(FIRST) });
  }

  // ---- publish -------------------------------------------------------------
  function publish(force) {
    if (!mk) return;
    let state;
    try { state = C.snapshot(mk, facts); } catch (e) { return; }
    if (state.catalogId && state.catalogId !== factsFor) loadFacts(state.catalogId);
    const json = JSON.stringify(state);
    if (!force && json === last) return;
    last = json;
    post({ type: "queue", state });
  }

  async function run(cmd) {
    switch (cmd.action) {
      case "playIndex":
        await withTimeout(mk.changeToMediaAtIndex(cmd.index));
        if (!mk.isPlaying) await withTimeout(mk.play());
        break;
      case "shuffleLibrary": await withTimeout(shuffleLibrary(), 30000); break;
      case "shuffle": mk.shuffleMode = (cmd.on !== undefined ? cmd.on : mk.shuffleMode !== 1) ? 1 : 0; break;
      case "repeat": mk.repeatMode = cmd.mode !== undefined ? cmd.mode : C.nextRepeatMode(mk.repeatMode); break;
      case "seek": await withTimeout(mk.seekToTime(cmd.seconds)); break;
      case "rate": await rate(cmd.value); break;
      case "addToLibrary": await addToLibrary(); break;
      case "search": await search(cmd.term, cmd.id); return;   // result is its own message
      case "playItem": await playItem(cmd.kind, cmd.id, cmd.mode); break;
      case "refresh": break;
    }
  }

  window.addEventListener("message", async (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.source !== TAG || d.type !== "command" || !mk) return;
    const cmd = C.sanitizeCommand(d);
    if (!cmd) return;
    try { await run(cmd); }
    catch (err) {
      if (cmd.action === "search") post({ type: "search", results: { id: cmd.id, term: cmd.term, ok: false, sections: C.normalizeSearch(null, null) } });
    }
    publish(true);
  });

  function attach() {
    try { mk = window.MusicKit && window.MusicKit.getInstance(); } catch (e) { mk = null; }
    if (!mk) return false;
    for (const ev of ["queueItemsDidChange", "queuePositionDidChange", "nowPlayingItemDidChange",
                      "shuffleModeDidChange", "repeatModeDidChange", "playbackStateDidChange"]) {
      try { mk.addEventListener(ev, () => publish(false)); } catch (e) {}
    }
    publish(true);
    return true;
  }

  const wait = setInterval(() => { if (attach()) clearInterval(wait); }, 1000);
  setInterval(() => publish(false), 1000);   // keeps the clock fresh; only changes are sent
})();
