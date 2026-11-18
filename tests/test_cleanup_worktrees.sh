#!/usr/bin/env bash
# Harness for `git cleanup worktrees` (bin/git-cleanup, lib/cleanup-worktrees and
# lib/cleanup-lib.sh), which removes the worktrees nobody has touched in 14
# days.
#
# Real git against real repositories in a scratch directory: the script's whole
# job is reading what git says about a worktree and arranging git's arguments,
# and the answers that matter (what was removed, what refused to go, what is
# locked afterwards) are on disk. The only stub is the editor. GIT_EDITOR is a
# script that records the file it was handed and then runs whatever EDIT_CMD
# says to it, which stands in for a person editing the list.
#
# The clock is CLEANUP_NOW, and every age here is made by backdating the
# commit and the worktree's creation, so the fourteen-day boundary can be hit
# to the second instead of being "about a fortnight".
#
# A user's own git config is shut out (GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM),
# or an editor, an alias or a default branch in it would change the answers.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
SCRIPT="$ROOT/bin/git-cleanup"
MANPAGE="$ROOT/man/man1/git-cleanup-worktrees.1"
OVERVIEW="$ROOT/man/man1/git-cleanup.1"
WORDS=(clean force discard unlock unlock-force lock)

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

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

# A repository whose only commit is 400 days old, so that a worktree's age can
# only come from when the worktree was made.
world() {
    W="$TMP/$1"; mkdir -p "$W/home"
    export HOME="$W/home"
    R="$HOME/repo"
    EDIT_DIR="$W/edit"; export EDIT_DIR
    git init -q -b main "$R"
    printf 'one\n' > "$R/f.txt"
    git -C "$R" add f.txt
    GIT_COMMITTER_DATE="@$((NOW - 400 * DAY)) +0000" git -C "$R" commit -q -m base
}

mk()  { GIT_COMMITTER_DATE="@$((NOW - $2)) +0000" git -C "$R" worktree add -q -b "${1// /-}" "$HOME/ws/$1"; }
mkd() { GIT_COMMITTER_DATE="@$((NOW - $2)) +0000" git -C "$R" worktree add -q --detach "$HOME/ws/$1"; }

# Every kind of worktree at once, so one listing can be asserted whole.
full_world() {
    world "$1"
    mk idle $((30 * DAY)); mk idle2 $((90 * DAY))
    mk recent $((2 * DAY))
    mk edge-old $((14 * DAY)); mk edge-new $((14 * DAY - 1))
    mk work $((40 * DAY)); echo x > "$HOME/ws/work/new.txt"
    mk modified $((40 * DAY)); echo two >> "$HOME/ws/modified/f.txt"
    mkd detached $((40 * DAY))
    GIT_COMMITTER_DATE="@$((NOW - 40 * DAY)) +0000" git -C "$HOME/ws/detached" commit -q --allow-empty -m wip
    mkd detached-safe $((40 * DAY))
    mk locked $((50 * DAY)); git -C "$R" worktree lock --reason "waiting on QA" "$HOME/ws/locked"
    mk "with space" $((30 * DAY)); mk with $((30 * DAY))
    mk missing $((30 * DAY)); rm -rf "$HOME/ws/missing"
}

# run DIR ANSWER ARGS...: the output lands in $OUT and the status in $RC. The
# answer is what the final "go ahead?" reads from stdin.
run() {
    local dir=$1 ans=$2; shift 2
    rm -rf "$EDIT_DIR"; mkdir -p "$EDIT_DIR"
    OUT="$(cd "$dir" && printf '%s' "$ans" | "$SCRIPT" worktrees "$@" 2>&1)"; RC=$?
}
YES=$'y\n'

has()        { [ -d "$HOME/ws/$1" ] && echo yes || echo no; }
registered() { git -C "$R" worktree list --porcelain | grep -c "^worktree $HOME/ws/$1\$"; }
lockedline() { git -C "$R" worktree list --porcelain | grep -A4 "^worktree $HOME/ws/$1\$" | grep '^locked' || true; }
edits()      { cat "$EDIT_DIR/count" 2>/dev/null || echo 0; }

