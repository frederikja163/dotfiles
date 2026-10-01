local function write_if_possible()
    if not vim.bo.modifiable then
        return
    end

    local name = vim.api.nvim_buf_get_name(0)

    if name == "" then
        return
    end

    if vim.fn.filewritable(name) == 1 then
        vim.cmd.write()
    end
end

-- Options
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.number = true
vim.opt.splitright = true
vim.opt.scrolloff = 5
vim.opt.cursorline = true
vim.opt.inccommand = 'split'
vim.opt.relativenumber = true
vim.opt.wrap = false
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.swapfile = false
vim.opt.winborder = "rounded"
vim.opt.signcolumn = "yes"
vim.g.mapleader = " "

-- Keymaps
vim.keymap.set('n', '<leader>r', '<cmd>update<CR> <cmd>source<CR>')
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('t', '<Esc>', '<C-\\><C-n>')
vim.keymap.set('i', '<C-j>', '<C-o>j')
vim.keymap.set('i', '<C-k>', '<C-o>k')
vim.keymap.set('i', '<C-h>', '<C-o>h')
vim.keymap.set('i', '<C-l>', '<C-o>l')
vim.keymap.set('n', '<leader>ww', write_if_possible)
vim.keymap.set('n', '<leader>wc', function()
    if #vim.api.nvim_list_wins() > 1 then
        vim.cmd.close()
    end
end)

local resizeStep = 5
local directions = {
    { key = 'h', focus = 'h', move = 'H', resize = 'vertical resize -' .. resizeStep },
    { key = 'j', focus = 'j', move = 'J', resize = 'resize +' .. resizeStep },
    { key = 'k', focus = 'k', move = 'K', resize = 'resize -' .. resizeStep },
    { key = 'l', focus = 'l', move = 'L', resize = 'vertical resize +' .. resizeStep },
}
for _, d in ipairs(directions) do
    vim.keymap.set('n', '<leader>' .. d.key, '<cmd>wincmd ' .. d.focus .. '<CR>',
        { desc = 'Focus the window ' .. d.key })
    vim.keymap.set('n', '<leader>m' .. d.key, '<cmd>wincmd ' .. d.move .. '<CR>',
        { desc = 'Move the window ' .. d.key })
    vim.keymap.set('n', '<leader>s' .. d.key, '<cmd>' .. d.resize .. '<CR>',
        { desc = 'Resize the window ' .. d.key })
end

vim.keymap.set('n', '<leader><Tab>', '<cmd>bnext<CR>', { desc = 'Next buffer' })
vim.keymap.set('n', '<leader><S-Tab>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })

-- new window
vim.keymap.set('n', '<leader>ws', '<cmd>wincmd s<CR>')
vim.keymap.set('n', '<leader>wv', '<cmd>wincmd v<CR>')

-- File browser
vim.pack.add({ { src = "https://github.com/nvim-mini/mini.pick" } })
require('mini.pick').setup()
vim.keymap.set('n', '<leader>ff', '<cmd>Pick files<CR>')
vim.keymap.set('n', '<leader>fb', '<cmd>Pick buffers<CR>')
vim.keymap.set('n', '<leader>fh', '<cmd>Pick help<CR>')

-- LSP
vim.pack.add({ { src = "https://github.com/neovim/nvim-lspconfig" } })
vim.lsp.enable({ "lua_ls", "clangd", "denols", "html", "ts_ls", "roslyn_ls", "omnisharp" })

-- C# is served by two servers and the split is by file, not by project:
-- roslyn_ls for .cs in a real project, OmniSharp for project-less .csx
-- scripts, which roslyn refuses to load at all (see install.sh).
--
-- Both root_dir functions below exist to keep that split exact. Neither
-- server can be told apart by filetype -- nvim gives .csx the filetype `cs`
-- as well -- so the buffer name is the only signal, and with lspconfig's
-- defaults OmniSharp's root pattern (*.sln, *.csproj) matched every ordinary
-- .cs file and started it next to roslyn_ls: two sets of diagnostics, two
-- completion sources, two project loads. A root_dir that returns without
-- calling `on_dir` is how a vim.lsp.config declines to start for a buffer.
local function is_csx(bufnr)
    return vim.api.nvim_buf_get_name(bufnr):match('%.csx$') ~= nil
end

vim.lsp.config('roslyn_ls', {
    root_dir = function(bufnr, on_dir)
        if is_csx(bufnr) then
            return
        end
        local root = vim.fs.root(bufnr, function(name)
            return name:match('%.slnx?$') ~= nil
        end) or vim.fs.root(bufnr, function(name)
            return name:match('%.csproj$') ~= nil
        end)
        if root then
            on_dir(root)
        end
    end,
    handlers = {
        ['workspace/projectInitializationComplete'] = function(_, _, ctx)
            local client = vim.lsp.get_client_by_id(ctx.client_id)
            if not client then
                return vim.NIL
            end
            local buffers = vim.tbl_keys(client.attached_buffers)
            vim.schedule(function()
                for _, buf in ipairs(buffers) do
                    if vim.api.nvim_buf_is_loaded(buf) then
                        vim.lsp.buf_detach_client(buf, client.id)
                        vim.lsp.buf_attach_client(buf, client.id)
                    end
                end
            end)
            return vim.NIL
        end,
    },
    cmd = {
        'roslyn-language-server',
        '--logLevel',
        'Information',
        '--extensionLogDirectory',
        vim.fs.joinpath(os.getenv('TMPDIR') or '/tmp', 'roslyn_ls/logs'),
        '--stdio',
    },
})

-- The script's own directory is the right root for a .csx: it has no project
-- to find, and rooting at an enclosing solution would hand OmniSharp the very
-- workspace roslyn_ls is already loading.
vim.lsp.config('omnisharp', {
    root_dir = function(bufnr, on_dir)
        if not is_csx(bufnr) then
            return
        end
        on_dir(vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)))
    end,
})

