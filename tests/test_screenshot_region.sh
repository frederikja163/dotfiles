#!/usr/bin/env bash
# Harness for bin/screenshot-region, in its three forms: a selected area or
# window, the focused window, and the whole of the focused monitor.
#
# grim, wl-copy, slurp, notify-send and hyprctl are stubbed, so what is under
# test is which arguments reach grim, that the picture ends up both in a file
# and on the clipboard, and that a cancelled selection, a failed capture or an
# unknown focus leaves both alone. The stub grim writes the file it is given,
# which is what the clipboard stub then reads, so a copy is told from nothing
# having happened. A window is asked of grim by id (-T) and an area by
# geometry (-g), which is the thing most worth checking here. lib/capture-saved runs in the foreground here
# (DOTFILES_CAPTURE_SYNC) and has a test of its own. What this cannot check is a
# real capture; that is grim's.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/screenshot-region"

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

cat > "$TMP/bin/slurp" <<'EOF'
#!/usr/bin/env bash
echo started >> "$STUB_DIR/slurp-calls"
[ -e "$STUB_DIR/cancel" ] && exit 1
if [ -e "$STUB_DIR/pick" ]; then cat "$STUB_DIR/pick"; else echo "10,20 300x200 "; fi
EOF
cat > "$TMP/bin/grim" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/grim-args"
out="${@: -1}"
echo png > "$out"
[ -e "$STUB_DIR/grim-fails" ] && exit 1
exit 0
EOF
cat > "$TMP/bin/wl-copy" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/copy-args"
[ -e "$STUB_DIR/copy-fails" ] && exit 1
cat > "$STUB_DIR/clipboard"
EOF
cat > "$TMP/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/notices"
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
    "-j clients")
        cat "$STUB_DIR/clients.json" 2>/dev/null || echo '[]' ;;
    "-j monitors")
        echo '[{"name":"DP-4","activeWorkspace":{"id":8},"specialWorkspace":{"name":""}}]' ;;
    monitors)
        [ -e "$STUB_DIR/no-focus" ] && exit 0
        printf 'Monitor eDP-1 (ID 0):\n\tfocused: no\n'
        printf 'Monitor DP-4 (ID 1):\n\tfocused: yes\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

export STUB_DIR="$TMP/stub"
export XDG_PICTURES_DIR="$TMP/pictures"
export PATH="$TMP/bin:$PATH"
export DOTFILES_CAPTURE_SYNC=1

reset() { rm -rf "$STUB_DIR" "$XDG_PICTURES_DIR"; mkdir -p "$STUB_DIR"; }
notices() { cat "$STUB_DIR/notices" 2>/dev/null; }
clipboard() { cat "$STUB_DIR/clipboard" 2>/dev/null; }
files() { ls "$XDG_PICTURES_DIR/Screenshots" 2>/dev/null | wc -l; }
saved() { ls "$XDG_PICTURES_DIR/Screenshots/"* 2>/dev/null | head -1; }

echo "a region"
reset
"$SCRIPT"
check "succeeds" "$?" 0
check "grim gets the selection and the file" "$(sed "s|$XDG_PICTURES_DIR|P|" "$STUB_DIR/grim-args" | sed -E 's/[0-9]{4}-[0-9-]+_[0-9-]+/STAMP/')" "-g 10,20 300x200 P/Screenshots/screenshot-STAMP.png"
check "one file is kept" "$(files)" 1
check "the image is on the clipboard as a png" "$(clipboard) $(cat "$STUB_DIR/copy-args")" "png --type image/png"
check "it says so" "$(notices | grep -c 'Area copied and saved')" 1
check "and the notice is for the file" "$(notices | grep -c "$(basename "$(saved)")")" 1

echo
echo "a window clicked in the picker"
reset
echo '[{"mapped":true,"hidden":false,"at":[1287,47],"size":[1709,1386],"workspace":{"id":8,"name":"8"},"stableId":"55"}]' > "$STUB_DIR/clients.json"
echo "1287,47 1709x1386 window:55" > "$STUB_DIR/pick"
"$SCRIPT"
check "succeeds" "$?" 0
check "grim is asked for the window by id, not by geometry" "$(sed 's|[^ ]*\.png$|FILE|' "$STUB_DIR/grim-args")" "-T 55 FILE"
check "the image is on the clipboard" "$(clipboard)" png
check "it says a window" "$(notices | grep -c 'Window copied and saved')" 1

