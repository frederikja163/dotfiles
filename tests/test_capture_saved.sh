#!/usr/bin/env bash
# Harness for lib/capture-saved: the notice that follows a screenshot or a
# screencast, what following it does, and the deleting of old captures.
#
# notify-send and kitty are stubbed. The notify-send stub records its arguments
# and, when asked, answers "default" the way it does when the notice is clicked
# or followed with SUPER+N; otherwise it answers nothing, as for one that
# timed out. Ages are real: files are given modification times with touch -d.
# What this cannot check is dunst showing the notice, or yazi putting the
# cursor on the file; the second is only the argument handed to kitty.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/lib/capture-saved"

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

cat > "$TMP/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$STUB_DIR/notice"
echo >> "$STUB_DIR/notice"
[ -e "$STUB_DIR/slow" ] && sleep 2
[ -e "$STUB_DIR/follow" ] && echo default
exit 0
EOF
cat > "$TMP/bin/kitty" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/kitty-args"
EOF
chmod +x "$TMP/bin/"*

export STUB_DIR="$TMP/stub"
export PATH="$TMP/bin:$PATH"
export DOTFILES_CAPTURE_SYNC=1
dir="$TMP/captures"

reset() {
    rm -rf "$STUB_DIR" "$dir"
    mkdir -p "$STUB_DIR" "$dir"
}
# make FILE AGE_IN_DAYS
make() { echo data > "$dir/$1"; touch -d "$2 days ago" "$dir/$1"; }
exists() { [ -e "$dir/$1" ] && echo yes || echo no; }
until_true() {
    for _ in $(seq 100); do
        eval "$1" && return 0
        sleep 0.05
    done
    return 1
}

echo "the notice"
reset
make screenshot-new.png 0
"$SCRIPT" "Region copied and saved" "$dir/screenshot-new.png"
notice="$(cat "$STUB_DIR/notice")"
check "it is sent, once" "$(grep -c -- '--app-name' "$STUB_DIR/notice")" 1
check "for eight seconds, long enough to click" "$(echo "$notice" | grep -c -- '--expire-time=8000')" 1
check "with a default action, which click and SUPER+N follow" "$(echo "$notice" | grep -c -- '--action=default=Open')" 1
check "the summary is what it was given" "$(echo "$notice" | grep -c 'Region copied and saved')" 1
check "it names the file" "$(echo "$notice" | grep -c 'screenshot-new.png')" 1
check "a screenshot is its own icon" "$(echo "$notice" | grep -c -- "--icon=$dir/screenshot-new.png")" 1
make screencast-new.mp4 0
"$SCRIPT" "Screencast saved" "$dir/screencast-new.mp4"
check "a video gets a generic one" "$(grep -c -- '--icon=video-x-generic' "$STUB_DIR/notice")" 1

echo
echo "following it"
reset
make screenshot-new.png 0
touch "$STUB_DIR/follow"
"$SCRIPT" "Saved" "$dir/screenshot-new.png"
until_true '[ -s "$STUB_DIR/kitty-args" ]'
check "opens yazi in kitty, in the folder, on the file" "$(cat "$STUB_DIR/kitty-args" 2>/dev/null)" "--directory $dir yazi $dir/screenshot-new.png"

echo
echo "letting it time out"
reset
make screenshot-new.png 0
"$SCRIPT" "Saved" "$dir/screenshot-new.png"
sleep 0.3
check "opens nothing" "$([ -e "$STUB_DIR/kitty-args" ] && echo yes || echo no)" no

echo
echo "deleting old captures"
reset
make screenshot-old.png 31
make screenshot-recent.png 29
make screenshot-new.png 0
make screencast-old.mp4 45
make screencast-recent.mp4 10
make notes-old.txt 90
make other.png 90
"$SCRIPT" "Saved" "$dir/screenshot-new.png"
check "a screenshot over thirty days is deleted" "$(exists screenshot-old.png)" no
check "one under thirty is kept" "$(exists screenshot-recent.png)" yes
check "the one just taken is kept" "$(exists screenshot-new.png)" yes
check "a recording is not pruned by a screenshot" "$(exists screencast-old.mp4)" yes
make screencast-new.mp4 0
"$SCRIPT" "Saved" "$dir/screencast-new.mp4"
check "but is by the next recording, when over thirty days" "$(exists screencast-old.mp4)" no
check "one under thirty is kept" "$(exists screencast-recent.mp4)" yes
check "and the screenshots are left as they were" "$(exists screenshot-recent.png)" yes
check "a file with another prefix is never touched" "$(exists notes-old.txt)" yes
check "nor one with no prefix" "$(exists other.png)" yes

echo
echo "the age is the modification time"
reset
make screenshot-read.png 40
touch -a -d "now" "$dir/screenshot-read.png"
make screenshot-new.png 0
"$SCRIPT" "Saved" "$dir/screenshot-new.png"
check "opening a file does not give it another thirty days" "$(exists screenshot-read.png)" no

echo
echo "the number of days can be changed"
reset
make screenshot-a.png 8
make screenshot-b.png 6
make screenshot-new.png 0
DOTFILES_CAPTURE_KEEP_DAYS=7 "$SCRIPT" "Saved" "$dir/screenshot-new.png"
check "older than that goes" "$(exists screenshot-a.png)" no
check "younger stays" "$(exists screenshot-b.png)" yes

echo
echo "another folder is left alone"
reset
mkdir -p "$TMP/elsewhere"
echo data > "$TMP/elsewhere/screenshot-old.png"; touch -d "90 days ago" "$TMP/elsewhere/screenshot-old.png"
make screenshot-new.png 0
"$SCRIPT" "Saved" "$dir/screenshot-new.png"
check "only the capture's own folder is pruned" "$([ -e "$TMP/elsewhere/screenshot-old.png" ] && echo yes || echo no)" yes

echo
echo "detaching"
reset
make screenshot-new.png 0
touch "$STUB_DIR/slow"
start=$SECONDS
# The lock is taken in a subshell that then exits, so the only thing that can
# still hold it afterwards is the detached run, if it kept the descriptor.
( exec 9>"$TMP/lock"; flock -n 9; DOTFILES_CAPTURE_SYNC=0 "$SCRIPT" "Saved" "$dir/screenshot-new.png" )
check "returns without waiting for the notice" "$((SECONDS - start))" 0
check "the notice is sent regardless" "$(until_true '[ -s "$STUB_DIR/notice" ]' && echo yes || echo no)" yes
check "does not keep the caller's lock on fd 9" "$(flock -n "$TMP/lock" true && echo free || echo held)" free

echo
echo "bad usage"
reset
"$SCRIPT" 2>/dev/null
check "no arguments is a usage error" "$?" 2
"$SCRIPT" "Saved" "$dir/missing.png" 2>/dev/null
check "a file that is not there is one too" "$?" 2

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
