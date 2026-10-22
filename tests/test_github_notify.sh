#!/usr/bin/env bash
# Harness for bin/github-notify: the loop that turns unread GitHub threads into
# dunst notifications.
#
# gh, notify-send and sleep are stubbed, so nothing here reaches GitHub or a
# notification daemon. What is asserted is what the script would post across a
# run of passes: nothing for the backlog at login, one notice for a thread that
# appears, nothing for one that merely stays, and a fresh notice when a known
# thread is updated.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/github-notify"

TMP="$(mktemp -d)"
STATE="$TMP/state"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$STATE"

# gh: each call for the list prints the next block of the plan file, blocks
# separated by a line holding only "--". A block reading "FAIL <message>" fails
# with that on stderr instead. Thread lines are the already-filtered output of
# the --jq expression, so this does not test the filter -- that is checked
# against the real API by hand -- only what the script does with its output.
#
# Any other call is a probe for one fact about a thread, answered from
# $STATE/probe/<last path segment of the URL> and failing when there is none.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = api ] && [ "$2" != notifications ]; then
    cat "$STATE/probe/$(basename "$2")" 2>/dev/null
    exit
fi
n=$(( $(cat "$STATE/call" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STATE/call"
block="$(awk -v want="$n" 'BEGIN{b=1} /^--$/{b++; next} b==want{print}' "$STATE/plan")"
case "$block" in
    FAIL*) printf '%s\n' "${block#FAIL }" >&2; exit 1 ;;
    *) [ -n "$block" ] && printf '%s\n' "$block"; exit 0 ;;
esac
STUB

cat > "$TMP/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
args=()
for a in "$@"; do
    case "$a" in
        --app-name=*|--urgency=*|--action=*) ;;
        *) args+=("$a") ;;
    esac
done
printf '%s|%s\n' "${args[0]:-}" "${args[1]:-}" >> "$STATE/notify"
# With an action, the real one blocks until the notice is clicked or closed and
# prints the action's name; a click is simulated by the file existing.
case " $* " in
    *" --action=default=Open "*) [ -e "$STATE/click" ] && echo default ;;
esac
exit 0
STUB

cat > "$TMP/bin/xdg-open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STATE/opened"
STUB

# sleep: the loop's only clock. Stop the script once the plan has been walked.
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

# scenario <once|loop> <sleep-limit>, with the plan on stdin.
scenario() {
    local mode="$1" limit="$2" once=0
    [ "$mode" = "once" ] && once=1

    printf '%s\n' "$limit" > "$STATE/sleep_limit"
    cat > "$STATE/plan"
    echo 0 > "$STATE/call"
    echo 0 > "$STATE/sleeps"
    : > "$STATE/notify"
    : > "$STATE/opened"
    mkdir -p "$STATE/probe"

    (
        PATH="$TMP/bin:$PATH" \
        STATE="$STATE" \
        DOTFILES_GITHUB_NOTIFY_INTERVAL=0 \
        DOTFILES_GITHUB_NOTIFY_ONCE="$once" \
        DOTFILES_GITHUB_NOTIFY_SYNC=1 \
            "$SCRIPT" || :
    ) >/dev/null 2>&1
}

