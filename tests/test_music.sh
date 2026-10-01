#!/usr/bin/env bash
# Harness for bin/music, bin/music-get, and install.sh's seeding rule.
#
# Nothing here touches the network. bin/music-get's download is not testable
# offline and should not be: asserting against archive.org would make the suite
# fail when a mirror is slow, which is the opposite of what the script is for.
# What is testable is everything around it -- the queue bin/music builds, the
# gate install.sh makes out of `music --list`, and music-get reporting a
# failure rather than swallowing it.
#
# The network is cut off rather than stubbed, by pointing urllib at a proxy
# address that cannot answer. That exercises the real urllib path and the real
# exception handling, which a stubbed fetch() would skip straight past.
#
# The seeding rule is checked by running the real seed_music out of install.sh
# rather than a copy of it. install.sh dispatches on $1 at the end, so it
# cannot simply be sourced; the function is cut out by sed and run with a
# stubbed music-get that records whether it was called. A reimplementation here
# would pass while install.sh itself was wrong, which is the only failure worth
# catching -- that gate is the difference between seeding a fresh machine and
# dumping 600MB onto a collection someone curated.
#
# MUSIC_DIR is how both scripts are aimed at a scratch directory; it exists for
# this harness and is documented in both.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
PLAY="$REPO/bin/music"
GET="$REPO/bin/music-get"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

# An unroutable address from the reserved TEST-NET-1 block, so a connection
# attempt dies in the stack and never leaves the machine.
offline() {
    MUSIC_GET_DEADLINE=5 \
    http_proxy="http://192.0.2.1:9" https_proxy="http://192.0.2.1:9" \
    "$GET" "$@"
}

# A directory of audio files with the kind of names these releases really have.
populate() {
    local d="$1"; shift
    mkdir -p "$d"
    local n
    for n in "$@"; do : > "$d/$n"; done
}

echo "scenario: music --list is the single answer to what counts as music"
# install.sh's gate is this command printing nothing, so the extension list
# lives in bin/music alone rather than being copied into install.sh and
# bin/music-get.
d="$TMP/kinds"
populate "$d" "a track.mp3" "it's here.flac" "[brackets].ogg" "x.opus" \
               "y.m4a" "z.wav" "q.aac" "r.wma" "notes.txt" "playlist.m3u8"
check "all eight audio extensions" "$(MUSIC_DIR="$d" "$PLAY" --list | wc -l)" 8
check "and nothing else" \
    "$(MUSIC_DIR="$d" "$PLAY" --list | grep -cE '\.(txt|m3u8)$')" 0
check "quoted names survive whole" \
    "$(MUSIC_DIR="$d" "$PLAY" --list | grep -c "it's here.flac")" 1
check "exit 0" "$(MUSIC_DIR="$d" "$PLAY" --list >/dev/null 2>&1; printf '%s' "$?")" 0

echo "scenario: an empty or missing directory lists nothing, and is not an error"
# Nothing to list has to be distinguishable from a broken script, or the gate
# in install.sh cannot tell "no music yet" from "something went wrong".
d="$TMP/bare"; mkdir -p "$d"
check "empty: no output" "$(MUSIC_DIR="$d" "$PLAY" --list | wc -l)" 0
check "empty: exit 0" "$(MUSIC_DIR="$d" "$PLAY" --list >/dev/null 2>&1; printf '%s' "$?")" 0
check "missing: no output" "$(MUSIC_DIR="$TMP/absent" "$PLAY" --list | wc -l)" 0
check "missing: exit 0" \
    "$(MUSIC_DIR="$TMP/absent" "$PLAY" --list >/dev/null 2>&1; printf '%s' "$?")" 0
check "missing: still not created" "$([ -e "$TMP/absent" ] && echo yes || echo no)" no

echo "scenario: non-audio clutter does not read as a seeded directory"
# A leftover playlist or a stray note is not music, so install.sh still seeds.
d="$TMP/clutter"
populate "$d" "playlist.m3u8" "notes.txt"
check "lists nothing" "$(MUSIC_DIR="$d" "$PLAY" --list | wc -l)" 0

