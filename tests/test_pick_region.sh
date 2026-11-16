#!/usr/bin/env bash
# Harness for lib/pick-region: the picker behind both screenshot-region and
# screencast-region, where a drag takes an area and a click takes a window.
#
# hyprctl and slurp are stubbed. hyprctl answers `-j clients` and `-j monitors`
# from JSON files shaped like the real ones -- including the two oddities that
# the script has to allow for: "visible" is true for every window, and a window
# in a special workspace has a name and no id. slurp records its arguments and
# the rectangles it was given on stdin, and answers with whatever the test says
# the user picked. What is asserted is which windows are offered, and what is
# done with the answer. What this cannot check is slurp's own behaviour, that a
# click selects the highlighted rectangle and the smallest one wins; that is
# read from its source, and has to be tried with the mouse.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/pick-region"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/empty" "$TMP/stub"

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
[ -e "$STUB_DIR/hyprctl-fails" ] && exit 1
case "$2" in
    clients) cat "$STUB_DIR/clients.json" ;;
    monitors) cat "$STUB_DIR/monitors.json" ;;
esac
EOF
cat > "$TMP/bin/slurp" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/slurp-args"
cat > "$STUB_DIR/slurp-stdin"
[ -e "$STUB_DIR/cancel" ] && exit 1
cat "$STUB_DIR/pick" 2>/dev/null
exit 0
EOF
chmod +x "$TMP/bin/"*

export STUB_DIR="$TMP/stub"
export PATH="$TMP/bin:$PATH"

# Two monitors: the first on desktop 1 with nothing special open, the second on
# desktop 8 with a special workspace open over it.
cat > "$STUB_DIR/monitors.json" <<'EOF'
[
 {"name":"eDP-1","activeWorkspace":{"id":1,"name":"1"},"specialWorkspace":{"address":"","type":"","name":""}},
 {"name":"DP-4","activeWorkspace":{"id":8,"name":"8"},"specialWorkspace":{"address":"special:quake-8","type":"special","name":"special:quake-8"}}
]
EOF
# window ID WORKSPACE_JSON AT SIZE [mapped] [hidden]
window() {
    printf '{"mapped":%s,"hidden":%s,"visible":true,"at":[%s],"size":[%s],"workspace":%s,"class":"%s","stableId":"id-%s"}' \
        "${5:-true}" "${6:-false}" "$3" "$4" "$2" "$1" "$1"
}
write_clients() {
    local IFS=,
    printf '[%s]\n' "$*" > "$STUB_DIR/clients.json"
}
ws() { printf '{"id":%s,"name":"%s"}' "$1" "$1"; }
special() { printf '{"address":"%s","type":"special","name":"%s"}' "$1" "$1"; }

run() { "$SCRIPT" 2>/dev/null; }
offered() { grep -v '^$' "$STUB_DIR/slurp-stdin" | sort | tr '\n' ';'; }

echo "which windows are offered"
rm -f "$STUB_DIR/cancel" "$STUB_DIR/hyprctl-fails" "$STUB_DIR/pick"
write_clients \
    "$(window shown-1 "$(ws 1)" "7,47" "1266,746")" \
    "$(window shown-8 "$(ws 8)" "1287,47" "1709,1386")" \
    "$(window other-desktop "$(ws 2)" "7,47" "629,746")" \
    "$(window other-desktop-8 "$(ws 3)" "9,9" "10,10")" \
    "$(window quake-open "$(special special:quake-8)" "1280,0" "3440,576")" \
    "$(window quake-closed "$(special special:quake-2)" "0,0" "1280,320")" \
    "$(window teams-closed "$(special special:teams)" "7,47" "1266,746")" \
    "$(window unmapped "$(ws 1)" "50,50" "100,100" false)" \
    "$(window hidden "$(ws 1)" "60,60" "100,100" true true)" \
    "$(window empty "$(ws 1)" "70,70" "0,0")"
