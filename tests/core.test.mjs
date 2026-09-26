// Unit tests for extension/core.js (the logic that runs inside Apple Music).
// Run: node --test tests/
import test from "node:test";
import assert from "node:assert/strict";
import { core as C, fakeMusicKit, seeded } from "./helpers.mjs";

test("snapshot: current / previous / next / upcoming", () => {
  const s = C.snapshot(fakeMusicKit());
  assert.equal(s.current.title, "Two");
  assert.equal(s.previous.title, "One");
  assert.equal(s.next.title, "Three");
  assert.deepEqual(s.upcoming.map(u => u.title), ["Three", "Four"]);
  assert.equal(s.time, 42);                 // floored
  assert.equal(s.duration, 200);            // rounded
  assert.equal(s.current.duration, 200);    // from durationInMillis
});

test("snapshot: shuffle and repeat are reported", () => {
  const s = C.snapshot(fakeMusicKit({ shuffleMode: 1, repeatMode: 2 }));
  assert.equal(s.shuffle, true);
  assert.equal(s.repeat, 2);
  assert.equal(C.snapshot(fakeMusicKit({ repeatMode: 7 })).repeat, 0, "unknown repeat mode -> off");
});

test("snapshot: rating/library facts only apply to the song they were fetched for", () => {
  const mk = fakeMusicKit();
  const cid = C.catalogIdOf(mk.queue.currentItem);
  assert.equal(cid, "102");
  const good = C.snapshot(mk, { catalogId: cid, rating: 1, inLibrary: true });
  assert.equal(good.rating, 1);
  const stale = C.snapshot(mk, { catalogId: "999", rating: -1, inLibrary: false });
  assert.equal(stale.rating, 0, "facts for another song must be ignored");
  assert.equal(stale.inLibrary, true, "library items are in the library by definition");
});

test("snapshot: catalog songs not in library report inLibrary from facts", () => {
  const mk = fakeMusicKit();
  const cur = mk.queue.items[1];
  cur.attributes.playParams = { id: "555", kind: "song" };     // plain catalog song
  cur.id = "555";
  assert.equal(C.catalogIdOf(cur), "555");
  assert.equal(C.snapshot(mk).inLibrary, null, "unknown until fetched");
  assert.equal(C.snapshot(mk, { catalogId: "555", inLibrary: false }).inLibrary, false);
});

test("catalogIdOf: uploaded library tracks have no catalog id", () => {
  assert.equal(C.catalogIdOf({ id: "i.x", attributes: { playParams: { id: "i.x", isLibrary: true } } }), "");
  assert.equal(C.catalogIdOf(null), "");
});

test("snapshot: unplayable items are skipped, autoplay is appended display-only", () => {
  const mk = fakeMusicKit();
  mk.queue.items[2].isPlayable = false;
  mk.queue.autoplayItems = [{ id: "ap1", attributes: { name: "Similar", artistName: "X" } }];
  const s = C.snapshot(mk);
  assert.deepEqual(s.upcoming.map(u => u.title), ["Four", "Similar"]);
  assert.equal(s.upcoming[1].autoplay, true);
  assert.equal(s.upcoming[1].index, -1);
});

test("art: only Apple's CDN, with size filled in", () => {
  assert.equal(C.art({ artworkURL: "https://is1-ssl.mzstatic.com/a/{w}x{h}.{f}" }, 64), "https://is1-ssl.mzstatic.com/a/64x64.jpg");
  assert.equal(C.art({ artworkURL: "https://evil.example/{w}.jpg" }, 64), "");
  assert.equal(C.art({ artworkURL: "http://is1-ssl.mzstatic.com/a.jpg" }, 64), "", "plain http refused");
});

test("pickOffsets: unique, in range, capped by library size", () => {
  const offs = C.pickOffsets(11119, 5, 40, seeded(1));
  assert.equal(offs.length, 40);
  assert.equal(new Set(offs).size, 40);
  for (const o of offs) assert.ok(o >= 0 && o <= 11119 - 5);
  assert.equal(C.pickOffsets(12, 5, 40, seeded(2)).length, 3, "small library: ceil(12/5) pages");
  assert.deepEqual(C.pickOffsets(3, 5, 40, seeded(3)), [0], "tiny library: one page at 0");
});

test("pickOffsets: spread over the whole library (not alphabetical clusters)", () => {
  const offs = C.pickOffsets(11119, 5, 40, seeded(7));
  const quarters = [0, 0, 0, 0];
  for (const o of offs) quarters[Math.min(3, Math.floor(o / (11119 / 4)))]++;
  for (const q of quarters) assert.ok(q >= 4, "every quarter of the library is sampled: " + quarters);
});

