#!/usr/bin/env bash
# Harness for lib/indicator: the lines behind Waybar's camera, microphone and
# Caps Lock pills.
#
# The sysfs files it reads are replaced by files in a scratch directory, and
# pactl is stubbed: `get-source-mute` answers from a file, and `subscribe`
# follows a file that the test appends events to, which is how PulseAudio's
# event stream is imitated. Each indicator runs for real, in its own process
# group so that killing it takes its pactl with it, and writes to a file the test
# reads; its waits are shortened so a change shows within a fraction of a second.
#
# What is asserted is what the pills depend on: that a line is printed when the
# state changes and not otherwise, that the mic is re-read on a source event and
# not on an unrelated one, that a line is repeated on the heartbeat, and that a
# process whose reader has gone away exits instead of lingering. What this
# cannot check is the hardware: that the LED follows the key (the kernel's and
# Hyprland's job) and that uvcvideo's use count follows an open camera, which
# was checked once by hand.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/indicator"

TMP="$(mktemp -d)"
trap 'for p in "${groups[@]:-}"; do [ -n "$p" ] && kill -- "-$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
groups=()
mkdir -p "$TMP/bin" "$TMP/leds" "$TMP/stub"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

cat > "$TMP/bin/pactl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    get-source-mute)
        echo "$*" >> "$STUB_DIR/queries"
        [ -e "$STUB_DIR/pactl-fails" ] && exit 1
        echo "Mute: $(cat "$STUB_DIR/mute")" ;;
    subscribe)
        echo started >> "$STUB_DIR/subscribes"
        [ -e "$STUB_DIR/subscribe-ends" ] && exit 0
        exec tail -n0 -F "$STUB_DIR/events" ;;
esac
EOF
chmod +x "$TMP/bin/pactl"

export STUB_DIR="$TMP/stub"
export PATH="$TMP/bin:$PATH"
export XDG_RUNTIME_DIR="$TMP"
export INDICATOR_LEDS_DIR="$TMP/leds"
export INDICATOR_CAMERA_REFCNT="$TMP/refcnt"
export INDICATOR_TICK=0.05
export INDICATOR_HEARTBEAT=600
export INDICATOR_RETRY=0.2

: > "$STUB_DIR/events"
echo yes > "$STUB_DIR/mute"

CAMERA=$'\uf030 CAMERA'
MIC=$'\uf130 MIC'
CAPS=$'\u21ea CAPS'

# start NAME ARG: run the indicator in its own group, output in $TMP/NAME.
start() {
    : > "$TMP/$1"
    setsid "$SCRIPT" "$2" > "$TMP/$1" 2>/dev/null &
    groups+=("$!")
    started=$!
}
stop() { kill -- "-$1" 2>/dev/null; wait "$1" 2>/dev/null; }
lines() { wc -l < "$TMP/$1"; }
lastline() { tail -1 "$TMP/$1"; }
until_true() {
    for _ in $(seq 100); do
        eval "$1" && return 0
        sleep 0.05
    done
    return 1
}
settle() { sleep 0.4; }

echo "caps lock"
mkdir -p "$TMP/leds/input3::capslock" "$TMP/leds/input21::capslock"
echo 0 > "$TMP/leds/input3::capslock/brightness"
echo 0 > "$TMP/leds/input21::capslock/brightness"
start caps caps; pid=$started
until_true '[ "$(lines caps)" -ge 1 ]'
check "starts with one empty line, so the pill is hidden" "$(lastline caps)|$(lines caps)" "|1"
settle
check "prints nothing while nothing changes" "$(lines caps)" 1
echo 1 > "$TMP/leds/input3::capslock/brightness"
until_true '[ "$(lastline caps)" = "$CAPS" ]'
check "one keyboard on shows the pill" "$(lastline caps)" "$CAPS"
echo 1 > "$TMP/leds/input21::capslock/brightness"
settle
check "a second one on changes nothing" "$(lines caps)" 2
echo 0 > "$TMP/leds/input3::capslock/brightness"
settle
check "one still on keeps the pill" "$(lastline caps)" "$CAPS"
echo 0 > "$TMP/leds/input21::capslock/brightness"
until_true '[ -z "$(lastline caps)" ]'
check "all off hides it again" "$(lastline caps)|$(lines caps)" "|3"
stop "$pid"

echo
echo "caps lock with no keyboard LED at all"
rm -rf "$TMP/leds"; mkdir -p "$TMP/leds"
start caps-none caps; pid=$started
until_true '[ "$(lines caps-none)" -ge 1 ]'
check "is just empty" "$(lastline caps-none)|$(lines caps-none)" "|1"
stop "$pid"

