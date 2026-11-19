#!/usr/bin/env bash
# The part of `git cleanup <thing>` that does not depend on the thing: reading
# the flags, writing the list, opening it in $GIT_EDITOR, parsing what comes
# back, asking once more, and applying it line by line. Sourced by
# lib/cleanup-worktrees and lib/cleanup-branches. It was extracted from the
# worktrees script alone, along the seams a second one would obviously want,
# and the branches script was then written against it. That moved one seam:
# how long idle means. It was fourteen days written into this file, and
# branches wanted one, so each subcommand now says (DAYS_DEFAULT below).
#
# The list is opened in an editor, the way `git rebase -i` does, and what is
# saved is what happens. A picker (fzf, numbers typed at a prompt) was weighed
# first and lost on scale: someone who makes several worktrees a day has dozens
# to review, numbers do not survive that, and an editor brings search,
# substitution and macros for free. It also leaves nothing to draw, so this is
# a writer, a parser and an applier.
#
# Notes in the file start with "##", and a turned-off line with "# ". That is
# deliberate: :%s/^# // turns everything on, and must not turn the notes into
# lines to be read. A note written with one "#" would lose it to that
# substitution and be read as a line with an unknown word; with two it keeps
# one and is still a comment. The parser skips anything starting with "#".
#
# Why the first word of a line is not decoration. The default for every line
# is the mildest word, which git itself refuses on an item with work in it, so
# turning on a whole section can never throw work away; discarding it takes a
# stronger word typed on that line. That replaces the typing of a name that
# was planned for the same job, and is harder to do by accident.
#
# The list is only a request. Each line is looked at again just before it is
# acted on, because an item can change while the editor is open: one that has
# moved to a riskier tier (idle to recent, anything to has-work) is refused
# rather than changed on stale information. A refusal or a failure is reported
# and the rest carry on, with a non-zero exit at the end.
#
# After the editor closes the plan is summarised and confirmed once more.
# Saving an unedited list applies its defaults, and removal cannot be undone
# the way a rebase can.
#
# --help is the manual, not this script's text. Git turns `git <cmd> --help`
# into `man git-<cmd>` before the command is ever run, for external commands as
# much as its own. `git cleanup` alone gets that, but the arguments after a
# subcommand are passed through untouched, so `git cleanup worktrees --help`
# reaches the script, which hands them to `man`, and -h prints the short form.
# The pages are found without any setup: man derives its search path from PATH,
# and a `man` directory beside a PATH entry's `bin` is on it (this repo's bin/
# names ~/dotfiles/man). Installing them under ~/.local/share/man was passed
# over for needing an install.sh line and a MANPATH that nothing else wants.
#
# CLEANUP_NOW (seconds since the epoch) stands in for the clock. Only the tests
# set it, to put the idle boundary where they can hit it.
#
# What the script that sources this must provide:
#
#   variables, set before cleanup_main
#     CLEANUP_CMD      what the user types, "git cleanup worktrees": the prefix
#                      of every message
#     CLEANUP_MAN      the manual page's name, "git-cleanup-worktrees"
#     ITEM, ITEMS      the thing listed, singular and plural, for prose
#     DAYS_DEFAULT     days without activity that make an item idle, unless
#                      --days says otherwise: 14 for worktrees, 7 for branches
#                      (a merged branch costs nothing to remake; a worktree is
#                      a checkout somebody may come back to). Left unset it is
#                      14.
#     VALID_WORDS      array of the words a line may start with
#     REASON_WORD      the one word that may carry a quoted reason ("lock")
#     RECHECK_EXEMPT   array of words that are not refused when the item has
#                      moved to a riskier tier (a lock only adds a lock)
#     HEADER_NOTE      the last line of the header, for what is kept
#
#   functions
#     words            the words and what they do, one block, for the editor
#                      header and -h
#     setup            after the flags are read: fill TITLE, VERB and
#                      STATE_NAME, which can depend on $DAYS
#     header_title     the first line of the file
#     load_items       fill N and I_key (a unique id per item) for every item,
#                      and whatever the script's own arrays hold. Called again
#                      before each action, so it must reflect the world now
#     load_one KEY     optional. Like load_items, but for the one item KEY: N
#                      becomes 1 (or 0 if it is gone) with the item at index
#                      0. cleanup_apply calls it before each action instead of
#                      load_items, which is what keeps applying linear: a full
#                      reload per action made deleting N branches cost N
#                      reloads of all of them, 30 seconds for 560 of 1040
#     prepare          optional. Called once, after the first load_items and
#                      before the first inspect, for work that is cheaper done
#                      for every item at once than inside each inspect (a
#                      branch lookup that costs a network round trip, say)
#     inspect I        fill the I_* arrays for item I (see below)
#     act_on I K       carry out word A_verb[K] on item I, reporting with
#                      refuse / failed / echo, and keeping its own counts
#     confirm_text     print what the plan does, for "Will ...", from A_verb
#     summary          print the closing line
#
#   what inspect I fills, at index I
#     I_key  I_disp  I_col2  I_prot  I_tier  I_state  I_act  I_miss  I_badge
#     I_subject
#   I_tier is 1 (protected, never acted on) to 5 (idle). I_state is the tier
#   the item would be in were it not protected or locked, 3 to 5, and is what
#   the recheck compares. I_disp is the name shown and typed, I_col2 a second
#   column, I_act the time of the last activity, I_miss 1 when the thing is
#   already gone, I_badge why it is where it is, I_subject a line of context.
#   The tiers are the same five for every kind of item, because the ordering
#   and the headings are written against them.
#
# After parse(), A_verb / A_key / A_reason hold what the user asked for.

