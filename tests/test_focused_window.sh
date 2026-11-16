#!/usr/bin/env bash
# Harness for lib/focused-window: the focused window as "ID x,y WxH", which
# screenshot-region turns into grim -T and screencast-region into -g.
#
# hyprctl is stubbed and answers `-j activewindow` from a file, in the shape the
# real one has -- which is also an empty object when nothing is focused. What is
# asserted is that the three fields come out in that order, that a negative
# position (a monitor to the left of the origin) survives, and that anything
# that is not a window gives nothing and no error, so a caller can test the
# answer for being empty.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/focused-window"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/empty"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

cat > "$TMP/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[ -e "$ANSWER.fails" ] && exit 1
cat "$ANSWER"
EOF
chmod +x "$TMP/bin/hyprctl"
export ANSWER="$TMP/answer"
export PATH="$TMP/bin:$PATH"

answer() { printf '%s\n' "$1" > "$ANSWER"; }

answer '{"address":"0x1","mapped":true,"at":[1287,47],"size":[1709,1386],"stableId":"18000051","class":"kitty"}'
check "id, position, size" "$("$SCRIPT")" "18000051 1287,47 1709x1386"

answer '{"at":[-1280,-40],"size":[1280,720],"stableId":"7f"}'
check "a negative position is kept" "$("$SCRIPT")" "7f -1280,-40 1280x720"

answer '{}'
check "nothing focused: nothing printed" "$("$SCRIPT")" ""
"$SCRIPT" > /dev/null 2>&1
check "and no error" "$?" 0

answer '{"at":[1,2],"size":[3,4]}'
check "no id: nothing" "$("$SCRIPT")" ""

answer 'not json'
check "nonsense: nothing" "$("$SCRIPT")" ""

answer ''
check "silence: nothing" "$("$SCRIPT")" ""

touch "$ANSWER.fails"
check "hyprctl failing: nothing" "$("$SCRIPT")" ""
rm -f "$ANSWER.fails"

PATH="$TMP/empty" "$BASH" "$SCRIPT" > "$TMP/out" 2>&1
check "no hyprctl at all: nothing printed" "$(cat "$TMP/out")" ""

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
