-- env: bare
-- The modal engine (lua/ide/modal.lua), with no plugins and no config around
-- it. Most cases drive it with a list of keys, which is what the injectable
-- key source is for; the last scenarios use the real getcharstr, because
-- whether <S-Tab> arrives as the bytes the declaration expects, whether an idle
-- mode really ends, and whether a replayed key really runs are things only the
-- real thing can answer.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')
package.path = os.getenv('NVIM_LUA') .. '/?.lua;' .. package.path

local modal = require('ide.modal')

-- Notifications are captured, not shown. An error message that is scheduled by
-- one scenario is printed during the next blocking read -- which is the first
-- real getcharstr -- and in a headless nvim that prompt eats the keys typed for
-- it. In use the message appears after the mode has ended, so this is only a
-- fact about the harness; capturing also lets the message be checked.
local notified = {}
vim.notify = function(message, level)
    table.insert(notified, { message = message, level = level })
end

local function source(keys)
    local i = 0
    return function()
        i = i + 1
        local key = keys[i]
        if key == nil then
            error('the key list ran out: the mode did not end where it should have')
        end
        if key == 'CTRL-C' then
            error('Keyboard interrupt')
        end
        return vim.keycode(key)
    end, function()
        return i
    end
end

local log
local function fresh()
    log = {}
end
local function note(what)
    return function(count)
        table.insert(log, ('%s%s'):format(what, count > 1 and ('x' .. count) or ''))
    end
end

T.section('declaring a mode')
local ok_missing = pcall(modal.define, 'bad1', { desc = 'x', keys = { { 'h', function() end } } })
T.check('a key with no desc is refused', ok_missing, false)
local ok_dup = pcall(modal.define, 'bad2', {
    desc = 'x',
    keys = { { 'h', function() end, desc = 'a' }, { 'h', function() end, desc = 'b' } },
})
T.check('a key bound twice is refused', ok_dup, false)

modal.define('t', {
    desc = 'A test mode',
    hint = 'h l',
    keys = {
        { 'h', note('h'), desc = 'left' },
        { 'l', note('l'), desc = 'right' },
        { '<S-Tab>', note('stab'), desc = 'back' },
        { 'q', function() table.insert(log, 'q') end, desc = 'quit', leave = true },
        { 'b', function() error('boom') end, desc = 'breaks' },
        { 'g', function() return { switch = 't2' } end, desc = 'go to t2' },
        { 'e', function() table.insert(log, 'in:' .. tostring(modal.current())) end, desc = 'reads current' },
        { 'n', function() return modal.enter('t', { getchar = function() return vim.keycode('<Esc>') end }) end, desc = 'nested' },
    },
    on_enter = function() table.insert(log, '+enter') end,
    on_leave = function() table.insert(log, '+leave') end,
})
modal.define('t2', {
    desc = 'A second test mode',
    keys = { { 'z', note('z'), desc = 'zed' } },
})
modal.define('quiet', {
    desc = 'Ignores foreign keys',
    foreign = 'ignore',
    keys = { { 'h', note('h'), desc = 'left' } },
})

local listed = modal.list()
T.check('modes are listed in declaration order', vim.tbl_map(function(m) return m.name end, listed), { 't', 't2', 'quiet' })
T.check('a listed mode carries its keys and their descs', listed[1].keys[1], { lhs = 'h', desc = 'left', leave = false })
T.check('a one-shot key is marked in the list', listed[1].keys[4].leave, true)

T.section('sticky keys, and Escape')
fresh()
local keys, used = source({ 'h', 'l', 'l', 'h', '<Esc>' })
local result = modal.enter('t', { getchar = keys })
T.check('every key ran, in order, with enter and leave around them', log, { '+enter', 'h', 'l', 'l', 'h', '+leave' })
T.check('Escape ends it', result.reason, 'escape')
T.check('four keys were the mode\'s own', result.keys, 4)
T.check('and Escape was the last thing read', used(), 5)
T.check('nothing is running afterwards', modal.current(), nil)

