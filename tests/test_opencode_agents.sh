#!/usr/bin/env bash
# Harness for opencode/: that every mode which can reach a shell gates the
# shared set of git commands with the action it is meant to, that no mode can
# push at all, that the commit agent's `git commit` allow stays last in its
# list, and that nobody re-opens what a project has closed.
#
# This exists because the guard is written out four times -- build, plan,
# review and commit each carry the same list -- and the config format has no way
# to share a list. A plugin could
# have injected it from one place and was rejected: a plugin that fails to load
# takes the guard with it silently, which is the exact failure being guarded
# against. Copies are safer and drift is the price, so the drift is what gets
# tested. Why the commit agent's action for each differs is set out in
# agent/commit.md.
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
# - push is denied in every mode, with no exception: it needs the user's SSH
#   key or an HTTPS token, and "ask" would not avoid that -- approving the
#   prompt is what puts the credential in reach. Agents hand the push back.
# - review denies everything: read-only by construction.
# - commit allows `git commit`, because the split table it shows first is the
#   approval, and asks on the rest.
# - plan denies commit: it will not edit a file, so any commit it made would be
#   of someone else's work.
# - build asks on everything else, commit included -- switching to the commit
#   agent is the better answer, not the only one.
expected_action() {
    case "$1:$2" in
        *:push)        printf 'deny' ;;
        review:*)      printf 'deny' ;;
        commit:commit) printf 'allow' ;;
        plan:commit)   printf 'deny' ;;
        *)             printf 'ask' ;;
    esac
}

echo "scenario: every shell-capable mode gates the shared git commands"
for agent in build plan review commit; do
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

echo "scenario: no mode may push, whatever it is told"
# Not a safety rule about the push itself: it needs the user's SSH key or an
# HTTPS token, and the only way an agent could run one is if the credential
# were within its reach. "deny" rather than "ask" because approving the prompt
# is exactly the thing being avoided. Checked on its own as well as through the
# shared list, because this is the one entry that must never be relaxed to ask.
for agent in build plan review commit; do
    # Any rule whose resource mentions the command, anchored or not, so a
    # pattern rewritten to "git push*" is still caught.
    got="$(grep -F -- "$agent shell " "$TMP/flat" | grep -E 'git push' | tail -1 | awk '{print $3}')"
    check "$agent refuses to push" "${got:-missing}" deny
done

echo "scenario: commit's git commit allow stays last in its list"
# A rule is matched against the whole command line, heredoc body included, so a
# commit whose message mentions rebasing or pushing matches those rules too.
# Last match wins, so the `*git commit*` allow has to sit after every other
# rule or this agent trips over its own commit messages -- which is exactly
# what sank the earlier version of this list. A real `git push` carries no
# "git commit" anywhere in it, so the deny above still stands.
commit_allow="$(grep -nF -- "commit shell allow *git commit*" "$TMP/flat" | tail -1 | cut -d: -f1)"
last_other="$(grep -nE "^commit shell (ask|deny) " "$TMP/flat" | tail -1 | cut -d: -f1)"
check "commit: git commit is allowed" "${commit_allow:+yes}" yes
order=no
[ -n "$commit_allow" ] && [ -n "$last_other" ] && [ "$commit_allow" -gt "$last_other" ] && order=yes
check "commit: the git commit allow comes after every other rule" "$order" yes
# The flattening step of its own documented workflow, which would prompt on
# every run if the list reached it. agent/commit.md says why it is restore and
# not `git reset --mixed HEAD`.
restore="$(grep -F -- "commit shell " "$TMP/flat" | grep -cF -- "git restore" || true)"
check "commit leaves git restore ungated" "${restore:-0}" 0

echo "scenario: no agent re-opens what a project has closed"
# An agent's rules are appended after the project's and the last match wins, so
# a broad allow belonging to an agent would silently re-permit anything a
# project had denied. V2's own base policy is a single `*: * allow`; a second
# wildcard allow, or a shell-scoped one, means an agent carries its own. (V1
# spelled the same guard as `bash allow *`; V2 renamed the action to shell and
# moved the base policy from the tool to `*`.)
# The commit agent used to be exempt, when it had an open shell. It no longer
# has one -- its only allow is the narrow `*git commit*` -- so it is checked
# with the rest.
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

echo "scenario: no mode carves an allow out of the git list"
# The list is only worth having if nothing sits after it re-permitting a
# member. `*git commit*` on the commit agent is the single deliberate
# exception, checked for its position above.
for agent in build plan review commit; do
    carve="$(grep -E "^$agent shell allow .*git " "$TMP/flat" \
             | grep -vF -- "commit shell allow *git commit*" | awk '{print $4}' | tr '\n' ' ')"
    check "$agent carves no allow out of the git list" "${carve:-none}" none
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
