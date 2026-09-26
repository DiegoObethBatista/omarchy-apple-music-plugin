// Loads the plugin's pure JS files outside the browser / Quickshell.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// extension/core.js is CommonJS-compatible.
export const core = createRequire(import.meta.url)(path.join(ROOT, "extension/core.js"));

// Logic.js is a QML ".pragma library" script: strip the pragma and evaluate
// it in this realm (so arrays/objects compare normally with deepStrictEqual).
export function loadLogic() {
  const src = readFileSync(path.join(ROOT, "Logic.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
  const names = ["G", "repeatIcon", "repeatLabel", "nextRepeatMode", "nextRating", "mediaKeyTarget",
                 "parseProbe", "searchSections", "flatten", "clampIndex", "safeArt", "fmtTime"];
  return new Function(src + "\nreturn { " + names.join(", ") + " };")();
}

// A deterministic RNG for shuffle tests.
export function seeded(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2 ** 32; };
}

// Minimal MusicKit stand-in with the fields snapshot() reads.
export function fakeMusicKit(overrides = {}) {
  const song = (id, name, extra = {}) => ({
    id, attributes: { name, artistName: "Artist " + id, albumName: "Album",
      artwork: { url: "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.{f}" },
      playParams: { id, catalogId: "10" + id.replace(/\D/g, ""), isLibrary: true, kind: "song" },
      durationInMillis: 200000 }, ...extra });
  const items = [song("i.a1", "One"), song("i.a2", "Two"), song("i.a3", "Three"), song("i.a4", "Four")];
  return {
    shuffleMode: 0, repeatMode: 0, autoplayEnabled: false, isPlaying: true,
    currentPlaybackTime: 42.7, currentPlaybackDuration: 200.2,
    queue: {
      position: 1, length: items.length, items,
      get currentItem() { return items[this.position]; },
      previousPlayableItemIndex: 0, nextPlayableItemIndex: 2,
      autoplayItems: [], indexForItem: () => -1
    },
    ...overrides
  };
}
