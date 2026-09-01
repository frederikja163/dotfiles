#!/usr/bin/env bash
# Install the packages needed on every machine. Arch / EndeavourOS only.
# Safe to re-run: --needed skips anything already present.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pacman >/dev/null; then
  echo "This script only supports Arch-based distros (pacman not found)." >&2
  exit 1
fi

# Strip comments and blank lines from a package list.
read_list() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
}

# --- official repos --------------------------------------------------------

mapfile -t pkgs < <(read_list "$DOTFILES/packages/pacman.txt")
if [ ${#pkgs[@]} -gt 0 ]; then
  echo "==> pacman (${#pkgs[@]} packages)"
  sudo pacman -S --needed "${pkgs[@]}"
fi

# --- AUR -------------------------------------------------------------------

mapfile -t aur < <(read_list "$DOTFILES/packages/aur.txt")
if [ ${#aur[@]} -gt 0 ]; then
  if command -v yay >/dev/null; then
    echo "==> yay (${#aur[@]} packages)"
    yay -S --needed "${aur[@]}"
  else
    echo "!! yay not found, skipping AUR packages: ${aur[*]}" >&2
  fi
fi

# --- neovim via bob --------------------------------------------------------

NVIM_VERSION="${NVIM_VERSION:-v0.12.5}"

echo "==> bob: neovim $NVIM_VERSION"
bob install "$NVIM_VERSION"
bob use "$NVIM_VERSION"

if ! command -v nvim >/dev/null; then
  echo
  echo "!! nvim is not on PATH. Add bob's shim directory to your shell config:"
  echo '   export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"'
fi

# --- oh-my-zsh -------------------------------------------------------------

# Installed under XDG_DATA_HOME rather than ~/.oh-my-zsh, matching the ZSH
# variable set in zsh/.zshrc. KEEP_ZSHRC stops the installer replacing the
# config this repo links in.
OMZ_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/oh-my-zsh"

if [ -d "$OMZ_DIR" ]; then
  echo "==> oh-my-zsh already installed"
else
  echo "==> oh-my-zsh"
  ZSH="$OMZ_DIR" KEEP_ZSHRC=yes RUNZSH=no CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# --- login shell -----------------------------------------------------------

if [ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ]; then
  echo "==> login shell already zsh"
else
  echo "==> setting login shell to zsh"
  chsh -s "$(command -v zsh)"
fi

# --- udev rules ------------------------------------------------------------

# Wake-from-dock. See the comments in the rule for why this is needed.
for rule in "$DOTFILES"/system/*.rules; do
  [ -e "$rule" ] || continue
  dest="/etc/udev/rules.d/$(basename "$rule")"

  if sudo cmp -s "$rule" "$dest" 2>/dev/null; then
    echo "==> udev: $(basename "$rule") already installed"
  else
    echo "==> udev: installing $(basename "$rule")"
    sudo install -m 644 "$rule" "$dest"
    sudo udevadm control --reload
    # Re-run the rules against devices that are already plugged in, so this
    # takes effect without a reboot.
    sudo udevadm trigger --subsystem-match=usb --action=add
  fi
done

# --- manual steps ----------------------------------------------------------

cat <<'EOF'

Remaining manual step:
  Rider — open JetBrains Toolbox and install it from there. Toolbox has no
  usable CLI, so this cannot be scripted.
EOF
