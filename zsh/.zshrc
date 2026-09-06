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

# .NET SDK + runtime (full install; /usr/share/dotnet is missing aspnet-runtime)
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$PATH"
