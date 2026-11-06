-- env: full
-- LSP lookups and the lists they end up in: the picker (drop, send), a single
-- result jumping, the hierarchies, the keys that start them, the stack pickers.
--
-- The language server is a fake, written in Lua (lib.lua): what is under test is
-- what this config does with an answer, and a real server would make that depend
-- on a project loading. Where a real server matters -- what Roslyn actually
-- returns -- test_roslyn.lua asks it.
--
-- The files are in a scratch directory that is made the working directory, so
-- paths are shown relative to it as they are in use, and "Aaa.Tests" is named to
-- sort *before* the others: results come back in path order, so the tests-last
-- rule only shows when the test file would otherwise have been first.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

local root = vim.uv.fs_realpath(vim.fn.tempname() .. '')
do
    root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    root = vim.uv.fs_realpath(root)
end

local function write(path, lines)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines, full)
    return full
end

local alpha = write('src/Alpha.cs', {
    'class Alpha',
    '{',
    '    public static int Run() => 1;',
    '}',
})
local beta = write('src/Beta.cs', {
    'class Beta',
    '{',
    '    int y = Alpha.Run();',
    '}',
})
local gamma = write('src/Gamma.cs', {
    'class Gamma',
    '    static int z = Alpha.Run();',
})
local tests = write('Aaa.Tests/AlphaTests.cs', {
    'class AlphaTests',
    '    void T() { Alpha.Run(); }',
})
vim.cmd.cd(root)

local function loc(file, line, col, to)
    return {
        uri = vim.uri_from_fname(file),
        range = {
            start = { line = line - 1, character = col - 1 },
            ['end'] = { line = line - 1, character = (to or col + 2) },
        },
    }
end
local function item(name, file, line, col, detail)
    local range = loc(file, line, col).range
    return { name = name, kind = 6, detail = detail, uri = vim.uri_from_fname(file), range = range, selectionRange = range }
end

local references = { loc(alpha, 3, 24, 26), loc(beta, 3, 16, 18), loc(gamma, 2, 24, 26), loc(tests, 2, 22, 24) }
local current_references = references

