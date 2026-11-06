-- env: full
-- The keys, the modes behind them, and the things that list them: run against
-- the real config, started the way it is started for real.
--
-- A mode is entered by calling the callback of the mapping that enters it, and
-- its keys are typed by timers, since the mode's loop is what is blocking while
-- they arrive. Feeding the entry key with feedkeys 'x' would not do: that runs
-- as :normal does, and under :normal getcharstr() returns <Esc> the moment the
-- typeahead is empty instead of waiting, so every mode ended before its first key.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

local function press(entry)
    local map = vim.fn.maparg(vim.keycode(entry), 'n', false, true)
    assert(map.callback, 'nothing is mapped to ' .. entry)
    map.callback()
end

local function run_mode(entry, keys, spy)
    vim.defer_fn(function() vim.api.nvim_input(keys) end, 60)
    if spy then
        vim.defer_fn(spy, 25)
    end
    press(entry)
end

local function reset_windows()
    vim.cmd('silent! only!')
    vim.cmd('enew!')
end

local function width(win) return vim.api.nvim_win_get_width(win) end
local function height(win) return vim.api.nvim_win_get_height(win) end

T.section('the config loads')
T.check('no module failed', vim.g.ide_failed, {})

T.section('every key of ours has a description')
T.check('none was made without one', require('ide.mapped').undescribed(), {})

local expected = {
    '<C-h>', '<C-j>', '<C-k>', '<C-l>', '<Space>ff', '<Space>fb', '<Space>fh', '<Space>fo', '<Space>fj',
    '<Space>fr', '<Space>fR', '<Space>fd', '<Space>fD', '<Space>fp', '<Space>/', '<Space>e', '<Space><Space>',
    '<Space>?', '<Space>q', '<Space>Q', ']e', '[e', '<Space>s', '<Space>m', '<Space>ws', '<Space>wv', '<Space>wc',
    '<Space>wo', '<Space>w=', '<Space>ww', '<Space>wr', ']c', '[c', '<Space>d', '<Space>D',
    '<Space>bb', '<Space>br', '<Space>bw', '<Space>tt', '<Space>tn', '<Space>tf', '<Space>tl',
}
local absent = {}
for _, lhs in ipairs(expected) do
    local map = vim.fn.maparg(vim.keycode(lhs), 'n', false, true)
    if vim.tbl_isempty(map) then
        table.insert(absent, lhs)
    end
end
T.check('and the ones this stage is about are all bound', absent, {})
T.check('the keys moved off the review prefix are gone', vim.fn.maparg(vim.keycode('<Space>h'), 'n'), '')
T.check('<leader>r is the review mode, not the config reload it was',
    vim.fn.maparg(vim.keycode('<Space>r'), 'n', false, true).desc, 'Mode: Review the diff, hunk by hunk')
T.check('<leader>D is the debug mode', vim.fn.maparg(vim.keycode('<Space>D'), 'n', false, true).desc,
    'Mode: Debug the program, step by step')

T.section('the wide find is the plain key and the shift one is this buffer')
do
    local pickers = require('mini.extra').pickers
    local real = { lsp = pickers.lsp, diagnostic = pickers.diagnostic }
    local seen
    pickers.lsp = function(opts) seen = { 'lsp', opts.scope } end
    pickers.diagnostic = function(opts) seen = { 'diagnostic', opts.scope } end
    local function pressed(keys)
        seen = nil
        vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
        return seen
    end
    T.check('fr: symbols of the solution', pressed('<Space>fr'), { 'lsp', 'workspace_symbol_live' })
    T.check('fR: symbols of this buffer', pressed('<Space>fR'), { 'lsp', 'document_symbol' })
    T.check('fs is not a find any more', vim.fn.maparg(vim.keycode('<Space>fs'), 'n'), '')
    T.check('fd: diagnostics of the open files', pressed('<Space>fd'), { 'diagnostic', 'all' })
    T.check('fD: diagnostics of this buffer', pressed('<Space>fD'), { 'diagnostic', 'current' })
    pickers.lsp, pickers.diagnostic = real.lsp, real.diagnostic
end

