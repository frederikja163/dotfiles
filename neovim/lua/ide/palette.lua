-- Finding things: the key cheatsheet and the command palette. Both are pickers,
-- and both are built from what is live rather than from a list kept beside the
-- config, so neither can drift from it -- the same reason `SUPER + /` is
-- generated from `hyprctl binds`.
--
--   <leader>?        every key with a description, normal mode first and then
--                    one group per mode, the way hypr-keybinds groups them.
--                    A reference: Enter just closes it.
--   <leader><leader> the palette: commands, actions and modes, by name. Enter
--                    runs the one under the cursor (a command that wants
--                    arguments is typed onto the command line instead).
--
-- A key is listed when it has a `desc`, which is what makes a description worth
-- writing: tests/nvim/test_keys.lua fails for a map of this config without one.
-- Neovim's own default maps are left out (ide.mapped knows which maps are this
-- config's) except for the few that are part of the working vocabulary: BUILTIN,
-- and the ones named in KEEP_DEFAULT, which carry descriptions of their own. Without that the sheet is two hundred lines of [a ]a [b ]b and
-- the keys that are this config's drown.

local mapped = require('ide.mapped')
local modal = require('ide.modal')
local registry = require('ide.registry')

local M = {}

-- Keys that are Neovim's own and worth knowing. They are commands, not maps,
-- so nothing can be read back for them.
local BUILTIN = {
    { 'ZR', 'Restart Neovim and restore the session (a count 1-8 does not restore it)' },
    { '<C-]>', 'Go to the definition of the word under the cursor' },
    { '<C-t>', 'Go back from a definition' },
    { '<C-w>d', 'Show the diagnostics under the cursor (<leader>d is the short way)' },
}

-- Defaults that carry their own description, kept in the sheet.
local KEEP_DEFAULT = {
    gra = true, grn = true, grx = true, gO = true, K = true,
    ['[d'] = true, [']d'] = true, ['[q'] = true, [']q'] = true, ['[l'] = true, [']l'] = true,
    ['[b'] = true, [']b'] = true, gc = true, gcc = true,
}

-- keytrans writes <C-H>; this config, and most people, write <C-h>.
local function show(lhs)
    return (vim.fn.keytrans(lhs):gsub('<C%-(%a)>', function(letter)
        return '<C-' .. letter:lower() .. '>'
    end))
end

local function lines_for_keys()
    local normal, other = {}, {}
    local seen = {}

    local function add(map, buffer_local)
        -- lhsraw, not lhs: lhs is already in notation (<C-H>), and translating
        -- that again escapes the bracket.
        local lhs = show(map.lhsraw or map.lhs)
        local id = map.mode .. lhs .. (buffer_local and '@buf' or '')
        if seen[id] or not map.desc or map.desc == '' then
            return
        end
        -- A buffer-local map is kept whoever made it; a global one only if it is
        -- this config's, or one of the defaults worth knowing.
        if not buffer_local and not mapped.is_ours(map) and not KEEP_DEFAULT[lhs] then
            return
        end
        seen[id] = true
        local row = ('%-18s %s'):format(lhs, map.desc)
        if map.mode == 'n' then
            table.insert(normal, row)
        else
            table.insert(other, ('%-18s [%s] %s'):format(lhs, map.mode, map.desc))
        end
    end

    for _, mode in ipairs({ 'n', 'x', 'i', 't' }) do
        for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
            add(map, false)
        end
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
            add(map, true)
        end
    end
    for _, key in ipairs(BUILTIN) do
        table.insert(normal, ('%-18s %s'):format(key[1], key[2]))
    end
    table.sort(normal)
    table.sort(other)
    vim.list_extend(normal, other)

    for _, mode in ipairs(modal.list()) do
        for _, key in ipairs(mode.keys) do
            table.insert(normal, ('%-18s %s%s'):format(
                ('%s ▸ %s'):format(mode.name, show(vim.keycode(key.lhs))),
                key.desc, key.leave and '  (then leaves)' or ''))
        end
    end
    return normal
end

--- The cheatsheet. Exposed for the tests, which read it without a picker.
---@return string[]
function M.key_lines()
    return lines_for_keys()
end

function M.keys()
    require('mini.pick').start({
        source = {
            name = 'Keys',
            items = lines_for_keys(),
            choose = function() end,
        },
    })
end

local function entries()
    local out = {}
    for _, mode in ipairs(modal.list()) do
        table.insert(out, {
            text = ('Mode: %-10s %s%s'):format(mode.name, mode.desc, mode.entry and ('  (' .. vim.fn.keytrans(vim.keycode(mode.entry)) .. ')') or ''),
            run = function() modal.open(mode.name) end,
        })
    end
    for _, command in ipairs(registry.commands) do
        table.insert(out, {
            text = (':%-12s %s'):format(command.name .. (command.bang and '[!]' or ''), command.desc),
            run = function()
                if command.nargs == nil or command.nargs == '0' then
                    vim.cmd(command.name)
                else
                    vim.api.nvim_feedkeys(':' .. command.name .. ' ', 'n', false)
                end
            end,
        })
    end
    for _, action in ipairs(registry.actions) do
        local title = type(action.title) == 'function' and action.title() or action.title
        table.insert(out, {
            text = ('%s%s'):format(title, action.desc and ('  ' .. action.desc) or ''),
            run = action.fn,
        })
    end
    return out
end

--- What the palette offers, as text. Exposed for the tests.
---@return string[]
function M.palette_lines()
    return vim.tbl_map(function(entry) return entry.text end, entries())
end

function M.palette()
    require('mini.pick').start({
        source = {
            name = 'Palette',
            items = entries(),
            -- After the picker has gone: a command that opens another picker, or
            -- a mode that blocks reading keys, should not start inside this one.
            choose = function(item)
                vim.schedule(item.run)
            end,
        },
    })
end

return M
