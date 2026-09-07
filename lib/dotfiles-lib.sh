# Shared by bin/dotfiles-check and bin/dotfiles-update. Sourced, not run.
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
