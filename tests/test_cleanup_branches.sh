#!/usr/bin/env bash
# Harness for `git cleanup branches` (bin/git-cleanup, lib/cleanup-branches and
# lib/cleanup-lib.sh), which deletes the local branches that are merged or
# pushed and have been quiet for a week. The worktrees half is
# test_cleanup_worktrees.sh; what both share is tested there, and what is
# particular to branches is tested here.
#
# Real git against real repositories in a scratch directory, with a real bare
# repository standing in for origin where a branch has to be pushed. The stubs
# are the editor, as in the worktrees test, and gh. gh is stubbed in every case,
# not only where it is the point: a real one on PATH would call GitHub, so no
# test here can be allowed to reach it. The stub prints $GH_OUT (a file of
# "branch<TAB>sha<TAB>number" lines, which is what the script's --jq asks gh
# for) and exits $GH_RC, and counts how often it was called, because "not
# called unless needed" is something worth holding the script to.
#
# The clock is CLEANUP_NOW, and every age is made by backdating the commit and
# the branch's creation, so the one-week boundary can be hit to the second.
#
# A user's own git config is shut out (GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM),
# or an editor, an alias or a default branch in it would change the answers.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
SCRIPT="$ROOT/bin/git-cleanup"
MANPAGE="$ROOT/man/man1/git-cleanup-branches.1"
WORDS=(clean force unlock unlock-force lock)

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_EDITOR="$TMP/bin/editor"

NOW=1800000000
DAY=86400
export CLEANUP_NOW=$NOW

cat > "$TMP/bin/editor" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$EDIT_DIR/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$EDIT_DIR/count"
cp -- "$1" "$EDIT_DIR/seen.$n"
[ -n "${EDIT_CMD:-}" ] && eval "$EDIT_CMD"
exit "${EDIT_RC:-0}"
STUB
chmod +x "$TMP/bin/editor"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# The two calls the script makes: `gh repo view` (which repository this is) and
# `gh api graphql` (the merged pull requests of the branches named by the
# -f hN=<branch> arguments). The real gh applies the script's --jq itself, so
# what is printed here is what that filter would have printed: one
# "pN<TAB>sha<TAB>number" line for each merged pull request of branch hN.
echo "$*" >> "${GH_LOG:?}"
# GH_FAIL_ON=graphql fails only that call, so that the second of the two
# failure messages can be reached.
if [ "${GH_RC:-0}" -ne 0 ] && { [ -z "${GH_FAIL_ON:-}" ] || [ "$2" = "${GH_FAIL_ON#api }" ] || [ "$GH_FAIL_ON" = "$2" ]; }; then
    echo "gh: no luck" >&2; exit "$GH_RC"
fi
case "$1 $2" in
    "repo view") echo "owner/repo"; exit 0 ;;
    "api graphql") ;;
    *) echo "gh stub: unexpected: $*" >&2; exit 64 ;;
esac
shift 2
while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ] && [[ $2 == h[0-9]*=* ]]; then
        k="${2%%=*}"; name="${2#*=}"
        if [ -f "${GH_OUT:-}" ]; then
            awk -F'\t' -v b="$name" -v k="p${k#h}" '$1 == b { print k "\t" $2 "\t" $3 }' "$GH_OUT"
        fi
    fi
    shift
done
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_LOG="$TMP/gh.log"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

# A repository whose only commit is 400 days old, so that a branch's age can
# only come from when the branch was made or last committed to.
world() {
    W="$TMP/$1"; mkdir -p "$W/home"
    export HOME="$W/home"
    R="$HOME/repo"; export R
    EDIT_DIR="$W/edit"; export EDIT_DIR
    GH_OUT="$W/gh.out"; export GH_OUT; unset GH_RC
    : > "$GH_LOG"
    git init -q -b main "$R"
    printf 'one\n' > "$R/f.txt"
    git -C "$R" add f.txt
    GIT_COMMITTER_DATE="@$((NOW - 400 * DAY)) +0000" git -C "$R" commit -q -m base
}

