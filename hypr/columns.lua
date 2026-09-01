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

-- Width available to columns, in the same logical pixels window geometry uses.
--
--   monitor width / scale, minus the outer gaps and the borders on both sides
--
-- Verified against a lone column, which spans everything: eDP-1 is 1920 at
-- scale 1.5, so 1280 logical, and the column measures 1266 = 1280 - 2*5 - 2*2.
-- colresize fractions are relative to exactly this width.
local function usable_width(mon)
    if not mon then
        return nil
    end

    local scale = (mon.scale and mon.scale > 0) and mon.scale or 1

    local gap = 5
    local gaps = hl.get_config("general.gaps_out")
    if type(gaps) == "table" and tonumber(gaps.left) then
        gap = tonumber(gaps.left)
    elseif tonumber(gaps) then
        gap = tonumber(gaps)
    end

    local border = tonumber(hl.get_config("general.border_size")) or 2

    return (mon.width / scale) - 2 * gap - 2 * border
end

-- How much of the monitor the columns currently occupy, left edge of the first
-- to right edge of the last. Wider than usable_width means the tape scrolls.
local function span_of(cols)
    if #cols == 0 then
        return 0
    end

    local last = cols[#cols]
    return (last.x + last.width) - cols[1].x
end

-- Fraction of the monitor still free. Negative if the columns already overflow.
local function free_fraction(cols, usable)
    if not usable or usable <= 0 then
        return 0
    end
    return (usable - span_of(cols)) / usable
end

local MIN_COLUMN = 0.1

local function clamp_fraction(f)
    return math.max(MIN_COLUMN, math.min(1.0, f))
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

    -- Splitting a window out adds a column, so it has to come out of the space
    -- that is left. Work out how wide it may be before moving anything.
    local wanted, room
    if usable then
        wanted = (source.width / usable) / 2
        room = free_fraction(cols, usable)
    end

    layout_msg("promote")

    if even or not usable or room < MIN_COLUMN then
        -- Either the columns were all equal anyway, or there is not enough room
        -- left for a sensibly sized column. Re-even them: n columns at 1/n
        -- always fills the monitor exactly and never overflows it.
        layout_msg(("colresize all %.3f"):format(1.0 / (#cols + 1)))
    else
        -- Half the source column, but never more than the free space, so the
        -- columns stay inside the monitor.
        layout_msg(("colresize %.3f"):format(clamp_fraction(math.min(wanted, room))))
    end
end

-- Bring the columns back inside the monitor if they are somehow wider than it.
--
-- Nothing in this file can create an overflow -- new columns and resizes are
-- both capped -- but one can arrive from outside: a workspace moved to a
-- smaller monitor, a `colresize` from hyprctl, a monitor that changed scale.
-- `fit all` evens the columns out and makes them fill the monitor exactly,
-- which is the only cheap way back into bounds.
local function enforce_bounds()
    local mon = hl.get_active_monitor()
    local ws = mon and mon.active_workspace
    if not ws or ws.special then
        return
    end

    local cols = columns_of(ws)
    if #cols < 2 then
        return -- a lone column is capped at the full width already
    end

    local usable = usable_width(mon)
    if not usable then
        return
    end

    -- A pixel of slack: widths are rounded, so exact equality is not reliable.
    if span_of(cols) > usable + 1 then
        layout_msg("fit all")
    end
end

-- Grow or shrink the focused column, without letting the columns spill past the
-- edge of the monitor: growing is capped at the space that is actually free.
-- Once the monitor is full, growing does nothing -- shrink another column first.
local function resize_column(delta)
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws or ws.special then
        return
    end

    local cols = columns_of(ws)
    local own = column_containing(cols, win)
    local usable = usable_width(win.monitor)
    if not own or not usable or usable <= 0 then
        return
    end

    local current = own.width / usable

    if delta > 0 then
        local room = free_fraction(cols, usable)
        if room <= 0 then
            return -- already filling the monitor
        end
        delta = math.min(delta, room)
    end

    local target = clamp_fraction(current + delta)
    if math.abs(target - current) < 0.001 then
        return
    end

    layout_msg(("colresize %.3f"):format(target))
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
    enforce_bounds()
end)

-- The column geometry can also change without any of the binds being used.
for _, event in ipairs({ "workspace.active", "window.close", "monitor.added", "monitor.removed" }) do
    hl.on(event, enforce_bounds)
end

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

        -- Column width. Capped so the columns never run past the monitor edge,
        -- which is what makes the tape scroll when focus moves.
        hl.bind(mainMod .. " + CTRL + " .. key, function()
            resize_column(h.dir == "next" and 0.05 or -0.05)
        end, { repeating = true, description = "Resize column " .. h.label })

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
    resize_column = resize_column,
    enforce_bounds = enforce_bounds,
    usable_width = usable_width,
    span_of = span_of,
    stable_order = stable_order,
    main_column = main_column,
}
