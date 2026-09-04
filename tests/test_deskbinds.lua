-- Standalone harness for deskbinds.lua: stubs the hl API, then drives the
-- registered bind callbacks and asserts what they dispatch.

-- Resolve the hyprland modules from this repo, overridable for testing a copy.
local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local binds, dispatched, monitor_calls, world, events, renames, execs, moves, mod

local function reset(w)
    world = w
    binds, dispatched, monitor_calls, events, renames, execs, moves =
        {}, {}, {}, {}, {}, {}, {}

    _G.hl = {
        -- deskbinds requires columns, which registers the layout on load.
        layout = { register = function() end },
        bind = function(keys, fn, opts) binds[keys] = { fn = fn, opts = opts } end,
        on = function(event, fn) events[event] = fn end,
        timer = function(cb, opts) cb() end, -- fire immediately in tests
        exec_cmd = function(cmd) table.insert(execs, cmd) end,
        dispatch = function(d) table.insert(dispatched, d) end,
        monitor = function(spec)
            table.insert(monitor_calls, spec)
            -- Mimic Hyprland: setting mirror hides the monitor, clearing it
            -- brings it back.
            for _, m in ipairs(world.monitors) do
                if m.name == spec.output then
                    m.mirroring = (spec.mirror ~= nil and spec.mirror ~= "") and spec.mirror or nil
                end
            end
        end,
        get_monitors = function()
            -- Hyprland drops a mirroring monitor from this list entirely.
            local out = {}
            for _, m in ipairs(world.monitors) do
                if not m.mirroring then table.insert(out, m) end
            end
            return out
        end,
        get_workspaces = function() return world.workspaces end,
        get_active_monitor = function()
            for _, m in ipairs(world.monitors) do
                if m.id == world.focused_monitor_id then return m end
            end
        end,
        dsp = {
            layout = function(m) return { kind = "layout", arg = m } end,
            no_op = function() return { kind = "no_op" } end,
            focus = function(a)
                -- Focusing an id that does not exist creates that desktop, on
                -- the focused monitor, exactly as Hyprland does.
                if type(a.workspace) == "number" then
                    local exists = false
                    for _, ws in ipairs(world.workspaces) do
                        if ws.id == a.workspace then exists = true end
                    end
                    if not exists then
                        local mon
                        for _, m in ipairs(world.monitors) do
                            if m.id == world.focused_monitor_id then mon = m end
                        end
                        table.insert(world.workspaces,
                            { id = a.workspace, special = false, monitor = mon })
                    end
                end
                return { kind = "focus", arg = a }
            end,
            window = {
                move = function(a) return { kind = "move", arg = a } end,
                swap = function(a) return { kind = "swap", arg = a } end,
            },
            workspace = {
                rename = function(a)
                    table.insert(renames, a)
                    return { kind = "rename", arg = a }
                end,
                move = function(a)
                    table.insert(moves, a)
                    return { kind = "wsmove", arg = a }
                end,
            },
        },
    }

    package.loaded.deskbinds = nil
    package.loaded.programs = nil
    package.loaded.columns = nil
    mod = require("deskbinds")
end

-- Build a world: two monitors; mon0 shows ws1, mon1 shows ws3.
local function two_monitors(focused)
    local mon0 = { id = 0, name = "eDP-1", description = "BOE 0x0DBB", is_mirror = false }
    local mon1 = { id = 1, name = "DP-4",  description = "Dell DELL P3424WE DVYH6T3", is_mirror = false }
    local ws1  = { id = 1, special = false, monitor = mon0 }
    local ws2  = { id = 2, special = false, monitor = mon0 }
    local ws3  = { id = 3, special = false, monitor = mon1 }
    local wsS  = { id = -99, special = true, monitor = mon0 }
    mon0.active_workspace = ws1
    mon1.active_workspace = ws3
    return {
        monitors = { mon0, mon1 },
        workspaces = { ws1, ws2, ws3, wsS },
        focused_monitor_id = focused,
    }
end

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-52s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-52s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