local float_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(float_buf)
vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { 'x' })
local ns = vim.api.nvim_create_namespace('test-x')
vim.diagnostic.set(ns, float_buf, { { lnum = 0, col = 0, message = 'something is wrong here' } })
vim.api.nvim_feedkeys(vim.keycode('<Space>d'), 'x', false)
local shown
for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
        shown = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    end
end
T.ok('<leader>d opens the diagnostics under the cursor', shown ~= nil and shown:find('something is wrong here', 1, true) ~= nil, shown)
vim.cmd('silent only!')
vim.diagnostic.reset(ns, float_buf)

T.section('moving between windows')
reset_windows()
-- A full-height window on the left, and two stacked on the right. With
-- 'splitright' on, which this config sets, a new vertical split is on the right
-- and is the one that gets split again, so go to its top by hand.
vim.cmd('vsplit')
vim.cmd('split')
vim.cmd('wincmd t')
vim.cmd('wincmd l')
local top_right = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys(vim.keycode('<C-h>'), 'x', false)
local left_column = vim.api.nvim_get_current_win()
T.ok('Ctrl-h goes left', left_column ~= top_right)
vim.api.nvim_feedkeys(vim.keycode('<C-l>'), 'x', false)
T.check('Ctrl-l goes back', vim.api.nvim_get_current_win(), top_right)
vim.api.nvim_feedkeys(vim.keycode('<C-j>'), 'x', false)
local bottom_right = vim.api.nvim_get_current_win()
T.ok('Ctrl-j goes down', bottom_right ~= top_right)
vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'x', false)
T.check('Ctrl-k goes up', vim.api.nvim_get_current_win(), top_right)
vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'x', false)
T.check('at the edge it stays put: nothing is handed to anything else', vim.api.nvim_get_current_win(), top_right)

T.section('the size mode')
reset_windows()
vim.cmd('vsplit')
vim.cmd('wincmd t')
local left = vim.api.nvim_get_current_win()
local before = width(left)
local label
run_mode('<Space>s', 'll<Esc>', function()
    label = require('ide.statusline').render(vim.api.nvim_get_current_win())
end)
T.check('two l are two steps wider', width(left), before + 10)
T.ok('the statusline named the mode while it ran', label and label:find('SIZE', 1, true) ~= nil, label)
T.ok('and does not afterwards', require('ide.statusline').render(left):find('SIZE', 1, true) == nil)
T.check('nothing is left running', require('ide.modal').current(), nil)

before = width(left)
run_mode('<Space>s', '3h<Esc>')
T.check('a count: 3h is three steps narrower', width(left), before - 15)

vim.cmd('split')
local lower = vim.api.nvim_get_current_win()
before = height(lower)
run_mode('<Space>s', 'k<Esc>')
T.check('k is shorter', height(lower), before - 5)
run_mode('<Space>s', 'jj<Esc>')
T.check('j is taller', height(lower), before + 5)

