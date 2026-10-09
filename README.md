# Apple Music for Omarchy

Omarchy shell plugin (`service` + `bar-widget`) that runs **music.apple.com** as a
dedicated Chromium web app and controls it from the Omarchy bar.

- Own Chromium profile (`~/.local/share/omarchy-apple-music`) so Apple Music is a
  separate MPRIS player, never confused with Brave/YouTube tabs
- Widevine DRM works (Chromium ships it), sign in once with your Apple ID
- Artwork, title/artist/album, seek bar, shuffle / prev / play-pause / next / **repeat**
- **Search** Apple Music and your library from the popup: play now, play next, add to queue
- **Love / Suggest less / Add to library** for the current song
- **Library mix** (󰕆): random mix from your whole library, starts in ~2 s
- **Hide window**: moves Apple Music to a hidden workspace, music keeps playing
- **Media keys prefer Apple Music** (optional binding, see below)
- Accurate per-track time and length (from MusicKit, not Chromium's MPRIS clock)
- **Previous / Up next** list from the real Apple Music queue (incl. autoplay);
  click any upcoming track to jump to it

## Install

```bash
omarchy plugin add https://github.com/DiegoObethBatista/omarchy-apple-music-plugin.git --enable
```

Requires `chromium`, `jq` and `python3` (all standard on Omarchy).

Tested with Chromium 152. The bridge extension is loaded with `--load-extension`,
which Google removed from branded Chrome (137+) but which still works in Chromium,
so the plugin needs `chromium`, not `google-chrome`. If a future build ignores it,
the plugin degrades to play/pause and track info from MPRIS, and the bar tooltip
reads "bridge not connected".

The bridge calls Apple's web-player API (`amp-api.music.apple.com`) with the
session tokens of the page you signed into, to rate songs, add to library and
search. This is not an official Apple API; use it at your own discretion.

Optional app-launcher entry:

```bash
cat > ~/.local/share/applications/"Apple Music.desktop" <<EOF
[Desktop Entry]
Name=Apple Music
Exec=$HOME/.config/omarchy/plugins/diegohades.apple-music/bin/apple-music
Icon=apple-music
Type=Application
Categories=Audio;Music;Player;
EOF
```

## Remove

1. If you added the media-key bindings, delete them from `~/.config/hypr/bindings.lua`
   first: they call a script inside the plugin folder, so they stop working once it is gone.
2. Quit Apple Music and remove the plugin:

   ```bash
   ~/.config/omarchy/plugins/diegohades.apple-music/bin/apple-music --quit
   omarchy plugin remove diegohades.apple-music
   ```

3. Delete the dedicated Chromium profile. It holds your Apple Music sign-in
   (cookies and session tokens) and the bridge's native-messaging manifest:

   ```bash
   rm -rf ~/.local/share/omarchy-apple-music
   ```

4. If you created the optional launcher entry: `rm ~/.local/share/applications/"Apple Music.desktop"`

Runtime files in `$XDG_RUNTIME_DIR/omarchy-apple-music` are removed when the app
closes and cleared at logout.

## Bar widget

| Action | Result |
|---|---|
| Left click | Open Apple Music if closed; otherwise play/pause |
| Middle click | Next track |
| Scroll | Previous / next |
| Right click | Popup: search, artwork, seek, controls, love/dislike/library, mix, queue, hide/quit |

Keys inside the popup:

| Key | Action |
|---|---|
| `s` or `/` | Search (type; results appear as you type) |
| `↑` `↓` | Select a result |
| `Enter` / `Shift+Enter` / `Ctrl+Enter` | Play now / play next / add to end of queue |
| `Esc` | Close search, then close popup |
| `p` `n` `b` | Play-pause, next, previous (back) |
| `r` | Cycle repeat: off → all → one |
| `f` | Love / un-love the current song |

Settings (`shell.json` entry): `showTitle` (bool), `maxLabelWidth` (px).

## Media keys: Apple Music first

Add to `~/.config/hypr/bindings.lua`:

```lua
local am_key = os.getenv("HOME") .. "/.config/omarchy/plugins/diegohades.apple-music/bin/apple-music-key"
for _, k in ipairs({ "XF86AudioPlay", "XF86AudioPause", "XF86AudioNext", "XF86AudioPrev",
                     "ALT + XF86AudioPlay", "ALT + SHIFT + XF86AudioPlay" }) do hl.unbind(k) end
o.bind("XF86AudioPlay",  "Play/pause (Apple Music first)", am_key .. " playPause", { locked = true })
o.bind("XF86AudioPause", "Play/pause (Apple Music first)", am_key .. " playPause", { locked = true })
o.bind("XF86AudioNext",  "Next track (Apple Music first)", am_key .. " next",      { locked = true })
o.bind("ALT + XF86AudioPlay", "Next track (Apple Music first)", am_key .. " next", { locked = true })
o.bind("XF86AudioPrev",  "Previous track (Apple Music first)", am_key .. " previous", { locked = true })
o.bind("ALT + SHIFT + XF86AudioPlay", "Previous track (Apple Music first)", am_key .. " previous", { locked = true })
```

Rule: if Apple Music is playing, the key goes to it. If something else is
playing (a video) and Apple Music is paused, the key goes to that instead.
Otherwise it resumes Apple Music. If the plugin isn't loaded, `apple-music-key`
falls back to Omarchy's own media service, so the keys never go dead.
`Shift` + play still switches the media source (Omarchy default).

## IPC — use in Hyprland keybindings

```bash
omarchy-shell apple-music launch
omarchy-shell apple-music playPause | next | previous
omarchy-shell apple-music mediaKey playPause   # Apple Music first, else system player
omarchy-shell apple-music status               # JSON
omarchy-shell apple-music queue                # JSON: previous, current, next, upcoming[]
omarchy-shell apple-music playIndex 7          # jump to queue index
omarchy-shell apple-music shuffleLibrary       # random mix of whole library
omarchy-shell apple-music shuffle              # toggle queue shuffle; prints on/off
omarchy-shell apple-music setShuffle true
omarchy-shell apple-music repeat               # cycle off -> all -> one
omarchy-shell apple-music setRepeat 2          # 0 off, 1 one, 2 all
omarchy-shell apple-music like                 # toggle Love
omarchy-shell apple-music dislike              # toggle Suggest less
omarchy-shell apple-music addToLibrary
omarchy-shell apple-music search "in flames"   # then: searchResults (JSON)
omarchy-shell apple-music playItem albums 1497661496 now   # now | next | later
omarchy-shell apple-music hide | show | toggleWindow
omarchy-shell apple-music seek 90              # seconds into current track
omarchy-shell apple-music quit
```

## Launcher script

`bin/apple-music` launches or focuses the app (and un-hides it). Other flags:
`--pid`, `--probe`, `--quit`, `--hide`, `--show`, `--queue`, `--search-results`,
`--play-index N`, `--shuffle [on|off]`, `--shuffle-library`, `--repeat [off|one|all]`,
`--rate like|dislike|clear`, `--add-to-library`, `--search ID TERM`,
`--play-item KIND ID now|next|later`, `--seek SECONDS`.
Override the profile dir with `APPLE_MUSIC_DATA_DIR`.

## How it works

The launcher starts Chromium with its own `--user-data-dir`, giving it its own
main process. Chromium publishes MPRIS as
`org.mpris.MediaPlayer2.chromium.instance<PID>`; the service matches that PID,
so only the Apple Music window is controlled.

MPRIS has no queue, search or ratings, so the launcher also loads a small bundled
extension (`extension/`, only into this dedicated profile). It uses MusicKit
inside the page and sends state over Chrome native messaging to
`bin/apple-music-bridge`, which writes
`$XDG_RUNTIME_DIR/omarchy-apple-music/queue-<PID>.json` (and `search-<PID>.json`)
and relays commands from the `commands-<PID>` FIFO. The native-host manifest is
written into the dedicated profile, so your normal Chromium profile is untouched.

Why a separate library mix: the web player only loads ~50 songs of the
alphabetical "Songs" list into the queue, so plain shuffle only reorders
those. The mix samples 40 random spots across the whole library instead.

The launcher passes `--autoplay-policy=no-user-gesture-required` so bar
buttons can start playback without clicking inside the window first.

Existing Apple Music windows need one restart after updating to pick up
extension changes.

## Code layout

One job per file:

| File | Job |
|---|---|
| `Service.qml` | Player state, controls, IPC (`omarchy-shell apple-music …`) |
| `BarWidget.qml` | Bar label + mouse, popup shell: search field, keyboard shortcuts, footer buttons |
| `NowPlaying.qml` | Popup view: artwork, title/artist/album, seek bar, transport, love/library/mix buttons |
| `SearchResults.qml` | Popup view: search status line and result sections |
| `QueuePanel.qml` | Popup view: Previous / Up next list |
| `SearchRow.qml`, `QueueRow.qml` | One search result / one queue track |
| `Logic.js` | Pure helpers (icons, time format, repeat cycle, search flattening), unit-tested |
| `bin/apple-music` | Launcher + CLI (all shell quoting lives here) |
| `bin/apple-music-bridge` | Native-messaging host between the extension and the shell |
| `extension/` | Chromium extension that reads/controls MusicKit |

Views get the service (`am`) and the bar (`bar`, for theme colours and font)
as properties and call the service directly; `BarWidget.qml` keeps the
keyboard focus logic (`PanelKeyCatcher`, search field) and decides which view
is visible.

## Tests

```bash
tests/run.sh          # offline: syntax, qmllint, JS + Python unit tests, launcher, plugin validate
tests/run.sh --live   # also drives the running Apple Music (undoes its own changes)
```

| Suite | What it covers |
|---|---|
| `tests/core.test.mjs` | Queue snapshot, mix sampling, search normalisation, command validation (the logic in the page) |
| `tests/logic.test.mjs` | Repeat cycle, rating toggles, media-key routing, search sections, artwork allow-list, icons |
| `tests/test_bridge.py` | Bridge framing, size limit, file permissions, symlink refusal, command filtering, a real end-to-end process run; also checks the Python and JS validators agree |
| `tests/launcher.test.sh` | The exact JSON each launcher flag sends, and that bad input is rejected |
| `tests/live.sh` | Repeat, like/dislike, search, play next, hide/show, media keys, mix, against the real app |

Pure logic lives in `extension/core.js` and `Logic.js` so it can be tested
without a browser or the shell.

## License

MIT

## Learn how it works

See [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md): a lesson-by-lesson tour of the code, with exercises.

## Security notes

- No sudo or pkexec is required. No network listeners, no system services, no downloads, no bundled binaries.
- The dedicated Chromium profile is launched with `--load-extension` to load the bundled bridge extension, and with `--autoplay-policy=no-user-gesture-required`. No Chromium security feature is turned off. These flags apply only to that profile; your regular browser is not affected.
- The launcher only opens `https://music.apple.com/` URLs, since that profile has the extension loaded.
- Runtime state (queue/search JSON + command FIFO) lives only in the owner-only `$XDG_RUNTIME_DIR/omarchy-apple-music` (`0700`); the bridge refuses to start without it, and refuses a symlinked state dir.
- The extension and native-messaging host are installed only into the plugin's dedicated Chromium profile; your regular browser profile is untouched.
- Commands are validated three times (launcher, bridge, page) against a fixed allow-list; unknown actions and malformed ids are dropped.
- Apple Music tokens stay inside the page. Only results (titles, ids, artwork URLs) reach the bar.
- Data coming from the web page is treated as untrusted: displayed as plain text, artwork loaded only from Apple's CDN, bridge messages size-limited.