# A branch with nothing of its own, created AGE seconds ago.
mk() { GIT_COMMITTER_DATE="@$((NOW - $2)) +0000" git -C "$R" branch "$1"; }

# A branch with COUNT commits of its own, the last AGE seconds old. The checkout
# is left on main.
mkw() {
    local n=${3:-1} c
    git -C "$R" switch -q -c "$1" main
    for ((c = 1; c <= n; c++)); do
        printf '%s\n' "$1 $c" > "$R/$1-$c.txt"
        git -C "$R" add "$1-$c.txt"
        GIT_COMMITTER_DATE="@$((NOW - $2)) +0000" git -C "$R" commit -q -m "$1 work $c"
    done
    git -C "$R" switch -q main
}

origin() {
    git init -q --bare "$W/origin.git"
    git -C "$R" remote add origin "$W/origin.git"
    git -C "$R" push -q origin main
}

# run DIR ANSWER ARGS...: the output lands in $OUT and the status in $RC.
run() {
    local dir=$1 ans=$2; shift 2
    rm -rf "$EDIT_DIR"; mkdir -p "$EDIT_DIR"; : > "$GH_LOG"
    OUT="$(cd "$dir" && printf '%s' "$ans" | "$SCRIPT" branches "$@" 2>&1)"; RC=$?
}
YES=$'y\n'

has()   { git -C "$R" show-ref --verify --quiet "refs/heads/$1" && echo yes || echo no; }
edits() { cat "$EDIT_DIR/count" 2>/dev/null || echo 0; }
ghcalls() { grep -c '^api graphql' "$GH_LOG" || true; }
lockval() { git -C "$R" config --get "branch.$1.cleanupLock" || true; }

# What a row says in front of its name ("clean", "# unlock", "##"), and which
# group's heading it sits under. A name is always between two spaces and the
# next column, which is what tells feat from feat/x.
lead()  { printf '%s\n' "$OUT" | awk -v n="$1" '!/^## [1-5] / { i = index($0, "  " n "  "); if (i > 0) print substr($0, 1, i - 1) }' | sed 's/ *$//'; }
group() { printf '%s\n' "$OUT" | awk -v n="$1" '/^## [1-5] /{g=$2} !/^## [1-5] / && index($0, "  " n "  ") > 0 {print g}'; }
lineno() { printf '%s\n' "$OUT" | grep -n "  $1  " | head -1 | cut -d: -f1; }
row()   { printf '%s\n' "$OUT" | grep -- "  $1  " | head -1; }

full_world() {
    world "$1"
    origin
    git -C "$R" remote set-head origin main
    mk idle $((30 * DAY)); mk idle2 $((90 * DAY))
    mk recent $((3600)); mk mid $((3 * DAY)); mk edge-old $((7 * DAY)); mk edge-new $((7 * DAY - 1))
    mkw work $((40 * DAY)) 3; mkw work1 $((40 * DAY))
    mkw psh $((40 * DAY)); git -C "$R" push -q -u origin psh
    mkw gone $((40 * DAY)); git -C "$R" push -q -u origin gone
    git -C "$R" push -q origin --delete gone; git -C "$R" fetch -q --prune
    mk locked $((50 * DAY)); git -C "$R" config branch.locked.cleanupLock "waiting on QA"
    mk held $((30 * DAY)); git -C "$R" worktree add -q "$HOME/ws/held-wt" held
    mk onbranch $((30 * DAY))
    mkw squashed $((40 * DAY)) 2
    mk mrg $((30 * DAY))
}