run_mode('<Space>s', '=<Esc>')
local wins = vim.api.nvim_list_wins()
T.ok('= makes the columns equal again', math.abs(width(wins[1]) - width(wins[#wins])) <= 1, { width(wins[1]), width(wins[#wins]) })

local current = vim.api.nvim_get_current_win()
local normal_width = width(current)
run_mode('<Space>s', 'm<Esc>')
T.ok('m maximises', width(current) > normal_width, width(current))
run_mode('<Space>s', 'm<Esc>')
T.check('and the next m puts it back', width(current), normal_width)

run_mode('<Space>s', 'x')
T.check('an unbound key leaves the mode, to be run as typed', require('ide.modal').current(), nil)
vim.api.nvim_feedkeys('', 'x', false)

T.section('the move mode')
reset_windows()
local function buffer_with(text)
    vim.cmd('enew')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
end
buffer_with('left')
vim.cmd('vsplit')
buffer_with('right')
vim.cmd('wincmd l')
buffer_with('moved')
local function order()
    local list = vim.api.nvim_tabpage_list_wins(0)
    table.sort(list, function(a, b) return vim.fn.win_screenpos(a)[2] < vim.fn.win_screenpos(b)[2] end)
    return vim.tbl_map(function(w) return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false)[1] end, list)
end
vim.cmd('wincmd t')
T.check('to begin with, the focused window is the right-hand one', #order(), 2)
vim.cmd('wincmd b')
local initial = order()
T.check('and they are in this order', initial, { initial[1], 'moved' })
local other = initial[1]
run_mode('<Space>m', 'h<Esc>')
T.check('h swaps it with its left neighbour', order(), { 'moved', other })
T.check('and it is still the one with focus', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], 'moved')
run_mode('<Space>m', 'l<Esc>')
T.check('l swaps it back', order(), { other, 'moved' })
run_mode('<Space>m', 'l<Esc>')
T.check('at the far edge it does not move further', order(), { other, 'moved' })
run_mode('<Space>m', 'x<Esc>')
T.check('x exchanges with the next window', order(), { 'moved', other })

T.section('going to errors')
reset_windows()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c', 'd', 'e', 'f' })
local ns = vim.api.nvim_create_namespace('keys-test')
local function diag(lnum, severity)
    return { lnum = lnum, col = 0, message = 'm' .. lnum, severity = severity }
end
vim.diagnostic.set(ns, 0, {
    diag(1, vim.diagnostic.severity.ERROR), diag(2, vim.diagnostic.severity.WARN),
    diag(4, vim.diagnostic.severity.ERROR),
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(']e', 'x', false)
T.check(']e goes to the first error after the cursor', vim.api.nvim_win_get_cursor(0)[1], 2)
vim.api.nvim_feedkeys(']e', 'x', false)
T.check('and the next one skips the warning between them', vim.api.nvim_win_get_cursor(0)[1], 5)
vim.api.nvim_feedkeys('[e', 'x', false)
T.check('[e goes back', vim.api.nvim_win_get_cursor(0)[1], 2)
vim.diagnostic.reset(ns)

T.section('the statusline')
local win = vim.api.nvim_get_current_win()
local plain = require('ide.statusline').render(win)
T.ok('has the file, and no mode, no review', plain:find('%f', 1, true) ~= nil and plain:find('REVIEW', 1, true) == nil, plain)
vim.diagnostic.set(ns, 0, { diag(0, vim.diagnostic.severity.ERROR), diag(1, vim.diagnostic.severity.ERROR), diag(2, vim.diagnostic.severity.WARN) })
local with = require('ide.statusline').render(win)
T.ok('counts errors and warnings', with:find('E2', 1, true) ~= nil and with:find('W1', 1, true) ~= nil, with)
vim.diagnostic.reset(ns)

local real_clients = vim.lsp.get_clients
vim.lsp.get_clients = function() error('the client list is unavailable') end
local fallback = require('ide.statusline').render(win)
T.ok('a statusline that fails falls back to a plain line with the file in it', fallback:find('%f', 1, true) ~= nil, fallback)
vim.lsp.get_clients = function() return { {} } end
T.ok('and a client without a name is not what makes it fail', require('ide.statusline').render(win):find('%f', 1, true) ~= nil)
vim.lsp.get_clients = real_clients

T.section('the cheatsheet and the palette')
local palette = require('ide.palette')
local sheet = table.concat(palette.key_lines(), '\n')
for _, want in ipairs({ '<C-h>', '<Space>ff', '<Space>fR', 'size ▸ h', 'size ▸ m', 'move ▸ x', 'ZR', 'grr' }) do
    T.ok('the cheatsheet lists ' .. want, sheet:find(want, 1, true) ~= nil)
end
T.ok('and not a default it has no use for', sheet:find('[a', 1, true) == nil)
T.ok('nor a plugin\'s map', sheet:find('Matchit', 1, true) == nil and sheet:find('%', 1, true) == nil)
T.ok('the arrow aliases are not repeated', sheet:find('<Left>', 1, true) == nil)
local list = table.concat(palette.palette_lines(), '\n')
for _, want in ipairs({ 'Mode: size', 'Mode: move', ':Review', ':Fresh', ':Forget' }) do
    T.ok('the palette offers ' .. want, list:find(want, 1, true) ~= nil)
end

T.finish()
