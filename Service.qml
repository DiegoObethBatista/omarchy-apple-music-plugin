import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Headless service: tracks the Apple Music web app's MPRIS player and exposes
// launch + playback controls to the bar widget and to IPC (for keybindings).
//
//   omarchy-shell apple-music launch | playPause | next | previous | status | quit
Item {
  id: root

  property var shell: null

  readonly property string launcher: Qt.resolvedUrl("bin/apple-music").toString().replace(/^file:\/\//, "")

  // Main PID of the dedicated Chromium instance (0 = not running).
  property int appPid: 0
  readonly property bool running: appPid > 0

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

  readonly property bool playing: player ? !!player.isPlaying : false
  readonly property bool hasTrack: player !== null && !!(player.trackTitle || player.trackArtist)
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player && player.trackAlbum ? player.trackAlbum : ""
  readonly property string artUrl: player && player.trackArtUrl ? player.trackArtUrl : ""
  // Chromium's MPRIS reports mpris:length = INT64_MAX for Apple Music (its
  // MSE stream has an infinite media duration), so the MPRIS length is garbage.
  // Prefer MusicKit's real duration from the queue when it's for this track;
  // fall back to MPRIS only if it's a sane value (< 24 h).
  readonly property real mprisLength: player && player.lengthSupported ? player.length : 0
  // True when the bridge's snapshot describes the track MPRIS is showing.
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

  // Shuffle lives in MusicKit (Chromium's MPRIS doesn't implement it).
  // Optimistic local value so the button reacts instantly; the bridge
  // snapshot overrides it once MusicKit confirms.
  property var shufflePending: null
  readonly property bool shuffle: shufflePending !== null ? shufflePending : !!(queue && queue.shuffle)
  readonly property bool canShuffle: running && queue !== null

  function setShuffle(on) {
    if (!root.canShuffle) return false
    root.shufflePending = on
    shuffleTimeout.restart()
    cmdProc.command = [root.launcher, "--shuffle", on ? "on" : "off"]
    cmdProc.running = true
    return true
  }
  function toggleShuffle() { return setShuffle(!root.shuffle) }
  readonly property real length: queueLength > 0 ? queueLength
                                 : (mprisLength > 0 && mprisLength < 86400 ? mprisLength : 0)
  property real position: 0

  // Queue published by the bundled Chromium extension via bin/apple-music-bridge.
  // Shape: { position, length, previous, current, next, upcoming: [...] }
  // where each item is { index, title, artist, album, art, duration }.
  readonly property string stateDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-apple-music"
  property var queue: null
  readonly property var previousTrack: queue ? queue.previous : null
  readonly property var nextTrack: queue ? queue.next : null
  readonly property var upcoming: queue && queue.upcoming ? queue.upcoming : []
  readonly property bool hasQueue: queue !== null && (previousTrack !== null || nextTrack !== null)

  // Jump straight to a queue entry (e.g. clicking "Up next" in the popup).
  function playQueueIndex(index) {
    if (!root.running || !Number.isInteger(index)) return false
    cmdProc.command = [root.launcher, "--play-index", String(index)]
    cmdProc.running = true
    return true
  }

  function launch() {
    Quickshell.execDetached([root.launcher])
    pidTimer.interval = 1000
    pidProc.running = true
  }

  function quit() {
    Quickshell.execDetached([root.launcher, "--quit"])
    root.appPid = 0
  }

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

  function seekTo(seconds) {
    var target = Math.max(0, root.length > 0 ? Math.min(root.length - 1, seconds) : seconds)
    // MPRIS SetPosition uses Chromium's continuous stream clock (spans the whole
    // queue), so seek through MusicKit whenever the bridge is available.
    if (root.queueInSync) {
      cmdProc.command = [root.launcher, "--seek", String(Math.floor(target))]
      cmdProc.running = true
    } else if (player && player.canSeek) {
      player.position = target
    } else {
      return false
    }
    root.position = target
    root.queueLoadedAt = Date.now()
    if (root.queue) root.queue.time = target
    return true
  }

  function raise() {
    launch()   // launcher focuses the existing window when it is running
  }

  function statusJson() {
    return JSON.stringify({
      running: root.running,
      pid: root.appPid,
      hasPlayer: root.player !== null,
      playing: root.playing,
      title: root.title,
      artist: root.artist,
      album: root.album,
      position: Math.round(root.position),
      length: Math.round(root.length),
      shuffle: root.shuffle,
      previous: root.previousTrack ? { title: root.previousTrack.title, artist: root.previousTrack.artist } : null,
      next: root.nextTrack ? { title: root.nextTrack.title, artist: root.nextTrack.artist } : null
    })
  }

  Process { id: cmdProc }

  // Drop the optimistic value if MusicKit never confirms (e.g. old extension).
  Timer { id: shuffleTimeout; interval: 3000; onTriggered: root.shufflePending = null }

  FileView {
    id: queueFile
    path: root.running ? root.stateDir + "/queue-" + root.appPid + ".json" : ""
    printErrors: false
    onLoaded: {
      var q = null
      try { q = JSON.parse(text()) } catch (e) { q = null }
      // Only reset the clock anchor when the reported time actually changed.
      if (!q || !root.queue || q.time !== root.queue.time || q.playing !== root.queue.playing)
        root.queueLoadedAt = Date.now()
      root.queue = q
      if (q && root.shufflePending !== null && !!q.shuffle === root.shufflePending) {
        root.shufflePending = null
        shuffleTimeout.stop()
      }
    }
    onLoadFailed: root.queue = null
  }

  // The bridge replaces the file atomically; polling reload is simpler and
  // more robust than inotify across renames. Tiny file, 1 s cadence.
  Timer {
    interval: 1000
    repeat: true
    running: root.running
    triggeredOnStart: true
    onTriggered: queueFile.reload()
  }

  onRunningChanged: if (!running) root.queue = null

  // PID discovery: fast while starting up, relaxed once found.
  Process {
    id: pidProc
    command: [root.launcher, "--pid"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pid = parseInt(String(text || "").trim())
        root.appPid = isNaN(pid) ? 0 : pid
        pidTimer.interval = root.appPid > 0 ? 5000 : 4000
      }
    }
  }

  Timer {
    id: pidTimer
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: pidProc.running = true
  }

  // MPRIS position is not pushed continuously; poll it while playing.
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
    function queue(): string { return JSON.stringify(root.queue) }
    function playIndex(index: int): string { return root.playQueueIndex(index) ? "ok" : "unhandled" }
    function shuffle(): string { return root.toggleShuffle() ? (root.shuffle ? "on" : "off") : "unhandled" }
    function setShuffle(on: bool): string { return root.setShuffle(on) ? "ok" : "unhandled" }
    function seek(seconds: real): string { return root.seekTo(seconds) ? "ok" : "unhandled" }
    function ping(): string { return "ok" }
  }
}
