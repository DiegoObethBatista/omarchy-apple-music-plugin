#!/bin/bash
# Live checks against the running Apple Music + Omarchy shell.
# Every change is undone (repeat, shuffle, rating, window, queue position is
# not restored). Requires: Apple Music open and signed in, something queued.
set -u
S="omarchy-shell apple-music"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
st()  { $S status | jq -r "$1"; }
wait_for() {  # wait_for 'jq expr' expected [seconds]
  local i; for ((i = 0; i < ${3:-8} * 4; i++)); do
    [[ "$(st "$1")" == "$2" ]] && return 0; sleep 0.25; done; return 1
}

# The shell hot-reloads the plugin when its files change; give it a moment.
for _ in $(seq 20); do [[ "$($S ping 2>/dev/null)" == ok ]] && break; sleep 0.5; done
[[ "$($S ping 2>/dev/null)" == ok ]] || { echo "shell plugin not loaded"; exit 1; }
[[ "$(st .running)" == true ]] || { echo "Apple Music not running"; exit 1; }
wait_for .hasPlayer true 10 || { echo "no MPRIS player"; exit 1; }

echo "repeat"
start=$(st .repeat)
$S setRepeat 2 >/dev/null; wait_for .repeat 2 && ok "repeat all" || bad "repeat all"
$S repeat     >/dev/null; wait_for .repeat 1 && ok "cycle -> one" || bad "cycle -> one"
$S repeat     >/dev/null; wait_for .repeat 0 && ok "cycle -> off" || bad "cycle -> off"
$S setRepeat "$start" >/dev/null

echo "like / dislike (restored afterwards)"
r0=$(st .rating)
if [[ $r0 == 0 ]]; then
  $S like    >/dev/null; wait_for .rating 1  && ok "like"            || bad "like"
  $S dislike >/dev/null; wait_for .rating -1 && ok "dislike replaces" || bad "dislike replaces"
  $S dislike >/dev/null; wait_for .rating 0  && ok "undo"            || bad "undo"
else echo "  skip (current song already rated $r0)"; fi

echo "search"
$S search "in flames colony" >/dev/null
for _ in $(seq 40); do n=$($S searchResults | jq '[.sections[].items[]] | length'); [[ $n -gt 0 ]] && break; sleep 0.25; done
[[ ${n:-0} -gt 0 ]] && ok "search returned $n results" || bad "search returned nothing"
album=$($S searchResults | jq -r '[.sections[] | select(.title=="Albums") | .items[]][0] | "\(.kind) \(.id) \(.title)"')
[[ $album == albums\ * ]] && ok "album result: ${album#* * }" || bad "no album result"

echo "play next from search"
song=$($S searchResults | jq -r '[.sections[] | select(.title=="Songs") | .items[]][0] | "\(.id)\t\(.title)"')
sid=${song%%$'\t'*}; stitle=${song#*$'\t'}
$S playItem songs "$sid" next >/dev/null
for _ in $(seq 32); do [[ "$($S queue | jq -r '.next.title // ""')" == "$stitle" ]] && break; sleep 0.25; done
[[ "$($S queue | jq -r '.next.title // ""')" == "$stitle" ]] && ok "play next: '$stitle' is up next" || bad "play next (next is '$($S queue | jq -r .next.title)')"

echo "window hide / show (music keeps playing)"
was=$(st .window)
$S hide >/dev/null; wait_for .window hidden 5 && ok "hidden" || bad "hide"
sleep 1; [[ "$(st .playing)" == true ]] && ok "still playing while hidden" || bad "stopped when hidden"
$S show >/dev/null; wait_for .window visible 5 && ok "shown" || bad "show"
[[ $was == hidden ]] && $S hide >/dev/null

echo "media keys (the wrapper the Hyprland bindings call)"
KEY="$(dirname "$0")/../bin/apple-music-key"
"$KEY" playPause; wait_for .playing false 4 && ok "play/pause key pauses Apple Music" || bad "media key pause"
"$KEY" playPause; wait_for .playing true 4  && ok "play/pause key resumes Apple Music" || bad "media key resume"
t0=$(st .title)
"$KEY" next; for _ in $(seq 32); do t1=$(st .title); [[ -n $t1 && $t1 != "$t0" ]] && break; sleep 0.25; done
[[ -n $t1 && $t1 != "$t0" ]] && ok "next key skips ($t0 -> $t1)" || bad "next key (still '$t1')"
"$KEY" bogus 2>/dev/null; [[ $? == 2 ]] && ok "wrapper rejects unknown actions" || bad "wrapper accepted bogus action"

echo "library mix rebuilds the queue every time"
q0=$($S queue | jq -r '[.current.title] + [.upcoming[].title] | join("|")')
$S shuffleLibrary >/dev/null
for _ in $(seq 40); do q1=$($S queue | jq -r '[.current.title] + [.upcoming[].title] | join("|")'); [[ $q1 != "$q0" ]] && break; sleep 0.25; done
[[ $q1 != "$q0" ]] && ok "new mix: ${q1%%|*}" || bad "mix did not change the queue"
$S shuffleLibrary >/dev/null
for _ in $(seq 40); do q2=$($S queue | jq -r '[.current.title] + [.upcoming[].title] | join("|")'); [[ $q2 != "$q1" ]] && break; sleep 0.25; done
[[ $q2 != "$q1" ]] && ok "second mix differs: ${q2%%|*}" || bad "second mix left the queue unchanged"

echo
echo "live: $pass passed, $fail failed"
[[ $fail == 0 ]]
