# Apple Music plugin — a guided walkthrough

A lesson-by-lesson tour of how this plugin is built. Each lesson has:
**what the file does → the key lines → why it's done that way → try it yourself.**

Do the "Try it" boxes — running things is how this sticks.
All paths are relative to `~/.config/omarchy/plugins/diegohades.apple-music/`.

---

## 0. The big picture

The plugin has **two ways of talking to Apple Music**, because one wasn't enough:

```
                    ┌──────────────── Omarchy shell (Quickshell / QML) ───────────────┐
  you click ──────► │  BarWidget.qml  ──reads──►  Service.qml                           │
                    │   (what you see)            (the brain, no UI)                    │
                    └───────────────┬───────────────────────────┬──────────────────────┘
                                    │ PATH A: MPRIS (D-Bus)     │ PATH B: the bridge
                                    │ play/pause/next/prev,     │ queue, per-track time,
                                    │ title/artist/artwork      │ seek, shuffle, library mix
                                    ▼                           ▼
                                               bin/apple-music-bridge (Python)
                                                  ▲ native messaging (stdin/stdout)
                                                  ▼
                              extension/background.js → relay.js → page.js
                                                                     │
                    ┌─────────── Chromium, own profile ──────────────▼──────┐
                    │  music.apple.com   ── MusicKit JS (Apple's player) ────│
                    └───────────────────────────────────────────────────────┘
```

- **Path A — MPRIS** is the Linux standard every media player speaks over D-Bus.
  Free, simple, and what we built first.
- **Path B — the bridge** exists because MPRIS can't tell you the queue, and
  Chromium reports broken time values for Apple Music (lesson 5). So we reach
  *into the page* and ask Apple's own player, MusicKit.

File map (≈1,300 lines total):

| File | Language | Role |
|---|---|---|
| `manifest.json` | JSON | Tells Omarchy what the plugin is and where its entry points are |
| `bin/apple-music` | Bash | Launcher + small command-line tool |
| `Service.qml` | QML/JS | Headless brain: state, controls, IPC |
| `BarWidget.qml`, `QueueRow.qml` | QML | The bar icon and popup |
| `extension/*` | JS | Chromium extension that reads MusicKit |
| `bin/apple-music-bridge` | Python | Pipe between the extension and the shell |

---

## 1. `manifest.json` — how Omarchy finds the plugin

Omarchy scans `~/.config/omarchy/plugins/*/manifest.json`. The important keys:

```json
"id": "diegohades.apple-music",          // unique; <author>.<name>
"kinds": ["service", "bar-widget"],       // what this plugin provides
"entryPoints": {
  "service":   "Service.qml",             // loaded once, lives while the shell runs
  "barWidget": "BarWidget.qml"            // one instance per bar placement
},
"barWidget": { "defaults": {...}, "schema": [...] }   // user settings (showTitle, maxLabelWidth)
```

**Why two kinds?** A *service* has no UI and exists exactly once — the right
place for state and for keyboard-shortcut commands. A *bar widget* is purely
visual and can be placed (or not) on the bar. Separating them means
`omarchy-shell apple-music next` works even if you remove the icon from the bar.

> **Try it**
> ```bash
> omarchy plugin validate .
> jq '.. | objects | select(.id? == "diegohades.apple-music")' ~/.config/omarchy/shell.json
> ```
> The second command shows where the widget is placed on your bar.

---

## 2. `bin/apple-music` — the launcher

Everything starts here. The key idea is one flag:

```bash
DATA_DIR="$HOME/.local/share/omarchy-apple-music"
...
exec setsid uwsm-app -- chromium \
  --user-data-dir="$DATA_DIR" \        # ← the key idea
  --app="$URL" \                       # window without tabs/address bar
  --load-extension="$PLUGIN_DIR/extension" \
  --autoplay-policy=no-user-gesture-required \
  ...
```