echo "scenario: the list puts every branch in the first group that fits it"
full_world s1
printf 'squashed\t%s\t7\n' "$(git -C "$R" rev-parse squashed)" > "$GH_OUT"
git -C "$R" switch -q onbranch
before="$(git -C "$R" for-each-ref refs/heads | wc -l)"
run "$R" "" -n
check "exit 0" "$RC" 0
check "headings run 1 to 5, in order" "$(grep -o '^## [1-5]' <<<"$OUT" | awk '{printf "%s ", $2}')" "1 2 3 4 5 "
check "the default branch is protected" "$(group main)" 1
check "the branch you are on is protected" "$(group onbranch)" 1
check "...and says so" "$(row onbranch | grep -c '(current branch)')" 1
check "a branch held by a worktree is protected" "$(group held)" 1
check "...and names the worktree" "$(row held | grep -c "(checked out in ~/ws/held-wt)")" 1
check "a locked one is group 2" "$(group locked)" 2
check "unmerged and unpushed is work" "$(group work)" 3
check "...counting its commits" "$(row work | grep -c '3 commits only here')" 1
check "...in the singular for one" "$(row work1 | grep -c '1 commit only here')" 1
check "pushed with nothing of its own is not work" "$(group psh)" 5
check "...and says it is pushed" "$(row psh | grep -c 'pushed')" 1
check "a branch merged into main is idle" "$(group mrg)" 5
check "...and says merged" "$(row mrg | grep -c 'merged')" 1
check "a squash-merged one is idle through its pull request" "$(group squashed)" 5
check "...and names it" "$(row squashed | grep -c 'merged (PR #7)')" 1
check "clean and old is idle" "$(group idle)" 5
check "an hour old is recent" "$(group recent)" 4
check "an upstream that is gone is shown" "$(row gone | grep -c 'upstream gone')" 1
check "...and is not trusted: its commits are on no remote now, so work" "$(group gone)" 3
check "the upstream is a column" "$(row psh | grep -c 'origin/psh')" 1
check "-n changes nothing" "$(git -C "$R" for-each-ref refs/heads | wc -l)" "$before"

echo "scenario: a week, not fourteen days"
check "three days old is still recent: this week's work stays listed" "$(group mid)" 4
check "exactly a week is idle" "$(group edge-old)" 5
check "a second short of it is recent" "$(group edge-new)" 4
run "$R" "" -n --days 100
check "--days moves it: 90 days is recent under a 100-day rule" "$(group idle2)" 4
check "...and work is work however long it is" "$(group work)" 3
run "$R" "" -n --days nope
check "a bad --days is a usage error" "$RC" 2

echo "scenario: a branch made today from an old commit is not idle"
check "its tip is a year old" "$(git -C "$R" log -1 --format=%ct recent)" "$((NOW - 400 * DAY))"
run "$R" "" -n
check "and it is still recent" "$(group recent)" 4

echo "scenario: what each row starts with"
check "protected has no word" "$(lead main)" "##"
check "locked is off, and unlocks first" "$(lead locked)" "# unlock"
check "work is off" "$(lead work)" "# clean"
check "recent is off" "$(lead recent)" "# clean"
check "idle is on" "$(lead idle)" "clean"

echo "scenario: order inside a group"
check "idle: oldest first" "$([ "$(lineno idle2)" -lt "$(lineno idle)" ] && echo yes)" yes
check "recent: newest first" "$([ "$(lineno recent)" -lt "$(lineno edge-new)" ] && echo yes)" yes

echo "scenario: gh is asked once, and only when it is needed"
check "a repo with a branch of unmerged work asked once" "$(ghcalls)" 1
world s2
mk idle $((30 * DAY)); mk recent 3600
run "$R" "" -n
check "nothing unmerged: gh is never called" "$(ghcalls)" 0
world s2b
mkw a $((40 * DAY)); mkw b $((40 * DAY)); mkw c $((40 * DAY))
run "$R" "" -n
check "three unmerged branches: still one call" "$(ghcalls)" 1
check "...as a graphql request, asking for merged pull requests" "$(grep -c 'states:MERGED' "$GH_LOG")" 1
check "...with the names as variables and not in the query text" "$(grep -c 'headRefName:\$h0' "$GH_LOG")" 1
check "...and the name of the repository first" "$(grep -c '^repo view' "$GH_LOG")" 1

