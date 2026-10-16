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
vim.opt.autoread = true
vim.opt.autowriteall = true
vim.opt.updatetime = 1000
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

-- 'autoread' alone only reloads when something runs :checktime, and nothing
-- does by itself; these are the moments a file changed elsewhere (an agent,
-- git checkout) gets picked up. CursorHold is why 'updatetime' is down to
-- 1000: at the default 4000 a buffer stayed stale long enough to edit it
-- and collide on save. Not from the command-line window, where
-- :checktime is an error.
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = augroup,
    callback = function()
        if vim.fn.getcmdwintype() == '' then
            vim.cmd.checktime()
        end
    end,
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

-- Starting over: `:Forget` quits and `:Fresh` restarts, and both leave this
-- directory with no session, so the next start opens on an empty layout.
--
-- Clearing `session_key` is what stops VimLeavePre writing the layout back
-- the moment the file is gone. The file is deleted by path rather than with
-- sessions.delete(), which only knows the sessions it detected at startup
-- and errors outright when there were none.
--
-- `:restart!` rather than `:restart`: without the bang nvim saves and
-- restores a session of its own, which would bring the layout straight back.
-- The new instance gets the same argv, so `nvim .` from bin/ide still lands
-- on this directory and goes on to save a new session when it quits.
--
-- If the quit is refused -- an unsaved buffer, a running terminal job --
-- the key is put back, so quitting normally afterwards saves the layout as
-- before instead of silently leaving no session. The refusal is not
-- reported here: vim shows its own E37 even through the pcall.
local function forget_session(quit)
    local key = session_key
    if key then
        vim.fn.delete(vim.fs.joinpath(sessions.config.directory, key))
        sessions.detected[key] = nil
        vim.v.this_session = ''
        session_key = nil
    end
    if not pcall(vim.cmd, quit) then
        session_key = key
    end
end

vim.api.nvim_create_user_command('Forget', function()
    forget_session('qall')
end, { desc = "Quit and delete this directory's session" })

vim.api.nvim_create_user_command('Fresh', function()
    forget_session('restart!')
end, { desc = "Restart with this directory's session deleted" })
vim.keymap.set('n', '<leader>wr', '<cmd>Fresh<CR>', { desc = "Restart with this directory's session deleted" })

-- Reviewing a diff
--
-- A diff is read here in the file itself, not in a copy of it: the removed
-- lines are drawn as virtual lines between the real ones, so the buffer is
-- the working file with its LSP attached and gd, grr and the rest behave as
-- they do while editing. That inline layout is the default. The other one,
-- side by side (vim's own :diffsplit, on <leader>gs), puts the old version
-- in a scratch buffer no server attaches to; it is there for when the shape
-- of a change reads better that way, and its right-hand side is still the
-- real file.
--
-- gitsigns draws both. Its inline view (`diffthis` with `unified = true`) is
-- the one used here; the older `show_deleted` option looked like the same
-- thing for every buffer at once, but it is deprecated upstream.
-- diffview.nvim was the other candidate and was passed over: its newer side
-- is also a real buffer, but it has no inline mode.
--
-- Both layouts belong to one window and file, and on their own neither
-- follows when that window moves on to the next file: gitsigns closes the
-- inline view, and a :diffsplit is left with the old file's revision beside
-- the new file. Review mode is what makes them follow. While it is on, every
-- git-tracked buffer that lands in a window gets the current layout opened
-- again; for side by side, the old split is closed and a new one made for
-- the new file, so there is only ever one revision window. That window is
-- marked 'winfixbuf', so ]q from inside it lands in the file window instead.
--
-- It is opened from GitSignsUpdate rather than BufWinEnter alone because a
-- freshly loaded buffer is not attached yet when it enters the window.
-- Attaching is not enough either: the first GitSignsUpdate comes with only
-- the branch name, before the file has been diffed, and diffthis fails an
-- assertion if called then. The hunk counts in the status dict are the
-- public sign that the diff is ready, so that is what is waited for.
--
-- The list of changed files is a picker in the current window. gitsigns'
-- own file-tree panel (`:Gitsigns diff`) was used for it at first and taken
-- out: it always opens in a tab of its own, and tabs are not part of how
-- this nvim is used.
vim.pack.add({ { src = "https://github.com/lewis6991/gitsigns.nvim" } })
local gitsigns = require('gitsigns')
gitsigns.setup({
    -- A new file is part of the diff too, and belongs in the quickfix list.
    attach_to_untracked = true,
})

-- Same algorithm as git/config, so nvim and `git diff` draw the same hunks.
vim.opt.diffopt:append('algorithm:histogram')

