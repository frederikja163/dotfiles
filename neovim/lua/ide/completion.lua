-- Completion, with what Neovim has built in, driven by the language server.
--
-- This replaces nvim-cmp and the five plugins that hung off it (cmp-nvim-lsp,
-- cmp-path, cmp-vsnip, vim-vsnip, lspkind.nvim). 0.12's own completion does what
-- they were being used for -- a menu with kinds and details, a documentation
-- popup beside it, snippet expansion, the extra edits that come with an item (a
-- `using` for the type you picked) -- and the reasons to move were concrete:
--
--   * The popup that says what is being completed was drawn by a function
--     Neovim has deprecated (vim.lsp.util.stylize_markdown, gone in 0.14) that
--     only understood code fences, so bold, links and escapes in a server's
--     documentation came out as raw markdown. Neovim's own popup renders markdown
--     with tree-sitter, as hover does.
--   * cmp-nvim-lsp sends an item's `command` to the server, and Roslyn's
--     completion items carry client-side ones (roslyn.client.completionComplexEdit)
--     that only the client's own `commands` table can run. The built-in path calls
--     client:exec_cmd, which looks there first.
--   * Six plugins and a formatter that did `packadd lspkind-nvim` against a
--     directory called lspkind.nvim, which fails with E919 every time it runs.
--
-- How it behaves.
--
-- The menu opens as you type. Neovim itself only asks on the characters a server
-- names as triggers (`.`, `(` and so on), so for letters it is asked here: a
-- word character typed while no menu is showing asks, after a pause of 25ms in
-- typing, and while the menu is open Neovim narrows it as you type without
-- asking again.
--
-- It is asked as an *invoked* completion, and that is not the obvious way. The
-- obvious way -- the one :help lsp-autocompletion gives first -- is to add the
-- letters to the server's trigger characters, so that Neovim sends each as a
-- trigger character. Roslyn answers that with nothing in the middle of a word:
-- it considers a letter a trigger only where an identifier starts, which is the
-- right thing for a trigger and means `Console.Wri` shows no menu at all. A fake
-- server cannot show this, and the real one did: typing `Console.Wri` opened
-- nothing for thirty seconds. VS Code asks for completion while typing a word as
-- an invocation, with no trigger character, and the second suggestion in the
-- help -- call vim.lsp.completion.get() from InsertCharPre -- does the same.
--
-- 'completeopt' has `noinsert` and not `noselect`: the first item is highlighted
-- but not inserted. That is what makes the documentation popup appear at once,
-- since it is shown for the highlighted item, and it is what cmp's
-- `confirm({ select = true })` did. `fuzzy` matches camel case the way Rider does
-- (`wl` finds WriteLine). `popup` is the documentation window.
--
-- Keys, all in keys.lua; the functions they call are here:
--
--   <CR>     accept the highlighted item (a newline when there is no menu)
--   <Tab>    next item; or the next snippet placeholder; or a tab
--   <S-Tab>  previous item; or the previous placeholder; or a back-tab
--   <C-d> <C-u>   scroll the documentation, while a menu is open
--   <C-Space>     ask for completions now
--   <C-e>    close the menu: Neovim's own, unchanged
--
-- Accepting is Neovim's `<C-y>`, which is what fires CompleteDone, and that is
-- where Neovim applies an item's snippet, its additional edits and its command:
-- accepting any other way (a plain <CR>, which inserts the match and a newline)
-- would skip all three. <CR> is mapped to <C-y> for that reason.
--
-- Not carried over: path completion (cmp-path). `<C-x><C-f>` is Neovim's, and a
-- path is rarely typed in C#. Completion of words from the buffer, which cmp was
-- never set up for either, is `<C-n>`.
--
-- The kind icons come from mini.icons, so they match the pickers.

local group = require('ide.group')

local M = {}

vim.o.completeopt = 'menu,menuone,noinsert,popup,fuzzy'
vim.o.pumheight = 14
vim.o.pumborder = 'rounded'

