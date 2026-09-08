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
# And: an empty desktop is kept only by a `persistent` workspace rule, whose
# selector is the id as a string and keeps matching after a rename. Issued at
# runtime it takes effect at once, but switching it off removes the desktop
# only while it is out of view, so the order (focus away, then drop the rule)
# is load-bearing -- the stub cannot see that either way round. `hyprctl
# reload` rebuilds the rule list, dropping every rule made since config load.
# window.close does take window = "address:0x..." and closes that window rather
# than the focused one, which is how a desktop closes its own quake terminal.
# Dispatcher tables are not field-validated, so --verify-config accepts any
# spelling here: only a running instance shows which one works.
#
# For the session restore: `[workspace <id> silent] cmd` through exec_cmd works
# for an ordinary desktop and creates it if it is not there, while exec_raw
# ignores the prefix entirely and hands the whole string to a shell (its
# redirects are interpreted, its window never appears). exec_cmd itself runs no
# shell, so a relaunch that has to `cd` first goes through `sh -c "..."`, whose
# nested single quotes do survive the argument splitter. config.reloaded fires
# at the first load as well, immediately before hyprland.start -- session.lua
# relies on that order to tell a reload from a fresh start.
#
# And the one that cost a real file: the sandbox is started by the *host*
# compositor's exec dispatcher, so it inherits the host's environment and not
# the shell's. A nested instance therefore wrote its own two windows into the
# real ~/.local/share/hypr/session. sandbox.sh now passes HYPR_SESSION and
# session.lua refuses the default path when HYPR_SANDBOX=1.
#
# That parks it in a special workspace, which is outside the desktop model and
# so cannot be reached or shown by accident. It never draws while it is hidden,
# but it runs: use hyprctl and what the config writes out, not your eyes.
#
# Two limits of the sandbox, both found while testing the modes:
#
# `./tests/sandbox.sh keys` (wtype) does fire binds, which is the only way to
# test a key that enters or leaves a mode -- but only because input.lua turns
# on resolve_binds_by_sym under HYPR_SANDBOX. Without it Hyprland resolves the
# bind keysym through the config's layout, which does not match the keymap
# wtype invents, so keys reach clients and no bind ever fires.
#
# A hidden nested instance has no *active window*: nothing gives its surface
# keyboard focus, so `hyprctl activewindow` answers "Invalid" and
# hl.get_active_window() is nil. Binds still fire and the layout still places
# windows, but anything whose effect depends on the focused window does
# nothing in there. Assert those against the stubbed tests, where the world is
# written down, not against the sandbox.