# What a row says in front of its path ("clean", "# unlock", "##"), and which
# group's heading it sits under. A path is always followed by two spaces, which
# is what tells ~/ws/with from ~/ws/with space.
lead()   { printf '%s\n' "$OUT" | sed -nE "s|^(.*[^ ]) +~/$1( {2}.*)?\$|\1|p"; }
group()  { printf '%s\n' "$OUT" | awk -v p="~/$1" '/^## [1-5] /{g=$2} index($0, " " p "  ") > 0 {print g}'; }
lineno() { printf '%s\n' "$OUT" | grep -n " ~/$1  " | head -1 | cut -d: -f1; }

echo "scenario: the list puts every worktree in the first group that fits it"
full_world s1
before="$(git -C "$R" worktree list | wc -l)"
run "$R" "" -n
check "exit 0" "$RC" 0
check "headings run 1 to 5, in order" "$(grep -o '^## [1-5]' <<<"$OUT" | awk '{printf "%s ", $2}')" "1 2 3 4 5 "
check "the main worktree is protected" "$(group repo)" 1
check "a locked one is group 2" "$(group ws/locked)" 2
check "untracked files are work" "$(group ws/work)" 3
check "a tracked change is work" "$(group ws/modified)" 3
check "a detached HEAD holding commits nothing else has is work" "$(group ws/detached)" 3
check "a detached HEAD whose commits are on a branch is not" "$(group ws/detached-safe)" 5
check "clean and active this week is recent" "$(group ws/recent)" 4
check "clean and idle is idle" "$(group ws/idle)" 5
check "a missing directory is idle" "$(group ws/missing)" 5
check "a path with a space in it is found" "$(group "ws/with space")" 5
check "and so is the shorter path it starts with" "$(group ws/with)" 5

check "-n changes nothing" "$(git -C "$R" worktree list | wc -l)" "$before"

echo "scenario: a worktree made today from an old commit is not idle"
# The reason activity is not the commit date: a worktree's HEAD starts as
# whatever it was branched from, and this one starts as a 400-day-old commit.
check "its commit is a year old" "$(git -C "$HOME/ws/recent" log -1 --format=%ct)" "$((NOW - 400 * DAY))"
check "and it is still recent" "$(group ws/recent)" 4

echo "scenario: the fourteen-day boundary"
check "exactly 14 days is idle" "$(group ws/edge-old)" 5
check "a second short of that is recent" "$(group ws/edge-new)" 4

echo "scenario: what each row starts with"
check "protected has no word" "$(lead repo)" "##"
check "locked is off, and unlocks first" "$(lead ws/locked)" "# unlock"
check "work is off" "$(lead ws/work)" "# clean"
check "recent is off" "$(lead ws/recent)" "# clean"
check "idle is on" "$(lead ws/idle)" "clean"
check "a missing directory is on" "$(lead ws/missing)" "clean"

echo "scenario: order inside a group"
check "idle: oldest first" "$([ "$(lineno ws/idle2)" -lt "$(lineno ws/idle)" ] && echo yes)" yes
check "idle: ...and the youngest last" "$([ "$(lineno ws/idle)" -lt "$(lineno ws/edge-old)" ] && echo yes)" yes
check "recent: newest first" "$([ "$(lineno ws/recent)" -lt "$(lineno ws/edge-new)" ] && echo yes)" yes

echo "scenario: rows say why"
check "the lock reason" "$(grep -c 'locked: waiting on QA' <<<"$OUT")" 1
check "untracked files counted" "$(grep -c '1 untracked' <<<"$OUT")" 1
check "modified files counted" "$(grep -c '1 modified' <<<"$OUT")" 1
check "commits on no branch" "$(grep -c 'detached, commits on no branch' <<<"$OUT")" 1
check "a missing directory" "$(grep -c 'directory missing' <<<"$OUT")" 1

echo "scenario: -y cleans the idle ones and nothing else"
full_world s2
run "$R" "" -y
check "exit 0" "$RC" 0
check "seven removed" "$(grep -c '^removed' <<<"$OUT")" 7
for name in idle idle2 edge-old detached-safe "with space" with; do
    check "$name is gone" "$(has "$name")" no
