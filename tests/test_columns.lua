-- Harness for columns.lua. Uses the real numbers measured in the sandbox:
-- monitor 1920px at scale 2 -> 960 logical, colresize 1.0 == 944px.

-- Resolve the hyprland modules from this repo, overridable for testing a copy.
local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local msgs, dispatched, world, open_handler, early_handler, binds, timers, events

local function win(addr, x, y, w, h, floating)
    return {
        address = addr,
        at = { x = x, y = y },
        size = { x = w, y = h },
        floating = floating or false,
        floating_ = floating,
    }
end

local function reset(w)
    world, msgs, dispatched, binds, timers, events = w, {}, {}, {}, 0, {}

    _G.hl = {
        bind = function(keys, fn, opts) binds[keys] = fn end,
        on = function(event, fn)
            if event == "window.open" then open_handler = fn end
            if event == "window.open_early" then early_handler = fn end
            events[event] = fn
        end,
        timer = function(cb, opts) timers = timers + 1 end, -- do not fire: it is a safety net
        dispatch = function(d)
            table.insert(dispatched, d)
            if type(d) == "table" and d.layout then table.insert(msgs, d.layout) end
        end,
        get_active_window = function() return world.active end,
        get_active_monitor = function() return world.monitor_obj end,
        get_config = function(key)
            if key == "general.gaps_out" then return { left = 5, right = 5, top = 5, bottom = 5 } end
            if key == "general.border_size" then return 2 end
        end,
        get_windows = function(filter)
            local out = {}
            for _, x in ipairs(world.windows) do table.insert(out, x) end
            return out
        end,
        dsp = {
            layout = function(m) return { layout = m } end,
            focus = function(a) return { focus = a } end,
            window = { swap = function(a) return { swap = a } end },
        },
    }

    package.loaded.columns = nil
    package.loaded.programs = nil
    return require("columns")
end

local MON = { width = 1920, scale = 2 } -- 960 logical

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-50s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-50s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

local ws = { id = 1, special = false }

