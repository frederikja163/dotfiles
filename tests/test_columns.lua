-- Harness for columns.lua.
--
-- The numbers come from real hardware: eDP-1 is 1920 at scale 1.5, so 1280
-- logical, and a lone column measures 1266 = 1280 - 2*5 gaps - 2*2 borders.
-- MON below uses 1920 at scale 2 -> 960 logical -> usable 946.

-- Resolve the hyprland modules from this repo, overridable for testing a copy.
local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local MON = { width = 1920, scale = 2 } -- usable 946
local USABLE = 946

local msgs, dispatched, focuses, world, binds, events, timers, timer_cbs, mod
local open_handler, early_handler

local function win(addr, x, y, w, h, floating)
    return {
        address = addr,
        at = { x = x, y = y },
        size = { x = w, y = h },
        floating = floating or false,
    }
end

local function reset(w)
    world, msgs, dispatched, focuses, binds, events, timers, timer_cbs =
        w, {}, {}, {}, {}, {}, 0, {}

    _G.hl = {
        bind = function(keys, fn, opts) binds[keys] = fn end,
        on = function(event, fn)
            events[event] = fn
            if event == "window.open" then open_handler = fn end
            if event == "window.open_early" then early_handler = fn end
        end,
        timer = function(cb, opts)
            timers = timers + 1
            table.insert(timer_cbs, cb)
        end,
        exec_cmd = function(cmd) end,
        dispatch = function(d)
            table.insert(dispatched, d)
            if type(d) == "table" and d.layout then table.insert(msgs, d.layout) end
            if type(d) == "table" and d.focus then table.insert(focuses, d.focus.window) end
        end,
        get_active_window = function() return world.active end,
        get_active_monitor = function() return world.monitor_obj end,
        get_windows = function()
            local out = {}
            for _, x in ipairs(world.windows) do table.insert(out, x) end
            return out
        end,
        get_config = function(key)
            if key == "general.gaps_out" then return { left = 5, right = 5, top = 5, bottom = 5 } end
            if key == "general.border_size" then return 2 end
        end,
        dsp = {
            layout = function(m) return { layout = m } end,
            focus = function(a) return { focus = a } end,
            window = { swap = function(a) return { swap = a } end },
        },
    }

    package.loaded.columns = nil
    package.loaded.programs = nil
    mod = require("columns")
    return mod
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

local function close_enough(label, got, want, eps)
    local ok = math.abs(got - want) <= (eps or 0.005)
    check(label .. (" (%.4f)"):format(got), ok, true)
end

-- Every colresize fraction emitted, in order.
local function fractions()
    local out = {}
    for _, m in ipairs(msgs) do
        local f = m:match("^colresize ([%d%.]+)$")
        if f then table.insert(out, tonumber(f)) end
    end
    return out
end

local function total(list)
    local t = 0
    for _, v in ipairs(list) do t = t + v end
    return t
end

local ws = { id = 1, special = false }

local function place(windows, active, monitor_ws)
    local w = { windows = windows, active = active,
                monitor_obj = { width = MON.width, scale = MON.scale, x = 0,
                                active_workspace = monitor_ws or ws } }
    reset(w)
    for _, x in ipairs(windows) do
        x.workspace = monitor_ws or ws
        x.monitor = MON
    end
    return mod
end

--------------------------------------------------------------------------------
print("usable width")
place({ win("a", 7, 7, 946, 526) }, nil)
check("matches the calibrated formula", mod.usable_width(MON), USABLE)

--------------------------------------------------------------------------------
print("to_unit: fractions always end up adding to exactly 1")
place({ win("a", 7, 7, 100, 100) }, nil)
close_enough("scales an under-full set", total(mod.to_unit({ 0.2, 0.2 })), 1.0)
close_enough("scales an over-full set", total(mod.to_unit({ 0.9, 0.9, 0.9 })), 1.0)
close_enough("leaves a correct set alone", total(mod.to_unit({ 0.5, 0.5 })), 1.0)
close_enough("handles all zeros", total(mod.to_unit({ 0, 0, 0 })), 1.0)
local kept = mod.to_unit({ 0.6, 0.2 })
close_enough("keeps proportions: 3:1 stays 3:1", kept[1] / kept[2], 3.0, 0.05)
local floored = mod.to_unit({ 0.98, 0.01 })
check("nothing ends up below the floor", floored[2] >= 0.079, true)
close_enough("and it still adds to 1", total(floored), 1.0)