**Why its own `--user-data-dir`?** Chromium runs one main process per
profile. A separate profile gives Apple Music **its own PID**, and Chromium names its
MPRIS player `org.mpris.MediaPlayer2.chromium.instance<PID>`. So the PID is
how we tell "Apple Music" apart from your Brave/YouTube tabs. No guessing
from window titles.

Other things worth noticing:
- `uwsm-app --` — Omarchy's way of launching apps so systemd tracks them properly.
- The `case "$1"` block (lines ~15–55) turns the launcher into a mini CLI:
  `--pid`, `--quit`, `--queue`, `--play-index N`, `--seek S`, `--shuffle`, `--shuffle-library`.
  The shell calls these instead of doing file/FIFO work in QML (easier to test from a terminal).
- Lines ~60–70 write the **native-messaging host manifest** into the profile (lesson 7).
- If it's already running, it focuses the window instead of launching twice.

> **Try it**
> ```bash
> bin/apple-music --pid
> busctl --user list | grep mpris
> ```
> You'll see the same PID in both. That's the whole trick of path A.

---

## 3. `Service.qml` — the brain

QML is **declarative and reactive**. You don't write "when X changes, update Y";
you write `Y: <expression using X>` and Qt re-evaluates it automatically.
That's the most important concept in both QML files.

### 3a. Finding the player (lines 17–31)

```qml
property int appPid: 0
readonly property bool running: appPid > 0

readonly property var player: {
  if (!root.running) return null
  var suffix = ".instance" + root.appPid
  for (...) if (name.startsWith("org.mpris.MediaPlayer2.chromium") && name.endsWith(suffix)) return p
  return null
}
```

`Mpris.players` comes from Quickshell (`import Quickshell.Services.Mpris`).
`player` is a *binding*: when `appPid` changes or a new player appears on D-Bus,
it recomputes by itself. Everything downstream (`title`, `playing`, the icon on the bar)
follows automatically.

How does `appPid` get set? A `Timer` runs `bin/apple-music --pid` through a
`Process` every few seconds (lines 213–234). QML doesn't shell out
synchronously. You set `running = true` on a `Process` and handle its output in a callback.

### 3b. Controls (lines 119–154)

```qml
function next() { if (player && player.canGoNext) { player.next(); return true } ... }
```

Path A is just method calls on the MPRIS object. `seekTo` is the interesting one.
It prefers path B (`--seek` via the launcher) and falls back to MPRIS. Lesson 5 explains why.

### 3c. Reading the bridge (lines 182–211)

```qml
FileView { path: stateDir + "/queue-" + appPid + ".json"; onLoaded: root.queue = JSON.parse(text()) }
Timer    { interval: 1000; onTriggered: queueFile.reload() }
```

The bridge writes a JSON file; the service re-reads it every second. `queue`
is then just another property. `previousTrack`, `nextTrack` and `upcoming` are bindings on it.

### 3d. The smooth clock (lines 236–256)

MusicKit reports the time once per second. To avoid a jumpy display the service
remembers **when** it read the value (`queueLoadedAt`) and adds the elapsed
time: `pos = queue.time + (now - queueLoadedAt)`. It then clamps the value to
`[0, length]` so the seek bar can never run past the end.

### 3e. IPC — keyboard shortcuts (lines 258–286)

```qml
IpcHandler {
  target: "apple-music"
  function next(): string { ... }
  function seek(seconds: real): string { ... }
}
```

Every function here becomes a terminal command: `omarchy-shell apple-music next`.
The **type annotations are required** (`: string`, `seconds: real`). Quickshell
uses them to parse command-line arguments.

> **Try it**
> ```bash
> omarchy-shell apple-music status | jq
> omarchy-shell apple-music next
> omarchy-shell apple-music seek 60
> ```
> Then bind one in `~/.config/hypr/bindings.lua`, the same way Omarchy's own
> media keys are bound in `/usr/share/omarchy/default/hypr/bindings/media.lua`:
> `o.bind("SUPER + ALT + M", "Apple Music play/pause", "omarchy-shell apple-music playPause")`

