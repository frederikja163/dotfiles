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
| `system`   | `/etc`                  | system config (needs root)        |
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

A desktop is a row of **columns**, each a vertical stack of windows.
`hypr/columns.lua` is a custom Lua layout (`hl.layout.register`), so it decides
where every window goes itself: `recalculate` divides the work area up and
places each window. There is no scrolling tape and nothing to correct
afterwards.

The columns **always fill the monitor exactly** — by construction rather than by
correction. Widths are fractions that add up to 1.0, `recalculate` divides
`ctx.area` by them, and Hyprland's `place` inserts the gaps. Nothing can leave
dead space or run off the edge.

**Modifiers mean one thing each:** `SHIFT` moves · `CTRL` changes geometry ·
`ALT` scopes up from the window to its whole column.

| Bind | Action |
| --- | --- |
| `SUPER + H/J/K/L` | focus, wrapping inside the desktop |
| `SUPER + SHIFT + H/L` | move the window into the neighbouring column |
| `SUPER + SHIFT + J/K` | move the window up/down inside its column |
| `SUPER + CTRL + H/J/K/L` | resize the window (sideways is its column) |
| `SUPER + ALT + SHIFT + H/L` | move the whole column |
| `SUPER + M` | cycle windows through the widest column |

Apps open where the desktop is — the directory of its quake terminal.

