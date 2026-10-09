#!/bin/bash
# Launcher tests: argument validation and the exact JSON each subcommand
# writes to the bridge FIFO. Uses a fake "running app" (a sleep process whose
# command line carries the --user-data-dir marker) and a private runtime dir,
# so it never touches the real Apple Music.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/bin/apple-music"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "  FAIL: $*"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/am-launcher-test.XXXXXX")
export XDG_RUNTIME_DIR="$T/run"; mkdir -m 700 -p "$XDG_RUNTIME_DIR/omarchy-apple-music"
export APPLE_MUSIC_DATA_DIR="$T/data"
# A process pgrep will match as "the app": exec -a sets its argv[0]-line.
bash -c "exec -a 'fake-chromium --user-data-dir=$APPLE_MUSIC_DATA_DIR' sleep 60" &
FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.2
FIFO="$XDG_RUNTIME_DIR/omarchy-apple-music/commands-$FAKE"
mkfifo -m 600 "$FIFO"

# Write the launcher's command into the FIFO and capture what arrives.
send_and_read() {
  local out="$T/out"; : > "$out"
  ( timeout 3 head -n1 "$FIFO" > "$out" ) &
  local reader=$!
  sleep 0.05
  "$L" "$@" <<<"${STDIN-}" >/dev/null 2>&1
  local rc=$?
  wait $reader 2>/dev/null
  printf '%s|%s' "$rc" "$(cat "$out")"
}

check() {  # check 'expected json' args...
  local want="$1"; shift
  local r; r=$(send_and_read "$@")
  local rc=${r%%|*} got=${r#*|}
  if [[ $rc == 0 ]] && [[ "$(jq -cS . <<<"$got" 2>/dev/null)" == "$(jq -cS . <<<"$want")" ]]; then ok
  else bad "$* -> rc=$rc got=$got want=$want"; fi
}

check_rejected() {  # args... must exit 2 (usage) and send nothing
  "$L" "$@" <<<"${STDIN-}" >/dev/null 2>&1
  local rc=$?
  [[ $rc == 2 ]] && ok || bad "$* should be rejected (rc=$rc)"
}

echo "launcher: commands"
check '{"action":"repeat"}'                         --repeat
check '{"action":"repeat","mode":0}'                --repeat off
check '{"action":"repeat","mode":1}'                --repeat one
check '{"action":"repeat","mode":2}'                --repeat all
check '{"action":"rate","value":1}'                 --rate like
check '{"action":"rate","value":-1}'                --rate dislike
check '{"action":"rate","value":0}'                 --rate clear
check '{"action":"addToLibrary"}'                   --add-to-library
check '{"action":"shuffle","on":true}'              --shuffle on
check '{"action":"shuffle"}'                        --shuffle
check '{"action":"shuffleLibrary"}'                 --shuffle-library
check '{"action":"seek","seconds":42}'              --seek 42
check '{"action":"playIndex","index":7}'            --play-index 7
check '{"action":"playItem","kind":"albums","id":"1497661496","mode":"next"}' --play-item albums 1497661496 next
check '{"action":"playItem","kind":"library-playlists","id":"p.AbC_9","mode":"now"}' --play-item library-playlists p.AbC_9 now
# Search terms arrive on stdin, never as arguments (other users can read argv).
STDIN="in flames" check '{"action":"search","id":3,"term":"in flames"}' --search 3
# Quotes, backslashes and unicode in search terms must stay valid JSON.
STDIN='Motörhead "Ace" \ of' check '{"action":"search","id":4,"term":"Motörhead \"Ace\" \\ of"}' --search 4

echo "launcher: rejected input"
check_rejected --repeat twice
check_rejected --rate love
check_rejected --seek abc
check_rejected --seek -5
check_rejected --play-index 1x
check_rejected --play-index 007
check_rejected --seek 05
check_rejected --play-item artists 123 now
check_rejected --play-item songs '1;rm' now
check_rejected --play-item songs 123 sometime
STDIN=term check_rejected --search notanumber
STDIN=term check_rejected --search 007
STDIN="" check_rejected --search 5
STDIN="   " check_rejected --search 5
check_rejected --search 5 "term on argv is refused"
check_rejected --bogus
check_rejected http://music.apple.com/
check_rejected https://evil.example/
check_rejected https://music.apple.com.evil.example/
check_rejected file:///etc/passwd

echo "launcher: search text never reaches argv"
# Wrap every command the launcher may spawn and log its arguments; the search
# term must reach the FIFO but never appear in any child's argv.
SPY="$T/spy"; mkdir -p "$SPY"; : > "$T/argv.log"
for c in jq timeout bash cat head pgrep; do
  real=$(command -v "$c")
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$T/argv.log" "$real" > "$SPY/$c"
  chmod +x "$SPY/$c"
done
secret="my private search 7f3a"
r=$(PATH="$SPY:$PATH" STDIN="$secret" send_and_read --search 9)
[[ $r == "0|"*"$secret"* ]] && ok || bad "search via stdin did not reach the FIFO: $r"
[[ -s "$T/argv.log" ]] && ok || bad "argv spy logged nothing (test is not exercising children)"
grep -qF "$secret" "$T/argv.log" && bad "search text leaked into argv: $(grep -F "$secret" "$T/argv.log")" || ok

echo "launcher: profile dir"
# Run the launch path with a fake setsid so no browser starts: an existing
# world-readable profile dir is tightened and the host manifest is valid JSON.
mkdir -p "$T/fakebin" "$T/data2"; chmod 755 "$T/data2"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
PATH="$T/fakebin:$PATH" APPLE_MUSIC_DATA_DIR="$T/data2" "$L" >/dev/null 2>&1
[[ $(stat -c %a "$T/data2") == 700 ]] && ok || bad "profile dir not owner-only: $(stat -c %a "$T/data2")"
jq -e '.path | endswith("/bin/apple-music-bridge")' "$T/data2/NativeMessagingHosts/io.omarchy.apple_music.json" >/dev/null && ok || bad "native host manifest"

echo "launcher: probe / not running"
# Look-alike profile dirs must not match the running app: a shared prefix, or "."
# standing in for any character in the regex.
out=$(APPLE_MUSIC_DATA_DIR="$T/dat" "$L" --probe); [[ $out == "0 none" ]] && ok || bad "prefix dir matched: $out"
out=$(APPLE_MUSIC_DATA_DIR="$T/d.ta" "$L" --probe); [[ $out == "0 none" ]] && ok || bad "regex dot matched: $out"
out=$("$L" --probe); [[ $out == "$FAKE "* ]] && ok || bad "--probe with app running: $out"
kill $FAKE 2>/dev/null; wait $FAKE 2>/dev/null
out=$("$L" --probe); [[ $out == "0 none" ]] && ok || bad "--probe with app stopped: $out"
"$L" --repeat >/dev/null 2>&1; [[ $? == 1 ]] && ok || bad "commands fail cleanly when the app is not running"
env -u XDG_RUNTIME_DIR "$L" --repeat >/dev/null 2>&1; [[ $? == 1 ]] && ok || bad "refuses without XDG_RUNTIME_DIR"

echo "launcher: $pass passed, $fail failed"
[[ $fail == 0 ]]
