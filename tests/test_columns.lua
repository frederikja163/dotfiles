-- Tests for the column layout.
--
-- The layout owns the geometry, so the interesting parts are plain functions on
-- a state table and need no compositor at all. Only a stub `hl` is needed for
-- the module to load.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

_G.hl = {
    layout = { register = function(name, provider) _G.__provider = provider end },
    bind = function() end,
    get_windows = function() return _G.__windows or {} end,
    dispatch = function(d) table.insert(_G.__dispatched, d) end,
    dsp = {
        layout = function(m) return { layout = m } end,
        focus = function(a) return { kind = "focus", arg = a } end,
        window = { move = function(a) return { kind = "move", arg = a } end },
    },
}

local C = require("columns")

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

local function near(label, got, want, eps)
    check(label .. (" (%.4f)"):format(got), math.abs(got - want) <= (eps or 0.005), true)
end

-- Total width of the columns, which must always be 1.
local function width_total(st)
    local t = 0
    for _, c in ipairs(st.columns) do t = t + c.width end
    return t
end

local function shape(st)
    local parts = {}
    for _, c in ipairs(st.columns) do
        parts[#parts + 1] = table.concat(c.ids, "+")
    end
    return table.concat(parts, " | ")
end

-- A state built from a description like { {1,2}, {3} }.
local function build(cols, widths)
    local st = C.new_state()
    for i, ids in ipairs(cols) do
        local heights = {}
        for j = 1, #ids do heights[j] = 1 / #ids end
        st.columns[i] = { ids = { table.unpack(ids) }, heights = heights,
                          width = widths and widths[i] or (1 / #cols) }
    end
    st.focused = cols[1] and cols[1][1] or nil
    return st
end

local AREA = { x = 5, y = 5, w = 600, h = 400 }

--------------------------------------------------------------------------------
print("to_unit")
near("scales up", (function() local t = 0 for _, v in ipairs(C.to_unit({ 0.2, 0.2 })) do t = t + v end return t end)(), 1.0)
near("scales down", (function() local t = 0 for _, v in ipairs(C.to_unit({ 0.9, 0.9, 0.9 })) do t = t + v end return t end)(), 1.0)
near("all zeros", (function() local t = 0 for _, v in ipairs(C.to_unit({ 0, 0 })) do t = t + v end return t end)(), 1.0)
local prop = C.to_unit({ 0.6, 0.2 })
near("keeps 3:1", prop[1] / prop[2], 3.0, 0.05)
local floored = C.to_unit({ 0.99, 0.005 })
check("respects the floor", floored[2] >= C.MIN - 0.001, true)
near("and still totals 1", floored[1] + floored[2], 1.0)

--------------------------------------------------------------------------------
print("reconcile: new windows join the focused column, at the bottom")
local st = build({ { 1, 2 }, { 3 } })
st.focused = 3
C.reconcile(st, { 1, 2, 3, 4 }, 3)
check("window 4 joined the focused column", shape(st), "1+2 | 3+4")
near("widths still total 1", width_total(st), 1.0)

print("reconcile: a second window splits the lone column")
st = build({ { 1 } })
st.focused = 1
C.reconcile(st, { 1, 2 }, 1)
check("two columns now, not a stack", shape(st), "1 | 2")
near("evenly split", st.columns[1].width, 0.5)
near("widths total 1", width_total(st), 1.0)

print("reconcile: that holds even if the lone column has several windows")
st = build({ { 1, 2, 3 } })
st.focused = 2
C.reconcile(st, { 1, 2, 3, 4 }, 2)
check("the new window gets its own column", shape(st), "1+2+3 | 4")
near("widths total 1", width_total(st), 1.0)

print("reconcile: with two columns already, new windows join the focused one")
st = build({ { 1 }, { 2 } })
st.focused = 2
C.reconcile(st, { 1, 2, 3 }, 2)
check("joined the focused column", shape(st), "1 | 2+3")
check("still two columns", #st.columns, 2)

print("reconcile: the first window creates the one column")
st = C.new_state()
C.reconcile(st, { 7 }, 7)
check("one column, one window", shape(st), "7")
near("it fills the monitor", width_total(st), 1.0)

print("reconcile: a closed window is removed and its width redistributed")
st = build({ { 1 }, { 2 }, { 3 } })
C.reconcile(st, { 1, 3 }, 1)
check("column of 2 is gone", shape(st), "1 | 3")
near("widths total 1", width_total(st), 1.0)
near("and are even again", st.columns[1].width, 0.5)

print("reconcile: closing one of several in a column keeps the column")
st = build({ { 1, 2, 3 }, { 4 } })
C.reconcile(st, { 1, 3, 4 }, 1)
check("still two columns", shape(st), "1+3 | 4")
near("heights total 1", st.columns[1].heights[1] + st.columns[1].heights[2], 1.0)

print("reconcile: a new window does not steal its own column")
-- window 9 is active *and* new: it must land in the previously focused column
st = build({ { 1 }, { 2 } })
st.focused = 2
C.reconcile(st, { 1, 2, 9 }, 9)
check("joined column 2", shape(st), "1 | 2+9")

--------------------------------------------------------------------------------
print("boxes: fill the area exactly, every time")
local function assert_exact(label, st)
    local b = C.boxes(st, AREA)
    -- columns: x of first is area.x, right edge of last is area.x + area.w
    local minx, maxr = math.huge, -math.huge
    local per_col = {}
    for _, e in ipairs(b) do
        minx = math.min(minx, e.box.x)
        maxr = math.max(maxr, e.box.x + e.box.w)
        per_col[e.box.x] = per_col[e.box.x] or {}
        table.insert(per_col[e.box.x], e.box)
    end
    check(label .. ": starts at the left edge", minx, AREA.x)
    check(label .. ": ends at the right edge", maxr, AREA.x + AREA.w)
    -- every column's windows must fill the height exactly
    local heights_ok = true
    for _, list in pairs(per_col) do
        local top, bottom = math.huge, -math.huge
        for _, box in ipairs(list) do
            top = math.min(top, box.y)
            bottom = math.max(bottom, box.y + box.h)
        end
        if top ~= AREA.y or bottom ~= AREA.y + AREA.h then heights_ok = false end
    end
    check(label .. ": columns fill the height", heights_ok, true)
end

assert_exact("one window", build({ { 1 } }))
assert_exact("two columns", build({ { 1 }, { 2 } }))
assert_exact("three uneven", build({ { 1 }, { 2 }, { 3 } }, { 0.5, 0.3, 0.2 }))
assert_exact("stacked", build({ { 1, 2, 3 }, { 4 } }))
assert_exact("awkward thirds", build({ { 1 }, { 2 }, { 3 } }, { 1/3, 1/3, 1/3 }))

--------------------------------------------------------------------------------
print("new column")
st = build({ { 1, 2 }, { 3 } }, { 0.6, 0.4 })
check("splits the focused window out", C.new_column(st, 2), true)
check("into its own column, right of the source", shape(st), "1 | 2 | 3")
near("total is unchanged", width_total(st), 1.0)
near("source halved", st.columns[1].width, 0.3)
near("new column has the other half", st.columns[2].width, 0.3)
near("the other column is untouched", st.columns[3].width, 0.4)

st = build({ { 1, 2 }, { 3 } }) -- equal columns
C.new_column(st, 2)
near("equal columns are evened out again", st.columns[1].width, 1 / 3)
near("total is 1", width_total(st), 1.0)

st = build({ { 1 }, { 2 } })
check("a window already alone does nothing", C.new_column(st, 1), false)

--------------------------------------------------------------------------------
print("move between columns")
st = build({ { 1, 2 }, { 3 } })
check("moves right", C.move_to_column(st, 2, "next"), true)
check("into the neighbour, at the bottom", shape(st), "1 | 3+2")
near("total is 1", width_total(st), 1.0)

st = build({ { 1 }, { 2 } })
C.move_to_column(st, 2, "prev")
check("emptying a column removes it", shape(st), "1+2")
near("the survivor fills the monitor", width_total(st), 1.0)
check("one column left", #st.columns, 1)

st = build({ { 1, 2 } })
C.move_to_column(st, 2, "next")
check("at the edge but not alone: new column", shape(st), "1 | 2")
near("total is 1", width_total(st), 1.0)

st = build({ { 1 }, { 2 } })
check("alone at the edge does nothing", C.move_to_column(st, 1, "prev"), false)

--------------------------------------------------------------------------------
print("move within a column")
st = build({ { 1, 2, 3 } })
C.move_in_column(st, 2, "up")
check("swaps with the one above", shape(st), "2+1+3")
C.move_in_column(st, 2, "down")
check("and back down", shape(st), "1+2+3")
check("top window cannot go up", C.move_in_column(st, 1, "up"), false)

--------------------------------------------------------------------------------
print("swap columns")
st = build({ { 1 }, { 2 }, { 3 } }, { 0.5, 0.3, 0.2 })
C.swap_column(st, 2, "prev")
check("columns swapped", shape(st), "2 | 1 | 3")
-- The column keeps its own width, so a narrow column stays narrow when it is
-- moved to the other side.
near("width travels with the column", st.columns[1].width, 0.3)
near("and the wide one keeps its width too", st.columns[2].width, 0.5)
near("total is still 1", width_total(st), 1.0)
check("edge column cannot swap further", C.swap_column(st, 2, "prev"), false)

--------------------------------------------------------------------------------
print("resize column: the others give up the difference")
st = build({ { 1 }, { 2 }, { 3 } })
C.resize_column(st, 1, 0.3)
near("total stays 1", width_total(st), 1.0)
near("focused grew", st.columns[1].width, 1/3 + 0.3, 0.02)

st = build({ { 1 }, { 2 } })
C.resize_column(st, 1, 5.0)
near("absurd growth still totals 1", width_total(st), 1.0)
check("the other keeps the floor", st.columns[2].width >= C.MIN - 0.001, true)

st = build({ { 1 } })
check("a lone column cannot resize", C.resize_column(st, 1, 0.2), false)

print("resize row: same, vertically")
st = build({ { 1, 2, 3 } })
C.resize_row(st, 1, 0.2)
local hs = st.columns[1].heights
near("heights total 1", hs[1] + hs[2] + hs[3], 1.0)
near("focused row grew", hs[1], 1/3 + 0.2, 0.02)
st = build({ { 1 } })
check("a lone window cannot resize vertically", C.resize_row(st, 1, 0.2), false)

--------------------------------------------------------------------------------
print("cycle through the main column")
st = build({ { 1 }, { 2 } }, { 0.7, 0.3 })
C.cycle_main(st, 2)
check("outside the main column, so it moves in", shape(st), "2 | 1")

st = build({ { 1 }, { 2 }, { 3 } }, { 0.6, 0.2, 0.2 })
C.cycle_main(st, 1)
check("already main: pulls the next one in", shape(st), "2 | 1 | 3")
C.cycle_main(st, 2)
check("second press takes a different window", shape(st), "3 | 1 | 2")
near("widths never move", st.columns[1].width, 0.6)

st = build({ { 1 } })
check("nothing to cycle with one column", C.cycle_main(st, 1), false)

--------------------------------------------------------------------------------
print("the invariant survives a long random sequence")
math.randomseed(20260901)
st = build({ { 1 } })
local next_id, live = 2, { 1 }
local ops_run = 0
for step = 1, 400 do
    local ids = {}
    for _, v in ipairs(live) do ids[#ids + 1] = v end
    local focus = live[math.random(#live)]
    C.reconcile(st, ids, focus)

    local roll = math.random(8)
    if roll == 1 and #live < 12 then
        next_id = next_id + 1
        table.insert(live, next_id)
    elseif roll == 2 and #live > 1 then
        table.remove(live, math.random(#live))
    elseif roll == 3 then
        C.new_column(st, focus)
    elseif roll == 4 then
        C.move_to_column(st, focus, math.random(2) == 1 and "prev" or "next")
    elseif roll == 5 then
        C.resize_column(st, focus, (math.random() - 0.5) * 0.6)
    elseif roll == 6 then
        C.swap_column(st, focus, math.random(2) == 1 and "prev" or "next")
    elseif roll == 7 then
        C.cycle_main(st, focus)
    else
        C.resize_row(st, focus, (math.random() - 0.5) * 0.4)
    end
    ops_run = ops_run + 1

    -- the invariant, after every single step
    if #st.columns > 0 and math.abs(width_total(st) - 1.0) > 0.01 then
        check("width total after step " .. step, width_total(st), 1.0)
        break
    end
    local b = C.boxes(st, AREA)
    local maxr = -math.huge
    for _, e in ipairs(b) do maxr = math.max(maxr, e.box.x + e.box.w) end
    if #b > 0 and maxr ~= AREA.x + AREA.w then
        check("right edge after step " .. step, maxr, AREA.x + AREA.w)
        break
    end
end
check(("survived %d random operations"):format(ops_run), ops_run, 400)
near("widths still total exactly 1", width_total(st), 1.0)

print("row heights: a second window takes half the column, not a third")
st = build({ { 1 } })
st.focused = 1
C.reconcile(st, { 1, 2 }, 1)   -- lone column, so this splits into two columns
st = build({ { 1 }, { 9 } })   -- two columns, so the next window stacks
st.focused = 1
C.reconcile(st, { 1, 9, 2 }, 1)
local h = st.columns[1].heights
check("two windows in the column", #st.columns[1].ids, 2)
near("first row is half", h[1], 0.5)
near("second row is half", h[2], 0.5)
near("heights total 1", h[1] + h[2], 1.0)

print("row heights: a third window makes it thirds")
st = build({ { 1, 2 }, { 9 } })
st.focused = 2
C.reconcile(st, { 1, 2, 9, 3 }, 2)
h = st.columns[1].heights
check("three windows", #st.columns[1].ids, 3)
near("each row a third", h[1], 1/3)
near("heights total 1", h[1] + h[2] + h[3], 1.0)

print("row heights: uneven column splits the focused row in half")
st = build({ { 1, 2 }, { 9 } })
st.columns[1].heights = { 0.8, 0.2 }
st.focused = 1
C.reconcile(st, { 1, 2, 9, 3 }, 1)
h = st.columns[1].heights
near("focused row halved", h[1], 0.4)
near("new row takes the other half", h[2], 0.4)
near("the untouched row is unchanged", h[3], 0.2)
near("heights total 1", h[1] + h[2] + h[3], 1.0)
check("new window sits below the focused one", st.columns[1].ids[2], 3)

print("row heights: a window moved into a column shares evenly")
st = build({ { 1 }, { 2 } })
C.move_to_column(st, 2, "prev")
h = st.columns[1].heights
check("one column now", #st.columns, 1)
near("both rows equal", h[1], 0.5)
near("heights total 1", h[1] + h[2], 1.0)

print("crossing to another screen: arriving at the edge it came in from")
st = build({ { 1 }, { 2 } }, { 0.5, 0.5 })
C.insert_edge(st, 9, "last")
check("a window pushed left joins the right edge", shape(st), "1 | 2 | 9")
near("a share is taken from the edge column", st.columns[2].width, 0.25)
near("total is 1", width_total(st), 1.0)

st = build({ { 1 }, { 2 } }, { 0.5, 0.5 })
C.insert_edge(st, 9, "first")
check("one pushed right joins the left edge", shape(st), "9 | 1 | 2")
near("total is 1", width_total(st), 1.0)

st = build({ { 1, 2 } }, { 1.0 })
C.insert_edge(st, 9, "first")
check("arriving on an un-split desktop still makes a column", shape(st), "9 | 1+2")
near("total is 1", width_total(st), 1.0)

print("crossing: an expected window is placed at the edge, not by the focus")
-- The window would otherwise land beside the focused one, which on a busy
-- desktop is nowhere near the side it crossed from.
st = build({ { 1 }, { 2 }, { 3 } })
st.focused = 2
C.expect_arrival(st, 9, "first")
C.reconcile(st, { 1, 2, 3, 9 }, 9)
check("it arrives at the edge", shape(st), "9 | 1 | 2 | 3")
check("the expectation is cleared", st.arriving, nil)

print("crossing: a second window follows the usual rules")
st = build({ { 1 }, { 2 } })
C.expect_arrival(st, 9, "last")
C.reconcile(st, { 1, 2, 9 }, 9)
check("the expected one goes to the edge", shape(st), "1 | 2 | 9")
C.reconcile(st, { 1, 2, 9, 10 }, 9)
check("the next by the usual rules", shape(st), "1 | 2 | 9+10")

print("crossing: which column is at the edge")
st = build({ { 1 }, { 2, 3 }, { 4 } })
check("leftmost is at the left edge", C.at_edge(st, 1, "prev"), true)
check("...and not at the right", C.at_edge(st, 1, "next"), false)
check("rightmost is at the right edge", C.at_edge(st, 4, "next"), true)
check("a middle window is at neither edge", C.at_edge(st, 2, "prev"), false)
check("up and down are never at a horizontal edge", C.at_edge(st, 1, "up"), false)

print("crossing: a window alone in its column")
check("alone", C.alone_in_column(st, 1), true)
check("...or stacked", C.alone_in_column(st, 2), false)

print("handing a column to another workspace")
-- Windows arrive one at a time, so the destination is told what is coming and
-- groups them as they turn up.
st = build({ { 1, 2 }, { 3 } })
st.focused = 1
local dst = C.new_state()
dst.columns = { { ids = { 9 }, heights = { 1.0 }, width = 1.0 } }
dst.adopting = { [1] = true, [2] = true }

C.reconcile(dst, { 9, 1 }, 9)          -- first window lands
check("first arrival makes one new column", shape(dst), "9 | 1")
C.reconcile(dst, { 9, 1, 2 }, 9)       -- second lands
check("second joins the same column", shape(dst), "9 | 1+2")
near("widths total 1", width_total(dst), 1.0)
check("adoption is finished", dst.adopting, nil)

print("...a late arrival is not mistaken for a new window")
dst = C.new_state()
dst.columns = { { ids = { 9 }, heights = { 1.0 }, width = 1.0 } }
dst.adopting = { [1] = true, [2] = true }
C.reconcile(dst, { 9, 1 }, 9)
C.reconcile(dst, { 9, 1 }, 9)          -- a reconcile with nothing new
check("the outstanding window is still expected", dst.adopting ~= nil, true)
C.reconcile(dst, { 9, 1, 2 }, 9)
check("and still joins the column when it lands", shape(dst), "9 | 1+2")

print("...without adoption they would be placed normally")
dst = C.new_state()
dst.columns = { { ids = { 9 }, heights = { 1.0 }, width = 1.0 } }
dst.focused = 9
C.reconcile(dst, { 9, 1 }, 9)
check("a lone column splits instead", shape(dst), "9 | 1")
C.reconcile(dst, { 9, 1, 2 }, 9)
check("then stacks on the focused column", shape(dst), "9+2 | 1")

-- A returned string is an error, and Hyprland puts it on screen. Pressing a
-- focus key on a desktop with nothing on it is ordinary, so it has to come back
-- as handled-and-did-nothing rather than as a complaint.
print("scenario: keys pressed on an empty desktop")
local empty = { targets = {} }
check("focus is silently ignored", _G.__provider.layout_msg(empty, "focus l"), true)
check("so is moving a window",     _G.__provider.layout_msg(empty, "movewin up"), true)
check("so is resizing a column",   _G.__provider.layout_msg(empty, "colresize 0.05"), true)

-- deskbinds calls this when a desktop goes: workspace ids are reused, so a
-- layout left behind would be inherited by the next desktop given that id.
print("scenario: a desktop's layout is forgotten with the desktop")
-- The layout table itself is private, so what can be checked from out here is
-- that deskbinds has something to call and that calling it is harmless for a
-- desktop with no layout -- which is the common case, since most desktops
-- never had one.
check("forget is exported for deskbinds to call", type(C.forget), "function")
check("forgetting an unknown desktop is harmless", pcall(C.forget, 12345), true)

-- The crossing itself: a focus or a move that runs out of room left or right
-- hands over to the screen beside, through the hook deskbinds sets. The layout
-- owns one workspace's windows, so the "next screen" is a workspace id the
-- hook returns; here it is a fixed desktop with its own two windows.
print("scenario: focus at the edge crosses to the screen beside")
local function ctx_for(ws_id, active_id, list)
    _G.__windows = {}
    local targets = {}
    for i, entry in ipairs(list) do
        local win = {
            stable_id = entry.id, address = "0x" .. entry.id,
            active = entry.id == active_id, workspace = { id = ws_id },
        }
        _G.__windows[#_G.__windows + 1] = win
        targets[i] = { window = win, place = function() end }
    end
    return { targets = targets, area = { x = 0, y = 0, w = 100, h = 100 } }
end

-- A real desktop is placed by recalculate before any key is pressed, and the
-- layout state is built there; layout_msg only acts on state it has.
local function laid_out(ws_id, active_id, list)
    local ctx = ctx_for(ws_id, active_id, list)
    _G.__provider.recalculate(ctx)
    return ctx
end

local crossed_to
C.set_screen_step(function(ws, dir) crossed_to = { ws = ws, dir = dir } return 77 end)
C.set_screen_focus(function(ws, dir) crossed_to = { ws = ws, dir = dir } return 77 end)

_G.__dispatched = {}
crossed_to = nil
local ctx = laid_out(101, 1, { { id = 1 }, { id = 2 } })
check("focus right inside the desktop is handled", _G.__provider.layout_msg(ctx, "focus r"), true)
check("...and does not cross", crossed_to, nil)
check("...by focusing the neighbour", _G.__dispatched[1] and _G.__dispatched[1].kind, "focus")

-- The rightmost column has nothing to the right, so focus crosses instead of
-- wrapping back to the left of the same screen.
_G.__dispatched = {}
crossed_to = nil
ctx = laid_out(105, 2, { { id = 1 }, { id = 2 } })
_G.__provider.layout_msg(ctx, "focus r")
check("focus right at the edge crosses, not wraps", crossed_to and crossed_to.dir, "next")

-- A single window leaves nowhere to go to the right, so focus steps onto the
-- next screen.
_G.__dispatched = {}
crossed_to = nil
ctx = laid_out(102, 1, { { id = 1 } })
check("focus right at the edge is handled", _G.__provider.layout_msg(ctx, "focus r"), true)
check("...and asks for the screen beside", crossed_to and crossed_to.dir, "next")
check("...from this desktop", crossed_to and crossed_to.ws, 102)
check("...and focuses that screen's desktop", _G.__dispatched[1] and _G.__dispatched[1].kind, "focus")
check("...by workspace", _G.__dispatched[1] and _G.__dispatched[1].arg.workspace, 77)

crossed_to = nil
_G.__dispatched = {}
_G.__provider.layout_msg(ctx, "focus l")
check("focus left asks the other way", crossed_to and crossed_to.dir, "prev")

-- Up and down still wrap inside the column and never cross screens.
crossed_to = nil
_G.__provider.layout_msg(ctx, "focus u")
check("vertical focus does not cross", crossed_to, nil)

print("scenario: a window alone at the edge moves to the screen beside")
_G.__dispatched = {}
crossed_to = nil
ctx = laid_out(103, 1, { { id = 1 } })
check("moving right is handled", _G.__provider.layout_msg(ctx, "movecol next"), true)
check("...and asks for the screen to the right", crossed_to and crossed_to.dir, "next")
check("...and moves the window there", _G.__dispatched[1] and _G.__dispatched[1].kind, "move")
check("...addressed to that desktop", _G.__dispatched[1] and _G.__dispatched[1].arg.workspace, 77)
check("...by address", _G.__dispatched[1] and _G.__dispatched[1].arg.window, "address:0x1")
-- The window leaves this desktop's layout at once, so it is gone from it.
local stc = C.new_state()
stc.columns = { { ids = { 1 }, heights = { 1.0 }, width = 1.0 } }
C.expect_arrival(stc, 1, "last")
C.reconcile(stc, {}, nil)
check("and it is removed from this desktop", #stc.columns, 0)

print("scenario: a stack at the edge does not cross, it splits")
-- Two windows in the leftmost column: moving left makes a new column to the
-- left rather than sending one window to the other screen. The state is built
-- by reconciling, so the leftmost column really holds a stack.
_G.__dispatched = {}
crossed_to = nil
ctx = laid_out(104, 1, { { id = 1 } })
ctx = laid_out(104, 2, { { id = 1 }, { id = 2 } })
ctx = laid_out(104, 1, { { id = 1 }, { id = 2 }, { id = 3 } })
check("moving left from a stack is handled", _G.__provider.layout_msg(ctx, "movecol prev"), true)
check("...and does not cross screens", crossed_to, nil)
check("...and dispatches nothing", #_G.__dispatched, 0)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