| Bind | Action |
| --- | --- |
| ``SUPER + ` `` | drop the desktop's quake terminal down, or put it away |
| `SUPER + Q` | a terminal in the same directory, with its own history |
| `SUPER + I` | `bin/ide`: Rider if there is a solution there, else nvim |

Numbers address screens, with one rule: **act on screen *n*, or on your own
desktops if you are already there.**

| Bind | another screen | your own screen |
| --- | --- | --- |
| `SUPER + <n>` | go there | next desktop |
| `SUPER + SHIFT + <n>` | move window there | move window to next desktop |
| `SUPER + ALT + SHIFT + <n>` | move column there | move column to next desktop |
| `SUPER + CTRL + <n>` | duplicate onto it | new desktop |
| `SUPER + CTRL + SHIFT + <n>` | move this whole desktop there | — |

Apps and window state: `Q` terminal · `R` launcher · `E` files · `C` close ·
`V` float · `Escape` power menu · `/` this list.

Arrow keys mirror `HJKL` everywhere, but are bound without descriptions so they
do not double every entry in the cheatsheet.

- On a desktop with a **single column**, a new window starts a **second
  column** — one column means the desktop is not really split up yet. Once
  there are two or more, the split is deliberate and new windows join the
  **focused column**, at the bottom. To split one out again, move it past the
  last column with `SUPER + SHIFT + H/L`, which gives it a column of its own.
- Splitting halves the column it came from, unless all columns were equal, in
  which case they are evened out again. Either way the total is unchanged.
- Resizing takes the difference from the other columns in proportion, so
  deliberately uneven columns stay uneven.
- Focus never steps onto another monitor, so the binds do not depend on how the
  monitors are arranged — use the number keys for that.
- Swapping a column carries its width along, so a narrow column stays narrow
  when moved to the other side.

Windows are tracked by `stable_id`, which survives being moved about, and the
state lives in memory only: after a config reload the windows of a desktop
collapse into one column.

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

Desktops remember which screen they belong to. Unplugging a screen makes
Hyprland pile its desktops onto whatever is left, and plugging it back in does
not send them home, so `deskbinds.lua` does it: on `monitor.added` every desktop
returns to the screen it came from.

Screens are recognised by their **description**, not their connector name —
`DP-4` came back as `DP-5` after a redock, so a name is worthless for
recognising the same panel. Descriptions are stable and include the serial
(`Dell Inc. DELL P3424WE DVYH6T3`). Moving a desktop by hand with
`SUPER + CTRL + SHIFT + <n>` also updates where it belongs, so it stays put
across replugs.

A monitor that is duplicating another **disappears from `hl.get_monitors()`**,
and `hl.get_monitor(name)` returns nil for it, so Hyprland cannot be asked about
it at all. `deskbinds.lua` therefore remembers which monitors it has set to
duplicate: without that, the monitor's number would stop responding and the
duplicate could never be switched off. Remembered monitors are spliced back into
the numbering by id, so the other monitors keep their numbers. (`hyprctl
monitors all` does list them, but calling `hyprctl` from inside the config
deadlocks — the compositor is busy running the Lua.)

Toggling duplication also restarts waybar via `bin/waybar-main`, since
duplicating can change which monitor is the largest, and the workspace buttons
are keyed by desktop name, which is renumbered when a monitor comes or goes.

Desktops are **named after what you are doing on them**, not numbered: the
directory the desktop's quake terminal is sitting in, so the bar reads
`dotfiles` rather than `2`. A terminal that has not been taken anywhere is `~`,
and so is a desktop with no terminal at all.

`quake.lua` finds the directory and `deskbinds.lua` owns the naming, joined by a
hook so the dependency only runs one way. Waybar needs no say in it: when its
`format-icons` has no entry for a workspace it falls back to showing the
workspace's own name (`workspace.cpp`, `selectIcon`), which is exactly what is
wanted.

A desktop is **born with its name**. Creating one means focusing a workspace
that does not exist yet, and Hyprland calls it whatever it was asked for — ask
for an id and the bar shows `7` until something renames it. Asking by name
instead means there is nothing to correct and no number ever flashes up. The
catch is that `name:` goes to an existing workspace of that name rather than
making a second one, so the name has to be known-unique before it is asked for.

Names must be unique for waybar's sake too. It marks a button active when its
name equals the *globally* focused workspace's name, with no monitor check
(`workspaces.cpp`, `isActiveByName`), so two desktops sharing a name highlight
at once; it resolves a workspace's monitor by name as well, which misattributes
the `hosting-monitor` class. Two desktops open on the same directory therefore
read `dotfiles` and `dotfiles 1.2`, falling back to the `<monitor>.<desktop>`
coordinate that every desktop used to carry.

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
| `columns.lua`     | the column layout itself, and its binds              |
| `autostart.lua`   | processes launched with the session                  |

`programs.lua` is the only module that returns a value; `keybinds.lua` requires
it so the terminal and launcher are named in one place.

## Desktop notes

Waybar runs **on every monitor**: the full bar on the main one, where "main" is
just the largest by pixel area, and a bar carrying nothing but the workspaces on
each of the others. `waybar/config.jsonc` deliberately has no `output` key, so
it names no monitors and works unchanged on any machine; `bin/waybar-main` works
out which monitor is which and starts waybar against a generated copy holding
both bars with their `output` filled in. waybar has no command line option for
this — only `-b` to pick a bar by name — hence the generated copy.

The short bar is derived from the same config rather than written out again, so
the modules are described once. The workspace module is left at its default of
showing only the workspaces of the output it is on, which is what lets one
description serve every monitor.

Connector names are not stable (`DP-4` became `DP-5` after a redock), which is
why nothing keys off them. If the monitor cannot be determined, the bar appears
on every monitor rather than not at all.

`hypr/autostart.lua` starts it, and restarts it on `monitor.added`/`removed`, so
the bar follows the main monitor across docking and undocking.

hyprpaper is autostarted too. dunst is dbus-activated and needs no entry.

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
hyprctl reload              # hyprland (PATH changes included: env is re-applied)
waybar-main                 # waybar (restarts the bars on every monitor)
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

## Suspend

**Disabled, deliberately.** This machine only supports s2idle (`cat
/sys/power/mem_sleep` offers no `deep`), and resuming from it left the laptop's
own panel permanently black. Hibernate is not an option either: a 512M swapfile
against 30G of RAM.

Every route in is closed:

| Route | Behaviour |
| --- | --- |
| lid close | locks the session (`system/90-no-suspend.conf`) |
| sleep key | ignored |
| idle | `hypr/hypridle.conf` dims, locks and blanks, never suspends |
| power menu | has no Suspend entry |

The power button still powers off, which is what a long press should do.

To undo this: delete `/etc/systemd/logind.conf.d/90-no-suspend.conf`, restart
`systemd-logind`, and add a `Suspend` entry back to `bin/power-menu`. Worth
knowing first that waking only worked from the built-in keyboard or the lid --
a keyboard behind the Dell dock could not do it, because the dock's USB hubs
have `wakeup=disabled` and the wake signal never travels up.

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

`HYPR_SANDBOX=1` skips autostart, since `hypridle` and a second waybar would
act on the *host* session. The modifier stays SUPER: the host grabs those
combinations so the binds are not pressable by hand, but nested testing goes
through `hyprctl dispatch`, and swapping the modifier to ALT used to collapse
`SUPER+ALT+SHIFT` onto `ALT+SHIFT` and hide real collisions.

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
