-- env: full
-- Review: what a revision means, the list of hunks and how it is stepped
-- through, the mode that does the stepping, and the things that have to stay
-- out of its way (the quickfix stack, the formatter).
--
-- The fixture is a repository where the three obvious answers to "compared
-- with what?" are three different ones, so that a test cannot pass by getting
-- the revision wrong in a way that happens to give the same count:
--
--   c0 --- c1 (tag v1) --- m2                     main
--             \
--              t1 --- t2                          topic (checked out)
--
--   t1 changes a.cs in two places; t2 adds src/c.cs and a test file.
--   m2 changes b.cs line 5, after topic left main.
--   The working tree has an uncommitted edit to b.cs line 2 and a new file.
--
-- So against HEAD there are two hunks, against BASE (c1, where topic left main)
-- six, and against main itself seven, because main's own change to b.cs shows
-- up as reverted -- the reading that `:Review main` used to avoid by quietly
-- meaning BASE.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

local ROOT = os.getenv('NVIM_ROOT')
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, 'p')
repo = vim.uv.fs_realpath(repo)

local function git(...)
    local result = vim.system(vim.list_extend({ 'git' }, { ... }), { cwd = repo, text = true }):wait()
    assert(result.code == 0, ('git %s: %s'):format(table.concat({ ... }, ' '), result.stderr))
    return vim.trim(result.stdout)
end

local function write(path, lines)
    local full = repo .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines, full)
end

local function numbered(count, prefix)
    local lines = {}
    for i = 1, count do
        lines[i] = (prefix or 'line') .. i
    end
    return lines
end

local function replace_line(path, number, text)
    local lines = vim.fn.readfile(repo .. '/' .. path)
    lines[number] = text
    vim.fn.writefile(lines, repo .. '/' .. path)
end

git('init', '-q', '-b', 'main')
write('README.md', { 'readme' })
write('a.cs', numbered(10))
git('add', '.')
git('commit', '-qm', 'c0')
local c0 = git('rev-parse', 'HEAD')

write('b.cs', numbered(8, 'b'))
git('add', '.')
git('commit', '-qm', 'c1')
git('tag', 'v1')
local c1 = git('rev-parse', 'HEAD')

git('checkout', '-q', '-b', 'topic')
replace_line('a.cs', 2, 'line2 changed')
replace_line('a.cs', 9, 'line9 changed')
git('commit', '-qam', 't1')
write('src/c.cs', numbered(3, 'c'))
write('Foo.Tests/CTests.cs', numbered(3, 't'))
git('add', '.')
git('commit', '-qm', 't2')
local topic = git('rev-parse', 'HEAD')

git('checkout', '-q', 'main')
replace_line('b.cs', 5, 'b5 changed on main')
git('commit', '-qam', 'm2')
local m2 = git('rev-parse', 'HEAD')
git('checkout', '-q', 'topic')

replace_line('b.cs', 2, 'b2 edited, not committed')
write('new.cs', { 'brand', 'new' })

vim.cmd.cd(repo)

local gitrev = require('ide.gitrev')
local review = require('ide.review')
local modal = require('ide.modal')

-- Starting finishes later, in steps. A test that goes on once `on` is set would
-- be racing the rest of it, so this waits for all of it, for this commit.
local function started(commit, size)
    return T.wait(15000, function()
        return review.state.ready and review.state.commit == commit
            and review.list_info() ~= nil and (size == nil or review.list_info().size == size)
    end)
end

T.section('the config loads')
T.check('no module failed', vim.g.ide_failed, {})

T.section('what a revision means')
local function commit_of(spec)
    local resolved, err = gitrev.resolve(spec)
    return resolved and resolved.commit, err
