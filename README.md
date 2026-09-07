# dotfiles

Arch, Hyprland, kitty, Neovim. `install.sh` symlinks everything out of this repo
into place, so editing a file here edits the live system.

This is an index. The reasoning lives in the files themselves, at the top of
each one.

## Quick start

On a fresh EndeavourOS install, paste this into a terminal. It will generate an
SSH key, open GitHub so you can add it, clone the repo, and install everything:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/frederikja163/dotfiles/main/setup.sh)
```

To inspect the script first:

```sh
curl -fsSL https://raw.githubusercontent.com/frederikja163/dotfiles/main/setup.sh | less
```

## What is where

| In repo    | Links to                      | Contents                             |
| ---------- | ----------------------------- | ------------------------------------ |
| `neovim`   | `~/.config/nvim`              | `init.lua` + pack lock               |
| `hypr`     | `~/.config/hypr`              | Hyprland modules, hyprlock, hypridle |
| `waybar`   | `~/.config/waybar`            | `config.jsonc`, `style.css`          |
| `kitty`    | `~/.config/kitty`             | `kitty.conf`                         |
| `dunst`    | `~/.config/dunst`             | `dunstrc`                            |
| `fuzzel`   | `~/.config/fuzzel`            | `fuzzel.ini`                         |
| `zsh`      | `~/.zshenv`, `~/.config/zsh/` | oh-my-zsh setup, `PATH`, prompt      |
| `git`      | `~/.config/git`               | identity and settings                |
| `bin`      | `~/.local/bin`                | small scripts, on `PATH`             |
| `system`   | `/etc`                        | system config (needs root)           |
| `packages` | —                             | `pacman.txt`, `aur.txt`              |
| `tests`    | —                             | `run.sh`, `sandbox.sh`, Lua tests    |

catppuccin-mocha and JetBrainsMono Nerd Font throughout.

## hypr/

`hyprland.lua` is only an entry point. One module per concern:

| Module            | Contains                                                  |
| ----------------- | --------------------------------------------------------- |
| `programs.lua`    | app names + the main modifier; the only module that returns a value |
| `monitors.lua`    | display layout                                            |
| `environment.lua` | env vars, permissions, and the `PATH` keybinds run with   |
| `look.lua`        | gaps, borders, decoration, animations                     |
| `input.lua`       | keyboard, mouse, touchpad, gestures                       |
| `windowrules.lua` | window, layer and workspace rules                         |
| `keybinds.lua`    | app and window binds                                      |
| `deskbinds.lua`   | monitors and desktops on the number keys; desktop naming  |
| `columns.lua`     | the column layout itself, and its binds                   |
| `quake.lua`       | the drop-down terminal, one per desktop                   |
| `autostart.lua`   | processes launched with the session                       |

Also `hyprlock.conf` and `hypridle.conf`, which Hyprland does not read — the
programs of those names do.

## bin/

A `dotfiles-` prefix means the script knows about this repo: it reads its git
state, applies its configs, or writes a file only this repo's Lua parses. A
bare name means the opposite -- it would work unchanged in someone else's
dotfiles, and is named after whatever it drives instead.

| Script                   | Does                                                                |
| ------------------------ | ------------------------------------------------------------------- |
| `dotfiles-check-updates` | says at login if this repo is behind its remote                     |
| `dotfiles-update`        | pull, then re-run the install scripts if the commits need it        |
| `dotfiles-reload`        | apply the dotfiles live: hyprland, waybar, wallpaper, idling, dunst |
| `dotfiles-monitor-order` | pin which screen is monitor 1, 2, ...; set orientation              |
| `dotfiles-session-restore` | last login's desktops and windows back; `--off` to stop           |
| `hypr-keybinds`          | the `SUPER + /` cheatsheet, generated from `hyprctl binds`          |
| `ide`                    | `SUPER + I`: Rider if the directory holds a solution, else nvim     |
| `power-menu`             | `SUPER + Escape`: lock, log out, reboot, shut down                  |
| `proc-cwd`               | the working directory of each pid given                             |
| `screenshot-region`      | `SUPER + S`: select a region, onto the clipboard                    |
| `terminal-cwd`           | the working directory of a terminal's shell, given its pid          |
| `waybar-main`            | starts waybar on every monitor, full bar on the largest             |

Shared shell code lives in `lib/`, which is not on `PATH`: see
`lib/dotfiles-lib.sh`, sourced by `dotfiles-check-updates` and `dotfiles-update`.

## Keys

Each modifier means one thing: **SHIFT** moves · **CTRL** changes geometry ·
**ALT** scopes up from the window to its whole column · **numbers** address
screens.

**SUPER + /** lists every bind, read live from `hyprctl binds`, so it cannot
drift from the config — that is the reference rather than this file. Binds are
declared in `keybinds.lua`, `columns.lua`, `deskbinds.lua` and `quake.lua`; one
without a `description` will not appear in the list.

Apps open where the desktop is, meaning the directory of its quake terminal:
``SUPER + ` `` drops that terminal down, `SUPER + Q` opens another one beside it
and `SUPER + I` runs `bin/ide` there.

## Desktop model

A **desktop** is a row of **columns**, each a vertical stack of windows.
`columns.lua` is a custom Lua layout, so it places every window itself and the
columns add up to exactly the monitor width by construction, never by
correction.

- A new window joins the focused column at the bottom — unless the desktop has
  only one column, in which case it starts a second, since one column means it
  was never really split up.
- Splitting halves the column it came from, unless the columns were all equal,
  in which case they even out again. Resizing takes from the others in
  proportion, so deliberately uneven columns stay uneven.