---

## 4. `BarWidget.qml` + `QueueRow.qml` — what you see

### 4a. Getting the service (line 10)

```qml
readonly property var am: bar && bar.shell ? bar.shell.serviceFor("diegohades.apple-music") : null
```

The widget holds no state of its own. It **reads** the service. `root.am.title`,
`root.am.upcoming`, etc. are all live bindings.

### 4b. The icon and scrolling title (lines 20–79)

`glyphText` picks a Nerd Font glyph (`󰎆` idle, `󰏤`/`󰐊` pause/play).
The title scrolls with a `NumberAnimation on x` that only runs when the text
is wider than `maxLabelWidth` (a user setting from the manifest schema).

### 4c. Mouse handling (lines 81–105)

One `MouseArea` over the widget: left = play/pause (or launch), middle = next,
right = toggle popup, wheel = prev/next. Hover shows a tooltip.

### 4d. The popup (lines 107–end)

`PopupCard` is an Omarchy UI component (from `qs.Ui`). Inside is a `Column`
containing the artwork row, a `PanelSlider` seek bar (line ~194), the button row
(shuffle, library mix, prev, play, next), the **queue section** (line ~287),
and the Show/Quit buttons.

The queue list is a `Repeater` (line ~322). Give it an array (`model: root.am.upcoming`)
and it stamps out one `QueueRow` per item. Each row gets `modelData` (the track)
and `index`. Clicking it emits `activated`, and the popup calls
`root.am.playQueueIndex(modelData.index)`.

`QueueRow.qml` is a separate file, so it's a **reusable component**. Any
`.qml` file whose name starts with a capital letter can be used as a type by
files in the same folder.

Colors come from the theme (`root.bar.foreground`, `Color.accent`), never hardcoded.
That's why it follows your Omarchy theme. The shuffle button turns `Color.accent` when on.

> **Try it — your first edit**
> In `BarWidget.qml` line 20 change the idle glyph `"󰎆"` to `"󰝚"`, save, and
> watch the bar. Widget changes usually hot-reload. If not: `omarchy restart shell`.
> (In testing, **`Service.qml` changes needed `omarchy restart shell`** to take effect.)

---

## 5. Why path A wasn't enough (the bugs that shaped the design)

Look at what Chromium reports over MPRIS while Apple Music plays:

```bash
N=org.mpris.MediaPlayer2.chromium.instance$(bin/apple-music --pid)
busctl --user get-property $N /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata | tr ' ' '\n' | grep -A2 length
busctl --user get-property $N /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Position
```

1. **Length = 9223372036854775807** (the largest 64-bit number). MusicKit
   streams audio through Media Source Extensions with an "infinite" duration,
   and Chromium passes that through as-is.
2. **Position keeps counting across songs.** MusicKit plays the queue as one
   continuous stream, so at the start of song 2 MPRIS says e.g. 324 s, not 0.
   That was the "end of the song" bug.
3. **No queue, no shuffle.** MPRIS has an optional TrackList interface; Chromium
   doesn't implement it, nor the `Shuffle` property.

The lesson: **a standard interface is only as good as its implementation.**
When it lies, go to the source of truth, which here is MusicKit inside the page.

---

## 6. The extension — three JavaScript worlds

Chrome extensions are sandboxed in layers, so reaching MusicKit takes three scripts:

| Script | Runs in | Can see MusicKit? | Can use `chrome.*` APIs? |
|---|---|---|---|
| `page.js` | the page's **MAIN** world | ✅ | ❌ |
| `relay.js` | the **isolated** content-script world | ❌ | ✅ (a few) |
| `background.js` | the extension's **service worker** | ❌ | ✅ (native messaging) |

