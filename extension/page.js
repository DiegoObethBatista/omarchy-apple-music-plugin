// Runs in the page's MAIN world so it can read MusicKit. Publishes the queue
// neighbourhood (previous / current / next) and executes jump commands.
(() => {
  const TAG = "omarchy-apple-music";
  const UPCOMING = 5;

  const art = (i, size) => {
    const u = i && (i.artworkURL || (i.attributes && i.attributes.artwork && i.attributes.artwork.url));
    return u ? String(u).replace("{w}", size).replace("{h}", size).replace("{f}", "jpg") : "";
  };
  const item = (i, index) => i ? {
    index,
    id: String(i.id || ""),
    title: i.title || (i.attributes && i.attributes.name) || "",
    artist: i.artistName || (i.attributes && i.attributes.artistName) || "",
    album: i.albumName || (i.attributes && i.attributes.albumName) || "",
    art: art(i, 120),
    duration: Math.round((i.playbackDuration || 0) / 1000)
  } : null;

  let mk = null;
  let last = "";

  function snapshot() {
    const q = mk.queue;
    const pos = q.position;
    const items = q.items || [];
    const upcoming = [];
    for (let i = pos + 1; i < items.length && upcoming.length < UPCOMING; i++) {
      if (items[i] && items[i].isPlayable !== false) upcoming.push(item(items[i], i));
    }
    // Autoplay ("similar songs" after the album/single ends) lives in a
    // separate list. Its entries have no stable queue index until MusicKit
    // splices them in, so they're display-only (index -1).
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
    const next = nextIdx !== undefined && nextIdx !== null && nextIdx >= 0
      ? item(items[nextIdx], nextIdx) : (upcoming[0] || null);
    return {
      position: pos,
      length: q.length,
      shuffle: mk.shuffleMode === 1,
      repeat: mk.repeatMode,
      autoplay: !!mk.autoplayEnabled,
      current: item(q.currentItem, pos),
      previous: prevIdx !== undefined && prevIdx !== null && prevIdx >= 0 ? item(items[prevIdx], prevIdx) : null,
      next,
      upcoming
    };
  }

  function publish(force) {
    if (!mk) return;
    let state;
    try { state = snapshot(); } catch (e) { return; }
    const json = JSON.stringify(state);
    if (!force && json === last) return;
    last = json;
    window.postMessage({ source: TAG, type: "queue", state }, location.origin);
  }

  window.addEventListener("message", async (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.source !== TAG || d.type !== "command" || !mk) return;
    window.__omarchyLastCommand = { action: d.action, index: d.index, at: Date.now() };
    const withTimeout = (p) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 8000))]);
    try {
      if (d.action === "playIndex" && Number.isInteger(d.index)) {
        await withTimeout(mk.changeToMediaAtIndex(d.index));
        if (!mk.isPlaying) await withTimeout(mk.play());
      } else if (d.action === "refresh") {
        publish(true);
      }
    } catch (err) { /* ignore: item may be unplayable */ }
    publish(true);
  });

  function attach() {
    try { mk = window.MusicKit && window.MusicKit.getInstance(); } catch (e) { mk = null; }
    if (!mk) return false;
    for (const ev of ["queueItemsDidChange", "queuePositionDidChange", "nowPlayingItemDidChange",
                      "shuffleModeDidChange", "repeatModeDidChange"]) {
      try { mk.addEventListener(ev, () => publish(false)); } catch (e) {}
    }
    publish(true);
    return true;
  }

  const wait = setInterval(() => { if (attach()) clearInterval(wait); }, 1000);
  // Safety net in case an event is missed.
  setInterval(() => publish(false), 3000);
})();
