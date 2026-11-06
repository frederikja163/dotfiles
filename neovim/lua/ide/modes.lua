-- The modes that are about windows. The review mode is in ide.review, because
-- what its keys do is review's business and nothing else's.
--
-- Same grammar as hypr/modes.lua: a verb on the leader enters a mode, and
-- inside it the motions are bare. h/j/k/l mean the same here as they do for
-- moving between windows (<C-h> and friends) and in Hyprland -- left, down, up,
-- right -- and a count means "this many".

local modal = require('ide.modal')

-- Columns or rows a nudge moves. It is what the keys this replaced used.
local STEP = 5

local function resize(command, sign)
    return function(count)
        vim.cmd(('%s %s%d'):format(command, sign, STEP * count))
    end
end

-- Maximising is a toggle with a memory: winrestcmd() is the Ex commands that
-- put every window back at its present size, taken just before it fills the
-- screen. It is kept on the tab, so a second window in another tab has its own.
-- If the layout changed in between -- a window closed -- the commands apply to
-- window numbers that no longer mean the same thing, which is harmless: the
-- sizes come out odd and `=` fixes them.
local function maximise()
    local saved = vim.t.ide_restore
    if saved then
        vim.t.ide_restore = nil
        vim.cmd(saved)
        return
    end
    vim.t.ide_restore = vim.fn.winrestcmd()
    vim.cmd('wincmd _')
    vim.cmd('wincmd |')
end

modal.define('size', {
    desc = 'Resize the window',
    entry = '<leader>s',
    hint = 'h/j/k/l narrower, taller, shorter, wider  ·  5l five steps  ·  = equalise  ·  m maximise',
    keys = {
        { { 'h', '<Left>' }, resize('vertical resize', '-'), desc = 'Narrower' },
        { { 'l', '<Right>' }, resize('vertical resize', '+'), desc = 'Wider' },
        { { 'j', '<Down>' }, resize('resize', '+'), desc = 'Taller' },
        { { 'k', '<Up>' }, resize('resize', '-'), desc = 'Shorter' },
        { '=', function() vim.cmd('wincmd =') end, desc = 'Make all windows equal' },
        { 'm', maximise, desc = 'Maximise this window, or put it back' },
    },
})

-- Moving a window along. Sideways and up and down it *swaps* with its
-- neighbour in that direction, which is what repeats: wincmd H and friends send
-- the window to the far edge, and pressing them again does nothing. At the edge
-- it does go there -- a window pushed past the last one gets a row or column of
-- its own, as in the Hyprland layout -- so the same key that swapped last
-- reshapes next.
--
-- win_splitmove puts the window in a new split of the neighbour, on the side it
-- came from, which is a swap that keeps each window's own state (folds,
-- options, cursor) rather than exchanging buffers between them. The widths come
-- out as halves of the neighbour's, and `=` in the size mode evens them.
local function neighbour(direction)
    local number = vim.fn.winnr(direction)
    if number == vim.fn.winnr() then
        return nil
    end
    return vim.fn.win_getid(number)
end

local function move(direction, edge, vertical, after)
    return function(count)
        for _ = 1, count do
            local target = neighbour(direction)
            local ok, err
            if target then
                ok, err = pcall(vim.fn.win_splitmove, vim.api.nvim_get_current_win(), target,
                    { vertical = vertical, rightbelow = after })
            else
                ok, err = pcall(vim.cmd.wincmd, edge)
            end
            if not ok then
                vim.notify('move: ' .. tostring(err), vim.log.levels.WARN)
                return
            end
        end
    end
end

modal.define('move', {
    desc = 'Move the window',
    entry = '<leader>m',
    hint = 'h/j/k/l swap with the neighbour, or go to the edge  ·  x exchange  ·  r rotate',
    keys = {
        { { 'h', '<Left>' }, move('h', 'H', true, false), desc = 'Move the window left' },
        { { 'l', '<Right>' }, move('l', 'L', true, true), desc = 'Move the window right' },
        { { 'j', '<Down>' }, move('j', 'J', false, true), desc = 'Move the window down' },
        { { 'k', '<Up>' }, move('k', 'K', false, false), desc = 'Move the window up' },
        -- No count for x: to wincmd it names a window to exchange with, and the
        -- engine hands over 1 when none was typed.
        { 'x', function() vim.cmd('wincmd x') end, desc = 'Exchange with the next window' },
        { 'r', function(count) vim.cmd(count .. 'wincmd r') end, desc = 'Rotate the windows' },
    },
})