echo "scenario: many unmerged branches go in batches, and a branch is found in any of them"
world s3b
for n in $(seq 1 45); do mkw "u$n" $((40 * DAY)); done
printf 'u45\t%s\t45\nu2\t%s\t2\n' "$(git -C "$R" rev-parse u45)" "$(git -C "$R" rev-parse u2)" > "$GH_OUT"
run "$R" "" -n
check "45 branches are two requests, not forty-five" "$(ghcalls)" 2
check "one in the first batch is found" "$(group u2)" 5
check "one in the second batch is found" "$(group u45)" 5
check "the rest are work" "$(group u30)" 3

echo "scenario: a branch name with odd characters is asked about safely"
world s3c
mkw 'we"ird' $((40 * DAY))
printf 'we"ird\t%s\t5\n' "$(git -C "$R" rev-parse 'we"ird')" > "$GH_OUT"
run "$R" "" -n
check "a double quote in the name does not break the query" "$(group 'we"ird')" 5

echo "scenario: squash merges are matched on the tip, not the name"
world s3
mkw sq $((40 * DAY)) 2
printf 'sq\t%s\t12\n' "$(git -C "$R" rev-parse sq)" > "$GH_OUT"
run "$R" "" -n
check "name and tip match: idle" "$(group sq)" 5
printf 'sq\t%s\t12\n' "0000000000000000000000000000000000000000" > "$GH_OUT"
run "$R" "" -n
check "right name, other tip (it went on after the merge): work" "$(group sq)" 3
printf 'other\t%s\t12\n' "$(git -C "$R" rev-parse sq)" > "$GH_OUT"
run "$R" "" -n
check "right tip, other name: work" "$(group sq)" 3

echo "scenario: without gh, a squash-merged branch stays in has-work"
world s4
mkw sq $((40 * DAY)) 2
GH_RC=1 run "$R" "" -n
check "it is has work" "$(group sq)" 3
check "the run says why, once" "$(grep -c 'gh could not tell which repository' <<<"$OUT")" 1
check "exit 0 all the same" "$RC" 0
unset GH_RC
mkw sq2 $((40 * DAY))
GH_RC=1 run "$R" "" -n
check "two such branches still say it once" "$(grep -c 'gh could not' <<<"$OUT")" 1
GH_RC=1 GH_FAIL_ON=graphql run "$R" "" -n
check "a failure of the request itself is said too" "$(grep -c 'gh could not list merged pull requests' <<<"$OUT")" 1
check "...and the branch stays in has work" "$(group sq)" 3

echo "scenario: the default branch is found, in order"
world s5
origin
mk idle $((30 * DAY))
git -C "$R" branch -m main trunk
git -C "$R" push -q origin trunk; git -C "$R" remote set-head origin trunk
git -C "$R" switch -q idle
run "$R" "" -n
check "origin/HEAD says trunk: protected" "$(group trunk)" 1
check "...and said to be the default" "$(row trunk | grep -c '(default branch)')" 1
git -C "$R" remote remove origin
git -C "$R" switch -q trunk
git -C "$R" branch -m trunk main
run "$R" "" -n
check "without a remote, main is found" "$(row main | grep -c '(default branch)')" 1
git -C "$R" branch -m main elsewhere
git -C "$R" branch master
run "$R" "" -n
check "init.defaultBranch is tried, then master" "$(row master | grep -c '(default branch)')" 1

echo "scenario: -y deletes the idle ones and nothing else"
full_world s6
printf 'squashed\t%s\t7\n' "$(git -C "$R" rev-parse squashed)" > "$GH_OUT"
run "$R" "" -y
check "exit 0" "$RC" 0
for name in idle idle2 edge-old mrg psh squashed onbranch; do
    check "$name is gone" "$(has "$name")" no
