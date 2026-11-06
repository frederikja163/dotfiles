-- env: full
-- :Build, :Test, :Run and :Watch against the real dotnet, on a solution made here:
-- a library, an xunit project (a theory, a nested class, both kinds of namespace,
-- a test that fails and one that throws) and a console program. test_dotnet_parse.lua
-- has the parsers and the command lines; this is that they work together, in the
-- background, with the quickfix stack, the statusline, terminals and the session.
--
-- Slow (each dotnet is seconds), and needs the packages xunit restores from, which
-- are in ~/.nuget when the SDK has been used for tests before and come from
-- nuget.org otherwise. Where either is missing it says SKIPPED, loudly, rather
-- than fail for something that is not this config's.

vim.env.NVIM_TEST_BUDGET = '600'
local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

if vim.fn.executable('dotnet') == 0 then
    print('  SKIPPED: dotnet is not installed')
    T.finish()
end

vim.o.showmode = false
vim.g.ide_autosave = false
vim.g.ide_format = false

-- Nothing left running when this is over: the shared compiler and the MSBuild
-- nodes are made to stay for fifteen minutes so the next build is quick, which is
-- right for a person and not for a test.
vim.env.MSBUILDDISABLENODEREUSE = '1'
vim.env.UseSharedCompilation = 'false'
vim.env.DOTNET_CLI_TELEMETRY_OPTOUT = '1'

----------------------------------------------------------------------------
-- A solution
----------------------------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)

local function write(path, lines)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines, full)
    return full
end

local function run(cmd, cwd)
    local result = vim.system(cmd, { cwd = cwd or root, text = true }):wait()
    return result.code == 0, (result.stdout or '') .. (result.stderr or '')
end

local ok_new = run({ 'dotnet', 'new', 'xunit', '-n', 'Lib.Tests', '-o', 'tests/Lib.Tests', '--no-restore' })
if not ok_new then
    print('  SKIPPED: dotnet new xunit did not work here')
    T.finish()
end
os.remove(root .. '/tests/Lib.Tests/UnitTest1.cs')