DRY=0
YES=0
BAD=0
declare -A LISTED_STATE=()

# One line on stderr that is overwritten as it changes, and only when stderr is
# a terminal, so a pipe or a file is never given the carriage returns. What is
# slow here is a wait with nothing on the screen, and not how long it is: a
# counter that moves is the difference between a script that works and one that
# looks hung.
progress() {
    if [ -t 2 ]; then printf '\r\033[K%s' "$*" >&2; fi
    return 0
}

progress_done() {
    if [ -t 2 ]; then printf '\r\033[K' >&2; fi
    return 0
}

die() {
    progress_done
    echo "$CLEANUP_CMD: $*" >&2
    exit "${DIE_STATUS:-1}"
}

cleanup_usage() {
    cat <<EOF
usage: $CLEANUP_CMD [-n | -y] [--days N]

  -n, --dry-run  list the $ITEMS and what would happen to each by default
  -y, --yes      clean the idle ones now, without the editor or a question
  --days N       how long without activity counts as idle (default $DAYS_DEFAULT)
  -h, --help     this text

Without -n or -y the list opens in your git editor. The first word of a line
says what to do with that $ITEM, and "# " in front of a line turns it off:

EOF
    words | sed 's/^/  /'
    cat <<EOF

The groups, the safety checks and examples are in the manual:
    man $CLEANUP_MAN
EOF
}

