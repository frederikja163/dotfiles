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

## Desktop model

Windows live in **columns** on an infinite horizontal tape (Hyprland's
`scrolling` layout). Each column stacks windows vertically.

- A new window always opens in the **currently focused column**. Hyprland first
  puts it in a column of its own and scrolls the tape to reveal it; that scroll
  is not undone when the column merges into its neighbour, which used to shove
  the columns on the left off screen. `columns.lua` suppresses it with
  `inhibit_scroll` from `window.open_early` — by `window.open` the tape has
  already moved.
- `SUPER + N` moves the focused window out into a **new column**. So creating a
  column is `SUPER+Q` then `SUPER+N`, not the other way round.
- New column width: if all columns were equal, they are re-evened; otherwise the
  new column takes half the width of the column it came from.
- The columns of a desktop **always add up to exactly the monitor width** —
  never less, so there is no dead space, and never more, so the view never
  scrolls sideways when focus moves. Resizing takes from the other columns
  rather than growing the total; splitting a window out halves the column it
  came from; and anything that changes the columns (opening, closing, moving a
  window, a workspace landing on another monitor) ends with the widths
  rebalanced and the columns pulled back against the left edge. Relative sizes
  are preserved when rebalancing, so deliberately uneven columns stay uneven.

  Removing a column is measured a moment *after* the fact: reading the geometry
  straight away still shows the column that is going away, so the layout looks
  correct and nothing gets fixed.
- `SUPER + H/J/K/L` moves focus within the desktop and wraps at the ends; it
  never steps onto another monitor, so the binds do not depend on how the
  monitors are arranged. Use the number keys to switch monitor.
- `SUPER + SHIFT + H/L` moves the focused window into the neighbouring column,
  and `SUPER + SHIFT + J/K` moves it up and down inside its own column.
- `SUPER + ALT + H/L` swaps the whole column with its neighbour, and
  `SUPER + CTRL + H/L` resizes the column within the bounds above.
- `SUPER + M` cycles windows through the **main slot**, which is the widest
  column. If the focused window is outside that column it moves into it;
  otherwise each press pulls in the next window from elsewhere. Focus follows
  the main slot, so the big window is always the focused one. Windows sharing
  the main column are skipped, since swapping with a sibling changes nothing.

Monitors are numbered by id — **1 = eDP-1** (laptop), **2 = DP-4** (ultrawide).
The number keys are overloaded on whether that monitor is already focused:

| | monitor not focused | monitor already focused |
| --- | --- | --- |
| `SUPER + n` | focus it | next desktop, wrapping — or a new one if it is the only desktop |
| `SUPER + SHIFT + n` | move window to it | move window to next desktop |
| `SUPER + CTRL + n` | duplicate/extend toggle | new desktop, focused |

Empty desktops are removed by Hyprland automatically. There are no direct
`SUPER + 1..9` desktop binds any more; cycle with `SUPER + n` on the focused
monitor instead.

A monitor that is duplicating another **disappears from `hl.get_monitors()`**,
and `hl.get_monitor(name)` returns nil for it, so Hyprland cannot be asked about
it at all. `deskbinds.lua` therefore remembers which monitors it has set to
duplicate: without that, the monitor's number would stop responding and the
duplicate could never be switched off. Remembered monitors are spliced back into
the numbering by id, so the other monitors keep their numbers. (`hyprctl
monitors all` does list them, but calling `hyprctl` from inside the config
deadlocks — the compositor is busy running the Lua.)

Toggling duplication also refreshes waybar (`pkill -USR2 -x waybar`), since its
bars are keyed by monitor name and its workspace buttons by desktop name, both
of which change when a monitor comes or goes.

Desktops are **numbered per monitor**. Hyprland's own workspace ids are global,
so the second monitor can own ids 2 and 3. `deskbinds.lua` renames every desktop
to `<monitor>.<desktop>` — `1.1`, `2.1`, `2.2` — and `waybar/config.jsonc` maps
those to a plain `1`, `2`, `3` for display via `format-icons`.

The names are deliberately unique across monitors rather than just `1`, `2`.
Waybar marks a button active when its name equals the *globally* focused
workspace's name, with no monitor check (`workspaces.cpp`, `isActiveByName`), so
two monitors each owning a desktop named `1` makes both highlight at once. It
resolves a workspace's monitor by name too, which also misattributes the
`hosting-monitor` class.

In the bar, the focused desktop uses `.active` (solid) and the other monitor's
current desktop uses `.visible` (muted), so only one looks selected.

Everything in the config still addresses workspaces by their global id.

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
| `deskbinds.lua`   | monitor + desktop binds on the number keys           |
| `columns.lua`     | column behaviour: new column, sizing, swap-biggest   |
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

## Tests

```sh
./tests/run.sh
```

Runs the Lua tests for `hypr/columns.lua` and `hypr/deskbinds.lua` against a
stubbed `hl` API, then `Hyprland --verify-config`. Nothing touches the running
compositor, so it is safe at any time.

A stubbed API accepts calls the real one rejects, so behaviour changes are worth
trying in a nested instance:

```sh
HYPR_SANDBOX=1 Hyprland -c hypr/hyprland.lua
```

`HYPR_SANDBOX=1` skips autostart — `hypridle` would otherwise lock or suspend
the *host* session — and switches the modifier to ALT, because the host
compositor grabs every SUPER combination before the nested one sees it.

Editing `hypr/` applies immediately: `~/.config/hypr` is a symlink into this
repo and Hyprland reloads on change. To work on the config without that, copy it
elsewhere and point `HYPR_DIR` and `-c` at the copy.

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
