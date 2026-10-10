.pragma library
// Pure decision logic for Service.qml / BarWidget.qml. No QML types in here,
// so tests/logic.test.mjs runs it under Node.

// Nerd Font icons by code point (explicit and testable).
var G = {
  note: String.fromCodePoint(0xF0386), play: String.fromCodePoint(0xF040A), pause: String.fromCodePoint(0xF03E4),
  prev: String.fromCodePoint(0xF04AE), next: String.fromCodePoint(0xF04AD),
  shuffle: String.fromCodePoint(0xF049D), mix: String.fromCodePoint(0xF1156),
  repeat: String.fromCodePoint(0xF0456), repeatOnce: String.fromCodePoint(0xF0458), repeatOff: String.fromCodePoint(0xF0457),
  heart: String.fromCodePoint(0xF02D1), heartOutline: String.fromCodePoint(0xF02D5),
  thumbDown: String.fromCodePoint(0xF0511), thumbDownOutline: String.fromCodePoint(0xF0512),
  libraryAdd: String.fromCodePoint(0xF0412), libraryCheck: String.fromCodePoint(0xF012C),
  search: String.fromCodePoint(0xF0349), close: String.fromCodePoint(0xF0156),
  eye: String.fromCodePoint(0xF0208), eyeOff: String.fromCodePoint(0xF0209)
}

// MusicKit repeat modes: 0 = off, 1 = one, 2 = all.
function repeatIcon(mode) { return mode === 1 ? G.repeatOnce : mode === 2 ? G.repeat : G.repeatOff }
function repeatLabel(mode) { return mode === 1 ? "Repeat one" : mode === 2 ? "Repeat all" : "Repeat off" }
function nextRepeatMode(mode) { return mode === 0 ? 2 : mode === 2 ? 1 : 0 }   // off -> all -> one -> off

// Like/dislike buttons toggle: pressing the active one clears the rating.
function nextRating(current, pressed) { return current === pressed ? 0 : pressed }

// Media keys: which player gets play/pause/next/previous?
//   - Apple Music is playing                      -> Apple Music
//   - something else is playing                   -> the system (omarchy media)
//   - nothing plays, Apple Music has a track      -> Apple Music (resume it)
//   - otherwise                                   -> the system
function mediaKeyTarget(amPlaying, amHasTrack, othersPlaying) {
  if (amPlaying) return "apple"
  if (othersPlaying) return "system"
  return amHasTrack ? "apple" : "system"
}

// Launcher `--probe` prints "PID WINDOW" where WINDOW is visible|hidden|none.
function parseProbe(text) {
  var parts = String(text || "").trim().split(/\s+/)
  var pid = parseInt(parts[0])
  var win = parts[1]
  if (isNaN(pid) || pid <= 0) return { pid: 0, window: "none" }
  return { pid: pid, window: (win === "visible" || win === "hidden") ? win : "none" }
}

// Search results file -> sections for the UI, only if it answers `id`.
function searchSections(results, id) {
  if (!results || results.id !== id || !results.sections) return null
  var s = results.sections
  var out = []
  var add = function(title, list) { if (list && list.length) out.push({ title: title, items: list }) }
  add("In your library", s.library)
  add("Songs", s.songs)
  add("Albums", s.albums)
  add("Playlists", s.playlists)
  return out
}

// Flat list for keyboard navigation across sections.
function flatten(sections) {
  var out = []
  for (var i = 0; i < (sections || []).length; i++)
    for (var j = 0; j < sections[i].items.length; j++) out.push(sections[i].items[j])
  return out
}

function clampIndex(i, n) { return n <= 0 ? -1 : Math.max(0, Math.min(n - 1, i)) }

// Only Apple's image CDN; everything else is dropped (untrusted page data).
function safeArt(url) {
  var s = String(url || "")
  return /^https:\/\/[a-z0-9-]+\.mzstatic\.com\//.test(s) ? s : ""
}

// Now-playing cover. Chromium now hands MPRIS a downloaded copy of the art
// (file:///tmp/.org.chromium.Chromium.XXXXXX), not the page URL, so prefer the
// bridge's Apple CDN art (upscaled), then Chromium's own temp copy.
function nowArt(bridgeArt, mprisArt, size) {
  var a = safeArt(bridgeArt)
  if (a) return a.replace(/\/\d+x\d+bb\./, "/" + (size || 600) + "x" + (size || 600) + "bb.")
  var m = String(mprisArt || "")
  if (safeArt(m)) return m
  return /^file:\/\/\/tmp\/\.org\.chromium\.Chromium\.[A-Za-z0-9_]+$/.test(m) ? m : ""
}

function fmtTime(sec) {
  sec = Math.max(0, Math.floor(sec || 0))
  var m = Math.floor(sec / 60), s = sec % 60
  return m + ":" + (s < 10 ? "0" : "") + s
}
