# dotfiles

| In repo    | Links to                | Contents                          |
| ---------- | ----------------------- | --------------------------------- |
| `neovim`   | `~/.config/nvim`        | `init.lua` + pack lock            |
| `hypr`     | `~/.config/hypr`        | Hyprland modules, hyprlock, hypridle |
| `waybar`   | `~/.config/waybar`      | `config.jsonc`, `style.css`       |
| `kitty`    | `~/.config/kitty`       | `kitty.conf`                      |
| `dunst`    | `~/.config/dunst`       | `dunstrc`                         |
| `fuzzel`   | `~/.config/fuzzel`      | `fuzzel.ini`                      |
| `zsh`      | `~/.zshenv`, `~/.config/zsh/` | oh-my-zsh setup, PATH       |
| `bin`      | `~/.local/bin`          | small scripts, on `PATH`          |
| `packages` | —                       | `pacman.txt`, `aur.txt`           |

All of kitty, waybar and dunst use the catppuccin-mocha palette and
JetBrainsMono Nerd Font, matching the Neovim colorscheme.

## Keeping $HOME clean

Config is kept in `~/.config` rather than `$HOME` wherever the program allows
it. zsh is the awkward case: it always reads `$HOME/.zshenv` before it knows
about `ZDOTDIR`, so a one-line stub has to stay there. It points at
`~/.config/zsh`, where the real `.zshrc` lives.

The rest is moved out with variables set in `zsh/.zshrc`:

| What          | Was                | Now                                  |
| ------------- | ------------------ | ------------------------------------ |
| oh-my-zsh     | `~/.oh-my-zsh`     | `~/.local/share/oh-my-zsh`           |
| shell history | `~/.zsh_history`   | `~/.local/state/zsh/history`         |
| completion    | `~/.zcompdump*`    | `~/.cache/zsh/zcompdump-$ZSH_VERSION`|

Only removing `$HOME/.zshenv` requires root, by setting `ZDOTDIR` in
`/etc/zsh/zshenv` instead.

## Hyprland config layout

`hypr/hyprland.lua` is only an entry point; it requires one module per concern.
Hyprland puts the config directory on Lua's `package.path`, so `require("look")`
resolves to `hypr/look.lua`.

| Module            | Contains                                             |
| ----------------- | ---------------------------------------------------- |
| `programs.lua`    | app names + main modifier, returned as a table       |
| `monitors.lua`    | display layout                                       |
| `environment.lua` | env vars, `PATH`, permissions                        |
| `look.lua`        | gaps, borders, decoration, animations, layouts, misc |
| `input.lua`       | keyboard, mouse, touchpad, gestures                  |
| `windowrules.lua` | window, layer and workspace rules                    |
| `keybinds.lua`    | every bind, each with a `description`                |
| `autostart.lua`   | processes launched with the session                  |

`programs.lua` is the only module that returns a value; `keybinds.lua` requires
it so the terminal and launcher are named in one place.

## Desktop notes

Waybar runs **two bars**, configured by monitor name in `waybar/config.jsonc`:
a full one on `DP-4` (ultrawide) and a lean one on `eDP-1` (laptop panel).
Rename these if the hardware changes — `hyprctl monitors` lists them.

Waybar and hyprpaper are autostarted from `hypr/hyprland.lua`. dunst is
dbus-activated and needs no autostart entry.

**SUPER + /** shows a searchable list of every keybind, via `bin/hypr-keybinds`.
The list is generated from `hyprctl binds`, so it reflects what the compositor
actually has loaded and cannot drift from the config. It only works because
every `hl.bind` in `hypr/hyprland.lua` passes a `description` — new binds must
do the same or they will not appear:

**SUPER + Escape** opens the power menu (`bin/power-menu`): lock, suspend, log
out, reboot, shut down. The three destructive entries ask for confirmation.
Locking uses `hyprlock`; `hypridle` dims at 5 min, locks at 10, blanks the
displays at 12 and suspends at 30 (`hypr/hypridle.conf`).

Both the launcher (SUPER + R) and the cheatsheet use **fuzzel**, chosen over
hyprlauncher because it closes as soon as it loses keyboard focus. hyprlauncher
has no config file and is drawn by the compositor itself, so it appears in
neither `hyprctl clients` nor `hyprctl layers` and cannot be dismissed by a
window rule.

Scripts in `bin/` are reachable from keybinds because `hypr/hyprland.lua` adds
`~/.local/bin` to `PATH`. The graphical session does not source `~/.zshrc`, so
setting it there alone is not enough.

```lua
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal), { description = "Open terminal" })
```

Reloading without a logout:

```sh
hyprctl reload              # hyprland
killall -SIGUSR2 waybar     # waybar
dunstctl reload             # dunst
# kitty: ctrl+shift+f5
```

## Install

```sh
./install-packages.sh   # packages + neovim (Arch/EndeavourOS, needs sudo)
./install.sh            # symlink configs
```

`install.sh` backs up displaced files (see below) and leaves correct symlinks alone.
Both scripts are safe to re-run.

## Packages

`install-packages.sh` installs the things needed on every machine:
`packages/pacman.txt` via `pacman -S --needed`, `packages/aur.txt` via `yay`,
Neovim via [bob](https://github.com/MordechaiHadad/bob), then oh-my-zsh and
`chsh` to zsh. Every step is skipped if already done.

**Rider** is not installed by the script. `jetbrains-toolbox` is, and Rider is
installed from the Toolbox GUI — Toolbox has no usable CLI.

Work-machine-only software (GlobalProtect, Teams, FreeIPA/domain-join) is
deliberately excluded.

The Neovim version is pinned by `NVIM_VERSION`, set in the bob section of the
script. Override per run:

```sh
NVIM_VERSION=v0.11.3 ./install-packages.sh
```

bob's binary is not on `PATH` by default. Add to your shell config:

```sh
export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"
```

## Adding a config

Add one `link <path-in-repo> <absolute-destination>` line at the bottom of
`install.sh`. The destination is spelled out in full, so it can go anywhere.
Either argument may be a file or a directory:

```sh
link neovim     "$HOME/.config/nvim"
link zsh/.zshrc "$HOME/.zshrc"
link ghostty    "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
link scripts    "/opt/local/share/scripts"
```

## Backups

Files displaced by `install.sh` are moved to
`~/.local/state/dotfiles/backups/<timestamp>/<original path>`. Remove them all with:

```sh
rm -rf ~/.local/state/dotfiles/backups
```
