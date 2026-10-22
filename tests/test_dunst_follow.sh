#!/usr/bin/env bash
# Harness for lib/dunst-follow: the pause-and-restore that makes dunst create its
# notification surface again on the monitor in use.
#
# dunstctl is stubbed with a small model of dunst: a pause level held in a file,
# and a count of displayed notifications that is the real number while the level
# is 0 and nothing while it is above -- except for a notification that overrides
# the pause, which stays up until the level reaches 100, as one with
# override_pause_level does. That is the one behaviour the script leans on, and
# it is enough to ask the questions that matter: is the level put back to what
# the user had, is dunst ever left paused, and does an idle dunst get touched at
# all.
#
# What this cannot check is the thing the script is for: that the compositor
# then puts the new surface on the focused monitor. That needs a real dunst
# under a compositor that sends frames, and the hidden sandbox sends none (see
# tests/sandbox.sh), so it was measured by hand against the running session:
# the notifications layer in `hyprctl layers` had a different address after the
# script than before it.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/dunst-follow"

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

cat > "$TMP/bin/dunstctl" <<'EOF'
#!/usr/bin/env bash
[ -e "$STUB_DIR/down" ] && exit 1
level="$(cat "$STUB_DIR/level")"
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
    count)
        if [ "$level" -ge 100 ] || { [ "$level" -gt 0 ] && [ ! -e "$STUB_DIR/override" ]; }; then
            echo 0
        else
            cat "$STUB_DIR/shown"
        fi ;;
    get-pause-level) echo "$level" ;;
    set-pause-level) echo "$2" > "$STUB_DIR/level" ;;
esac
EOF
chmod +x "$TMP/bin/dunstctl"

# setup SHOWN LEVEL
setup() {
    rm -f "$TMP/calls" "$TMP/down" "$TMP/override"
    echo "$1" > "$TMP/shown"
    echo "$2" > "$TMP/level"
}

run() {
    PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" XDG_RUNTIME_DIR="$TMP" "$SCRIPT"
}

sets() {
    [ -e "$TMP/calls" ] || { echo 0; return; }
    grep -c '^set-pause-level' "$TMP/calls"
}

echo "scenario: something is on screen"
setup 2 0
run
check "it paused and then restored" "$(grep '^set-pause-level' "$TMP/calls" | tr '\n' ' ')" \
      "set-pause-level 100 set-pause-level 0 "
check "dunst is not left paused" "$(cat "$TMP/level")" 0

echo "scenario: nothing is on screen"
setup 0 0
run
check "dunst is not paused at all" "$(sets)" 0

echo "scenario: do not disturb was already on"
setup 1 3
touch "$TMP/override"
run
check "it still acted on the notice that was showing" "$(sets)" 2
check "the user's level is put back, not 0" "$(cat "$TMP/level")" 3

echo "scenario: dunst is not running"
setup 1 0
touch "$TMP/down"
run
check "it exits quietly" "$?" 0
check "and asked for nothing" "$(sets)" 0

echo "scenario: two focus changes at once"
# The second run must not read the first one's temporary level as the user's,
# or it would restore that and leave dunst paused with every later notification
# queued behind it. The second starts while the first is still paused, which is
# the only moment it can go wrong.
setup 1 0
run &
sleep 0.08
run &
wait
check "the level ends where it started" "$(cat "$TMP/level")" 0
check "each run paused and restored" "$(sets)" 4

echo
if [ "$fail" -gt 0 ]; then
    echo "$pass passed, $fail failed"
    exit 1
fi
echo "$pass passed, $fail failed"
