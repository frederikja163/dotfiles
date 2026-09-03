-- Column layout (roadmap.md, "Desktop setup").
--
-- A desktop is a row of columns; each column is a stack of windows. The
-- columns always fill the monitor exactly, because this layout is the thing
-- that decides where every window goes: `recalculate` divides the work area up
-- and places each window itself. There is no scrolling and nothing to correct
-- afterwards.
--
-- Everything is kept in one table, `state`, keyed by workspace:
--
--   state[ws] = { columns = { { ids = { window ids }, heights = { fractions },
--                              width = fraction }, ... },
--                 focused = window id }
--
-- Widths add up to 1.0, and so do the heights within a column. Windows are
-- referred to by `stable_id`, which survives being moved about.
--
-- The pure state functions are exported at the bottom so they can be tested
-- without a compositor.

local programs = require("programs")
local mainMod = programs.mainMod

local MIN = 0.08 -- smallest column or row, as a fraction

local state = {}

----------------------------------------------------------------------------
-- Fractions
----------------------------------------------------------------------------

local function sum(list)
    local total = 0
    for _, v in ipairs(list) do
        total = total + v
    end
    return total
end

-- Scale a list so it adds up to exactly 1, giving everything at least MIN.
local function to_unit(list)
    local n = #list
    if n == 0 then
        return {}
    end

    if n * MIN >= 1 then
        local even = {}
        for i = 1, n do
            even[i] = 1 / n
        end
        return even
    end

    local total = sum(list)
    local out = {}

    if total <= 0 then
        for i = 1, n do
            out[i] = 1 / n
        end
        return out
    end

    for i, v in ipairs(list) do
        out[i] = v / total
    end

    -- Pin anything below the floor, then share the rest out in proportion.
    local budget, free = 1.0, 0
    local pinned = {}
    for i, v in ipairs(out) do
        if v < MIN then
            pinned[i] = true
            budget = budget - MIN
        else
            free = free + v
        end
    end

    for i, v in ipairs(out) do
        if pinned[i] then
            out[i] = MIN
        elseif free > 0 then
            out[i] = budget * v / free
        end
    end

    return out
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------

local function new_state()
    return { columns = {}, focused = nil }
end

local function for_workspace(ws)
    if not state[ws] then
        state[ws] = new_state()
    end
    return state[ws]
end

-- Which column holds a window, and where in it.
local function locate(st, id)
    for ci, col in ipairs(st.columns) do
        for wi, wid in ipairs(col.ids) do
            if wid == id then
                return ci, wi
            end
        end
    end
end

local function normalize_widths(st)
    local widths = {}
    for i, col in ipairs(st.columns) do
        widths[i] = col.width or 0
    end
    widths = to_unit(widths)
    for i, col in ipairs(st.columns) do
        col.width = widths[i]
    end
end

local function normalize_heights(col)
    local heights = {}
    for i = 1, #col.ids do
        heights[i] = (col.heights and col.heights[i]) or 0
    end
    heights = to_unit(heights)
    col.heights = heights
end

local function drop_empty(st)
    for i = #st.columns, 1, -1 do
        if #st.columns[i].ids == 0 then
            table.remove(st.columns, i)
        end
    end
    normalize_widths(st)
end

