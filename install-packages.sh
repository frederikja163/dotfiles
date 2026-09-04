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

# --- AUR signing keys ------------------------------------------------------
#
# Some AUR PKGBUILDs declare a validpgpkeys fingerprint without the key being
# importable from the usual keyservers, which stalls yay at "PGP keys need
# importing". The key is not on the public keyservers at all — not even on a
# healthy one — so this is not a transient outage; a fresh system runs into
# the same wall. List them here as "keyid url" and the key is imported from
# the project's own server, after confirming the fingerprint matches.
aur_keys=(
  "224FA88A5A19A03B06827A1BF60CE2127D6BBBDE https://update.tasks.org/keys.asc"  # tasks-bin
)
for aur_key in "${aur_keys[@]}"; do
  read -r keyid url <<< "$aur_key"
  if gpg --list-keys "$keyid" >/dev/null 2>&1; then
    continue
  fi
  tmp="$(mktemp)"
  if curl -fsSL "$url" -o "$tmp"; then
    if [ "$(gpg --show-keys "$tmp" 2>/dev/null | sed -n '/^pub/{n;p;}' | tr -d ' ')" = "$keyid" ]; then
      echo "==> importing PGP key $keyid"
      gpg --import "$tmp"
    else
      echo "!! key file from $url does not match $keyid, skipping" >&2
    fi
  else
    echo "!! could not fetch key from $url" >&2
  fi
  rm -f "$tmp"
done

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

# --- system config ---------------------------------------------------------

# Files in system/ belong under /etc, so they need root. See the comments in
# each for what it does and why.
install_system_file() {
  local src="$1" dest="$2"

  if sudo cmp -s "$src" "$dest" 2>/dev/null; then
    echo "==> $(basename "$dest") already installed"
    return 1
  fi

  echo "==> installing $(basename "$dest")"
  sudo install -Dm 644 "$src" "$dest"
  return 0
}

if [ -e "$DOTFILES/system/90-no-suspend.conf" ]; then
  if install_system_file "$DOTFILES/system/90-no-suspend.conf" \
                         /etc/systemd/logind.conf.d/90-no-suspend.conf; then
    # logind re-reads its config on restart. Restarting it does not end the
    # session, but it does briefly drop its inhibitor locks.
    sudo systemctl restart systemd-logind
  fi
fi

# --- manual steps ----------------------------------------------------------

cat <<'EOF'

Remaining manual step:
  Rider — open JetBrains Toolbox and install it from there. Toolbox has no
  usable CLI, so this cannot be scripted.
EOF