-- A burst of typing is one request. Each key takes a number and asks only if it
-- is still the latest when the pause is over.
local DEBOUNCE = 25
local sequence = 0

local function ask_after_typing(buf)
    sequence = sequence + 1
    local mine = sequence
    vim.defer_fn(function()
        if mine ~= sequence or vim.api.nvim_get_current_buf() ~= buf then
            return
        end
        if not vim.api.nvim_get_mode().mode:find('^i') or vim.fn.pumvisible() ~= 0 then
            return
        end
        vim.lsp.completion.get()
    end, DEBOUNCE)
end

local watching = {}

local function watch_typing(buf)
    if watching[buf] then
        return
    end
    watching[buf] = true
    vim.api.nvim_create_autocmd('InsertCharPre', {
        group = group,
        buffer = buf,
        callback = function()
            -- Not while a menu is showing: it narrows by itself, and a new request
            -- would only replace what is on screen with the same list.
            if vim.fn.pumvisible() == 0 and vim.v.char:match('^[%w_]$') then
                ask_after_typing(buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = buf,
        callback = function()
            watching[buf] = nil
        end,
    })
end

--- How an item is shown: an icon for its kind, then the kind's name. The rest
--- is Neovim's own (the label, the label's detail, the server's `detail`).
---@param item lsp.CompletionItem
---@return table
function M.convert(item)
    local name = vim.lsp.protocol.CompletionItemKind[item.kind] or 'Unknown'
    local icons = rawget(_G, 'MiniIcons')
    if not icons then
        return { kind = name }
    end
    local icon, hl = icons.get('lsp', name)
    return { kind = icon .. ' ' .. name, kind_hlgroup = hl }
end

vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if not client or not client:supports_method('textDocument/completion', args.buf) then
            return
        end
        vim.lsp.completion.enable(true, client.id, args.buf, {
            autotrigger = true,
            convert = M.convert,
        })
        watch_typing(args.buf)
    end,
})

----------------------------------------------------------------------------
-- The keys
----------------------------------------------------------------------------

local function menu_open()
    return vim.fn.pumvisible() ~= 0
end

--- <CR>: accept the highlighted item, or a newline. Returns keys, for an
--- expression mapping.
---@return string
function M.confirm()
    if menu_open() and vim.fn.complete_info({ 'selected' }).selected >= 0 then
        return '<C-y>'
    end
    return '<CR>'
end

--- <Tab>: the next item, or the next placeholder of a snippet, or a tab.
---@return string
function M.next()
    if menu_open() then
        return '<C-n>'
    elseif vim.snippet.active({ direction = 1 }) then
        return '<Cmd>lua vim.snippet.jump(1)<CR>'
    end
    return '<Tab>'
end

--- <S-Tab>: the previous item, or the previous placeholder, or a back-tab.
---@return string
function M.previous()
    if menu_open() then
        return '<C-p>'
    elseif vim.snippet.active({ direction = -1 }) then
        return '<Cmd>lua vim.snippet.jump(-1)<CR>'
    end
    return '<S-Tab>'
end

--- Scroll the documentation window while a menu is open. Without one the key
--- does what it always does (<C-d> dedents, <C-u> deletes to the start of the
--- line), so mapping them costs nothing when they are not wanted.
---@param down boolean
---@return fun()
function M.scroll(down)
    return function()
        local key = down and '<C-d>' or '<C-u>'
        -- 'selected' and not 'preview_winid': the ids of the documentation window
        -- are only in the answer when something else is asked for with them.
        local win = menu_open() and vim.fn.complete_info({ 'selected' }).preview_winid or 0
        if win == 0 or not vim.api.nvim_win_is_valid(win) then
            -- 'n': not remapped, or this would call itself. 'i': before
            -- whatever is already typed ahead.
            return vim.api.nvim_feedkeys(vim.keycode(key), 'ni', false)
        end
        vim.api.nvim_win_call(win, function()
            vim.cmd.normal({ vim.keycode(key), bang = true })
        end)
    end
end

--- Ask for completions now, whatever was typed.
function M.invoke()
    vim.lsp.completion.get()
end

return M
