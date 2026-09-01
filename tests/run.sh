#!/usr/bin/env bash
# Run the Hyprland config tests, then check that Hyprland itself accepts the
# config. Safe to run any time: nothing here touches the running compositor.
#
#   ./tests/run.sh
#
# The tests stub the `hl` API, so they check the logic in hypr/*.lua without a
# compositor. They cannot catch wrong API usage -- that needs a real Hyprland,
# see the note at the bottom.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export HYPR_DIR="${HYPR_DIR:-hypr}"

if ! command -v lua5.4 >/dev/null; then
  echo "lua5.4 not found (pacman -S lua)" >&2
  exit 1
fi

failed=0

for test in tests/test_*.lua; do
  echo "==> $test"
  if ! lua5.4 "$test"; then
    failed=1
  fi
  echo
done

# Catches syntax errors and anything that breaks at config load, without
# applying the config to the running session.
if command -v Hyprland >/dev/null; then
  echo "==> Hyprland --verify-config"
  result="$(timeout 60 Hyprland --verify-config -c "$HYPR_DIR/hyprland.lua" 2>&1 | tail -1)"
  echo "    $result"
  [ "$result" = "config ok" ] || failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "all good"

# Note: a stubbed API happily accepts calls that Hyprland rejects. Bugs found
# only by running a nested instance so far: window.swap takes target= with an
# "address:" prefix (not window=), window.at/size are {x=,y=} tables rather than
# arrays, `consume` pulls from the next column instead of pushing to the
# previous one, and creating an hl.timer during config load segfaults. Test
# behaviour changes against a nested Hyprland:
#
#   HYPR_SANDBOX=1 Hyprland -c hypr/hyprland.lua
#
# HYPR_SANDBOX makes autostart a no-op (hypridle would lock the host session)
# and switches the modifier to ALT, since the host grabs SUPER.
