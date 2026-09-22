#!/usr/bin/env bash
# Harness for bin/unzip-here, the extractor yazi's Enter runs on a zip.
#
# Real unzip against real archives, in a scratch directory -- there is nothing
# worth stubbing, since the script's whole job is arranging unzip's arguments
# and the interesting answers are what lands on disk. notify-send is stubbed so
# a failing case does not post a desktop notification while the tests run.
#
# The archives are built with python's zipfile rather than `zip`, which is not
# installed here (and is not wanted: nothing in this repo creates zips).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/unzip-here"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Keep a failing extract from reaching the real notification daemon, and record
# what it would have said.
cat > "$TMP/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:?}"
STUB
chmod +x "$TMP/bin/notify-send"
export PATH="$TMP/bin:$PATH"
export NOTIFY_LOG="$TMP/notify.log"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

python3 - "$TMP" <<'PY'
import sys, zipfile, os
tmp = sys.argv[1]
os.makedirs(f"{tmp}/zips", exist_ok=True)
def z(name, entries):
    with zipfile.ZipFile(f"{tmp}/zips/{name}", "w") as f:
        for path, body in entries.items():
            f.writestr(path, body)

# Loose entries at the root: needs a directory of its own or it scatters.
z("many.zip",        {"a.txt": "a\n", "sub/b.txt": "b\n"})
# Already carries one top-level directory: must not be nested twice.
z("selfcontained.zip", {"proj/x.txt": "x\n", "proj/deep/y.txt": "y\n"})
# A single loose file is NOT self-contained -- one entry, no slash.
z("lone.zip",        {"only.txt": "only\n"})
# Spaces, which the opener passes through shell quoting.
z("spaced name.zip", {"s.txt": "s\n"})
PY

run() { ( cd "$1" && shift && "$SCRIPT" "$@" >/dev/null 2>&1; printf '%s' "$?" ); }
Z="$TMP/zips"

echo "scenario: an archive with loose entries gets a directory of its own"
# Otherwise Enter on a zip scatters its contents over the directory you were
# looking at, which is the thing that cannot be undone with one keystroke.
w="$TMP/w1"; mkdir -p "$w"
check "exit 0" "$(run "$w" "$Z/many.zip")" 0
check "named after the archive" "$([ -d "$w/many" ] && echo yes)" yes
check "with its contents" "$([ -f "$w/many/a.txt" ] && [ -f "$w/many/sub/b.txt" ] && echo yes)" yes
check "and nothing loose beside it" "$(find "$w" -maxdepth 1 -mindepth 1 | wc -l)" 1

echo "scenario: an archive that already holds one directory is not nested twice"
w="$TMP/w2"; mkdir -p "$w"
check "exit 0" "$(run "$w" "$Z/selfcontained.zip")" 0
check "its own directory, at the top" "$([ -f "$w/proj/x.txt" ] && echo yes)" yes
check "not proj/proj" "$([ -e "$w/selfcontained" ] && echo nested || echo no)" no

echo "scenario: a single loose file still gets a directory"
# One entry and no slash is not self-contained: without this it lands bare.
w="$TMP/w3"; mkdir -p "$w"
check "exit 0" "$(run "$w" "$Z/lone.zip")" 0
check "wrapped, not bare" "$([ -f "$w/lone/only.txt" ] && echo yes)" yes

echo "scenario: several archives at once"
# The reason this is a script at all: `unzip a.zip b.zip` reads b.zip as a
# member pattern inside a.zip, lists nothing and exits 11.
w="$TMP/w4"; mkdir -p "$w"
check "exit 0" "$(run "$w" "$Z/many.zip" "$Z/selfcontained.zip" "$Z/spaced name.zip")" 0
check "the first came out" "$([ -f "$w/many/a.txt" ] && echo yes)" yes
check "the second too" "$([ -f "$w/proj/x.txt" ] && echo yes)" yes
check "and the one with a space in its name" "$([ -f "$w/spaced name/s.txt" ] && echo yes)" yes

echo "scenario: extracting the same archive twice does not merge the two"
w="$TMP/w5"; mkdir -p "$w"
run "$w" "$Z/many.zip" >/dev/null
check "exit 0 again" "$(run "$w" "$Z/many.zip")" 0
check "a second directory" "$([ -f "$w/many-2/a.txt" ] && echo yes)" yes
check "the first untouched" "$([ -f "$w/many/a.txt" ] && echo yes)" yes

echo "scenario: failures are reported rather than silent"
# yazi discards an opener's output, so a failure that only prints to stderr is
# indistinguishable from nothing happening.
w="$TMP/w6"; mkdir -p "$w"
: > "$NOTIFY_LOG"
check "a missing archive exits non-zero" "$(run "$w" "$Z/nope.zip")" 1
check "...and notifies" "$(grep -c 'no such file' "$NOTIFY_LOG")" 1

: > "$NOTIFY_LOG"
printf 'not a zip at all' > "$w/broken.zip"
check "a corrupt archive exits non-zero" "$(run "$w" "$w/broken.zip")" 1
check "...and notifies" "$(grep -c 'failed to extract' "$NOTIFY_LOG")" 1

check "no arguments is a usage error" "$(run "$w")" 2

echo "scenario: one bad archive does not stop the others"
w="$TMP/w7"; mkdir -p "$w"
check "exits non-zero overall" "$(run "$w" "$Z/nope.zip" "$Z/many.zip")" 1
check "but the good one came out" "$([ -f "$w/many/a.txt" ] && echo yes)" yes

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
