// Pure helpers shared by page.js (runs in the Apple Music page) and the Node
// test suite (tests/core.test.mjs). No DOM, no MusicKit, no network in here:
// everything takes plain data in and returns plain data out, so every rule
// below is unit-tested.
(function (root) {
  "use strict";

  const UPCOMING = 5;
  const REPEAT = { OFF: 0, ONE: 1, ALL: 2 };           // MusicKit.PlayerRepeatMode
  const KINDS = ["songs", "albums", "playlists", "library-songs", "library-albums", "library-playlists"];
  const MODES = ["now", "next", "later"];
  // Apple ids: catalog "1229760597", library "i.rzm1qfMa2L90" / "l.xxx" / "p.xxx",
  // playlists "pl.e98a8cdc…". Anything else is rejected before it reaches the API.
  const ID_RE = /^[A-Za-z0-9._-]{1,64}$/;

  function art(i, size) {
    const u = i && (i.artworkURL || (i.attributes && i.attributes.artwork && i.attributes.artwork.url));
    if (!u) return "";
    const s = String(u).replace("{w}", size).replace("{h}", size).replace("{f}", "jpg");
    return /^https:\/\/[a-z0-9-]+\.mzstatic\.com\//.test(s) ? s : "";
  }

  function attr(i, k) { return i && i.attributes ? i.attributes[k] : undefined; }

  // Catalog id of a queue item, or "" (uploaded/non-catalog tracks have none).
  function catalogIdOf(i) {
    if (!i) return "";
    const pp = attr(i, "playParams") || i.playParams || {};
    if (pp.catalogId) return String(pp.catalogId);
    if (!pp.isLibrary && /^\d+$/.test(String(pp.id || i.id || ""))) return String(pp.id || i.id);
    return "";
  }

  function isLibraryItem(i) {
    const pp = (i && (attr(i, "playParams") || i.playParams)) || {};
    return !!pp.isLibrary;
  }

  function item(i, index) {
    if (!i) return null;
    return {
      index,
      id: String(i.id || ""),
      title: i.title || attr(i, "name") || "",
      artist: i.artistName || attr(i, "artistName") || "",
      album: i.albumName || attr(i, "albumName") || "",
      art: art(i, 120),
      duration: Math.round((i.playbackDuration || attr(i, "durationInMillis") || 0) / 1000)
    };
  }

  // The state the bar shows. `mk` only needs the MusicKit fields read below,
  // so tests pass a plain object. `extra` = song facts fetched separately
  // (rating / library membership) keyed to the current catalog id.
  function snapshot(mk, extra) {
    const q = mk.queue;
    const pos = q.position;
    const items = q.items || [];
    const upcoming = [];
    for (let i = pos + 1; i < items.length && upcoming.length < UPCOMING; i++) {
      if (items[i] && items[i].isPlayable !== false) upcoming.push(item(items[i], i));
    }
    // Autoplay ("similar songs" after the queue) lives in a separate list and
    // has no stable index until MusicKit splices it in: display-only (-1).
    let autoplay = [];
    try { autoplay = q.unplayedAutoplayItems || q.autoplayItems || []; } catch (e) {}
    for (const a of autoplay) {
      if (upcoming.length >= UPCOMING) break;
      if (!a || a.isPlayable === false) continue;
      let idx = -1;
      try { idx = q.indexForItem(a); } catch (e) {}
      if (idx !== -1 && idx <= pos) continue;
      if (upcoming.some(u => u.id && u.id === String(a.id))) continue;
      const t = item(a, idx);
      t.autoplay = true;
      upcoming.push(t);
    }
    const prevIdx = q.previousPlayableItemIndex;
    const nextIdx = q.nextPlayableItemIndex;
    const valid = (n) => n !== undefined && n !== null && n >= 0;
    const cur = q.currentItem;
    const cid = catalogIdOf(cur);
    const facts = extra && extra.catalogId === cid ? extra : {};
    return {
      position: pos,
      length: q.length,
      shuffle: mk.shuffleMode === 1,
      repeat: [0, 1, 2].includes(mk.repeatMode) ? mk.repeatMode : 0,
      autoplay: !!mk.autoplayEnabled,
      // Per-track clock from MusicKit. Chromium's MPRIS clock spans the whole
      // queue (one continuous MSE stream), so it can't be used.
      playing: !!mk.isPlaying,
      time: Math.max(0, Math.floor(mk.currentPlaybackTime || 0)),
      duration: Math.max(0, Math.round(mk.currentPlaybackDuration || 0)),
      current: item(cur, pos),
      catalogId: cid,
      rating: typeof facts.rating === "number" ? facts.rating : 0,
      inLibrary: isLibraryItem(cur) ? true : (typeof facts.inLibrary === "boolean" ? facts.inLibrary : null),
      previous: valid(prevIdx) ? item(items[prevIdx], prevIdx) : null,
      next: valid(nextIdx) ? item(items[nextIdx], nextIdx) : (upcoming[0] || null),
      upcoming
    };
  }

  // ---- whole-library random mix ------------------------------------------
  // Random page offsets spread over the library (many tiny pages, so the
  // mix never clusters alphabetically).
  function pickOffsets(total, pageSize, pages, rng) {
    rng = rng || Math.random;
    const want = Math.min(pages, Math.ceil(total / pageSize));
    const span = Math.max(1, total - pageSize + 1);
    const out = new Set();
    let guard = want * 50;
    while (out.size < want && guard-- > 0) out.add(Math.floor(rng() * span));
    return [...out];
  }

  function shuffleInPlace(a, rng) {
    rng = rng || Math.random;
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(rng() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }

  // off -> all -> one -> off, the same order as the Music app.
  function nextRepeatMode(m) { return m === REPEAT.OFF ? REPEAT.ALL : m === REPEAT.ALL ? REPEAT.ONE : REPEAT.OFF; }

  // ---- search ------------------------------------------------------------
  function result(x, kind) {
    const a = x.attributes || {};
    const sub = kind.indexOf("songs") !== -1 ? [a.artistName, a.albumName].filter(Boolean).join(" · ")
              : kind.indexOf("albums") !== -1 ? [a.artistName, a.releaseDate ? String(a.releaseDate).slice(0, 4) : ""].filter(Boolean).join(" · ")
              : (a.curatorName || (a.description && a.description.short) || "Playlist");
    return { kind, id: String(x.id), title: a.name || "", subtitle: sub || "", art: art(x, 96),
             duration: Math.round((a.durationInMillis || 0) / 1000) };
  }

  // Flatten Apple's catalog + library search responses into ordered sections.
  function normalizeSearch(catalog, library, limits) {
    limits = limits || { library: 4, songs: 6, albums: 4, playlists: 3 };
    const res = (r, k) => (r && r.results && r.results[k] && r.results[k].data) || [];
    const lib = [];
    for (const k of ["library-songs", "library-albums", "library-playlists"])
      for (const x of res(library, k)) if (lib.length < limits.library) lib.push(result(x, k));
    return {
      library: lib,
      songs: res(catalog, "songs").slice(0, limits.songs).map(x => result(x, "songs")),
      albums: res(catalog, "albums").slice(0, limits.albums).map(x => result(x, "albums")),
      playlists: res(catalog, "playlists").slice(0, limits.playlists).map(x => result(x, "playlists"))
    };
  }

  // MusicKit setQueue/playNext/playLater descriptor for a search result.
  function queueDescriptor(kind, id) {
    const map = { "songs": "song", "albums": "album", "playlists": "playlist",
                  "library-songs": "song", "library-albums": "album", "library-playlists": "playlist" };
    const key = map[kind];
    return key && ID_RE.test(id) ? { [key]: id } : null;
  }

  // ---- command validation --------------------------------------------------
  // Every command from the bridge is rebuilt field-by-field here; anything
  // unknown or out of range returns null and is ignored.
  function sanitizeCommand(d) {
    if (!d || typeof d !== "object" || typeof d.action !== "string") return null;
    const a = d.action;
    const int = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
    switch (a) {
      case "refresh": case "shuffleLibrary": case "addToLibrary":
        return { action: a };
      case "playIndex":
        return int(d.index, 0, 100000) ? { action: a, index: d.index } : null;
      case "seek":
        return typeof d.seconds === "number" && isFinite(d.seconds) && d.seconds >= 0 && d.seconds <= 86400
          ? { action: a, seconds: d.seconds } : null;
      case "shuffle":
        return d.on === undefined ? { action: a } : typeof d.on === "boolean" ? { action: a, on: d.on } : null;
      case "repeat":
        return d.mode === undefined ? { action: a } : int(d.mode, 0, 2) ? { action: a, mode: d.mode } : null;
      case "rate":
        return int(d.value, -1, 1) ? { action: a, value: d.value } : null;
      case "search":
        return typeof d.term === "string" && d.term.trim().length >= 1 && d.term.length <= 200 && int(d.id, 0, 1e9)
          ? { action: a, term: d.term.trim(), id: d.id } : null;
      case "playItem":
        return KINDS.includes(d.kind) && typeof d.id === "string" && ID_RE.test(d.id) && MODES.includes(d.mode)
          ? { action: a, kind: d.kind, id: d.id, mode: d.mode } : null;
      default:
        return null;
    }
  }

  const api = { UPCOMING, REPEAT, KINDS, MODES, ID_RE, art, catalogIdOf, isLibraryItem, item, snapshot,
                pickOffsets, shuffleInPlace, nextRepeatMode, normalizeSearch, queueDescriptor, sanitizeCommand };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.__omarchyAppleMusicCore = Object.freeze(api);
})(typeof globalThis !== "undefined" ? globalThis : this);