--------------------------------------------------------------------------------
print("resize: what one column gains, the others give up")
-- three equal columns of 313 (946 usable)
local r1 = win("r1", 7, 7, 313, 526)
local r2 = win("r2", 327, 7, 313, 526)
local r3 = win("r3", 647, 7, 306, 526)
place({ r1, r2, r3 }, r2)
mod.resize_column(0.15)
local f = fractions()
check("one fraction per column", #f, 3)
close_enough("still adds to exactly 1", total(f), 1.0)
close_enough("focused column grew by the step", f[2], 0.333 + 0.15, 0.02)

print("resize: shrinking also keeps the total")
place({ r1, r2, r3 }, r2)
mod.resize_column(-0.15)
f = fractions()
close_enough("adds to exactly 1", total(f), 1.0)
close_enough("focused column shrank", f[2], 0.333 - 0.15, 0.02)

print("resize: cannot starve the other columns")
place({ r1, r2, r3 }, r2)
mod.resize_column(5.0) -- absurd growth
f = fractions()
close_enough("adds to exactly 1", total(f), 1.0)
check("others keep at least the floor", f[1] >= 0.079 and f[3] >= 0.079, true)

print("resize: a lone column is left alone")
place({ win("s1", 7, 7, 946, 526) }, nil)
world.active = world.windows[1]
mod.resize_column(0.1)
check("no messages", #msgs, 0)

print("resize: floating window does nothing")
local fl = win("fl", 100, 100, 200, 200, true)
place({ r1, r2, fl }, fl)
mod.resize_column(0.1)
check("no messages", #msgs, 0)

--------------------------------------------------------------------------------
print("new column: even columns are evened again")
local e1 = win("e1", 7, 7, 313, 526)
local e2 = win("e2", 327, 7, 313, 259)
local e3 = win("e3", 327, 274, 313, 259)
local e4 = win("e4", 647, 7, 313, 526)
place({ e1, e2, e3, e4 }, e2)
mod.new_column()
check("promotes first", msgs[1], "promote")
check("then evens 4 columns in one message", msgs[2], "colresize all 0.2500")

print("new column: uneven columns split the source in half")
local u1 = win("u1", 7, 7, 200, 526)
local u2 = win("u2", 215, 7, 600, 259)
local u3 = win("u3", 215, 274, 600, 259)
place({ u1, u2, u3 }, u2)
mod.new_column()
check("promotes first", msgs[1], "promote")
f = fractions()
check("one fraction per resulting column", #f, 3)
close_enough("adds to exactly 1", total(f), 1.0)
-- The widths are first scaled to add up to 1 (200:600 -> 0.25:0.75), then the
-- source's 0.75 is split into two halves. Total stays exactly 1.
close_enough("untouched column keeps its share", f[1], 0.25, 0.02)
close_enough("source keeps half of its share", f[2], 0.375, 0.02)
close_enough("new column takes the other half", f[3], 0.375, 0.02)

print("new column: window already alone does nothing")
place({ u1, win("v", 215, 7, 600, 526) }, world.windows and nil)
local lone = win("w1", 7, 7, 400, 526)
local other = win("w2", 415, 7, 400, 526)
place({ lone, other }, other)
mod.new_column()
check("no messages", #msgs, 0)

--------------------------------------------------------------------------------
print("balance: judged on the span, not the widths added up")
-- widths add up to less than the monitor because a fraction includes the gaps,
-- so a correct layout must still be treated as correct
local b1 = win("b1", 7, 7, 469, 526)
local b2 = win("b2", 484, 7, 469, 526) -- span 946 = usable
place({ b1, b2 }, b1)
mod.balance()
check("no rebalance for a correct layout", #msgs, 0)

print("balance: too wide is pulled back in")
local o1 = win("o1", 7, 7, 700, 526)
local o2 = win("o2", 715, 7, 700, 526) -- span 1408
place({ o1, o2 }, o1)
mod.balance()
f = fractions()
check("a fraction per column", #f, 2)
close_enough("adds to exactly 1", total(f), 1.0)

print("balance: too narrow is expanded to fill")
local n1 = win("n1", 7, 7, 200, 526)
local n2 = win("n2", 215, 7, 200, 526) -- span 408, way under
place({ n1, n2 }, n1)
mod.balance()
f = fractions()
check("a fraction per column", #f, 2)
close_enough("adds to exactly 1", total(f), 1.0)
close_enough("equal columns stay equal", f[1], f[2], 0.01)

print("balance: proportions survive being rescaled")
local p1 = win("p1", 7, 7, 150, 526)
local p2 = win("p2", 165, 7, 450, 526) -- 1:3, but only 608 of 946
place({ p1, p2 }, p1)
mod.balance()
f = fractions()
close_enough("adds to exactly 1", total(f), 1.0)
close_enough("still 1:3", f[2] / f[1], 3.0, 0.1)

print("balance: applies by focusing each column, then restores focus")
place({ p1, p2 }, p1)
mod.balance()
check("scroll inhibited while it works", msgs[1], "inhibit_scroll true")
check("scroll released at the end", msgs[#msgs], "inhibit_scroll false")
check("focused one window per column plus the restore", #focuses, 3)
check("original focus restored last", focuses[#focuses], "address:p1")

--------------------------------------------------------------------------------
print("new windows join the focused column")
local j1 = win("j1", 7, 7, 469, 526)
local j2 = win("j2", 484, 7, 469, 526)
place({ j1, j2 }, j2)
open_handler(j2)
check("moves into the previous (focused) column", msgs[1], "consume_or_expel prev")

print("...and the first window on a desktop is left where it is")
local k1 = win("k1", 7, 7, 946, 526)
place({ k1 }, k1)
open_handler(k1)
check("no consume", (function()
    for _, m in ipairs(msgs) do if m:match("consume") then return true end end
    return false
end)(), false)

print("...a window opening unfocused is ignored")
place({ j1, j2 }, j1)
open_handler(j2)
check("no consume", (function()
    for _, m in ipairs(msgs) do if m:match("consume") then return true end end
    return false
end)(), false)

print("...scrolling is inhibited from open_early")
place({ j1 }, j1)
early_handler()
check("inhibits", msgs[1], "inhibit_scroll true")
check("arms a release timer", timers, 1)

--------------------------------------------------------------------------------
print("move window between columns")
local m1 = win("m1", 7, 7, 300, 526)
local m2 = win("m2", 315, 7, 300, 259)
local m3 = win("m3", 315, 274, 300, 259)
local m4 = win("m4", 623, 7, 300, 526)
place({ m1, m2, m3, m4 }, m3)
mod.move_between_columns("prev")
check("not alone, so expel then merge", msgs[1] .. "/" .. msgs[2],
      "consume_or_expel prev/consume_or_expel prev")

place({ m1, m4 }, m4)
mod.move_between_columns("prev")
check("alone needs only one message", msgs[1], "consume_or_expel prev")

place({ m1, m4 }, m1)
mod.move_between_columns("prev")
check("alone at the left edge does nothing", #msgs, 0)

place({ m1, m4 }, m1) -- m1 is leftmost, so there is a column to its right
mod.move_between_columns("next")
check("moving right uses next", msgs[1], "consume_or_expel next")

place({ m1, m4 }, m4)
mod.move_between_columns("next")
check("alone at the right edge does nothing", #msgs, 0)

--------------------------------------------------------------------------------
print("main slot cycling")
local c1 = win("c1", 7, 7, 200, 526)
local c2 = win("c2", 215, 7, 700, 526)
place({ c1, c2 }, c1)
mod.cycle_main()
check("outside the main column, so it moves in", dispatched[1].swap.target, "address:c2")

local d1 = win("d1", 7, 7, 700, 526)
local d2 = win("d2", 715, 7, 120, 526)
local d3 = win("d3", 840, 7, 120, 526)
place({ d1, d2, d3 }, d1)
mod.cycle_main()
check("already main, pulls the next one in", dispatched[1].swap.target, "address:d2")
check("and follows it with focus", focuses[1], "address:d2")

local g1 = win("g1", 7, 7, 240, 526)
local g2 = win("g2", 255, 7, 700, 259)
local g3 = win("g3", 255, 274, 700, 259)
place({ g1, g2, g3 }, g2)
local cols = mod.columns_of(ws)
check("main column chosen by width, not window area", mod.main_column(cols).width, 700)
mod.cycle_main()
check("never picks a sibling in the same column", dispatched[1].swap.target ~= "address:g3", true)

--------------------------------------------------------------------------------
print("column detection")
local x1 = win("x1", 7, 7, 469, 259)
local x2 = win("x2", 9, 274, 467, 259) -- 2px off, same column
local x3 = win("x3", 484, 7, 469, 526)
place({ x1, x2, x3 }, x1)
cols = mod.columns_of(ws)
check("groups 3 windows into 2 columns", #cols, 2)
check("first column holds 2 windows", #cols[1].windows, 2)
check("ordered left to right", cols[1].x < cols[2].x, true)
check("equal widths detected", mod.all_same_width(cols), true)

local y1 = win("y1", 484, 7, 300, 259)
local y2 = win("y2", 7, 7, 300, 526)
local y3 = win("y3", 484, 274, 300, 259)
place({ y1, y2, y3 }, y2)
local order = mod.stable_order(ws)
check("stable order: leftmost first", order[1].address, "y2")
check("then top of the next column", order[2].address, "y1")
check("then below it", order[3].address, "y3")

print("alignment: the tape is pulled back to the monitor edge")
-- correct widths but shifted right: content starts at 58 instead of 7
local a1 = win("a1", 58, 7, 469, 526)
local a2 = win("a2", 535, 7, 469, 526)
place({ a1, a2 }, a1)
mod.align_start()
check("moves the tape back by the offset", msgs[1], "move -51")

print("alignment: shifted off the left edge is also corrected")
local b3 = win("b3", -44, 7, 469, 526)
local b4 = win("b4", 433, 7, 469, 526)
place({ b3, b4 }, b3)
mod.align_start()
check("moves the tape right", msgs[1], "move +51")

print("alignment: already at the edge is left alone")
local c3 = win("c3", 7, 7, 469, 526)
local c4 = win("c4", 484, 7, 469, 526)
place({ c3, c4 }, c3)
mod.align_start()
check("no message", #msgs, 0)

print("alignment: content wider than the monitor may legitimately scroll")
local d4 = win("d4", -200, 7, 700, 526)
local d5 = win("d5", 508, 7, 700, 526) -- span 1408 > 946
place({ d4, d5 }, d4)
mod.align_start()
check("no message", #msgs, 0)

print("closing a column: measured after the fact, not before")
-- window.destroy and friends must go through the scheduler, because reading the
-- geometry straight away still shows the column that is going away
place({ c3, c4 }, c3)
mod.schedule_balance()
check("arms two passes: widths, then offset", timers, 2)
check("nothing dispatched yet", #msgs, 0)
-- run them, with the layout now showing the column already gone and shrunk
local shrunk = win("s1", 58, 7, 400, 526)
place({ shrunk }, shrunk)
mod.schedule_balance()
for _, cb in ipairs(timer_cbs) do cb() end
check("the widths pass ran", (function()
    for _, m in ipairs(msgs) do if m:match("colresize") then return true end end
    return false
end)(), true)

print("events that can remove a column are all wired up")
place({ c3, c4 }, c3)
for _, e in ipairs({ "window.close", "window.destroy", "workspace.active",
                     "workspace.move_to_monitor", "window.move_to_workspace",
                     "monitor.added", "monitor.removed", "monitor.layout_changed" }) do
    check("  " .. e, type(events[e]), "function")
end

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
