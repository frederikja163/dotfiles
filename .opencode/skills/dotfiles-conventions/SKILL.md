---
name: dotfiles-conventions
description: Use when adding or changing anything in this dotfiles repo - a new program's config, a script in bin/, a package, an install.sh link, README or code comments. Covers how configs reach the live system, where a new dependency must be declared, and the commenting style the repo is written in.
---

# How this repo is put together

`install.sh` symlinks each directory to where the program expects it, so
**editing a file here edits the running system**. `hypr/` in particular is
loaded by the compositor the user is sitting in.

## Adding a config

One line at the bottom of `install.sh`:

```sh
link ghostty "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
```

Either side may be a file or a directory. Destinations are spelled out in full
so they can go anywhere. `install.sh` backs up whatever it displaces and leaves
correct symlinks alone.

## Adding a dependency

Anything new goes in `packages/pacman.txt` or `packages/aur.txt`, with an
inline comment naming what needs it:

```
fzf                 # solution picker in bin/ide
```

Being installed on this machine is not the same as being declared. `fzf` was
present only as a dependency of `downgrade`, one `pacman -Rs` away from taking
`bin/ide` with it. Check with `pacman -Qi <pkg>` before relying on something.

## Scripts in bin/

`bin/` is symlinked to `~/.local/bin`. A script started from a **keybind** does
not get a shell profile: its `PATH` comes from `hypr/environment.lua`, and
anything it calls must be listed there. `nvim` (bob) and `rider` (JetBrains
Toolbox) both live outside the default `PATH` for this reason.

Keep failures visible. A GUI app launched detached with its output discarded
turns "command not found" into nothing happening at all — check the command
exists first and `notify-send`, since stderr from a keybind goes nowhere.

## Comments carry the reasoning

Headers explain **why**, including what was tried and rejected, so the next
reader does not repeat it. The README is deliberately only an index; the
explanation belongs next to the code. Match the existing voice — plain prose,
no bullet-point stubs, and a note whenever behaviour is deliberate rather than
accidental:

```lua
-- Nothing here closes a terminal when its desktop goes away, deliberately.
--
-- Tidying up on that signal was tried and is worse than the leak it fixes:
-- drop the terminal on an empty desktop, step away, come back, and it had
-- been killed underneath you.
```

Prefer fixing a cause over papering over a symptom, and say which you did.

## Tests

`hypr/columns.lua`, `hypr/deskbinds.lua` and `hypr/quake.lua` have tests in
`tests/`. Add cases when changing them — the stubbed `hl` API means a test can
model compositor behaviour (a workspace being created on focus, a special
workspace toggling) and catch a regression the real thing would only show
intermittently.

Run `./tests/run.sh` before saying a change works.