done
check "the missing one is no longer registered" "$(registered missing)" 0
for name in recent edge-new work modified detached locked; do
    check "$name stays" "$(has "$name")" yes
done
check "the main worktree stays" "$([ -d "$R/.git" ] && echo yes)" yes
check "the lock is untouched" "$(lockedline locked | cut -d' ' -f2-)" "waiting on QA"

echo "scenario: the folder goes with the last worktree, and only then"
world s3
mk only $((30 * DAY))
run "$R" "" -y
check "the worktree is gone" "$(has only)" no
check "and so is the folder it was in" "$([ -d "$HOME/ws" ] && echo yes || echo no)" no

world s3b
mk a $((30 * DAY)); mk b $((2 * DAY))
run "$R" "" -y
check "a goes" "$(has a)" no
check "the folder stays while b is in it" "$(has b)" yes

world s3c
mk a $((30 * DAY)); echo stray > "$HOME/ws/stray.txt"
run "$R" "" -y
check "a goes" "$(has a)" no
check "a stray file keeps the folder" "$(cat "$HOME/ws/stray.txt" 2>/dev/null)" stray

world s3d
mk deep/a $((30 * DAY))
run "$R" "" -y
check "the worktree is gone" "$([ -d "$HOME/ws/deep/a" ] && echo yes || echo no)" no
check "its folder is gone" "$([ -d "$HOME/ws/deep" ] && echo yes || echo no)" no
check "one level up and no further" "$([ -d "$HOME/ws" ] && echo yes || echo no)" yes

echo "scenario: the editor opens, and what it saves is what happens"
full_world s4
run "$R" "$YES"
check "exit 0" "$RC" 0
check "the editor ran once" "$(edits)" 1
check "it asked before removing anything" "$(grep -c 'Will remove 7. Go ahead?' <<<"$OUT")" 1
check "idle went" "$(has idle)" no
check "work stayed" "$(has work)" yes

full_world s4b
run "$R" "n"$'\n'
check "answering no cancels" "$RC" 1
check "...says so" "$(grep -c 'cancelled; nothing was changed' <<<"$OUT")" 1
check "...and removes nothing" "$(has idle)" yes

run "$R" ""
check "no answer at all cancels too" "$RC" 1
check "...and removes nothing" "$(has idle)" yes

EDIT_RC=1 run "$R" "$YES"
check "quitting the editor with an error cancels" "$RC" 1
check "...and removes nothing" "$(has idle)" yes

echo "scenario: the file documents every word it reads"
full_world s5
run "$R" "n"$'\n'
for w in "${WORDS[@]}"; do
    check "the header explains $w" "$(grep -Ec "^## +$w +[a-z]" "$EDIT_DIR/seen.1")" 1
done
check "every line starting \"# \" is a worktree" "$(grep '^# ' "$EDIT_DIR/seen.1" | grep -vcE '^# (clean|unlock) ')" 0
run "$R" "" -h
check "-h exits 0" "$RC" 0
for w in "${WORDS[@]}"; do
    check "-h explains $w" "$(grep -Ec "^  $w +[a-z]" <<<"$OUT")" 1
done

echo "scenario: turning every line on does not throw work away"
# :%s/^# // is the careless way to say "all of them", and has to be safe: the
# notes start with ## so they are not caught, protected rows start with ## so
# they are not caught, and a `clean` on a worktree with changes is refused.
full_world s6
EDIT_CMD='sed -i "s/^# //" "$1"' run "$R" "$YES"
check "exit 1: some were refused" "$RC" 1
check "the notes and the protected row did not become lines" "$(grep -c 'unknown word\|protected (' <<<"$OUT")" 0
check "13 asked for, with the lock to be undone" "$(grep -c 'Will remove 13, 1 unlocked first. Go ahead?' <<<"$OUT")" 1
check "ten removed, three refused" "$(grep -c '^10 removed, 0 locked, 3 not done' <<<"$OUT")" 1
for name in work modified detached; do
    check "$name was refused" "$(grep -c "^refused   ~/ws/$name:" <<<"$OUT")" 1
    check "$name is still there" "$(has $name)" yes