echo "scenario: install.sh seeds only a directory with no audio in it"
# The real function, cut out of install.sh, with music-get stubbed.
cat > "$TMP/seed-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
DOTFILES="$1"
eval "$(sed -n '/^seed_music() {/,/^}/p' "$DOTFILES/install.sh")"
seed_music
HARNESS
chmod +x "$TMP/seed-harness.sh"

# A fake repo whose bin/music defers to the real one, and whose music-get only
# records that it ran and with what.
fake="$TMP/fakerepo"; mkdir -p "$fake/bin"
cp "$REPO/install.sh" "$fake/install.sh"
cp "$REPO/bin/music" "$fake/bin/music"
cat > "$fake/bin/music-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GET_LOG:?}"
STUB
chmod +x "$fake/bin/music-get"

seeded() {
    export GET_LOG="$TMP/get.log"; : > "$GET_LOG"
    MUSIC_DIR="$1" HOME="$1/.." "$TMP/seed-harness.sh" "$fake" >/dev/null 2>&1
    printf '%s' "$(wc -l < "$GET_LOG")"
}

d="$TMP/fresh"; mkdir -p "$d"
check "an empty directory is seeded" "$(seeded "$d")" 1
check "and asked for 60 tracks" "$(cat "$TMP/get.log")" 60

d="$TMP/hasone"
populate "$d" "the one song I want.mp3"
check "one song is enough to stop it" "$(seeded "$d")" 0

d="$TMP/hasclutter"
populate "$d" "playlist.m3u8"
check "a playlist alone does not stop it" "$(seeded "$d")" 1

echo "scenario: music-get reports a failure rather than hiding it"
# The rename is the point: this is a tool run by hand now, so it exits non-zero
# and says why. Silencing it is install.sh's job, not its own.
d="$TMP/getfail"; mkdir -p "$d"
err="$(MUSIC_DIR="$d" offline 2>&1 >/dev/null || true)"
check "exit 1" "$(MUSIC_DIR="$d" offline >/dev/null 2>&1; printf '%s' "$?")" 1
check "and says what went wrong" \
    "$(grep -qiE 'cannot reach|got nothing' <<<"$err" && echo yes)" yes
check "no files left behind" "$(find "$d" -type f | wc -l)" 0
check "no .part turds in particular" "$(find "$d" -name '*.part' | wc -l)" 0

echo "scenario: --quiet is silent on both streams, for a caller that wants it"
d="$TMP/getquiet"; mkdir -p "$d"
out="$(MUSIC_DIR="$d" offline --quiet 2>&1)"
check "says nothing at all" "$([ -z "$out" ] && echo yes)" yes
check "but still exits non-zero" \
    "$(MUSIC_DIR="$d" offline --quiet >/dev/null 2>&1; printf '%s' "$?")" 1

echo "scenario: install.sh's redirect is what makes a failed download silent"
# What the user asked for, now enforced at the call site. The stub is gone
# here: the real music-get runs, offline, through the real seed_music.
real="$TMP/realrepo"; mkdir -p "$real/bin"
cp "$REPO/install.sh" "$real/install.sh"
cp "$REPO/bin/music" "$real/bin/music"
cp "$REPO/bin/music-get" "$real/bin/music-get"
d="$TMP/installsilent"; mkdir -p "$d"
out="$(MUSIC_DIR="$d" MUSIC_GET_DEADLINE=5 HOME="$d/.." \
       http_proxy="http://192.0.2.1:9" https_proxy="http://192.0.2.1:9" \
       "$TMP/seed-harness.sh" "$real" 2>&1)"; rc=$?
check "the install step exits 0" "$rc" 0
check "with nothing on stdout or stderr" "$([ -z "$out" ] && echo yes)" yes

echo "scenario: music-get rejects a bad option instead of guessing a count"
check "exit 2" "$(MUSIC_DIR="$TMP/getfail" "$GET" --nonsense >/dev/null 2>&1; printf '%s' "$?")" 2

