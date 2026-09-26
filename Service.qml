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
  readonly property real length: player && player.lengthSupported ? player.length : 0
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
    if (!player || !player.canSeek) return false
    player.position = Math.max(0, Math.min(root.length, seconds))
    root.position = player.position
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
      previous: root.previousTrack ? { title: root.previousTrack.title, artist: root.previousTrack.artist } : null,
      next: root.nextTrack ? { title: root.nextTrack.title, artist: root.nextTrack.artist } : null
    })
  }

  Process { id: cmdProc }

  FileView {
    id: queueFile
    path: root.running ? root.stateDir + "/queue-" + root.appPid + ".json" : ""
    printErrors: false
    onLoaded: {
      try { root.queue = JSON.parse(text()) } catch (e) { root.queue = null }
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
      root.position = root.player.positionSupported ? root.player.position : 0
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
    function ping(): string { return "ok" }
  }
}
