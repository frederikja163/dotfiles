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

-- ---------------------------------------------------------------------------
-- Column widths
--
-- One invariant: the columns of a desktop always add up to exactly the width
-- of the monitor. Never less, so there is no dead space; never more, so the
-- tape never scrolls sideways when focus moves. Every operation that can
-- disturb it -- resizing, splitting a window out, moving a window between
-- columns, opening and closing windows, changing monitor -- ends by restoring
-- it.
--
-- Widths are handled as fractions of the usable width that add up to 1.0, and
-- only converted to Hyprland's `colresize` at the very end.
-- ---------------------------------------------------------------------------

-- Usable width in the logical pixels window geometry uses: the monitor width
-- divided by its scale, less the outer gaps and borders on both sides.
--
-- Verified against a lone column, which spans everything: eDP-1 is 1920 at
-- scale 1.5, so 1280 logical, and the column measures 1266 = 1280 - 2*5 - 2*2.
-- `colresize` fractions are relative to exactly this width.
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

    local usable = (mon.width / scale) - 2 * gap - 2 * border
    if usable <= 0 then
        return nil
    end
    return usable
end

-- Left edge of the first column to right edge of the last.
local function span_of(cols)
    if #cols == 0 then
        return 0
    end
    local last = cols[#cols]
    return (last.x + last.width) - cols[1].x
end

-- Smallest column worth having, as a fraction of the monitor.
local MIN_COLUMN = 0.08

-- Rounding in Hyprland means the measured widths never add up to exactly 1.0.
-- Anything inside this is treated as already correct, so that simply moving
-- focus does not set off a rebalance.
local BALANCE_TOLERANCE = 0.01

local function sum(list)
    local total = 0
    for _, v in ipairs(list) do
        total = total + v
    end
    return total
end

-- Scale fractions so they add up to exactly 1.0, keeping their relative sizes
-- and giving every column at least MIN_COLUMN.
local function to_unit(fractions)
    local n = #fractions
    if n == 0 then
        return {}
    end

    local total = sum(fractions)
    local out = {}

    if total <= 0 then
        for i = 1, n do
            out[i] = 1 / n
        end
        return out
    end

    for i, v in ipairs(fractions) do
        out[i] = v / total
    end

    -- Anything under the floor is pinned there and the rest share what is left,
    -- still in proportion.
    local floored, free_total = {}, 0
    local budget = 1.0
    for i, v in ipairs(out) do
        if v < MIN_COLUMN then
            floored[i] = true
            budget = budget - MIN_COLUMN
        else
            free_total = free_total + v
        end
    end

    if budget < 0 then
        -- More columns than the floor allows: even split is the best available.
        for i = 1, n do
            out[i] = 1 / n
        end
        return out
    end

    for i, v in ipairs(out) do
        if floored[i] then
            out[i] = MIN_COLUMN
        elseif free_total > 0 then
            out[i] = budget * v / free_total
        end
    end

    return out
end

-- A window that can be used to focus a given column.
local function anchor_of(col)
    return col.windows and col.windows[1]
end

-- Apply a list of { address, fraction } pairs.
--
-- `colresize` only ever affects the focused column, so each column has to be
-- focused in turn. Focusing is done by window address rather than by stepping
-- sideways, so it does not matter how the columns are ordered. The tape would
-- scroll about while this happens, hence inhibit_scroll, and the original
-- focus is put back at the end.
local applying = false

local function apply_targets(targets)
    if applying or #targets == 0 then
        return
    end
    applying = true

    local focused = hl.get_active_window()

    layout_msg("inhibit_scroll true")

    for _, t in ipairs(targets) do
        hl.dispatch(hl.dsp.focus({ window = "address:" .. t.address }))
        layout_msg(("colresize %.4f"):format(t.fraction))
    end

    if focused then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. focused.address }))
    end

    layout_msg("inhibit_scroll false")

    applying = false
end

-- Restore the invariant on a workspace: keep the columns' relative widths but
-- scale them so they fill the monitor exactly.
local function balance(ws, mon)
    if applying then
        return
    end

    mon = mon or hl.get_active_monitor()
    ws = ws or (mon and mon.active_workspace)
    if not (ws and mon) or ws.special then
        return
    end

    local usable = usable_width(mon)
    if not usable then
        return
    end

    local cols = columns_of(ws)
    if #cols == 0 then
        return
    end

    -- Judge by the span, not by the widths added up: a `colresize` fraction
    -- covers a column plus its share of the gaps between columns, so the bare
    -- widths always total less than the monitor and comparing those would make
    -- this rebalance on every single call.
    if math.abs(span_of(cols) / usable - 1.0) <= BALANCE_TOLERANCE then
        return
    end

    local fractions = {}
    for i, c in ipairs(cols) do
        fractions[i] = c.width / usable
    end

    local unit = to_unit(fractions)

    local targets = {}
    for i, c in ipairs(cols) do
        local anchor = anchor_of(c)
        if anchor then
            table.insert(targets, { address = anchor.address, fraction = unit[i] })
        end
    end

    apply_targets(targets)
end

