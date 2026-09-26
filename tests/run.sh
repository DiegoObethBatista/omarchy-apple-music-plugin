#!/bin/bash
# Run every automated test. Exit code 0 = all green.
#   tests/run.sh           unit + launcher + static checks (no Apple Music needed)
#   tests/run.sh --live    also the live checks against the running app
set -u
cd "$(dirname "$0")/.."
status=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
run()  { "$@" || status=1; }

step "syntax"
run node --check extension/core.js
run node --check extension/page.js
run node --check extension/relay.js
run node --check extension/background.js
run bash -n bin/apple-music
run python3 -m py_compile bin/apple-music-bridge
rm -rf bin/__pycache__
run jq empty manifest.json extension/manifest.json

step "qmllint (errors only)"
QMLLINT=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
if [[ -x $QMLLINT ]]; then
  # Omarchy's qs.* modules aren't visible to the linter, so "unqualified"
  # and import warnings are expected; real syntax errors still fail.
  out=$("$QMLLINT" *.qml 2>&1)
  if grep -qE '^Error:|SyntaxError|Expected token' <<<"$out"; then
    grep -E '^Error:|SyntaxError|Expected token' -A2 <<<"$out"; status=1
  else echo "ok"; fi
else echo "qmllint not found, skipped"; fi

step "JavaScript unit tests (core.js, Logic.js)"
run node --test tests/*.test.mjs

step "Python bridge tests"
run python3 -m unittest discover -s tests -p 'test_*.py'

step "launcher tests"
run bash tests/launcher.test.sh

step "omarchy plugin validate"
if command -v omarchy >/dev/null; then run omarchy plugin validate .; else echo "omarchy not found, skipped"; fi

if [[ ${1:-} == --live ]]; then
  step "live checks (running Apple Music)"
  run bash tests/live.sh
fi

echo
[[ $status == 0 ]] && printf '\033[32mALL TESTS PASSED\033[0m\n' || printf '\033[31mSOME TESTS FAILED\033[0m\n'
exit $status
