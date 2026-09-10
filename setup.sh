#!/usr/bin/env bash
# Bootstrap a fresh EndeavourOS / Arch machine: git, SSH key, dotfiles.
#
# Intended to run once on a bare install. If you already have an ed25519 key
# in ~/.ssh/id_ed25519.pub it will be used instead of generating a new one.
#
# One-liner to fetch and run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/frederikja163/dotfiles/main/setup.sh)
set -euo pipefail

REPO="git@github.com:frederikja163/dotfiles.git"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

info()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m    %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m    !! %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m    %s\033[0m\n' "$*" >&2; exit 1; }

confirm() {
  printf '\n\033[1;36m>>> %s\033[0m\n' "$1"
  read -r -p "    Press Enter to continue..."
}

# ── 1. git ───────────────────────────────────────────────────────────────────

info "Checking for git..."
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | cut -d' ' -f3) already installed"
else
  info "Installing git..."
  sudo pacman -S --noconfirm --needed git
  ok "git installed"
fi

# ── 2. SSH key ───────────────────────────────────────────────────────────────

info "Checking for SSH key..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

KEY="$HOME/.ssh/id_ed25519.pub"

if [ -f "$KEY" ]; then
  ok "Existing key found — skipping generation"
else
  info "Generating new SSH key (ed25519)..."
  ssh-keygen -t ed25519 -C "dotfiles" -f "$HOME/.ssh/id_ed25519"
  ok "Key generated"
fi

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Your public key — copy this and add it to GitHub:          │"
echo "├──────────────────────────────────────────────────────────────┤"
echo ""
cat "$KEY"
echo ""
echo "└──────────────────────────────────────────────────────────────┘"

echo ""
echo "  1. The page below will open at https://github.com/settings/keys"
echo "  2. Click 'New SSH key', paste the key above, and save"
echo ""

# ── 3. Open GitHub ───────────────────────────────────────────────────────────

info "Opening GitHub SSH keys page..."
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "https://github.com/settings/keys" 2>/dev/null &
elif command -v open >/dev/null 2>&1; then
  open "https://github.com/settings/keys"
else
  warn "No browser launcher found — open https://github.com/settings/keys manually"
fi

# ── 4. Wait for user ────────────────────────────────────────────────────────

confirm "Add the key on GitHub, then press Enter to continue"

# ── 5. Clone ─────────────────────────────────────────────────────────────────

info "Cloning dotfiles..."
if [ -d "$DOTFILES_DIR" ]; then
  ok "Directory $DOTFILES_DIR already exists — skipping clone"
else
  git clone "$REPO" "$DOTFILES_DIR"
  ok "Cloned to $DOTFILES_DIR"
fi

# ── 6. Install ───────────────────────────────────────────────────────────────

info "Running install.sh..."
. "$DOTFILES_DIR/lib/dotfiles-lib.sh" || die "could not source dotfiles-lib.sh"
dotfiles_apply all

echo ""
ok "Done. Reload your shell or start a new terminal."
