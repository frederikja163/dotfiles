---
name: hyprland-lua-config
description: Use when editing hypr/*.lua in this dotfiles repo - the Hyprland Lua config (hl.bind, hl.dsp, hl.on, hl.timer, hl.window_rule, hl.layout.register), keybinds, workspaces, window rules, or anything the compositor launches. Records API behaviour that is silent, undocumented, or actively misleading, and how to check the API rather than guess.
---

# Hyprland's Lua config

`hypr/hyprland.lua` is an entry point that requires one module per concern.
Hyprland puts the config directory on `package.path`, so `require("look")`
finds `hypr/look.lua`. The global `hl` is the whole API.

## Check, do not guess

The API is compiled in and barely documented. Dump it instead of guessing —
this runs the config without touching the running session:

```lua
-- /tmp/probe/hyprland.lua
local out = assert(io.open("/tmp/probe/api.txt", "w"))
local function dump(t, prefix, depth)
    if depth > 4 then return end
    for k, v in pairs(t) do
        out:write(("%s%s = %s\n"):format(prefix, k, type(v)))
        if type(v) == "table" then dump(v, prefix .. k .. ".", depth + 1) end
    end
end
dump(hl, "hl.", 1)
out:close()
```

```sh
Hyprland --verify-config -c /tmp/probe/hyprland.lua
```

The same command validates field names: invalid ones are reported as
`unknown field 'x'` under `======== Config parsing result:`. Note that `pcall`
does **not** catch these — validation errors are collected and printed at the
end, so a wrapped call reports success while the config is still rejected.

For behaviour rather than shape, use `tests/sandbox.sh` (see the
hyprland-testing skill).

## Things that fail silently

These cost hours each. All verified against Hyprland 0.56.2.

- **Timers are oneshot only.** `hl.timer(fn, { timeout = 300, type = "repeating" })`
  never fires, with no error. To poll, re-arm from inside the callback.
- **`hl.monitor()`'s `position` takes a `"WxH"`-formatted string** (`"640x480"`),
  not the legacy `x@y` token — `"640@480"` fails the field with
  `error applying field 'position'`. Positions are logical pixels (a screen's
  pixels divided by its scale); a rotated (transform 1/3) screen's dimensions
  swap. The `hl.get_monitors()` monitor object exposes `width`, `height`,
  `scale`, `x`, `y` and `id` but no `wl`/`px_w` logical-size fields, and is
  empty at module load (see monitors.lua's tests for what the layout is built
  from).
- **`hl.dsp.workspace.toggle_special` takes a bare positional name**:
  `toggle_special("quake-1")`, no `special:` prefix. Passing a table —
  `{ workspace = ... }` or `{ name = ... }` — is accepted and ignored, and
  toggles Hyprland's default `special:special` instead.
- **Percentages in `size` window rules are ignored.** `size = "100% 40%"`
  leaves the window at its default size. Expressions work:
  `size = "monitor_w monitor_h*0.4"`, same syntax as `move`.
- **Named workspaces get negative ids.** Creating one with
  `focus({ workspace = "name:foo" })` gives it an id counting down from
  `-1337`, and those sort ahead of every ordinary desktop, silently
  reordering them. `name:` also *goes to* an existing workspace of that name
  rather than creating a second. Prefer creating by id and renaming.
- **A `size` window rule applies once, at creation.** A floating window keeps
  its pixels when it moves to another monitor, so anything meant to match the
  screen has to be re-applied when it gets there. Geometry dispatchers both
  take `{x =, y =}` — `window.resize{ window = "address:…", x = w, y = h }`
  sets an exact size and keeps the window centred, so `window.move{ window =
  …, x =, y = }` has to follow it. Both are in layout coordinates: the
  monitor's own pixels divided by its `scale`.
- **`hl.dsp.workspace.change_id` does not renumber a workspace.** It creates a
  new one under the target id and moves the windows across, leaving the
  original behind (empty, and still there if it was persistent). Anything
  keyed by the old id is orphaned -- in this repo a desktop's quake terminal
  lives in `special:quake-<desktop id>` and stays in the old one, where nothing
  will find it again. If a desktop needs to move within an ordering, reorder
  around it rather than renumbering it.
- **`hl.dsp.workspace.move` only moves the workspace you name if it is the
  active one.** Naming any other workspace reports `ok` and does nothing.
- **`hl.exec_cmd` does not run a shell.** Hyprland splits the arguments
  itself, quotes included, so `cmd 'a b'` arrives as one argument `a b` — but
  `>`, `&&` and `|` are not interpreted.

## Creating a timer during config load segfaults

`config.reloaded` and `hyprland.start` fire while the config is loading.
Creating an `hl.timer` there takes the whole compositor down —
`Hyprland --verify-config` dumps core — and a segfault cannot be caught with
`pcall`. Handlers for those two events must do their work directly.

Everything else (binds, other events) runs at runtime, where timers are fine.

## Window rules

Valid fields include `float`, `size`, `move`, `border_size`, `rounding`,
`no_shadow`, `no_blur`, `no_anim`, `opaque`, `pin`, `workspace`,
`focus_on_activate`, `suppress_event`, `no_focus`. `no_border` and `shadow`
are **not** fields and fail validation; use `border_size = 0` and
`no_shadow = true`.

Border and shadow are drawn **outside** the window box, so a window as wide as
its monitor spills onto the monitor next door.

## Events that exist and carry an argument

`window.open`, `window.close`, `window.title` (each passed the window, with
`class`, `title`, `pid`, `address`, `workspace`), `workspace.created`,
`workspace.removed`, `workspace.active`, `workspace.move_to_monitor`,
`monitor.added`, `monitor.removed`, `monitor.focused`, `config.reloaded`,
`hyprland.start`.

A freshly created workspace is **not in `hl.get_workspaces()`** when
`workspace.created` fires; it appears a few milliseconds later.

## Layouts

A layout's `layout_msg` returns `true` for "handled" and a **string to report
an error to the user**. Ordinary situations — an empty desktop, no focused
window — must return `true`, not an explanation.

## Programs the compositor starts

A program launched from a keybind does not get a shell profile, and two of its
inherited properties lie:

- **`PATH` comes from `hypr/environment.lua`**, not `.zshrc`. Anything a bind
  reaches for must be listed there.
- **It inherits the session's VT.** `stdin` is `/dev/tty2` and `/dev/tty`
  opens happily, so `[ -t 0 ]` and a `/dev/tty` probe both claim there is a
  terminal — and a TUI started on that assumption draws on a console nobody is
  looking at. **`stdout` is the honest signal**; require both ends.

## Talking to a Lua-configured Hyprland

`hyprctl dispatch` takes Lua, not the old string form:

```sh
hyprctl dispatch 'hl.dsp.exec_cmd("kitty")'
```
