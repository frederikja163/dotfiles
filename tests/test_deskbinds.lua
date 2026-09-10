-- Standalone harness for deskbinds.lua: stubs the hl API, then drives the
-- registered bind callbacks and asserts what they dispatch.

-- Resolve the hyprland modules from this repo, overridable for testing a copy.
local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

-- deskbinds.lua reads the pinned monitor order from $HYPR_MONITOR_ORDER when the
-- variable is set. tests/run.sh sets it; the os.getenv patch below makes this
-- file self-contained either way and guarantees it never reads the machine's
-- real, local pin file.
local pin_path = os.getenv("HYPR_MONITOR_ORDER") or "/tmp/hypr-monitor-order-test"
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "HYPR_MONITOR_ORDER" then
        return pin_path
    end
    return real_getenv(name)
end

local function set_pin(contents)
    local f = assert(io.open(pin_path, "w"))
    f:write(contents)
    f:close()
end
set_pin("") -- baseline: nothing pinned, so id order, as before

local binds, dispatched, monitor_calls, world, events, renames, execs, moves, rules, bound, mod

local function reset(w)
    world = w
    binds, dispatched, monitor_calls, events, renames, execs, moves, rules, bound =
        {}, {}, {}, {}, {}, {}, {}, {}, {}

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
        -- Keeping an empty desktop open is a workspace rule rather than a
        -- dispatch, so these are recorded separately. Hyprland replaces the
        -- rule for a selector it already has, which is why the last one for an
        -- id is what counts.
        --
        -- The rule's monitor also *binds* the id to a screen, and Hyprland
        -- reads that binding when a workspace with that id is created --
        -- ahead of the focused screen, and whether or not the rule still asks
        -- for persistence. An empty string does not unbind it (it is ignored,
        -- and the old screen goes on winning); "current" does, by naming
        -- whichever screen is in front, which is what an unbound id already
        -- gets. All three verified in a nested instance, and modelled here
        -- because a rule outliving its desktop is what sent new desktops to
        -- the wrong screen.
        workspace_rule = function(rule)
            table.insert(rules, rule)
            if rule.monitor == "current" then
                bound[rule.workspace] = nil
            elseif rule.monitor and rule.monitor ~= "" then
                bound[rule.workspace] = rule.monitor
            end
        end,
        get_workspace_windows = function(id)
            return (world.windows_on or {})[id] or {}
        end,
        get_active_monitor = function()
            for _, m in ipairs(world.monitors) do
                if m.id == world.focused_monitor_id then return m end
            end
        end,
        get_active_window = function() return world.active_window end,
        dsp = {
            layout = function(m) return { kind = "layout", arg = m } end,
            no_op = function() return { kind = "no_op" } end,
            focus = function(a)
                -- Focusing a fresh, empty desktop switches the active view over
                -- to it, so Hyprland reports no active window afterwards.
                -- (get_active_window() also takes a window named in the call,
                -- which must not clear it -- see the move test below.)
                if not a.window then
                    world.active_window = nil
                end
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
                        -- A workspace rule naming a monitor decides this
                        -- ahead of the focused screen, which is the whole
                        -- reason a dead desktop's rule has to go: see the
                        -- workspace_rule stub above.
                        for _, m in ipairs(world.monitors) do
                            if m.name == bound[tostring(a.workspace)] then mon = m end
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
                    -- Hyprland renames the workspace there and then, so the
                    -- next pass finds nothing to do and the bar does not
                    -- flicker. Modelled because bin/title reads the new name
                    -- straight back out of get_workspaces().
                    for _, ws in ipairs(world.workspaces) do
                        if ws.id == a.workspace then ws.name = a.name end
                    end
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
        active_window = { address = "0xWIN1", stable_id = "win1", floating = false },
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

-- deskbinds registers no keys at all any more: modes.lua owns them and calls
-- the actions below. Anything this file does bind would be a leftover.
local function bind_count()
    local n = 0
    for _ in pairs(binds) do n = n + 1 end
    return n
end

print("scenario: monitor 1 (eDP-1) focused")
reset(two_monitors(0))
check("no keys bound here", bind_count(), 0)
for _, name in ipairs({
    "focus_screen", "move_window_to_screen", "move_column_to_screen",
    "move_desktop_to_screen", "toggle_mirror_screen", "focus_neighbour_desktop",
    "move_window_to_neighbour_desktop", "move_column_to_neighbour_desktop",
}) do
    check("exports " .. name, type(mod[name]), "function")
end

print("scenario: the screen axis")
reset(two_monitors(0))
mod.focus_screen(2)
check("another screen -> focus its workspace", last().arg.workspace, 3)

reset(two_monitors(0))
mod.focus_screen(1)
check("the screen you are on -> a new desktop, lowest free id", last_of("focus").arg.workspace, 4)
local persisted_new = nil
for _, rule in ipairs(rules) do
    if rule.workspace == "4" then persisted_new = rule.persistent end
end
check("...and it is kept while empty", persisted_new, true)

reset(two_monitors(0))
local before = #dispatched
mod.focus_screen(5)
check("a screen that is not there -> nothing", #dispatched, before)

print("scenario: a new desktop lands at the end of its own screen")
-- The shape that used to get this wrong: a lower id is free, but it belongs
-- below the desktops this screen already has. mon1 holds ws3 while id 2 is
-- going spare, so the lowest free id globally would arrive *before* ws3 and
-- become that screen's desktop 1.
local gap = two_monitors(1) -- DP-4 focused, holding only ws3
for i, ws in ipairs(gap.workspaces) do
    if ws.id == 2 then table.remove(gap.workspaces, i) break end
end
reset(gap)
mod.focus_screen(2) -- the screen you are on: makes a desktop
check("skips the free id below this screen's own", last_of("focus").arg.workspace, 4)

-- ...and the gap is still available to the screen it sorts correctly on.
local gap2 = two_monitors(0) -- eDP-1 focused, holding ws1
for i, ws in ipairs(gap2.workspaces) do
    if ws.id == 2 then table.remove(gap2.workspaces, i) break end
end
reset(gap2)
mod.focus_screen(1)
check("but reuses it where it does sort last", last_of("focus").arg.workspace, 2)

print("scenario: the desktop axis (Tab), which now owns cycling")
reset(two_monitors(0))
mod.focus_neighbour_desktop(1)
check("next desktop", last().arg.workspace, 2)
check("...by focusing it", last().kind, "focus")

local w = two_monitors(0)
w.monitors[1].active_workspace = w.workspaces[2] -- ws2, the last one on mon0
reset(w)
mod.focus_neighbour_desktop(1)
check("next wraps to the first", last().arg.workspace, 1)

reset(two_monitors(0))
mod.focus_neighbour_desktop(-1)
check("previous wraps backwards to the last", last().arg.workspace, 2)

-- The old behaviour was to create a desktop when a screen had only one, which
-- made the key mean two different things. Tab cycles and nothing else now.
local one = two_monitors(1) -- DP-4 focused, only ws3 lives there
reset(one)
local before_one = #dispatched
mod.focus_neighbour_desktop(1)
check("a lone desktop has nowhere to cycle, and nothing is created", #dispatched, before_one)

print("scenario: a desktop addressed by its number on this screen")
-- mon0 owns ws1 and ws2, so its desktops are numbered 1 and 2 whatever their
-- global ids are. mon1 owns ws3, which is *its* desktop 1.
reset(two_monitors(0))
mod.focus_desktop_index(1)
check("desktop 1 here is workspace 1", last().arg.workspace, 1)
check("...by focusing it", last().kind, "focus")

reset(two_monitors(0))
mod.focus_desktop_index(2)
check("desktop 2 here is workspace 2", last().arg.workspace, 2)

-- The numbering is per screen: on the other monitor, desktop 1 is workspace 3.
reset(two_monitors(1))
mod.focus_desktop_index(1)
check("desktop 1 on the other screen is workspace 3", last().arg.workspace, 3)

reset(two_monitors(0))
local before_missing = #dispatched
mod.focus_desktop_index(7)
check("a desktop that is not there -> nothing", #dispatched, before_missing)
check("...and none is created", #hl.get_workspaces(), 4)

reset(two_monitors(0))
check("how many desktops this screen has", mod.desktop_count(), 2)
reset(two_monitors(1))
check("...and the other one", mod.desktop_count(), 1)

print("scenario: moving the window")
reset(two_monitors(0))
mod.move_window_to_screen(2)
check("to another screen", last().arg.workspace, 3)
check("...by moving it", last().kind, "move")

reset(two_monitors(0))
mod.move_window_to_screen(1)
check("to a new desktop on the screen you are on", last_of("focus").arg.workspace, 4)
check("...and the window follows", last_of("move").arg.workspace, 4)
check("...addressed by window, since focus has moved on", last_of("move").arg.window, "address:0xWIN1")

reset(two_monitors(0))
mod.move_window_to_neighbour_desktop(1)
check("to the next desktop", last().arg.workspace, 2)
check("...by moving it", last().kind, "move")

print("scenario: moving the window or its column to a desktop by number")
reset(two_monitors(0))
mod.move_window_to_desktop_index(2)
check("window to desktop 2 here", last().arg.workspace, 2)
check("...by moving it", last().kind, "move")

reset(two_monitors(0))
local before_gap = #dispatched
mod.move_window_to_desktop_index(6)
check("no sixth desktop -> nothing, and none is made", #dispatched, before_gap)

local fl2 = two_monitors(0)
fl2.active_window = { address = "0xFLOAT", stable_id = "f", floating = true }
reset(fl2)
local before_fl2 = #dispatched
mod.move_column_to_desktop_index(2)
check("a floating window has no column to send", #dispatched, before_fl2)

print("scenario: moving the whole desktop")
reset(two_monitors(0))
mod.move_desktop_to_screen(2)
check("to another screen", moves[1] and moves[1].monitor, "DP-4")
check("...addressed by workspace id", moves[1] and moves[1].workspace, 1)

reset(two_monitors(0))
mod.move_desktop_to_screen(1)
check("to the screen it is already on -> nothing", #moves, 0)

-- Waybar orders its buttons by name (waybar/config.jsonc asks for sort-by:
-- name, because ordering by workspace id ignores a reordered row). So sorting
-- the names of one screen's desktops has to give back the row itself --
-- including when labelled and unlabelled desktops are mixed, which is where
-- the old "<screen>.<desktop>" form went wrong on any screen but the first.
print("scenario: names sort into the same order as the row")
local mixed = two_monitors(0)
table.insert(mixed.workspaces, { id = 6, special = false, monitor = mixed.monitors[2] })
table.insert(mixed.workspaces, { id = 7, special = false, monitor = mixed.monitors[2] })
reset(mixed)
-- Screen 2 holds three desktops; only the middle one has been anywhere.
mod.set_labeller(function(ws) return ws.id == 6 and "dotfiles" or nil end)
mod.renumber_desktops()

local named = {}
for _, ren in ipairs(renames) do named[ren.workspace] = ren.name end

local row, names = {}, {}
for _, ws in ipairs(mod.desktops_on(world.monitors[2])) do
    table.insert(row, named[ws.id])
    table.insert(names, named[ws.id])
end
table.sort(names)
check("the row on screen 2", table.concat(row, " "), "1.2 2 dotfiles 3.2")
check("sorting the names gives the same order", table.concat(names, " "), table.concat(row, " "))

print("scenario: shuffling a desktop along its own row")
-- mon0 gets a row of three: ws1, ws2, ws6.
local function row_of(mon)
    local ids = {}
    for _, ws in ipairs(mod.desktops_on(mon)) do table.insert(ids, ws.id) end
    return table.concat(ids, ",")
end

local shuffle = two_monitors(0)
table.insert(shuffle.workspaces, { id = 6, special = false, monitor = shuffle.monitors[1] })
shuffle.monitors[1].active_workspace = shuffle.workspaces[2] -- ws2, the middle one
reset(shuffle)
check("the row to start with", row_of(world.monitors[1]), "1,2,6")

mod.move_desktop_in_row(1)
check("moving it right swaps it with the one after", row_of(world.monitors[1]), "1,6,2")

mod.move_desktop_in_row(-1)
check("and back again", row_of(world.monitors[1]), "1,2,6")

mod.move_desktop_in_row(-1)
check("moving it left puts it first", row_of(world.monitors[1]), "2,1,6")

-- At the end of the row there is nowhere further to go, and it must not wrap.
local edge = two_monitors(0)
table.insert(edge.workspaces, { id = 6, special = false, monitor = edge.monitors[1] })
edge.monitors[1].active_workspace = edge.workspaces[1] -- ws1, already first
reset(edge)
mod.move_desktop_in_row(-1)
check("already first, so left does nothing", row_of(world.monitors[1]), "1,2,6")

local edge2 = two_monitors(0)
table.insert(edge2.workspaces, { id = 6, special = false, monitor = edge2.monitors[1] })
edge2.monitors[1].active_workspace = edge2.workspaces[5] -- ws6, already last
reset(edge2)
mod.move_desktop_in_row(1)
check("already last, so right does nothing", row_of(world.monitors[1]), "1,2,6")

-- The workspace id never changes, which is what keeps its windows, its quake
-- terminal and its persistence rule attached to it.
local keep = two_monitors(0)
table.insert(keep.workspaces, { id = 6, special = false, monitor = keep.monitors[1] })
keep.monitors[1].active_workspace = keep.workspaces[2]
reset(keep)
local before_ids = {}
for _, ws in ipairs(hl.get_workspaces()) do before_ids[ws.id] = true end
mod.move_desktop_in_row(1)
local same = true
for _, ws in ipairs(hl.get_workspaces()) do
    if not before_ids[ws.id] then same = false end
end
check("no workspace was renumbered", same, true)

print("scenario: a moved desktop lands at the end of the screen it arrives on")
-- The shape that got this wrong: the desktop being moved has a *lower* id than
-- the desktops already on the target, so ordering by id alone dropped it into
-- the middle of that row and renumbered the ones after it.
local arrive = two_monitors(0) -- eDP-1 focused, showing ws1
-- Give DP-4 a row of its own with higher ids than ws1.
table.insert(arrive.workspaces, { id = 8, special = false, monitor = arrive.monitors[2] })
reset(arrive)
mod.move_desktop_to_screen(2)

-- The stub does not move the workspace itself, so say where it ended up and
-- then ask what that screen's row looks like.
world.workspaces[1].monitor = world.monitors[2]
local row = {}
for _, ws in ipairs(mod.desktops_on(world.monitors[2])) do table.insert(row, ws.id) end
check("it goes last, not into the middle", table.concat(row, ","), "3,8,1")

-- ...and it stays there: the position is remembered, not recomputed.
local again = {}
for _, ws in ipairs(mod.desktops_on(world.monitors[2])) do table.insert(again, ws.id) end
check("and stays there when asked again", table.concat(again, ","), "3,8,1")

print("scenario: a desktop moved to an empty screen needs no note")
local lone = two_monitors(0)
lone.workspaces = { lone.workspaces[1], lone.workspaces[4] } -- eDP-1 keeps ws1; DP-4 has none
lone.monitors[2].active_workspace = nil
reset(lone)
mod.move_desktop_to_screen(2)
world.workspaces[1].monitor = world.monitors[2]
local only = {}
for _, ws in ipairs(mod.desktops_on(world.monitors[2])) do table.insert(only, ws.id) end
check("it is simply the row", table.concat(only, ","), "1")

print("scenario: moving a column needs a tiled window to read the column from")
local fl = two_monitors(0)
fl.active_window = { address = "0xFLOAT", stable_id = "f", floating = true }
reset(fl)
local before_float = #dispatched
mod.move_column_to_screen(2)
check("a floating window has no column", #dispatched, before_float)

local none = two_monitors(0)
none.active_window = nil
reset(none)
local before_none = #dispatched
mod.move_column_to_neighbour_desktop(1)
check("no window, no column", #dispatched, before_none)

print("scenario: duplicate then un-duplicate with the same key")
local m = two_monitors(0)
reset(m)
mod.toggle_mirror_screen(2)
check("first press duplicates onto the focused monitor", monitor_calls[1].mirror, "eDP-1")
check("target is the other monitor", monitor_calls[1].output, "DP-4")

-- Hyprland now hides DP-4 from get_monitors(); the slot must survive anyway.
local slots = mod.monitor_slots()
check("slot 2 still exists while duplicating", slots[2] and slots[2].name, "DP-4")
check("and is flagged as duplicating", slots[2] and slots[2].source, "eDP-1")
check("get_monitors no longer reports it", #hl.get_monitors(), 1)

mod.toggle_mirror_screen(2)
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
mod.toggle_mirror_screen(2) -- duplicate the middle monitor
local s2 = mod.monitor_slots()
check("slot 1 unchanged", s2[1].name, "eDP-1")
check("slot 2 is still the duplicating monitor", s2[2].name, "DP-4")
check("slot 3 did NOT move up", s2[3].name, "HDMI-1")

print("scenario: a duplicating screen has no desktops of its own")
local before_dup = #dispatched
mod.focus_screen(2)
check("so focusing it does nothing", #dispatched, before_dup)

print("scenario: how many screens are addressable")
reset(two_monitors(0))
check("both of them", mod.screen_count(), 2)

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

check("mon1 desktop1 -> 1.1 (desktop 1, screen 1)", named[1], "1.1")
check("mon1 desktop2 -> 2.1 (desktop 2, screen 1)", named[2], "2.1")
check("mon2 desktop1 -> 1.2 (desktop 1, screen 2)", named[3], "1.2")
check("mon2 desktop2 -> 2.2 (desktop 2, screen 2)", named[5], "2.2")
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
r2.workspaces[2].name = "2.1"
r2.workspaces[3].name = "1.2"
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

-- The pinned order decides which screen owns which number, independent of
-- Hyprland's monitor ids. reset() re-requires deskbinds.lua, which re-reads the
-- pin file, so the file has to be written before the scenario.
print("scenario: the pinned order overrides Hyprland id order")
set_pin("Dell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
reset(two_monitors(0))
local s = mod.monitor_slots()
check("pinned slot 1 is DP-4 (id 1)", s[1].name, "DP-4")
check("pinned slot 2 is eDP-1 (id 0)", s[2].name, "eDP-1")

print("scenario: desktop numbers follow the pinned order too")
mod.renumber_desktops()
by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("DP-4's desktop (id 3) is now 1.1", by_ws[3], "1.1")
-- eDP-1 is screen 2 under this pin order, so its desktops are 1 and 2 *of
-- screen 2*: the number that leads is the desktop's, not the screen's.
check("eDP-1's first desktop is 1.2", by_ws[1], "1.2")
check("eDP-1's second is 2.2", by_ws[2], "2.2")

print("scenario: a transform on a pinned line does not disturb the order")
set_pin("Dell DELL P3424WE DVYH6T3 transform=1\nBOE 0x0DBB\n")
reset(two_monitors(0))
local s = mod.monitor_slots()
check("pinned slot 1 is still DP-4", s[1].name, "DP-4")
check("pinned slot 2 is still eDP-1", s[2].name, "eDP-1")
local pe = require("monitorpin").load()
check("monitorpin reads the transform off the line", pe[1].transform, 1)
check("...and leaves the identity intact", pe[1].identity, "Dell DELL P3424WE DVYH6T3")
check("a line with no settings has no transform", pe[2].transform, nil)

print("scenario: a monitor no one has pinned joins after the pinned ones")
set_pin("Dell DELL P3424WE DVYH6T3\n")
local p = two_monitors(0)
local mon3 = { id = 2, name = "HDMI-1", active_workspace = nil }
local ws9 = { id = 9, special = false, monitor = mon3, name = "9" }
mon3.active_workspace = ws9
table.insert(p.monitors, mon3)
table.insert(p.workspaces, ws9)
reset(p)
local s3 = mod.monitor_slots()
check("pinned DP-4 first", s3[1].name, "DP-4")
check("then eDP-1 by id", s3[2].name, "eDP-1")
check("then HDMI-1 by id", s3[3].name, "HDMI-1")

print("scenario: a duplicating monitor keeps its pinned slot")
set_pin("HDMI-1\nDell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
local thr = two_monitors(0)
local mon4 = { id = 2, name = "HDMI-1", active_workspace = nil }
local ws9b = { id = 9, special = false, monitor = mon4, name = "9" }
mon4.active_workspace = ws9b
table.insert(thr.monitors, mon4)
table.insert(thr.workspaces, ws9b)
reset(thr)
mod.toggle_mirror_screen(2) -- duplicate the middle, pinned slot 2
local s4 = mod.monitor_slots()
check("slot 1 stays HDMI-1", s4[1].name, "HDMI-1")
check("slot 2 is DP-4, duplicating", s4[2].name, "DP-4")
check("slot 2 is flagged duplicating", s4[2].source, "eDP-1")
check("slot 3 stays eDP-1", s4[3].name, "eDP-1")

set_pin("") -- back to baseline, in case a later scenario runs after this one

-- quake.lua names a desktop after the directory its terminal is sitting in.
-- Waybar shows the workspace name whenever its format-icons has no entry, so
-- the label only has to end up in the name.
--
-- The name leads with the desktop's own number, because that number is a key:
-- SUPER+D then 2 goes to the second desktop on this screen, and a desktop
-- called just "dotfiles" gave no clue which number that was.
print("scenario: desktops that have something to call themselves")
reset(two_monitors(0))
mod.set_labeller(function(ws)
    return ({ [1] = "dotfiles", [3] = "runner" })[ws.id]
end)
mod.renumber_desktops()
local by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("the labelled one is numbered, then named", by_ws[1], "1 dotfiles")
check("the other one too, numbered per screen", by_ws[3], "1 runner")
check("an unlabelled desktop stays a number", by_ws[2], "2.1")

-- Names must stay unique across monitors: waybar matches the active workspace
-- by name alone, so a shared name lights up two buttons at once.
print("scenario: two desktops open on the same directory")
reset(two_monitors(0))
mod.set_labeller(function() return "dotfiles" end)
mod.renumber_desktops()
by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("the first is desktop 1", by_ws[1], "1 dotfiles")
check("the next is desktop 2, so the names differ already", by_ws[2], "2 dotfiles")
-- Same index on another screen, same label: the screen number breaks the tie.
check("a clash across screens keeps the screen number", by_ws[3], "1 dotfiles (2)")

print("scenario: no labeller at all")
reset(two_monitors(0))
mod.renumber_desktops()
by_ws = {}
for _, ren in ipairs(renames) do by_ws[ren.workspace] = ren.name end
check("everything is numbered as before", by_ws[1], "1.1")

-- The rule an id ended up with. Hyprland replaces the rule for a selector it
-- already has, so the last one issued for an id is the one in force -- and
-- since an empty desktop only survives being left by way of a `persistent`
-- rule, this is how "kept open" is asserted.
local function last_rule_for(id)
    for i = #rules, 1, -1 do
        if rules[i].workspace == tostring(id) then
            return rules[i]
        end
    end
end

-- bin/title: a desktop that is "comms" rather than a directory. The label is
-- what a desktop is called when nobody has said; a title is somebody saying.
local function renamed(id)
    for _, ren in ipairs(renames) do
        if ren.workspace == id then return true end
    end
    return false
end

print("scenario: naming a desktop outright")
reset(two_monitors(0))
mod.set_labeller(function() return "dotfiles" end)
mod.renumber_desktops()
check("named after its directory to begin with", world.workspaces[1].name, "1 dotfiles")
check("titling answers with the new name", mod.set_title_here("comms"), "1 comms")
check("...which is what the desktop is called", world.workspaces[1].name, "1 comms")
check("...and its neighbour is untouched", world.workspaces[2].name, "2 dotfiles")

-- A desktop whose only content is its quake terminal is empty as far as
-- Hyprland is concerned, so a named one would be swept up the moment you
-- looked away -- name, terminal and all. Naming it is asking for it.
check("a named desktop is kept open", mod.is_persistent(1), true)
check("...pinned to the screen it is on", last_rule_for(1) and last_rule_for(1).monitor, "eDP-1")

print("scenario: a title is frozen against the terminal wandering off")
-- The label changes on every `cd`; that is the thing a title is asked for to
-- stop. Only the untitled desktops follow it.
renames = {}
mod.set_labeller(function() return "somewhere-else" end)
mod.renumber_desktops()
check("the titled desktop is left alone", renamed(1), false)
check("...still by its name", world.workspaces[1].name, "1 comms")
check("while an untitled one follows its directory", world.workspaces[2].name, "2 somewhere-else")

print("scenario: the number is not part of the title")
-- Moving the desktop along its row renumbers it like any other, and the name
-- it was given rides along.
mod.move_desktop_in_row(1)
check("renumbered where it landed", world.workspaces[1].name, "2 comms")
check("...and the one it passed took the number it left", world.workspaces[2].name, "1 somewhere-else")

print("scenario: clearing a title")
check("answers with the name it falls back to", mod.set_title_here(""), "2 somewhere-else")
check("...which is its directory again", world.workspaces[1].name, "2 somewhere-else")

print("scenario: there is nothing in front to name")
local sp = two_monitors(0)
sp.monitors[1].active_workspace = sp.workspaces[4] -- the special one
reset(sp)
check("no desktop, so no name", mod.set_title_here("comms"), nil)

print("scenario: a desktop's title goes with the desktop")
-- Ids are reused, and a title left behind would be inherited: the next
-- desktop handed this id would come up called "comms".
local gone_title = two_monitors(0)
reset(gone_title)
mod.set_labeller(function() return nil end)
mod.set_title_here("comms")
check("named", world.workspaces[1].name, "1 comms")

table.remove(world.workspaces, 1) -- as Hyprland sweeps an empty desktop up
mod.renumber_desktops()
table.insert(world.workspaces, 1,
    { id = 1, special = false, monitor = world.monitors[1] })
mod.renumber_desktops()
check("the next desktop with that id is a number again", world.workspaces[1].name, "1.1")

-- A desktop is created by focusing something that does not exist yet, and it is
-- called whatever it was asked for until something renames it. Asking for the
-- name means there is never a number on the bar to correct.
-- Created by id and renamed at once. Asking for "name:" instead would work and
-- would hand the desktop a negative id, which sorts ahead of every other
-- desktop and renumbers the lot.
print("scenario: a new desktop is born with its name")
local n = two_monitors(0)
reset(n)
n.workspaces[1].name = "1 ~"
n.workspaces[2].name = "2 ~"
n.workspaces[3].name = "1 ~ (2)"
mod.set_labeller(function() return "~" end)
dispatched, renames = {}, {}
mod.new_desktop_here()
check("created by id", last_of("focus").arg.workspace, 4)
-- Third desktop on this screen, so it is born as "3 ~" rather than being
-- numbered a moment later by the renumbering pass.
check("and named straight away", renames[1] and renames[1].name, "3 ~")
check("the same desktop that was created", renames[1] and renames[1].workspace, 4)

print("scenario: a new desktop among unlabelled ones")
local m = two_monitors(0)
reset(m)
m.workspaces[1].name = "1.1"
m.workspaces[2].name = "2.1"
m.workspaces[3].name = "1.2"
mod.set_labeller(function() return "~" end)
dispatched, renames = {}, {}
mod.new_desktop_here()
check("still numbered, since the number is the point", renames[1] and renames[1].name, "3 ~")

print("scenario: no labeller, so it is born with its number")
reset(two_monitors(0))
dispatched, renames = {}, {}
mod.new_desktop_here()
check("created by id", last_of("focus").arg.workspace, 4)
-- Named on the way in rather than left to the deferred pass: without this the
-- bar shows the raw workspace id ("4") for the ~80ms until that runs.
check("named as it was created", renames[1] and renames[1].workspace, 4)
check("...with its position and screen", renames[1] and renames[1].name, "3.1")

print("scenario: a desktop asked for outright survives being left empty")
-- The plain screen key, pressed on the screen you are already on. Asking for a
-- desktop and passing through one are different keys now, and only the first
-- gets a persistence rule.
local p1 = two_monitors(0)
reset(p1)
mod.focus_screen(1)
check("created the desktop", last_of("focus").arg.workspace, 4)
check("...and asked for it to persist", last_rule_for(4) and last_rule_for(4).persistent, true)
check("addressed by id as a string", last_rule_for(4) and last_rule_for(4).workspace, "4")
check("only that one desktop is made persistent", #rules, 1)

print("scenario: a persistent desktop's rule names the screen it belongs to")
-- Issuing any persistent workspace rule makes Hyprland re-place every
-- persistent workspace it knows about. One whose rule names no monitor is
-- placed on whichever screen has focus at that moment -- so making an empty
-- desktop on one screen dragged every empty desktop from the other screen
-- across to join it.
reset(two_monitors(0)) -- eDP-1 focused
mod.focus_screen(1)    -- the screen you are on: makes a desktop, id 4
local pinned = last_rule_for(4)
check("the new desktop is kept while empty", pinned and pinned.persistent, true)
check("...and pinned to the screen it was made on", pinned and pinned.monitor, "eDP-1")

print("scenario: a persistent desktop that moves screens takes its rule along")
-- Otherwise the next re-placement pass reads the old screen out of the rule
-- and hauls the desktop back to it.
reset(two_monitors(0))
mod.place_desktop(1, nil, true) -- ws1, in view on eDP-1, kept while empty
check("pinned where it is", last_rule_for(1) and last_rule_for(1).monitor, "eDP-1")
mod.move_desktop_to_screen(2)
check("still persistent after the move", last_rule_for(1) and last_rule_for(1).persistent, true)
check("...and now pinned to the screen it moved to", last_rule_for(1) and last_rule_for(1).monitor, "DP-4")

print("scenario: a desktop made on the way somewhere is not persistent")
local p2 = two_monitors(1) -- DP-4 focused, a single desktop on it
reset(p2)
mod.move_window_to_screen(2) -- takes the window onto a fresh desktop
check("created one", last_of("focus").arg.workspace, 4)
check("...with no rule: it has a window on it, so it cannot lapse", #rules, 0)

-- SUPER+C on an empty desktop: leave it, then drop the rule. That order is
-- Hyprland's, not a preference -- it will not destroy the workspace it shows.
print("scenario: closing the empty desktop in view")
-- Closing lands on the desktop *before* the one closed: backing out of
-- somewhere should leave you where you came from. Only when there is nothing
-- before it does focus go forwards instead, and it never wraps -- the old
-- behaviour put you on desktop 1 from anywhere.
local c1 = two_monitors(0) -- mon0 shows ws1, the first, and also owns ws2
reset(c1)
check("it closed something", mod.close_desktop_here(), true)
check("nothing before the first, so focus goes forward", last_of("focus").arg.workspace, 2)
check("persistence dropped for the one left behind", last_rule_for(1).persistent, false)
check("...by id", last_rule_for(1).workspace, "1")
-- And the rule stops naming a screen, or the next desktop given this id is
-- born on it. There is no way to name none, so "current" -- the screen in
-- front -- stands in for it.
check("...and it no longer binds the id to a screen", last_rule_for(1).monitor, "current")

print("scenario: closing a desktop that has one before it")
local c2 = two_monitors(0)
c2.monitors[1].active_workspace = c2.workspaces[2] -- ws2, the last on mon0
reset(c2)
check("it closed something", mod.close_desktop_here(), true)
check("focus goes back to the one before", last_of("focus").arg.workspace, 1)

print("scenario: closing the middle desktop of three")
local c3 = two_monitors(0)
table.insert(c3.workspaces, { id = 6, special = false, monitor = c3.monitors[1] })
c3.monitors[1].active_workspace = c3.workspaces[2] -- ws2, with ws1 before and ws6 after
reset(c3)
check("it closed something", mod.close_desktop_here(), true)
check("focus goes backwards, not forwards", last_of("focus").arg.workspace, 1)

print("scenario: a closed desktop does not decide where the next one is born")
-- The bug, end to end: ask for a desktop on one screen, close it again, then
-- ask for one on the other screen -- and the new desktop appeared back on the
-- first screen. Its id had been freed and handed out again, and the dead
-- desktop's workspace rule still bound that id to the screen it had lived on.
local function ws_by_id(id)
    for _, ws in ipairs(world.workspaces) do
        if ws.id == id then return ws end
    end
end

local function drop_ws(id)
    for i, ws in ipairs(world.workspaces) do
        if ws.id == id then table.remove(world.workspaces, i) return end
    end
end

local reuse = two_monitors(0) -- eDP-1 focused, holding ws1 and ws2
reset(reuse)

mod.focus_screen(1) -- the screen you are on: makes a desktop, id 4
local first = last_of("focus").arg.workspace
check("made on the screen in front", ws_by_id(first).monitor.name, "eDP-1")

-- Hyprland shows a desktop it has just created; the stub does not follow
-- focus on its own, so say so before closing the thing.
world.monitors[1].active_workspace = ws_by_id(first)
check("closed it again", mod.close_desktop_here(), true)
drop_ws(first) -- as Hyprland removes it
world.monitors[1].active_workspace = ws_by_id(1)

-- Over on the other screen, where the freed id is the next one going.
world.focused_monitor_id = 1
mod.focus_screen(2)
local second = last_of("focus").arg.workspace
check("the same id is handed out again", second, first)
check("...and the new desktop is born where it was asked for", ws_by_id(second).monitor.name, "DP-4")

print("scenario: closing the last desktop on a screen is refused")
local c4 = two_monitors(1) -- DP-4 focused, holding only ws3
reset(c4)
check("nowhere to go, so nothing is closed", mod.close_desktop_here(), false)

print("scenario: the focus happens before the rule is dropped")
-- Both are recorded, so the order can be asserted rather than assumed: the
-- reverse leaves the desktop standing.
local c2 = two_monitors(0)
reset(c2)
local order = {}
local real_dispatch, real_rule = hl.dispatch, hl.workspace_rule
hl.dispatch = function(d)
    if d.kind == "focus" then table.insert(order, "focus") end
    return real_dispatch(d)
end
hl.workspace_rule = function(r)
    table.insert(order, "rule")
    return real_rule(r)
end
mod.close_desktop_here()
check("focus first", order[1], "focus")
check("rule second", order[2], "rule")
hl.dispatch, hl.workspace_rule = real_dispatch, real_rule

-- quake.lua hangs its own tidying up on this: the desktop's terminal is closed
-- with it, so the next desktop to get this id does not inherit the old one's
-- shell and directory.
-- The bug this exists for: a desktop has two ways to end and only one of them
-- used to clean up. Closing it with SUPER+C did. *Lapsing* -- left empty and
-- swept up by Hyprland, which is the commoner case by far -- did not, so its
-- screen, its place in the row, its persistence rule, its terminal and its
-- layout were all inherited by the next desktop handed that id.
print("scenario: a desktop that lapses is forgotten as thoroughly as one that is closed")
local lapse = two_monitors(0)
table.insert(lapse.workspaces, { id = 9, special = false, monitor = lapse.monitors[2] })
reset(lapse)

local forgotten = {}
mod.on_forget(function(id) table.insert(forgotten, id) end)

-- Let the pass see all four, so it knows they existed.
mod.renumber_desktops()
check("nothing has gone yet", #forgotten, 0)

-- ws9 vanishes on its own, the way Hyprland sweeps an empty desktop.
for i, ws in ipairs(world.workspaces) do
    if ws.id == 9 then table.remove(world.workspaces, i) break end
end
mod.renumber_desktops()
check("the pass notices it has gone", #forgotten, 1)
check("...and says which", forgotten[1], 9)

-- ...and having been forgotten once, it is not reported again.
mod.renumber_desktops()
check("only reported once", #forgotten, 1)

print("scenario: a lapsed desktop's persistence rule is dropped with it")
-- Otherwise the rule keeps naming a screen, and Hyprland places the next
-- desktop given that id there -- a new desktop arriving on the wrong monitor.
local stale = two_monitors(0)
table.insert(stale.workspaces, { id = 9, special = false, monitor = stale.monitors[2] })
reset(stale)
mod.place_desktop(9, nil, true)     -- id 9 is kept while empty
mod.renumber_desktops()
check("pinned to a screen while it exists", last_rule_for(9) and last_rule_for(9).persistent, true)

for i, ws in ipairs(world.workspaces) do
    if ws.id == 9 then table.remove(world.workspaces, i) break end
end
mod.renumber_desktops()
check("the rule is cleared once it has gone", last_rule_for(9) and last_rule_for(9).persistent, false)
check("...and it is no longer thought persistent", mod.is_persistent(9), false)

print("scenario: closing a desktop tells whoever asked to be told")
local h1 = two_monitors(0)
reset(h1)
local told = {}
mod.on_forget(function(id) table.insert(told, id) end)
mod.close_desktop_here()
check("called once", #told, 1)
check("with the id of the desktop being closed", told[1], 1)

print("scenario: nothing is closed, so nothing is forgotten")
local h2 = two_monitors(1) -- DP-4's only desktop, which cannot be closed
reset(h2)
told = {}
mod.on_forget(function(id) table.insert(told, id) end)
check("refused", mod.close_desktop_here(), false)
check("hook not called", #told, 0)

print("scenario: a desktop with a window on it is not closed")
local c3 = two_monitors(0)
c3.windows_on = { [1] = { { address = "0xWIN1" } } }
reset(c3)
check("refused", mod.close_desktop_here(), false)
check("nothing dispatched", #dispatched, 0)
check("no rule touched", #rules, 0)

print("scenario: a monitor's last desktop stays, empty or not")
local c4 = two_monitors(1) -- DP-4 focused, ws3 is all it has
reset(c4)
check("refused", mod.close_desktop_here(), false)
check("no rule touched", #rules, 0)

print("scenario: nothing to close when a special workspace is in view")
local c5 = two_monitors(0)
c5.monitors[1].active_workspace = c5.workspaces[4] -- the special one
reset(c5)
check("refused", mod.close_desktop_here(), false)
check("no rule touched", #rules, 0)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