T.section('counts')
fresh()
modal.enter('t', { getchar = (source({ '5', 'l', '1', '2', 'h', 'h', '<Esc>' })) })
T.check('5l is one call with a count of 5, 12h one with 12, h alone none', log, { '+enter', 'lx5', 'hx12', 'h', '+leave' })
fresh()
local r = modal.enter('t', { getchar = (source({ '0', 'l' })) })
T.check('0 with no count before it is an ordinary unbound key', r.reason, 'foreign')
T.check('and is what gets replayed', r.replayed, '0')

T.section('one-shot keys')
fresh()
keys, used = source({ 'l', 'q', 'l' })
result = modal.enter('t', { getchar = keys })
T.check('a one-shot key runs and then leaves', log, { '+enter', 'l', 'q', '+leave' })
T.check('it says that is why', result.reason, 'key')
T.check('and the key after it was not read', used(), 2)

T.section('keys the mode does not own')
fresh()
keys, used = source({ 'l', 'w', 'l' })
result = modal.enter('t', { getchar = keys })
T.check('the mode ends on the first one', log, { '+enter', 'l', '+leave' })
T.check('reason', result.reason, 'foreign')
T.check('the key is handed back to be run as typed', result.replayed, 'w')
T.check('and nothing after it was read', used(), 2)
fresh()
result = modal.enter('t', { getchar = (source({ '3', 'w' })) })
T.check('a count typed before it goes with it', result.replayed, '3w')
fresh()
keys, used = source({ 'x', 'h', 'y', 'h', '<Esc>' })
result = modal.enter('quiet', { getchar = keys })
T.check('foreign = "ignore" swallows them and stays', log, { 'h', 'h' })
T.check('until Escape', result.reason, 'escape')