done
check "the refusal says what to write" "$(grep -c 'use force to discard it' <<<"$OUT")" 3
check "the detached one says why" "$(grep -c 'has work (detached, commits on no branch)' <<<"$OUT")" 1
check "recent ones go on a plain clean" "$(has recent)" no
check "the locked one was unlocked and went" "$(has locked)" no
check "the main worktree is untouched" "$([ -d "$R/.git" ] && echo yes)" yes

echo "scenario: force discards, and only where it is written"
full_world s7
EDIT_CMD='sed -i -E "s|^# clean( +~/ws/work )|force\1|; s|^# clean( +~/ws/modified )|force\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "the prompt says changes are discarded" "$(grep -c '2 of them discarding changes' <<<"$OUT")" 1
check "work went" "$(has work)" no
check "modified went" "$(has modified)" no
check "an unchanged line next to them did not" "$(has detached)" yes

echo "scenario: a locked worktree needs unlocking, in the word"
full_world s7b
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/locked )|clean\1|" "$1"' run "$R" "$YES"
check "clean on a locked one is refused" "$(grep -c '^refused   ~/ws/locked: locked (waiting on QA); use unlock or unlock-force' <<<"$OUT")" 1
check "exit 1" "$RC" 1
check "it is still there" "$(has locked)" yes
check "and still locked" "$(lockedline locked | cut -d' ' -f2-)" "waiting on QA"

full_world s7c
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/locked )|unlock\1|" "$1"' run "$R" "$YES"
check "unlock removes it" "$(has locked)" no
check "exit 0" "$RC" 0

world s7d
mk lk $((50 * DAY)); git -C "$R" worktree lock --reason "waiting on QA" "$HOME/ws/lk"; echo x > "$HOME/ws/lk/new.txt"
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|unlock\1|" "$1"' run "$R" "$YES"
check "unlock alone does not discard changes" "$(grep -c 'has work (1 untracked); use unlock-force to discard it' <<<"$OUT")" 1
check "so it is not unlocked either" "$(lockedline lk | cut -d' ' -f2-)" "waiting on QA"
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|unlock-force\1|" "$1"' run "$R" "$YES"
check "unlock-force does" "$(has lk)" no

echo "scenario: lock keeps a worktree"
world s7e
mk keep $((30 * DAY))
EDIT_CMD='sed -i -E "s|^clean( +~/ws/keep )|lock\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "it is still there" "$(has keep)" yes
check "and locked" "$([ -n "$(lockedline keep)" ] && echo yes)" yes
run "$R" "" -n
check "next time it is in group 2" "$(group ws/keep)" 2

echo "scenario: a bad list reopens the editor with the faults at the top"
world s8
mk idle $((30 * DAY)); mk other $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^clean( +~/ws/idle )|frob\1|" "$1"; else sed -i -E "s|^frob|clean|" "$1"; fi' run "$R" "$YES"
bad="$(grep -n '^clean .* ~/ws/idle ' "$EDIT_DIR/seen.1" | cut -d: -f1)"
check "the editor was opened twice" "$(edits)" 2
check "the second time it names the word" "$(grep -c '^## error: line [0-9]*: unknown word "frob"' "$EDIT_DIR/seen.2")" 1
check "with the number of the line in that file" "$(grep -c "^## error: line $((bad + 2)): " "$EDIT_DIR/seen.2")" 1
check "which is the line" "$(sed -n "$((bad + 2))p" "$EDIT_DIR/seen.2" | cut -c1-4)" frob
check "fixed, it carries on" "$(has idle)" no
check "exit 0" "$RC" 0

world s8b
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^##( +~/repo )|clean\1|" "$1"; else sed -i -E "/^clean +~\/repo /d" "$1"; fi' run "$R" "$YES"
check "turning a protected one on is an error" "$(grep -c 'is protected (main worktree) and is never cleaned' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no
check "the main worktree is untouched" "$([ -d "$R/.git" ] && echo yes)" yes

