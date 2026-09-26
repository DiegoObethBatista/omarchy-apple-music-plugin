# Apple Music for Omarchy

Omarchy shell plugin (`service` + `bar-widget`) that runs **music.apple.com** as a
dedicated Chromium web app and controls it from the Omarchy bar over MPRIS.

- Own Chromium profile (`~/.local/share/omarchy-apple-music`) so Apple Music is a
  separate MPRIS player, never confused with Brave/YouTube tabs
- Widevine DRM works (Chromium ships it), sign in once with your Apple ID
- Artwork, title/artist/album, seek bar, shuffle / prev / play-pause / next, show / quit
- **Library mix** (󰒝): random mix from your whole library — starts in ~2 s
- Accurate per-track time and length (from MusicKit, not Chromium's MPRIS clock)
- **Previous / Up next** list from the real Apple Music queue (incl. autoplay);
  click any upcoming track to jump to it

## Install

```bash
omarchy plugin add https://github.com/DiegoObethBatista/omarchy-apple-music-plugin.git --enable
```

Requires `chromium`, `jq` and `python3` (all standard on Omarchy).

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

## Bar widget

| Action | Result |
|---|---|
| Left click | Open Apple Music if closed; otherwise play/pause |
| Middle click | Next track |
| Scroll | Previous / next |
| Right click | Popup: artwork, seek, shuffle + controls, previous / up next, show window, quit |

Settings (`shell.json` entry): `showTitle` (bool), `maxLabelWidth` (px).

## IPC — use in Hyprland keybindings

```bash
omarchy-shell apple-music launch
omarchy-shell apple-music playPause
omarchy-shell apple-music next
omarchy-shell apple-music previous
omarchy-shell apple-music status   # JSON, includes previous/next
omarchy-shell apple-music queue    # JSON: previous, current, next, upcoming[]
omarchy-shell apple-music playIndex 7   # jump to queue index
omarchy-shell apple-music shuffleLibrary   # random mix of whole library
omarchy-shell apple-music shuffle       # toggle queue shuffle; prints on/off
omarchy-shell apple-music setShuffle true
omarchy-shell apple-music seek 90       # seconds into current track
omarchy-shell apple-music quit
```

## Launcher script

`bin/apple-music` launches or focuses the app; `--pid` prints the main PID,
`--quit` closes it, `--queue` prints the queue JSON, `--play-index N` jumps
to a queue entry, `--shuffle [on|off|toggle]`, `--shuffle-library`, `--seek SECONDS`. Override the profile dir with `APPLE_MUSIC_DATA_DIR`.

## How it works

The launcher starts Chromium with its own `--user-data-dir`, giving it its own
main process. Chromium publishes MPRIS as
`org.mpris.MediaPlayer2.chromium.instance<PID>`; the service matches that PID,
so only the Apple Music window is controlled.

MPRIS has no queue, so the launcher also loads a small bundled extension
(`extension/`, only into this dedicated profile). It reads MusicKit's queue
inside the page and sends it over Chrome native messaging to
`bin/apple-music-bridge`, which writes
`$XDG_RUNTIME_DIR/omarchy-apple-music/queue-<PID>.json` and relays jump commands
from the `commands-<PID>` FIFO. The native-host manifest is written into the
dedicated profile, so your normal Chromium profile is untouched. Why a separate library mix: the web player only loads ~50 songs of the
alphabetical "Songs" list into the queue, so plain shuffle only reorders
those. The mix samples 40 random spots across the whole library instead.

The launcher passes `--autoplay-policy=no-user-gesture-required` so bar
buttons can start playback without clicking inside the window first.

Existing
Apple Music windows need one restart after updating to pick up the extension.

## License

MIT

## Learn how it works

See [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md): a lesson-by-lesson tour of the code, with exercises.

## Security notes

- No network listeners, no `sudo`/`pkexec`, no systemd units, no downloads, no bundled binaries.
- Runtime state (queue JSON + command FIFO) lives only in the owner-only `$XDG_RUNTIME_DIR/omarchy-apple-music` (`0700`); the bridge refuses to start without it.
- The extension and native-messaging host are installed only into the plugin's dedicated Chromium profile; your regular browser profile is untouched.
- Data coming from the web page is treated as untrusted: displayed as plain text, artwork loaded only from Apple's CDN, bridge messages size-limited and validated.
