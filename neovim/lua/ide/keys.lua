-- Every key, in one place. The modules export what a key does; this file says
-- which key does it.
--
-- The grammar is the one hypr/modes.lua uses. A motion says where and means the
-- same thing everywhere: h j k l are left, down, up, right, as the Ctrl chords
-- below, as the modes in ide.modes and as SUPER+h in Hyprland. A verb is the
-- leader and a letter, and either does one thing or enters a mode, in which the
-- motions are bare (<leader>s then l, l, l). In Hyprland SHIFT widens a verb's
-- scope (SHIFT+M widens SUPER+M to the column). Here it narrows it, for the finds
-- that have a scope: <leader>fr is the symbols of the solution, the usual thing to
-- look for, and <leader>fR is the symbols of this buffer; fd and fD likewise. It is
-- fr, not fs, to be the r of grr: the two are the ones reached for together.
--
-- The leader groups:
--
--   f   find: files, buffers, recent, symbols, diagnostics, lists, sessions
--   w   windows, and writing
--   b   build, run, watch
--   t   test: all, nearest, file, last
--   s m r   size, move and review, which are modes (see ide.modes, ide.review)
--
-- Neovim's own `g`, `[` and `]` are the vocabulary for going somewhere and are
-- kept: gd, grr, gri, grt, ]d, ]q and the rest mean what Neovim says, and only
-- what happens to their results is this config's (ide.lists). `<leader>g` is
-- deliberately not a group. The review keys used to be there, one letter from
-- the LSP's `gr` family, and the two were mixed up in practice.
--
-- Every key has a description: it is what the cheatsheet (<leader>?) lists, and
-- tests/nvim/test_keys.lua fails for one that has none.
--
-- Loaded after the modules it binds and after options.lua, because <leader>
-- is expanded when a mapping is made.

local autosave = require('ide.autosave')
local completion = require('ide.completion')
local dotnet = require('ide.dotnet')
local lists = require('ide.lists')
local navigate = require('ide.navigate')
local palette = require('ide.palette')
local sessions = require('ide.sessions')
local gitsigns = require('gitsigns')

local map = vim.keymap.set

map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear the search highlight' })
map('t', '<Esc>', '<C-\\><C-n>', { desc = 'Leave terminal mode' })

-- Windows. Ctrl and a motion focuses; moving and resizing are modes.
for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do
    local where = ({ h = 'left', j = 'below', k = 'above', l = 'right' })[key]
    map('n', '<C-' .. key .. '>', '<cmd>wincmd ' .. key .. '<CR>', { desc = 'Focus the window ' .. where })
    map('t', '<C-' .. key .. '>', '<cmd>wincmd ' .. key .. '<CR>', { desc = 'Focus the window ' .. where })
end
-- Completion (ide.completion). The menu is Neovim's own, so <C-n>, <C-p>, <C-y>
-- and <C-e> are what they always were; these are the keys cmp had that it has no
-- equivalent for. <C-s> is Neovim's: signature help, by hand.
map('i', '<CR>', completion.confirm, { expr = true, desc = 'Accept the highlighted completion, or a new line' })
map({ 'i', 's' }, '<Tab>', completion.next, { expr = true, desc = 'Next completion or snippet placeholder, or a tab' })
map({ 'i', 's' }, '<S-Tab>', completion.previous, { expr = true, desc = 'Previous completion or snippet placeholder' })
map('i', '<C-Space>', completion.invoke, { desc = 'Ask for completions now' })
map('i', '<C-d>', completion.scroll(true), { desc = 'Scroll the documentation down while a menu is open' })
map('i', '<C-u>', completion.scroll(false), { desc = 'Scroll the documentation up while a menu is open' })

map('i', '<C-j>', '<C-o>j', { desc = 'Move the cursor down without leaving Insert mode' })
map('i', '<C-k>', '<C-o>k', { desc = 'Move the cursor up without leaving Insert mode' })
map('i', '<C-h>', '<C-o>h', { desc = 'Move the cursor left without leaving Insert mode' })
map('i', '<C-l>', '<C-o>l', { desc = 'Move the cursor right without leaving Insert mode' })

map('n', '<leader>ws', '<cmd>wincmd s<CR>', { desc = 'Split the window below' })
map('n', '<leader>wv', '<cmd>wincmd v<CR>', { desc = 'Split the window to the right' })
map('n', '<leader>wc', function()
    if #vim.api.nvim_list_wins() > 1 then
        vim.cmd.close()
    end
end, { desc = 'Close this window, unless it is the last' })
map('n', '<leader>wo', '<cmd>only<CR>', { desc = 'Close every other window' })
map('n', '<leader>w=', '<cmd>wincmd =<CR>', { desc = 'Make all windows equal' })
map('n', '<leader>ww', autosave.write, { desc = 'Write this buffer, if it can be' })
map('n', '<leader>wr', '<cmd>Fresh<CR>', { desc = "Restart with this directory's session deleted" })