end
T.check('nothing is HEAD', commit_of(nil), topic)
T.check('an empty string is HEAD', commit_of(''), topic)
T.check('HEAD', commit_of('HEAD'), topic)
T.check('BASE is where this branch left main', commit_of('BASE'), c1)
T.check('BASE:main says so outright', commit_of('BASE:main'), c1)
T.check('BASE~1 is the commit before it', commit_of('BASE~1'), c0)
T.check('BASE^ is the same', commit_of('BASE^'), c0)
T.check('a branch is its tip, not where this branch left it', commit_of('main'), m2)
T.check('a tag', commit_of('v1'), c1)
T.check('a commit, abbreviated', commit_of(c0:sub(1, 8)), c0)
T.check('HEAD~1', commit_of('HEAD~1'), git('rev-parse', 'HEAD~1'))
T.check('the label is what was typed', gitrev.resolve('BASE:main').label, 'BASE:main')

local missing, err = commit_of('BASE:nope')
T.check('an unknown branch after BASE: is refused', missing, nil)
T.ok('and says which', err:find('no branch called nope', 1, true) ~= nil, err)
missing, err = commit_of('nope')
T.check('an unknown revision is refused', missing, nil)
T.ok('and says so', err:find('unknown revision: nope', 1, true) ~= nil, err)
missing, err = commit_of('BASE~99')
T.check('a suffix that names nothing is refused', missing, nil)

git('branch', 'BASEBALL', c0)
T.check('a branch that merely starts with BASE is a branch', commit_of('BASEBALL'), c0)
git('branch', '-q', '-D', 'BASEBALL')

git('branch', 'old', c0)
git('config', 'lines-changed.base', 'old')
T.check('lines-changed.base moves the default branch, as it does for the tool', commit_of('BASE'), c0)
git('config', '--unset', 'lines-changed.base')
git('branch', '-q', '-D', 'old')
T.check('and unsetting it puts it back', commit_of('BASE'), c1)

T.section('the same answer as bin/lines-changed')
if vim.fn.executable('dotnet-script') == 1 then
    for _, spec in ipairs({ 'HEAD', 'BASE', 'BASE:main', 'BASE~1', 'main', 'v1', c0:sub(1, 8) }) do
        local result = vim.system({ ROOT .. '/bin/lines-changed', '--json', spec }, { cwd = repo, text = true }):wait()
        local base = result.code == 0 and vim.json.decode(result.stdout).base or ('exit ' .. result.code .. ' ' .. result.stderr)
        T.check(('BASE means the same for ' .. spec), commit_of(spec), base)
    end
else
    print('  SKIPPED: dotnet-script is not installed, so the tool cannot be asked')
end

T.section('completion and the base picker')
local function has(list, wanted)
    return vim.tbl_contains(list, wanted)
end
T.ok('HEAD and BASE are offered', has(gitrev.complete(''), 'HEAD') and has(gitrev.complete(''), 'BASE'))
T.ok('branches and tags are too', has(gitrev.complete(''), 'main') and has(gitrev.complete('v'), 'v1'))
T.check('typed text narrows them', gitrev.complete('BA'), { 'BASE' })
T.ok('after BASE: only branches, keeping the prefix', has(gitrev.complete('BASE:ma'), 'BASE:main'))
T.ok('and not tags', not has(gitrev.complete('BASE:'), 'BASE:v1'))

local items = gitrev.picker_items()
local refs = vim.tbl_map(function(item) return item.ref end, items)
T.check('the picker starts with HEAD, then BASE', { refs[1], refs[2] }, { 'HEAD', 'BASE' })
T.ok('and lists the branches', has(refs, 'main') and has(refs, 'topic'))
T.ok('the tag', has(refs, 'v1'))
T.ok('and recent commits by hash', has(refs, git('rev-parse', '--short', c0)))
local text_of = {}
for _, item in ipairs(items) do text_of[item.ref] = item.text end
T.ok('BASE says what it is relative to', text_of.BASE:find('main', 1, true) ~= nil, text_of.BASE)
T.ok('a tag is marked as one', text_of.v1:find('tag', 1, true) ~= nil, text_of.v1)