vim.keymap.set('n', '<leader>d', vim.diagnostic.open_float)

local augroup = vim.api.nvim_create_augroup("custom", {
    clear = true,
})

vim.api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    callback = function()
        if not vim.bo.modifiable then
            return
        end

        if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
            return
        end

        vim.lsp.buf.format()
    end,
})

vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = write_if_possible,
})

vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    callback = write_if_possible,
})

-- Sessions
--
-- Sessions are global files named after the working directory, never a
-- Session.vim beside the code: everything edited here is a git checkout, and
-- a session file in the tree is one more thing to gitignore in every repo.
-- That is why `file` is disabled below rather than left at its default.
--
-- mini.sessions' own `autoread` is deliberately off. With no local
-- Session.vim to find it falls back to the most recently written *global*
-- session, so a bare nvim in one project reopens a different project's
-- windows. The autocommands below key on the working directory instead.
--
-- Opening a directory takes part, in both directions; opening a file does
-- not, so reading one file cannot replace the session for its project -- the
-- usual way an autosaving session manager loses a layout.
--
-- A directory means `nvim` with no arguments, and equally `nvim <dir>`: that
-- is what bin/ide runs as `exec nvim .`, and behind SUPER+I it is the main
-- way a project gets opened here. Keying only on a bare `nvim` looked right
-- and restored nothing in practice.
vim.pack.add({ { src = "https://github.com/nvim-mini/mini.sessions" } })
local sessions = require('mini.sessions')
sessions.setup({
    autoread = false,
    autowrite = false,
    file = '',
})

-- The directory this session belongs to, or nil if this start is not one.
local function session_dir()
    local args = vim.fn.argv()

    if #args > 1 then
        return nil
    end

    if #args == 1 then
        if vim.fn.isdirectory(args[1]) == 0 then
            return nil
        end
        -- normalize also trims the trailing slash that `:p` puts on a
        -- directory, so `nvim .` and a bare `nvim` agree on the name.
        return vim.fs.normalize(vim.fn.fnamemodify(args[1], ':p'))
    end

    if vim.api.nvim_buf_get_name(0) ~= '' then
        return nil
    end
    -- Piped input (`cmd | nvim -`) is already in the first buffer by VimEnter
    -- and leaves no argument or name behind to notice it by.
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines > 1 or (lines[1] or '') ~= '' then
        return nil
    end

    return vim.fs.normalize(vim.fn.getcwd())
end

-- Settled at VimEnter and reused on the way out, rather than worked out twice:
-- a session that restores with `cd` in it, or any `:cd` during the session,
-- would otherwise be written back under a different name than it was read by.
local session_key = nil

vim.api.nvim_create_autocmd("VimEnter", {
    group = augroup,
    nested = true, -- so restored buffers still fire FileType, and LSPs attach
    callback = function()
        local dir = session_dir()
        if not dir then
            return
        end
        session_key = (dir:gsub('/', '%%'))
        if sessions.detected[session_key] then
            sessions.read(session_key, { verbose = false })
        end
    end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
        if session_key then
            sessions.write(session_key, { verbose = false })
        end
    end,
})

vim.keymap.set('n', '<leader>fs', function()
    sessions.select()
end, { desc = 'Pick a session' })

-- Theme
vim.pack.add({ { src = "https://github.com/catppuccin/nvim" } })
require('catppuccin').setup({ transparent_background = true })
vim.cmd.colorscheme "catppuccin-mocha"

vim.pack.add({ { src = "https://github.com/nvim-treesitter/nvim-treesitter" } })
require('nvim-treesitter.configs').setup({
    auto_install = true
})

-- Auto complete
vim.pack.add({
    { src = "https://github.com/hrsh7th/nvim-cmp" },
    { src = "https://github.com/hrsh7th/vim-vsnip" },
    { src = "https://github.com/hrsh7th/cmp-vsnip" },
    { src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
    { src = "https://github.com/hrsh7th/cmp-path" },
    { src = "https://github.com/onsails/lspkind.nvim" },
})
local cmp = require("cmp")
cmp.setup({
    snippet = {
        expand = function(args)
            vim.fn["vsnip#anonymous"](args.body)
        end,
    },
    mapping = {
        ["<C-p>"] = cmp.mapping.select_prev_item(),
        ["<C-n>"] = cmp.mapping.select_next_item(),
        ["<C-d>"] = cmp.mapping.scroll_docs(-4),
        ["<C-f>"] = cmp.mapping.scroll_docs(4),
        ["<C-Space>"] = cmp.mapping.complete(),
        ["<C-e>"] = cmp.mapping.close(),
        ["<CR>"] = cmp.mapping.confirm({
            behavior = cmp.ConfirmBehavior.Replace,
            select = true,
        }),
        ["<Tab>"] = cmp.mapping(cmp.mapping.select_next_item(), { "i", "s" }),
        ["<S-Tab>"] = cmp.mapping(cmp.mapping.select_prev_item(), { "i", "s" }),
    },
    formatting = {
        format = function(_, vim_item)
            vim.cmd("packadd lspkind-nvim")
            vim_item.kind = require("lspkind").presets.codicons[vim_item.kind]
                .. "  "
                .. vim_item.kind
            return vim_item
        end,
    },
    sources = {
        { name = "nvim_lsp" },
        { name = "vsnip" },
        { name = "path" },
    },
})