echo
echo "camera"
echo 0 > "$TMP/refcnt"
start cam camera; pid=$started
until_true '[ "$(lines cam)" -ge 1 ]'
check "idle: empty" "$(lastline cam)|$(lines cam)" "|1"
echo 1 > "$TMP/refcnt"
until_true '[ "$(lastline cam)" = "$CAMERA" ]'
check "open: the pill" "$(lastline cam)" "$CAMERA"
echo 2 > "$TMP/refcnt"
settle
check "a second program opening it changes nothing" "$(lines cam)" 2
echo 0 > "$TMP/refcnt"
until_true '[ -z "$(lastline cam)" ]'
check "closed: hidden again" "$(lastline cam)|$(lines cam)" "|3"
stop "$pid"

echo
echo "camera driver not loaded"
rm -f "$TMP/refcnt"
start cam-none camera; pid=$started
until_true '[ "$(lines cam-none)" -ge 1 ]'
check "is just empty" "$(lastline cam-none)|$(lines cam-none)" "|1"
stop "$pid"

echo
echo "microphone"
echo yes > "$STUB_DIR/mute"; rm -f "$STUB_DIR/queries"
start mic mic; pid=$started
until_true '[ "$(lines mic)" -ge 1 ]'
check "muted: empty" "$(lastline mic)|$(lines mic)" "|1"
check "it asked for the default source" "$(head -1 "$STUB_DIR/queries")" "get-source-mute @DEFAULT_SOURCE@"
until_true '[ -s "$STUB_DIR/subscribes" ]'
sleep 0.3
queries=$(wc -l < "$STUB_DIR/queries")
echo no > "$STUB_DIR/mute"
echo "Event 'change' on source-output #12" >> "$STUB_DIR/events"
settle
check "an unrelated event does not re-read it" "$(wc -l < "$STUB_DIR/queries")" "$queries"
check "and so the pill is not shown yet" "$(lastline mic)" ""
echo "Event 'change' on source #67" >> "$STUB_DIR/events"
until_true '[ "$(lastline mic)" = "$MIC" ]'
check "a source event shows it when unmuted" "$(lastline mic)" "$MIC"
echo yes > "$STUB_DIR/mute"
echo "Event 'change' on source #67" >> "$STUB_DIR/events"
until_true '[ -z "$(lastline mic)" ]'
check "and hides it when muted again" "$(lastline mic)|$(lines mic)" "|3"
echo no > "$STUB_DIR/mute"
echo "Event 'change' on server" >> "$STUB_DIR/events"
until_true '[ "$(lastline mic)" = "$MIC" ]'
check "a change of default source is noticed too" "$(lastline mic)" "$MIC"
stop "$pid"
check "its pactl is gone with it" "$(pgrep -fc "tail -n0 -F $STUB_DIR/events")" 0

echo
echo "microphone: audio server unreachable"
touch "$STUB_DIR/pactl-fails"
start mic-down mic; pid=$started
until_true '[ "$(lines mic-down)" -ge 1 ]'
check "is empty, not an error" "$(lastline mic-down)|$(lines mic-down)" "|1"
stop "$pid"
rm -f "$STUB_DIR/pactl-fails"

echo
echo "microphone: the event stream ends"
echo no > "$STUB_DIR/mute"; rm -f "$STUB_DIR/subscribes"
touch "$STUB_DIR/subscribe-ends"
start mic-restart mic; pid=$started
until_true '[ "$(wc -l < "$STUB_DIR/subscribes" 2>/dev/null || echo 0)" -ge 3 ]'
check "subscribes again rather than giving up" "$([ "$(wc -l < "$STUB_DIR/subscribes")" -ge 3 ] && echo yes || echo no)" yes
check "and still shows the state" "$(lastline mic-restart)" "$MIC"
check "without repeating itself" "$(lines mic-restart)" 1
stop "$pid"
rm -f "$STUB_DIR/subscribe-ends"

echo
echo "the heartbeat"
echo 0 > "$TMP/refcnt"
: > "$TMP/beat"
INDICATOR_HEARTBEAT=1 setsid "$SCRIPT" camera > "$TMP/beat" 2>/dev/null &
pid=$!; groups+=("$pid")
sleep 3.3
check "repeats the line while nothing changes" "$([ "$(lines beat)" -ge 3 ] && echo yes || echo no)" yes
stop "$pid"

echo
echo "a reader that has gone"
start=$SECONDS
INDICATOR_HEARTBEAT=1 "$SCRIPT" camera 2>/dev/null | head -1 > /dev/null
check "the indicator exits instead of lingering" "$([ $((SECONDS - start)) -le 4 ] && echo yes || echo no)" yes

echo
echo "an argument it does not know"
"$SCRIPT" nonsense 2>/dev/null
check "is a usage error" "$?" 2

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