T.section('starting a review')
-- Two lists of somebody else's, to see that review neither frees nor buries them.
vim.fn.setqflist({}, 'f')
vim.call('setqflist', {}, ' ', { title = 'References: A', items = { { filename = repo .. '/a.cs', lnum = 1, text = 'x' } } })
vim.call('setqflist', {}, ' ', { title = 'References: B', items = { { filename = repo .. '/a.cs', lnum = 2, text = 'y' } } })
vim.cmd('1chistory')
vim.cmd('edit ' .. repo .. '/a.cs')
local file_win = vim.api.nvim_get_current_win()
T.ok('gitsigns attached to the file', T.wait(8000, function()
    local status = vim.b.gitsigns_status_dict
    return status ~= nil and status.added ~= nil
end))

review.start('BASE')
T.ok('review turned on, and finished starting', started(c1))
local info = review.list_info()
T.check('six hunks against BASE: a.cs twice, b.cs, c.cs, the test file, the new file', info.size, 6)
T.check('the base is the merge base', review.state.commit, c1)
T.check('and is shown as typed', review.state.ref, 'BASE')
T.check('it starts on the first entry', info.idx, 1)
T.check('the list is called what it is', vim.fn.getqflist({ id = review.state.list_id, title = 0 }).title, 'Review: BASE')

local function files()
    return vim.tbl_map(function(item)
        return vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ':t')
    end, review.list_items())
