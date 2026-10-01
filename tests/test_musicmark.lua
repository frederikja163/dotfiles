-- Standalone harness for musicmark.lua: stubs the hl API, deskbinds and quake,
-- then asks the registered decorator what each desktop is called.
--
-- deskbinds and quake are stubbed rather than loaded, because what is tested
-- here is the marker's own rules -- which desktop, and for how long. How a name
-- is composed around it has cases in tests/test_deskbinds.lua against the same
-- set_decorator hook, and quake's own workspace naming has tests/test_quake.lua.
--
-- THE QUAKE SCENARIOS ARE THE POINT OF THIS FILE. The first version of
-- musicmark.lua refused every special workspace, which silently disabled the
-- whole feature: the drop-down terminal is where commands actually get typed,
-- and it lives in "special:quake-<desktop>". Every test here passed anyway,
-- because they all used ordinary windows -- and so did the sandbox run. A case
-- that types `music` into a quake terminal is the one that would have caught
-- it, so there is one now.
--
-- owner_alive() is left completely unstubbed. It reads /proc, so the test uses
-- real pids: 1 is always alive, and a pid above the kernel's maximum can never
-- be. That exercises the actual code path, and the alternative -- stubbing
-- io.open -- would test the stub.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

-- Above /proc/sys/kernel/pid_max on any configuration, so /proc/<this> cannot
-- exist and owner_alive() must say no.
local DEAD_PID = 99999999
local LIVE_PID = 1

local world, decorator, renumbers, mod

local function reset(w)
    world = w or { windows = {}, active = nil }
    decorator, renumbers = nil, 0

    _G.hl = {
        get_workspace_windows = function(id) return world.windows[id] or {} end,
        get_active_window = function() return world.active end,
    }

    package.loaded.deskbinds = {
        set_decorator = function(fn) decorator = fn end,
        schedule_renumber = function() renumbers = renumbers + 1 end,
    }

    -- The real one, in one line: a window in "special:quake-<id>" belongs to
    -- desktop <id>, and anything else belongs to no desktop through this route.
    package.loaded.quake = {
        desktop_of = function(win)
            local name = win and win.workspace and win.workspace.name
            local id = name and tostring(name):match("^special:quake%-(%-?%d+)$")
            return id and tonumber(id)
        end,
    }

    package.loaded.musicmark = nil
    mod = require("musicmark")
end

-- A desktop holding windows at the given addresses.
local function desktop(id, ...)
    world.windows[id] = {}
    for _, address in ipairs({ ... }) do
        table.insert(world.windows[id], { address = address })
    end
end

-- A focused ordinary window on a desktop.
local function focus_window(addr, id)
    world.active = { address = addr, workspace = { id = id, name = tostring(id) } }
end

-- A focused quake terminal, which sits in its own special workspace. Its
-- workspace id is the *terminal's* and is deliberately nothing like the
-- desktop's: that mismatch is what the old code tripped over.
local function focus_quake(addr, desktop_id)
    world.active = {
        address = addr,
        workspace = { id = -96, name = "special:quake-" .. desktop_id, special = true },
    }
end

-- What the bar would show for this desktop, given a label already decided.
local function name(id, label)
    return decorator({ id = id }, label)
end

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-56s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-56s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

local MARK = "🎵"

print("scenario: `music` typed into a quake terminal marks its desktop")
-- The case the whole feature exists for, and the one the first version got
-- wrong. The terminal is in special:quake-3, so desktop 3 is what gets marked
-- even though no window of desktop 3 is involved at all.
reset()
focus_quake("0xq3", 3)
check("set_here answers with the desktop, not the workspace", mod.set_here(LIVE_PID), 3)
check("it asked for a renumber", renumbers, 1)
check("desktop 3 is marked", name(3, "Music"), "Music " .. MARK)
check("the terminal's own workspace id is not", name(-96, "quake"), "quake")
check("and no other desktop is", name(4, "dotfiles"), "dotfiles")

