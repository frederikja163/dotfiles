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

# Only packages that are missing entirely are this script's business, and only
# then does pacman run at all.
#
# `pacman -S --needed <the whole list>` was what this did, and it is wrong twice
# over. It treats a listed package being out of date as something to fix, which
# is system maintenance rather than anything to do with these dotfiles -- and
# because it names the package without upgrading the system, it is a partial
# upgrade, which Arch does not support. That is not theoretical; it broke:
#
#   installing aquamarine (0.15.0-2) breaks dependency 'libaquamarine.so=13-64'
#   required by hyprtoolkit
#
# hyprland was in the list and due an update, so pacman pulled in its new
# dependency aquamarine (libaquamarine.so=14) while leaving hyprtoolkit -- an
# indirect dependency, absent from the list -- at the build wanting so=13. The
# transaction could not be satisfied, so nothing installed at all. The repos
# were consistent the whole time; only this script's view of them was not.
#
# Skipping installed packages avoids that by not asking for the upgrade in the
# first place, which is also what stops a routine `dotfiles-update` from
# dragging in a kernel and the reboot that follows it. When something genuinely
# is missing there is no way around -u: installing a named package against a
# freshly synced database is the classic Arch breakage, so the full upgrade
# comes with it and is announced rather than sprung.
#
# A list entry naming a virtual or a provider rather than a real package would
# look missing here and be installed explicitly. There are none today; the
# alternative, parsing `pacman -T`, is harder to read for a case that does not
# yet exist.
mapfile -t pkgs < <(read_list "$DOTFILES/packages/pacman.txt")

missing=()
for pkg in "${pkgs[@]}"; do
  pacman -Qq "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

if [ ${#missing[@]} -eq 0 ]; then
  echo "==> pacman: all ${#pkgs[@]} packages present, nothing to install"
  echo "    (upgrading the system is separate: sudo pacman -Syu)"
else
  echo "==> pacman: ${#missing[@]} of ${#pkgs[@]} missing: ${missing[*]}"
  echo "    Installing these requires a full system upgrade (-Syu); a partial"
  echo "    one is what breaks Arch. Expect a reboot if the kernel is included."
  sudo pacman -Syu --needed "${missing[@]}"
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

# Same rule as the pacman block above: only what is missing, and yay is not run
# at all when there is nothing to build. It matters more here, because yay would
# otherwise rebuild AUR packages from source on a routine dotfiles pull.
mapfile -t aur < <(read_list "$DOTFILES/packages/aur.txt")

aur_missing=()
for pkg in "${aur[@]}"; do
  pacman -Qq "$pkg" >/dev/null 2>&1 || aur_missing+=("$pkg")
done

if [ ${#aur_missing[@]} -eq 0 ]; then
  echo "==> yay: all ${#aur[@]} AUR packages present, nothing to build"
elif ! command -v yay >/dev/null; then
  echo "!! yay not found, skipping AUR packages: ${aur_missing[*]}" >&2
else
  # -Syu rather than -S for the reason the pacman block explains: building a
  # new AUR package can pull repo dependencies with it, and naming those
  # without upgrading the system is the same partial upgrade by another route.
  echo "==> yay: ${#aur_missing[@]} of ${#aur[@]} missing: ${aur_missing[*]}"
  yay -Syu --needed "${aur_missing[@]}"
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