echo "5,5 50x50" > "$STUB_DIR/pick"
run > /dev/null
check "windows on the desktops being shown, each with its id" "$(offered)" "1280,0 3440x576 window:id-quake-open;1287,47 1709x1386 window:id-shown-8;7,47 1266x746 window:id-shown-1;"
check "so not another desktop's, though 'visible' says so" "$(offered | grep -c '629x746\|10x10')" 0
check "nor a closed special workspace's" "$(offered | grep -c '1280x320')" 0
check "but the open one's" "$(offered | grep -c '3440x576')" 1
check "nor an unmapped, hidden or empty window" "$(offered | grep -c '100x100\|0x0')" 0
check "slurp is asked for the monitors too, and for the label back" "$(cat "$STUB_DIR/slurp-args")" "-o -f %x,%y %wx%h %l"

echo
echo "a window with no id"
write_clients "$(window shown-1 "$(ws 1)" "7,47" "1266,746")" '{"mapped":true,"hidden":false,"at":[1,1],"size":[5,5],"workspace":{"id":1,"name":"1"}}'
run > /dev/null
check "is not offered, and does not spoil the others" "$(offered)" "7,47 1266x746 window:id-shown-1;"
write_clients \
    "$(window shown-1 "$(ws 1)" "7,47" "1266,746")" \
    "$(window shown-8 "$(ws 8)" "1287,47" "1709,1386")"

echo
echo "what comes back"
echo "100,200 300x400 " > "$STUB_DIR/pick"
check "the pick is passed on" "$(run)" "100,200 300x400"
echo "-1280,0 1280x720" > "$STUB_DIR/pick"
check "a monitor to the left, with a negative x, is fine" "$(run)" "-1280,0 1280x720"

echo
echo "a click on a window"
echo "7,47 1266x746 window:id-shown-1" > "$STUB_DIR/pick"
check "gives the rectangle, then the window's id" "$(run | tr '\n' '|')" "7,47 1266x746|id-shown-1|"
echo "7,47 1266x746 window:id-shown-8" > "$STUB_DIR/pick"
check "a label that belongs to another window's rectangle is no window" "$(run | tr '\n' '|')" "7,47 1266x746|"
echo

echo "an area dragged from over a window"
echo "20,60 300x200 window:id-shown-1" > "$STUB_DIR/pick"
check "keeps slurp's stale label out of it: the area only" "$(run | tr '\n' '|')" "20,60 300x200|"
echo "an area, no label"
echo "20,60 300x200 " > "$STUB_DIR/pick"
check "the area only" "$(run | tr '\n' '|')" "20,60 300x200|"
echo "a click on a monitor"
echo "1920,0 2560x1440 DP-4" > "$STUB_DIR/pick"
check "is its rectangle, and no window" "$(run | tr '\n' '|')" "1920,0 2560x1440|"

echo
echo "a pick that is not a region"
touch "$STUB_DIR/cancel"
run > "$TMP/out"; rc=$?
check "cancelled: non-zero" "$rc" 1
check "cancelled: nothing printed" "$(cat "$TMP/out")" ""
rm -f "$STUB_DIR/cancel"
echo "300,300 1x1 " > "$STUB_DIR/pick"
run > "$TMP/out"; rc=$?
check "a click that hit nothing (1x1): non-zero" "$rc" 1
check "and nothing printed" "$(cat "$TMP/out")" ""
echo "300,300 1x2 " > "$STUB_DIR/pick"
check "1 wide and 2 tall is a real region" "$(run)" "300,300 1x2"
: > "$STUB_DIR/pick"
run > "$TMP/out"; rc=$?
check "an empty answer: non-zero" "$rc" 1

echo
echo "hyprctl not answering"
touch "$STUB_DIR/hyprctl-fails"
echo "10,10 20x20 " > "$STUB_DIR/pick"
check "the pick still works" "$(run)" "10,10 20x20"
check "with no windows offered" "$(offered)" ""
rm -f "$STUB_DIR/hyprctl-fails"

echo
echo "hyprctl giving nonsense"
echo "not json" > "$STUB_DIR/clients.json"
check "the pick still works" "$(run)" "10,10 20x20"
check "with no windows offered" "$(offered)" ""

echo
echo "no windows at all"
echo "[]" > "$STUB_DIR/clients.json"
check "the pick still works" "$(run)" "10,10 20x20"

echo
echo "slurp missing"
PATH="$TMP/empty" "$BASH" "$SCRIPT" >/dev/null 2>&1
check "fails" "$?" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
