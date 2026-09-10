# Shared by bin/dotfiles-check-updates, bin/dotfiles-update and setup.sh.
# Sourced, not run.
#
# In lib/ rather than bin/, which is where it started. bin/ is symlinked onto
# PATH, and although being non-executable already made this impossible to run,
# it still landed in zsh's command hash and so turned up when completing
# `dotfiles-<TAB>` -- noise in the list of things you actually can run. Nothing
# needs it on PATH: both callers source it by absolute path off the repo root,
# which they resolve anyway to find the repo they are reporting on.
#
# lib/ is deliberately not linked anywhere by install.sh. It is read out of the
# repo, so there is nothing to install.

# Print the https equivalent of a git remote url.
#
# Both callers talk to GitHub over https rather than the configured ssh url,
# deliberately. There is no ssh-agent in the graphical session and the key has a
# passphrase, so ssh has nothing to authenticate with: it fails outright where
# there is no terminal, and asks for the passphrase on every run where there is.
# This repo is public, so https needs no credentials at all.
#
# A private repo would have to go back to ssh, and would then be limited to
# places a passphrase can be typed.
dotfiles_https_url() {
    local url="$1"

    case "$url" in
        git@*:*)
            # host:path -> host/path, done before the scheme is prefixed so the
            # substitution cannot land on the colon in "https:".
            local rest="${url#git@}"
            printf '%s\n' "https://${rest/://}"
            ;;
        ssh://git@*)
            printf '%s\n' "https://${url#ssh://git@}"
            ;;
        *)
            printf '%s\n' "$url"
            ;;
    esac
}

# Run install.sh for each mode given (all, packages, links), then apply the
# result to the running session via dotfiles-reload. The two entry points to
# this repo -- setup.sh on a fresh machine, bin/dotfiles-update for updates --
# both end with exactly this sequence, so it lives here once rather than twice,
# where one copy could gain a step the other forgot.
#
# install.sh is safe to run repeatedly and skips what is already done, so an
# update can pass "all" and get everything for the price of the checks.
#
# The reload is guarded on dotfiles-reload existing on PATH. On a fresh machine
# bin/ has not been linked into ~/.local/bin yet and nothing is running to
# reload, so skipping it is right; that same guard means a lib pulled by a newer
# clone than the scripts on the machine does not fail on a missing command.
dotfiles_apply() {
    # The repo root from this file's own location: lib/ sits one level below the
    # repo, and every caller sources this by absolute path, so BASH_SOURCE[0] is
    # the real path rather than a symlink alias.
    local repo
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    local any=0 mode
    for mode in "$@"; do
        case "$mode" in
            all|packages|links) ;;
            *) echo "dotfiles_apply: bad mode: $mode" >&2; return 2 ;;
        esac
        "$repo/install.sh" "$mode" || return 1
        any=1
    done

    if [ "$any" -eq 1 ] && command -v dotfiles-reload >/dev/null 2>&1; then
        dotfiles-reload
    fi
    return 0
}
