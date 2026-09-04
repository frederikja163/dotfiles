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

# deskbinds.lua reads the pinned monitor order from this when set; pointing it
# at a scratch file keeps the tests from depending on (or touching) the real,
# machine-local one.
export HYPR_MONITOR_ORDER="${TMPDIR:-/tmp}/hypr-monitor-order-test"

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
# previous one, creating an hl.timer during config load segfaults, timers are
# only ever oneshot (type="repeating" never fires), workspace.toggle_special
# takes a bare name as a positional argument and silently ignores a table, and
# percentages in a size rule are ignored where monitor_w/monitor_h work.
#
# Test behaviour changes against a nested Hyprland:
#
#   ./tests/sandbox.sh start
#   ./tests/sandbox.sh hyprctl clients -j
#   ./tests/sandbox.sh stop
#
# Lately: monitors are id-ordered from get_monitors(), and hl.monitor's
# position field is a "WxH" string ("640x480"), not the x@y token, with
# logical coordinates (pixels / scale).
#
# That parks it in a special workspace, which is outside the desktop model and
# so cannot be reached or shown by accident. It never draws while it is hidden,
# but it runs: use hyprctl and what the config writes out, not your eyes.