world s8c
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then echo "clean ~/ws/nope" >> "$1"; else sed -i "/ws\/nope/d" "$1"; fi' run "$R" "$YES"
check "a path that is not listed is an error" "$(grep -c 'no listed worktree starts at' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no

world s8d
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "/^clean +~\/ws\/idle /p" "$1"; else awk "!s[\$0]++" "$1" > "$1.n" && mv "$1.n" "$1"; fi' run "$R" "$YES"
check "the same worktree twice is an error" "$(grep -c 'is already on line' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no

echo "scenario: a worktree that changed while the editor was open is not removed"
world s9
mk idle $((30 * DAY)); mk other $((30 * DAY))
EDIT_CMD='echo x > "$HOME/ws/idle/new.txt"' run "$R" "$YES"
check "exit 1" "$RC" 1
check "it says what changed" "$(grep -c '^refused   ~/ws/idle: changed while the editor was open (was idle, now has work)' <<<"$OUT")" 1
check "the new file survived" "$(cat "$HOME/ws/idle/new.txt" 2>/dev/null)" x
check "the other one still went" "$(has other)" no

world s9b
mk idle $((30 * DAY))
EDIT_CMD='GIT_COMMITTER_DATE="@$CLEANUP_NOW +0000" git -C "$HOME/ws/idle" commit -q --allow-empty -m x' run "$R" "$YES"
check "a commit made meanwhile makes it recent, and it stays" "$(grep -c 'was idle, now recent' <<<"$OUT")" 1
check "it is still there" "$(has idle)" yes

world s9c
mk idle $((30 * DAY))
EDIT_CMD='sed -i -E "s|^clean( +~/ws/idle )|force\1|" "$1"; echo x > "$HOME/ws/idle/new.txt"' run "$R" "$YES"
check "force written for a clean worktree does not cover new changes" "$(grep -c 'was idle, now has work' <<<"$OUT")" 1
check "the new file survived" "$(cat "$HOME/ws/idle/new.txt" 2>/dev/null)" x

echo "scenario: a removal that fails puts the lock back"
# A damaged .git file is a failure git makes even under --force, and one that
# leaves the worktree registered. (A read-only parent folder is not: git drops
# the registration and empties the checkout before it fails, so there is
# nothing left to lock.)
world s10
mk lk $((30 * DAY)); git -C "$R" worktree lock --reason "waiting on QA" "$HOME/ws/lk"
echo "gitdir: /nonexistent/elsewhere" > "$HOME/ws/lk/.git"
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|unlock-force\1|" "$1"' run "$R" "$YES"
check "exit 1" "$RC" 1
check "the failure is reported" "$(grep -c '^failed    ~/ws/lk:' <<<"$OUT")" 1
check "it is locked again, with its reason" "$(lockedline lk | cut -d' ' -f2-)" "waiting on QA"

echo "scenario: discard throws the changes away, then cleans"
# Refusals have to come before the discarding, so that a refused line loses
# nothing; the cases below check the file is still there.
world s14
printf 'ign\n' > "$R/.gitignore"; git -C "$R" add .gitignore
GIT_COMMITTER_DATE="@$((NOW - 400 * DAY)) +0000" git -C "$R" commit -q -m ignore
mk stale $((40 * DAY)); mk fresh $((2 * DAY)); mk tidy $((40 * DAY))
for w in stale fresh; do
    echo two >> "$HOME/ws/$w/f.txt"
    echo new > "$HOME/ws/$w/staged.txt"; git -C "$HOME/ws/$w" add staged.txt
    echo u > "$HOME/ws/$w/untracked.txt"
    mkdir -p "$HOME/ws/$w/d/e"; echo x > "$HOME/ws/$w/d/e/y"
    echo keep > "$HOME/ws/$w/ign"
done
EDIT_CMD='sed -i -E "s|^# clean( +~/ws/(stale\|fresh) )|discard\1|; s|^clean( +~/ws/tidy )|discard\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "the prompt says changes are discarded" "$(grep -c 'Will remove 3, 3 of them discarding changes. Go ahead?' <<<"$OUT")" 1
check "a worktree with changes says so" "$(grep -c '^removed   ~/ws/stale (changes discarded)' <<<"$OUT")" 1
check "a recent one goes too" "$(grep -c '^removed   ~/ws/fresh (changes discarded)' <<<"$OUT")" 1
check "one with nothing to discard is just removed" "$(grep -c '^removed   ~/ws/tidy$' <<<"$OUT")" 1
check "the summary" "$(grep -c '^3 removed, 0 locked, 0 not done' <<<"$OUT")" 1
for w in stale fresh tidy; do
    check "$w is gone" "$(has $w)" no
