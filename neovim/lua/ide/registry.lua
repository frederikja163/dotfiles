-- What the palette can offer. A command made through here is also a palette
-- entry, and an action is a palette entry that has no command of its own -- a
-- toggle, a verb that would be a key if keys were free. Nothing else knows
-- what the palette lists, so a feature is findable by being declared, not by
-- someone remembering to add it to a menu.
--
-- Commands are recorded rather than discovered because nvim_get_commands
-- cannot say which ones are this config's: a plugin's :Gitsigns, :Pick and the
-- thirty :TS... commands would bury them.

local M = { commands = {}, actions = {} }

--- Define a user command and list it in the palette. `opts.desc` is required.
---@param name string
---@param fn function|string
---@param opts table  the usual nvim_create_user_command options
function M.command(name, fn, opts)
    assert(opts and opts.desc, 'command ' .. name .. ' needs a desc')
    vim.api.nvim_create_user_command(name, fn, opts)
    table.insert(M.commands, { name = name, desc = opts.desc, nargs = opts.nargs, bang = opts.bang })
end

--- List something in the palette that is not a command. The title may be a
--- function, asked each time the palette opens, so that a toggle can say what it
--- is set to now.
---@param title string|fun(): string
---@param fn function
---@param desc? string
function M.action(title, fn, desc)
    table.insert(M.actions, { title = title, fn = fn, desc = desc })
end

return M
