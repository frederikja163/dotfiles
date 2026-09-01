# The only zsh file that has to live in $HOME.
#
# zsh always reads $HOME/.zshenv first and only then looks in $ZDOTDIR, so this
# stub is what redirects everything else into ~/.config/zsh. The alternative is
# setting ZDOTDIR in /etc/zsh/zshenv, which needs root and is not portable.
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
