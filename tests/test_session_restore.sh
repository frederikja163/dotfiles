#!/usr/bin/env bash
# Harness for bin/dotfiles-session-restore: the decision of whether to put the
# last session back, which is the difference between logging in to a clean
# desktop and having a dozen programs relaunch themselves at you.
#
# hyprctl is stubbed, so nothing here reaches a compositor -- what is asserted
# is which Lua the script would have dispatched: `restore()` or the `arm()`
# that only starts writing the session down. $XDG_RUNTIME_DIR and
# $XDG_DATA_HOME are pointed at scratch directories, so the real markers are
# neither read nor written.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/dotfiles-session-restore"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A hyprctl that answers the monitor wait and writes down what it was asked.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "monitors" ]; then
    echo '[{"id": 0}]'
    exit 0
fi
printf '%s\n' "$*" >> "$HYPRCTL_LOG"
STUB
chmod +x "$TMP/bin/hyprctl"

pass=0
fail=0

# Run the script in a world of its own: `runtime` says whether this boot has
# already had a compositor, `state` persists across it the way ~/.local/share
# does. Answers with what the script dispatched.
run() {
    local runtime="$1" state="$2" signature="$3"
    shift 3

    export HYPRCTL_LOG="$TMP/dispatched"
    : > "$HYPRCTL_LOG"

    PATH="$TMP/bin:$PATH" \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_DATA_HOME="$state" \
    HYPRLAND_INSTANCE_SIGNATURE="$signature" \
    HYPR_SANDBOX="${HYPR_SANDBOX:-}" \
        "$SCRIPT" "$@" >/dev/null 2>&1

    if grep -q 'restore()' "$HYPRCTL_LOG"; then
        echo restore
    elif grep -q 'arm()' "$HYPRCTL_LOG"; then
        echo arm
    else
        echo nothing
    fi
}

check() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        printf '  ok   %-56s %s\n' "$label" "$got"
    else
        fail=$((fail + 1))
        printf '  FAIL %-56s got %s want %s\n' "$label" "$got" "$want"
    fi
}

fresh() {
    rm -rf "$TMP/run" "$TMP/data"
    mkdir -p "$TMP/run" "$TMP/data"
}

# A reboot empties $XDG_RUNTIME_DIR, so the first compositor after one finds no
# marker. Starting the machine is starting the day.
echo "scenario: the first compositor since the machine came up"
fresh
check "nothing is put back" "$(run "$TMP/run" "$TMP/data" sig-one)" arm
check "...but the session is written from now on" \
      "$(ls "$TMP/run" | grep -c hypr-session-booted)" 1

# The marker outlives the compositor but not the boot, so a second one means
# Hyprland went down and came back: a crash, or a config change that took it
# with it. Everything that was open a moment ago should be open again.
echo "scenario: a second compositor in the same boot"
check "the session goes back" "$(run "$TMP/run" "$TMP/data" sig-two)" restore

echo "scenario: the same compositor asking twice"
check "already restored, so nothing happens" \
      "$(run "$TMP/run" "$TMP/data" sig-two)" nothing

echo "scenario: --now overrides all of it"
fresh
check "restores on a fresh boot" "$(run "$TMP/run" "$TMP/data" sig-one --now)" restore
check "...and again in the same compositor" \
      "$(run "$TMP/run" "$TMP/data" sig-one --now)" restore

echo "scenario: switched off"
fresh
: > "$TMP/run/hypr-session-booted"   # a second compositor, so it would restore
mkdir -p "$TMP/data/hypr" && : > "$TMP/data/hypr/session.off"
check "not even after a crash" "$(run "$TMP/run" "$TMP/data" sig-two)" arm
check "but --now still does" "$(run "$TMP/run" "$TMP/data" sig-three --now)" restore

# With nowhere to keep the marker there is no way to tell a boot from a
# restart, and the answer that does not relaunch a dozen programs wins.
echo "scenario: no runtime directory to remember the boot in"
fresh
check "treated as a fresh boot" "$(run "" "$TMP/data" sig-four)" arm

echo "scenario: inside the sandbox"
fresh
check "never restores a nested instance" \
      "$(HYPR_SANDBOX=1 run "$TMP/run" "$TMP/data" sig-five)" nothing

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
