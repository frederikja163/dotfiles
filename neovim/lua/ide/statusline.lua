-- The statusline. It exists to say what the keyboard is currently doing: a mode
-- from ide.modal is invisible apart from this, and a mode entered and forgotten
-- leaves h/j/k/l meaning something other than what they mean everywhere else --
-- the reason hypr/modes.lua puts its submap name on the bar. The rest is what
-- is worth a glance while working: whether a review is running and how far
-- through its list you are, the file, diagnostics, which language servers are
-- attached and what they are busy with.
--
-- It is a function, not a format string, because a mode only shows in the
-- window you are in, and the statusline of a window that is not current is
-- drawn too. vim.g.statusline_winid is the window being drawn.
--
-- Review is looked at through package.loaded rather than required: the
-- statusline is drawn at startup, and pulling the review module (and with it
-- gitsigns) in for a label that is empty almost always would be the wrong
-- thing to be waiting for.
--
-- Highlights are derived from the colour scheme's own groups, reversed, so they
-- follow whatever scheme is on -- and survive `transparent_background`, where a
-- hard-coded background would not match anything.

local M = {}

local function escape(text)
    return (text:gsub('%%', '%%%%'))
end

local function derive(from)
    local hl = vim.api.nvim_get_hl(0, { name = from, link = false })
    return { fg = hl.fg, bold = true, reverse = true }
end

local function highlights()
    vim.api.nvim_set_hl(0, 'IdeMode', derive('WarningMsg'))
    vim.api.nvim_set_hl(0, 'IdeReview', derive('Function'))
    vim.api.nvim_set_hl(0, 'IdeJob', derive('DiagnosticInfo'))
    vim.api.nvim_set_hl(0, 'IdeDebug', derive('DiagnosticError'))
end

local function diagnostics(buf)
    local counts = vim.diagnostic.count(buf)
    local out = {}
    for _, severity in ipairs({
        { vim.diagnostic.severity.ERROR, 'E', 'DiagnosticError' },
        { vim.diagnostic.severity.WARN, 'W', 'DiagnosticWarn' },
    }) do
        local n = counts[severity[1]]
        if n and n > 0 then
            table.insert(out, ('%%#%s#%s%d%%*'):format(severity[3], severity[2], n))
        end
    end
    return table.concat(out, ' ')
end

local function servers(buf)
    local names = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        table.insert(names, (tostring(client.name):gsub('_ls$', '')))
    end
    return table.concat(names, ' ')
end

local function render(win)
    win = win or vim.g.statusline_winid
    local current = win == vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local left = {}

    if current then
        local mode = require('ide.modal').current()
        if mode then
            table.insert(left, ('%%#IdeMode# %s %%*'):format(escape(mode:upper())))
        end
    end

    local review = package.loaded['ide.review']
    local progress = review and review.status and review.status()
    if progress then
        table.insert(left, ('%%#IdeReview# REVIEW %s %%*'):format(escape(progress)))
    end

    -- A debugging session, which goes on when the mode that drives it is left. Read
    -- through package.loaded like review, and for the same reason.
    local debugging = package.loaded['ide.debug']
    local debug_state = debugging and debugging.status and debugging.status()
    if debug_state then
        table.insert(left, ('%%#IdeDebug# DEBUG %s %%*'):format(debug_state))
    end

    -- A build or a test run that is going. It is in the background, and without
    -- this the only sign of it is that nothing has come back yet.
    local job = vim.g.ide_job
    if job and job ~= '' then
        table.insert(left, ('%%#IdeJob# ⟳ %s %%*'):format(escape(tostring(job):upper())))
    end

    table.insert(left, ' %f%m%r')

    local right = {}
    local problems = diagnostics(buf)
    if problems ~= '' then
        table.insert(right, problems)
    end
    local attached = servers(buf)
    if attached ~= '' then
        table.insert(right, escape(attached))
    end
    if current then
        local busy = vim.lsp.status()
        if busy ~= '' then
            table.insert(right, escape(vim.fn.strcharpart(busy, 0, 40)))
        end
    end
    table.insert(right, '%l:%c')
    table.insert(right, '%P')

    return table.concat(left, '') .. '%=' .. table.concat(right, '  ') .. ' '
end

-- A statusline that throws is drawn again, and fails again, at every redraw --
-- and a redraw happens on every key, including the ones a mode is reading. So
-- an error here is caught, said once, and answered with a plain line, which is
-- also what keeps a broken module from hiding which file is open.
local complained = false

--- The statusline for the window being drawn, or for `win`, which is how the
--- tests ask: g:statusline_winid is only set while Vim is drawing.
---@param win? integer
---@return string
function M.render(win)
    local ok, line = pcall(render, win)
    if ok then
        return line
    end
    if not complained then
        complained = true
        vim.schedule(function()
            vim.notify('statusline: ' .. tostring(line), vim.log.levels.ERROR)
        end)
    end
    return ' %f%m%r%=%l:%c '
end

highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
    group = require('ide.group'),
    callback = highlights,
})
vim.o.statusline = "%!v:lua.require'ide.statusline'.render()"

return M
