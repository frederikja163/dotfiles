#!/usr/bin/env bash
# Harness for bin/waybar-main, and the regression test for the duplicate bar.
#
# waybar itself is stubbed, along with hyprctl, setpriv, pgrep and pkill, so the
# script's own logic is what is under test: does running it twice, or twice at
# once, leave exactly one bar? The stub bar records its pid in $BARS while it
# runs and removes it on the way out, which is what the stubbed pgrep and pkill
# read -- a real pgrep cannot match a shell stub, whose comm is "bash".
#
# The point of the concurrent case is the bug this file was written for: two
# runs overlapping so each pkill ran before the other's bar existed, and both
# bars survived. hyprctl is slowed down so the first run spends a moment
# before it spawns, which is what a four-monitor machine's enumeration did and
# what gave the second run its window.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/waybar-main"

TMP="$(mktemp -d)"
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/config/waybar" "$TMP/bars"
cp waybar/config.jsonc "$TMP/config/waybar/config.jsonc"

export XDG_CONFIG_HOME="$TMP/config"
export XDG_RUNTIME_DIR="$TMP/run"
export BARS="$TMP/bars"

cleanup() {
    local f
    for f in "$BARS"/*; do
        [ -e "$f" ] || continue
        kill "${f##*/}" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# A running bar: its pidfile is its liveness, and it comes and goes with TERM.
cat > "$TMP/bin/waybar" <<'STUB'
#!/usr/bin/env bash
: > "$BARS/$$"
trap 'rm -f "$BARS/$$"' EXIT
sleep 30
STUB

# Drop the capability flags and run what follows, as the real one ends up doing.
cat > "$TMP/bin/setpriv" <<'STUB'
#!/usr/bin/env bash
shift 2
exec "$@"
STUB

# One monitor. SLOW_HYPRCTL widens the window the race needed, the time the
# first run spends before it spawns its bar.
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
[ -n "${SLOW_HYPRCTL:-}" ] && sleep "$SLOW_HYPRCTL"
if [ -n "${MONITORS_JSON:-}" ]; then
    printf '%s\n' "$MONITORS_JSON"
    exit 0
fi
cat <<'JSON'
[{"name":"TEST-1","width":1920,"height":1080,"scale":1.0,"disabled":false}]
JSON
STUB

# pgrep -x waybar: list the pids in $BARS, fail when there are none.
cat > "$TMP/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
status=1
for f in "$BARS"/*; do
    if [ -e "$f" ]; then printf '%s\n' "${f##*/}"; status=0; fi
done
exit $status
STUB

# pkill -x waybar: kill the pids in $BARS.
cat > "$TMP/bin/pkill" <<'STUB'
#!/usr/bin/env bash
for f in "$BARS"/*; do
    [ -e "$f" ] || continue
    kill "${f##*/}" 2>/dev/null
done
exit 0
STUB

chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

bar_count() {
    local n=0 f
    for f in "$BARS"/*; do [ -e "$f" ] && n=$((n + 1)); done
    printf '%s' "$n"
}
bar_pids() {
    local f
    for f in "$BARS"/*; do [ -e "$f" ] && printf '%s ' "${f##*/}"; done
}

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

echo "scenario: one run starts a bar"
"$SCRIPT" >/dev/null 2>&1
check "one bar" "$(bar_count)" 1

echo "scenario: running again replaces the bar, not adds one"
first="$(bar_pids)"
"$SCRIPT" >/dev/null 2>&1
check "still one bar" "$(bar_count)" 1
check "a different bar" "$([ "$(bar_pids)" != "$first" ] && echo yes)" yes

echo "scenario: two runs at once leave one bar"
# The regression: without the lock both runs pkill before either bar exists and
# both survive. The second starts while the first is still reading monitors.
export SLOW_HYPRCTL=0.6
"$SCRIPT" >/dev/null 2>&1 &
a=$!
sleep 0.4
"$SCRIPT" >/dev/null 2>&1 &
b=$!
wait "$a" "$b"
check "one bar, not two" "$(bar_count)" 1
unset SLOW_HYPRCTL

echo "scenario: an already-running bar is replaced by a concurrent pair"
# Same again with a bar up first, so the lock has to cover killing it too.
first="$(bar_pids)"
export SLOW_HYPRCTL=0.6
"$SCRIPT" >/dev/null 2>&1 &
a=$!
sleep 0.4
"$SCRIPT" >/dev/null 2>&1 &
b=$!
wait "$a" "$b"
check "one bar" "$(bar_count)" 1
check "and it is a new one" "$([ "$(bar_pids)" != "$first" ] && echo yes)" yes
unset SLOW_HYPRCTL

# What the generated config says about one monitor's workspaces format.
format_of() {
    python3 - "$XDG_RUNTIME_DIR/waybar-main.jsonc" "$1" <<'PY'
import json, sys
bars = {b["output"]: b for b in json.load(open(sys.argv[1]))}
print(bars[sys.argv[2]]["hyprland/workspaces"]["format"])
PY
}

echo "scenario: a narrow screen gets its desktop names cut, a wide one does not"
# The laptop: 1920 pixels at scale 1.5 is 1280 logical, which is what the bar
# is laid out in. The raw width alone would call it a wide screen.
export MONITORS_JSON='[
 {"name":"LAPTOP","width":1920,"height":1200,"scale":1.5,"disabled":false},
 {"name":"DESK","width":2560,"height":1440,"scale":1.0,"disabled":false},
 {"name":"FHD","width":1920,"height":1080,"scale":1.0,"disabled":false},
 {"name":"NOSCALE","width":1280,"height":720,"disabled":false}]'
"$SCRIPT" >/dev/null 2>&1
check "scaled laptop is truncated" "$(format_of LAPTOP)" "{name:.12}"
check "wide monitor keeps the icon format" "$(format_of DESK)" "{icon}"
check "1080p at scale 1 keeps the icon format" "$(format_of FHD)" "{icon}"
check "a missing scale counts as 1" "$(format_of NOSCALE)" "{name:.12}"
unset MONITORS_JSON

echo "scenario: the clock is the last module on the right"
last="$(python3 - "$XDG_RUNTIME_DIR/waybar-main.jsonc" <<'PY'
import json, sys
bar = json.load(open(sys.argv[1]))[0]
print(bar["modules-right"][-1], "modules-center" in bar)
PY
)"
check "clock last, no centre group" "$last" "clock False"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
