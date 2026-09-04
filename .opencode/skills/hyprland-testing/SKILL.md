---
name: hyprland-testing
description: Use when verifying a change to hypr/*.lua, waybar, or bin/ scripts in this dotfiles repo, or whenever a nested Hyprland, hyprctl, pkill or killall is about to be run. The user is sitting in the live session that these commands can disturb.
---

# Testing without wrecking the live session

`~/.config/hypr` is a symlink into this repo and the user is working in the
compositor it configures. Every command here can reach that session.

## The two harnesses

```sh
./tests/run.sh              # Lua tests against a stubbed hl API, then
                            # Hyprland --verify-config. Safe at any time.

./tests/sandbox.sh start    # a nested Hyprland, hidden
./tests/sandbox.sh exec kitty
./tests/sandbox.sh hyprctl clients -j
./tests/sandbox.sh stop
```

`sandbox.sh` parks the nested compositor in the special workspace `sandbox`,
which sits outside the desktop model — `deskbinds.lua` filters special
workspaces out everywhere — so no key reaches it and nothing shows it. Always
use it rather than launching `Hyprland -c ...` by hand.

It never draws while hidden, because it gets no frame callbacks. That is fine:
read it with `sandbox.sh hyprctl` and with files the config writes out. Do not
expect to verify anything by looking at it.

## Rules that exist because they were broken

- **Never launch a nested compositor onto a visible desktop.** It becomes a
  tiled window and re-tiles everything the user has open. Eight of them once
  piled up on their screen at once.
- **Never `pkill -f` or `killall` on a pattern that matches system-wide.**
  `pkill -f 'kitty --class quake'` kills the user's own terminals, and a
  pattern matching the current command line kills the shell running it. Kill
  by pid, from `ps -eo pid,ppid,args` filtered to the sandbox's children.
- **`hyprctl` with no `-i` talks to the live session.** Instance *indexes* are
  worse than useless — `-i 1` is whichever instance happens to be second, not
  yours. `sandbox.sh hyprctl` targets by signature.
- **Read-only inspection of the live session is fine** (`hyprctl clients -j`,
  `workspaces -j`, log files). Dispatching to it is not, unless asked.

## A stub is not the compositor

`tests/run.sh` stubs `hl`, so it happily accepts calls the real API rejects.
Bugs that only a running instance has ever caught are listed at the bottom of
`tests/run.sh` — read it before trusting a green run. Add to that list when
you find another.

Both are worth running: the stub catches logic, `--verify-config` catches field
names and load-time crashes.

## Driving the sandbox

The nested config cannot be typed into. Give it a command file and poll it from
a self-re-arming oneshot timer (`type = "repeating"` never fires), then write
commands from the outside and read what it logs:

```lua
local poll
poll = function()
    local f = io.open("/tmp/sb/cmd", "r")
    if f then
        local cmd = (f:read("*a") or ""):gsub("%s+$", "")
        f:close()
        if cmd ~= "" then os.remove("/tmp/sb/cmd") --[[ act on cmd ]] end
    end
    hl.timer(poll, { timeout = 300, type = "oneshot" })
end
hl.on("hyprland.start", function() hl.timer(poll, { timeout = 500, type = "oneshot" }) end)
```

Sample on a timeline when checking for a flash or a race — `+2ms`, `+40ms`,
`+100ms` — since several of the bugs here were only visible for one frame.