T.section('failures end the mode instead of repeating')
fresh()
result = modal.enter('t', { getchar = (source({ 'l', 'b', 'l' })) })
T.check('an error in a key leaves the mode', result.reason, 'error')
T.check('leave still ran, and the key after the error did not', log, { '+enter', 'l', '+leave' })
vim.wait(20)
T.check('and the error is reported, naming the mode and what went wrong', #notified == 1 and notified[1].message:match('^t mode: .*boom') ~= nil, true)
T.check('at error level', notified[1] and notified[1].level, vim.log.levels.ERROR)
T.check('nothing is left running', modal.current(), nil)
fresh()
result = modal.enter('t', { getchar = (source({ 'l', 'CTRL-C' })) })
T.check('Ctrl-C leaves', result.reason, 'interrupt')
T.check('and leave ran', log, { '+enter', 'l', '+leave' })

T.section('a mode that has to let the page move')
modal.define('reader', {
    desc = 'Reads',
    pass = { '<C-d>', '<C-u>' },
    keys = { { 'j', note('j'), desc = 'next' } },
})
vim.cmd('enew!')
local tall = {}
for i = 1, 200 do tall[i] = 'line ' .. i end
vim.api.nvim_buf_set_lines(0, 0, -1, false, tall)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
fresh()
result = modal.enter('reader', { getchar = (source({ 'j', '<C-d>', 'j', '<Esc>' })) })
T.check('a pass key does not end the mode: the key after it still ran', log, { 'j', 'j' })
T.check('it ended by Escape', result.reason, 'escape')
T.ok('and the page did move', vim.api.nvim_win_get_cursor(0)[1] > 1, vim.api.nvim_win_get_cursor(0))
local moved = vim.api.nvim_win_get_cursor(0)[1]
result = modal.enter('reader', { getchar = (source({ '<C-u>', '<Esc>' })) })
T.ok('and Ctrl-u moves it back', vim.api.nvim_win_get_cursor(0)[1] < moved)
local cheat = modal.list()[#modal.list()].keys
T.check('the cheatsheet lists the keys that scroll as one entry', cheat[#cheat].desc, 'Scroll; the mode stays')

T.section('switching and nesting')
fresh()
result = modal.enter('t', { getchar = (source({ 'g', 'z', '<Esc>' })) })
T.check('a key can hand over to another mode', log, { '+enter', '+leave', 'z' })
T.check('which then ends the usual way', result.reason, 'escape')
T.check('and remembers how the first one ended', result.previous.reason, 'key')
fresh()
local inner
modal.define('outer', { desc = 'x', keys = { { 'n', function() inner = modal.enter('outer', { getchar = function() return vim.keycode('<Esc>') end }) end, desc = 'nested' } } })
modal.enter('outer', { getchar = (source({ 'n', '<Esc>' })) })
T.check('a mode cannot be entered from inside itself', inner.reason, 'busy')
fresh()
modal.enter('t', { getchar = (source({ 'e', '<Esc>' })) })
T.check('current() names the mode while it runs', log, { '+enter', 'in:t', '+leave' })

T.section('what must not wedge a mode')
-- A statusline that throws: the mode redraws it after every key, and the error
-- used to come out of the loop and leave the mode "running" for good.
local saved_statusline = vim.o.statusline
vim.o.statusline = "%!luaeval('error(\"boom\")')"
fresh()
result = modal.enter('t', { getchar = (source({ 'l', 'l', '<Esc>' })) })
T.check('a statusline that throws does not end it', log, { '+enter', 'l', 'l', '+leave' })
T.check('it ended by Escape', result.reason, 'escape')
T.check('and it is not left running', modal.current(), nil)
vim.o.statusline = saved_statusline

modal.define('breaks on entry', {
    desc = 'x',
    on_enter = function() error('cannot start') end,
    on_leave = function() table.insert(log, 'left anyway') end,
    keys = { { 'h', note('h'), desc = 'left' } },
})
fresh()
result = modal.enter('breaks on entry', { getchar = (source({ 'h' })) })
T.check('something unexpected inside the loop is an error', result.reason, 'error')
T.check('the mode still had its leave called', log, { 'left anyway' })
T.check('and is not left running', modal.current(), nil)
vim.wait(20)
T.ok('and the error was reported', #notified >= 1 and notified[#notified].message:find('cannot start', 1, true) ~= nil, notified[#notified])
result = modal.enter('t', { getchar = (source({ '<Esc>' })) })
T.check('so the next mode can be entered', result.reason, 'escape')

T.section('the real getcharstr')
fresh()
local buf = vim.api.nvim_get_current_buf()
vim.defer_fn(function() vim.api.nvim_input('hl') end, 20)
vim.defer_fn(function() vim.api.nvim_input('<S-Tab>') end, 50)
vim.defer_fn(function() vim.api.nvim_input('<Esc>') end, 80)
result = modal.enter('t')
T.check('typed keys reach the keys, and <S-Tab> is the same key as declared', log, { '+enter', 'h', 'l', 'stab', '+leave' })
T.check('Escape ends it', result.reason, 'escape')
T.check('the keyboard buffer is empty afterwards', vim.fn.getchar(1), 0)

T.section('the idle timeout')
modal.define('idle', { desc = 'Short fuse', idle = 250, keys = { { 'h', note('h'), desc = 'left' } } })
fresh()
local t0 = vim.uv.hrtime()
result = modal.enter('idle')
local took = (vim.uv.hrtime() - t0) / 1e6
T.check('untouched, it ends itself', result.reason, 'timeout')
T.ok('after about the idle time, not instantly and not much later', took >= 230 and took < 900, took)
T.check('and nothing is left running', modal.current(), nil)
vim.wait(150)
T.check('the Escape it typed was consumed, none left to leak into Normal mode', vim.fn.getchar(1), 0)

fresh()
t0 = vim.uv.hrtime()
for _, at in ipairs({ 150, 300, 450 }) do
    vim.defer_fn(function() vim.api.nvim_input('h') end, at)
end
result = modal.enter('idle')
took = (vim.uv.hrtime() - t0) / 1e6
T.check('a key restarts the clock', log, { 'h', 'h', 'h' })
T.ok('so it ended an idle period after the last one, not after the first', took >= 650 and took < 1300, took)
T.check('still a timeout', result.reason, 'timeout')

T.section('replaying a foreign key')
vim.cmd('enew!')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abcdef' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.defer_fn(function() vim.api.nvim_input('x') end, 20)
result = modal.enter('t')
T.check('the mode ended on a key it does not own', result.reason, 'foreign')
vim.api.nvim_feedkeys('', 'x', false)
T.check('and that key then ran as a Normal-mode command', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], 'bcdef')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.defer_fn(function() vim.api.nvim_input('2x') end, 20)
modal.enter('t')
vim.api.nvim_feedkeys('', 'x', false)
T.check('with its count', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], 'def')

T.finish()