end
local order = files()
T.check('code first, the test file last', order[#order], 'CTests.cs')
T.check('a.cs has two entries, together', { order[1], order[2] }, { 'a.cs', 'a.cs' })

T.check('the list went to the end of the stack, after the two that were there', vim.fn.getqflist({ nr = '$' }).nr, 3)
T.check('and nothing was freed: the first is still there', vim.fn.getqflist({ nr = 1, title = 0 }).title, 'References: A')
T.check('and the second', vim.fn.getqflist({ nr = 2, title = 0 }).title, 'References: B')
T.check('the status line says where it is', review.status(), 'BASE 1/6')
T.ok('the first hunk is on screen, in the file window', vim.api.nvim_get_current_win() == file_win and vim.fn.expand('%:t') == 'a.cs')

T.ok('the inline diff opened in that window', T.wait(8000, function()
    return vim.w[file_win].review_buf == vim.api.nvim_get_current_buf()
end))

T.section('stepping')
review.step(1)(1)
T.check('one hunk on', review.list_info().idx, 2)
review.step(1)(2)
T.check('a count steps that many', review.list_info().idx, 4)
review.step(-1)(1)
T.check('and back', review.list_info().idx, 3)
review.step(1)(100)
T.check('it stops at the last hunk instead of wrapping', review.list_info().idx, 6)
T.check('the last one is the test file', vim.fn.expand('%:t'), 'CTests.cs')
review.step(-1)(100)
T.check('and at the first', review.list_info().idx, 1)

review.by_file(1)(1)
T.check('a file on: the first entry of the next file', review.list_info().idx, 3)
T.check('which is b.cs', vim.fn.expand('%:t'), 'b.cs')
review.by_file(1)(1)
review.by_file(-1)(1)
T.check('a file back lands on its first entry', review.list_info().idx, 3)
review.by_file(-1)(1)
T.check('and again, on a.cs, at its first hunk and not its last', review.list_info().idx, 1)
review.by_file(-1)(1)
T.check('before the first file it stays', review.list_info().idx, 1)

T.section('dropping what is done')
review.step(1)(1)
review.drop()
info = review.list_info()
T.check('one fewer', info.size, 5)
T.check('and the next one slid into its place', info.idx, 2)
T.check('the status line counts what is left', review.status(), 'BASE 2/5')
review.undrop()
info = review.list_info()
T.check('undo brings it back', info.size, 6)
T.check('at the place it was', info.idx, 2)
T.check('undo with nothing left to undo is a no-op', (function() review.undrop(); return review.list_info().size end)(), 6)

review.step(1)(100)
local before_last = review.list_info().size
review.drop()
T.check('dropping the last entry moves to the one before it', review.list_info().idx, before_last - 1)
review.step(-1)(100)
for _ = 1, 5 do review.drop() end
T.check('dropping them all leaves an empty list', review.list_info().size, 0)
T.check('and the status line says it is done', review.status(), 'BASE done')
review.drop()
T.check('dropping from an empty list is harmless', review.list_info().size, 0)
for _ = 1, 6 do review.undrop() end
T.check('undo brings every one back', review.list_info().size, 6)

T.section('the stack stays usable around the review')
vim.cmd('1chistory')
T.check('someone else\'s list is current after they select it', vim.fn.getqflist({ title = 0 }).title, 'References: A')
review.step(1)(1)
T.check('a step selects the review list again, whatever was current', vim.fn.getqflist({ title = 0 }).title, 'Review: BASE')
T.check('the stack did not grow', vim.fn.getqflist({ nr = '$' }).nr, 3)

T.section('the mode')
review.step(-1)(100)
local result
local function typed(keys, ms) vim.defer_fn(function() vim.api.nvim_input(keys) end, ms or 60) end
typed('jj<Esc>')
result = modal.enter('review')
T.check('jj is two hunks', review.list_info().idx, 3)
T.check('and Escape leaves the mode', result.reason, 'escape')
T.check('with the review still on', review.state.on, true)
typed('2k<Esc>')
modal.enter('review')
T.check('a count: 2k is two back', review.list_info().idx, 1)
typed('<Tab><Esc>')
modal.enter('review')
T.check('Tab is the next file', review.list_info().idx, 3)
typed('<S-Tab><Esc>')
modal.enter('review')
T.check('S-Tab the previous', review.list_info().idx, 1)
typed('d<Esc>')
modal.enter('review')
T.check('d drops', review.list_info().size, 5)
typed('u<Esc>')
modal.enter('review')
T.check('u brings it back', review.list_info().size, 6)

local text_before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
typed('<C-d><C-u>j<Esc>')
result = modal.enter('review')
T.check('scrolling does not leave the mode: Ctrl-d, Ctrl-u and then j still worked', review.list_info().idx, 2)
T.check('it ended by Escape, not by the scroll', result.reason, 'escape')
T.check('and nothing was typed into the buffer', vim.api.nvim_buf_get_lines(0, 0, -1, false), text_before)

typed('x')
result = modal.enter('review')
T.check('a key the mode does not own leaves it', result.reason, 'foreign')
vim.api.nvim_feedkeys('', 'x', false)
vim.cmd('silent! undo')
T.check('and review is still on', review.state.on, true)

local label
vim.defer_fn(function() label = require('ide.statusline').render(vim.api.nvim_get_current_win()) end, 25)
typed('<Esc>', 80)
modal.enter('review')
T.ok('the statusline shows the review and how far through it is', label:find('REVIEW', 1, true) ~= nil and label:find('BASE 2/6', 1, true) ~= nil, label)

local cheat = table.concat(require('ide.palette').key_lines(), '\n')
T.ok('the cheatsheet lists the mode\'s keys', cheat:find('review ▸ j', 1, true) ~= nil and cheat:find('review ▸ d', 1, true) ~= nil)
T.ok('and the one that scrolls', cheat:find('Scroll; the mode stays', 1, true) ~= nil)
local palette = table.concat(require('ide.palette').palette_lines(), '\n')
T.ok('the palette offers the mode, with its key', palette:find('Mode: review', 1, true) ~= nil and palette:find('<Space>r', 1, true) ~= nil, palette)
T.ok('and the command', palette:find(':Review', 1, true) ~= nil)

T.section('no formatting while reviewing')
-- A language server that formats, stood in for, and only for the write itself:
-- Neovim's own handlers call methods on whatever get_clients returns, and they
-- run while anything is waiting.
local formatted = 0
local function write_with_formatter()
    local real_clients, real_format = vim.lsp.get_clients, vim.lsp.buf.format
    vim.lsp.get_clients = function() return { { name = 'stub_ls' } } end
    vim.lsp.buf.format = function() formatted = formatted + 1 end
    local ok, err = pcall(vim.cmd, 'silent write')
    vim.lsp.get_clients, vim.lsp.buf.format = real_clients, real_format
    assert(ok, err)
end
vim.cmd('edit ' .. repo .. '/b.cs')
write_with_formatter()
T.check('a write while review is on does not format', formatted, 0)
typed('q')
result = modal.enter('review')
T.check('q is a key that leaves the mode', result.reason, 'key')
T.check('q stops the review', review.state.on, false)
write_with_formatter()
T.check('and the next write formats again', formatted, 1)

T.section('coming back to it')
local id_before = review.state.list_id
T.check('stopping leaves the list where it was', vim.fn.getqflist({ id = id_before, nr = 0 }).nr, 3)
T.check('and the review ended cleanly', { review.state.base, review.state.commit }, { nil, nil })
T.check('the status line has nothing to say', review.status(), nil)
review.start('BASE')
T.ok('turned on again', started(c1))
T.check('the same list comes back', review.state.list_id, id_before)
T.check('as it was left', review.list_info().size, 6)
T.check('without a new one in the stack', vim.fn.getqflist({ nr = '$' }).nr, 3)

review.step(1)(1)
review.drop()
review.stop()
review.start('BASE')
T.ok('turned on a third time', started(c1))
T.check('a hunk dropped before stopping is still dropped', review.list_info().size, 5)

review.start('HEAD')
T.ok('another base', started(topic, 2))
T.check('is a different list: two hunks, the edit and the new file', review.list_info().size, 2)
T.check('built at the end of the stack, and the old one kept', vim.fn.getqflist({ nr = '$' }).nr, 4)
T.check('named for its base', vim.fn.getqflist({ id = review.state.list_id, title = 0 }).title, 'Review: HEAD')

review.start('main')
T.ok('against main as it is now', started(m2, 7))
T.check('seven: main\'s own change to b.cs shows as reverted', review.list_info().size, 7)

vim.cmd('Review BASE')
T.ok('the command does the same', started(c1, 5))
T.check('and BASE has its own list back, with the hunk that was dropped still dropped', review.list_info().size, 5)
T.check('not a new one: the stack is as it was', vim.fn.getqflist({ nr = '$' }).nr, 5)

review.start('HEAD')
T.ok('HEAD again', started(topic, 2))
T.check('its own list too, the one made before', vim.fn.getqflist({ nr = '$' }).nr, 5)

T.section('starts that overlap')
-- A base picked, and another a moment later, before the first has finished: the
-- first used to finish against the second one's base and build a list titled
-- for one revision out of the other's hunks.
local stack_before = vim.fn.getqflist({ nr = '$' }).nr
review.start('main')
review.start('BASE')
T.ok('the one started last is the one that stands', started(c1, 5))
T.check('named for its revision', vim.fn.getqflist({ id = review.state.list_id, title = 0 }).title, 'Review: BASE')
vim.wait(500)
T.check('the other did not finish afterwards and take over', review.state.commit, c1)
T.check('and left no list of its own behind', vim.fn.getqflist({ nr = '$' }).nr, stack_before)

review.start('HEAD')
review.stop()
vim.wait(1000)
T.check('a stop overtakes a start that was still under way', review.state.on, false)
T.check('and it does not come back', review.state.ready, false)

review.start('BASE')
T.ok('and starting again after that works', started(c1, 5))

vim.cmd('Review!')
T.check('! stops it', review.state.on, false)

T.section('what goes wrong')
local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level }) end
review.start('no-such-ref')
vim.wait(100)
T.check('an unknown revision is reported', #notified, 1)
T.ok('as an error naming it', notified[1] and notified[1].message:find('no-such-ref', 1, true) ~= nil and notified[1].level == vim.log.levels.ERROR, notified)
T.check('and nothing was started', review.state.on, false)
vim.notify = real_notify

review.stop()
T.check('stopping when nothing is on is harmless', review.state.on, false)

T.finish()
