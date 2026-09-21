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

-- Windows handed over from another workspace arrive one at a time. They are
-- remembered in st.adopting so that each one joins a single shared column as it
-- turns up, instead of being placed as an unrelated new window.
local function adopt(st, id)
    local ci = st.adopt_anchor and locate(st, st.adopt_anchor)

    if ci then
        local col = st.columns[ci]
        table.insert(col.ids, id)
        table.insert(col.heights, 1 / #col.ids)
        normalize_heights(col)
    else
        table.insert(st.columns, { ids = { id }, heights = { 1.0 }, width = 1 })
        st.adopt_anchor = id
    end

    st.adopting[id] = nil
    if next(st.adopting) == nil then
        st.adopting = nil
        st.adopt_anchor = nil
    end

    normalize_widths(st)
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

-- A window on its way in from the screen beside this one. It lands at the
-- edge it came in at, as a column of its own, instead of by the usual
-- placement rules -- which would drop it wherever the focused window happens
-- to be, nowhere near the side it crossed from.
--
-- The move is a dispatch, so the destination only learns the window is coming
-- by being told here; `arriving` is read and cleared by the reconcile that
-- sees the window for the first time.
local function expect_arrival(st, id, side)
    st.arriving = { id = id, side = side }
end

local function insert_edge(st, id, side)
    if #st.columns == 0 then
        st.columns[1] = { ids = { id }, heights = { 1.0 }, width = 1.0 }
        return
    end

    local at = side == "first" and 1 or (#st.columns + 1)
    local col = st.columns[side == "first" and 1 or #st.columns]
    local fresh = { ids = { id }, heights = { 1.0 }, width = col.width / 2 }
    col.width = col.width / 2
    table.insert(st.columns, at, fresh)
    normalize_widths(st)
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
            if st.arriving and st.arriving.id == id then
                insert_edge(st, id, st.arriving.side)
                st.arriving = nil
            elseif st.adopting and st.adopting[id] then
                adopt(st, id)
            else
                insert(st, id)
            end
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

-- Move the focused window onto the screen beside this one.
--
-- The window leaves this desktop's layout at once, and the screen it lands on
-- is told to expect it so it becomes a column of its own at the near edge.
-- Which edge is "near" follows the reading order of the screens: a window
-- pushed left joins the right side of the screen on the left (and the other
-- way round), so stepping off an end wraps to that same far side.
--
-- Returns false when there is no window to address, which is the only reason
-- the caller's target can go unused.
local function move_window_to_screen(st, id, dir, target_ws)
    local address
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.stable_id == id then
            address = w.address
            break
        end
    end
    if not address then
        return false
    end

    expect_arrival(for_workspace(target_ws), id, dir == "prev" and "last" or "first")
    remove(st, id)

    hl.dispatch(hl.dsp.window.move({
        workspace = target_ws,
        window = "address:" .. address,
    }))
    return true
end

-- Whether the focused window's column is the outermost one on `dir`'s side,
-- which is where this desktop meets the screen beside it.
local function at_edge(st, id, dir)
    local ci = locate(st, id)
    if not ci then
        return false
    end
    if dir == "prev" then
        return ci == 1
    end
    if dir == "next" then
        return ci == #st.columns
    end
    return false
end

local function alone_in_column(st, id)
    local ci = locate(st, id)
    return ci ~= nil and #st.columns[ci].ids == 1
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

-- The window that focus should move to within the desktop.
--
-- Up and down wrap inside the column: with two windows stacked there, stepping
-- down from the bottom one lands on the top one, which is how a short list is
-- navigated. Left and right do *not* wrap -- running out of columns left or
-- right returns nothing, which is the signal for the caller to cross to the
-- screen beside. Wrapping there was the old behaviour and it is exactly wrong
-- once the desktops are ordered left to right: focus at the leftmost column
-- would jump to the far right of the same screen instead of going left.
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

    local to = dir == "prev" and ci - 1 or ci + 1
    if to < 1 or to > #st.columns then
        return nil
    end

    -- Keep roughly the same height in the new column.
    local col = st.columns[to]
    return col.ids[math.min(wi, #col.ids)]
end

-- Hand the focused window's whole column over to another workspace.
--
-- Windows have to be moved one at a time, so the destination is seeded with the
-- column first: otherwise each arrival would be treated as a new window and be
-- scattered by the usual placement rules. Focus follows a moved window, so it
-- is put back on the window that had it once they have all arrived.
--
-- Returns true if a column was moved.
local function move_column_to_workspace(from_ws, to_ws, focused_id)
    if not (from_ws and to_ws) or from_ws == to_ws then
        return false
    end

    local src = state[from_ws]
    if not src then
        return false
    end

    local ci = locate(src, focused_id)
    if not ci then
        return false
    end

    local ids = {}
    for i, wid in ipairs(src.columns[ci].ids) do
        ids[i] = wid
    end

    -- stable ids are what the layout works in, but the dispatcher wants a
    -- window selector.
    local address = {}
    for _, w in ipairs(hl.get_windows() or {}) do
        if w.stable_id then
            address[w.stable_id] = w.address
        end
    end

    -- Tell the destination what is coming. Seeding it with a real column
    -- instead would be worse than useless: the first arrival triggers a
    -- reconcile there, which would drop every window that has not landed yet --
    -- and, if that column shared this table, shorten the list being iterated
    -- below.
    local dst = for_workspace(to_ws)
    dst.adopting = {}
    dst.adopt_anchor = nil
    for _, wid in ipairs(ids) do
        dst.adopting[wid] = true
    end

    table.remove(src.columns, ci)
    normalize_widths(src)

    for _, wid in ipairs(ids) do
        local a = address[wid]
        if a then
            hl.dispatch(hl.dsp.window.move({ workspace = to_ws, window = "address:" .. a }))
        end
    end

    if address[focused_id] then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. address[focused_id] }))
    end

    return true
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

-- Which screen to cross to, set by deskbinds when it loads. The layout cannot
-- look this up itself: it has no access to the pin file or the monitor slots,
-- and it works in workspace ids while a screen is something else entirely.
-- Until it is set -- the stubbed tests, or a config that failed part way --
-- a focus or a move at the edge stays inside the desktop, as it always did.
--
-- Both are called as fn(from_ws, dir) and answer a workspace id, or nil for
-- "do not cross". `from_ws` is the desktop being stepped off, so the hook can
-- work out which *screen* that is; it must be passed rather than left to the
-- hook to look up, because follow_mouse means the focused monitor is wherever
-- the pointer rests and not necessarily the screen being laid out. It is nil
-- only where there is genuinely no id to give -- an empty desktop, which
-- carries no window and so no workspace -- and the hook falls back to the
-- screen in front for that one case.
--
-- Two hooks rather than one because a move and a focus could reasonably want
-- different screens: a move goes to the screen beside however empty it is,
-- since the window is what makes the desktop, whereas a focus landing on a
-- bare screen has nothing to focus. deskbinds currently gives both the same
-- function, so they behave identically; the split is kept because it costs
-- nothing and is the seam where that would change.
local screen_step = nil
local screen_focus = nil

local function set_screen_step(fn)
    screen_step = fn
end

local function set_screen_focus(fn)
    screen_focus = fn
end

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

        -- An empty desktop carries no targets, so there is no workspace to key
        -- the state on -- but a horizontal focus is still meaningful there: it
        -- steps onto the screen beside, which is what keeps an empty desktop
        -- from being a dead end. There is no focused window to move, though, so
        -- everything else stays handled-and-did-nothing.
        if not ws then
            if command == "focus" and screen_focus then
                local dir = ({ l = "prev", r = "next" })[arg]
                if dir then
                    -- nil workspace, deliberately: there is no id to give,
                    -- and that is the signal for the hook to fall back to
                    -- the screen in front. See edge_workspace in deskbinds.
                    local target_ws = screen_focus(nil, dir)
                    if target_ws then
                        hl.dispatch(hl.dsp.focus({ workspace = target_ws }))
                    end
                end
            end
            return true
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
            if to then
                local win = windows[to]
                if win and win.address then
                    st.focused = to
                    hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
                end
            elseif (dir == "prev" or dir == "next") and screen_focus then
                -- Nothing on this desktop that way, so the focus steps onto
                -- the screen beside it, landing on that screen's own desktop
                -- even when it is empty. The point is to keep moving: the next
                -- press carries on from there, and the opposite direction
                -- comes straight back.
                local target_ws = screen_focus(ws, dir)
                if target_ws then
                    hl.dispatch(hl.dsp.focus({ workspace = target_ws }))
                end
            end
        elseif command == "newcol" then
            new_column(st, id)
        elseif command == "movecol" then
            local dir = arg == "prev" and "prev" or "next"
            -- A window alone in the outermost column has no neighbour to join,
            -- so it crosses to the screen beside. A stack at the edge keeps
            -- its existing behaviour: it splits off a new column inward.
            if (dir == "prev" or dir == "next") and at_edge(st, id, dir)
               and alone_in_column(st, id) and screen_step then
                local target_ws = screen_step(ws, dir)
                if target_ws then
                    move_window_to_screen(st, id, dir, target_ws)
                end
            else
                move_to_column(st, id, dir)
            end
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

-- Keys live in modes.lua. The layout messages below are this file's public
-- interface to them, and to `hyprctl dispatch 'hl.dsp.layout("...")'`:
--
--   focus l|r|u|d      move the focus
--   movecol prev|next  move the focused window to the column beside it
--   movewin up|down    move it within its column
--   swapcol prev|next  move the whole column
--   colresize <f>      widen/narrow the column by a fraction of the screen
--   rowresize <f>      grow/shrink the window within its column
--   cyclemain          promote through the widest column
--   newcol             give the focused window a column of its own
--
-- A focus or a move that runs out of room left or right crosses to the screen
-- beside, through the screen_step hook deskbinds sets at load. Up and down
-- still wrap inside the column, and the other messages are desktop-local.
--
-- There is no bind for "newcol": moving a window past the last column already
-- gives it one. The message stays for dispatching by hand.

-- Forget a desktop's layout. Called by deskbinds when the desktop goes, since
-- workspace ids are reused and the next desktop given this one would otherwise
-- inherit its columns.
local function forget(ws)
    state[ws] = nil
end

-- Exported for tests: all of these work on a plain state table.
return {
    forget = forget,
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
    move_column_to_workspace = move_column_to_workspace,
    move_window_to_screen = move_window_to_screen,
    expect_arrival = expect_arrival,
    insert_edge = insert_edge,
    at_edge = at_edge,
    alone_in_column = alone_in_column,
    set_screen_step = set_screen_step,
    set_screen_focus = set_screen_focus,
    neighbour = neighbour,
    MIN = MIN,
}