done
for name in recent edge-new work work1 gone locked held main; do
    check "$name stays" "$(has "$name")" yes
done
check "the lock is untouched" "$(lockval locked)" "waiting on QA"
check "every deletion says what it was at" "$(grep -c '^deleted   .* (was [0-9a-f]\{7,\})$' <<<"$OUT")" 7

echo "scenario: a deleted branch can be brought back from what is printed"
world s7
mk idle $((30 * DAY))
tip="$(git -C "$R" rev-parse --short idle)"
run "$R" "" -y
check "it is gone" "$(has idle)" no
check "the line names the commit" "$(grep -c "^deleted   idle (was $tip)" <<<"$OUT")" 1
git -C "$R" branch idle "$tip"
check "and git branch brings it back" "$(has idle)" yes

echo "scenario: the editor opens, and what it saves is what happens"
full_world s8
run "$R" "$YES"
check "exit 0" "$RC" 0
check "the editor ran once" "$(edits)" 1
check "it asked before deleting anything" "$(grep -c 'Will delete' <<<"$OUT")" 1
check "idle went" "$(has idle)" no
check "work stayed" "$(has work)" yes
check "the summary" "$(grep -c '^[0-9]* deleted, 0 locked, 0 not done' <<<"$OUT")" 1

full_world s8b
run "$R" "n"$'\n'
check "answering no cancels" "$RC" 1
check "...and deletes nothing" "$(has idle)" yes
EDIT_RC=1 run "$R" "$YES"
check "quitting the editor with an error cancels" "$RC" 1
check "...and deletes nothing" "$(has idle)" yes

echo "scenario: the file documents every word it reads"
full_world s9
run "$R" "n"$'\n'
for w in "${WORDS[@]}"; do
    check "the header explains $w" "$(grep -Ec "^## +$w +[a-z]" "$EDIT_DIR/seen.1")" 1
done
check "discard is not one of them" "$(grep -c '^## +discard ' "$EDIT_DIR/seen.1")" 0
run "$R" "" -h
check "-h exits 0" "$RC" 0
for w in "${WORDS[@]}"; do
    check "-h explains $w" "$(grep -Ec "^  $w +[a-z]" <<<"$OUT")" 1
done
check "-h gives the one-week default" "$(grep -c 'default 7)' <<<"$OUT")" 1

echo "scenario: turning every line on does not throw work away"
full_world s10
EDIT_CMD='sed -i "s/^# //" "$1"' run "$R" "$YES"
check "exit 1: some were refused" "$RC" 1
check "the notes and the protected rows did not become lines" "$(grep -c 'unknown word\|is protected' <<<"$OUT")" 0
for name in work work1; do
    check "$name was refused" "$(grep -c "^refused   $name: has work" <<<"$OUT")" 1
    check "$name is still there" "$(has $name)" yes
done
# work, work1, gone, and squashed too, since no pull request is stubbed here.
check "the refusal says what to write" "$(grep -c 'use force to delete it anyway' <<<"$OUT")" 4
check "the commits are still reachable" "$(git -C "$R" rev-list --count work --not main)" 3
check "a recent one goes on a plain clean" "$(has recent)" no
check "the locked one was unlocked and went" "$(has locked)" no
check "the default branch is untouched" "$(has main)" yes
check "so is the held branch" "$(has held)" yes

echo "scenario: force deletes unmerged work, only where it is written"
full_world s11
EDIT_CMD='sed -i -E "s|^# clean( +work )|force\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "the prompt says commits are lost" "$(grep -c '1 of them losing commits that are neither merged nor pushed' <<<"$OUT")" 1
check "work went" "$(has work)" no
check "an unchanged line next to it did not" "$(has work1)" yes