local server = T.fake_server({
    capabilities = {
        definitionProvider = true,
        referencesProvider = true,
        implementationProvider = true,
        typeDefinitionProvider = true,
        callHierarchyProvider = true,
        typeHierarchyProvider = true,
    },
    responses = {
        ['textDocument/references'] = function() return current_references end,
        ['textDocument/definition'] = function() return { loc(alpha, 3, 24, 26) } end,
        ['textDocument/implementation'] = function() return { loc(beta, 3, 16, 18), loc(gamma, 2, 24, 26) } end,
        ['textDocument/typeDefinition'] = function() return { loc(beta, 1, 7, 10) } end,
        ['textDocument/prepareCallHierarchy'] = function() return { item('Run', alpha, 3, 24) } end,
        ['callHierarchy/incomingCalls'] = function()
            return {
                { from = item('Beta.y', beta, 3, 9), fromRanges = { loc(beta, 3, 16, 18).range } },
                { from = item('AlphaTests.T', tests, 2, 10), fromRanges = { loc(tests, 2, 22, 24).range } },
            }
        end,
        ['callHierarchy/outgoingCalls'] = function(params)
            return {
                { to = item('Console.WriteLine', gamma, 1, 1), fromRanges = { loc(alpha, 3, 30, 31).range } },
                { to = item('Helper', gamma, 2, 5), fromRanges = { loc(alpha, 3, 24, 26).range } },
            }
        end,
        ['textDocument/prepareTypeHierarchy'] = function() return { item('Alpha', alpha, 1, 7) } end,
        ['typeHierarchy/supertypes'] = function()
            return { item('Base', gamma, 1, 7, 'Lib'), item('IThing', beta, 1, 7, 'Lib') }
        end,
    },
})

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level }) end
local function last_note()
    return notified[#notified] and notified[#notified].message
end

-- Not `:edit` when already there: re-editing the current file frees and reads
-- it again, and a server attached by hand (as the fake is) is detached by that
-- for good. A real config re-attaches on FileType through vim.lsp.enable.
local function go_to_alpha()
    vim.cmd('silent only!')
    if vim.api.nvim_buf_get_name(0) ~= alpha then
        vim.cmd('edit ' .. alpha)
    end
    vim.api.nvim_win_set_cursor(0, { 3, 24 })
end

-- Stop whatever is attached to this buffer, wait until it really has gone, and
-- attach `other`. Stopping is not instant, and a server left running would still
-- answer for the buffer -- with more than one call-hierarchy item to choose
-- between, a question that is asked of a person.
local function use(other)
    local buf = vim.api.nvim_get_current_buf()
    local ids = {}
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        table.insert(ids, c.id)
        c:stop(true)
    end
    T.wait(3000, function()
        for _, client_id in ipairs(ids) do
            if vim.lsp.get_client_by_id(client_id) then
                return false
            end
        end
        return true
    end)
    return other.attach(buf)
end

local function listed()
    return vim.tbl_map(function(entry)
        return ('%s:%d'):format(vim.fn.fnamemodify(vim.fn.bufname(entry.bufnr), ':.'), entry.lnum)
    end, vim.fn.getqflist())
end

local function press(lhs)
    local map = vim.fn.maparg(lhs, 'n', false, true)
    assert(map.callback, 'nothing is mapped to ' .. lhs)
    map.callback()
end

local function stack_titles(loc_win)
    local titles = {}
    local get = loc_win and function(w) return vim.fn.getloclist(loc_win, w) end or function(w) return vim.fn.getqflist(w) end
    for nr = 1, get({ nr = '$' }).nr do
        titles[#titles + 1] = get({ nr = nr, title = 0 }).title
    end
    return titles
end

T.section('the config loads, and the server attaches')
T.check('no module failed', vim.g.ide_failed, {})
go_to_alpha()
local client = server.attach(vim.api.nvim_get_current_buf())
T.ok('the fake server attached', client ~= nil)

T.section('the keys')
T.check('grr is ours, with its own description', vim.fn.maparg('grr', 'n', false, true).desc,
    'Find the usages of the symbol: pick, drop, send to a list')
for _, lhs in ipairs({ 'gri', 'grt', 'grb', 'grc', 'grC', '<Space>fq', '<Space>fl' }) do
    T.ok(lhs .. ' is bound', vim.fn.maparg(vim.keycode(lhs), 'n') ~= '' or vim.fn.maparg(vim.keycode(lhs), 'n', false, true).callback ~= nil)
end
T.check('gd is bound in a buffer with a server', vim.fn.maparg('gd', 'n', false, true).buffer, 1)
vim.cmd('enew')
T.check('and is Vim\'s own gd elsewhere, not ours', vim.fn.maparg('gd', 'n'), '')
go_to_alpha()

T.section('usages: a picker, drop what is noise, send what is left')
local stack_before = vim.fn.getqflist({ nr = '$' }).nr
local sent
local seen = {}
T.picker_script({
    function()
        local items = require('mini.pick').get_picker_items()
        seen.count = #items
        seen.order = vim.tbl_map(function(i) return vim.fn.fnamemodify(i.path, ':.') end, items)
        seen.first_text = items[1].text
        seen.name = require('mini.pick').get_picker_opts().source.name
    end,
    '<C-d>',
    function()
        seen.after_drop = #require('mini.pick').get_picker_items()
        seen.name_after = require('mini.pick').get_picker_opts().source.name
    end,
    '<C-q>',
})
press('grr')
T.ok('the picker closed after sending', T.wait(5000, function()
    return vim.fn.getqflist({ nr = '$' }).nr > stack_before
end))
T.check('the request was for references, including the declaration', server.asked('textDocument/references')[1].params.context,
    { includeDeclaration = true })
T.check('at the cursor', server.asked('textDocument/references')[1].params.position, { line = 2, character = 24 })
T.check('four results', seen.count, 4)
T.check('in file order, the test project last although it sorts first', seen.order,
    { 'src/Alpha.cs', 'src/Beta.cs', 'src/Gamma.cs', 'Aaa.Tests/AlphaTests.cs' })
T.check('each shows where it is and what is there', seen.first_text, 'src/Alpha.cs:3:24  public static int Run() => 1;')
T.check('the picker is named for what was asked, and how many', seen.name, 'References: Run (4)')
T.check('Ctrl-d dropped the one under the cursor', seen.after_drop, 3)
T.check('and the name counts what is left', seen.name_after, 'References: Run (3)')
T.check('the first was the one dropped, so the list is the other three', listed(),
    { 'src/Beta.cs:3', 'src/Gamma.cs:2', 'Aaa.Tests/AlphaTests.cs:2' })
T.check('it is titled with what was sent', vim.fn.getqflist({ title = 0 }).title, 'References: Run (3)')
T.check('it went to the end of the stack', vim.fn.getqflist({ nr = '$' }).nr, stack_before + 1)
T.check('and is the current list', vim.fn.getqflist({ nr = 0 }).nr, stack_before + 1)
T.ok('the quickfix window is open', vim.fn.getqflist({ winid = 0 }).winid ~= 0)
T.check('the first entry is the one we are on', vim.fn.getqflist({ idx = 0 }).idx, 1)
T.ok('in the file window, not the list', vim.bo.buftype == '' and vim.fn.expand('%:t') == 'Beta.cs', vim.fn.expand('%:t'))
vim.api.nvim_feedkeys(']q', 'x', false)
T.check(']q then goes to the second', vim.fn.expand('%:t'), 'Gamma.cs')
vim.cmd('cclose')

T.section('Tab previews the one under the cursor, without leaving where you are')
local preview = {}
T.picker_script({
    function()
        local target = require('mini.pick').get_picker_state().windows.target
        preview.target_buf_before = vim.api.nvim_win_get_buf(target)
        preview.jumps_before = #vim.fn.getjumplist()[1]
        local known = vim.fn.bufnr(beta)
        preview.beta_loaded_before = known ~= -1 and vim.api.nvim_buf_is_loaded(known)
    end,
    '<C-n>',
    '<Tab>',
    function()
        local pick = require('mini.pick')
        local state = pick.get_picker_state()
        local win = state.windows.main
        local buf = vim.api.nvim_win_get_buf(win)
        preview.shows_preview = state.buffers.preview ~= nil and buf == state.buffers.preview
        preview.text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        preview.cursor_line = vim.api.nvim_win_get_cursor(win)[1]
        preview.target_buf = vim.api.nvim_win_get_buf(state.windows.target)
    end,
    '<C-n>',
    function()
        local pick = require('mini.pick')
        local buf = vim.api.nvim_win_get_buf(pick.get_picker_state().windows.main)
        preview.moved = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    end,
    '<Tab>',
    function()
        local state = require('mini.pick').get_picker_state()
        preview.back_to_list = state.buffers.preview == nil or vim.api.nvim_win_get_buf(state.windows.main) == state.buffers.main
    end,
    '<Esc>',
})
go_to_alpha()
press('grr')
T.ok('the picker opened and closed', T.wait(5000, function() return preview.back_to_list ~= nil end))
T.ok('Tab shows a preview in the picker\'s own window', preview.shows_preview)
T.ok('it is the file the second result is in', table.concat(preview.text, '\n'):find('Beta', 1, true) ~= nil, preview.text)
T.check('the cursor is on the result\'s line, which is in view', { preview.cursor_line, preview.text[preview.cursor_line] }, { 3, vim.fn.readfile(beta)[3] })
T.check('the window you will return to still shows the buffer it did', preview.target_buf, preview.target_buf_before)
T.check('and no jump was recorded: Ctrl-o goes where it did', #vim.fn.getjumplist()[1], preview.jumps_before)
T.ok('moving down while previewing shows the next result', preview.moved:find('Gamma', 1, true) ~= nil, preview.moved)
T.ok('Tab again is the list', preview.back_to_list)
local known = vim.fn.bufnr(beta)
T.check('and loaded no buffer for the file', known ~= -1 and vim.api.nvim_buf_is_loaded(known), preview.beta_loaded_before)

T.section('marking, and sending only the narrowed list')
local marked_count, narrowed
T.picker_script({
    '<C-x>', '<C-n>', '<C-x>',
    function() marked_count = #require('mini.pick').get_picker_matches().marked_inds end,
    '<C-d>',
    function() narrowed = #require('mini.pick').get_picker_items() end,
    'G', 'a', 'm',
    function() seen.matches = #require('mini.pick').get_picker_matches().all end,
    '<C-q>',
})
go_to_alpha()
local before = vim.fn.getqflist({ nr = '$' }).nr
press('grr')
T.ok('sent', T.wait(5000, function() return vim.fn.getqflist({ nr = '$' }).nr > before end))
T.check('two marked', marked_count, 2)
T.check('Ctrl-d dropped both marked ones, not the one under the cursor', narrowed, 2)
T.check('typing narrowed what was left to one', seen.matches, 1)
T.check('and only that one was sent', listed(), { 'src/Gamma.cs:2' })
vim.cmd('cclose')

T.section('the location list, for this window')
go_to_alpha()
local win = vim.api.nvim_get_current_win()
local qf_before = vim.fn.getqflist({ nr = '$' }).nr
T.picker_script({ '<M-q>' })
press('grr')
T.ok('a location list was made', T.wait(5000, function() return vim.fn.getloclist(win, { size = 0 }).size > 0 end))
T.check('it holds all four', vim.fn.getloclist(win, { size = 0 }).size, 4)
T.check('titled the same way', vim.fn.getloclist(win, { title = 0 }).title, 'References: Run (4)')
T.check('the quickfix stack was not touched', vim.fn.getqflist({ nr = '$' }).nr, qf_before)
T.ok('its window is open', vim.fn.getloclist(win, { winid = 0 }).winid ~= 0)
vim.cmd('lclose')

T.section('a single result is jumped to')
current_references = { loc(beta, 3, 16, 18) }
go_to_alpha()
local origin = vim.api.nvim_win_get_cursor(0)
press('grr')
T.ok('and we are there', T.wait(5000, function() return vim.fn.expand('%:t') == 'Beta.cs' end))
T.check('at the position', vim.api.nvim_win_get_cursor(0), { 3, 15 })
local stack = vim.fn.gettagstack()
T.check('the tag stack has the jump', #stack.items, 1)
T.check('named for the word it started from', stack.items[1].tagname, 'Run')
vim.cmd('pop')
T.check('so Ctrl-t comes back', { vim.fn.expand('%:t'), vim.api.nvim_win_get_cursor(0)[1] }, { 'Alpha.cs', origin[1] })
vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'x', false)
T.ok('and the jump is in the jump list too', true)

T.section('a single result where the cursor already is')
current_references = { loc(alpha, 3, 24, 26) }
go_to_alpha()
notified = {}
press('grr')
T.ok('says so', T.wait(5000, function() return #notified > 0 end))
T.ok('rather than doing nothing, silently', last_note():find('Only this one', 1, true) ~= nil, last_note())
T.check('and stays', vim.fn.expand('%:t'), 'Alpha.cs')
current_references = references

T.section('nothing found')
current_references = {}
notified = {}
press('grr')
T.ok('the language server\'s own message is passed on', T.wait(5000, function() return #notified > 0 end))
T.check('no picker was opened', require('mini.pick').is_picker_active(), false)
current_references = references

T.section('implementations, the type, the definition')
T.picker_script({ '<Esc>' })
press('gri')
T.ok('two implementations are picked from', T.wait(5000, function() return #server.asked('textDocument/implementation') > 0 end))
vim.wait(300)
T.check('and Escape leaves nothing behind', require('mini.pick').is_picker_active(), false)
go_to_alpha()
press('grt')
T.ok('one type: jumped to', T.wait(5000, function() return vim.fn.expand('%:t') == 'Beta.cs' end))
T.check('on the line', vim.api.nvim_win_get_cursor(0)[1], 1)
go_to_alpha()
vim.cmd('edit ' .. beta)
vim.api.nvim_win_set_cursor(0, { 3, 16 })
local beta_client = server.attach(vim.api.nvim_get_current_buf())
vim.api.nvim_feedkeys('gd', 'x', false)
T.ok('gd goes to the definition', T.wait(5000, function() return vim.fn.expand('%:t') == 'Alpha.cs' end))
T.check('at the declaration', vim.api.nvim_win_get_cursor(0), { 3, 23 })

T.section('callers')
go_to_alpha()
local callers = {}
T.picker_script({
    function()
        callers.items = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items())
        callers.name = require('mini.pick').get_picker_opts().source.name
    end,
    '<C-q>',
})
before = vim.fn.getqflist({ nr = '$' }).nr
press('grc')
T.ok('a list of callers was made', T.wait(5000, function() return vim.fn.getqflist({ nr = '$' }).nr > before end))
T.check('named for the question', callers.name, 'Callers: Run (2)')
T.check('each says who calls, then what is there', callers.items, {
    'src/Beta.cs:3:16  Beta.y  │  int y = Alpha.Run();',
    'Aaa.Tests/AlphaTests.cs:2:22  AlphaTests.T  │  void T() { Alpha.Run(); }',
})
T.check('the server was asked about what prepare returned', server.asked('callHierarchy/incomingCalls')[1].params.item.name, 'Run')
T.check('the list is the same entries', #vim.fn.getqflist(), 2)
vim.cmd('cclose')

T.section('callees')
go_to_alpha()
local callees = {}
T.picker_script({
    function() callees.items = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items()) end,
    '<Esc>',
})
press('grC')
T.ok('the question was asked', T.wait(5000, function() return #server.asked('callHierarchy/outgoingCalls') > 0 end))
vim.wait(300)
T.check('the places are in the item that was asked about, in the order of the code', callees.items, {
    'src/Alpha.cs:3:24  Helper  │  public static int Run() => 1;',
    'src/Alpha.cs:3:30  Console.WriteLine  │  public static int Run() => 1;',
})

T.section('several things under the cursor: ask which')
local asked_which
local real_select = vim.ui.select
server.requests = {}
local two = { item('Run', alpha, 3, 24), item('Run', beta, 3, 9, 'overload') }
local real_prepare = server
vim.ui.select = function(choices, opts, on_choice)
    asked_which = { count = #choices, prompt = opts.prompt, shown = vim.tbl_map(opts.format_item, choices) }
    on_choice(choices[2])
end
-- the fake answers prepare with two items for this one request
local original = server.asked
local calls = 0
local fake2 = T.fake_server({
    name = 'fake_two',
    capabilities = { callHierarchyProvider = true },
    responses = {
        ['textDocument/prepareCallHierarchy'] = function() return two end,
        ['callHierarchy/incomingCalls'] = function(params)
            return { { from = item('From ' .. params.item.name .. ' in ' .. vim.fn.fnamemodify(vim.uri_to_fname(params.item.uri), ':t'), gamma, 2, 5), fromRanges = { loc(gamma, 2, 24, 26).range } } }
        end,
    },
})
vim.cmd('edit ' .. gamma)
vim.api.nvim_win_set_cursor(0, { 2, 24 })
use(fake2)
before = vim.fn.getqflist({ nr = '$' }).nr
press('grc')
T.ok('it asked', T.wait(5000, function() return asked_which ~= nil end))
T.check('with both of them', asked_which.count, 2)
T.ok('named, with the detail where there is one', asked_which.shown[2]:find('overload', 1, true) ~= nil, asked_which.shown)
vim.wait(500)
T.check('and used the one chosen', fake2.asked('callHierarchy/incomingCalls')[1].params.item.detail, 'overload')
T.check('which was a single result there, so it was jumped to', vim.fn.expand('%:t'), 'Gamma.cs')
vim.ui.select = real_select

T.section('a server that cannot, and one that fails')
vim.cmd('edit ' .. gamma)
local weak = T.fake_server({ name = 'fake_weak', capabilities = { referencesProvider = true } })
use(weak)
notified = {}
press('grc')
T.ok('callers say the server cannot', last_note() ~= nil and last_note():find('supports the call hierarchy', 1, true) ~= nil, last_note())
notified = {}
press('grb')
T.ok('and so do base types', last_note() ~= nil and last_note():find('supports the type hierarchy', 1, true) ~= nil, last_note())

local failing = T.fake_server({
    name = 'fake_failing',
    capabilities = { callHierarchyProvider = true },
    responses = {
        ['textDocument/prepareCallHierarchy'] = function() return { item('Run', alpha, 3, 24) } end,
        ['callHierarchy/incomingCalls'] = { error = 'the project is still loading' },
    },
})
use(failing)
notified = {}
press('grc')
T.ok('an error from the server is shown, with what was being asked', T.wait(5000, function() return #notified > 0 end))
T.ok('naming it', last_note():find('Callers: the project is still loading', 1, true) ~= nil, last_note())

T.section('base types')
go_to_alpha()
use(server)
local bases = {}
T.picker_script({
    function() bases.items = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items()) end,
    '<Esc>',
})
press('grb')
T.ok('asked', T.wait(5000, function() return #server.asked('typeHierarchy/supertypes') > 0 end))
vim.wait(300)
T.check('each is named, with where it comes from, in the order the server gave', bases.items, {
    'src/Gamma.cs:1:7  Base Lib  │  class Gamma',
    'src/Beta.cs:1:7  IThing Lib  │  class Beta',
})

T.section('the stack of lists')
vim.fn.setqflist({}, 'f')
vim.call('setqflist', {}, ' ', { title = 'First', items = { { filename = alpha, lnum = 1, text = 'one' }, { filename = beta, lnum = 3, text = 'two' } } })
vim.call('setqflist', {}, ' ', { title = 'Second', items = { { filename = gamma, lnum = 2, text = 'three' } } })
vim.cmd('1chistory')
go_to_alpha()
local previews = {}
T.picker_script({
    function()
        previews.items = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items())
    end,
    '<CR>',
})
lists = require('ide.lists')
lists.stack('quickfix')
T.ok('picked', T.wait(5000, function() return vim.fn.getqflist({ nr = 0 }).nr == 2 end))
T.check('newest first, the current one marked', previews.items, { '  2  Second (1)', '▸ 1  First (2)' })
T.ok('and it is shown', T.wait(3000, function() return vim.fn.getqflist({ winid = 0 }).winid ~= 0 end))
vim.cmd('cclose')

T.section('the picker for lists that are not there')
vim.fn.setqflist({}, 'f')
notified = {}
lists.stack('quickfix')
T.ok('says there are none', last_note() ~= nil and last_note():find('No quickfix lists yet', 1, true) ~= nil, last_note())

T.section('dd in the quickfix window')
vim.call('setqflist', {}, ' ', { title = 'Three', items = {
    { filename = alpha, lnum = 1, text = 'a' }, { filename = beta, lnum = 1, text = 'b' }, { filename = gamma, lnum = 1, text = 'c' } } })
vim.cmd('copen')
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys('dd', 'x', false)
T.check('drops the entry under the cursor', #vim.fn.getqflist(), 2)
T.check('and the cursor stays on the one that slid up', vim.api.nvim_win_get_cursor(0)[1], 2)
vim.cmd('cclose')

vim.notify = real_notify
T.finish()