done

echo "scenario: discard does what it says before removing"
# A dirty worktree that git refuses to remove without force is the proof that
# the discard ran first: the removal is a plain one.
world s14b
mk w $((40 * DAY)); echo two >> "$HOME/ws/w/f.txt"; echo u > "$HOME/ws/w/untracked.txt"
EDIT_CMD='sed -i -E "s|^# clean( +~/ws/w )|discard\1|" "$1"; git -C "$HOME/ws/w" status --porcelain > "$EDIT_DIR/status"' run "$R" "$YES"
check "it had changes when the list was shown" "$(wc -l < "$EDIT_DIR/status")" 2
check "and was removed" "$(has w)" no

echo "scenario: discard is refused, and discards nothing, where it should be"
world s14c
mk lk $((40 * DAY)); git -C "$R" worktree lock --reason "waiting on QA" "$HOME/ws/lk"; echo u > "$HOME/ws/lk/untracked.txt"
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|discard\1|" "$1"' run "$R" "$YES"
check "a locked worktree is refused" "$(grep -c '^refused   ~/ws/lk: locked (waiting on QA); use unlock or unlock-force' <<<"$OUT")" 1
check "exit 1" "$RC" 1
check "its file is still there" "$([ -e "$HOME/ws/lk/untracked.txt" ] && echo yes || echo no)" yes
check "and it is still locked" "$(lockedline lk | cut -d' ' -f2-)" "waiting on QA"

world s14f
mkd det $((40 * DAY))
GIT_COMMITTER_DATE="@$((NOW - 40 * DAY)) +0000" git -C "$HOME/ws/det" commit -q --allow-empty -m wip
echo u > "$HOME/ws/det/untracked.txt"
EDIT_CMD='sed -i -E "s|^# clean( +~/ws/det )|discard\1|" "$1"' run "$R" "$YES"
check "commits on no branch: refused" "$(grep -c '^refused   ~/ws/det: has commits on no branch; use force' <<<"$OUT")" 1
check "exit 1" "$RC" 1
check "its file is still there" "$([ -e "$HOME/ws/det/untracked.txt" ] && echo yes || echo no)" yes
check "and so is the commit" "$(git -C "$HOME/ws/det" log -1 --format=%s)" wip
EDIT_CMD='sed -i -E "s|^# clean( +~/ws/det )|force\1|" "$1"' run "$R" "$YES"
check "force is what removes it" "$(has det)" no

world s14g
mk lk $((40 * DAY)); git -C "$R" worktree lock --reason "waiting on QA" "$HOME/ws/lk"; echo u > "$HOME/ws/lk/untracked.txt"
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^# unlock( +~/ws/lk )|discard-force\1|" "$1"; else sed -i "/^discard-force/d" "$1"; fi' run "$R" "$YES"
check "discard-force is not a word" "$(grep -c 'unknown word "discard-force"' "$EDIT_DIR/seen.2")" 1

world s14d
mk idle $((30 * DAY))
EDIT_CMD='sed -i -E "s|^clean( +~/ws/idle )|discard\1|" "$1"; echo x > "$HOME/ws/idle/new.txt"' run "$R" "$YES"
check "changes that came after the list was shown are not discarded" "$(grep -c 'was idle, now has work' <<<"$OUT")" 1
check "the new file survived" "$(cat "$HOME/ws/idle/new.txt" 2>/dev/null)" x

world s14e
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^##( +~/repo )|discard\1|" "$1"; else sed -i -E "/^discard +~\/repo /d" "$1"; fi' run "$R" "$YES"
check "the main worktree cannot be discarded in either" "$(grep -c 'is protected (main worktree)' "$EDIT_DIR/seen.2")" 1