echo "scenario: a locked branch needs unlocking, in the word"
full_world s12
EDIT_CMD='sed -i -E "s|^# unlock( +locked )|clean\1|" "$1"' run "$R" "$YES"
check "clean on a locked one is refused" "$(grep -c '^refused   locked: locked (waiting on QA); use unlock or unlock-force' <<<"$OUT")" 1
check "exit 1" "$RC" 1
check "it is still there, and still locked" "$(has locked) $(lockval locked)" "yes waiting on QA"
full_world s12b
EDIT_CMD='sed -i -E "s|^# unlock( +locked )|unlock\1|" "$1"' run "$R" "$YES"
check "unlock deletes it" "$(has locked)" no
check "and no marker is left behind" "$(git -C "$R" config --get-regexp 'cleanuplock' | wc -l)" 0

world s12c
mkw lk $((50 * DAY)); git -C "$R" config branch.lk.cleanupLock "waiting on QA"
EDIT_CMD='sed -i -E "s|^# unlock( +lk )|unlock\1|" "$1"' run "$R" "$YES"
check "unlock alone does not delete unmerged work" "$(grep -c 'has work (1 commit only here); use unlock-force to delete it anyway' <<<"$OUT")" 1
check "so it is not unlocked either" "$(lockval lk)" "waiting on QA"
EDIT_CMD='sed -i -E "s|^# unlock( +lk )|unlock-force\1|" "$1"' run "$R" "$YES"
check "unlock-force does" "$(has lk)" no

echo "scenario: lock keeps a branch, and takes a reason"
world s13
mk keep $((30 * DAY)); mk plain $((30 * DAY)); mk other $((30 * DAY))
EDIT_CMD='sed -i -E "s|^clean( +keep )|lock \"release 1.4, ticket #42\" \1|; s|^clean( +plain )|lock\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "the reason is the marker's value" "$(lockval keep)" "release 1.4, ticket #42"
check "it is said back" "$(grep -c '^locked    keep: release 1.4, ticket #42' <<<"$OUT")" 1
check "no reason: the command says it made the lock" "$(lockval plain)" "kept by git cleanup branches"
check "both are kept" "$(has keep)$(has plain)" yesyes
check "the one left on was deleted" "$(has other)" no
check "the prompt counts the locks" "$(grep -c 'Will delete 1; lock 2. Go ahead?' <<<"$OUT")" 1
run "$R" "" -n
check "next time they are in group 2" "$(group keep)$(group plain)" 22
check "the row shows the reason" "$(row keep | grep -c 'locked: release 1.4, ticket #42')" 1
EDIT_CMD='sed -i -E "s|^# unlock( +keep )|lock \"new reason\" \1|" "$1"' run "$R" "$YES"
check "a new reason replaces the old one" "$(lockval keep)" "new reason"
EDIT_CMD='sed -i -E "s|^# unlock( +keep )|lock\1|" "$1"' run "$R" "$YES"
check "lock with no reason leaves an existing one" "$(lockval keep)" "new reason"
check "...and says it already was" "$(grep -c '^locked    keep (already)' <<<"$OUT")" 1

echo "scenario: the lock follows a rename and goes with a delete"
world s13b
mk keep $((30 * DAY)); git -C "$R" config branch.keep.cleanupLock "why"
git -C "$R" branch -m keep kept
check "a rename carries the marker" "$(lockval kept)" "why"
git -C "$R" branch -D -q kept
check "a delete takes it" "$(git -C "$R" config --get-regexp 'cleanuplock' | wc -l)" 0

echo "scenario: a bad list reopens the editor with the faults at the top"
world s14
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^clean( +idle )|frob\1|" "$1"; else sed -i -E "s|^frob|clean|" "$1"; fi' run "$R" "$YES"
check "the editor was opened twice" "$(edits)" 2
check "the second time it names the word, and what is allowed" "$(grep -c '^## error: line [0-9]*: unknown word "frob": use clean, force, unlock, unlock-force or lock' "$EDIT_DIR/seen.2")" 1
check "fixed, it carries on" "$(has idle)" no

