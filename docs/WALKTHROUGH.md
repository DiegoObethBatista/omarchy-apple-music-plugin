# Apple Music plugin — a guided walkthrough

A lesson-by-lesson tour of how this plugin is built. Each lesson has:
**what the file does → the key lines → why it's done that way → try it yourself.**

Do the "Try it" boxes — running things is how this sticks.
All paths are relative to `~/.config/omarchy/plugins/diegohades.apple-music/`.
Code is referenced by **function or section name** rather than line number, so
use your editor's search (e.g. search for `function seekTo`) to jump there.

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

File map (≈2,200 lines of plugin code, plus tests):

| File | Language | Role |
|---|---|---|
| `manifest.json` | JSON | Tells Omarchy what the plugin is and where its entry points are |
| `bin/apple-music` | Bash | Launcher + small command-line tool |
| `Service.qml` | QML/JS | Headless brain: state, controls, IPC |
| `BarWidget.qml` | QML | The bar icon, mouse handling, popup shell (search field, keys) |
| `NowPlaying.qml`, `SearchResults.qml`, `QueuePanel.qml` | QML | The popup's views |
| `SearchRow.qml`, `QueueRow.qml` | QML | One search result / one queue track |
| `extension/*` | JS | Chromium extension that reads MusicKit |
| `bin/apple-music-bridge` | Python | Pipe between the extension and the shell |
| `bin/apple-music-key` | Bash | Media-key entry point (Apple Music first, then the system) |
| `Logic.js` | JS | Pure helpers for the QML side (icons, repeat cycle, parsing), unit-tested |

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
DATA_DIR="${APPLE_MUSIC_DATA_DIR:-$HOME/.local/share/omarchy-apple-music}"
...
exec setsid uwsm-app -- chromium \
  --user-data-dir="$DATA_DIR" \        # ← the key idea
  --app="$URL" \                       # window without tabs/address bar
  --load-extension="$PLUGIN_DIR/extension" \
  --autoplay-policy=no-user-gesture-required \
  --password-store=gnome-libsecret \   # cookies encrypted with the GNOME keyring
  ...
```

(`APPLE_MUSIC_DATA_DIR` exists so the tests can point the launcher at a
throwaway profile.)

**Why its own `--user-data-dir`?** Chromium runs one main process per
profile. A separate profile gives Apple Music **its own PID**, and Chromium names its
MPRIS player `org.mpris.MediaPlayer2.chromium.instance<PID>`. So the PID is
how we tell "Apple Music" apart from your Brave/YouTube tabs. No guessing
from window titles.

Other things worth noticing:
- `uwsm-app --` — Omarchy's way of launching apps so systemd tracks them properly.
- The `case "${1:-}" in` block turns the launcher into a mini CLI (`bin/apple-music --help`
  lists it all): `--probe`, `--pid`, `--quit`, `--queue`, `--play-index N`, `--seek S`,
  `--shuffle`, `--repeat`, `--rate`, `--search`, `--play-item`, `--hide`/`--show` and more.
  The shell calls these instead of doing file/FIFO work in QML (easier to test from a terminal).
  Every argument is checked with a strict regex before it becomes JSON (lesson 12).
- `app_pid()` finds the browser with `pgrep -f`. The profile path is **regex-escaped
  and anchored** (`data_re()`), so a look-alike path such as `…/omarchy-apple-music-old`
  can never match.
- After the `case` block (search for `NM_DIR=`) it creates the profile **owner-only
  (`0700`)** and writes the **native-messaging host manifest** into it with `jq`
  (lesson 7). Building JSON with `jq` instead of a heredoc means an odd path
  can't corrupt the file.
- A URL argument is accepted only if it starts with `https://music.apple.com/`:
  this profile has the bridge extension loaded, so it should never open anything else.
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

### 3a. Finding the player (`readonly property var player`)

```qml
property int appPid: 0
readonly property bool running: appPid > 0

readonly property var player: {
  if (!root.running) return null
  var suffix = ".instance" + root.appPid
  for (...) if (name.indexOf("org.mpris.MediaPlayer2.chromium") === 0 && name.endsWith(suffix)) return p
  return null
}
```

