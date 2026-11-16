#!/usr/bin/env bash
# Harness for bin/screencast-region: the one key that starts a recording and
# stops it, in its three forms (a selected area or window, the focused window,
# and the focused monitor).
#
# slurp, wf-recorder, notify-send, pkill and hyprctl are stubbed. The
# wf-recorder stub does the two things the script relies on: it writes the file
# it was given, and it finishes on SIGINT rather than on anything harder. It is
# Python because a bash stub cannot catch SIGINT here: a non-interactive shell
# starts its background jobs with it ignored, and a trap cannot undo that, where
# a real program installs its own handler. That is enough to ask what matters:
# does a second press stop the first run and not start another, is a press
# during the selection ignored, does a cancelled selection leave nothing behind,
# is a recorder that produced nothing reported rather than saved, and does the
# bar's pill follow it: on while recording, off after, and no notification in
# between to sit over the screen. lib/capture-saved runs in the foreground here
# (DOTFILES_CAPTURE_SYNC), and has a test of its own.
#
# What this cannot check is the recorder itself. That was run by hand against
# the live session, on a fixed region (reading the screen is harmless): an odd
# 301x203 selection on the scale-1.5 panel came out as a valid 452x304 H.264
# file in yuv420p. The full-screen form hands the focused monitor's name to
# wf-recorder as -o, which is checked here as an argument and not as a capture.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/screencast-region"

TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/empty"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

cat > "$TMP/bin/slurp" <<'EOF'
#!/usr/bin/env bash
echo started >> "$STUB_DIR/slurp-calls"
while [ -e "$STUB_DIR/hold" ]; do sleep 0.05; done
[ -e "$STUB_DIR/cancel" ] && exit 1
if [ -e "$STUB_DIR/pick" ]; then cat "$STUB_DIR/pick"; else echo "10,20 300x200 "; fi
EOF
cat > "$TMP/bin/wf-recorder" <<'EOF'
#!/usr/bin/env python3
import os, signal, sys, time
d = os.environ["STUB_DIR"]
open(d + "/recorder-args", "w").write(" ".join(sys.argv[1:]) + "\n")
out = sys.argv[sys.argv.index("-f") + 1]
if os.path.exists(d + "/fail"):
    sys.exit(1)
def stop(*_):
    open(d + "/recorder-signals", "a").write("int\n")
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
open(out, "w").write("frames\n")
while True:
    time.sleep(0.05)
EOF
cat > "$TMP/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/notices"
EOF
cat > "$TMP/bin/pkill" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/pkill-calls"
EOF
cat > "$TMP/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-j activewindow")
        if [ -e "$STUB_DIR/no-window" ]; then
            echo '{}'
        else
            echo '{"stableId":"abc123","at":[1287,47],"size":[1709,1386]}'
        fi ;;
    "-j clients") echo '[]' ;;
    "-j monitors") echo '[]' ;;
    monitors)
        [ -e "$STUB_DIR/no-focus" ] && exit 0
        printf 'Monitor eDP-1 (ID 0):\n\t1920x1200@60.00000 at 0x0\n\tfocused: no\n'
        printf 'Monitor DP-4 (ID 1):\n\t2560x1440@60.00000 at 1920x0\n\tfocused: yes\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

export STUB_DIR="$TMP/stub"
export XDG_VIDEOS_DIR="$TMP/videos"
export XDG_RUNTIME_DIR="$TMP/run"
export PATH="$TMP/bin:$PATH"
export DOTFILES_CAPTURE_SYNC=1

reset() {
    rm -rf "$STUB_DIR" "$XDG_VIDEOS_DIR" "$XDG_RUNTIME_DIR"
    mkdir -p "$STUB_DIR" "$XDG_RUNTIME_DIR"
}

# until_true CONDITION: poll for up to five seconds, and succeed when it holds.
until_true() {
    for _ in $(seq 100); do
        eval "$1" && return 0
        sleep 0.05
    done
    return 1
}

pidfile="$XDG_RUNTIME_DIR/screencast-region.pid"
files() { ls "$XDG_VIDEOS_DIR/Screencasts" 2>/dev/null | wc -l; }
notices() { cat "$STUB_DIR/notices" 2>/dev/null; }