test("shuffleInPlace: same elements, different order", () => {
  const a = Array.from({ length: 50 }, (_, i) => i);
  const b = C.shuffleInPlace([...a], seeded(9));
  assert.deepEqual([...b].sort((x, y) => x - y), a);
  assert.notDeepEqual(b, a);
});

test("nextRepeatMode: off -> all -> one -> off", () => {
  assert.equal(C.nextRepeatMode(0), 2);
  assert.equal(C.nextRepeatMode(2), 1);
  assert.equal(C.nextRepeatMode(1), 0);
});

test("normalizeSearch: sections, limits, subtitles", () => {
  const song = (id, n) => ({ id, attributes: { name: n, artistName: "In Flames", albumName: "Colony", durationInMillis: 180000,
    artwork: { url: "https://is1-ssl.mzstatic.com/x/{w}x{h}.{f}" } } });
  const catalog = { results: {
    songs: { data: Array.from({ length: 9 }, (_, i) => song(String(100 + i), "S" + i)) },
    albums: { data: [{ id: "1497661496", attributes: { name: "Colony", artistName: "In Flames", releaseDate: "1999-06-01" } }] },
    playlists: { data: [{ id: "pl.abc", attributes: { name: "In Flames Essentials", curatorName: "Apple Music Metal" } }] } } };
  const library = { results: { "library-songs": { data: [{ id: "i.xyz", attributes: { name: "Colony", artistName: "In Flames", albumName: "Colony" } }] } } };
  const r = C.normalizeSearch(catalog, library);
  assert.equal(r.library.length, 1);
  assert.equal(r.library[0].kind, "library-songs");
  assert.equal(r.songs.length, 6, "songs capped at 6");
  assert.equal(r.songs[0].subtitle, "In Flames · Colony");
  assert.equal(r.songs[0].duration, 180);
  assert.equal(r.albums[0].subtitle, "In Flames · 1999");
  assert.equal(r.playlists[0].subtitle, "Apple Music Metal");
  assert.deepEqual(C.normalizeSearch(null, null), { library: [], songs: [], albums: [], playlists: [] });
});

test("queueDescriptor: maps kinds, rejects bad ids", () => {
  assert.deepEqual(C.queueDescriptor("songs", "287374525"), { song: "287374525" });
  assert.deepEqual(C.queueDescriptor("library-albums", "l.AbC"), { album: "l.AbC" });
  assert.deepEqual(C.queueDescriptor("playlists", "pl.e98a8cdc"), { playlist: "pl.e98a8cdc" });
  assert.equal(C.queueDescriptor("artists", "1"), null);
  assert.equal(C.queueDescriptor("songs", "1; drop"), null);
  assert.equal(C.queueDescriptor("songs", "../../x"), null, "slashes are not allowed");
});

test("sanitizeCommand: accepts valid commands, strips extra fields", () => {
  assert.deepEqual(C.sanitizeCommand({ action: "rate", value: 1, evil: "x" }), { action: "rate", value: 1 });
  assert.deepEqual(C.sanitizeCommand({ action: "repeat" }), { action: "repeat" });
  assert.deepEqual(C.sanitizeCommand({ action: "repeat", mode: 2 }), { action: "repeat", mode: 2 });
  assert.deepEqual(C.sanitizeCommand({ action: "search", term: "  in flames ", id: 3 }), { action: "search", term: "in flames", id: 3 });
  assert.deepEqual(C.sanitizeCommand({ action: "playItem", kind: "albums", id: "1497661496", mode: "next" }),
    { action: "playItem", kind: "albums", id: "1497661496", mode: "next" });
  assert.deepEqual(C.sanitizeCommand({ action: "seek", seconds: 12.5 }), { action: "seek", seconds: 12.5 });
});

test("sanitizeCommand: rejects anything malformed", () => {
  const bad = [
    null, "rate", {}, { action: "eval" }, { action: "rate", value: 2 }, { action: "rate", value: "1" },
    { action: "repeat", mode: 3 }, { action: "shuffle", on: "yes" }, { action: "seek", seconds: -1 },
    { action: "seek", seconds: Infinity }, { action: "playIndex", index: 1.5 }, { action: "search", term: "", id: 1 },
    { action: "search", term: "x".repeat(201), id: 1 }, { action: "search", term: "ok" },
    { action: "playItem", kind: "artists", id: "1", mode: "now" }, { action: "playItem", kind: "songs", id: "1", mode: "now!" },
    { action: "playItem", kind: "songs", id: "<script>", mode: "now" }
  ];
  for (const b of bad) assert.equal(C.sanitizeCommand(b), null, JSON.stringify(b));
});
