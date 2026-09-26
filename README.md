# Apple Music for Omarchy

Omarchy shell plugin (`service` + `bar-widget`) that runs **music.apple.com** as a
dedicated Chromium web app and controls it from the Omarchy bar over MPRIS.

- Own Chromium profile (`~/.local/share/omarchy-apple-music`) so Apple Music is a
  separate MPRIS player, never confused with Brave/YouTube tabs
- Widevine DRM works (Chromium ships it), sign in once with your Apple ID
- Artwork, title/artist/album, seek bar, prev / play-pause / next, show / quit

## Install

```bash
omarchy plugin add https://github.com/DiegoObethBatista/omarchy-apple-music-plugiin.git --enable
```

Requires `chromium` and `jq` (both standard on Omarchy).

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
| Right click | Popup: artwork, seek, controls, show window, quit |

Settings (`shell.json` entry): `showTitle` (bool), `maxLabelWidth` (px).

## IPC — use in Hyprland keybindings

```bash
omarchy-shell apple-music launch
omarchy-shell apple-music playPause
omarchy-shell apple-music next
omarchy-shell apple-music previous
omarchy-shell apple-music status   # JSON
omarchy-shell apple-music quit
```

## Launcher script

`bin/apple-music` launches or focuses the app; `--pid` prints the main PID,
`--quit` closes it. Override the profile dir with `APPLE_MUSIC_DATA_DIR`.

## How it works

The launcher starts Chromium with its own `--user-data-dir`, giving it its own
main process. Chromium publishes MPRIS as
`org.mpris.MediaPlayer2.chromium.instance<PID>`; the service matches that PID,
so only the Apple Music window is controlled.

## License

MIT
