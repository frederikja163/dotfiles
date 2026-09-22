#!/usr/bin/env bash
# Harness for opencode/: that every mode which can reach a shell guards the
# same set of git commands, and that none of them re-opens what a project has
# closed.
#
# This exists because the guard is written out three times -- build and plan in
# opencode.jsonc, review in agent/review.md -- and the config format has no way
# to share a list. A plugin could have injected it from one place and was
# rejected: a plugin that fails to load takes the guard with it silently, which
# is the exact failure being guarded against. Copies are safer and drift is the
# price, so the drift is what gets tested.
#
# Asserted against `opencode agent list`, which prints each agent's fully
# resolved permission rules -- the merge of opencode's defaults, this repo's
# project config and the agent's own. That is the thing that actually decides
# whether a command runs, rather than what the files appear to say.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-56s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-56s got %s want %s\n' "$1" "$2" "$3"
    fi
}

if ! command -v opencode >/dev/null; then
    echo "  skip: opencode is not on PATH"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! opencode agent list > "$TMP/raw" 2>/dev/null; then
    echo "  FAIL opencode agent list did not run" >&2
    exit 1
fi

# One line per rule: "<agent> <permission> <action> <pattern>". The script goes
# in on stdin and the data by path, so neither has to be quoted inside the
# other.
python3 - "$TMP/raw" > "$TMP/flat" <<'PARSE'
import sys, json, re

# "<name> (<mode>)" on its own line, then that agent's rules as an indented
# JSON array. Accumulated line by line rather than matched with one regex,
# because the array is indented and a greedy pattern would span agents.
agent, buf = None, []

def flush(name, lines):
    if not name or not lines:
        return
    try:
        rules = json.loads("".join(lines))
    except json.JSONDecodeError:
        return
    for r in rules:
        print(name, r.get("permission", ""), r.get("action", ""), r.get("pattern", ""))

for line in open(sys.argv[1]):
    header = re.match(r"^(\S+) \((\w+)\)\s*$", line)
    if header:
        flush(agent, buf)
        agent, buf = header.group(1), []
    elif agent is not None:
        buf.append(line)
flush(agent, buf)
PARSE

[ -s "$TMP/flat" ] || { echo "  FAIL could not parse any agent rules" >&2; exit 1; }

# The git commands every shell-capable mode must gate, one per line, in the
# same order as the config so a diff between the two reads straight.
shared_commands() {
    cat <<'CMDS'
commit
push
pull
merge
am
cherry-pick
revert
rebase
reset
filter-branch
filter-repo
replace
update-ref
tag
branch -d
branch -D
branch --delete
reflog
gc
prune
stash
CMDS
}

# build and plan ask, because the user is meant to decide. review denies,
# because it is read-only by construction and the answer to "commit this"
# there is to change mode, not to approve a prompt.
expected_action() {
    case "$1" in
        review) printf 'deny' ;;
        *)      printf 'ask' ;;
    esac
}

echo "scenario: every mode that can reach a shell guards the same git commands"
for agent in build plan review; do
    want="$(expected_action "$agent")"
    missing=""; wrongaction=""

    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        pattern="*git $cmd*"
        if ! grep -qF -- "$agent bash $want $pattern" "$TMP/flat"; then
            # Scoped to this agent, or a rule that exists only for another one
            # is misreported as the wrong action rather than as missing.
            if grep -F -- "$agent bash " "$TMP/flat" | grep -qF -- " $pattern"; then
                wrongaction="$wrongaction $cmd"
            else
                missing="$missing $cmd"
            fi
        fi
    done < <(shared_commands)

    check "$agent guards every shared git command" "${missing:-none}" none
    check "...all of them as \"$want\"" "${wrongaction:-none}" none
done

echo "scenario: no agent re-opens what a project has closed"
# An agent's rules are appended after the project's and the last match wins, so
# an allow-all belonging to an agent would silently re-permit anything a
# project had denied. The project's own is legitimate and comes first; a second
# one means an agent carries its own.
for agent in build plan review; do
    n="$(grep -c "^$agent bash allow \*$" "$TMP/flat" || true)"
    check "$agent carries no bash allow-all of its own" \
          "$([ "${n:-0}" -le 1 ] && echo ok || echo "$n")" ok
done

echo "scenario: review stays read-only"
last_edit="$(grep "^review edit " "$TMP/flat" | tail -1 | awk '{print $3}')"
check "the last edit rule for review denies" "$last_edit" deny

echo "scenario: reading history is never gated"
# The guard is worthless if it also stops an agent orienting itself, which a
# pattern like "*git *" would do.
for agent in build plan review; do
    gated=""
    for safe in log show diff status blame rev-parse describe fetch; do
        if grep -qF -- "$agent bash " "$TMP/flat" \
           && grep -qF -- " *git $safe*" "$TMP/flat"; then
            gated="$gated $safe"
        fi
    done
    check "$agent leaves read-only git alone" "${gated:-none}" none
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