write('src/Lib/Lib.csproj', {
    '<Project Sdk="Microsoft.NET.Sdk">',
    '  <PropertyGroup>',
    '    <TargetFramework>net10.0</TargetFramework>',
    '    <ImplicitUsings>disable</ImplicitUsings>',
    '    <Nullable>enable</Nullable>',
    '  </PropertyGroup>',
    '</Project>',
})
local calc = write('src/Lib/Calc.cs', {
    'namespace Lib;',
    '',
    'public static class Calc',
    '{',
    '    public static int Add(int a, int b) => a + b;',
    '    public static int Half(int a) => a / 2;',
    '}',
})
write('src/App/App.csproj', {
    '<Project Sdk="Microsoft.NET.Sdk">',
    '  <PropertyGroup>',
    '    <OutputType>Exe</OutputType>',
    '    <TargetFramework>net10.0</TargetFramework>',
    '    <ImplicitUsings>disable</ImplicitUsings>',
    '    <Nullable>enable</Nullable>',
    '  </PropertyGroup>',
    '  <ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup>',
    '</Project>',
})
local program = write('src/App/Program.cs', {
    'System.Console.WriteLine("hello from App");',
    'System.Console.WriteLine("args: " + string.Join(" ", args));',
})
local calc_tests = write('tests/Lib.Tests/CalcTests.cs', {
    'using Lib;',                                           -- 1
    'using Xunit;',                                         -- 2
    '',                                                     -- 3
    'namespace Lib.Tests;',                                 -- 4
    '',                                                     -- 5
    'public class CalcTests',                               -- 6
    '{',                                                    -- 7
    '    [Fact]',                                           -- 8
    '    public void Add_adds()',                           -- 9
    '    {',                                                -- 10
    '        Assert.Equal(5, Calc.Add(2, 3));',             -- 11
    '    }',                                                -- 12
    '',                                                     -- 13
    '    [Fact]',                                           -- 14
    '    public void Half_is_wrong_on_purpose()',           -- 15
    '    {',                                                -- 16
    '        Assert.Equal(3, Calc.Half(5));',               -- 17
    '    }',                                                -- 18
    '',                                                     -- 19
    '    [Theory]',                                         -- 20
    '    [InlineData(1, 2)]',                               -- 21
    '    [InlineData(2, 3)]',                               -- 22
    '    public void Add_one(int a, int expected)',         -- 23
    '    {',                                                -- 24
    '        Assert.Equal(expected, Calc.Add(a, 1));',      -- 25
    '    }',                                                -- 26
    '',                                                     -- 27
    '    public class Nested',                              -- 28
    '    {',                                                -- 29
    '        [Fact]',                                       -- 30
    '        public void Deep()',                           -- 31
    '        {',                                            -- 32
    '            Assert.True(true);',                       -- 33
    '        }',                                            -- 34
    '    }',                                                -- 35
    '}',                                                    -- 36
    '',                                                     -- 37
    'public class OtherTests',                              -- 38
    '{',                                                    -- 39
    '    [Fact]',                                           -- 40
    '    public void Throws_unexpectedly()',                -- 41
    '    {',                                                -- 42
    '        var x = new int[0];',                          -- 43
    '        var y = x[3];',                                -- 44
    '    }',                                                -- 45
    '}',                                                    -- 46
})
local block_tests = write('tests/Lib.Tests/BlockTests.cs', {
    'using Xunit;',
    '',
    'namespace Lib',
    '{',
    '    namespace Tests.Block',
    '    {',
    '        public class BlockTests',
    '        {',
    '            [Fact]',
    '            public void Block_passes()',
    '            {',
    '                Assert.True(true);',
    '            }',
    '        }',
    '    }',
    '}',
})
run({ 'dotnet', 'new', 'sln', '-n', 'App', '--format', 'sln' })
run({ 'dotnet', 'sln', 'App.sln', 'add', 'src/Lib/Lib.csproj', 'src/App/App.csproj', 'tests/Lib.Tests/Lib.Tests.csproj' })
run({ 'dotnet', 'add', 'tests/Lib.Tests/Lib.Tests.csproj', 'reference', 'src/Lib/Lib.csproj' })
local restored, restore_output = run({ 'dotnet', 'restore', 'App.sln', '-nologo', '-v', 'q' })
if not restored then
    print('  SKIPPED: the packages for an xunit project could not be restored here (no network and not cached):')
    print('  ' .. restore_output:sub(1, 300):gsub('\n', ' '))
    T.finish()