echo "scenario: lock takes a reason"
world s15
mk keep $((30 * DAY)); mk plain $((30 * DAY)); mk other $((30 * DAY))
EDIT_CMD='sed -i -E "s|^clean( +~/ws/keep )|lock \"waiting on QA, ticket #42\" \1|; s|^clean( +~/ws/plain )|lock\1|" "$1"' run "$R" "$YES"
check "exit 0" "$RC" 0
check "the reason is the lock's" "$(lockedline keep | cut -d' ' -f2-)" "waiting on QA, ticket #42"
check "it is said back" "$(grep -c '^locked    ~/ws/keep: waiting on QA, ticket #42' <<<"$OUT")" 1
check "no reason: the command says it made the lock" "$(lockedline plain | cut -d' ' -f2-)" "kept by git cleanup worktrees"
check "both are kept" "$(has keep)$(has plain)" yesyes
check "the one left on was removed" "$(has other)" no
check "the prompt counts the locks" "$(grep -c 'Will remove 1; lock 2. Go ahead?' <<<"$OUT")" 1
check "the row shows the reason next time" "$(git -C "$R" worktree list --porcelain | grep -c '^locked waiting on QA')" 1

world s15b
mk lk $((30 * DAY)); git -C "$R" worktree lock --reason "old reason" "$HOME/ws/lk"
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|lock \"new reason\" \1|" "$1"' run "$R" "$YES"
check "a new reason replaces the old one" "$(lockedline lk | cut -d' ' -f2-)" "new reason"
check "and the worktree stays" "$(has lk)" yes
EDIT_CMD='sed -i -E "s|^# unlock( +~/ws/lk )|lock\1|" "$1"' run "$R" "$YES"
check "lock with no reason leaves an existing one" "$(lockedline lk | cut -d' ' -f2-)" "new reason"
check "...and says it already was" "$(grep -c '^locked    ~/ws/lk (already)' <<<"$OUT")" 1

echo "scenario: a reason in the wrong place is an error"
world s15c
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^clean( +~/ws/idle )|force \"why\" \1|" "$1"; else sed -i -E "s|^force \"why\" |clean |" "$1"; fi' run "$R" "$YES"
check "only lock takes one" "$(grep -c 'only lock takes a reason in quotes, not force' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no

world s15d
mk idle $((30 * DAY))
EDIT_CMD='if [ "$n" = 1 ]; then sed -i -E "s|^clean( +~/ws/idle )|lock \"oops \1|" "$1"; else sed -i -E "s|^lock \"oops |clean |" "$1"; fi' run "$R" "$YES"
check "an unfinished reason reopens the editor" "$(edits)" 2
check "...with an error at the top" "$(grep -c '^## error: line' "$EDIT_DIR/seen.2")" 1
check "once fixed it goes ahead" "$(has idle)" no