world s14b
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^clean( +idle )|discard\1|" "$1"; else sed -i -E "s|^discard|clean|" "$1"; fi' run "$R" "$YES"
check "discard is not a word for branches" "$(grep -c 'unknown word "discard"' "$EDIT_DIR/seen.2")" 1

world s14c
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^##( +main )|clean\1|" "$1"; else sed -i -E "/^clean +main /d" "$1"; fi' run "$R" "$YES"
check "turning the default branch on is an error" "$(grep -c 'main is protected (default branch) and is never cleaned' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no
check "main is untouched" "$(has main)" yes

world s14d
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then echo "clean nope" >> "$1"; else sed -i "/^clean nope/d" "$1"; fi' run "$R" "$YES"
check "a branch that is not listed is an error" "$(grep -c 'no listed branch starts at' "$EDIT_DIR/seen.2")" 1

echo "scenario: a branch that changed while the editor was open is not deleted"
world s15
mk idle $((30 * DAY)); mk other $((30 * DAY))
EDIT_CMD='git -C "$R" switch -q idle; echo x > "$R/new.txt"; git -C "$R" add new.txt; git -C "$R" commit -q -m late; git -C "$R" switch -q main' run "$R" "$YES"
check "exit 1" "$RC" 1
check "it says what changed" "$(grep -c '^refused   idle: changed while the editor was open (was idle, now has work)' <<<"$OUT")" 1
check "the new commit survived" "$(has idle)" yes
check "the other one still went" "$(has other)" no

world s15b
mk idle $((30 * DAY))
EDIT_CMD='git -C "$R" worktree add -q "$HOME/ws/late" idle' run "$R" "$YES"
check "a worktree made on it meanwhile protects it" "$(grep -c '^refused   idle: protected (checked out in ~/ws/late)' <<<"$OUT")" 1
check "it is still there" "$(has idle)" yes

echo "scenario: a branch held by a worktree"
world s16
mk held $((30 * DAY))
git -C "$R" worktree add -q "$HOME/ws/h" held
run "$R" "" -n
check "it is protected" "$(group held)" 1
rm -rf "$HOME/ws/h"
run "$R" "" -n
check "with its directory gone it still is" "$(group held)" 1
check "...and the row points at the cure" "$(row held | grep -c 'directory is gone: git cleanup worktrees clears it')" 1
git -C "$R" worktree prune
run "$R" "" -n
check "once pruned it is judged on its own" "$(group held)" 5

echo "scenario: a failed delete puts the lock back"
world s17
mk lk $((30 * DAY)); git -C "$R" config branch.lk.cleanupLock "waiting on QA"
EDIT_CMD='sed -i -E "s|^# unlock( +lk )|unlock\1|" "$1"; : > "$R/.git/refs/heads/lk.lock"' run "$R" "$YES"
rm -f "$R/.git/refs/heads/lk.lock"
check "exit 1" "$RC" 1
check "the failure is reported" "$(grep -c '^failed    lk:' <<<"$OUT")" 1
check "it is locked again, with its reason" "$(lockval lk)" "waiting on QA"
check "and still there" "$(has lk)" yes

echo "scenario: nothing to do"
world s18
run "$R" ""
check "only the default branch: exit 0" "$RC" 0
check "...says so" "$(grep -c 'nothing but protected branches here' <<<"$OUT")" 1
check "...without opening the editor" "$(edits)" 0
world s18b
mk recent 3600
run "$R" "" -y
check "-y with nothing idle: exit 0" "$RC" 0
check "...says so" "$(grep -c 'no idle branches' <<<"$OUT")" 1
check "...and leaves the recent one" "$(has recent)" yes

