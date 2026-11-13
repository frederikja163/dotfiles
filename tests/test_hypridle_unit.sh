#!/usr/bin/env bash
# Harness for the hypridle supervision: systemd/hypridle.service.d/recover.conf
# and the restart in bin/dotfiles-reload.
#
# The question is the one that left the laptop screen black: when hypridle dies,
# does something start it again, and does that start put the backlight back. The
# unit is read with systemd-analyze rather than started, so nothing here touches
# the running session. dotfiles-reload runs against stubbed systemctl and
# hyprctl, and says which route it took.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

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

DROPIN="$ROOT/systemd/hypridle.service.d/recover.conf"
body="$(grep -v '^#' "$DROPIN")"

echo "scenario: the drop-in"
check "it restores the backlight before starting" \
      "$(grep -c '^ExecStartPre=-%h/dotfiles/lib/screen-power restore$' <<<"$body")" 1
check "it wakes the screens before starting" \
      "$(grep -c '^ExecStartPre=-%h/dotfiles/lib/screen-power wake$' <<<"$body")" 1
check "a failing pre-step cannot stop hypridle starting" \
      "$(grep '^ExecStartPre=' <<<"$body" | grep -vc '=-')" 0
check "it never gives up restarting" \
      "$(grep -c '^StartLimitIntervalSec=0$' <<<"$body")" 1

echo "scenario: the drop-in is understood by systemd"
if command -v systemd-analyze >/dev/null && [ -f /usr/lib/systemd/user/hypridle.service ]; then
    mkdir -p "$TMP/unit/hypridle.service.d"
    cp /usr/lib/systemd/user/hypridle.service "$TMP/unit/"
    cp "$DROPIN" "$TMP/unit/hypridle.service.d/"
    out="$(systemd-analyze --user --no-pager verify "$TMP/unit/hypridle.service" 2>&1)"
    check "verify finds nothing wrong with the unit and drop-in" "$out" ""
else
    echo "  skip systemd-analyze or the packaged unit is not available"
fi

echo "scenario: dotfiles-reload restarts hypridle"
mkdir -p "$TMP/bin"
for c in hyprctl waybar-main dunstctl notify-send; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$c"
done
# The script waits for a *new* waybar pid before it moves on to hypridle: the
# first look, taken before the bar is started, finds none and the later ones
# find one. Nothing else is running.
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "$2" = waybar ] || exit 1
if [ -e "$STUB_DIR/waybar-looked" ]; then echo 999; exit 0; fi
touch "$STUB_DIR/waybar-looked"; exit 1
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/systemctl.log"
case "$*" in
    *is-active*) [ "${UNIT_ACTIVE:-}" = 1 ] ;;
esac
EOF
chmod +x "$TMP"/bin/*

reload() {
    : > "$TMP/systemctl.log"; rm -f "$TMP/waybar-looked"
    PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" UNIT_ACTIVE="$1" \
        "$ROOT/bin/dotfiles-reload" >/dev/null 2>&1
    sleep 2
    grep -c 'restart hypridle.service' "$TMP/systemctl.log"
}
check "a running unit is restarted through systemd" "$(reload 1)" 1
check "a stopped unit is left stopped" "$(reload 0)" 0

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