echo "scenario: the manual"
check "the page has an entry for every word the script reads" "$(for w in "${WORDS[@]}"; do grep -B1 -xF ".B ${w//-/\\-}" "$MANPAGE" | grep -cx '\.TP'; done | tr '\n' ' ')" "1 1 1 1 1 1 "
if command -v man >/dev/null; then
    check "the worktrees page renders without warnings" "$(man --warnings -l "$MANPAGE" 2>&1 >/dev/null | wc -l)" 0
    check "the overview renders without warnings" "$(man --warnings -l "$OVERVIEW" 2>&1 >/dev/null | wc -l)" 0
    check "man finds the worktrees page from PATH alone" "$(PATH="$ROOT/bin:$PATH" MANPATH= man -w git-cleanup-worktrees 2>/dev/null)" "$MANPAGE"
    check "man finds the overview from PATH alone" "$(PATH="$ROOT/bin:$PATH" MANPATH= man -w git-cleanup 2>/dev/null)" "$OVERVIEW"
    # Git takes --help only when it follows the command itself; after a
    # subcommand it is the script's, which has to open the page.
    mp() { PATH="$ROOT/bin:$PATH" MANPATH= MANPAGER=cat PAGER=cat MANWIDTH=80 "$@" 2>&1 </dev/null; }
    out="$(mp git cleanup worktrees --help)"; rc=$?
    check "git cleanup worktrees --help works through git" "$rc" 0
    check "...and is the worktrees manual" "$(grep -c '^THE WORDS' <<<"$out")" 1
    out="$(mp git cleanup --help)"
    check "git cleanup --help is the overview" "$(grep -c '^THE FILE' <<<"$out")" 1
else
    echo "  SKIPPED: man is not installed, so the pages are not rendered or looked up"
fi
out="$(PATH="$ROOT/bin:$PATH" git cleanup worktrees -h 2>&1 </dev/null)"
check "-h is the short help, and names the manual" "$(grep -c 'man git-cleanup-worktrees' <<<"$out")" 1

echo "scenario: the dispatcher"
world s16
mk idle $((30 * DAY))
for spelling in worktrees worktree wt; do
    rm -rf "$EDIT_DIR"; mkdir -p "$EDIT_DIR"
    OUT="$(cd "$R" && "$SCRIPT" "$spelling" -n 2>&1)"; RC=$?
    check "$spelling lists the worktrees" "$RC$(grep -c '~/ws/idle' <<<"$OUT")" 01
done
OUT="$(cd "$R" && "$SCRIPT" 2>&1)"; RC=$?
check "no argument is a usage error" "$RC" 2
check "...that lists what there is to clean" "$(grep -c 'worktrees' <<<"$OUT")" 1
OUT="$(cd "$R" && "$SCRIPT" branches 2>&1)"; RC=$?
check "something it does not know is a usage error" "$RC" 2
check "...which names it" "$(grep -c 'unknown thing to clean: branches' <<<"$OUT")" 1
OUT="$(cd "$R" && "$SCRIPT" -h 2>&1)"; RC=$?
check "-h is the usage, and not an error" "$RC" 0
OUT="$(cd "$R" && "$SCRIPT" wt --days nope 2>&1)"; RC=$?
check "arguments reach the script: a bad one is its error" "$RC" 2
OUT="$(cd "$R" && "$SCRIPT" wt --days 100 -n 2>&1)"
check "...and a good one is used" "$(grep -c '^## 4 recent: clean, but active in the last 100 days' <<<"$OUT")" 1


check "the old name is gone" "$([ -e "$ROOT/bin/git-worktree-clean" ] && echo there || echo gone)" gone

echo "scenario: --days moves the line"
full_world s11
run "$R" "" -n --days 100
check "90 days is recent under a 100-day rule" "$(group ws/idle2)" 4
run "$R" "" -n --days=7
check "--days=7 works too" "$(group ws/recent)" 4
check "...and 14 days is idle under it" "$(group ws/edge-new)" 5
run "$R" "" -n --days 0
check "nothing clean is recent at 0 days" "$(group ws/recent)" 5
run "$R" "" -n --days abc
check "a non-number is a usage error" "$RC" 2

echo "scenario: the worktree you are in is protected"
full_world s12
run "$HOME/ws/idle" "" -n
check "it is group 1" "$(group ws/idle)" 1
check "labelled as current" "$(grep -c '(current)' <<<"$OUT")" 1
run "$HOME/ws/idle" "" -y
check "-y leaves it" "$(has idle)" yes
check "-y still cleans the others" "$(has idle2)" no

echo "scenario: nothing to do"
world s13
run "$R" ""
check "only the main worktree: exit 0" "$RC" 0
check "...says so" "$(grep -c 'nothing to clean' <<<"$OUT")" 1
check "...without opening the editor" "$(edits)" 0

world s13b
mk recent $((2 * DAY))
run "$R" "" -y
check "-y with nothing idle: exit 0" "$RC" 0
check "...says so" "$(grep -c 'no idle worktrees' <<<"$OUT")" 1
check "...and leaves the recent one" "$(has recent)" yes

mkdir -p "$TMP/nowhere"
GIT_CEILING_DIRECTORIES="$TMP" run "$TMP/nowhere" "" -n
check "outside a repository is an error" "$RC" 1
check "...with a message" "$(grep -c 'not inside a git repository' <<<"$OUT")" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
