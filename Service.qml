import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Logic.js" as Logic

// Headless service: tracks the Apple Music web app's MPRIS player and the
// MusicKit state published by the bundled extension, and exposes launch +
// playback controls to the bar widget and to IPC (for keybindings).
//
//   omarchy-shell apple-music <function>   (see IpcHandler at the bottom)
Item {
  id: root

  property var shell: null

  readonly property string launcher: Qt.resolvedUrl("bin/apple-music").toString().replace(/^file:\/\//, "")

  // ---- process + window ----------------------------------------------------
  // Main PID of the dedicated Chromium instance (0 = not running).
  property int appPid: 0
  // "visible" | "hidden" (parked on the special workspace) | "none"
  property string windowState: "none"
  readonly property bool running: appPid > 0
  readonly property bool windowHidden: windowState === "hidden"

  // ---- MPRIS (transport + metadata) -----------------------------------------
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    if (!root.running) return null
    var suffix = ".instance" + root.appPid
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var name = String(p && p.dbusName || "")
      if (name.indexOf("org.mpris.MediaPlayer2.chromium") === 0 && name.endsWith(suffix)) return p
    }
    return null
  }
  // Any OTHER player currently playing (Brave, Spotify, mpv, ...)?
  readonly property bool othersPlaying: {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && p !== root.player && p.isPlaying) return true
    }
    return false
  }

  readonly property bool playing: player ? !!player.isPlaying : false
  readonly property bool hasTrack: player !== null && !!(player.trackTitle || player.trackArtist)
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player && player.trackAlbum ? player.trackAlbum : ""
  readonly property string artUrl: player && player.trackArtUrl ? player.trackArtUrl : ""

  // ---- MusicKit state from the extension --------------------------------------
  // Chromium's MPRIS reports mpris:length = INT64_MAX and a clock that spans
  // the whole queue, so time/length come from MusicKit when available.
  readonly property string stateDir: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-apple-music"   // owner-only; no /tmp fallback
  property var queue: null
  readonly property var previousTrack: queue ? queue.previous : null
  readonly property var nextTrack: queue ? queue.next : null
  readonly property var upcoming: queue && queue.upcoming ? queue.upcoming : []
  readonly property bool hasQueue: queue !== null && (previousTrack !== null || nextTrack !== null)
  readonly property bool bridged: running && queue !== null

  readonly property real mprisLength: player && player.lengthSupported ? player.length : 0
  readonly property bool queueInSync: {
    var c = queue ? queue.current : null
    return c !== null && c !== undefined && (!root.title || !c.title || c.title === root.title)
  }
  readonly property real queueLength: {
    if (!queueInSync) return 0
    if (queue.duration > 0) return queue.duration
    return queue.current.duration > 0 ? queue.current.duration : 0
  }
  property real queueLoadedAt: 0   // ms, when queue.time was read
  readonly property real length: queueLength > 0 ? queueLength
                                 : (mprisLength > 0 && mprisLength < 86400 ? mprisLength : 0)
  property real position: 0

  // Optimistic values so buttons react instantly; the next snapshot from
  // MusicKit confirms them (or the timeout drops them).
  property var pending: ({})
  function pendingOr(key, confirmed) { return root.pending[key] !== undefined ? root.pending[key] : confirmed }
  function setPending(key, value) {
    var p = Object.assign({}, root.pending); p[key] = value; root.pending = p
    pendingTimeout.restart()
  }
  function confirmPending(q) {
    if (!q) return
    var p = Object.assign({}, root.pending), changed = false
    var confirmed = { shuffle: !!q.shuffle, repeat: q.repeat, rating: q.rating, inLibrary: q.inLibrary }
    for (var k in p) if (p[k] === confirmed[k]) { delete p[k]; changed = true }
    if (changed) root.pending = p
  }

  readonly property bool shuffle: pendingOr("shuffle", !!(queue && queue.shuffle))
  readonly property int repeatMode: pendingOr("repeat", queue && typeof queue.repeat === "number" ? queue.repeat : 0)
  readonly property int rating: pendingOr("rating", queue && typeof queue.rating === "number" ? queue.rating : 0)
  // true / false / null (unknown, e.g. uploaded tracks)
  readonly property var inLibrary: pendingOr("inLibrary", queue && queue.inLibrary !== undefined ? queue.inLibrary : null)
  readonly property bool canRate: bridged && queueInSync && !!(queue && queue.catalogId)

  // ---- commands ------------------------------------------------------------------
  // Commands queue up so rapid clicks are never dropped while a previous
  // launcher call is still running. `input` (optional) is sent on stdin:
  // personal text like search terms must never be in argv, which any local
  // user can read from /proc.
  property var cmdQueue: []
  function run(args, input) {
    root.cmdQueue = root.cmdQueue.concat([{ args: args, input: input || "" }])
    if (!cmdProc.running) runNext()
  }
  function runNext() {
    if (root.cmdQueue.length === 0) return
    var next = root.cmdQueue[0]
    root.cmdQueue = root.cmdQueue.slice(1)
    cmdProc.input = next.input
    cmdProc.command = [root.launcher].concat(next.args)
    cmdProc.running = true
  }

  function setShuffle(on) {
    if (!root.bridged) return false
    setPending("shuffle", on)
    run(["--shuffle", on ? "on" : "off"])
    return true
  }
  function toggleShuffle() { return setShuffle(!root.shuffle) }

  function setRepeat(mode) {
    if (!root.bridged || [0, 1, 2].indexOf(mode) === -1) return false
    setPending("repeat", mode)
    run(["--repeat", ["off", "one", "all"][mode]])
    return true
  }
  function cycleRepeat() { return setRepeat(Logic.nextRepeatMode(root.repeatMode)) }

  // value: 1 like, -1 dislike, 0 clear. Buttons toggle (Logic.nextRating).
  function rate(value) {
    if (!root.canRate || [-1, 0, 1].indexOf(value) === -1) return false
    setPending("rating", value)
    run(["--rate", value === 1 ? "like" : value === -1 ? "dislike" : "clear"])
    return true
  }
  function toggleLike() { return rate(Logic.nextRating(root.rating, 1)) }
  function toggleDislike() { return rate(Logic.nextRating(root.rating, -1)) }

  function addToLibrary() {
    if (!root.canRate || root.inLibrary === true) return false
    setPending("inLibrary", true)
    run(["--add-to-library"])
    return true
  }

  function shuffleLibrary() {
    if (!root.running) { launch(); return false }
    run(["--shuffle-library"])
    return true
  }

  function playQueueIndex(index) {
    if (!root.running || !Number.isInteger(index)) return false
    run(["--play-index", String(index)])
    return true
  }

  function seekTo(seconds) {
    var target = Math.max(0, root.length > 0 ? Math.min(root.length - 1, seconds) : seconds)
    if (root.queueInSync) run(["--seek", String(Math.floor(target))])
    else if (player && player.canSeek) player.position = target
    else return false
    root.position = target
    root.queueLoadedAt = Date.now()
    if (root.queue) root.queue.time = target
    return true
  }

  // ---- search ----------------------------------------------------------------------
  // Each query gets an id; only results answering the latest id are shown,
  // so slow answers to old keystrokes can't overwrite newer ones.
  property int searchId: 0
  property string searchTerm: ""
  property bool searching: false
  property var searchResults: []       // [{ title, items: [...] }]
  property bool searchFailed: false

  function search(term) {
    term = String(term || "").trim()
    root.searchTerm = term
    root.searchId += 1
    if (term.length < 2 || !root.bridged) {
      root.searching = false; root.searchResults = []; root.searchFailed = false
      return root.bridged
    }
    root.searching = true
    run(["--search", String(root.searchId)], term.replace(/[\r\n]+/g, " "))   // term on stdin, not argv
    return true
  }
  function clearSearch() { search("") }

  // kind: songs|albums|playlists|library-*; mode: now|next|later
  function playItem(kind, id, mode) {
    if (!root.bridged) return false
    run(["--play-item", kind, id, mode || "now"])
    return true
  }

  // ---- window + app ------------------------------------------------------------------
  function launch() {
    Quickshell.execDetached([root.launcher])
    probeTimer.interval = 1000
    probeProc.running = true
  }
  function quit() {
    Quickshell.execDetached([root.launcher, "--quit"])
    root.appPid = 0
    root.windowState = "none"
  }
  function raise() { launch() }       // the launcher un-hides and focuses a running window
  function hideWindow() {
    if (!root.running) return false
    Quickshell.execDetached([root.launcher, "--hide"])
    root.windowState = "hidden"
    return true
  }
  function showWindow() {
    if (!root.running) { launch(); return false }
    Quickshell.execDetached([root.launcher, "--show"])
    root.windowState = "visible"
    return true
  }
  function toggleWindow() { return root.windowHidden ? showWindow() : hideWindow() }

  // ---- transport ---------------------------------------------------------------------
  function osd(label, icon) {
    if (!shell) return
    var msg = root.title ? (root.title + (root.artist ? " — " + root.artist : "")) : label
    shell.summon("omarchy.osd", JSON.stringify({ icon: icon, message: msg }))
  }

  function playPause() {
    if (!player) { launch(); return false }
    if (player.canTogglePlaying) player.togglePlaying()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (player.canPlay) player.play()
    else return false
    return true
  }
  function next() {
    if (player && player.canGoNext) { player.next(); return true }
    return false
  }
  function previous() {
    if (player && player.canGoPrevious) { player.previous(); return true }
    return false
  }

  // Media keys: Apple Music first when it's the one playing (or the only
  // thing that could play); otherwise hand the key to Omarchy's media service.
  function mediaKey(action) {
    var target = Logic.mediaKeyTarget(root.playing, root.hasTrack, root.othersPlaying)
    if (target === "apple") {
      var ok = action === "next" ? next() : action === "previous" ? previous() : playPause()
      if (ok) {
        if (action === "next") osd("Next", "media-next")
        else if (action === "previous") osd("Previous", "media-previous")
        else osd(root.playing ? "Pause" : "Play", root.playing ? "media-pause" : "media-play")
        return "apple"
      }
    }
    Quickshell.execDetached(["omarchy-shell", "media", action])
    return "system"
  }

  function statusJson() {
    return JSON.stringify({
      running: root.running,
      pid: root.appPid,
      window: root.windowState,
      hasPlayer: root.player !== null,
      playing: root.playing,
      title: root.title,
      artist: root.artist,
      album: root.album,
      position: Math.round(root.position),
      length: Math.round(root.length),
      shuffle: root.shuffle,
      repeat: root.repeatMode,
      rating: root.rating,
      inLibrary: root.inLibrary,
      previous: root.previousTrack ? { title: root.previousTrack.title, artist: root.previousTrack.artist } : null,
      next: root.nextTrack ? { title: root.nextTrack.title, artist: root.nextTrack.artist } : null
    })
  }

  Process {
    id: cmdProc
    property string input: ""
    stdinEnabled: true
    onStarted: { write(input + "\n"); input = "" }
    onExited: root.runNext()
  }

  Timer { id: pendingTimeout; interval: 4000; onTriggered: root.pending = ({}) }

  FileView {
    id: queueFile
    path: root.running ? root.stateDir + "/queue-" + root.appPid + ".json" : ""
    printErrors: false
    onLoaded: {
      var q = null
      try { q = JSON.parse(text()) } catch (e) { q = null }
      if (!q || !root.queue || q.time !== root.queue.time || q.playing !== root.queue.playing)
        root.queueLoadedAt = Date.now()
      root.queue = q
      root.confirmPending(q)
    }
    onLoadFailed: root.queue = null
  }

  FileView {
    id: searchFile
    path: root.running ? root.stateDir + "/search-" + root.appPid + ".json" : ""
    printErrors: false
    onLoaded: {
      var r = null
      try { r = JSON.parse(text()) } catch (e) { r = null }
      var sections = Logic.searchSections(r, root.searchId)
      if (sections === null) return            // stale answer or no answer yet
      root.searchResults = sections
      root.searchFailed = !r.ok
      root.searching = false
    }
  }

  // The bridge replaces the files atomically; a 1 s poll is simpler and
  // sturdier than inotify across renames. Search polls fast while waiting.
  Timer {
    interval: 1000
    repeat: true
    running: root.running
    triggeredOnStart: true
    onTriggered: queueFile.reload()
  }
  Timer {
    interval: 250
    repeat: true
    running: root.running && root.searching
    onTriggered: searchFile.reload()
  }

  onRunningChanged: if (!running) { root.queue = null; root.searchResults = []; root.searching = false }

  // PID + window discovery in one launcher call: fast while starting up.
  Process {
    id: probeProc
    command: [root.launcher, "--probe"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = Logic.parseProbe(text)
        root.appPid = p.pid
        root.windowState = p.window
        probeTimer.interval = root.appPid > 0 ? 3000 : 4000
      }
    }
  }
  Timer {
    id: probeTimer
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: probeProc.running = true
  }

  // Position: MusicKit time + elapsed since that snapshot, clamped to the song.
  Timer {
    interval: 1000
    repeat: true
    running: root.player !== null
    triggeredOnStart: true
    onTriggered: {
      if (!root.player) return
      root.player.positionChanged()
      var pos
      if (root.queueInSync && typeof root.queue.time === "number") {
        pos = root.queue.time
        if (root.queue.playing) pos += (Date.now() - root.queueLoadedAt) / 1000
      } else if (root.queue) {
        pos = 0   // bridge active but mid track-change: MPRIS clock is wrong here
      } else {
        pos = root.player.positionSupported ? root.player.position : 0
      }
      root.position = root.length > 0 ? Math.min(Math.max(0, pos), root.length) : Math.max(0, pos)
    }
  }

  IpcHandler {
    target: "apple-music"

    function launch(): string { root.launch(); return "ok" }
    function quit(): string { root.quit(); return "ok" }
    function status(): string { return root.statusJson() }
    function playPause(): string {
      var ok = root.playPause()
      if (ok) root.osd(root.playing ? "Pause" : "Play", root.playing ? "media-pause" : "media-play")
      return ok ? "ok" : "launching"
    }
    function next(): string {
      var ok = root.next()
      if (ok) root.osd("Next", "media-next")
      return ok ? "ok" : "unhandled"
    }
    function previous(): string {
      var ok = root.previous()
      if (ok) root.osd("Previous", "media-previous")
      return ok ? "ok" : "unhandled"
    }
    // Media keys: routes to Apple Music or to `omarchy-shell media`.
    function mediaKey(action: string): string {
      if (["playPause", "next", "previous"].indexOf(action) === -1) return "unknown action"
      return root.mediaKey(action)
    }
    function queue(): string { return JSON.stringify(root.queue) }
    function playIndex(index: int): string { return root.playQueueIndex(index) ? "ok" : "unhandled" }
    function shuffle(): string { return root.toggleShuffle() ? (root.shuffle ? "on" : "off") : "unhandled" }
    function setShuffle(on: bool): string { return root.setShuffle(on) ? "ok" : "unhandled" }
    function shuffleLibrary(): string { return root.shuffleLibrary() ? "ok" : "unhandled" }
    function repeat(): string { return root.cycleRepeat() ? Logic.repeatLabel(root.repeatMode) : "unhandled" }
    function setRepeat(mode: int): string { return root.setRepeat(mode) ? "ok" : "unhandled" }
    function like(): string { return root.toggleLike() ? (root.rating === 1 ? "liked" : "cleared") : "unhandled" }
    function dislike(): string { return root.toggleDislike() ? (root.rating === -1 ? "disliked" : "cleared") : "unhandled" }
    function addToLibrary(): string { return root.addToLibrary() ? "ok" : (root.inLibrary === true ? "already in library" : "unhandled") }
    function seek(seconds: real): string { return root.seekTo(seconds) ? "ok" : "unhandled" }
    function search(term: string): string { return root.search(term) ? "ok" : "unhandled" }
    function searchResults(): string { return JSON.stringify({ term: root.searchTerm, searching: root.searching, failed: root.searchFailed, sections: root.searchResults }) }
    function playItem(kind: string, id: string, mode: string): string { return root.playItem(kind, id, mode) ? "ok" : "unhandled" }
    function hide(): string { return root.hideWindow() ? "ok" : "not running" }
    function show(): string { root.showWindow(); return "ok" }
    function toggleWindow(): string { return root.toggleWindow() ? root.windowState : "not running" }
    function ping(): string { return "ok" }
  }
}