- Moving a window past the last column gives it a column of its own; that is how
  a column is made. Swapping a column carries its width with it.
- Focus wraps inside the desktop and never crosses monitors, so the binds do not
  care how the screens are arranged. The number keys cross.
- Column state is in memory only: after a config reload a desktop's windows
  collapse into one column.

Each monitor has a number, `1`..`0`, in an order **pinned** by
`dotfiles-monitor-order` (script or a hand-edited `~/.local/share/hypr/monitor-order`)
rather than by Hyprland's connector ids, which reshuffle on redock. Monitors no
one has pinned yet follow in id order. A screen's line can also carry
`transform=1..3` — orientation for a panel mounted portrait — which
`monitors.lua` applies; the same script asks for it, and then for the row's
direction — monitor 1 on the left (the default `ltr`), on the right (`rtl`),
or the screens stacked top-to-bottom (`ttb`). The number keys act on that
screen — or on your own desktops when you are already on it:

|                    | another screen        | the one you are on              |
| ------------------ | --------------------- | ------------------------------- |
| `SUPER + n`        | focus it              | next desktop, or make a second  |
| `+ SHIFT`          | move window there     | move window to the next desktop |
| `+ CTRL`           | duplicate/extend      | new desktop, and it stays       |
| `+ ALT + SHIFT`    | move column there     | move column to the next desktop |
| `+ CTRL + SHIFT`   | move this desktop there | —                             |

Desktops are **named after the directory** their quake terminal is sitting in,
so the bar reads `dotfiles` rather than `2`; `~` when it has not been taken
anywhere.

Hyprland removes an empty desktop as soon as you leave it, which is right for
one made in passing and wrong for one asked for outright: `SUPER + CTRL + n`
therefore makes a desktop that **stays while empty**, so it can be set up
before there is anything on it. `SUPER + C` closes it — the same key that
closes a window, since an empty desktop is the one time it has no window to
close. It declines on a monitor's last desktop. A desktop kept this way does
not survive `dotfiles-reload`: see the reasoning in `deskbinds.lua`.

Closing a desktop **takes its quake terminal with it**, so the next desktop to
be given that id starts at `~` rather than inheriting a closed desktop's shell
and working directory. A desktop that merely lapses — left empty, so Hyprland
removes it — keeps its terminal, and does pass it on; `quake.lua` says why the
two differ.

They also remember which screen they belong to, recognised by monitor
*description* rather than connector name — `DP-4` came back as `DP-5` after a
redock — and go home when it is plugged back in.

## Across a restart

`session.lua` writes the session down as it changes —
`~/.local/share/hypr/session`, machine-local, one tab-separated record per
line — and `dotfiles-session-restore` puts it back at the next login, started
from `autostart.lua`. What comes back: the desktops, on the right screens,
each with the quake terminal its name comes from, in the directory that shell
was in; and one window per process, so kitty reopens in the right directory and
Rider on the right solution.

What cannot: scrollback, whatever command was running, editor buffers, and the
column layout — the columns are rebuilt from the order the windows arrive in.
A program that keeps one process for several windows (Firefox) is started once
and left to restore its own windows.

There is no session protocol on Wayland, so this is a snapshot and a relaunch,
and a login that relaunches a dozen programs says so in a notification.
`dotfiles-session-restore --off` stops it happening, `--on` again; the session
is still written either way.

## Day to day

```sh
./install-packages.sh      # packages + neovim (Arch, needs sudo)
./install.sh               # symlink configs; backs up anything it displaces

dotfiles-reload            # apply the dotfiles to the running session
                           # kitty: ctrl+shift+f5

./tests/run.sh             # Lua tests, then Hyprland --verify-config
./tests/sandbox.sh start   # a nested Hyprland, hidden, to try things in
```

`reload` (see `bin/reload`) runs the `hyprctl reload`, then restarts waybar and
re-reads hyprpaper's and hypridle's conf — both only at startup — and reloads
dunst. It runs detached, so it never holds the terminal, restarts a daemon only
if it is already running, refuses to act under `HYPR_SANDBOX=1`, and raises a
notification for a step that failed.
`hyprlock.conf` is picked up at the next lock, and a change to the `PATH`
exports in `environment.lua` needs a full session restart to be certain —
`dotfiles-reload` only re-exports them to processes started afterwards.

Both install scripts are safe to re-run and skip whatever is already done.

## Notes

- **`$HOME` stays clean.** Config goes in `~/.config`, state in
  `~/.local/state`, caches in `~/.cache`. zsh is the awkward one: it reads
  `$HOME/.zshenv` before it knows about `ZDOTDIR`, so a one-line stub has to
  stay there. Setting `ZDOTDIR` in `/etc/zsh/zshenv` instead would remove even
  that, but needs root.
- **Suspend is disabled deliberately**, by every route — see
  `system/90-no-suspend.conf` for why and how to undo it.
- **Rider is not installed by the script.** `jetbrains-toolbox` is, and Rider is
  installed from its GUI; Toolbox has no usable CLI.
- **Neovim** is managed by [bob](https://github.com/MordechaiHadad/bob) and
  pinned by `NVIM_VERSION` in `install-packages.sh`.
- **Work-machine-only software** (GlobalProtect, Teams, FreeIPA) is left out on
  purpose.
- **Adding a config** is one `link <path-in-repo> <absolute-destination>` line
  at the bottom of `install.sh`. Either side may be a file or a directory.
- **Backups** taken by `install.sh` go to
  `~/.local/state/dotfiles/backups/<timestamp>/<original path>`. Delete them all
  with `rm -rf ~/.local/state/dotfiles/backups`.