end
vim.cmd.cd(root)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local dotnet = require('ide.dotnet')

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level or vim.log.levels.INFO }) end
local function last_note() return notified[#notified] end

local function finished(what, ms)
    T.ok(what .. ': it ended', T.until_true(ms or 240000, function() return vim.g.ide_job == nil end))
    T.sleep(100)
end

local function line_of(file, text)
    for i, line in ipairs(vim.fn.readfile(file)) do
        if line:find(text, 1, true) then return i end
    end
end

local function qf() return vim.fn.getqflist({ nr = 0, id = 0, size = 0, title = 0, winid = 0, items = 0 }) end
local function depth() return vim.fn.getqflist({ nr = '$' }).nr end
local function entries()
    return vim.tbl_map(function(e)
        return ('%s:%d'):format(e.bufnr > 0 and vim.fn.fnamemodify(vim.fn.bufname(e.bufnr), ':t') or '-', e.lnum)
    end, vim.fn.getqflist())
end
local function windows() return #vim.api.nvim_tabpage_list_wins(0) end
local function terminal_buffers()
    local found = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal' then table.insert(found, buf) end
    end
    return found
end
local function buffer_text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

local function open(file)
    vim.cmd('silent only!')
    vim.cmd('edit ' .. file)
end

T.async(function()
    T.section('the config loads')
    T.check('no module failed', vim.g.ide_failed, {})
    T.check('nothing is running to begin with', vim.g.ide_job, nil)

    ------------------------------------------------------------------------
    T.section('a build that works')
    open(calc)
    local origin = vim.api.nvim_get_current_win()
    local stack_before = depth()
    notified = {}
    vim.cmd('Build')
    T.check('while it goes, the statusline is told', vim.g.ide_job, 'Build')
    local line = require('ide.statusline').render(origin)
    T.ok('and shows it', line:find('BUILD', 1, true) ~= nil, line)
    T.ok('the editor is not blocked: this test itself is running while it goes', vim.g.ide_job == 'Build')
    finished('Build')
    T.check('the job is gone from the statusline afterwards', vim.g.ide_job, nil)
    T.ok('it says it succeeded', last_note().message:find('Build succeeded', 1, true) ~= nil, last_note())
    T.check('as information', last_note().level, vim.log.levels.INFO)
    T.check('no list was made for nothing', depth(), stack_before)

    ------------------------------------------------------------------------
    T.section('a build that fails')
    local broken = write('src/Lib/Broken.cs', {
        'namespace Lib;',
        '',
        'public class Broken',
        '{',
        '    int a = missing;',
        '    int b = Other.Nope();',
        '    void M() { int unused; }',
        '}',
    })
    -- Something that was being read, in the stack, that a build must not bury.
    vim.fn.setqflist({}, 'f')
    vim.call('setqflist', {}, ' ', { title = 'References: Calc', items = { { filename = calc, lnum = 5, text = 'x' } } })
    notified = {}
    vim.cmd('Build')
    finished('Build with errors')
    T.check('the list is the end of the stack', { depth(), qf().nr }, { 2, 2 })
    T.ok('named for the solution and what was found', qf().title == 'Build App.sln: 2 errors, 1 warning', qf().title)
    T.check('each diagnostic once, errors and the warning, in the order found', entries(), { 'Broken.cs:5', 'Broken.cs:6', 'Broken.cs:7' })
    T.check('the first is an error with its place', { vim.fn.getqflist()[1].type, vim.fn.getqflist()[1].col, vim.fn.getqflist()[1].text }, { 'E', 13, "CS0103: The name 'missing' does not exist in the current context" })
    T.ok('the window is open', qf().winid ~= 0)
    T.check('and focus has not left the file being worked in', vim.api.nvim_get_current_win(), origin)
    T.check('what was in the stack before is still there', vim.fn.getqflist({ nr = 1, title = 0 }).title, 'References: Calc')
    T.check('it says it failed, as an error', { last_note().message:find('Build FAILED: 2 errors, 1 warning', 1, true) ~= nil, last_note().level }, { true, vim.log.levels.ERROR })
    local build_list = qf().id

    vim.cmd('cclose')
    notified = {}
    vim.cmd('Build')
    finished('the same build again')
    T.check('the same list is updated where it is, not another pushed', { qf().id, depth() }, { build_list, 2 })
    vim.cmd('1chistory')
    vim.cmd('Build')
    finished('and again, with something else the current list')
    T.check('the stack still has two', depth(), 2)
    T.check('and the result is brought to the front', qf().id, build_list)

    ------------------------------------------------------------------------
    T.section('the build is mended')
    os.remove(broken)
    notified = {}
    vim.cmd('Build')
    finished('the mended build')
    T.ok('it succeeds', last_note().message:find('Build succeeded', 1, true) ~= nil, last_note())
    T.check('the list that held the errors is emptied in place, not left to be mistaken for current', { qf().id, qf().size }, { build_list, 0 })
    T.check('and its window is closed', qf().winid, 0)

    local warn_file = write('src/Lib/Warn.cs', { 'namespace Lib;', 'public class Warn { void M() { int unused; } }' })
    notified = {}
    vim.cmd('Build')
    finished('a build with only a warning')
    T.ok('it succeeds and says what it found', last_note().message:find('Build succeeded: 1 warning', 1, true) ~= nil, last_note())
    T.check('the warning is in the list', vim.fn.getqflist({ id = build_list, size = 0 }).size, 1)
    T.check('which is not forced open on a build that worked', qf().winid, 0)
    os.remove(warn_file)

    T.section('a build of just the project')
    notified = {}
    vim.cmd('Build project')
    finished('the project build')
    T.ok('works too', last_note().message:find('Build succeeded', 1, true) ~= nil, last_note())

    ------------------------------------------------------------------------
    T.section('all the tests')
    notified = {}
    open(calc_tests)
    vim.cmd('Test')
    T.check('while they go, the statusline is told', vim.g.ide_job, 'Test')
    finished('all the tests')
    T.ok('it says what failed and what passed', last_note().message:find('Tests: 2 failed, 5 passed', 1, true) ~= nil, last_note())
    T.check('as a warning', last_note().level, vim.log.levels.WARN)
    T.ok('the list is titled with the scope and the counts', qf().title:find('all tests', 1, true) and qf().title:find('2 failed of 7', 1, true), qf().title)
    T.check('it lists both, each at its line in the test file', entries(), { 'CalcTests.cs:' .. line_of(calc_tests, 'Assert.Equal(3, Calc.Half(5))'), 'CalcTests.cs:' .. line_of(calc_tests, 'var y = x[3]') })
    T.check('the first reads as the test and what was wrong', vim.fn.getqflist()[1].text, 'CalcTests.Half_is_wrong_on_purpose: Assert.Equal() Failure: Values differ | Expected: 3 | Actual: 2')
    T.ok('its window is open', qf().winid ~= 0)
    local test_list = qf().id
    T.ok('and it is not the build\'s list', test_list ~= build_list)
    vim.cmd('cclose')

    ------------------------------------------------------------------------
    T.section('the test at the cursor')
    local function nearest(text, offset)
        open(calc_tests)
        vim.api.nvim_win_set_cursor(0, { line_of(calc_tests, text), offset or 8 })
        notified = {}
        vim.cmd('Test nearest')
        finished('nearest at ' .. text)
        return last_note().message
    end
    T.ok('a passing test: one ran, and it passed', nearest('Assert.Equal(5, Calc.Add(2, 3))'):find('Tests passed: 1 ', 1, true) ~= nil, last_note())
    T.check('the list of failures is emptied in place', { qf().id, qf().size }, { test_list, 0 })
    T.ok('a theory is one test with its rows: both ran', nearest('public void Add_one'):find('Tests passed: 2 ', 1, true) ~= nil, last_note())
    T.ok('on the attribute above a method it is that method', nearest('[InlineData(2, 3)]', 10):find('Tests passed: 2 ', 1, true) ~= nil, last_note())
    T.ok('a failing one: only it ran, and it failed', nearest('Assert.Equal(3, Calc.Half(5))'):find('Tests: 1 failed, 0 passed', 1, true) ~= nil, last_note())
    T.check('and the list has it at its line', entries(), { 'CalcTests.cs:' .. line_of(calc_tests, 'Assert.Equal(3, Calc.Half(5))') })
    T.ok('a nested class: its own method, by the + that names it', nearest('Assert.True(true)', 14):find('Tests passed: 1 ', 1, true) ~= nil, last_note())
    T.ok('in a class but not in a method: the class, which is four tests and not its nested one', nearest('public class CalcTests', 8):find('Tests: 1 failed, 3 passed', 1, true) ~= nil, last_note())
    T.ok('the other class in the file is its own', nearest('var x = new int[0]'):find('Tests: 1 failed, 0 passed', 1, true) ~= nil, last_note())
    T.ok('a class in a block namespace, two deep', (function()
        open(block_tests)
        vim.api.nvim_win_set_cursor(0, { line_of(block_tests, 'Assert.True(true)'), 20 })
        notified = {}
        vim.cmd('Test nearest')
        finished('nearest in a block namespace')
        return last_note().message:find('Tests passed: 1 ', 1, true) ~= nil
    end)(), last_note())

    ------------------------------------------------------------------------
    T.section('the tests in the file')
    open(calc_tests)
    notified = {}
    vim.cmd('Test file')
    finished('the file')
    T.ok('every class in it: the class, the nested one and the other', last_note().message:find('Tests: 2 failed, 4 passed', 1, true) ~= nil, last_note())
    T.ok('and not the other file\'s class', not last_note().message:find('5 passed', 1, true))
    T.ok('the title names the file', qf().title:find('CalcTests.cs', 1, true) ~= nil, qf().title)
    open(block_tests)
    notified = {}
    vim.cmd('Test file')
    finished('the other file')
    T.ok('a file of its own: one test, passing', last_note().message:find('Tests passed: 1 ', 1, true) ~= nil, last_note())

    T.section('the same again')
    open(calc_tests)
    vim.api.nvim_win_set_cursor(0, { line_of(calc_tests, 'Assert.Equal(3, Calc.Half(5))'), 8 })
    vim.cmd('Test nearest')
    finished('nearest, to be repeated')
    open(block_tests)
    notified = {}
    vim.cmd('Test last')
    finished('last')
    T.ok('it repeats what was run, whatever file is in the window now', last_note().message:find('Tests: 1 failed, 0 passed', 1, true) ~= nil, last_note())
    vim.cmd('cclose')

    ------------------------------------------------------------------------
    T.section('nothing to run')
    open(calc)
    notified = {}
    vim.cmd('Test nearest')
    T.ok('a file that is not a test says so, without running anything', last_note() ~= nil and last_note().level == vim.log.levels.WARN, last_note())
    T.check('(nothing started)', vim.g.ide_job, nil)
    vim.cmd('enew')
    notified = {}
    vim.cmd('Test file')
    T.ok('a buffer that is not C# is refused', last_note().message:find('not a C# file', 1, true) ~= nil, last_note())
    local stray = vim.fn.tempname() .. '/Stray.cs'
    vim.fn.mkdir(vim.fn.fnamemodify(stray, ':h'), 'p')
    vim.fn.writefile({ 'class Stray { }' }, stray)
    vim.cmd('edit ' .. stray)
    notified = {}
    vim.cmd('Build')
    T.ok('a file in no project is not built', last_note().message:find('No solution or project above', 1, true) ~= nil, last_note())
    vim.cmd('Run')
    T.ok('nor run', last_note().message:find('No project above', 1, true) ~= nil, last_note())
    vim.cmd('Test')
    T.ok('nor tested', last_note().message:find('No solution or project above', 1, true) ~= nil, last_note())
    vim.cmd('Test sideways')
    T.ok('an unknown scope is refused', last_note().message:find('all, file, nearest or last', 1, true) ~= nil, last_note())

    ------------------------------------------------------------------------
    T.section('a test project that does not compile')
    local bad = write('tests/Lib.Tests/Bad.cs', { 'namespace Lib.Tests;', 'public class Bad { int x = nope; }' })
    open(calc_tests)
    notified = {}
    vim.cmd('Test')
    finished('tests that cannot be built')
    T.ok('the tests are not run, and it says why', last_note().message:find('Tests not run, the build failed: 1 error', 1, true) ~= nil, last_note())
    T.check('as an error', last_note().level, vim.log.levels.ERROR)
    T.check('the list is the compile error, where it is', entries(), { 'Bad.cs:2' })
    T.ok('titled so it is not taken for a test failure', qf().title:find('build failed', 1, true) ~= nil, qf().title)
    os.remove(bad)
    vim.cmd('cclose')

    ------------------------------------------------------------------------
    T.section('one thing at a time')
    open(calc_tests)
    notified = {}
    vim.cmd('Test')
    T.check('tests go', vim.g.ide_job, 'Test')
    vim.cmd('Build')
    T.check('a build started over them takes their place', vim.g.ide_job, 'Build')
    finished('the build that replaced them')
    T.sleep(6000)
    local messages = vim.tbl_map(function(n) return n.message end, notified)
    T.ok('only the build reported: the tests it stopped said nothing', #messages == 1 and messages[1]:find('Build succeeded', 1, true) ~= nil, messages)

    notified = {}
    vim.cmd('Test')
    T.check('tests go again', vim.g.ide_job, 'Test')
    vim.cmd('Test!')
    T.check('! stops them', vim.g.ide_job, nil)
    T.ok('and says so', last_note().message == 'Stopped', last_note())
    T.sleep(6000)
    T.check('and they report nothing afterwards', #notified, 1)
    vim.cmd('Build!')
    T.ok('stopping when nothing goes says so', last_note().message:find('No build or test run is going', 1, true) ~= nil, last_note())

    ------------------------------------------------------------------------
    T.section('run')
    open(program)
    origin = vim.api.nvim_get_current_win()
    local wins_before = windows()
    vim.cmd('Run')
    T.check('a window below has the terminal', windows(), wins_before + 1)
    T.check('focus stays in the file', vim.api.nvim_get_current_win(), origin)
    local first_terminal = terminal_buffers()[1]
    T.ok('it is a terminal', first_terminal ~= nil)
    T.ok('the program ran, and what it printed is there', T.until_true(120000, function()
        return buffer_text(first_terminal):find('hello from App', 1, true) ~= nil
    end), buffer_text(first_terminal))
    T.ok('and its arguments, of which there were none', buffer_text(first_terminal):find('args:', 1, true) ~= nil)

    vim.cmd('Run one "two words" three')
    T.check('running again takes over the window', windows(), wins_before + 1)
    T.check('the old terminal is gone', vim.api.nvim_buf_is_valid(first_terminal), false)
    local second_terminal = terminal_buffers()[1]
    T.ok('arguments go to the program, a quoted one as one', T.until_true(120000, function()
        return buffer_text(second_terminal):find('args: one two words three', 1, true) ~= nil
    end), buffer_text(second_terminal))

    open(calc)
    vim.cmd('Run')
    -- Not asked to be anything else: a library is a project, dotnet run is pointed
    -- at it, and what dotnet has to say about that is what the terminal shows. Its
    -- wording changes between SDKs; that it names the project does not.
    T.ok('a library is run too, and dotnet says why it cannot', T.until_true(120000, function()
        local found = terminal_buffers()[1]
        return found and buffer_text(found):find('Lib.csproj', 1, true) ~= nil
    end), buffer_text(terminal_buffers()[1]))

    ------------------------------------------------------------------------
    T.section('watch')
    open(program)
    vim.cmd('Watch')
    T.check('it is a second terminal, beside the first', #terminal_buffers(), 2)
    T.ok('dotnet watch started', T.until_true(120000, function()
        for _, buf in ipairs(terminal_buffers()) do
            if buffer_text(buf):find('dotnet watch', 1, true) then return true end
        end
        return false
    end))
    T.ok('and ran the program under it', T.until_true(120000, function()
        for _, buf in ipairs(terminal_buffers()) do
            if buffer_text(buf):find('hello from App', 1, true) and buffer_text(buf):find('dotnet watch', 1, true) then return true end
        end
        return false
    end))

    ------------------------------------------------------------------------
    T.section('leaving')
    local before_leaving = #terminal_buffers()
    T.ok('two terminals are open, and a program is still running', before_leaving == 2)
    vim.api.nvim_exec_autocmds('VimLeavePre', {})
    T.check('closing the editor closes them', #terminal_buffers(), 0)
    local session = vim.fn.tempname()
    vim.cmd('mksession! ' .. session)
    local saved = table.concat(vim.fn.readfile(session), '\n')
    T.check('so a session cannot restart them', saved:find('term://', 1, true), nil)

    ------------------------------------------------------------------------
    T.section('what dotnet said, when it could not be read')
    open(calc)
    -- A build that works prints nothing at the verbosity used, so a broken one is
    -- what there is something to show of.
    local broken_again = write('src/Lib/Broken.cs', { 'namespace Lib;', 'public class Broken { int a = missing; }' })
    vim.cmd('Build')
    finished('a build, to have some output')
    os.remove(broken_again)
    vim.cmd('cclose')
    vim.cmd('DotnetOutput')
    local out_buf = vim.api.nvim_get_current_buf()
    T.ok('the output is in a window of its own', vim.bo[out_buf].buftype == 'nofile' and #vim.api.nvim_buf_get_lines(out_buf, 0, -1, false) > 1)
    T.ok('and is what dotnet printed', buffer_text(out_buf):find('error CS0103', 1, true) ~= nil, buffer_text(out_buf))
    T.check('read-only', vim.bo[out_buf].modifiable, false)
    vim.api.nvim_feedkeys('q', 'x', false)
    T.check('and q closes it', vim.api.nvim_buf_is_valid(out_buf) and #vim.fn.win_findbuf(out_buf) > 0, false)

    local fake_bin = vim.fn.tempname()
    vim.fn.mkdir(fake_bin, 'p')
    vim.fn.writefile({ '#!/bin/sh', 'echo "something went wrong in a way nobody expected"', 'exit 3' }, fake_bin .. '/dotnet')
    vim.fn.setfperm(fake_bin .. '/dotnet', 'rwxr-xr-x')
    local real_path = vim.env.PATH
    vim.env.PATH = fake_bin .. ':' .. real_path
    notified = {}
    vim.cmd('Build')
    finished('a build that fails with nothing to list')
    vim.env.PATH = real_path
    T.ok('is reported as a failure, with its exit status', last_note().message:find('failed (exit 3)', 1, true) ~= nil, last_note())
    T.ok('and the output is opened, because there is nothing else to read', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find('something went wrong', 1, true) ~= nil)
    vim.cmd('close')

    vim.env.PATH = '/nonexistent'
    notified = {}
    vim.cmd('Build')
    vim.env.PATH = real_path
    T.ok('with no dotnet at all it says so, and nothing is left running', last_note().message:find('could not be started', 1, true) ~= nil and vim.g.ide_job == nil, last_note())

    ------------------------------------------------------------------------
    T.section('the keys')
    local called
    local real = { build = dotnet.build, run = dotnet.run, watch = dotnet.watch, test = dotnet.test }
    dotnet.build = function() called = 'build' end
    dotnet.run = function() called = 'run' end
    dotnet.watch = function() called = 'watch' end
    dotnet.test = function(scope) called = 'test ' .. tostring(scope) end
    for keys, want in pairs({
        ['<Space>bb'] = 'build', ['<Space>br'] = 'run', ['<Space>bw'] = 'watch',
        ['<Space>tt'] = 'test all', ['<Space>tn'] = 'test nearest', ['<Space>tf'] = 'test file', ['<Space>tl'] = 'test last',
    }) do
        called = nil
        vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
        T.check(keys .. ' does ' .. want, called, want)
    end
    dotnet.build, dotnet.run, dotnet.watch, dotnet.test = real.build, real.run, real.watch, real.test

    local sheet = table.concat(require('ide.palette').key_lines(), '\n')
    T.ok('all of them are on the cheatsheet', sheet:find('Run the test at the cursor', 1, true) ~= nil and sheet:find('Build the solution', 1, true) ~= nil)
    local palette = table.concat(require('ide.palette').palette_lines(), '\n')
    T.ok('and the commands are in the palette', palette:find(':Build', 1, true) and palette:find(':Test', 1, true) and palette:find(':Run', 1, true)
        and palette:find(':Watch', 1, true) and palette:find(':DotnetOutput', 1, true), palette)
    T.check('the commands complete their arguments', vim.fn.getcompletion('Test ', 'cmdline'), { 'all', 'file', 'nearest', 'last' })

    vim.notify = real_notify
end)
