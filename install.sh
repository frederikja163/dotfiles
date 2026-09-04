#!/usr/bin/env bash
# Symlink each config from this repo to its destination.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Anything displaced by this run goes here, grouped by timestamp.
# Remove every backup ever taken with:  rm -rf "$BACKUP_ROOT"
BACKUP_ROOT="${DOTFILES_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/backups}"
RUN="$(date +%Y%m%d-%H%M%S)"

# link <path-in-repo> <absolute-destination>
link() {
  local src="$DOTFILES/$1" dst="$2"

  if [ ! -e "$src" ]; then
    echo "missing $src" >&2
    return 1
  fi

  if [ -L "$dst" ]; then
    if [ "$(readlink -f "$dst")" = "$src" ]; then
      echo "ok      $dst"
      return
    fi
    rm "$dst"
  elif [ -e "$dst" ]; then
    # Mirror the destination's absolute path inside the backup dir so that
    # entries never collide and their origin stays obvious.
    local bak="$BACKUP_ROOT/$RUN/${dst#/}"
    mkdir -p "$(dirname "$bak")"
    mv "$dst" "$bak"
    echo "backup  $dst -> $bak"
  fi

  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "link    $dst -> $src"
}

# --- configs ---------------------------------------------------------------

link neovim   "$HOME/.config/nvim"
link hypr     "$HOME/.config/hypr"
link kitty    "$HOME/.config/kitty"
link waybar   "$HOME/.config/waybar"
link dunst    "$HOME/.config/dunst"
link fuzzel   "$HOME/.config/fuzzel"
link zsh/.zshenv "$HOME/.zshenv"                 # stub: points zsh at ZDOTDIR
link zsh/.zshrc  "$HOME/.config/zsh/.zshrc"
link git      "$HOME/.config/git"                # ~/.gitconfig would override it
link bin      "$HOME/.local/bin"