local function last()
    return dispatched[#dispatched]
end

-- Last dispatch of a given kind. Needed because creating a desktop is followed
-- by rename dispatches from the renumbering pass.
local function last_of(kind)
    for i = #dispatched, 1, -1 do
        if dispatched[i].kind == kind then
            return dispatched[i]
        end
    end
end

-- Only the number keys belong to deskbinds; columns.lua is loaded alongside it
-- and registers its own.
local function bind_count()
    local n = 0
    for keys in pairs(binds) do
        if keys:match("%d$") then n = n + 1 end
    end
    return n
end

print("scenario: monitor 1 (eDP-1) focused")
reset(two_monitors(0))
-- plain, SHIFT, CTRL, CTRL+SHIFT, ALT+SHIFT on each of 10 keys
check("bind count (10 keys x 5 modifier combinations)", bind_count(), 50)

binds["SUPER + 1"].fn()
check("M+1 on focused mon -> next desktop id", last().arg.workspace, 2)

binds["SUPER + 2"].fn()
check("M+2 on other mon -> focus its workspace", last().arg.workspace, 3)

binds["SUPER + SHIFT + 1"].fn()
check("M+S+1 focused -> move to next desktop", last().arg.workspace, 2)
check("M+S+1 uses move dispatcher", last().kind, "move")

binds["SUPER + SHIFT + 2"].fn()
check("M+S+2 other -> move to that monitor's ws", last().arg.workspace, 3)

binds["SUPER + CTRL + 1"].fn()
check("M+C+1 focused -> new desktop, lowest free id", last_of("focus").arg.workspace, 4)

binds["SUPER + CTRL + 2"].fn()
check("M+C+2 other -> mirror issued", #monitor_calls, 1)
check("M+C+2 mirror target output", monitor_calls[1].output, "DP-4")
check("M+C+2 mirrors the focused monitor", monitor_calls[1].mirror, "eDP-1")

print("scenario: wrap-around, mon0 focused on its LAST desktop (ws2)")
local w = two_monitors(0)
w.monitors[1].active_workspace = w.workspaces[2] -- ws2, the highest on mon0
reset(w)
binds["SUPER + 1"].fn()
check("M+1 wraps back to first desktop", last().arg.workspace, 1)

print("scenario: monitor 2 (DP-4) focused, and it has only ONE desktop")
reset(two_monitors(1))
binds["SUPER + 2"].fn()
check("M+2 with 1 desktop -> creates a second one", last_of("focus").arg.workspace, 4)
check("...and it is a focus dispatch", last_of("focus").kind, "focus")
binds["SUPER + 1"].fn()
check("M+1 on other mon -> focus eDP-1 workspace", last().arg.workspace, 1)
binds["SUPER + CTRL + 1"].fn()
check("M+C+1 other -> mirror eDP-1 onto DP-4", monitor_calls[1].mirror, "DP-4")

print("scenario: monitor with 2 desktops still cycles, does not create")
local t = two_monitors(0) -- mon0 has ws1 + ws2
reset(t)
local before_ids = {}
binds["SUPER + 1"].fn()
check("M+1 with 2 desktops -> cycles to existing ws2", last().arg.workspace, 2)

print("scenario: creating a second desktop picks the lowest free id")
local q = two_monitors(1)
-- ids 1,2,3,5 exist but 5 sits on mon0, so mon1 still has a single desktop
-- and the lowest free id is 4
table.insert(q.workspaces, { id = 5, special = false, monitor = q.monitors[1] })
reset(q)
binds["SUPER + 2"].fn()
check("skips occupied ids, picks 4", last_of("focus").arg.workspace, 4)

print("scenario: duplicate then un-duplicate with the same key")
local m = two_monitors(0)
reset(m)
binds["SUPER + CTRL + 2"].fn()
check("first press duplicates onto the focused monitor", monitor_calls[1].mirror, "eDP-1")
check("target is the other monitor", monitor_calls[1].output, "DP-4")

-- Hyprland now hides DP-4 from get_monitors(); the slot must survive anyway.
local slots = mod.monitor_slots()
check("slot 2 still exists while duplicating", slots[2] and slots[2].name, "DP-4")
check("and is flagged as duplicating", slots[2] and slots[2].source, "eDP-1")
check("get_monitors no longer reports it", #hl.get_monitors(), 1)

binds["SUPER + CTRL + 2"].fn()
check("second press clears the mirror", monitor_calls[2].mirror, "")
check("waybar refreshed on both toggles", #execs, 2)
check("by restarting it on the main monitor", execs[1], "waybar-main")
check("position restored to auto", monitor_calls[2].position, "auto")
check("monitor is live again", #hl.get_monitors(), 2)
check("slot no longer flagged", mod.monitor_slots()[2].source, nil)

print("scenario: numbering does not shift when a monitor duplicates")
local three = two_monitors(0)
local mon3 = { id = 2, name = "HDMI-1", active_workspace = nil }
local ws9 = { id = 9, special = false, monitor = mon3, name = "9" }
mon3.active_workspace = ws9
table.insert(three.monitors, mon3)
table.insert(three.workspaces, ws9)
reset(three)
binds["SUPER + CTRL + 2"].fn() -- duplicate the middle monitor
local s2 = mod.monitor_slots()
check("slot 1 unchanged", s2[1].name, "eDP-1")
check("slot 2 is still the duplicating monitor", s2[2].name, "DP-4")
check("slot 3 did NOT move up", s2[3].name, "HDMI-1")

print("scenario: plain M+n on a duplicating monitor does nothing")
local before = #dispatched
binds["SUPER + 2"].fn()
check("no dispatch", #dispatched, before)

print("scenario: single monitor, pressing an absent monitor number")
local s = two_monitors(0)
s.monitors = { s.monitors[1] }
reset(s)
local before = #dispatched
binds["SUPER + 5"].fn()
check("M+5 with no monitor 5 -> no dispatch", #dispatched, before)

print("scenario: per-monitor desktop numbering")
-- mon0 owns ids 1 and 2; mon1 owns ids 3 and 5.
-- Names must be "<monitor>.<desktop>" and globally unique, because waybar
-- highlights every button whose name matches the focused workspace's name.
local r = two_monitors(0)
local mon1 = r.monitors[2]
table.insert(r.workspaces, { id = 5, special = false, monitor = mon1, name = "5" })
for _, w in ipairs(r.workspaces) do w.name = w.name or tostring(w.id) end
reset(r)
mod.renumber_desktops()

local named = {}
for _, ren in ipairs(renames) do named[ren.workspace] = ren.name end

check("mon1 desktop1 (id 1) -> 1.1", named[1], "1.1")
check("mon1 desktop2 (id 2) -> 1.2", named[2], "1.2")
check("mon2 desktop1 (id 3) -> 2.1", named[3], "2.1")
check("mon2 desktop2 (id 5) -> 2.2", named[5], "2.2")
check("all four renamed", #renames, 4)

-- The whole point: no two desktops may share a name.
local seen, dupes = {}, 0
for _, name in pairs(named) do
    if seen[name] then dupes = dupes + 1 end
    seen[name] = true
end
check("no duplicate names across monitors", dupes, 0)

print("scenario: names already correct are left alone")
local r2 = two_monitors(0)
r2.workspaces[1].name = "1.1"
r2.workspaces[2].name = "1.2"
r2.workspaces[3].name = "2.1"
r2.workspaces[4].name = "special"
reset(r2)
mod.renumber_desktops()
check("no redundant renames", #renames, 0)

print("scenario: renumber is wired to workspace events")
check("workspace.created hooked", type(events["workspace.created"]), "function")
check("workspace.active hooked", type(events["workspace.active"]), "function")
check("workspace.removed hooked", type(events["workspace.removed"]), "function")
check("monitor.added hooked", type(events["monitor.added"]), "function")

print("scenario: a screen is recognised by description, not connector name")
local r = two_monitors(0)
reset(r)
check("description wins", mod.identity(r.monitors[2]), "Dell DELL P3424WE DVYH6T3")
check("falls back to the name when there is no description",
      mod.identity({ name = "HEADLESS-1", description = "" }), "HEADLESS-1")

print("scenario: desktops go home after a replug, even under a new connector")
local w = two_monitors(0)
reset(w)
mod.renumber_desktops()          -- records where each desktop belongs

-- Unplug: Hyprland shoves DP-4's desktop onto the laptop screen.
local mon0, mon1 = w.monitors[1], w.monitors[2]
w.workspaces[3].monitor = mon0
w.monitors = { mon0 }
mod.restore_homes()
check("nothing moves while that screen is unplugged", #moves, 0)

-- Replug: the same panel comes back on a different connector.
mon1.name = "DP-7"
w.monitors = { mon0, mon1 }
moves = {}
mod.restore_homes()
check("the desktop is sent home", #moves, 1)
check("...to the right workspace", moves[1] and moves[1].workspace, 3)
check("...addressed by its new connector name", moves[1] and moves[1].monitor, "DP-7")

print("scenario: desktops already in the right place are left alone")
local q = two_monitors(0)
reset(q)
mod.renumber_desktops()
moves = {}
mod.restore_homes()
check("no moves", #moves, 0)

-- quake.lua names a desktop after the directory its terminal is sitting in.
-- Waybar shows the workspace name whenever its format-icons has no entry, so
-- the label only has to end up in the name.
print("scenario: desktops that have something to call themselves")
reset(two_monitors(0))
mod.set_labeller(function(ws)
    return ({ [1] = "dotfiles", [3] = "runner" })[ws.id]
end)
mod.renumber_desktops()
local by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("the labelled one takes its name", by_ws[1], "dotfiles")
check("the other labelled one too", by_ws[3], "runner")
check("an unlabelled desktop stays a number", by_ws[2], "1.2")

-- Names must stay unique across monitors: waybar matches the active workspace
-- by name alone, so a shared name lights up two buttons at once.
print("scenario: two desktops open on the same directory")
reset(two_monitors(0))
mod.set_labeller(function() return "dotfiles" end)
mod.renumber_desktops()
by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("the first keeps the plain name", by_ws[1], "dotfiles")
check("the next carries its number too", by_ws[2], "dotfiles 1.2")
check("and so does one on another screen", by_ws[3], "dotfiles 2.1")

print("scenario: no labeller at all")
reset(two_monitors(0))
mod.renumber_desktops()
by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("everything is numbered as before", by_ws[1], "1.1")

-- A desktop is created by focusing something that does not exist yet, and it is
-- called whatever it was asked for until something renames it. Asking for the
-- name means there is never a number on the bar to correct.
-- Created by id and renamed at once. Asking for "name:" instead would work and
-- would hand the desktop a negative id, which sorts ahead of every other
-- desktop and renumbers the lot.
print("scenario: a new desktop is born with its name")
local n = two_monitors(0)
reset(n)
n.workspaces[1].name = "~"
n.workspaces[2].name = "~ 1.2"
n.workspaces[3].name = "~ 2.1"
mod.set_labeller(function() return "~" end)
dispatched, renames = {}, {}
mod.new_desktop_here()
check("created by id", last_of("focus").arg.workspace, 4)
check("and named straight away", renames[1] and renames[1].name, "~ 1.3")
check("the same desktop that was created", renames[1] and renames[1].workspace, 4)

print("scenario: a new desktop when the plain name is free")
local m = two_monitors(0)
reset(m)
m.workspaces[1].name = "1.1"
m.workspaces[2].name = "1.2"
m.workspaces[3].name = "2.1"
mod.set_labeller(function() return "~" end)
dispatched, renames = {}, {}
mod.new_desktop_here()
check("takes the plain name", renames[1] and renames[1].name, "~")

print("scenario: no labeller, so nothing to name it")
reset(two_monitors(0))
dispatched, renames = {}, {}
mod.new_desktop_here()
check("created by id", last_of("focus").arg.workspace, 4)
-- The renumbering pass still numbers it afterwards; what matters is that
-- creating it did not name it first.
check("nothing named it on the way in", renames[1] and renames[1].workspace, 1)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