echo "start, then stop with a second press"
reset
"$SCRIPT" & first=$!
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
check "recording begins" "$([ -s "$pidfile" ] && echo yes || echo no)" yes
check "the pill is on" "$("$SCRIPT" --status)" "● REC"
check "the bar was told it started" "$(grep -c . "$STUB_DIR/pkill-calls")" 1
"$SCRIPT"
check "the second press returns at once" "$?" 0
until_true '! kill -0 '"$first"' 2>/dev/null'
check "the first run ends once stopped" "$(kill -0 "$first" 2>/dev/null && echo alive || echo gone)" gone
check "the recorder got SIGINT" "$(cat "$STUB_DIR/recorder-signals" 2>/dev/null)" int
check "one file was kept" "$(files)" 1
check "it is an mp4 in yuv420p" "$(grep -oE -- '-x yuv420p|\.mp4' "$STUB_DIR/recorder-args" | tr '\n' ' ')" "-x yuv420p .mp4 "
check "the region reached the recorder" "$(grep -c -- '-g 10,20 300x200' "$STUB_DIR/recorder-args")" 1
check "the result is announced" "$(notices | grep -c 'Screencast saved')" 1
check "the notice is for the file, so following opens it" "$(notices | grep -c 'screencast-.*\.mp4')" 1
check "no other notice while it records" "$(notices | grep -c -- '--app-name')" 1
check "the bar was told twice, by the right name" "$(grep -cx -- '-x -RTMIN+8 waybar' "$STUB_DIR/pkill-calls")" 2
check "the pid file is gone" "$([ -e "$pidfile" ] && echo left || echo gone)" gone
check "the pill is off again" "$("$SCRIPT" --status)" ""

echo
echo "the whole screen"
reset
"$SCRIPT" --screen & first=$!
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
check "records" "$([ -s "$pidfile" ] && echo yes || echo no)" yes
check "names the focused monitor" "$(grep -c -- '-o DP-4' "$STUB_DIR/recorder-args")" 1
check "does not name a region" "$(grep -c -- '-g' "$STUB_DIR/recorder-args")" 0
check "asks for no selection" "$([ -e "$STUB_DIR/slurp-calls" ] && echo yes || echo no)" no
check "the pill is on" "$("$SCRIPT" --status)" "● REC"
"$SCRIPT"
until_true '! kill -0 '"$first"' 2>/dev/null'
check "the region key stops it too" "$(kill -0 "$first" 2>/dev/null && echo alive || echo gone)" gone
check "the file was kept" "$(files)" 1

echo
echo "a window clicked in the picker"
reset
echo "50,60 400x300 window:55" > "$STUB_DIR/pick"
"$SCRIPT" & first=$!
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
check "records its rectangle, and the id is not in it" "$(grep -c -- '-g 50,60 400x300 -x' "$STUB_DIR/recorder-args")" 1
"$SCRIPT"
wait "$first"

echo
echo "the focused window"
reset
"$SCRIPT" --window & first=$!
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
check "records" "$([ -s "$pidfile" ] && echo yes || echo no)" yes
check "records its rectangle" "$(grep -c -- '-g 1287,47 1709x1386' "$STUB_DIR/recorder-args")" 1
check "asks for no selection" "$([ -e "$STUB_DIR/slurp-calls" ] && echo yes || echo no)" no
"$SCRIPT" --screen
until_true '! kill -0 '"$first"' 2>/dev/null'
check "any of the keys stops it" "$(kill -0 "$first" 2>/dev/null && echo alive || echo gone)" gone
check "the file was kept" "$(files)" 1

echo
echo "no focused window"
reset
touch "$STUB_DIR/no-window"
"$SCRIPT" --window 2>/dev/null
check "fails" "$?" 1
check "starts no recorder" "$([ -e "$STUB_DIR/recorder-args" ] && echo yes || echo no)" no
check "says why" "$(notices | grep -c 'No window is focused')" 1
check "releases the lock for the next press" "$(flock -n "$XDG_RUNTIME_DIR/screencast-region.lock" true && echo free || echo held)" free

