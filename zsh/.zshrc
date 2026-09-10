# Lives at ~/.config/zsh/.zshrc, found via ZDOTDIR (set in ~/.zshenv).

# XDG base directories, referenced below.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# --- history ---------------------------------------------------------------
# History is state, not config, so it belongs under XDG_STATE_HOME.
HISTFILE="$XDG_STATE_HOME/zsh/history"
HISTSIZE=10000
SAVEHIST=10000
mkdir -p "${HISTFILE:h}"

# --- oh-my-zsh -------------------------------------------------------------
export ZSH="$XDG_DATA_HOME/oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)

# Keep the completion dump out of $HOME as well.
ZSH_COMPDUMP="$XDG_CACHE_HOME/zsh/zcompdump-$ZSH_VERSION"
mkdir -p "${ZSH_COMPDUMP:h}"

source "$ZSH/oh-my-zsh.sh"

# --- title -----------------------------------------------------------------
# `title comms` names the desktop you are on -- bin/title -- but oh-my-zsh
# gets that word first: lib/termsupport.zsh defines a `title` function that
# sets the *terminal's* title, and a shell function beats anything on PATH. So
# the command appeared to work and did nothing: no error, no change on the
# bar. That is what this section exists for.
#
# Both are kept, because oh-my-zsh's is not decoration. Its precmd and preexec
# hooks call `title` on every prompt and every command, and those escape
# sequences are the signal hypr/quake.lua watches to notice a `cd` and rename
# the desktop after its new directory. Take them away -- DISABLE_AUTO_TITLE
# and `unfunction title`, which is the obvious fix -- and every desktop name
# on the bar freezes, which is the opposite of the point.
#
# So oh-my-zsh keeps its function under another name, and only a `title` typed
# at the prompt reaches the script. The test is the function stack: the hooks
# call it from omz_termsupport_precmd/preexec, which leaves that name below
# this one on the stack, while a command typed at the prompt has nothing under
# it at all.
if (( $+functions[title] )); then
  functions[omz-title]=$functions[title]

  title() {
    if (( $#funcstack > 1 )); then
      omz-title "$@"     # oh-my-zsh's hooks: the terminal's own title
      return
    fi
    command title "$@"   # typed at the prompt: the name of the desktop
  }
fi

# --- prompt pinned to the bottom --------------------------------------------
# A terminal fills from the top, so a fresh window leaves the prompt at row 1
# with the whole screen empty below it. Pad with blank lines before drawing the
# prompt until the cursor sits on the last row; from then on the screen is full
# and output scrolls the older lines upwards on its own, which is the wanted
# behaviour: new lines appear at the bottom and everything else moves up.
#
# Padding only happens while there is unused space below the cursor — a new
# window, or right after `clear` — so it is a no-op for the rest of the session.
_prompt_to_bottom() {
  [[ -t 1 && $TERM != dumb ]] || return

  # DSR 6: ask the terminal for the cursor position. It answers on stdin with
  # ESC [ <row> ; <col> R. Bail out on anything that does not reply in time
  # rather than swallowing the user's keystrokes.
  local reply row
  print -n $'\e[6n'
  read -s -d 'R' -t 0.5 reply || return
  row=${${reply#*$'\e['}%%;*}
  [[ $row == <-> ]] || return

  (( row < LINES )) && print -n ${(pl:$((LINES - row))::\n:):-}
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _prompt_to_bottom

# --- path ------------------------------------------------------------------
# bob-managed neovim
export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"

# scripts from the dotfiles repo (bin/ is linked to ~/.local/bin)
export PATH="$HOME/.local/bin:$PATH"

# JetBrains Toolbox shell scripts (rider, etc.)
export PATH="$XDG_DATA_HOME/JetBrains/Toolbox/scripts:$PATH"

# .NET lives in the pacman tree. A manual dotnet-install.sh tree in ~/.dotnet
# was used first, because /usr/share/dotnet ships no ASP.NET Core runtime — but
# the aspnet-runtime package supplies that, so the manual copy bought nothing
# and rotted: once its files were gone, DOTNET_ROOT still pointed at the empty
# directory and every apphost-built binary died with ".NET location: Not found".
# Set explicitly rather than relying on the apphost's built-in default, so a
# move off /usr/share/dotnet surfaces here.
export DOTNET_ROOT="/usr/share/dotnet"

# Global tools installed by install.sh (dotnet-script, roslyn-language-server)
# land in ~/.dotnet/tools. Not on PATH by default; repeated here and in
# hypr/environment.lua, which nvim started from a keybind inherits.
export PATH="$HOME/.dotnet/tools:$PATH"