`Mpris.players` comes from Quickshell (`import Quickshell.Services.Mpris`).
`player` is a *binding*: when `appPid` changes or a new player appears on D-Bus,
it recomputes by itself. Everything downstream (`title`, `playing`, the icon on the bar)
follows automatically.

How does `appPid` get set? `probeTimer` runs `bin/apple-music --probe` through
`probeProc` every few seconds. One call answers two questions: the PID and the
window state (`"12345 visible"`, `"12345 hidden"` or `"0 none"`), which
`Logic.parseProbe()` turns into `appPid` and `windowState`. QML doesn't shell out
synchronously. You set `running = true` on a `Process` and handle its output in a callback.

### 3b. Controls (`// ---- commands` and `// ---- transport`)

```qml
function next() { if (player && player.canGoNext) { player.next(); return true } ... }
```

Path A is just method calls on the MPRIS object. `seekTo` is the interesting one.
It prefers path B (`--seek` via the launcher) and falls back to MPRIS. Lesson 5 explains why.

Path B commands all go through `run(args)`, which **queues** them in `cmdQueue`
and runs one launcher process at a time, so fast clicks are never dropped.
Buttons also feel instant thanks to **optimistic state**: `setPending("shuffle", true)`
flips the button right away, and `confirmPending()` clears it once MusicKit's next
snapshot agrees (or a 4 s timeout drops it).

### 3c. Reading the bridge (the two `FileView`s)

```qml
FileView { path: stateDir + "/queue-" + appPid + ".json"; onLoaded: root.queue = JSON.parse(text()) }
Timer    { interval: 1000; onTriggered: queueFile.reload() }
```

The bridge writes a JSON file; the service re-reads it every second. `queue`
is then just another property. `previousTrack`, `nextTrack` and `upcoming` are bindings on it.
Search works the same way with `search-<pid>.json`, polled every 250 ms while a
search is pending. Each query carries an id, and `Logic.searchSections()` ignores
answers to older ids, so a slow reply can't overwrite a newer one.

### 3d. The smooth clock (the `Timer` above `IpcHandler`)

MusicKit reports the time once per second. To avoid a jumpy display the service
remembers **when** it read the value (`queueLoadedAt`) and adds the elapsed
time: `pos = queue.time + (now - queueLoadedAt)`. It then clamps the value to
`[0, length]` so the seek bar can never run past the end.

### 3e. IPC — keyboard shortcuts (`IpcHandler`)

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

## 4. `BarWidget.qml` + the view files — what you see

### 4a. Getting the service (`readonly property var am`)

```qml
readonly property var am: bar && bar.shell ? bar.shell.serviceFor("diegohades.apple-music") : null
```

The widget holds no state of its own. It **reads** the service. `root.am.title`,
`root.am.upcoming`, etc. are all live bindings.

### 4b. The icon and scrolling title

`glyphText` picks a Nerd Font glyph from `Logic.G` (`note` idle, `pause`/`play`).
All glyphs live in `Logic.js` as code points, so `tests/logic.test.mjs` can check them.
The title scrolls with a `NumberAnimation on x` that only runs when the text
is wider than `maxLabelWidth` (a user setting from the manifest schema).

### 4c. Mouse handling (the `MouseArea`)

One `MouseArea` over the widget: left = play/pause (or launch), middle = next,
right = toggle popup, wheel = prev/next. Hover shows a tooltip, which also says
"bridge not connected" when path B is down (lesson 6).

### 4d. The popup (`KeyboardPanel` in `BarWidget.qml`)

