#!/usr/bin/env bash
# Install everything on this machine: the packages first, then the config
# symlinks, in that order because a config is no use linked into place if the
# program reading it is not installed yet.
#
#   install.sh             packages, then links
#   install.sh packages    just the packages (needs sudo)
#   install.sh links       just the symlinks
#
# This was two files and became one. Every call site that mattered -- setup.sh
# on a fresh machine, bin/dotfiles-update for updates -- needed both halves
# anyway, so a single dispatch over two functions has less surface than the
# pair of files had, and the halves still run independently for when only one
# is meant. Safe to re-run: each half skips whatever is already done.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mode="${1:-all}"
case "$mode" in
    all|packages|links) ;;
    *) echo "usage: install.sh [all|packages|links]" >&2; exit 1 ;;
esac

# --- packages ---------------------------------------------------------------

install_packages() {
    if ! command -v pacman >/dev/null; then
        echo "This script only supports Arch-based distros (pacman not found)." >&2
        exit 1
    fi

    # Strip comments and blank lines from a package list.
    read_list() {
        sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$1"
    }

    # --- official repos ----------------------------------------------------

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

    # --- AUR signing keys --------------------------------------------------
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

    # --- .NET global tools ----------------------------------------------------

    # Global tools are where these niceties live. dotnet-script runs C# files
    # straight from the command line. roslyn-language-server is the C# language
    # server (Microsoft.CodeAnalysis.LanguageServer) for real .cs projects; nvim
    # starts it via lspconfig's roslyn_ls config. OmniSharp (installed from the
    # AUR, for .csx scripts -- roslyn serves no project-less file) is the second
    # half of that split, see neovim/init.lua.
    #
    # roslyn-language-server must come from the Azure DevOps feed rather than
    # nuget.org: it is what ships the versions VS Code uses, and the --prerelease
    # flag is required because there are no stable tags.
    #
    # The shims land in ~/.dotnet/tools, which is not on PATH by default --
    # zsh/.zshrc and hypr/environment.lua put it there, the latter so an nvim
    # started from a keybind (with no shell profile behind it) can still start
    # the server.
    dotnet_tools=(dotnet-script)
    if command -v dotnet >/dev/null; then
        if dotnet tool list -g | grep -q roslyn-language-server; then
            echo "==> roslyn-language-server already installed"
        else
            echo "==> installing roslyn-language-server"
            dotnet tool install -g roslyn-language-server --prerelease \
                --source https://pkgs.dev.azure.com/azure-public/vside/_packaging/vs-impl/nuget/v3/index.json
        fi
        for tool in "${dotnet_tools[@]}"; do
            if dotnet tool list -g | grep -q "$tool"; then
                echo "==> $tool already installed"
            else
                echo "==> installing $tool"
                dotnet tool install -g "$tool"
            fi
        done
    else
        echo "!! dotnet not found, skipping .NET global tools" >&2
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
}

# --- Rider ------------------------------------------------------------------

# Rider is the one program here that cannot be installed by this script:
# Toolbox owns it and has no usable CLI. So the most that can be done is to
# notice it is absent and put Toolbox in front of the user -- at the very end,
# once nothing else is waiting on the terminal, and only when it is actually
# missing. It used to print the same paragraph on every run regardless, which
# is noise on a machine where Rider has been installed for months.
#
# Detected by the Toolbox shim rather than `command -v rider` alone, which is
# what bin/ide uses but is not enough here: the shim directory reaches PATH via
# zsh/.zshrc and hypr/environment.lua, and this script runs under bash with
# neither necessarily applied -- on a fresh machine the login shell has not
# even been zsh until a few lines ago, so an installed Rider would look absent.
# PATH is still consulted as well, for a Rider that came from somewhere other
# than Toolbox.
install_rider() {
    local shim="${XDG_DATA_HOME:-$HOME/.local/share}/JetBrains/Toolbox/scripts/rider"

    if [ -x "$shim" ] || command -v rider >/dev/null; then
        echo "==> Rider already installed"
        return
    fi

    if ! command -v jetbrains-toolbox >/dev/null; then
        echo "!! Rider is missing, and so is jetbrains-toolbox to install it from." >&2
        echo "   Install the jetbrains-toolbox AUR package first, then re-run this." >&2
        return
    fi

    # No display, no Toolbox window: run from a bare VT or over ssh the launch
    # would fail somewhere the user cannot see, so say what to do instead of
    # appearing to have done it.
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
        cat <<'EOF'

Remaining manual step:
  Rider — open JetBrains Toolbox and install it from there. Toolbox has no
  usable CLI, so this cannot be scripted.
EOF
        return
    fi

    echo
    echo "==> Rider is not installed; opening JetBrains Toolbox — install it from there."
    # Detached for the reason bin/ide gives: this script is about to exit, and
    # Toolbox has to outlive the shell that started it. -f forks and returns
    # straight away, which a plain "&" only almost does.
    setsid -f jetbrains-toolbox </dev/null >/dev/null 2>&1
}

# --- config symlinks --------------------------------------------------------