echo "scenario: bin/music refuses to play an empty directory"
d="$TMP/bare"
check "exit 1" "$(MUSIC_DIR="$d" "$PLAY" --once >/dev/null 2>&1; printf '%s' "$?")" 1
# Captured first rather than piped into grep: this harness runs under `set -o
# pipefail`, so a pipeline ending in grep still reports music's own exit 1 and
# an `&& echo yes` after it never fires. That read as the script printing
# nothing when it was printing correctly.
err="$(MUSIC_DIR="$d" "$PLAY" --once 2>&1 >/dev/null || true)"
check "and explains itself" "$(grep -qi 'no audio files' <<<"$err" && echo yes)" yes
check "unknown option is exit 2" \
    "$(MUSIC_DIR="$d" "$PLAY" --nope >/dev/null 2>&1; printf '%s' "$?")" 2

echo "scenario: bin/music hands mpv every track, in order"
# mpv is stubbed because the question is which paths it is given, not what it
# does with them. --list and the play path share one find, and this is what
# proves the play path still passes the whole queue through.
d="$TMP/plays"
populate "$d" "01 first.mp3" "02 second.mp3" "03 it's third.mp3"
mkdir -p "$d/stub"
cat > "$d/stub/mpv" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        --*|--) ;;
        *) printf '%s\n' "$arg" ;;
    esac
done
STUB
chmod +x "$d/stub/mpv"
handed="$(PATH="$d/stub:$PATH" MUSIC_DIR="$d" "$PLAY" --once 2>/dev/null | grep '^/')"
check "three tracks reached mpv" "$(wc -l <<<"$handed")" 3
check "in sorted order" "$(head -1 <<<"$handed" | xargs -0 basename)" "01 first.mp3"
check "and --list agrees with what mpv got" \
    "$([ "$handed" = "$(MUSIC_DIR="$d" "$PLAY" --list)" ] && echo yes)" yes

echo "scenario: the desktop mark never reaches a session that was not handed over"
# This one is about the harness as much as the script. A bare `hyprctl` talks
# to whichever Hyprland is running -- the one the user is sitting in -- so
# bin/music gating on HYPRLAND_INSTANCE_SIGNATURE is what stops this very suite
# renaming a live desktop on every run. Caught by noticing the play scenario
# above was calling the real hyprctl.
cat > "$d/stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HYPRCTL_LOG:?}"
STUB
chmod +x "$d/stub/hyprctl"
export HYPRCTL_LOG="$TMP/hyprctl.log"

: > "$HYPRCTL_LOG"
env -u HYPRLAND_INSTANCE_SIGNATURE \
    PATH="$d/stub:$PATH" MUSIC_DIR="$d" "$PLAY" --once >/dev/null 2>&1
check "no compositor handed over: hyprctl not called at all" "$(wc -l < "$HYPRCTL_LOG")" 0

echo "scenario: given a compositor, it marks on the way in and clears on the way out"
: > "$HYPRCTL_LOG"
HYPRLAND_INSTANCE_SIGNATURE=test-sig \
    PATH="$d/stub:$PATH" MUSIC_DIR="$d" "$PLAY" --once >/dev/null 2>&1
check "it marked the desktop" "$(grep -c "musicmark').set_here(" "$HYPRCTL_LOG")" 1
check "with its own pid, not a literal" \
    "$(grep -qE "set_here\([0-9]+\)" "$HYPRCTL_LOG" && echo yes)" yes
check "and cleared it afterwards" "$(grep -c "musicmark').clear()" "$HYPRCTL_LOG")" 1
check "through repl, not dispatch" "$(grep -c '^repl ' "$HYPRCTL_LOG")" 2
check "clearing came last" "$(tail -1 "$HYPRCTL_LOG" | grep -qF 'clear()' && echo yes)" yes

echo "scenario: the mark is cleared even when playback is interrupted"
# The trap is the tidy path; musicmark's pid check is the fallback for a
# SIGKILL. This covers the tidy one, which is the common case: Ctrl-C.
cat > "$d/stub/mpv" <<'STUB'
#!/usr/bin/env bash
kill -INT $PPID
sleep 5
STUB
chmod +x "$d/stub/mpv"
: > "$HYPRCTL_LOG"
HYPRLAND_INSTANCE_SIGNATURE=test-sig \
    PATH="$d/stub:$PATH" MUSIC_DIR="$d" "$PLAY" --once >/dev/null 2>&1
check "interrupted: still cleared" "$(grep -c "musicmark').clear()" "$HYPRCTL_LOG")" 1

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