-- `layout` outlives review mode, so <leader>gr brings back the last one used.
-- `split` is the side-by-side pair: the file window and its revision window.
local review = { on = false, base = nil, layout = 'unified', split = nil }

local function diff_ready(buf)
    local status = vim.b[buf].gitsigns_status_dict
    return status ~= nil and status.added ~= nil
end

local function split_close()
    local split = review.split
    review.split = nil
    if not split then
        return
    end
    if vim.api.nvim_win_is_valid(split.rev) then
        vim.api.nvim_win_close(split.rev, true)
    end
    if vim.api.nvim_win_is_valid(split.file) then
        vim.api.nvim_win_call(split.file, function()
            vim.cmd.diffoff()
        end)
        vim.w[split.file].review_buf = nil
    end
end

-- `vim.w.review_buf` records which buffer this window's view was opened for,
-- so a GitSignsUpdate for a buffer already on show does not open it twice.
-- That matters most inline: diffthis is a toggle there, and a second call
-- would close the view instead.
--
-- diffthis reads the old version from git before it draws, and draws in
-- whichever window is current by then; `done` is how a caller waits for it
-- before moving focus, as opening the quickfix window does.
local function review_open(win, done)
    done = done or function() end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.w[win].review_buf == buf or not diff_ready(buf)
        or (review.split and win == review.split.rev) then
        return done()
    end
    -- A diff the user made by hand is left alone.
    if vim.wo[win].diff and not (review.split and win == review.split.file) then
        return done()
    end

    vim.w[win].review_buf = buf
    if review.layout == 'unified' then
        gitsigns.diffthis(review.base, { unified = true }, vim.schedule_wrap(done))
        return
    end

    split_close()
    vim.w[win].review_buf = buf
    gitsigns.diffthis(review.base, { vertical = true }, vim.schedule_wrap(function()
        for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
            if other ~= win and vim.wo[other].diff then
                vim.wo[other].winfixbuf = true
                review.split = { file = win, rev = other }
            end
        end
        done()
    end))
end

local function review_close_all()
    split_close()
    -- gitsigns has no public way to ask whether a window has the inline view.
    -- Its internal module is asked when it is there, because the record
    -- alone goes wrong if a diffthis ever failed: the "close" would then open
    -- a view, after review mode had ended.
    local ok, unified = pcall(require, 'gitsigns.unified')
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local open = vim.w[win].review_buf == vim.api.nvim_win_get_buf(win)
        if ok and type(unified.get_view) == 'function' then
            open = unified.get_view(win) ~= nil
        end
        if open then
            -- Closing does no git work, so it finishes inside win_call
            -- rather than landing later in whichever window is current.
            vim.api.nvim_win_call(win, function()
                gitsigns.diffthis(nil, { unified = true })
            end)
        end
        vim.w[win].review_buf = nil
    end
end

vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "GitSignsUpdate",
    callback = function(args)
        if review.on and args.data and args.data.buffer == vim.api.nvim_get_current_buf() then
            review_open(vim.api.nvim_get_current_win())
        end
    end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function()
        if review.on then
            review_open(vim.api.nvim_get_current_win())
        end
    end,
})

-- gitsigns closes the inline view on this same event; forget it here as
-- well, or coming back to the buffer would look like the view were open.
vim.api.nvim_create_autocmd("BufWinLeave", {
    group = augroup,
    callback = function(args)
        if vim.w.review_buf == args.buf then
            vim.w.review_buf = nil
        end
    end,
})

-- Closing the revision window by hand ends the pair; the next file still
-- gets a new one while review mode is on.
vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
        local split = review.split
        if split and tonumber(args.match) == split.rev then
            review.split = nil
            if vim.api.nvim_win_is_valid(split.file) then
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(split.file) then
                        vim.api.nvim_win_call(split.file, function()
                            vim.cmd.diffoff()
                        end)
                    end
                end)
            end
        end
    end,
})

local function review_stop()
    review_close_all()
    review.on, review.base = false, nil
    gitsigns.toggle_word_diff(false)
    gitsigns.reset_base(true)
end