print("scenario: a quake mark needs no window on the desktop it marks")
-- Deliberately empty: a quake terminal is never on the desktop it belongs to,
-- so a rule that looked for one there would find nothing. This is the
-- assertion that pins the two modes apart.
check("desktop 3 holds no windows at all", #(world.windows[3] or {}), 0)
check("marked regardless", name(3, nil), MARK)

print("scenario: a quake terminal for a negative desktop id")
-- Hyprland numbers named workspaces downwards, so quake.lua's own comment
-- warns "quake--1337" is an ordinary name. The pattern allows the sign.
reset()
focus_quake("0xq", -1337)
check("resolved", mod.set_here(LIVE_PID), -1337)
check("and marked", name(-1337, "odd"), "odd " .. MARK)

print("scenario: an ordinary window marks whichever desktop holds it")
reset()
desktop(3, "0xaaa")
desktop(4, "0xbbb")
focus_window("0xaaa", 3)
check("set_here answers with the desktop id", mod.set_here(LIVE_PID), 3)
check("that desktop is marked", name(3, "music"), "music " .. MARK)
check("another desktop is not", name(4, "dotfiles"), "dotfiles")

print("scenario: an unnamed desktop takes the mark as its whole label")
-- deskbinds turns a label into "<number> <label>", so returning just the mark
-- is what produces "1 <note>" instead of "1.1 <note>".
check("nil label", name(3, nil), MARK)
check("empty label", name(3, ""), MARK)

print("scenario: an ordinary window's mark follows it to another desktop")
-- Nothing is re-registered: the window simply reports from somewhere else, the
-- way it does after SUPER+M, and deskbinds renames on that event already.
world.windows[3] = {}
desktop(9, "0xaaa")
check("the old desktop is no longer marked", name(3, "music"), "music")
check("the new one is", name(9, "music"), "music " .. MARK)

print("scenario: a quake mark stays put, because the terminal cannot move")
-- quake.lua binds one terminal per desktop by workspace name, so there is no
-- move to follow. The id is the identity, so shuffling the desktop along its
-- row or sending it to another screen keeps the note -- the name is rebuilt
-- from the id on every pass.
reset()
focus_quake("0xq5", 5)
mod.set_here(LIVE_PID)
desktop(5, "0xsomethingelse")
check("still marked after the desktop gains a window", name(5, "x"), "x " .. MARK)
world.windows[5] = {}
check("and after it loses it again", name(5, "x"), "x " .. MARK)

print("scenario: the mark dies with the bin/music that set it")
-- A SIGKILL leaves no chance to clear the mark, so it is only believed while
-- its owner is alive. Without this a killed player leaves a note up forever.
reset()
focus_quake("0xq3", 3)
check("registered against a dead pid", mod.set_here(DEAD_PID), 3)
check("the mark is not shown", name(3, "music"), "music")
-- And having noticed, it forgets: the next pass must not keep re-checking a
-- pid that will never come back.
check("the registration is dropped too", name(3, "music"), "music")

print("scenario: clear() takes the mark off")
reset()
focus_quake("0xq3", 3)
mod.set_here(LIVE_PID)
check("marked to begin with", name(3, "music"), "music " .. MARK)
check("clear reports having done something", mod.clear(), true)
check("the mark is gone", name(3, "music"), "music")
check("and it renumbered twice in total", renumbers, 2)
check("clearing again is a no-op", mod.clear(), false)
check("which asks for no further renumber", renumbers, 2)

print("scenario: there is nothing to mark without a window in front")
-- A nested Hyprland in tests/sandbox.sh is in this state unless it has been
-- given a headless output, so `music` run inside one marks nothing.
reset({ windows = {}, active = nil })
check("no active window", mod.set_here(LIVE_PID), nil)
check("nothing marked", name(1, "music"), "music")
check("and no renumber asked for", renumbers, 0)

reset({ windows = {}, active = { workspace = { id = 3 } } })
check("an active window with no address", mod.set_here(LIVE_PID), nil)

print("scenario: a special workspace that is not a quake terminal is refused")
-- A window on its way out of a special workspace, or any other scratchpad:
-- there is no desktop to name, and quake.desktop_of says so.
reset()
world.active = {
    address = "0xaaa",
    workspace = { id = -40, name = "special:magic", special = true },
}
check("refused", mod.set_here(LIVE_PID), nil)
check("and no renumber asked for", renumbers, 0)

print("scenario: a mark needs an owner to vouch for it")
-- Called without a pid, there would be nothing to watch and the note could
-- never be taken off except by hand.
reset()
focus_quake("0xq3", 3)
check("no pid is refused outright", mod.set_here(nil), nil)
check("nothing marked", name(3, "music"), "music")
check("no renumber asked for", renumbers, 0)

print("scenario: registering again moves the mark, across both modes")
reset()
desktop(5, "0xccc")
focus_quake("0xq3", 3)
mod.set_here(LIVE_PID)
check("quake desktop marked", name(3, "x"), "x " .. MARK)
focus_window("0xccc", 5)
check("re-registering on an ordinary window answers with it", mod.set_here(LIVE_PID), 5)
check("the quake desktop is released", name(3, "x"), "x")
check("and the window's desktop is marked", name(5, "x"), "x " .. MARK)
-- Back the other way, which is the transition that would catch a stale
-- `address` being left set alongside a new `desktop`.
focus_quake("0xq3", 3)
mod.set_here(LIVE_PID)
check("and back to quake", name(3, "x"), "x " .. MARK)
check("releasing the window's desktop", name(5, "x"), "x")

print("scenario: a desktop with no id is never marked")
-- deskbinds asks the hook about a desktop it has not created yet, passing an
-- empty table; a desktop with no id has no windows to be playing anything.
reset()
focus_quake("0xq3", 3)
mod.set_here(LIVE_PID)
check("an idless workspace keeps its label", decorator({}, "music"), "music")

print("scenario: nothing is marked before anything is registered")
reset()
desktop(1, "0xaaa")
check("a decorator was registered on load", type(decorator), "function")
check("but marks nothing", name(1, "music"), "music")
check("and asked for no renumber on load", renumbers, 0)

print()
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