install_links() {
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

    link neovim   "$HOME/.config/nvim"
    link hypr     "$HOME/.config/hypr"
    link kitty    "$HOME/.config/kitty"
    link waybar   "$HOME/.config/waybar"
    link dunst    "$HOME/.config/dunst"
    link fuzzel   "$HOME/.config/fuzzel"
    link yazi     "$HOME/.config/yazi"
    link zsh/.zshenv "$HOME/.zshenv"                 # stub: points zsh at ZDOTDIR
    link zsh/.zshrc  "$HOME/.config/zsh/.zshrc"
    link git      "$HOME/.config/git"                # ~/.gitconfig would override it
    # bin/ is deliberately not linked. It was linked to ~/.local/bin, which put
    # the repo's working tree at the exact path pipx, uv and `pip install
    # --user` install into, inside a repo that is public. zsh/.zshrc and
    # hypr/environment.lua name ~/dotfiles/bin on PATH instead.
    link .omnisharp "$HOME/.omnisharp"     # global omnisharp.json for .csx scripts

    # opencode's *global* config, which is the one that carries the model and
    # the agents; the repo's own opencode.json beside AGENTS.md is a separate,
    # project-scoped file and is not linked anywhere.
    #
    # No credentials go through here. opencode keeps those in
    # ~/.local/share/opencode/auth.json, outside the config directory entirely,
    # which is what makes this safe to track in a public repo.
    #
    # opencode installs @opencode-ai/plugin into whatever directory this
    # resolves to and writes a .gitignore covering the npm droppings; that
    # .gitignore is tracked verbatim so regenerating it is a no-op.
    link opencode "$HOME/.config/opencode"

    # What opens a directory: yazi, via the kitty-wrapping entry in the same
    # folder (see the comments in xdg/mimeapps.list). Separate links rather
    # than a linked xdg/ because the two files live on opposite sides of the
    # config/data split.
    link xdg/mimeapps.list "$HOME/.config/mimeapps.list"
    link xdg/applications/yazi.desktop "$HOME/.local/share/applications/yazi.desktop"

    # Browsers reveal a file through org.freedesktop.FileManager1 instead of the
    # default above; this shadows Dolphin's provider so that call fails and they
    # fall back to yazi. See the comment in the file.
    link xdg/dbus-1/services/org.freedesktop.FileManager1.service \
         "$HOME/.local/share/dbus-1/services/org.freedesktop.FileManager1.service"

    # The desktop database is a cache of which .desktop file claims which MIME
    # types, and the directory default is looked up through it. Linking the
    # entry above is not enough on its own: until this runs, the file is there
    # but no directory resolves to it.
    if command -v update-desktop-database >/dev/null; then
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    fi
}

# --- music ------------------------------------------------------------------

# Give a fresh machine something for `music` to play, and only a fresh machine.
#
# The rule is that a single audio file in ~/Music stops this dead. Not "top the
# collection up to an hour", which is what it did first and is wrong: the
# directory is the user's, a deliberately curated four tracks is a collection
# and not a shortfall, and anything measuring what is there against a target
# eventually deletes or duplicates to meet it. Nothing at all is the only state
# that reads as "nobody has put music here yet" without guessing.
#
# The test lives here rather than inside bin/music-get, which always downloads:
# a downloader that refuses unless the directory is empty is a one-shot seeder
# and cannot be used to fetch more, which is the job its name promises. The
# condition is `music --list` printing nothing, so the extension list that
# decides what counts as music stays in bin/music alone.
#
# Silent and never fatal, by instruction, and that is this line's business
# rather than the downloader's. bin/music-get reports and exits non-zero like
# any other tool when run by hand; the redirect and `|| true` are what make it
# quiet here. install.sh runs under `set -e`, so without the `|| true` a failed
# or interrupted download would abandon the install part way through, after the
# packages and before the links. Missing music is not worth that.
#
# Not backgrounded. It was, and it is worse: setup.sh ends, the terminal looks
# finished, and 600MB keeps arriving over a connection the user is about to
# take elsewhere, with nothing on screen to say so and no way to stop it short
# of finding the pid.
seed_music() {
    [ -x "$DOTFILES/bin/music-get" ] || return 0

    # Spelled as an `if` rather than `[ -n ... ] && return 0`. Bash exempts the
    # left side of an && from `set -e`, so the short form does work, but the
    # reader has to know that to see it -- and the cost of being wrong here is
    # an install that stops silently at this line.
    if [ -n "$("$DOTFILES/bin/music" --list 2>/dev/null)" ]; then
        return 0
    fi

    "$DOTFILES/bin/music-get" 60 >/dev/null 2>&1 || true
}

# install_rider comes last in both modes that install anything, rather than at
# the end of install_packages where the message used to be: it can open a
# window, and that belongs after the run rather than in the middle of one.
#
# seed_music runs only in `all`. It needs both halves: mpv comes from the
# packages and ~/Music being worth filling follows from the rest being in
# place, and neither single-half mode is a fresh machine.
case "$mode" in
    all)      install_packages; install_links; seed_music; install_rider ;;
    packages) install_packages; install_rider ;;
    links)    install_links ;;
esac