map('n', '<leader><Tab>', '<cmd>bnext<CR>', { desc = 'Next buffer' })
map('n', '<leader><S-Tab>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })

-- Finding. Everything here is a picker (ide.pick), and mini.extra supplies the
-- ones for things Neovim already knows.
local extra = function(name, local_opts)
    return function()
        require('mini.extra').pickers[name](local_opts)
    end
end
local pick = function(name)
    return function()
        require('mini.pick').builtin[name]()
    end
end

map('n', '<leader>ff', pick('files'), { desc = 'Find a file' })
map('n', '<leader>fb', pick('buffers'), { desc = 'Find an open buffer' })
map('n', '<leader>fh', pick('help'), { desc = 'Find a help page' })
map('n', '<leader>fo', extra('oldfiles', { current_dir = true }), { desc = 'Find a recent file in this directory' })
map('n', '<leader>fj', extra('list', { scope = 'jump' }), { desc = 'Find a place in the jump list' })
map('n', '<leader>fr', extra('lsp', { scope = 'workspace_symbol_live' }), { desc = 'Find a symbol in the solution, as you type' })
map('n', '<leader>fR', extra('lsp', { scope = 'document_symbol' }), { desc = 'Find a symbol in this buffer' })
map('n', '<leader>fd', extra('diagnostic', { scope = 'all' }), { desc = 'Find a diagnostic in any open file' })
map('n', '<leader>fD', extra('diagnostic', { scope = 'current' }), { desc = 'Find a diagnostic in this buffer' })
map('n', '<leader>fp', sessions.select, { desc = 'Pick a session' })
map('n', '<leader>/', pick('grep_live'), { desc = 'Search the text of every file' })
map('n', '<leader>e', extra('explorer'), { desc = 'Browse the file system' })

map('n', '<leader><leader>', palette.palette, { desc = 'The palette: every command, action and mode' })
map('n', '<leader>?', palette.keys, { desc = 'List every key' })

-- Going somewhere with the language server. These are Neovim's own keys, kept;
-- what is new is where the results go (ide.navigate, ide.lists): one result is
-- jumped to, several are picked from, and the picker drops entries and sends
-- the rest to a list. `gd` is bound per buffer, when a server attaches; see
-- ide.navigate for why.
map('n', 'grr', navigate.references, { desc = 'Find the usages of the symbol: pick, drop, send to a list' })
map('n', 'gri', navigate.implementation, { desc = 'Go to the implementations of the symbol' })
map('n', 'grt', navigate.type_definition, { desc = 'Go to the type of the symbol' })
map('n', 'grb', navigate.base_types, { desc = 'Go to what this type derives from' })
map('n', 'grc', navigate.callers, { desc = 'Find who calls this' })
map('n', 'grC', navigate.callees, { desc = 'Find what this calls' })

-- Quickfix and the location list. Both are plain toggles here; what goes in
-- them, and in what order, is ide.lists. The pickers are for the stack: every
-- list that is still in it, to go back to one.
map('n', '<leader>fq', function() lists.stack('quickfix') end, { desc = 'Find a quickfix list in the stack' })
map('n', '<leader>fl', function() lists.stack('location') end, { desc = "Find one of this window's location lists" })
map('n', '<leader>q', function()
    vim.cmd(vim.fn.getqflist({ winid = 0 }).winid ~= 0 and 'cclose' or 'copen')
end, { desc = 'Show or hide the quickfix list' })
map('n', '<leader>Q', function()
    if vim.fn.getloclist(0, { winid = 0 }).winid ~= 0 then
        return vim.cmd.lclose()
    end
    local ok = pcall(vim.cmd.lopen)
    if not ok then
        vim.notify('This window has no location list', vim.log.levels.INFO)
    end
end, { desc = 'Show or hide this window\'s location list' })

-- Build and run (<leader>b) and test (<leader>t), which are ide.dotnet's. A build
-- or a test run goes on in the background and the result is a quickfix list; run
-- and watch are terminals. All of them are also commands -- :Build, :Run, :Watch,
-- :Test [all|file|nearest|last] -- for when there is something to add.
map('n', '<leader>bb', function() dotnet.build() end, { desc = 'Build the solution; errors go to a list' })
map('n', '<leader>br', function() dotnet.run() end, { desc = 'Run this project, in a terminal below' })
map('n', '<leader>bw', function() dotnet.watch() end, { desc = 'Run this project under dotnet watch' })
map('n', '<leader>tt', function() dotnet.test('all') end, { desc = 'Run all the tests; failures go to a list' })
map('n', '<leader>tn', function() dotnet.test('nearest') end, { desc = 'Run the test at the cursor' })
map('n', '<leader>tf', function() dotnet.test('file') end, { desc = 'Run the tests in this file' })
map('n', '<leader>tl', function() dotnet.test('last') end, { desc = 'Run the last tests again' })

-- Going to errors. The rest of [ and ] -- ]d, ]q, ]l, ]b -- is Neovim's.
map('n', ']e', function()
    vim.diagnostic.jump({ count = 1, severity = vim.diagnostic.severity.ERROR, float = true })
end, { desc = 'Next error' })
map('n', '[e', function()
    vim.diagnostic.jump({ count = -1, severity = vim.diagnostic.severity.ERROR, float = true })
end, { desc = 'Previous error' })

-- The diagnostics under the cursor, which is used all the time, so it has the
-- short key and the debug mode is the one on <leader>D. Neovim's own <C-w>d is a
-- chord that is awkward to type for something this frequent, and stays as it is.
-- <C-d> was considered and is not used: it scrolls half a page, which is more
-- frequent still.
map('n', '<leader>d', vim.diagnostic.open_float, { desc = 'Show the diagnostics under the cursor' })

-- Review is a mode, on <leader>r, and is declared with its keys in ide.review.
-- What stays out here is what is useful with no review running.
map('n', '<leader>hp', gitsigns.preview_hunk_inline, { desc = 'Preview this hunk inline' })

-- In a :diffsplit, ]c and [c are vim's own and keep working the vim way.
for key, direction in pairs({ [']c'] = 'next', ['[c'] = 'prev' }) do
    map('n', key, function()
        if vim.wo.diff then
            vim.cmd.normal({ key, bang = true })
        else
            gitsigns.nav_hunk(direction)
        end
    end, { desc = 'Jump to the ' .. direction .. ' hunk' })
end
