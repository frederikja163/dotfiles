-- Things that are on or off, and one place to flip them: `:Toggle`, or a picker
-- of them with what each is set to now. Each is also in the palette, and its
-- entry there says which way it is set.
--
--   hints      inlay hints: parameter names and inferred types, in the text
--   lens       code lenses: "3 references" above a member
--   highlight  the other uses of the symbol under the cursor, read and write
--              told apart (Roslyn reports which, and Rider shows it the same way)
--   format     format on write
--   autosave   writing a buffer when focus leaves it
--
-- These are a command and not keys because they are set once and left, or
-- flipped a few times a day at most; a key is for what is done every few
-- minutes. They are not remembered between sessions: each starts in the state
-- below, which is the quiet one except for the usages highlight. Hints and
-- lenses add text to the screen and are off; the highlight only recolours text
-- that is already there, and is the part of an IDE that is missed when it is
-- not.
--
-- The server does the hard part for the first three -- the settings that decide
-- what a hint or a lens shows are in ide.lsp -- so what is switched here is only
-- whether Neovim asks and draws.
--
-- The highlight is asked for when the cursor has rested ('updatetime') and
-- cleared when it moves, in the buffers of servers that can do it. It is its own
-- autocommands rather than a toggle of something Neovim has, because Neovim has
-- nothing: documentHighlight is a request and a way to draw its answer, and
-- when to make it is left to the config.

local group = require('ide.group')
local registry = require('ide.registry')

local M = {}

local function notify(text)
    vim.notify(text, vim.log.levels.INFO)
end

local function clear_highlights()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            vim.api.nvim_buf_call(buf, vim.lsp.buf.clear_references)
        end
    end
end

M.items = {
    {
        name = 'hints',
        title = 'Inlay hints',
        desc = 'parameter names and inferred types, drawn in the text',
        get = function()
            return vim.lsp.inlay_hint.is_enabled()
        end,
        set = function(on)
            vim.lsp.inlay_hint.enable(on)
        end,
    },
    {
        name = 'lens',
        title = 'Code lens',
        desc = 'reference counts above members; grx runs the one on the line',
        get = function()
            return vim.lsp.codelens.is_enabled()
        end,
        set = function(on)
            vim.lsp.codelens.enable(on)
        end,
    },
    {
        name = 'highlight',
        title = 'Usages highlight',
        desc = 'the other uses of the symbol under the cursor, reads and writes apart',
        get = function()
            return vim.g.ide_highlight ~= false
        end,
        set = function(on)
            vim.g.ide_highlight = on
            if not on then
                clear_highlights()
            end
        end,
    },
    {
        name = 'format',
        title = 'Format on write',
        desc = 'the language server formats the buffer every time it is written',
        get = function()
            return vim.g.ide_format ~= false
        end,
        set = function(on)
            vim.g.ide_format = on
        end,
    },
    {
        name = 'autosave',
        title = 'Autosave',
        desc = 'write a buffer when focus leaves it; <leader>ww always writes',
        get = function()
            return vim.g.ide_autosave ~= false
        end,
        set = function(on)
            vim.g.ide_autosave = on
        end,
    },
}

local by_name = {}
for _, item in ipairs(M.items) do
    by_name[item.name] = item
end

local function state(item)
    return item.get() and 'on' or 'off'
end

--- Flip a toggle, or set it. Says what it is now.
---@param name string
---@param value? boolean  nil to flip
---@return boolean? now  nil if there is no such toggle
function M.set(name, value)
    local item = by_name[name]
    if not item then
        notify(('No toggle called %s: %s'):format(name, table.concat(vim.tbl_map(function(i) return i.name end, M.items), ', ')))
        return nil
    end
    local now = value
    if now == nil then
        now = not item.get()
    end
    item.set(now)
    notify(('%s: %s'):format(item.title, now and 'on' or 'off'))
    return now
end

local function pick()
    local rows = {}
    for _, item in ipairs(M.items) do
        table.insert(rows, {
            name = item.name,
            text = ('%-10s %-4s %s'):format(item.name, state(item), item.desc),
        })
    end
    require('mini.pick').start({
        source = {
            name = 'Toggles',
            items = rows,
            choose = function(row)
                vim.schedule(function()
                    M.set(row.name)
                end)
            end,
        },
    })
end

registry.command('Toggle', function(opts)
    if opts.args == '' then
        return pick()
    end
    local name, word = opts.args:match('^(%S+)%s*(%S*)$')
    local value
    if word == 'on' then
        value = true
    elseif word == 'off' then
        value = false
    end
    M.set(name, value)
end, {
    nargs = '?',
    desc = 'Flip inlay hints, code lens, the usages highlight, format on write or autosave; with no argument, pick one',
    complete = function(lead)
        local names = vim.tbl_map(function(item) return item.name end, M.items)
        return vim.tbl_filter(function(name)
            return vim.startswith(name, lead)
        end, names)
    end,
})

for _, item in ipairs(M.items) do
    registry.action(function()
        return ('Toggle: %s (%s)'):format(item.title, state(item))
    end, function()
        M.set(item.name)
    end, item.desc)
end

----------------------------------------------------------------------------
-- The usages highlight
----------------------------------------------------------------------------

local METHOD = 'textDocument/documentHighlight'

vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if not (client and client:supports_method(METHOD, args.buf)) then
            return
        end
        local local_group = vim.api.nvim_create_augroup('ide.highlight.' .. args.buf, { clear = true })
        vim.api.nvim_create_autocmd('CursorHold', {
            group = local_group,
            buffer = args.buf,
            callback = function()
                if vim.g.ide_highlight ~= false then
                    vim.lsp.buf.document_highlight()
                end
            end,
        })
        vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter' }, {
            group = local_group,
            buffer = args.buf,
            callback = vim.lsp.buf.clear_references,
        })
    end,
})

return M