echo "scenario: progress is shown on a terminal and never in a pipe"
world s20
mkw a $((40 * DAY)); mkw b $((40 * DAY)); mk idle $((30 * DAY))
run "$R" "" -n
check "piped: no progress text at all" "$(grep -c 'checking branch\|reading branches\|asking GitHub' <<<"$OUT")" 0
check "piped: no carriage returns" "$(printf '%s' "$OUT" | grep -c $'\r')" 0
if command -v script >/dev/null; then
    tty="$(cd "$R" && script -qec "$SCRIPT branches -n" /dev/null 2>&1 | tr '\r' '\n')"
    check "on a terminal: the counting stage" "$(grep -ac 'checking branch [0-9]* of 4' <<<"$tty" | sed 's/^[1-9][0-9]*$/some/')" some
    check "on a terminal: the GitHub stage" "$(grep -ac 'asking GitHub about 2 unmerged branches' <<<"$tty" | sed 's/^[1-9][0-9]*$/some/')" some
    check "on a terminal: the reading stage" "$(grep -ac 'reading branches, [0-9]* of 4' <<<"$tty" | sed 's/^[1-9][0-9]*$/some/')" some
    check "on a terminal: the list is still printed" "$(grep -ac '^## 5 idle' <<<"$tty")" 1
else
    echo "  SKIPPED: script is not installed, so there is no terminal to test the progress line on"
fi

echo "scenario: applying many deletions does not reload every branch for each one"
world s21
for n in $(seq 1 30); do mk "m$n" $((30 * DAY)); done
GIT_TRACE2_PERF="$TMP/perf-s21.log" run "$R" "" -y
check "all thirty went" "$(grep -c '^deleted' <<<"$OUT")" 30
# The one for-each-ref that lists every branch is made up front. A full reload
# for each deletion would make thirty more; a lookup of a single branch names
# its ref (refs/heads/m7) and is not the same command line.
check "for-each-ref over every branch: once" "$(grep -ac "| start .*git for-each-ref refs/heads '--format" "$TMP/perf-s21.log")" 1
check "for-each-ref of a single branch: once per deletion" "$(grep -ac "| start .*git for-each-ref refs/heads/m[0-9]* '--format" "$TMP/perf-s21.log")" 30

echo "scenario: the manual and the dispatcher"
check "the page has an entry for every word the script reads" "$(for w in "${WORDS[@]}"; do grep -B1 -xF ".B ${w//-/\\-}" "$MANPAGE" | grep -cx '\.TP'; done | tr '\n' ' ')" "1 1 1 1 1 "
if command -v man >/dev/null; then
    check "the page renders without warnings" "$(man --warnings -l "$MANPAGE" 2>&1 >/dev/null | wc -l)" 0
    check "man finds it from PATH alone" "$(PATH="$ROOT/bin:$PATH" MANPATH= man -w git-cleanup-branches 2>/dev/null)" "$MANPAGE"
    out="$(PATH="$ROOT/bin:$PATH" MANPATH= MANPAGER=cat PAGER=cat MANWIDTH=80 git cleanup branches --help 2>&1 </dev/null)"; rc=$?
    check "git cleanup branches --help works through git" "$rc" 0
    check "...and is the branches manual" "$(grep -c '^THE WORDS' <<<"$out")" 1
else
    echo "  SKIPPED: man is not installed, so the page is not rendered or looked up"
fi
world s19
mk idle $((30 * DAY))
for spelling in branches branch br; do
    rm -rf "$EDIT_DIR"; mkdir -p "$EDIT_DIR"
    OUT="$(cd "$R" && "$SCRIPT" "$spelling" -n 2>&1)"; RC=$?
    check "$spelling lists the branches" "$RC$(grep -c '  idle  ' <<<"$OUT")" 01
done
OUT="$(cd "$R" && "$SCRIPT" 2>&1)"
check "the usage lists branches" "$(grep -c 'branches' <<<"$OUT")" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