# One thread in the format the script reads: fields split on the unit separator.
# thread ID UPDATED REPO TITLE [EVENT [PROBE [URL]]]. The page URL is made up
# from the repo and id unless one is given.
thread() {
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" \
        "${7:-https://github.com/$3/pull/$1}" "${5:-Updated}" "${6:-}" "$4"
}

count() { wc -l < "$STATE/notify" | tr -d ' '; }
line()  { sed -n "${1}p" "$STATE/notify"; }

echo "scenario: a single pass announces everything unread"
scenario once 1 <<PLAN
$(thread 1 t1 me/app 'Fix the parser' 'Review requested')
PLAN
check "one notice" "$(count)" "1"
check "repo and reason in the summary, title in the body" "$(line 1)" \
      "me/app: Review requested|Fix the parser"

echo "scenario: following a notice opens its page"
rm -f "$STATE/click"
scenario once 1 <<PLAN
$(thread 7 t1 me/app 'Look at this' 'Mentioned' '' 'https://github.com/me/app/pull/7#issuecomment-99')
PLAN
check "a notice nobody follows opens nothing" "$(cat "$STATE/opened")" ""
touch "$STATE/click"
scenario once 1 <<PLAN
$(thread 7 t1 me/app 'Look at this' 'Mentioned' '' 'https://github.com/me/app/pull/7#issuecomment-99')
PLAN
check "a followed one opens the thread, at its comment" "$(cat "$STATE/opened")" \
      "https://github.com/me/app/pull/7#issuecomment-99"
scenario loop 2 <<PLAN
--
$(for i in 1 2 3 4 5 6 7; do thread "$i" t1 me/app "Thread $i" 'Mentioned'; done)
PLAN
check "a followed burst opens the notifications page" "$(cat "$STATE/opened")" \
      "https://github.com/notifications"
rm -f "$STATE/click"

echo "scenario: the notice says what happened, not why you are told"
scenario once 1 <<PLAN
$(thread 1 t1 me/app 'Fix it' 'New comment' 'https://api.github.com/repos/me/app/issues/comments/5')
$(thread 2 t1 me/app 'Ship it' 'State changed' 'https://api.github.com/repos/me/app/pulls/2')
$(thread 3 t1 me/app 'Offline' 'New comment' 'https://api.github.com/repos/me/app/issues/comments/9')
$(thread 4 t1 me/app 'Tests' 'CI failed')
PLAN
check "no probe answers: the plain events" "$(cat "$STATE/notify" | cut -d'|' -f1 | paste -sd,)" \
      "me/app: New comment,me/app: State changed,me/app: New comment,me/app: CI failed"
mkdir -p "$STATE/probe"
echo alice > "$STATE/probe/5"
echo Merged > "$STATE/probe/2"
scenario once 1 <<PLAN
$(thread 1 t1 me/app 'Fix it' 'New comment' 'https://api.github.com/repos/me/app/issues/comments/5')
$(thread 2 t1 me/app 'Ship it' 'State changed' 'https://api.github.com/repos/me/app/pulls/2')
$(thread 3 t1 me/app 'Offline' 'New comment' 'https://api.github.com/repos/me/app/issues/comments/9')
PLAN
check "a comment names who wrote it" "$(line 1 | cut -d'|' -f1)" "me/app: New comment from alice"
check "a state change says merged, closed or reopened" "$(line 2 | cut -d'|' -f1)" "me/app: Merged"
check "a probe that fails leaves the plain event" "$(line 3 | cut -d'|' -f1)" "me/app: New comment"
rm -rf "$STATE/probe"

echo "scenario: the backlog at login is only remembered"
scenario loop 3 <<PLAN
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
--
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
--
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
PLAN
check "nothing posted" "$(count)" "0"

echo "scenario: a new thread, an unchanged one, and an updated one"
scenario loop 4 <<PLAN
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
--
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
$(thread 2 t2 me/app 'New thread' 'Assigned')
--
$(thread 1 t1 me/app 'Old thread' 'Mentioned')
$(thread 2 t2 me/app 'New thread' 'Assigned')
--
$(thread 1 t3 me/app 'Old thread' 'Mentioned')
$(thread 2 t2 me/app 'New thread' 'Assigned')
PLAN
check "only the new thread, then the updated one" "$(count)" "2"
check "the new thread" "$(line 1)" "me/app: Assigned|New thread"
check "the updated thread is announced again" "$(line 2)" \
      "me/app: Mentioned|Old thread"

echo "scenario: reading a thread and then getting it again"
scenario loop 4 <<PLAN
$(thread 1 t1 me/app 'Thread' 'Mentioned')
--
--
$(thread 1 t1 me/app 'Thread' 'Mentioned')
--
$(thread 1 t1 me/app 'Thread' 'Mentioned')
PLAN
check "a thread that went away and came back is announced" "$(count)" "1"

echo "scenario: markup in a title cannot reach dunst"
scenario loop 2 <<PLAN
--
$(thread 1 t1 me/app 'Use <b> & more' 'Mentioned')
PLAN
check "escaped" "$(line 1)" "me/app: Mentioned|Use &lt;b&gt; &amp; more"

echo "scenario: a burst is folded into one notice"
scenario loop 2 <<PLAN
--
$(for i in 1 2 3 4 5 6 7; do thread "$i" t1 me/app "Thread $i" 'Mentioned'; done)
PLAN
check "one summary" "$(count)" "1"
check "it counts them" "$(line 1 | cut -d'|' -f1)" "github: 7 new notifications"

echo "scenario: offline says nothing, and a pass after it still works"
scenario loop 3 <<PLAN
--
FAIL error connecting to api.github.com
--
$(thread 1 t1 me/app 'After the outage' 'Mentioned')
PLAN
check "no notice for the failure, one for the thread" "$(count)" "1"
check "the thread" "$(line 1)" "me/app: Mentioned|After the outage"

echo "scenario: a failed pass does not forget what was seen"
scenario loop 4 <<PLAN
$(thread 1 t1 me/app 'Thread' 'Mentioned')
--
FAIL error connecting to api.github.com
--
$(thread 1 t1 me/app 'Thread' 'Mentioned')
PLAN
check "the same thread is not announced after the outage" "$(count)" "0"

echo "scenario: a bad token is said once"
scenario loop 3 <<PLAN
FAIL HTTP 401: Bad credentials
--
FAIL HTTP 401: Bad credentials
--
FAIL HTTP 401: Bad credentials
PLAN
check "one notice" "$(count)" "1"
check "it says what to do" "$(line 1)" \
      "github: not signed in|gh has no working token. Run: gh auth login"

if [ "$fail" -gt 0 ]; then
    printf '%d failed\n' "$fail"
    exit 1
fi
printf '%d checks passed\n' "$pass"
