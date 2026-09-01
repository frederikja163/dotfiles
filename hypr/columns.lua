-- Column behaviour on top of the built-in scrolling layout
-- (roadmap.md lines 14-31).
--
-- Model:
--   * a desktop is a horizontal tape of columns
--   * each column stacks windows vertically
--   * windows ALWAYS open in the currently focused column
--   * M+n takes the focused window out into a new column of its own
--
-- So the order for creating a column is M+q then M+n, not the other way round.
--
-- The scrolling layout does the hard parts (tape, viewport scrolling, stacking,
-- fullscreen). This module supplies the two behaviours it does not have:
-- new windows joining the current column, and the new-column width rule.

local programs = require("programs")
local mainMod = programs.mainMod

local GAP = 4 -- px tolerance when deciding whether two edges line up

local function layout_msg(msg)
    hl.dispatch(hl.dsp.layout(msg))
end

-- Tiled (non-floating) windows on a workspace.
local function tiled_windows(ws)
    local out = {}
    if not ws then
        return out
    end

    for _, w in ipairs(hl.get_windows({ workspace = ws.id }) or {}) do
        if not w.floating then
            table.insert(out, w)
        end
    end
    return out
end

-- Group windows into columns by x position. Windows sharing a left edge (within
-- GAP) are in the same column. Returns a list of { x, width, windows }, ordered
-- left to right.
local function columns_of(ws)
    local cols = {}

    for _, w in ipairs(tiled_windows(ws)) do
        local x, width = w.at.x, w.size.x

        local found
        for _, c in ipairs(cols) do
            if math.abs(c.x - x) <= GAP then
                found = c
                break
            end
        end

        if found then
            table.insert(found.windows, w)
            -- Keep the widest reading; they should all agree.
            found.width = math.max(found.width, width)
        else
            table.insert(cols, { x = x, width = width, windows = { w } })
        end
    end

    -- Windows inside a column top to bottom, columns left to right.
    for _, c in ipairs(cols) do
        table.sort(c.windows, function(a, b) return a.at.y < b.at.y end)
    end
    table.sort(cols, function(a, b) return a.x < b.x end)
    return cols
end

local function column_containing(cols, win)
    if not win then
        return nil
    end

    for _, c in ipairs(cols) do
        for _, w in ipairs(c.windows) do
            if w.address == win.address then
                return c
            end
        end
    end
end

local function all_same_width(cols)
    if #cols < 2 then
        return true
    end

    local first = cols[1].width
    for _, c in ipairs(cols) do
        if math.abs(c.width - first) > GAP then
            return false
        end
    end
    return true
end

-- colresize takes a fraction of the usable width. Window geometry is in
-- logical pixels, so the monitor's pixel width has to be divided by its scale.
-- The remaining error from gaps and borders is under 2%, which is invisible for
-- a "half of the selected column" rule.
local function usable_width(mon)
    if not mon then
        return nil
    end

    local scale = (mon.scale and mon.scale > 0) and mon.scale or 1
    return mon.width / scale
end

local function clamp_fraction(f)
    return math.max(0.1, math.min(1.0, f))
end