echo
echo "an area dragged from over a window"
reset
echo '[{"mapped":true,"hidden":false,"at":[1287,47],"size":[1709,1386],"workspace":{"id":8,"name":"8"},"stableId":"55"}]' > "$STUB_DIR/clients.json"
echo "20,60 300x200 window:55" > "$STUB_DIR/pick"
"$SCRIPT"
check "is still taken as an area, by geometry" "$(sed 's|[^ ]*\.png$|FILE|' "$STUB_DIR/grim-args")" "-g 20,60 300x200 FILE"
check "and says an area" "$(notices | grep -c 'Area copied and saved')" 1

echo
echo "the focused window"
reset
"$SCRIPT" --window
check "succeeds" "$?" 0
check "grim is asked for it by id" "$(sed 's|[^ ]*\.png$|FILE|' "$STUB_DIR/grim-args")" "-T abc123 FILE"
check "no selection is asked for" "$([ -e "$STUB_DIR/slurp-calls" ] && echo yes || echo no)" no
check "the image is on the clipboard" "$(clipboard)" png
check "one file is kept" "$(files)" 1
check "it says a window" "$(notices | grep -c 'Window copied and saved')" 1

echo
echo "no focused window"
reset
touch "$STUB_DIR/no-window"
"$SCRIPT" --window 2>/dev/null
check "fails" "$?" 1
check "grim is never run" "$([ -e "$STUB_DIR/grim-args" ] && echo yes || echo no)" no
check "says why" "$(notices | grep -c 'No window is focused')" 1

echo
echo "a cancelled selection"
reset
touch "$STUB_DIR/cancel"
"$SCRIPT"
check "exits quietly" "$?" 0
check "grim is never run" "$([ -e "$STUB_DIR/grim-args" ] && echo yes || echo no)" no
check "nothing is copied" "$([ -e "$STUB_DIR/clipboard" ] && echo yes || echo no)" no
check "nothing is saved" "$(files)" 0

echo
echo "the whole screen"
reset
"$SCRIPT" --screen
check "succeeds" "$?" 0
check "grim gets the focused monitor" "$(grep -c -- '-o DP-4 ' "$STUB_DIR/grim-args")" 1
check "no selection is asked for" "$([ -e "$STUB_DIR/slurp-calls" ] && echo yes || echo no)" no
check "the image is on the clipboard" "$(clipboard)" png
check "one file is kept" "$(files)" 1
check "it says so" "$(notices | grep -c 'Screen copied and saved')" 1

echo
echo "no focused monitor"
reset
touch "$STUB_DIR/no-focus"
"$SCRIPT" --screen 2>/dev/null
check "fails" "$?" 1
check "grim is never run, which would have taken every screen" "$([ -e "$STUB_DIR/grim-args" ] && echo yes || echo no)" no
check "says why" "$(notices | grep -c 'which monitor')" 1

echo
echo "a failed capture"
for form in "" "--screen" "--window"; do
    reset
    touch "$STUB_DIR/grim-fails"
    "$SCRIPT" $form 2>/dev/null
    check "${form:-region}: exits non-zero" "$?" 1
    check "${form:-region}: says it failed" "$(notices | grep -c 'Capture failed')" 1
    check "${form:-region}: keeps no half-written file" "$(files)" 0
    check "${form:-region}: copies nothing" "$([ -e "$STUB_DIR/clipboard" ] && echo yes || echo no)" no
    check "${form:-region}: does not claim a save" "$(notices | grep -c 'saved')" 0
done

echo
echo "a clipboard that will not take it"
reset
touch "$STUB_DIR/copy-fails"
"$SCRIPT" 2>/dev/null
check "exits non-zero" "$?" 1
check "the file is kept, since it was taken" "$(files)" 1
check "says the copy failed" "$(notices | grep -c 'could not copy')" 1

echo
echo "an argument it does not know"
reset
"$SCRIPT" --nonsense 2>/dev/null
check "is a usage error" "$?" 2

echo
echo "a missing tool"
PATH="$TMP/empty" "$BASH" "$SCRIPT" --screen 2>/dev/null
check "fails rather than doing nothing silently" "$?" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