echo
echo "the whole screen, stopped by the whole-screen key"
reset
"$SCRIPT" & first=$!
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
"$SCRIPT" --screen
until_true '! kill -0 '"$first"' 2>/dev/null'
check "stops a region recording" "$(kill -0 "$first" 2>/dev/null && echo alive || echo gone)" gone
check "and starts nothing" "$(ls "$XDG_VIDEOS_DIR/Screencasts" | wc -l)" 1

echo
echo "no focused monitor"
reset
touch "$STUB_DIR/no-focus"
"$SCRIPT" --screen 2>/dev/null
check "fails" "$?" 1
check "starts no recorder" "$([ -e "$STUB_DIR/recorder-args" ] && echo yes || echo no)" no
check "says why" "$(notices | grep -c 'which monitor')" 1
check "releases the lock for the next press" "$(flock -n "$XDG_RUNTIME_DIR/screencast-region.lock" true && echo free || echo held)" free

echo
echo "a press during the selection"
reset
touch "$STUB_DIR/hold"
"$SCRIPT" & first=$!
until_true '[ -s "$STUB_DIR/slurp-calls" ]'
"$SCRIPT"
check "does not open a second selection" "$(wc -l < "$STUB_DIR/slurp-calls")" 1
check "does not signal anything" "$([ -e "$STUB_DIR/recorder-signals" ] && echo yes || echo no)" no
rm "$STUB_DIR/hold"
until_true '[ -s "$pidfile" ] && [ "$(files)" = 1 ]'
check "the first one then goes on to record" "$([ -s "$pidfile" ] && echo yes || echo no)" yes
"$SCRIPT"
wait "$first"

echo
echo "a cancelled selection"
reset
touch "$STUB_DIR/cancel"
"$SCRIPT"
check "exits quietly" "$?" 0
check "starts no recorder" "$([ -e "$STUB_DIR/recorder-args" ] && echo yes || echo no)" no
check "makes no file" "$(files)" 0
check "says nothing" "$(notices | wc -l)" 0
check "does not touch the bar" "$([ -e "$STUB_DIR/pkill-calls" ] && echo yes || echo no)" no
check "releases the lock for the next press" "$(flock -n "$XDG_RUNTIME_DIR/screencast-region.lock" true && echo free || echo held)" free

echo
echo "a recorder that produces nothing"
reset
touch "$STUB_DIR/fail"
"$SCRIPT" 2>/dev/null
check "exits non-zero" "$?" 1
check "keeps no empty file" "$(files)" 0
check "reports the failure" "$(notices | grep -c 'Recording failed')" 1
check "does not claim it saved" "$(notices | grep -c 'saved')" 0

echo
echo "a stale pid file"
reset
echo 999999 > "$pidfile"
"$SCRIPT" & first=$!
until_true '[ "$(cat "$pidfile" 2>/dev/null)" != 999999 ] && [ "$(files)" = 1 ]'
check "is replaced rather than signalled" "$(grep -c . "$pidfile")" 1
"$SCRIPT"
wait "$first"
check "the recording was still saved" "$(files)" 1

echo
echo "the pill's status"
reset
check "idle: nothing" "$("$SCRIPT" --status)" ""
echo 999999 > "$pidfile"
check "a pid file naming a dead process: nothing" "$("$SCRIPT" --status)" ""
sleep 30 & sleeper=$!
echo "$sleeper" > "$pidfile"
check "a live pid: the pill" "$("$SCRIPT" --status)" "● REC"
kill "$sleeper"; wait "$sleeper" 2>/dev/null
check "--status takes no lock" "$(flock -n "$XDG_RUNTIME_DIR/screencast-region.lock" true && echo free || echo held)" free

echo
echo "an argument it does not know"
reset
"$SCRIPT" --nonsense 2>/dev/null
check "is a usage error" "$?" 2

echo
echo "a missing tool"
reset
PATH="$TMP/empty" "$BASH" "$SCRIPT" 2>/dev/null
check "fails rather than doing nothing silently" "$?" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
