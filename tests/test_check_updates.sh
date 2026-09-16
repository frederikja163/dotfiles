#!/usr/bin/env bash
# Harness for bin/dotfiles-check-updates: the loop that watches the remote and
# the one notification it keeps current.
#
# git, notify-send, busctl, curl and sleep are all stubbed, so nothing here
# reaches a remote, a notification daemon or a clock. What is asserted is the
# sequence of notifications the script would post -- a new one, a replacement,
# nothing for an unchanged answer, and a close when the repo comes current.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/dotfiles-check-updates"

TMP="$(mktemp -d)"
STATE="$TMP/state"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$STATE"

# git: a fixed branch and remote, a fetch whose success and behind-count come
# from the current line of a plan file, and a behind-count read back from what
# the last fetch left.
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
    symbolic-ref) printf 'main\n' ;;
    config)
        case "${2:-}" in
            branch.main.remote) printf 'origin\n' ;;
            branch.main.merge)  printf 'refs/heads/main\n' ;;
            *) exit 1 ;;
        esac ;;
    remote) printf 'https://example.test/dotfiles.git\n' ;;
    fetch)
        n=$(( $(cat "$STATE/call" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" > "$STATE/call"
        line="$(sed -n "${n}p" "$STATE/plan")"
        case "$line" in
            ok*) printf '%s\n' "${line#ok }" > "$STATE/behind"; exit 0 ;;
            *) exit 1 ;;
        esac ;;
    rev-parse)
        if [ "$(cat "$STATE/local_exists" 2>/dev/null || echo 0)" = 1 ]; then
            printf '0123456789abcdef0123456789abcdef01234567\n'
            exit 0
        fi
        exit 1 ;;
    rev-list)
        case "${@: -1}" in
            *refs/remotes*) cat "$STATE/local_behind" 2>/dev/null || printf '0\n' ;;
            *) cat "$STATE/behind" 2>/dev/null || printf '0\n' ;;
        esac ;;
    *) exit 0 ;;
esac
STUB

# notify-send: hand out an id, and record the replace-id and text it was given.
cat > "$TMP/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
replace=none
args=()
for a in "$@"; do
    case "$a" in
        --replace-id=*) replace="${a#*=}" ;;
        --app-name=*|--urgency=*|--print-id) ;;
        *) args+=("$a") ;;
    esac
done
id=$(( $(cat "$STATE/nextid" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$id" > "$STATE/nextid"
printf '%s|%s|%s\n' "$replace" "${args[0]:-}" "${args[1]:-}" >> "$STATE/notify"
printf '%s\n' "$id"
STUB

# busctl: record the id it was asked to close.
cat > "$TMP/bin/busctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >> "$STATE/closed"
STUB

# curl: the reachability probe's answer, set per scenario.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit "$(cat "$STATE/curl_exit" 2>/dev/null || echo 0)"
STUB

# sleep: the loop's only clock. Count calls and stop the script after the plan
# has been walked, so a loop test ends on its own.
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$STATE/sleeps" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STATE/sleeps"
if [ "$n" -ge "$(cat "$STATE/sleep_limit")" ]; then
    kill -TERM "$PPID" 2>/dev/null
fi
exit 0
STUB

chmod +x "$TMP/bin/"*

pass=0
fail=0

check() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        printf '  ok   %-58s %s\n' "$label" "$got"
    else
        fail=$((fail + 1))
        printf '  FAIL %-58s got %s want %s\n' "$label" "$got" "$want"
    fi
}

# scenario <once|loop> <sleep-limit> then the plan lines on stdin. ONCE is what
# the environment would say; a loop is the script deciding it has no watcher.
scenario() {
    local mode="$1" limit="$2" once=0
    [ "$mode" = "once" ] && once=1
    shift 2

    printf '%s\n' "$limit" > "$STATE/sleep_limit"
    cat > "$STATE/plan"
    echo 0 > "$STATE/nextid"
    echo 0 > "$STATE/call"
    echo 0 > "$STATE/sleeps"
    echo 0 > "$STATE/behind"
    : > "$STATE/notify"
    : > "$STATE/closed"
    echo "${CURL_EXIT:-0}" > "$STATE/curl_exit"
    echo "${LOCAL_EXISTS:-0}" > "$STATE/local_exists"
    echo "${LOCAL_BEHIND:-0}" > "$STATE/local_behind"

    # A subshell so the "Terminated" the parent prints when the loop's stub
    # sleep stops the script does not land in the test output.
    (
        PATH="$TMP/bin:$PATH" \
        STATE="$STATE" \
        DOTFILES_CHECK_UPDATES_INTERVAL=0 \
        DOTFILES_CHECK_UPDATES_ONCE="$once" \
        DOTFILES_CHECK_UPDATES_PROBE_TIMEOUT=2 \
            "$SCRIPT" "$@" || :
    ) >/dev/null 2>&1
}

# What was posted, flattened: a new notice and its text, or replace=N.
posted() {
    if [ -s "$STATE/notify" ]; then
        cut -d'|' -f1 "$STATE/notify" | tr '\n' ' '
    fi
}

echo "scenario: a current repo says nothing at login"
scenario once 1 <<'PLAN'
ok 0
PLAN
check "no notification" "$(posted)" ""

echo "scenario: commits are waiting at login"
scenario once 1 <<'PLAN'
ok 1
PLAN
check "one new notice, for one commit" "$(posted)" "none "
check "the text" "$(sed -n '1p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: 1 commit behind"

echo "scenario: the loop keeps one notice current across a session"
CURL_EXIT=1 scenario loop 6 <<'PLAN'
ok 2
ok 2
ok 3
fail
fail
fail
PLAN
check "posted only on a change, always in place" "$(posted)" "none 1 2 "
check "the behind-count was corrected" "$(sed -n '2p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: 3 commits behind"
check "a failure became the offline notice" "$(sed -n '3p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: no network"
check "nothing was closed" "$(wc -l < "$STATE/closed")" "0"

echo "scenario: pulling closes the notice"
scenario loop 2 <<'PLAN'
ok 1
ok 0
PLAN
check "the notice is taken down" "$(cat "$STATE/closed")" "1"

echo "scenario: a fetch that cannot see the remote says so"
CURL_EXIT=0 scenario once 1 <<'PLAN'
fail
PLAN
check "the remote, not the network" "$(sed -n '1p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: cannot fetch from origin"

echo "scenario: -f reports work the repo already holds when the fetch is down"
CURL_EXIT=1 LOCAL_EXISTS=1 LOCAL_BEHIND=2 scenario once 1 -f <<'PLAN'
fail
PLAN
check "the behind notice, from the local ref" \
      "$(sed -n '1p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: 2 commits behind"

echo "scenario: -f with nothing already fetched still blames the network"
CURL_EXIT=1 LOCAL_EXISTS=1 LOCAL_BEHIND=0 scenario once 1 -f <<'PLAN'
fail
PLAN
check "the offline notice" \
      "$(sed -n '1p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: no network"

echo "scenario: without -f a failed fetch never consults the local refs"
CURL_EXIT=1 LOCAL_EXISTS=1 LOCAL_BEHIND=2 scenario once 1 <<'PLAN'
fail
PLAN
check "the local ref is ignored" \
      "$(sed -n '1p' "$STATE/notify" | cut -d'|' -f2)" \
      "dotfiles: no network"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