-- Scenario A: two equal columns, focused column has 2 stacked windows.
-- Expect promote then "colresize all 0.333" (3 columns, evened).
print("A: equal columns, split one out -> re-even")
local a1 = win("a1", 7, 7, 469, 526)
local a2 = win("a2", 484, 7, 469, 259)
local a3 = win("a3", 484, 274, 469, 259)
a2.workspace, a2.monitor = ws, MON
local mod = reset({ windows = { a1, a2, a3 }, active = a2 })
for _, w in ipairs({ a1, a2, a3 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("first msg is promote", msgs[1], "promote")
check("evens all three columns", msgs[2], "colresize all 0.333")

-- Scenario B: uneven columns. Focused column is 700 wide of 960 logical
-- (fraction 0.729) with 2 windows -> new column should be half: ~0.365
print("B: uneven columns with room to spare -> half of selected")
-- usable is 946; these span 508, so there is plenty of room for a new column
local b1 = win("b1", 7, 7, 200, 526)
local b2 = win("b2", 215, 7, 300, 259)
local b3 = win("b3", 215, 274, 300, 259)
mod = reset({ windows = { b1, b2, b3 }, active = b2 })
for _, w in ipairs({ b1, b2, b3 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("promote first", msgs[1], "promote")
check("half of the source column (300/946/2)", msgs[2], "colresize 0.159")

print("B2: the same split with no room left evens out instead of overflowing")
local c1 = win("c1", 7, 7, 200, 526)
local c2 = win("c2", 215, 7, 700, 259)
local c3 = win("c3", 215, 274, 700, 259) -- span 908 of 946 usable
mod = reset({ windows = { c1, c2, c3 }, active = c2 })
for _, w in ipairs({ c1, c2, c3 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("evens rather than spilling over", msgs[2], "colresize all 0.333")

-- Scenario C: focused window already alone in its column -> no-op
print("C: already alone in its column -> nothing happens")
local c1 = win("c1", 7, 7, 469, 526)
local c2 = win("c2", 484, 7, 469, 526)
mod = reset({ windows = { c1, c2 }, active = c2 })
for _, w in ipairs({ c1, c2 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("no layout messages", #msgs, 0)

-- Scenario D: floating window focused -> no-op
print("D: floating window -> nothing happens")
local d1 = win("d1", 7, 7, 469, 526)
local d2 = win("d2", 100, 100, 400, 300, true)
mod = reset({ windows = { d1, d2 }, active = d2 })
for _, w in ipairs({ d1, d2 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("no layout messages", #msgs, 0)

-- Scenario E: column grouping tolerance
print("E: column detection")
local e1 = win("e1", 7, 7, 469, 259)
local e2 = win("e2", 9, 274, 467, 259) -- 2px off, same column
local e3 = win("e3", 484, 7, 469, 526)
mod = reset({ windows = { e1, e2, e3 }, active = e1 })
for _, w in ipairs({ e1, e2, e3 }) do w.workspace, w.monitor = ws, MON end
local cols = mod.columns_of(ws)
check("groups 3 windows into 2 columns", #cols, 2)
check("first column holds 2 windows", #cols[1].windows, 2)
check("columns ordered left to right", cols[1].x < cols[2].x, true)
check("equal widths detected", mod.all_same_width(cols), true)

-- Scenario F: window.open consume behaviour
print("F: new window joins the focused column")
local f1 = win("f1", 7, 7, 469, 526)
local f2 = win("f2", 484, 7, 469, 526)
mod = reset({ windows = { f1, f2 }, active = f2 })
for _, w in ipairs({ f1, f2 }) do w.workspace, w.monitor = ws, MON end
open_handler(f2)
check("moves into the previous (focused) column", msgs[1], "consume_or_expel prev")
check("and re-enables scrolling afterwards", msgs[2], "inhibit_scroll false")

print("F2: first window on an empty desktop is left alone")
local g1 = win("g1", 7, 7, 944, 526)
mod = reset({ windows = { g1 }, active = g1 })
g1.workspace, g1.monitor = ws, MON
open_handler(g1)
check("no consume for a lone window", msgs[1], "inhibit_scroll false")
check("only that one message", #msgs, 1)

print("F3: window opening unfocused is left alone")
local h1 = win("h1", 7, 7, 469, 526)
local h2 = win("h2", 484, 7, 469, 526)
mod = reset({ windows = { h1, h2 }, active = h1 }) -- h2 opened but h1 keeps focus
for _, w in ipairs({ h1, h2 }) do w.workspace, w.monitor = ws, MON end
open_handler(h2)
check("no consume when not focused", msgs[1], "inhibit_scroll false")

print("F4: window not alone in its column is left alone (would expel)")
local n1 = win("n1", 7, 7, 469, 259)
local n2 = win("n2", 7, 274, 469, 259) -- same column as n1
mod = reset({ windows = { n1, n2 }, active = n2 })
for _, w in ipairs({ n1, n2 }) do w.workspace, w.monitor = ws, MON end
open_handler(n2)
check("scrolling re-enabled even on the bail-out path", msgs[1], "inhibit_scroll false")
check("and nothing else", #msgs, 1)

print("F5: open_early inhibits scrolling before the tape can move")
local o1 = win("o1", 7, 7, 469, 526)
mod = reset({ windows = { o1 }, active = o1 })
o1.workspace, o1.monitor = ws, MON
early_handler()
check("inhibits scrolling", msgs[1], "inhibit_scroll true")
check("arms a safety timer to release it", timers, 1)

-- Scenario G: cycle through the main slot (widest column)
print("G: focused window outside the main column -> moves into it")
local i1 = win("i1", 7, 7, 200, 526)   -- narrow, focused
local i2 = win("i2", 215, 7, 700, 526) -- widest column = main
mod = reset({ windows = { i1, i2 }, active = i1 })
for _, w in ipairs({ i1, i2 }) do w.workspace, w.monitor = ws, MON end
mod.cycle_main()
check("swaps with the main column window", dispatched[1].swap.target, "address:i2")
check("no explicit focus needed (focus follows)", #dispatched, 1)

print("G2: main column chosen by WIDTH, not window area")
-- the wide column is split in two, so each window's area (700x259=181k) is
-- smaller than the tall narrow one (240x526=126k)? no - make area misleading:
local a1 = win("a1", 7, 7, 240, 526)     -- area 126240, full height
local a2 = win("a2", 255, 7, 700, 259)   -- area 181300 but only half height
local a3 = win("a3", 255, 274, 700, 259)
mod = reset({ windows = { a1, a2, a3 }, active = a1 })
for _, w in ipairs({ a1, a2, a3 }) do w.workspace, w.monitor = ws, MON end
local cols = mod.columns_of(ws)
check("main column is the 700px wide one", mod.main_column(cols).width, 700)

print("G3: focused inside main column -> pulls in an OUTSIDE window")
mod = reset({ windows = { a1, a2, a3 }, active = a2 })
for _, w in ipairs({ a1, a2, a3 }) do w.workspace, w.monitor = ws, MON end
mod.cycle_main()
check("targets the window outside the main column", dispatched[1].swap.target, "address:a1")
check("focus follows into the main slot", dispatched[2].focus.window, "address:a1")

print("G4: a sibling in the same column is never chosen")
-- a3 shares the main column with a2, so it must not be the swap target
check("did not pick the sibling a3", dispatched[1].swap.target ~= "address:a3", true)

print("G5: cycling walks forward across several outside windows")
local b1 = win("b1", 7, 7, 700, 526)   -- main, focused
local b2 = win("b2", 715, 7, 120, 526)
local b3 = win("b3", 840, 7, 120, 526)
mod = reset({ windows = { b1, b2, b3 }, active = b1 })
for _, w in ipairs({ b1, b2, b3 }) do w.workspace, w.monitor = ws, MON end
mod.cycle_main()
check("press 1 -> b2", dispatched[1].swap.target, "address:b2")
-- simulate the swap taking effect
b1.at, b1.size = { x = 715, y = 7 }, { x = 120, y = 526 }
b2.at, b2.size = { x = 7, y = 7 },   { x = 700, y = 526 }
world.active = b2
dispatched = {}
mod.cycle_main()
check("press 2 -> b3, not back to b1", dispatched[1].swap.target, "address:b3")

print("G6: single column -> no-op")
local c1 = win("c1", 7, 7, 944, 259)
local c2 = win("c2", 7, 274, 944, 259)
mod = reset({ windows = { c1, c2 }, active = c1 })
for _, w in ipairs({ c1, c2 }) do w.workspace, w.monitor = ws, MON end
mod.cycle_main()
check("nothing dispatched", #dispatched, 0)

print("G7: floating window -> no-op")
local d1 = win("d1", 7, 7, 700, 526)
local d2 = win("d2", 100, 100, 300, 200, true)
mod = reset({ windows = { d1, d2 }, active = d2 })
for _, w in ipairs({ d1, d2 }) do w.workspace, w.monitor = ws, MON end
mod.cycle_main()
check("nothing dispatched", #dispatched, 0)

print("G8: stable order is left-to-right then top-to-bottom")
local m1 = win("m1", 484, 7,   300, 259)
local m2 = win("m2", 7,   7,   300, 526)
local m3 = win("m3", 484, 274, 300, 259)
mod = reset({ windows = { m1, m2, m3 }, active = m2 })
for _, w in ipairs({ m1, m2, m3 }) do w.workspace, w.monitor = ws, MON end
local order = mod.stable_order(ws)
check("leftmost first", order[1].address, "m2")
check("then top of next column", order[2].address, "m1")
check("then below it", order[3].address, "m3")

print("H: move window between columns")
-- three columns; focused window shares the middle one
local p1 = win("p1", 7,   7,   300, 526)
local p2 = win("p2", 315, 7,   300, 259)
local p3 = win("p3", 315, 274, 300, 259) -- focused, NOT alone
local p4 = win("p4", 623, 7,   300, 526)
mod = reset({ windows = { p1, p2, p3, p4 }, active = p3 })
for _, w in ipairs({ p1, p2, p3, p4 }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("prev")
check("not alone + neighbour -> two messages", #msgs, 2)
check("both are consume_or_expel prev", msgs[1] .. "/" .. msgs[2],
      "consume_or_expel prev/consume_or_expel prev")

print("H2: window alone in its column needs only one message")
local q1 = win("q1", 7,   7, 300, 526)
local q2 = win("q2", 315, 7, 300, 526) -- focused, alone
mod = reset({ windows = { q1, q2 }, active = q2 })
for _, w in ipairs({ q1, q2 }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("prev")
check("one message only", #msgs, 1)
check("it is consume_or_expel prev", msgs[1], "consume_or_expel prev")

print("H3: alone at the edge -> nothing happens")
mod = reset({ windows = { q1, q2 }, active = q1 }) -- q1 is leftmost and alone
for _, w in ipairs({ q1, q2 }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("prev")
check("no messages", #msgs, 0)

print("H4: not alone at the edge -> expel only, no merge back")
local r1 = win("r1", 7, 7,   300, 259)
local r2 = win("r2", 7, 274, 300, 259) -- focused, shares the only column
mod = reset({ windows = { r1, r2 }, active = r2 })
for _, w in ipairs({ r1, r2 }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("prev")
check("single expel, not two", #msgs, 1)

print("H5: moving right uses next")
mod = reset({ windows = { q1, q2 }, active = q1 })
for _, w in ipairs({ q1, q2 }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("next")
check("consume_or_expel next", msgs[1], "consume_or_expel next")

print("H6: floating window -> no-op")
local f = win("fl", 100, 100, 200, 200, true)
mod = reset({ windows = { q1, q2, f }, active = f })
for _, w in ipairs({ q1, q2, f }) do w.workspace, w.monitor = ws, MON end
mod.move_between_columns("prev")
check("no messages", #msgs, 0)

print("I: columns must never exceed the monitor")
-- MON is 1920 at scale 2 -> 960 logical, so usable = 960 - 2*5 - 2*2 = 946
local u1 = win("u1", 7, 7, 946, 526)
mod = reset({ windows = { u1 }, active = u1 })
u1.workspace, u1.monitor = ws, MON
check("usable width matches the calibrated formula", mod.usable_width(MON), 946)

print("I2: growing a column that already fills the screen does nothing")
local v1 = win("v1", 7, 7, 473, 526)
local v2 = win("v2", 484, 7, 473, 526) -- two halves: span 950 >= usable
mod = reset({ windows = { v1, v2 }, active = v1 })
for _, w in ipairs({ v1, v2 }) do w.workspace, w.monitor = ws, MON end
mod.resize_column(0.05)
check("no resize message", #msgs, 0)

print("I3: growing is capped at the free space")
-- one column of 300 on a 946 usable: 646 free = 0.68 of the monitor
local x1 = win("x1", 7, 7, 300, 526)
mod = reset({ windows = { x1 }, active = x1 })
x1.workspace, x1.monitor = ws, MON
mod.resize_column(0.05) -- plenty of room, so the full step applies
check("normal step applied", msgs[1], "colresize 0.367")

print("I4: a step larger than the remaining room is trimmed")
local y1 = win("y1", 7, 7, 900, 526) -- 46px free = 0.049
mod = reset({ windows = { y1 }, active = y1 })
y1.workspace, y1.monitor = ws, MON
mod.resize_column(0.5)
check("trimmed to the free space", msgs[1], "colresize 1.000")

print("I5: shrinking is always allowed")
mod = reset({ windows = { v1, v2 }, active = v1 })
for _, w in ipairs({ v1, v2 }) do w.workspace, w.monitor = ws, MON end
mod.resize_column(-0.05)
check("shrink works even when full", msgs[1], "colresize 0.450")

print("I6: new column falls back to evening out when there is no room")
-- three columns already filling the monitor, focused one shares its column
local z1 = win("z1", 7, 7, 313, 526)
local z2 = win("z2", 327, 7, 313, 259)
local z3 = win("z3", 327, 274, 313, 259) -- focused, not alone
local z4 = win("z4", 647, 7, 306, 526)
mod = reset({ windows = { z1, z2, z3, z4 }, active = z3 })
for _, w in ipairs({ z1, z2, z3, z4 }) do w.workspace, w.monitor = ws, MON end
mod.new_column()
check("promoted", msgs[1], "promote")
check("evened to 1/4 instead of overflowing", msgs[2], "colresize all 0.250")

print("J: overflow that arrives from outside is corrected")
-- two columns wider than the monitor: 600 + 600 on a 946 usable
local o1 = win("o1", 7, 7, 600, 526)
local o2 = win("o2", 615, 7, 600, 526)
local mon_ws = { id = 1, special = false }
mod = reset({ windows = { o1, o2 }, active = o1,
              monitor_obj = { width = MON.width, scale = MON.scale, active_workspace = mon_ws } })
for _, w in ipairs({ o1, o2 }) do w.workspace, w.monitor = mon_ws, MON end
mod.enforce_bounds()
check("evens the columns to fit", msgs[1], "fit all")

print("J2: columns that already fit are left alone")
local q1 = win("q1", 7, 7, 400, 526)
local q2 = win("q2", 415, 7, 400, 526) -- span 808 of 946
mod = reset({ windows = { q1, q2 }, active = q1,
              monitor_obj = { width = MON.width, scale = MON.scale, active_workspace = mon_ws } })
for _, w in ipairs({ q1, q2 }) do w.workspace, w.monitor = mon_ws, MON end
mod.enforce_bounds()
check("no message, uneven widths preserved", #msgs, 0)

print("J3: a lone column is never touched")
local r1 = win("r1", 7, 7, 946, 526)
mod = reset({ windows = { r1 }, active = r1,
              monitor_obj = { width = MON.width, scale = MON.scale, active_workspace = mon_ws } })
r1.workspace, r1.monitor = mon_ws, MON
mod.enforce_bounds()
check("no message", #msgs, 0)

print("J4: enforcement is wired to the events that can change geometry")
check("workspace.active hooked", type(events["workspace.active"]), "function")
check("window.close hooked", type(events["window.close"]), "function")
check("monitor.removed hooked", type(events["monitor.removed"]), "function")

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