That's why messages hop: `page.js ⇄ window.postMessage ⇄ relay.js ⇄ chrome.runtime ⇄ background.js`.

### `extension/manifest.json`
- `"world": "MAIN"` on `page.js` is what lets it read `window.MusicKit`.
- `"key": "MIIB…"`: a public key. Chromium derives the **extension ID** from it
  (first 32 hex chars of its SHA-256, with 0–f mapped to a–p). A fixed ID matters
  because the native host only accepts connections from an allowed ID (lesson 7).
- `"host_permissions"` for music.apple.com. Without it `chrome.tabs.query({url})`
  silently returned nothing. That was a real bug during the build.

### `extension/page.js` — the part that does the work
- `attach()` (line ~137) waits until MusicKit exists, then subscribes to its events
  (`nowPlayingItemDidChange`, `queueItemsDidChange`, …).
- `snapshot()` (line ~56) builds the JSON you see in `queue-<pid>.json`:
  previous, current, next 5, plus `time`, `duration`, `shuffle`, `playing`.
- `publish()` only sends when something changed (compares JSON strings).
- The `message` listener (line ~113) executes commands: `playIndex`, `seek`,
  `shuffle`, `shuffleLibrary`. Every call has a timeout, because some MusicKit
  promises never resolve (an unplayable track once hung for 3 minutes).
- `buildMix()` (line ~35) is the library mix, explained in lesson 9.

> **Try it**
> ```bash
> bin/apple-music --queue | jq '{time, duration, shuffle, current: .current.title, next: .next.title}'
> ```

---

## 7. Native messaging + `bin/apple-music-bridge`

**Native messaging** is Chrome's official way for an extension to talk to a
local program. Chromium starts the program itself and talks over stdin/stdout.

Chromium finds the program through a **host manifest**. The launcher writes it into
the dedicated profile, so your normal browser never sees it:

```json
// ~/.local/share/omarchy-apple-music/NativeMessagingHosts/io.omarchy.apple_music.json
{ "name": "io.omarchy.apple_music",
  "path": ".../bin/apple-music-bridge",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://fjoekhebednpfbbbhbmoaldpkmimfofk/"] }
```

### The wire format (bridge lines ~19–24 and ~60–70)
Each message is **4 bytes of length (native byte order) + that many bytes of JSON**:

```python
data = json.dumps(msg).encode()
sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
```

### Two directions, two mechanisms
- **Extension → shell (state):** the bridge writes `queue-<pid>.json` using
  *write to .tmp, then `os.replace`*. That's an atomic rename, so the shell never
  reads a half-written file.
- **Shell → extension (commands):** a **FIFO** (named pipe) `commands-<pid>`.
  A thread in the bridge blocks reading it. The launcher's `--seek` etc. write
  one JSON line into it.

### Why `<pid>` in the filenames?
`BROWSER_PID = os.getppid()`. The bridge's parent is Chromium, whose PID is the
same one in the MPRIS name. During the build, a test browser and your real one
both wrote to a shared `queue.json` and overwrote each other. Keying on PID
made that impossible.

> **Try it — drive it by hand**
> ```bash
> D=$XDG_RUNTIME_DIR/omarchy-apple-music; P=$(bin/apple-music --pid)
> ls -la $D                                  # queue-<P>.json and a 'p' (pipe) file
> echo '{"action":"seek","seconds":30}' > $D/commands-$P
> ```
> That's exactly what `bin/apple-music --seek 30` does.

---

## 8. Trace one click end to end

You click **"Up next → Desire"** in the popup. What happens:

1. `QueueRow` MouseArea → emits `activated()`
2. `BarWidget.qml` → `root.am.playQueueIndex(3)`
3. `Service.qml` → runs `bin/apple-music --play-index 3` via `Process`
4. Launcher → writes `{"action":"playIndex","index":3}` into `commands-<pid>`
5. Bridge thread reads the FIFO → sends a length-prefixed message on stdout
6. `background.js` receives it on the native port → `chrome.tabs.sendMessage`
7. `relay.js` → `window.postMessage` into the page
8. `page.js` → `mk.changeToMediaAtIndex(3)` → **music changes**
9. MusicKit fires `nowPlayingItemDidChange` → `publish()` → back up the chain →
   bridge rewrites `queue-<pid>.json`
