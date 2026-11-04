#!/usr/bin/env bash
# Harness for lib/screen-power: dimming the laptop panel and bringing it back.
#
# brightnessctl is stubbed with a backlight held in a file (192000 at its
# brightest, like this machine's), and hyprctl with two monitors and a log of
# what was dispatched. The question is the one that left the screen black: can
# the saved level ever end up being the dimmed one, and what comes back if it
# has. Neither stub touches the real panel or the live compositor.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/screen-power"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

cat > "$TMP/bin/brightnessctl" <<'EOF'
#!/usr/bin/env bash
max=192000
cur="$(cat "$STUB_DIR/level")"
case "$*" in
    -m) echo "intel_backlight,backlight,$cur,0%,$max" ;;
    *set*)
        for arg in "$@"; do v="$arg"; done
        case "$v" in
            *%) v=$((max * ${v%\%} / 100)) ;;
        esac
        echo "$v" > "$STUB_DIR/level" ;;
esac
EOF

cat > "$TMP/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    monitors)
        printf 'Monitor eDP-1 (ID 0):\n\tdpmsStatus: 0\n\nMonitor DP-4 (ID 1):\n\tdpmsStatus: 1\n' ;;
    dispatch) echo "$2" >> "$STUB_DIR/dispatched" ;;
esac
EOF
chmod +x "$TMP/bin/brightnessctl" "$TMP/bin/hyprctl"

run() {
    PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" XDG_RUNTIME_DIR="$TMP" "$SCRIPT" "$@"
}
level() { cat "$TMP/level"; }

reset() {
    rm -f "$TMP/screen-power.saved" "$TMP/dispatched"
    echo "$1" > "$TMP/level"
}

echo "scenario: dim and restore"
reset 96000
run dim
check "dim sets the dim level" "$(level)" 10
run restore
check "restore brings back the level it dimmed from" "$(level)" 96000

echo "scenario: dim twice without a restore"
reset 96000
run dim
run dim
run restore
check "the second dim did not save the dimmed level" "$(level)" 96000

echo "scenario: the saved level is gone by the time of the restore"
reset 10
run restore
check "a restore with nothing saved leaves it alone" "$(level)" 10

echo "scenario: the screen was already near black when dimmed"
reset 10
run dim
run restore
check "it falls back to 50%, not 10" "$(level)" 96000

echo "scenario: a restore is not repeated"
reset 96000
run dim
run restore
echo 50000 > "$TMP/level"
run restore
check "a second restore does not undo the user's change" "$(level)" 50000

echo "scenario: wake"
reset 96000
run wake
check "each monitor is woken by name" "$(tr '\n' '|' < "$TMP/dispatched")" \
      'hl.dsp.dpms({ action = "on", monitor = "eDP-1" })|hl.dsp.dpms({ action = "on", monitor = "DP-4" })|'

echo "scenario: no argument"
run >/dev/null 2>&1
check "it refuses" "$?" 2

echo
if [ "$fail" -gt 0 ]; then
    echo "$pass passed, $fail failed"
    exit 1
fi
echo "$pass passed, $fail failed"