-- `:Review` compares against HEAD: everything not yet committed, staged or
-- not. `:Review main` compares against where this branch left main -- the
-- merge base, as a pull request would show it -- rather than main's tip,
-- which would also show main's own later commits as reverted here.
local function review_start(rev)
    local base = 'HEAD'
    if rev and rev ~= '' then
        local result = vim.system({ 'git', 'merge-base', rev, 'HEAD' }, { text = true }):wait()
        base = result.code == 0 and vim.trim(result.stdout) or rev
    end

    -- Off until the new base is in place: the GitSignsUpdate that changing
    -- it fires would otherwise open views against the old one, and race the
    -- quickfix window for focus.
    review_close_all()
    review.on, review.base = false, base
    -- Set here and nowhere else in review mode: changing word_diff makes
    -- gitsigns throw away every buffer's diff and recompute it, and a
    -- diffthis in that window fails the assertion described at the top. Turning it
    -- off for side by side, where vim already marks changed words, did that
    -- on every switch of layout.
    gitsigns.toggle_word_diff(true)
    gitsigns.change_base(base, true, function(err)
        if err then
            vim.notify('Review: ' .. err, vim.log.levels.ERROR)
            vim.schedule(review_stop)
            return
        end
        vim.schedule(function()
            review.on = true
            review_open(vim.api.nvim_get_current_win(), function()
                gitsigns.setqflist('all')
            end)
        end)
    end)
end

local function review_layout(layout)
    review.layout = layout
    if not review.on then
        return review_start()
    end
    -- The window the file is in, not the revision window, if that has focus.
    local win = vim.api.nvim_get_current_win()
    if review.split and win == review.split.rev then
        win = review.split.file
    end
    review_close_all()
    vim.api.nvim_set_current_win(win)
    review_open(win)
end

vim.api.nvim_create_user_command('Review', function(opts)
    if opts.bang then
        review_stop()
    else
        review_start(opts.args)
    end
end, {
    nargs = '?',
    bang = true,
    desc = 'Review the diff against HEAD, or against the merge base with a revision; ! to stop',
    complete = function(lead)
        local refs = vim.fn.systemlist({ 'git', 'for-each-ref', '--format=%(refname:short)' })
        return vim.tbl_filter(function(ref)
            return vim.startswith(ref, lead)
        end, refs)
    end,
})

vim.keymap.set('n', '<leader>gr', function()
    if review.on then
        review_stop()
    else
        review_start()
    end
end, { desc = 'Toggle review mode against HEAD' })

vim.keymap.set('n', '<leader>gs', function()
    review_layout(review.on and review.layout == 'split' and 'unified' or 'split')
end, { desc = 'Review side by side, or back to inline' })

vim.keymap.set('n', '<leader>gq', function()
    gitsigns.setqflist('all')
end, { desc = 'Every hunk in the repo to the quickfix list' })

-- Against the review base when reviewing, HEAD otherwise, and new files too.
vim.keymap.set('n', '<leader>gf', function()
    local root = vim.trim(vim.fn.system({ 'git', 'rev-parse', '--show-toplevel' }))
    if vim.v.shell_error ~= 0 then
        return vim.notify('Not in a git repository', vim.log.levels.WARN)
    end
    local paths = vim.fn.systemlist({ 'git', '-C', root, 'diff', '--name-only', review.base or 'HEAD' })
    vim.list_extend(paths, vim.fn.systemlist({ 'git', '-C', root, 'ls-files', '--others', '--exclude-standard' }))
    local items = vim.tbl_map(function(path)
        return vim.fn.fnamemodify(root .. '/' .. path, ':.')
    end, paths)
    require('mini.pick').start({ source = { items = items, name = 'Changed files' } })
end, { desc = 'Pick a changed file' })

vim.keymap.set('n', '<leader>gp', gitsigns.preview_hunk_inline, { desc = 'Show this hunk inline' })

-- In a :diffsplit, ]c and [c are vim's own and keep working the vim way.
for key, direction in pairs({ [']c'] = 'next', ['[c'] = 'prev' }) do
    vim.keymap.set('n', key, function()
        if vim.wo.diff then
            vim.cmd.normal({ key, bang = true })
        else
            gitsigns.nav_hunk(direction)
        end
    end, { desc = 'Jump to the ' .. direction .. ' hunk' })
end

-- Theme
--
-- gitsigns is themed as if the background were opaque. With
-- `transparent_background` the integration follows it by default, and that
-- variant paints a diff with foreground colours: every added line of the
-- inline review view (<leader>gr) went solid green text, and every changed
-- word dark text on green, hiding both treesitter and the LSP's semantic
-- highlighting. The opaque variant marks the same lines with background
-- colours only -- DiffAdd, as the side-by-side view does -- so the code
-- underneath keeps its own colours.
vim.pack.add({ { src = "https://github.com/catppuccin/nvim" } })
require('catppuccin').setup({
    transparent_background = true,
    integrations = {
        gitsigns = { enabled = true, transparent = false },
    },
})
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
