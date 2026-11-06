-- Which key maps are this config's, and whether each has a description.
--
-- Two things need to know. The cheatsheet should list this config's keys and
-- leave out Neovim's own and the plugins', and the rule that every key has a
-- description is only worth anything if something checks it.
--
-- A map says which script made it: `sid`. Neovim's own defaults have -8, a
-- plugin's maps have the id of the plugin's script, and this config's have the id
-- of init.lua, because the modules are `require`d from init.lua and run in its
-- context. So a map is this config's if it has the id that a map made from here
-- has, which is found out by making one of no consequence and reading it back.
--
-- This is not what it was first. It was a snapshot of the maps at startup, with a
-- map counted as Neovim's if it was in the snapshot unchanged, and then a wrapper
-- round vim.keymap.set that was installed while the modules loaded and took notes.
-- Both rested on the belief that every map made from Lua carries the same script
-- id (-8) and so cannot be told apart. That was a guess, and it is wrong: only the
-- defaults have -8. The snapshot got what a plugin adds later wrong and the
-- wrapper patched a function every plugin shares, to find out what one comparison
-- says.
--
-- Where it stops being true: a map made in code that runs outside any script --
-- a callback from a timer, or from vim.schedule -- has no script id of its own.
-- Nothing in this config makes a global map that way, and the buffer-local ones
-- come from autocommands, which keep the id of the script that made them.

local probe = '<Plug>(ide-mapped-probe)'
vim.keymap.set('n', probe, '<Nop>')
local sid = vim.fn.maparg(probe, 'n', false, true).sid
vim.keymap.del('n', probe)

local M = {}

--- Whether this config made the map (a table from nvim_get_keymap).
---@param map table
---@return boolean
function M.is_ours(map)
    return map.sid == sid
end

--- The maps of this config that have no description, as "mode lhs": the global
--- ones and the ones in any loaded buffer.
---@return string[]
function M.undescribed()
    local found = {}
    local function scan(maps)
        for _, map in ipairs(maps) do
            if M.is_ours(map) and (map.desc == nil or map.desc == '') then
                table.insert(found, ('%s %s'):format(map.mode, vim.fn.keytrans(map.lhsraw or map.lhs)))
            end
        end
    end
    for _, mode in ipairs({ 'n', 'x', 'i', 't', 'o', 'c', 's' }) do
        scan(vim.api.nvim_get_keymap(mode))
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
                scan(vim.api.nvim_buf_get_keymap(buf, mode))
            end
        end
    end
    table.sort(found)
    return found
end

return M
