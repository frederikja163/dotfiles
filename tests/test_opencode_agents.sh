#!/usr/bin/env bash
# Harness for opencode/: that every mode which can reach a shell gates the
# shared set of git commands with the action it is meant to, that the commit
# agent confirms rather than denies, and that nobody re-opens what a project
# has closed.
#
# This exists because the guard is written out four times -- build, plan and
# review share one list, while the commit agent carries an anchored variant of
# its own -- and the config format has no way to share a list. A plugin could
# have injected it from one place and was rejected: a plugin that fails to load
# takes the guard with it silently, which is the exact failure being guarded
# against. Copies are safer and drift is the price, so the drift is what gets
# tested. Why the commit agent's patterns differ is set out in agent/commit.md.
#
# Asserted against `opencode api get /api/agent`, which returns each agent's
# fully resolved permission rules -- the merge of opencode's defaults, this
# repo's project config and the agent's own. That is the thing that actually
# decides whether a command runs, rather than what the files appear to say.
#
# V1 read the same rules out of `opencode agent list`. V2 dropped that
# subcommand and renamed the rule fields (`bash` to `shell`, `pattern` to
# `resource`, `action` to `effect`), so the source and the flattening below
# changed with it.
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

if ! opencode api get /api/agent > "$TMP/raw" 2>/dev/null; then
    echo "  FAIL opencode api get /api/agent did not run" >&2
    exit 1
fi

# One line per rule: "<agent> <action> <effect> <resource>". `/api/agent`
# returns `{location, data:[{id, permissions:[{action, resource, effect}]}]}`,
# already resolved, so there is nothing to stitch together the way the V1
# console listing required.
python3 - "$TMP/raw" > "$TMP/flat" <<'PARSE'
import sys, json
doc = json.load(open(sys.argv[1]))
agents = doc.get("data", doc) if isinstance(doc, dict) else doc
for a in agents:
    for r in a.get("permissions", []):
        print(a.get("id", ""), r.get("action", ""), r.get("effect", ""), r.get("resource", ""))
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

# Per agent and command, because the modes do not share one action:
#
# - review denies everything: read-only by construction.
# - build and plan deny commit, which is the commit agent's job, and ask on the
#   rest so the user decides.
# - commit is checked separately: its whole job is git, so it confirms the
#   destructive commands instead of denying them and refuses only push, and its
#   patterns are anchored so a commit message cannot trip them.
expected_action() {
    case "$1:$2" in
        review:*)      printf 'deny' ;;
        build:commit)  printf 'deny' ;;
        plan:commit)   printf 'deny' ;;
        *)             printf 'ask' ;;
    esac
}

echo "scenario: build, plan and review gate the shared git commands"
for agent in build plan review; do
    missing=""; wrongaction=""

    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        want="$(expected_action "$agent" "$cmd")"
        pattern="*git $cmd*"
        # The last rule for this agent and pattern is the one that decides.
        got="$(grep -F -- "$agent shell " "$TMP/flat" \
               | grep -F -- " $pattern" | tail -1 | awk '{print $3}')"
        if [ -z "$got" ]; then
            missing="$missing $cmd"
        elif [ "$got" != "$want" ]; then
            wrongaction="$wrongaction $cmd($got)"
        fi
    done < <(shared_commands)

    check "$agent gates every shared git command" "${missing:-none}" none
    check "$agent uses the action each command should have" "${wrongaction:-none}" none
done

echo "scenario: commit confirms the shared commands and refuses only push"
# The commit agent is the mode whose whole job is git, so it does not deny the
# shared list -- the destructive commands confirm and only push is refused. Its
# patterns are anchored (no leading "*") on purpose: a commit message is part
# of the matched command line, and an unanchored guard blocked any commit whose
# message happened to mention the command. That is also why `commit` itself is
# allowed with a wildcard, so a chained `git add ... && git commit` still gets
# past the project's own ask.
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    [ "$cmd" = commit ] && continue
    case "$cmd" in
        push) want=deny ;;
        *)    want=ask ;;
    esac
    got="$(grep -F -- "commit shell " "$TMP/flat" \
           | grep -F -- " git $cmd*" | tail -1 | awk '{print $3}')"
    check "commit: $cmd" "${got:-missing}" "$want"
done < <(shared_commands)
commit_rule="$(grep -F -- "commit shell " "$TMP/flat" | grep -F -- ' *git commit*' | tail -1 | awk '{print $3}')"
check "commit: commit is allowed outright" "$commit_rule" allow
# And no destructive guard on it may lead with "*", or a message could trip it.
wild="$(grep -F -- "commit shell " "$TMP/flat" \
        | grep -E ' (deny|ask) \*git (push|pull|merge|am|cherry-pick|revert|rebase|reset|filter-branch|filter-repo|replace|update-ref|tag|branch|reflog|gc|prune|stash|restore|checkout)' \
        | wc -l)"
check "commit carries no wildcarded guard a message could trip" "$wild" 0

echo "scenario: no agent re-opens what a project has closed"
# An agent's rules are appended after the project's and the last match wins, so
# a broad allow belonging to an agent would silently re-permit anything a
# project had denied. V2's own base policy is a single `*: * allow`; a second
# wildcard allow, or a shell-scoped one, means an agent carries its own. (V1
# spelled the same guard as `bash allow *`; V2 renamed the action to shell and
# moved the base policy from the tool to `*`.)
for agent in build plan review commit; do
    broad="$(grep -cE "^$agent (\*|shell) allow \*$" "$TMP/flat" || true)"
    shell="$(grep -cE "^$agent shell allow \*$" "$TMP/flat" || true)"
    verdict=ok
    [ "${broad:-0}" -le 1 ] || verdict="$broad wildcard allow-alls"
    [ "${shell:-0}" -eq 0 ] || verdict="$verdict; $shell shell allow-alls"
    check "$agent carries no broad allow-all of its own" "$verdict" ok
done

echo "scenario: review and commit never edit files"
for agent in review commit; do
    last_edit="$(grep "^$agent edit " "$TMP/flat" | tail -1 | awk '{print $3}')"
    check "the last edit rule for $agent denies" "$last_edit" deny
done

echo "scenario: reading history is never gated"
# The guard is worthless if it also stops an agent orienting itself, which a
# pattern like "*git *" would do.
for agent in build plan review commit; do
    gated=""
    for safe in log show diff status blame rev-parse describe fetch; do
        if grep -F -- "$agent shell " "$TMP/flat" | grep -qF -- " *git $safe*"; then
            gated="$gated $safe"
        fi
    done
    check "$agent leaves read-only git alone" "${gated:-none}" none
done

echo "scenario: only the commit agent may flatten the index"
# Flattening the user's scratch staging is the commit agent's own job. It is an
# index-only reset, so it sits after the broader reset ask and wins -- last
# match wins -- and it must not appear on any other mode.
for agent in build plan review commit; do
    ask_line="$(grep -nF -- "$agent shell ask git reset*" "$TMP/flat" | tail -1 | cut -d: -f1)"
    allow_line="$(grep -nF -- "$agent shell allow *git reset --mixed HEAD*" "$TMP/flat" | tail -1 | cut -d: -f1)"
    want_allow=no
    [ "$agent" = commit ] && want_allow=yes
    got_allow=no
    [ -n "$allow_line" ] && got_allow=yes
    check "$agent allows only a flattened index" "$got_allow" "$want_allow"
    if [ "$got_allow" = yes ]; then
        order=no
        [ -n "$ask_line" ] && [ "$allow_line" -gt "$ask_line" ] && order=yes
        check "$agent orders that allow after the reset ask" "$order" yes
    fi
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