`KeyboardPanel` is an Omarchy UI component (from `qs.Ui`) that can take
keyboard focus (`PopupCard` can't, so the search field would get no typing).
Inside, a `PanelKeyCatcher` handles single-key shortcuts and a `Column` stacks:

- the search field (`TextField { id: searchField`), always visible;
- `SearchResults { … }`, shown while searching;
- `NowPlaying { … }`: artwork row, `PanelSlider` seek bar, transport and
  love/library/mix buttons. Artwork goes through `Logic.safeArt()`, which only
  allows Apple's image CDN;
- `QueuePanel { … }`, the Previous / Up next list;
- the Show/Quit buttons.

Each view is its own file and gets what it needs as properties:
`am: root.am` (the service) and `bar: root.bar` (theme colours, font).
`SearchResults` gets the cursor too and emits `playRequested(result, mode)`;
`BarWidget` decides what that means (play, then close search).

The queue list is a `Repeater` in `QueuePanel.qml`. Give it an array
(`model: queueSection.am.upcoming`) and it stamps out one `QueueRow` per item.
Each row gets `modelData` (the track) and `index`. Clicking it emits
`activated`, and the panel calls `queueSection.am.playQueueIndex(modelData.index)`.

Any `.qml` file whose name starts with a capital letter can be used as a type
by files in the same folder. That's how `BarWidget.qml` uses `NowPlaying`
and `QueuePanel` uses `QueueRow` without any import.

Colors come from the theme (`root.bar.foreground`, `Color.accent`), never hardcoded.
That's why it follows your Omarchy theme. The shuffle button turns `Color.accent` when on.

> **Try it — your first edit**
> In `Logic.js` change `note: String.fromCodePoint(0xF0386)` to `0xF075A` (󰝚), save, and
> watch the bar. Then run `node --test tests/logic.test.mjs`: the icon test still
> passes, because it only checks that every glyph is a single Nerd Font code point.
> Try `0x41` ("A") instead and watch it fail. Widget changes usually hot-reload. If not: `omarchy restart shell`.
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

The fourth file, `core.js`, is loaded next to `page.js` but has **no DOM, no
MusicKit and no network**: plain data in, plain data out (`snapshot()`,
`sanitizeCommand()`, `normalizeSearch()`, the mix helpers). That's what makes
the extension testable under Node (lesson 13).

### `extension/manifest.json`
- `"world": "MAIN"` on `page.js` is what lets it read `window.MusicKit`.
- `"key": "MIIB…"`: a public key. Chromium derives the **extension ID** from it
  (first 32 hex chars of its SHA-256, with 0–f mapped to a–p). A fixed ID matters
  because the native host only accepts connections from an allowed ID (lesson 7).
- `"host_permissions"` for music.apple.com. Without it `chrome.tabs.query({url})`
  silently returned nothing. That was a real bug during the build.

### `extension/page.js` — the part that does the work
- `attach()` waits until MusicKit exists, then subscribes to its events
  (`nowPlayingItemDidChange`, `queueItemsDidChange`, …).
- `publish()` calls `core.js` `snapshot()`, which builds the JSON you see in
  `queue-<pid>.json`: previous, current, up to 5 upcoming (including autoplay),
  plus `time`, `duration`, `shuffle`, `repeat`, `rating`, `inLibrary`, `playing`.
  It only sends when something changed (compares JSON strings).
- The `message` listener passes every command through `sanitizeCommand()`, then
  `run(cmd)` executes it: `playIndex`, `seek`, `shuffle`, `repeat`, `rate`,
  `addToLibrary`, `search`, `playItem`, `shuffleLibrary`. Every MusicKit call has a
  timeout (`withTimeout`), because some promises never resolve (an unplayable
  track once hung for 3 minutes).
- `amp()` calls Apple's web API for the things MusicKit's helper can't do
  (ratings, add to library). It uses the page's own tokens, which never leave
  the page: only results are published.
- `shuffleLibrary()` is the library mix, explained in lesson 9.

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

### The wire format (`encode()` and `read_frame()`)
Each message is **4 bytes of length (native byte order) + that many bytes of JSON**:

```python
def encode(msg):
    data = json.dumps(msg).encode()
    return struct.pack("=I", len(data)) + data
```

`read_frame()` does the reverse and refuses anything over `MAX_MESSAGE` (256 KB)
**before** reading the body, so a bad length can't make it allocate gigabytes.
Writes to stdout go through `Bridge.send()`, which holds a lock so two frames
can never interleave on the stream.

### Two directions, two mechanisms
- **Extension → shell (state):** the bridge writes `queue-<pid>.json` using
  *write to .tmp, then `os.replace`*. That's an atomic rename, so the shell never
  reads a half-written file.
- **Shell → extension (commands):** a **FIFO** (named pipe) `commands-<pid>`.
  A thread in the bridge (`command_loop`) blocks reading it. The launcher's
  `--seek` etc. write one JSON line into it, and `sanitize_command()` rebuilds
  each one field by field before forwarding it.

All of this lives in `$XDG_RUNTIME_DIR/omarchy-apple-music`, never `/tmp`.
`Bridge.prepare()` creates that directory `0700`, refuses it if it's a symlink
or owned by someone else, and replaces anything at the FIFO path that isn't a
FIFO. When Chromium closes, `cleanup()` removes the files.

### Why `<pid>` in the filenames?
`main()` passes `os.getppid()` to `Bridge`. The bridge's parent is Chromium,
whose PID is the same one in the MPRIS name. During the build, a test browser and your real one
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
2. `QueuePanel.qml` → `queueSection.am.playQueueIndex(3)`
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

`shuffleLibrary()` in `page.js`, with the pure parts in `core.js`:
1. Ask the Apple Music API for the library size (`/v1/me/library/songs?limit=1` → `meta.total`,
   e.g. ~11,000 songs).
2. `pickOffsets()` picks **40 random offsets**; fetch **5 songs** at each, all at once (`Promise.all`).
   Many small pages rather than a few big ones, so you don't get runs of neighbouring
   songs (the first version used 8×25 and gave "Bitter…, Bite…, Dyers…, Dybt…").
3. De-duplicate with a `Set`, then `shuffleInPlace()`, a **Fisher–Yates shuffle**. It's the
   standard unbiased shuffle: walk backwards, swap each item with a random earlier one.
4. `setQueue` with the first 25 songs (music starts in about 2 s), then
   `playLater` the rest in the background.
5. Each mix gets a generation number (`mixGen`). If you press the button again
   while a mix is still loading, the older one notices it's stale and stops.

Both helpers take an optional `rng`, so the tests pass a fixed sequence and get
predictable results.

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
| Inside the page | open DevTools in the Apple Music window (`Ctrl+Shift+I`) and use the console |
| Run the tests | `tests/run.sh` (lesson 13) |

Avoid `--remote-debugging-port` on your real profile: anything on your machine
can connect to that port and drive your signed-in session. If you need it, use a
throwaway profile (`APPLE_MUSIC_DATA_DIR=$(mktemp -d) bin/apple-music`).

Rule learned the hard way: **extension changes only load when the Apple Music
window restarts; Service changes need a shell restart.** When "the fix doesn't
work", check first that the new code is actually running.

---

## 11. Read one feature end to end: Repeat

Repeat is the smallest complete feature, so it is the best one to trace. Open
each file and find the line; every feature (like, search, hide) follows the
same path.

| Step | File | Look for |
|---|---|---|
| 1. Button | `NowPlaying.qml` | `iconText: Logic.repeatIcon(...)` → `onClicked: root.am.cycleRepeat()` |
| 2. Decision | `Logic.js` | `nextRepeatMode`: off (0) → all (2) → one (1) → off |
| 3. Service | `Service.qml` | `cycleRepeat()` → `run(["--repeat", ...])` (commands queue up in `cmdQueue`) |
| 4. Launcher | `bin/apple-music` | `--repeat)` case: validates `off\|one\|all`, writes `{"action":"repeat","mode":N}` to the FIFO |
| 5. Bridge | `bin/apple-music-bridge` | `sanitize_command`: only known actions and value ranges pass |
| 6. Extension | `relay.js` → `page.js` | `run(cmd)`: `mk.repeatMode = ...` |
| 7. Back to the bar | `core.js` `snapshot()` | publishes `repeat`, bridge writes `queue-<PID>.json`, Service reads `queue.repeat` |

Notice step 5 and step 6 **both** validate (`sanitize_command` in Python,
`sanitizeCommand` in `core.js`). `tests/test_bridge.py` checks the two agree.

### Where the other new features live

| Feature | Key code |
|---|---|
| Love / Suggest less / Add to library | `page.js` `rate()`, `addToLibrary()`, `loadFacts()` (fetches the current song's rating once per song) |
| Search | `page.js` `search()` → `core.js` `normalizeSearch()` → `search-<PID>.json` → `Logic.searchSections()` → `SearchResults.qml` → `SearchRow.qml` |
| Play now / next / later | `core.js` `queueDescriptor()` + `page.js` `playItem()` (`setQueue`, `playNext`, `playLater`) |
| Hide window | `bin/apple-music` `--hide` / `--show` (Hyprland `special:apple-music` workspace), `--probe` reports state |
| Media keys | `bin/apple-music-key` → `Service.mediaKey()` → `Logic.mediaKeyTarget()` |
| Typing in the popup | `BarWidget.qml` uses `KeyboardPanel` (not `PopupCard`) + `PanelKeyCatcher` |

## 12. Security: treat the page as untrusted

The plugin runs unsandboxed with your permissions and talks to a web page, so
the rule is: **nothing that comes from the page or the FIFO is trusted.**

| Threat | Defence | Where |
|---|---|---|
| A malformed or hostile command | Strict allow-list, checked three times | launcher regexes → `sanitize_command()` → `sanitizeCommand()` |
| Shell injection via search terms or ids | Arguments passed as arrays, never a shell string; ids must match `^[A-Za-z0-9._-]{1,64}$` | `Service.qml` `run()`, launcher `--play-item` |
| A huge or broken message from the extension | Size limit before reading, bad JSON skipped | `read_frame()` |
| Another user reading or swapping runtime files | Owner-only `$XDG_RUNTIME_DIR`, no `/tmp` fallback, symlinks refused | `Bridge.prepare()` |
| Another user reading the Apple sign-in | Profile created `0700`, cookies keyring-encrypted | launcher `NM_DIR` block, `--password-store` |
| A page-controlled image URL (tracking, local files) | Only `https://*.mzstatic.com/` artwork is shown | `Logic.safeArt()`, `core.js` `art()` |
| Apple tokens leaking | Used only inside the page for `amp-api.music.apple.com`; never published | `page.js` `amp()` |
| The profile opening other sites | Launcher only accepts `https://music.apple.com/` URLs | launcher `case` block |

Notice the pattern: each check sits at a **boundary** where data crosses from
one process or world into another, and the Python and JS validators are kept in
sync by a shared fixture (`tests/fixtures/commands.json`). See also the README's
*Security notes* and `SECURITY.md`.

## 13. Tests: how to know you didn't break it

```bash
tests/run.sh          # ~5 s, no Apple Music needed
tests/run.sh --live   # drives the real app
```

The trick that makes testing possible: **pure logic is kept out of the
UI and browser code.** `core.js` and `Logic.js` take plain data and return
plain data, so Node can test them without MusicKit or Quickshell. The launcher
test fakes a "running app" with `exec -a` (a `sleep` process whose command
line looks like Chromium) and reads what lands in the FIFO. It also runs the
launch path with a fake `setsid`, so it can check the profile permissions
without starting a browser. `tests/test_bridge.py` feeds the same command
fixture to the Python and the JS validators and requires identical answers.

Exercise: add a test first, watch it fail, then make it pass.
Try: "`--repeat` with no argument cycles" is covered, but "`setRepeat 5` is
rejected by the shell IPC" is not. Where would you check it?

## 14. Your turn: build the Autoplay toggle

MusicKit has `mk.autoplayEnabled` (similar songs after the queue ends), and
`core.js` `snapshot()` already publishes it as `autoplay`. Follow the Repeat
table above to make it controllable:

1. `core.js` `sanitizeCommand`: accept `{action:"autoplay", on:bool}` (+ a test in `tests/core.test.mjs`).
2. `page.js` `run()`: `mk.autoplayEnabled = cmd.on`.
3. `bin/apple-music-bridge` `sanitize_command`: same rule (+ add cases to
   `tests/fixtures/commands.json`, which both validators are tested against).
4. `bin/apple-music`: `--autoplay on|off` (+ `tests/launcher.test.sh`).
5. `Service.qml`: `readonly property bool autoplay`, `toggleAutoplay()`, IPC method.
6. `NowPlaying.qml`: a button, accent-coloured when on. Pick a glyph with
   `fc-query` or the Nerd Fonts cheat sheet, and add it to `Logic.G` (the icon test checks it).
7. `tests/run.sh`, restart the Apple Music window, `tests/run.sh --live`.

Stuck at a step? Look at how Repeat does the same step, and ask for a hint on
that step rather than the full answer.