-- M+n: move the focused window into a new column of its own.
--
--   if every column is the same width -> add and re-even all of them
--   otherwise                         -> the new column takes half the width
--                                        of the column it came from
local function new_column()
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws or ws.special then
        return
    end

    local cols = columns_of(ws)
    local source = column_containing(cols, win)

    -- Already alone in its column: there is nothing to split out.
    if not source or #source.windows < 2 then
        return
    end

    local even = all_same_width(cols)
    local usable = usable_width(win.monitor)
    local source_fraction = usable and (source.width / usable) or nil

    layout_msg("promote")

    if even then
        -- One more column than before, all equal.
        layout_msg(("colresize all %.3f"):format(1.0 / (#cols + 1)))
    elseif source_fraction then
        layout_msg(("colresize %.3f"):format(clamp_fraction(source_fraction / 2)))
    end
end

-- New windows should join the focused column instead of opening as their own
-- column, which is what the scrolling layout does by default.
--
-- Measured behaviour, which differs from the wiki: a new window is inserted as
-- its own column immediately to the RIGHT of the focused column, and takes
-- focus. `consume` pulls a window in from the *next* column (it fails with
-- "no next column" on the last one), so it is the wrong tool here and merges an
-- unrelated window. `consume_or_expel prev` moves the current window into the
-- previous column instead, which is the focused one, and appends it to the
-- bottom of that column.
-- A window is first placed in a column of its own, and bringing that column
-- into view scrolls the tape right. The column then disappears into its
-- neighbour, but the scroll is not undone, so the columns to the left slide off
-- screen. Inhibiting the scroll has to happen in open_early: by the time
-- window.open fires the tape has already moved.
hl.on("window.open_early", function()
    layout_msg("inhibit_scroll true")

    -- Never leave the workspace stuck with scrolling disabled, e.g. if the
    -- window never finishes opening.
    hl.timer(function()
        layout_msg("inhibit_scroll false")
    end, { timeout = 1000, type = "oneshot" })
end)

hl.on("window.open", function(win)
    -- Whatever happens below, scrolling must be re-enabled.
    local function done()
        layout_msg("inhibit_scroll false")
    end

    win = win or hl.get_active_window()
    if not win or win.floating then
        return done()
    end

    -- Only act on the window that actually has focus, so windows opening
    -- unfocused (see the no_focus rule in windowrules.lua) are left alone.
    local active = hl.get_active_window()
    if not active or active.address ~= win.address then
        return done()
    end

    local ws = win.workspace
    if not ws or ws.special then
        return done()
    end

    -- Nothing to merge into if this is the only window.
    if #tiled_windows(ws) < 2 then
        return done()
    end

    -- consume_or_expel expels instead of consuming when the window is not
    -- alone in its column, which would be the exact opposite of what we want.
    -- A freshly opened window always is alone, so bail out if that is somehow
    -- not the case rather than risk pushing it out again.
    local own = column_containing(columns_of(ws), win)
    if not own or #own.windows ~= 1 then
        return done()
    end

    layout_msg("consume_or_expel prev")
    layout_msg("inhibit_scroll false")
end)

-- M+m: cycle windows through the "main slot", which is simply whichever column
-- is currently the biggest.
--
--   focused window is NOT the biggest -> swap it into the main slot, so what
--                                        you are looking at becomes the big one
--   focused window IS the biggest     -> pull the next window into the main
--                                        slot and follow it with focus
--
-- Because focus follows the main slot rather than the window, repeated presses
-- flip through every window while the big one always stays highlighted. A
-- per-desktop index walks along the candidate list so it visits all of them
-- instead of ping-ponging between two.

-- Move the focused window into the column next to it.
--
-- Measured behaviour of `consume_or_expel <dir>`:
--
--            | window alone in its column | window not alone
--   prev     | merges into the left column | expels into a NEW column on the left
--   next     | merges into the right column | expels into a NEW column on the right
--
-- So a window that shares its column needs two messages: the first pulls it out
-- into a column of its own on that side, the second merges it into the
-- neighbour. A window already on its own only needs one.
local function move_between_columns(dir)
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws or ws.special then
        return
    end

    local cols = columns_of(ws)
    local own, own_index
    for i, c in ipairs(cols) do
        for _, w in ipairs(c.windows) do
            if w.address == win.address then
                own, own_index = c, i
                break
            end
        end
    end

    if not own then
        return
    end

    local neighbour = cols[dir == "prev" and own_index - 1 or own_index + 1]
    local alone = #own.windows == 1

    -- Alone at the edge of the tape: nowhere to go.
    if alone and not neighbour then
        return
    end

    layout_msg("consume_or_expel " .. dir)

    -- The first message only expelled it into a column of its own. Merge it
    -- into the neighbour, if there was one.
    if not alone and neighbour then
        layout_msg("consume_or_expel " .. dir)
    end
end

local main_cycle = {} -- [workspace id] = { count = n, idx = i }

-- Windows in a stable order: left to right by column, top to bottom inside it.
local function stable_order(ws)
    local wins = tiled_windows(ws)
    table.sort(wins, function(a, b)
        if math.abs(a.at.x - b.at.x) > GAP then
            return a.at.x < b.at.x
        end
        return a.at.y < b.at.y
    end)
    return wins
end

-- The main slot is the widest column, not the largest window. A column split
-- between two windows gives each of them a small height, so comparing window
-- areas picks the wrong thing and ties between siblings in the same column.
-- Leftmost wins a tie, which keeps the choice stable when columns are even.
local function main_column(cols)
    local best
    for _, c in ipairs(cols) do
        if not best or c.width > best.width + GAP then
            best = c
        end
    end
    return best
end

local function in_column(col, win)
    if not (col and win) then
        return false
    end

    for _, w in ipairs(col.windows) do
        if w.address == win.address then
            return true
        end
    end
    return false
end

local function swap_with(win)
    -- The swap dispatcher takes direction/target/next/prev, and a target has to
    -- be a window selector, hence the "address:" prefix.
    hl.dispatch(hl.dsp.window.swap({ target = "address:" .. win.address }))
end

local function focus_win(win)
    hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
end

local function cycle_main()
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws then
        return
    end

    local wins = stable_order(ws)
    if #wins < 2 then
        return
    end

    local cols = columns_of(ws)
    local main = main_column(cols)
    if not main or #cols < 2 then
        return -- a single column is already "main", nothing to cycle through
    end

    -- Not in the main column yet: move this window there. Focus travels with
    -- the window, so it ends up in the main slot without an explicit focus call.
    if not in_column(main, win) then
        swap_with(main.windows[1])
        main_cycle[ws.id] = { count = #wins, idx = 1 }
        return
    end

    -- Already in the main column: bring in the next window from elsewhere.
    -- Windows sharing the main column are skipped, since swapping with a
    -- sibling would change nothing visible.
    local candidates = {}
    for _, w in ipairs(wins) do
        if not in_column(main, w) then
            table.insert(candidates, w)
        end
    end

    if #candidates == 0 then
        return
    end

    local state = main_cycle[ws.id]
    if not state or state.count ~= #wins then
        state = { count = #wins, idx = 1 }
    end

    local pick = candidates[((state.idx - 1) % #candidates) + 1]
    state.idx = state.idx + 1
    main_cycle[ws.id] = state

    swap_with(pick)
    -- pick now occupies the main slot, so follow it rather than staying with
    -- the window that was just moved out.
    focus_win(pick)
end

hl.bind(mainMod .. " + N", new_column,
        { description = "Move window to a new column" })

-- Horizontal window management is column-based, so it lives here rather than in
-- keybinds.lua with the focus binds.
--   mainMod + SHIFT + h/l  move the window into the neighbouring column
--   mainMod + ALT   + h/l  swap the whole column with its neighbour
local horizontal = {
    { keys = { "H", "left"  }, dir = "prev", swapcol = "l", label = "left"  },
    { keys = { "L", "right" }, dir = "next", swapcol = "r", label = "right" },
}

for _, h in ipairs(horizontal) do
    for _, key in ipairs(h.keys) do
        hl.bind(mainMod .. " + SHIFT + " .. key, function()
            move_between_columns(h.dir)
        end, { repeating = true, description = "Move window to the column " .. h.label })

        hl.bind(mainMod .. " + ALT + " .. key, hl.dsp.layout("swapcol " .. h.swapcol),
                { repeating = true, description = "Swap column with the one to the " .. h.label })
    end
end

hl.bind(mainMod .. " + M", cycle_main,
        { description = "Cycle window through the main (biggest) column" })

return {
    columns_of = columns_of,
    all_same_width = all_same_width,
    new_column = new_column,
    cycle_main = cycle_main,
    move_between_columns = move_between_columns,
    stable_order = stable_order,
    main_column = main_column,
}