10. Service's 1 s timer reloads the file → `queue` changes → the bindings update
    the popup by themselves.

Seven hops out, four back, typically well under a second. Once this chain makes
sense, you understand the whole plugin.

---

## 9. The library mix — a small algorithm

Problem: the web player only puts ~50 songs from your alphabetical library into
the queue, so shuffle gave you songs that all started with "A".

`buildMix()` in `page.js`:
1. Ask the Apple Music API for the library size (`/v1/me/library/songs?limit=1` → `meta.total`, 11,119 for you).
2. Pick **40 random offsets** and fetch **5 songs** at each, all at once (`Promise.all`).
   Many small pages rather than a few big ones, so you don't get runs of neighbouring
   songs (the first version used 8×25 and gave "Bitter…, Bite…, Dyers…, Dybt…").
3. De-duplicate with a `Set`, then **Fisher–Yates shuffle**. It's the standard
   unbiased shuffle: walk backwards, swap each item with a random earlier one.
4. `setQueue` with the first 25 songs (music starts in about 2 s), then
   `playLater` the rest in the background.

It also needed `--autoplay-policy=no-user-gesture-required` in the launcher.
Chromium otherwise refuses to start audio unless you clicked *inside* the page
(`USER_INTERACTION_REQUIRED`).

---

## 10. Debugging toolkit (what was actually used to build this)

| Question | Command |
|---|---|
| Is my plugin valid? | `omarchy plugin validate .` |
| Did QML throw an error? | `journalctl --user --since "-2min" \| grep -i apple-music` |
| Reload the shell | `omarchy restart shell` |
| What does MPRIS say? | `busctl --user introspect org.mpris.MediaPlayer2.chromium.instance<PID> /org/mpris/MediaPlayer2` |
| What does the bridge see? | `bin/apple-music --queue \| jq` |
| Inside the page | launch Chromium with `--remote-debugging-port=9335` and evaluate JS over the DevTools protocol |

Rule learned the hard way: **extension changes only load when the Apple Music
window restarts; Service changes need a shell restart.** When "the fix doesn't
work", check first that the new code is actually running.

---

## 11. Your turn — build the Repeat button

The best way to learn it is to add a feature yourself. MusicKit has
`mk.repeatMode`: `0` = off, `1` = repeat one, `2` = repeat all. The recipe
follows the exact path shuffle took:

1. **`page.js`**: `snapshot()` already publishes `repeat: mk.repeatMode`. Add a
   `"repeat"` action in the message listener that cycles `0 → 2 → 1 → 0`.
2. **`relay.js`**: nothing to change (it forwards any `action`).
3. **`bin/apple-music-bridge`**: add `"repeat"` to the allowed actions list.
4. **`bin/apple-music`**: add a `--repeat)` case, modelled on `--shuffle-library`.
5. **`Service.qml`**: `readonly property int repeat: queue ? queue.repeat : 0`, a
   `cycleRepeat()` function, and `function repeat(): string` in `IpcHandler`.
6. **`BarWidget.qml`**: a `Button` next to shuffle. Glyph `󰑗` (off/all) or `󰑘`
   (one), accent-colored when not 0.
7. **Test in order**: restart the Apple Music window (quit it from the popup, then
   reopen it) → `bin/apple-music --repeat` → `bin/apple-music --queue | jq .repeat` →
   `omarchy restart shell` → click the button.
8. **Ship it**: `git add -A && git commit -m "Add repeat" && git push`.

Stuck at a step? Ask Hades for a hint on that step instead of the answer.
