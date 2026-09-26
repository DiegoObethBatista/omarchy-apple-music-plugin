# Apple Music for Omarchy

Omarchy shell plugin (`service` + `bar-widget`) that runs **music.apple.com** as a
dedicated Chromium web app and controls it from the Omarchy bar over MPRIS.

- Own Chromium profile (`~/.local/share/omarchy-apple-music`) so Apple Music is a
  separate MPRIS player, never confused with Brave/YouTube tabs
- Widevine DRM works (Chromium ships it), sign in once with your Apple ID
- Artwork, title/artist/album, seek bar, shuffle / prev / play-pause / next, show / quit
- Accurate per-track time and length (from MusicKit, not Chromium's MPRIS clock)
- **Previous / Up next** list from the real Apple Music queue (incl. autoplay);
  click any upcoming track to jump to it

## Install

```bash
omarchy plugin add https://github.com/DiegoObethBatista/omarchy-apple-music-plugiin.git --enable
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
omarchy-shell apple-music shuffle       # toggle; prints on/off
omarchy-shell apple-music setShuffle true
omarchy-shell apple-music seek 90       # seconds into current track
omarchy-shell apple-music quit
```

## Launcher script

`bin/apple-music` launches or focuses the app; `--pid` prints the main PID,
`--quit` closes it, `--queue` prints the queue JSON, `--play-index N` jumps
to a queue entry, `--shuffle [on|off|toggle]`, `--seek SECONDS`. Override the profile dir with `APPLE_MUSIC_DATA_DIR`.

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
dedicated profile, so your normal Chromium profile is untouched. Existing
Apple Music windows need one restart after updating to pick up the extension.

## License

MIT