cleanup_parse_args() {
    : "${DAYS_DEFAULT:=14}"
    DAYS="$DAYS_DEFAULT"
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run) DRY=1 ;;
            -y|--yes) YES=1 ;;
            --days) shift; DAYS="${1:-}" ;;
            --days=*) DAYS="${1#*=}" ;;
            -h) cleanup_usage; exit 0 ;;
            --help)
                if command -v man >/dev/null && man "$CLEANUP_MAN" 2>/dev/null; then exit 0; fi
                cleanup_usage; exit 0
                ;;
            *) cleanup_usage >&2; DIE_STATUS=2 die "unknown argument: $1" ;;
        esac
        shift
    done

    [[ $DAYS =~ ^[0-9]+$ ]] || DIE_STATUS=2 die "--days wants a whole number, not \"$DAYS\""
    DAYS_S=$((10#$DAYS * 86400))
    NOW="${CLEANUP_NOW:-$(date +%s)}"

    git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
}

fmt_age() {
    local s=$((NOW - $1))
    (( s < 0 )) && s=0
    if (( s < 3600 )); then echo "$((s / 60))m"
    elif (( s < 86400 )); then echo "$((s / 3600))h"
    else echo "$((s / 86400))d"
    fi
}

# Groups in tier order. Within one, idle goes oldest first, so the surest
# candidates are at the top, and has-work and recent go newest first, so what
# you were last doing is.
render_body() {
    local i t k pw=0 bw=0 prev=0 age sub
    for ((i = 0; i < N; i++)); do
        (( ${#I_disp[i]} > pw )) && pw=${#I_disp[i]}
        (( ${#I_col2[i]} > bw )) && bw=${#I_col2[i]}
    done
    {
        while IFS=$'\t' read -r t k i; do
            if [ "$t" -ne "$prev" ]; then
                (( prev )) && echo
                echo "## ${TITLE[t]}"
                prev=$t
            fi
            age="-"
            (( I_miss[i] )) || age="$(fmt_age "${I_act[i]}")"
            sub=""
            if [ -n "${I_subject[i]}" ]; then
                sub="${I_subject[i]}"
                (( ${#sub} > 50 )) && sub="${sub:0:47}..."
                sub="\"$sub\""
            fi
            printf '%-10s  %-*s  %-*s  %4s  %s  %s\n' "${VERB[t]}" "$pw" "${I_disp[i]}" \
                "$bw" "${I_col2[i]}" "$age" "${I_badge[i]}" "$sub"
        done < <(
            for ((i = 0; i < N; i++)); do
                t=${I_tier[i]}; k=0
                case $t in
                    3|4) k=$((-I_act[i])) ;;
                    5) k=${I_act[i]} ;;
                esac
                printf '%s\t%s\t%s\n' "$t" "$k" "$i"
            done | sort -t$'\t' -k1,1n -k2,2n -k3,3n
        )
    } | sed 's/ *$//'
}

header() {
    {
        header_title
        echo
        echo "Each line below is a $ITEM, and its first word says what to do with it:"
        echo
        words | sed 's/^/  /'
        echo
        echo "A line starting with \"# \" is off. Take the \"# \" off to turn it on, put it"
        echo "back (or delete the line) to skip it. Lines starting with \"##\" are notes and"
        echo "are never read, so uncommenting everything with :%s/^# // turns every"
        echo "$ITEM on and leaves these alone. Protected $ITEMS have no word and"
        echo "cannot be turned on."
        echo
        echo "Nothing happens until you save and quit, and then you are asked once more."
        echo "Quit with an error (:cq) to cancel. $HEADER_NOTE"
    } | sed 's/^/## /; s/ *$//'
}

# Which item a line names: the start of what follows the word, up to
# whitespace or the end of the line. The longest display name that fits wins,
# so that "~/a/b" does not claim a line for "~/a/b c". Matching against the
# known names, rather than splitting on whitespace, is what lets one hold a
# space.
match_row() {
    local i d best=-1 len=0
    for ((i = 0; i < N; i++)); do
        d="${I_disp[i]}"
        if [[ $1 == "$d" || $1 == "$d"[[:space:]]* ]] && (( ${#d} > len )); then
            best=$i; len=${#d}
        fi
    done
    MATCH=$best
}

word_list() {
    local n=${#VALID_WORDS[@]} i out=""
    for ((i = 0; i < n; i++)); do
        if (( i == 0 )); then out="${VALID_WORDS[i]}"
        elif (( i == n - 1 )); then out+=" or ${VALID_WORDS[i]}"
        else out+=", ${VALID_WORDS[i]}"
        fi
    done
    echo "$out"
}

is_word() {
    local w
    for w in "${VALID_WORDS[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

recheck_exempt() {
    local w
    for w in "${RECHECK_EXEMPT[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

parse() {
    local n=0 line verb rest p why
    local -A seen=()
    local reason_re='^"([^"]*)"[[:space:]]*(.*)$'
    A_verb=(); A_key=(); A_reason=(); E_line=(); E_msg=()
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        case $line in
            ''|'#'*) continue ;;
        esac
        verb="${line%%[[:space:]]*}"
        rest="${line#"$verb"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        if ! is_word "$verb"; then
            E_line+=("$n"); E_msg+=("unknown word \"$verb\": use $(word_list)")
            continue
        fi
        why=""
        if [[ $rest == \"* ]]; then
            if [ "$verb" != "$REASON_WORD" ]; then
                E_line+=("$n"); E_msg+=("only $REASON_WORD takes a reason in quotes, not $verb")
                continue
            fi
            if [[ $rest =~ $reason_re ]]; then
                why="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
            else
                E_line+=("$n"); E_msg+=("the reason has no closing quote")
                continue
            fi
        fi
        match_row "$rest"
        if [ "$MATCH" -lt 0 ]; then
            E_line+=("$n"); E_msg+=("no listed $ITEM starts at \"${rest:0:40}\"")
            continue
        fi
        p="${I_key[MATCH]}"
        if [ -n "${I_prot[MATCH]}" ]; then
            E_line+=("$n"); E_msg+=("${I_disp[MATCH]} is protected (${I_prot[MATCH]}) and is never cleaned")
            continue
        fi
        if [ -n "${seen["$p"]:-}" ]; then
            E_line+=("$n"); E_msg+=("${I_disp[MATCH]} is already on line ${seen["$p"]}")
            continue
        fi
        seen["$p"]=$n
        A_verb+=("$verb"); A_key+=("$p"); A_reason+=("$why")
    done < "$1"
    [ ${#E_msg[@]} -eq 0 ]
}

find_idx() {
    local i
    FOUND=-1
    for ((i = 0; i < N; i++)); do
        if [ "${I_key[i]}" = "$1" ]; then FOUND=$i; return; fi
    done
}

refuse() { echo "refused   $1: $2" >&2; BAD=$((BAD + 1)); }
failed() { echo "failed    $1: $2" >&2; BAD=$((BAD + 1)); }

cleanup_apply() {
    local k verb key i d was now
    BAD=0
    for ((k = 0; k < ${#A_verb[@]}; k++)); do
        verb="${A_verb[k]}"; key="${A_key[k]}"
        if declare -F load_one >/dev/null; then load_one "$key"; else load_items; fi
        find_idx "$key"
        if [ "$FOUND" -lt 0 ]; then echo "gone      $key"; continue; fi
        i=$FOUND
        inspect "$i"
        d="${I_disp[i]}"

        if [ -n "${I_prot[i]}" ]; then refuse "$d" "protected (${I_prot[i]})"; continue; fi

        if ! recheck_exempt "$verb"; then
            was="${LISTED_STATE["$key"]}"; now="${I_state[i]}"
            if (( now < was )); then
                refuse "$d" "changed while the editor was open (was ${STATE_NAME[was]}, now ${STATE_NAME[now]}); run again if it should still go"
                continue
            fi
        fi

        act_on "$i" "$k"
    done

    summary
    [ "$BAD" -eq 0 ]
}

confirm() {
    local ans
    printf 'Will %s. Go ahead? [y/N] ' "$(confirm_text)"
    read -r ans || ans=""
    [ -t 0 ] || echo
    [[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}

cleanup_main() {
    local i k candidates=0 editor shift_by file

    cleanup_parse_args "$@"
    setup
    load_items
    if declare -F prepare >/dev/null; then prepare; fi
    for ((i = 0; i < N; i++)); do
        progress "$CLEANUP_CMD: reading $ITEMS, $((i + 1)) of $N"
        inspect "$i"
        LISTED_STATE["${I_key[i]}"]="${I_state[i]}"
    done
    progress_done

    if [ "$DRY" -eq 1 ]; then
        render_body
        exit 0
    fi

    for ((i = 0; i < N; i++)); do
        [ -z "${I_prot[i]}" ] && candidates=$((candidates + 1))
    done
    if [ "$candidates" -eq 0 ]; then
        echo "$CLEANUP_CMD: nothing but protected $ITEMS here; nothing to clean"
        exit 0
    fi

    CLEANUP_TMP="$(mktemp -d)" || die "cannot make a temporary directory"
    trap 'rm -rf "$CLEANUP_TMP"' EXIT
    file="$CLEANUP_TMP/${CLEANUP_MAN}"
    { header; echo; render_body; } > "$file"

    if [ "$YES" -eq 1 ]; then
        parse "$file" || die "the generated list does not parse: ${E_msg[0]}"
    else
        editor="$(git var GIT_EDITOR)"
        while :; do
            sh -c "$editor \"\$@\"" "$editor" "$file" ||
                die "the editor exited with an error; nothing was changed"

            grep -v '^## error:' "$file" > "$file.stripped"
            mv -- "$file.stripped" "$file"

            parse "$file" && break

            # The numbers are those of the file as it will be when it reopens,
            # so they are moved down by the lines about to go above it.
            shift_by=$((${#E_msg[@]} + 1))
            {
                echo "## error: fix these and save again, or quit with an error (:cq) to cancel"
                for k in "${!E_msg[@]}"; do
                    printf '## error: line %d: %s\n' $((E_line[k] + shift_by)) "${E_msg[k]}"
                done
                cat -- "$file"
            } > "$file.errors"
            mv -- "$file.errors" "$file"
        done
    fi

    if [ ${#A_verb[@]} -eq 0 ]; then
        if [ "$YES" -eq 1 ]; then
            echo "$CLEANUP_CMD: no idle $ITEMS; nothing to clean"
        else
            echo "$CLEANUP_CMD: nothing turned on; nothing to do"
        fi
        exit 0
    fi

    if [ "$YES" -eq 0 ] && ! confirm; then
        echo
        echo "$CLEANUP_CMD: cancelled; nothing was changed"
        exit 1
    fi

    cleanup_apply
}
