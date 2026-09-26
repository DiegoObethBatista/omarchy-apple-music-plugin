// Unit tests for Logic.js (decisions made by Service.qml / BarWidget.qml).
import test from "node:test";
import assert from "node:assert/strict";
import { loadLogic } from "./helpers.mjs";

const L = loadLogic();

test("repeat: cycle order and labels", () => {
  assert.equal(L.nextRepeatMode(0), 2);
  assert.equal(L.nextRepeatMode(2), 1);
  assert.equal(L.nextRepeatMode(1), 0);
  assert.equal(L.repeatLabel(0), "Repeat off");
  assert.equal(L.repeatLabel(1), "Repeat one");
  assert.equal(L.repeatLabel(2), "Repeat all");
  assert.equal(L.repeatIcon(1), L.G.repeatOnce);
  assert.equal(L.repeatIcon(2), L.G.repeat);
  assert.equal(L.repeatIcon(0), L.G.repeatOff);
});

test("rating buttons toggle", () => {
  assert.equal(L.nextRating(0, 1), 1, "like");
  assert.equal(L.nextRating(1, 1), 0, "like again clears");
  assert.equal(L.nextRating(1, -1), -1, "dislike replaces like");
  assert.equal(L.nextRating(-1, -1), 0);
});

test("media keys: who gets the key", () => {
  // (appleMusicPlaying, appleMusicHasTrack, somethingElsePlaying)
  assert.equal(L.mediaKeyTarget(true, true, false), "apple");
  assert.equal(L.mediaKeyTarget(true, true, true), "apple", "Apple Music playing wins");
  assert.equal(L.mediaKeyTarget(false, true, true), "system", "don't steal the key from a playing video");
  assert.equal(L.mediaKeyTarget(false, true, false), "apple", "resume paused Apple Music");
  assert.equal(L.mediaKeyTarget(false, false, false), "system");
});

test("parseProbe", () => {
  assert.deepEqual(L.parseProbe("350059 visible\n"), { pid: 350059, window: "visible" });
  assert.deepEqual(L.parseProbe("350059 hidden"), { pid: 350059, window: "hidden" });
  assert.deepEqual(L.parseProbe("350059 weird"), { pid: 350059, window: "none" });
  assert.deepEqual(L.parseProbe("0 none"), { pid: 0, window: "none" });
  assert.deepEqual(L.parseProbe(""), { pid: 0, window: "none" });
  assert.deepEqual(L.parseProbe("garbage"), { pid: 0, window: "none" });
});

test("searchSections: ignores stale answers, keeps order, drops empty", () => {
  const results = { id: 4, ok: true, sections: { library: [{ id: "a" }], songs: [], albums: [{ id: "b" }], playlists: [{ id: "c" }] } };
  assert.equal(L.searchSections(results, 5), null, "answer to an older query");
  assert.equal(L.searchSections(null, 1), null);
  const s = L.searchSections(results, 4);
  assert.deepEqual(s.map(x => x.title), ["In your library", "Albums", "Playlists"]);
  assert.deepEqual(L.flatten(s).map(x => x.id), ["a", "b", "c"]);
});

test("clampIndex", () => {
  assert.equal(L.clampIndex(-1, 0), -1);
  assert.equal(L.clampIndex(5, 3), 2);
  assert.equal(L.clampIndex(-3, 3), 0);
});

test("safeArt: Apple CDN only", () => {
  assert.equal(L.safeArt("https://is1-ssl.mzstatic.com/x.jpg"), "https://is1-ssl.mzstatic.com/x.jpg");
  assert.equal(L.safeArt("https://mzstatic.com.evil.io/x.jpg"), "");
  assert.equal(L.safeArt("file:///etc/passwd"), "");
  assert.equal(L.safeArt(undefined), "");
});

test("fmtTime", () => {
  assert.equal(L.fmtTime(0), "0:00");
  assert.equal(L.fmtTime(65.9), "1:05");
  assert.equal(L.fmtTime(-3), "0:00");
  assert.equal(L.fmtTime(474), "7:54");
});

test("icons: every glyph is a single Nerd Font code point", () => {
  for (const [name, g] of Object.entries(L.G)) {
    assert.equal([...g].length, 1, name);
    assert.ok(g.codePointAt(0) >= 0xF0000, name + " is in the Material Design range");
  }
});