-- Put a window into a column, sized the way new columns are sized.
--
--   all rows the same height -> even them out again
--   otherwise                -> the focused row gives up half its height
--
-- The window lands directly below the focused one, so it appears where the
-- attention already is. Naively appending a row of 1/n and rescaling is what
-- made a second window take a third of the column instead of half.
local function add_to_column(col, id, focused)
    local even = true
    for i = 2, #col.heights do
        if math.abs(col.heights[i] - col.heights[1]) > 0.005 then
            even = false
            break
        end
    end

    local at
    for i, wid in ipairs(col.ids) do
        if wid == focused then
            at = i
            break
        end
    end

    local position = at and (at + 1) or (#col.ids + 1)
    table.insert(col.ids, position, id)

    if even then
        local n = #col.ids
        col.heights = {}
        for i = 1, n do
            col.heights[i] = 1 / n
        end
        return
    end

    if at then
        local half = col.heights[at] / 2
        col.heights[at] = half
        table.insert(col.heights, at + 1, half)
    else
        table.insert(col.heights, position, 1 / #col.ids)
        normalize_heights(col)
    end
end

-- Add a window.
--
-- With nothing there yet it becomes the first column. With exactly one column
-- it starts a second one: a lone column means the desktop is not really split
-- up yet, so the useful thing is to put the new window beside what is already
-- there rather than stacking on top of it. Once there are two or more columns
-- the split is deliberate, and new windows join the focused column at the
-- bottom.
local function insert(st, id)
    if #st.columns == 0 then
        st.columns[1] = { ids = { id }, heights = { 1.0 }, width = 1.0 }
        return
    end

    if #st.columns == 1 then
        st.columns[1].width = 0.5
        table.insert(st.columns, { ids = { id }, heights = { 1.0 }, width = 0.5 })
        return
    end

    local target
    if st.focused then
        target = select(1, locate(st, st.focused))
    end
    target = target or #st.columns

    add_to_column(st.columns[target], id, st.focused)
end

local function remove(st, id)
    local ci, wi = locate(st, id)
    if not ci then
        return
    end

    local col = st.columns[ci]
    table.remove(col.ids, wi)
    if col.heights then
        table.remove(col.heights, wi)
    end

    if #col.ids == 0 then
        table.remove(st.columns, ci)
        normalize_widths(st)
    else
        normalize_heights(col)
    end
end

-- Bring the state in line with the windows Hyprland actually has.
local function reconcile(st, ids, active)
    local present = {}
    for _, id in ipairs(ids) do
        present[id] = true
    end

    -- Gone.
    local known = {}
    for _, col in ipairs(st.columns) do
        for _, id in ipairs(col.ids) do
            known[id] = true
        end
    end
    for id in pairs(known) do
        if not present[id] then
            remove(st, id)
        end
    end

    -- The focused window decides where new ones land, so it has to be updated
    -- before they are inserted -- but only if it is a window we already know,
    -- otherwise a new window would choose its own column.
    if active and known[active] then
        st.focused = active
    end

    -- New.
    for _, id in ipairs(ids) do
        if not known[id] then
            insert(st, id)
        end
    end

    if active then
        st.focused = active
    end

    if #st.columns > 0 then
        normalize_widths(st)
        for _, col in ipairs(st.columns) do
            normalize_heights(col)
        end
    end

    return st
end

----------------------------------------------------------------------------
-- Geometry
----------------------------------------------------------------------------

-- Boxes for every window, filling `area` exactly. The last column and the
-- bottom window of each take the rounding remainder, so nothing is lost.
local function boxes(st, area)
    local out = {}
    local x = area.x

    for ci, col in ipairs(st.columns) do
        local w
        if ci == #st.columns then
            w = area.x + area.w - x
        else
            w = math.floor(area.w * col.width + 0.5)
        end

        local y = area.y
        for wi, id in ipairs(col.ids) do
            local h
            if wi == #col.ids then
                h = area.y + area.h - y
            else
                h = math.floor(area.h * (col.heights[wi] or (1 / #col.ids)) + 0.5)
            end

            out[#out + 1] = { id = id, box = { x = x, y = y, w = w, h = h } }
            y = y + h
        end

        x = x + w
    end

    return out
end

----------------------------------------------------------------------------
-- Operations
----------------------------------------------------------------------------

-- Split the focused window out into a column of its own, just right of the one
-- it came from. Equal columns are evened out again; otherwise the source column
-- is halved, so the total does not change either way.
local function new_column(st, id)
    local ci, wi = locate(st, id)
    if not ci then
        return false
    end

    local col = st.columns[ci]
    if #col.ids < 2 then
        return false -- already alone
    end

    local even = true
    for _, c in ipairs(st.columns) do
        if math.abs(c.width - st.columns[1].width) > 0.005 then
            even = false
            break
        end
    end

    table.remove(col.ids, wi)
    if col.heights then
        table.remove(col.heights, wi)
    end
    normalize_heights(col)

    local fresh = { ids = { id }, heights = { 1.0 }, width = col.width / 2 }
    col.width = col.width / 2
    table.insert(st.columns, ci + 1, fresh)

    if even then
        for _, c in ipairs(st.columns) do
            c.width = 1 / #st.columns
        end
    end

    normalize_widths(st)
    return true
end

-- Move the focused window into the neighbouring column, or into a new one at
-- the edge.
local function move_to_column(st, id, dir)
    local ci, wi = locate(st, id)
    if not ci then
        return false
    end

    local col = st.columns[ci]
    local target = dir == "prev" and ci - 1 or ci + 1
    local alone = #col.ids == 1

    if target < 1 or target > #st.columns then
        if alone then
            return false -- already a column of its own at the edge
        end
        -- Pull it out into a new column beyond the current one.
        table.remove(col.ids, wi)
        normalize_heights(col)
        local at = dir == "prev" and ci or ci + 1
        table.insert(st.columns, at, { ids = { id }, heights = { 1.0 }, width = col.width / 2 })
        col.width = col.width / 2
        normalize_widths(st)
        return true
    end

    table.remove(col.ids, wi)
    if col.heights then
        table.remove(col.heights, wi)
    end

    add_to_column(st.columns[target], id, nil)

    if #col.ids == 0 then
        -- The column it left is gone; its width goes back into the pot.
        table.remove(st.columns, ci)
    else
        normalize_heights(col)
    end

    normalize_widths(st)
    return true
end

-- Move the focused window up or down inside its column.
local function move_in_column(st, id, dir)
    local ci, wi = locate(st, id)
    if not ci then
        return false
    end

    local col = st.columns[ci]
    local to = dir == "up" and wi - 1 or wi + 1
    if to < 1 or to > #col.ids then
        return false
    end

    col.ids[wi], col.ids[to] = col.ids[to], col.ids[wi]
    return true
end

-- Swap the focused window's whole column with its neighbour.
local function swap_column(st, id, dir)
    local ci = locate(st, id)
    if not ci then
        return false
    end

    local to = dir == "prev" and ci - 1 or ci + 1
    if to < 1 or to > #st.columns then
        return false
    end

    st.columns[ci], st.columns[to] = st.columns[to], st.columns[ci]
    return true
end

-- Widen or narrow the focused column. The other columns give up, or take back,
-- the difference in proportion, so the total stays at 1.
local function resize_column(st, id, delta)
    local ci = locate(st, id)
    if not ci or #st.columns < 2 then
        return false
    end

    local widths = {}
    for i, col in ipairs(st.columns) do
        widths[i] = col.width
    end

    local ceiling = 1.0 - MIN * (#widths - 1)
    local target = math.max(MIN, math.min(ceiling, widths[ci] + delta))
    if math.abs(target - widths[ci]) < 0.001 then
        return false
    end

    local others = sum(widths) - widths[ci]
    local remaining = 1.0 - target

    for i, v in ipairs(widths) do
        if i == ci then
            widths[i] = target
        elseif others > 0 then
            widths[i] = remaining * v / others
        else
            widths[i] = remaining / (#widths - 1)
        end
    end

    widths = to_unit(widths)
    for i, col in ipairs(st.columns) do
        col.width = widths[i]
    end
    return true
end

-- Taller or shorter inside the column, same idea.
local function resize_row(st, id, delta)
    local ci, wi = locate(st, id)
    if not ci then
        return false
    end

    local col = st.columns[ci]
    if #col.ids < 2 then
        return false
    end

    local heights = {}
    for i = 1, #col.ids do
        heights[i] = col.heights[i]
    end

    local ceiling = 1.0 - MIN * (#heights - 1)
    local target = math.max(MIN, math.min(ceiling, heights[wi] + delta))
    if math.abs(target - heights[wi]) < 0.001 then
        return false
    end

    local others = sum(heights) - heights[wi]
    local remaining = 1.0 - target

    for i, v in ipairs(heights) do
        if i == wi then
            heights[i] = target
        elseif others > 0 then
            heights[i] = remaining * v / others
        else
            heights[i] = remaining / (#heights - 1)
        end
    end

    col.heights = to_unit(heights)
    return true
end

-- The window that focus should move to, wrapping inside the desktop. Nothing
-- here ever leaves the monitor: other monitors are reached with the number keys.
local function neighbour(st, id, dir)
    local ci, wi = locate(st, id)
    if not ci then
        return nil
    end

    if dir == "up" or dir == "down" then
        local col = st.columns[ci]
        local n = #col.ids
        if n < 2 then
            return nil
        end
        local to = dir == "up" and wi - 1 or wi + 1
        if to < 1 then to = n end
        if to > n then to = 1 end
        return col.ids[to]
    end

    local n = #st.columns
    if n < 2 then
        return nil
    end
    local to = dir == "prev" and ci - 1 or ci + 1
    if to < 1 then to = n end
    if to > n then to = 1 end

    -- Keep roughly the same height in the new column.
    local col = st.columns[to]
    return col.ids[math.min(wi, #col.ids)]
end

-- Cycle windows through the widest column, keeping the focus on it.
local function cycle_main(st, id)
    if #st.columns < 2 then
        return false
    end

    local main = 1
    for i, col in ipairs(st.columns) do
        if col.width > st.columns[main].width + 0.005 then
            main = i
        end
    end

    local ci, wi = locate(st, id)
    if not ci then
        return false
    end

    if ci ~= main then
        -- Put the focused window in the main column, swapping with whatever is
        -- at the top of it.
        local top = st.columns[main].ids[1]
        st.columns[main].ids[1] = id
        st.columns[ci].ids[wi] = top
        return true
    end

    -- Already in the main column: bring the next window from elsewhere in.
    local candidates = {}
    for i, col in ipairs(st.columns) do
        if i ~= main then
            for _, wid in ipairs(col.ids) do
                candidates[#candidates + 1] = { col = i, id = wid }
            end
        end
    end
    if #candidates == 0 then
        return false
    end

    st.cycle = ((st.cycle or 0) % #candidates) + 1
    local pick = candidates[st.cycle]

    local pi, pwi = locate(st, pick.id)
    st.columns[main].ids[wi] = pick.id
    st.columns[pi].ids[pwi] = id
    st.focused = pick.id
    return true
end

----------------------------------------------------------------------------
-- Hyprland glue
----------------------------------------------------------------------------

hl.layout.register("columns", {
    recalculate = function(ctx)
        if #ctx.targets == 0 then
            return
        end

        -- ctx does not say which workspace this is, so take it from a window.
        local ws, ids, active = nil, {}, nil
        for _, t in ipairs(ctx.targets) do
            local win = t.window
            if win then
                ids[#ids + 1] = win.stable_id
                if win.active then
                    active = win.stable_id
                end
                if not ws and win.workspace then
                    ws = win.workspace.id
                end
            end
        end

        if not ws then
            -- Nothing to key the state on; fall back to even columns.
            local n = #ctx.targets
            for i, t in ipairs(ctx.targets) do
                t:place(ctx:column(i, n))
            end
            return
        end

        local st = reconcile(for_workspace(ws), ids, active)

        local by_id = {}
        for _, entry in ipairs(boxes(st, ctx.area)) do
            by_id[entry.id] = entry.box
        end

        for _, t in ipairs(ctx.targets) do
            local win = t.window
            local box = win and by_id[win.stable_id]
            if box then
                t:place(box)
            end
        end
    end,

    layout_msg = function(ctx, msg)
        local command, arg = msg:match("^(%S+)%s*(.*)$")

        -- Find the workspace and the focused window from the targets, and keep a
        -- way back from a window id to something focusable.
        local ws, id, windows = nil, nil, {}
        for _, t in ipairs(ctx.targets) do
            local win = t.window
            if win then
                windows[win.stable_id] = win
                if not ws and win.workspace then
                    ws = win.workspace.id
                end
                if win.active then
                    id = win.stable_id
                end
            end
        end

        if not ws then
            return "columns: no workspace"
        end

        local st = for_workspace(ws)
        id = id or st.focused
        if not id then
            return true
        end

        if command == "focus" then
            local dir = ({ l = "prev", r = "next", u = "up", d = "down" })[arg]
            if not dir then
                return "columns: focus expects l, r, u or d"
            end
            local to = neighbour(st, id, dir)
            local win = to and windows[to]
            if win and win.address then
                st.focused = to
                hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
            end
        elseif command == "newcol" then
            new_column(st, id)
        elseif command == "movecol" then
            move_to_column(st, id, arg == "prev" and "prev" or "next")
        elseif command == "movewin" then
            move_in_column(st, id, arg == "up" and "up" or "down")
        elseif command == "swapcol" then
            swap_column(st, id, arg == "prev" and "prev" or "next")
        elseif command == "colresize" then
            resize_column(st, id, tonumber(arg) or 0)
        elseif command == "rowresize" then
            resize_row(st, id, tonumber(arg) or 0)
        elseif command == "cyclemain" then
            cycle_main(st, id)
        else
            return "columns: expected focus, newcol, movecol, movewin, " ..
                   "swapcol, colresize, rowresize or cyclemain"
        end

        return true
    end,
})

----------------------------------------------------------------------------
-- Keybinds
----------------------------------------------------------------------------

-- No bind for "newcol": moving a window past the last column with
-- mainMod + SHIFT + h/l already puts it in a column of its own. The message is
-- still there for `hyprctl dispatch 'hl.dsp.layout("newcol")'`.
hl.bind(mainMod .. " + M", hl.dsp.layout("cyclemain"),
        { description = "Cycle window through the main (widest) column" })

local horizontal = {
    { keys = { "H", "left"  }, dir = "prev", label = "left",  step = -0.05, focus = "l" },
    { keys = { "L", "right" }, dir = "next", label = "right", step =  0.05, focus = "r" },
}

for _, h in ipairs(horizontal) do
    for _, key in ipairs(h.keys) do
        hl.bind(mainMod .. " + " .. key, hl.dsp.layout("focus " .. h.focus),
                { repeating = true, description = "Focus window " .. h.label })

        hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.layout("movecol " .. h.dir),
                { repeating = true, description = "Move window to the column " .. h.label })

        hl.bind(mainMod .. " + ALT + " .. key, hl.dsp.layout("swapcol " .. h.dir),
                { repeating = true, description = "Swap column with the one to the " .. h.label })

        hl.bind(mainMod .. " + CTRL + " .. key, hl.dsp.layout(("colresize %.2f"):format(h.step)),
                { repeating = true, description = "Resize column " .. h.label })
    end
end

local vertical = {
    { keys = { "J", "down" }, dir = "down", label = "down", step =  0.05, focus = "d" },
    { keys = { "K", "up"   }, dir = "up",   label = "up",   step = -0.05, focus = "u" },
}

for _, v in ipairs(vertical) do
    for _, key in ipairs(v.keys) do
        hl.bind(mainMod .. " + " .. key, hl.dsp.layout("focus " .. v.focus),
                { repeating = true, description = "Focus window " .. v.label })

        hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.layout("movewin " .. v.dir),
                { repeating = true, description = "Move window " .. v.label .. " in its column" })

        hl.bind(mainMod .. " + CTRL + " .. key, hl.dsp.layout(("rowresize %.2f"):format(v.step)),
                { repeating = true, description = "Resize window " .. v.label })
    end
end

-- Exported for tests: all of these work on a plain state table.
return {
    new_state = new_state,
    add_to_column = add_to_column,
    to_unit = to_unit,
    locate = locate,
    reconcile = reconcile,
    boxes = boxes,
    new_column = new_column,
    move_to_column = move_to_column,
    move_in_column = move_in_column,
    swap_column = swap_column,
    resize_column = resize_column,
    resize_row = resize_row,
    cycle_main = cycle_main,
    neighbour = neighbour,
    MIN = MIN,
}
