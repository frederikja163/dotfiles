#!/usr/bin/env bash
# Bootstrap a fresh EndeavourOS / Arch machine: git, the GitHub CLI, the
# dotfiles, and a GitHub sign-in.
#
# Intended to run once on a bare install. If gh is already signed in it is used
# as-is rather than signing in again.
#
# One-liner to fetch and run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/frederikja163/dotfiles/main/setup.sh)
set -euo pipefail

# https, not the ssh url this used to carry: gh authenticates git over https
# through the credential helper in git/config, so no key pair and no account
# copy-paste are involved. See section 3.
REPO="https://github.com/frederikja163/dotfiles.git"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

info()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m    %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m    %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. git and gh ────────────────────────────────────────────────────────────

info "Checking for git and the GitHub CLI..."
missing=()
command -v git >/dev/null 2>&1 || missing+=(git)
command -v gh  >/dev/null 2>&1 || missing+=(github-cli)

if [ ${#missing[@]} -eq 0 ]; then
  ok "git and gh already installed"
else
  info "Installing: ${missing[*]}"
  sudo pacman -S --noconfirm --needed "${missing[@]}"
  ok "installed"
fi

# ── 2. Clone ─────────────────────────────────────────────────────────────────

# Before the sign-in, which the old ssh setup could not do. This clone needs no
# credentials -- a public repo over https -- and having the files on disk is
# what lets the git config be linked before gh runs.
info "Cloning dotfiles..."
if [ -d "$DOTFILES_DIR" ]; then
  ok "Directory $DOTFILES_DIR already exists — skipping clone"
else
  git clone "$REPO" "$DOTFILES_DIR"
  ok "Cloned to $DOTFILES_DIR"
fi

# ── 3. GitHub sign-in ────────────────────────────────────────────────────────

# gh replaces the ssh key pair this script used to generate and hand to GitHub
# by copy-paste. It stores a token for github.com and supplies it to git over
# https through the credential helper in git/config, so there is no public key
# to add to the account and nothing to paste, and git push works without an
# ssh-agent holding a passphrase.
#
# gh decides whether to configure that helper by asking git, and configures it
# with `git config --global` -- which writes ~/.gitconfig, the file git/config's
# header says must not exist, read last and so winning over the linked copy.
# Linking git/config now, rather than leaving it to install.sh below, means gh
# finds the helper already in place and leaves ~/.gitconfig alone. install.sh
# meets the same symlink afterwards and does nothing.
GIT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git"
if [ ! -e "$GIT_CONFIG_DIR" ] && [ ! -L "$GIT_CONFIG_DIR" ]; then
  mkdir -p "$(dirname "$GIT_CONFIG_DIR")"
  ln -s "$DOTFILES_DIR/git" "$GIT_CONFIG_DIR"
  ok "Linked git config"
fi

# --web is the browser/device flow: gh prints a one-time code and opens
# github.com to enter it. The protocol is pinned to https so the clone and that
# helper line up; left to the interactive prompt it would offer ssh.
info "Checking GitHub authentication..."
if gh auth status --hostname github.com >/dev/null 2>&1; then
  ok "Already signed in to GitHub"
else
  info "Signing in to GitHub..."
  gh auth login --hostname github.com --git-protocol https --web
  ok "Signed in"
fi

# ── 4. Install ───────────────────────────────────────────────────────────────

info "Running install.sh..."
. "$DOTFILES_DIR/lib/dotfiles-lib.sh" || die "could not source dotfiles-lib.sh"
dotfiles_apply all

echo ""
ok "Done. Reload your shell or start a new terminal."