-- Grow or shrink the focused column. Whatever it gains is taken from the other
-- columns in proportion to their size, and vice versa, so the total is
-- unchanged and the columns keep filling the monitor.
local function resize_column(delta)
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws or ws.special then
        return
    end

    local mon = win.monitor
    local usable = usable_width(mon)
    if not usable then
        return
    end

    local cols = columns_of(ws)
    local n = #cols
    if n < 2 then
        return -- a lone column already fills the monitor
    end

    local index
    for i, c in ipairs(cols) do
        for _, w in ipairs(c.windows) do
            if w.address == win.address then
                index = i
                break
            end
        end
    end
    if not index then
        return
    end

    local fractions = {}
    for i, c in ipairs(cols) do
        fractions[i] = c.width / usable
    end
    fractions = to_unit(fractions)

    -- Leave room for every other column to keep its minimum.
    local ceiling = 1.0 - MIN_COLUMN * (n - 1)
    local target = math.max(MIN_COLUMN, math.min(ceiling, fractions[index] + delta))
    if math.abs(target - fractions[index]) < 0.001 then
        return
    end

    local others = sum(fractions) - fractions[index]
    local remaining = 1.0 - target

    local wanted = {}
    for i, v in ipairs(fractions) do
        if i == index then
            wanted[i] = target
        elseif others > 0 then
            wanted[i] = remaining * v / others
        else
            wanted[i] = remaining / (n - 1)
        end
    end

    wanted = to_unit(wanted)

    local targets = {}
    for i, c in ipairs(cols) do
        local anchor = anchor_of(c)
        if anchor then
            table.insert(targets, { address = anchor.address, fraction = wanted[i] })
        end
    end

    apply_targets(targets)
end

-- M+n: split the focused window out into a column of its own.
--
--   all columns the same width -> the new set is evened out again
--   otherwise                  -> the source column is halved and the new
--                                 column takes the other half, so the total
--                                 does not change
local function new_column()
    local win = hl.get_active_window()
    if not win or win.floating then
        return
    end

    local ws = win.workspace
    if not ws or ws.special then
        return
    end

    local mon = win.monitor
    local usable = usable_width(mon)
    if not usable then
        return
    end

    local cols = columns_of(ws)
    local source = column_containing(cols, win)

    -- Already alone in its column: nothing to split out.
    if not source or #source.windows < 2 then
        return
    end

    local even = all_same_width(cols)

    -- Work out the widths before anything moves, keyed by a window that stays
    -- in each column. `win` itself becomes the new column.
    local targets
    if not even then
        local fractions = {}
        for i, c in ipairs(cols) do
            fractions[i] = c.width / usable
        end
        fractions = to_unit(fractions)

        targets = {}
        for i, c in ipairs(cols) do
            if c == source then
                -- The half that stays behind needs an anchor that is not the
                -- window being moved out.
                local stay
                for _, w in ipairs(c.windows) do
                    if w.address ~= win.address then
                        stay = w
                        break
                    end
                end
                if stay then
                    table.insert(targets, { address = stay.address, fraction = fractions[i] / 2 })
                end
                table.insert(targets, { address = win.address, fraction = fractions[i] / 2 })
            else
                local anchor = anchor_of(c)
                if anchor then
                    table.insert(targets, { address = anchor.address, fraction = fractions[i] })
                end
            end
        end
    end

    layout_msg("promote")

    if even then
        -- n + 1 columns of 1/(n + 1) fills the monitor exactly, in one message.
        layout_msg(("colresize all %.4f"):format(1.0 / (#cols + 1)))
    else
        apply_targets(targets)
    end
end

-- ---------------------------------------------------------------------------
-- New windows
--
-- A window is first given a column of its own, immediately right of the
-- focused one, and takes focus. Bringing that column into view scrolls the
-- tape, and the scroll is not undone when the column merges away, so it is
-- suppressed from open_early -- by window.open the tape has already moved.
--
-- `consume` pulls a window in from the *next* column (it fails with "no next
-- column" on the last one), so it is the wrong message here.
-- `consume_or_expel prev` moves the current window into the previous column,
-- which is the focused one, appending it to the bottom.
-- ---------------------------------------------------------------------------

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

    -- Nothing to merge into if this is the only window, but a lone column still
    -- has to fill the monitor.
    if #tiled_windows(ws) < 2 then
        done()
        return balance(ws, win.monitor)
    end

    -- consume_or_expel expels instead of consuming when the window is not alone
    -- in its column, which would be the exact opposite of what we want. A
    -- freshly opened window always is alone, so bail out if that is somehow not
    -- the case rather than risk pushing it out again.
    local own = column_containing(columns_of(ws), win)
    if not own or #own.windows ~= 1 then
        return done()
    end

    layout_msg("consume_or_expel prev")
    done()

    -- The window joined an existing column, so the count is unchanged, but the
    -- merge can still leave the widths short of the monitor.
    balance(ws, win.monitor)
end)

-- Anything else that can change the columns: a window closing may empty a
-- column, a workspace may arrive on a different monitor, a monitor may change
-- size or scale.
for _, event in ipairs({
    "workspace.active",
    "workspace.move_to_monitor",
    "window.close",
    "window.move_to_workspace",
    "monitor.added",
    "monitor.removed",
    "monitor.layout_changed",
}) do
    hl.on(event, function() balance() end)
end

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

    -- Moving the last window out of a column removes it, and expelling adds
    -- one, so the widths have to be redistributed either way.
    balance(ws, win.monitor)
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
    to_unit = to_unit,
    balance = balance,
    usable_width = usable_width,
    span_of = span_of,
    stable_order = stable_order,
    main_column = main_column,
}
