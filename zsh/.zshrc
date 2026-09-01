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

# --- path ------------------------------------------------------------------
# bob-managed neovim
export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"

# scripts from the dotfiles repo (bin/ is linked to ~/.local/bin)
export PATH="$HOME/.local/bin:$PATH"

# JetBrains Toolbox shell scripts (rider, etc.)
export PATH="$XDG_DATA_HOME/JetBrains/Toolbox/scripts:$PATH"
