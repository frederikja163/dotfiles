-- env: bare
-- What ide.dotnet makes of what dotnet prints, with no editor around it: the
-- parsers over transcripts of the real tools (tests/nvim/fixtures/dotnet, each
-- captured from a real run), which solution or project a file belongs to, and
-- which runner a directory uses.
--
-- The transcripts name files under {ROOT}, which is replaced with a directory
-- made here. That matters: a stack frame is only taken for the test's own if the
-- file it names exists, which is how the frames inside a test framework (their
-- paths are /_/src/..., from a build with deterministic paths) are told apart from
-- the ones that are wanted.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')
package.path = os.getenv('NVIM_LUA') .. '/?.lua;' .. package.path

local dotnet = require('ide.dotnet')

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)

local function write(path, lines)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines or { '' }, full)
    return full
end

local function fixture(name)
    local file = io.open(os.getenv('NVIM_TESTS') .. '/fixtures/dotnet/' .. name)
    local text = file:read('*a')
    file:close()
    return (text:gsub('{ROOT}', root))
end

local calc_tests = write('tests/Lib.Tests/CalcTests.cs')
local mstest = write('Mt/Test1.cs')
local broken = write('src/Lib/Broken.cs')
write('src/Lib/Lib.csproj')

local function shown(entries, field)
    return vim.tbl_map(function(e) return e[field] end, entries)
end

local function relative(path)
    return path and path:sub(#root + 2) or nil
end

----------------------------------------------------------------------------
T.section('xunit under VSTest')
local xunit = dotnet.parse_tests(fixture('vstest-xunit.txt'))
T.check('counts come from the summary line', { xunit.total, xunit.passed, xunit.failed, xunit.skipped }, { 5, 3, 2, 0 })
T.check('both failures are listed', #xunit.failures, 2)
T.check('in file and line order, not the order they were printed in', vim.tbl_map(function(e) return relative(e.filename) .. ':' .. e.lnum end, xunit.failures),
    { 'tests/Lib.Tests/CalcTests.cs:17', 'tests/Lib.Tests/CalcTests.cs:36' })
T.check('named by class and method, without the namespace', xunit.failures[1].text:match('^[^:]+'), 'CalcTests.Half_is_wrong_on_purpose')
T.check('a message of several lines is one line', xunit.failures[1].text,
    'CalcTests.Half_is_wrong_on_purpose: Assert.Equal() Failure: Values differ | Expected: 3 | Actual: 2')
T.check('an exception is the message', xunit.failures[2].text,
    'OtherTests.Throws_unexpectedly: System.IndexOutOfRangeException : Index was outside the bounds of the array.')
T.check('they are errors, in column 1 of the line', { xunit.failures[1].type, xunit.failures[1].col }, { 'E', 1 })
T.check('and valid, so ]q stops on them', xunit.failures[1].valid, 1)
T.check('the xunit logger\'s own [FAIL] lines are not mistaken for tests', xunit.failures[1].text:find('FAIL', 1, true), nil)
T.check('nothing here says no test matched', xunit.none_matched, false)

T.section('MSTest under VSTest: framework frames, rows, a message on two lines')
local ms = dotnet.parse_tests(fixture('vstest-mstest.txt'))
T.check('counts', { ms.total, ms.passed, ms.failed }, { 5, 2, 3 })
T.check('three failures, each on its own frame in the test file and not the framework\'s', vim.tbl_map(function(e) return relative(e.filename) .. ':' .. e.lnum end, ms.failures),
    { 'Mt/Test1.cs:12', 'Mt/Test1.cs:20', 'Mt/Test1.cs:26' })
T.check('a data row keeps its arguments, with the name before them', ms.failures[3].text:match('^[^:]+'), 'Rows (2,4)')
T.check('a message that continues at the start of the next line is joined', ms.failures[2].text,
    'Throws: Test method Mt.Test1.Throws threw exception: | System.IndexOutOfRangeException: Index was outside the bounds of the array.')
T.check('what a test printed is not part of its failure', table.concat(shown(ms.failures, 'text'), '\n'):find('hello from a test', 1, true), nil)

T.section('MSTest under Microsoft Testing Platform')
local mtp = dotnet.parse_tests(fixture('mtp-mstest.txt'))
T.check('counts come from the "Test run summary" block', { mtp.total, mtp.passed, mtp.failed, mtp.skipped }, { 5, 2, 3, 0 })
T.check('the same three failures at the same places: frames without the word "line"', vim.tbl_map(function(e) return relative(e.filename) .. ':' .. e.lnum end, mtp.failures),
    { 'Mt/Test1.cs:12', 'Mt/Test1.cs:20', 'Mt/Test1.cs:26' })
T.check('the message once, though MTP prints it twice', mtp.failures[1].text,
    "Fails_on_purpose: Assert.AreEqual failed. Expected:<3>. Actual:<2>. 'expected' expression: '3', 'actual' expression: 'Half(5)'.")
T.check('a message on two lines is joined', mtp.failures[2].text,
    'Throws: Test method Mt.Test1.Throws threw exception: | System.IndexOutOfRangeException: Index was outside the bounds of the array.')
T.check('and so is the row', mtp.failures[3].text:match('^[^:]+'), 'Rows (2,4)')
local mtp_pass = dotnet.parse_tests(fixture('mtp-pass.txt'))
T.check('a run that passes has counts and no failures', { mtp_pass.total, mtp_pass.passed, mtp_pass.failed, #mtp_pass.failures }, { 1, 1, 0, 0 })

T.section('nothing ran')
local none = dotnet.parse_tests(fixture('vstest-no-match.txt'))
T.check('a filter that matches nothing says so', none.none_matched, true)
T.check('with no tests counted', { none.total, #none.failures }, { 0, 0 })
T.check('Microsoft Testing Platform\'s way of saying it', dotnet.parse_tests('Mt.dll (net10.0) Zero tests ran\nExit code: 8').none_matched, true)
T.check('a project with no tests, which VSTest says in another way', dotnet.parse_tests('No test is available in /x/A.dll. Make sure that test discoverer').none_matched, true)
T.check('nothing at all is not "none matched" either way', dotnet.parse_tests('').none_matched, false)

T.section('frames it cannot place')
local localised = dotnet.parse_tests(table.concat({
    '  Failed Ns.Cls.Method [4 ms]',
    '  Error Message:',
    '   Assert failed',
    '  Stack Trace:',
    '     at Ns.Cls.Method() i ' .. calc_tests .. ':rad 12',
    '',
    'Failed!  - Failed:     1, Passed:     0, Skipped:     0, Total:     1, Duration: 4 ms - A.dll (net10.0)',
}, '\n'))
T.check('a failure whose frame is in another language is still listed', #localised.failures, 1)
T.check('with its message', localised.failures[1].text, 'Cls.Method: Assert failed')
T.check('and no file to go to', { localised.failures[1].filename, localised.failures[1].lnum, localised.failures[1].col }, { nil, 0, 0 })
T.check('but still valid, so the message can be reached', localised.failures[1].valid, 1)
local none_exist = dotnet.parse_tests(table.concat({
    '  Failed Ns.Cls.Method [4 ms]',
    '  Error Message:',
    '   boom',
    '  Stack Trace:',
    '     at Fw.Assert() in /_/src/Fw/Assert.cs:line 99',
    '     at Ns.Cls.Method() in ' .. mstest .. ':line 7',
}, '\n'))
T.check('of two frames the first whose file exists is the one used', { relative(none_exist.failures[1].filename), none_exist.failures[1].lnum }, { 'Mt/Test1.cs', 7 })
local with_theory = dotnet.parse_tests('  Failed Lib.Tests.CalcTests.Add_one(a: 2, expected: 3) [< 1 ms]\n  Error Message:\n   x\n')
T.check('a theory\'s namespace goes and its arguments stay', with_theory.failures[1].text, 'CalcTests.Add_one (a: 2, expected: 3): x')
local nested = dotnet.parse_tests('  Failed Ns.Outer+Inner.Method [1 ms]\n  Error Message:\n   x\n')
T.check('a nested class is the last two parts', nested.failures[1].text, 'Inner.Method: x')
local colour = dotnet.parse_tests('\27[31m  Failed Ns.Cls.M [1 ms]\27[0m\n  Error Message:\n   \27[1mred\27[0m\n')
T.check('colour codes are taken out first', colour.failures[1] and colour.failures[1].text, 'Cls.M: red')
local long = dotnet.parse_tests('  Failed Ns.Cls.M [1 ms]\n  Error Message:\n   ' .. string.rep('x', 900) .. '\n')
T.ok('a very long message is cut', #long.failures[1].text < 450 and long.failures[1].text:sub(-3) == '…', #long.failures[1].text)

T.section('a build')
local build = dotnet.parse_build(fixture('build-errors.txt'), root)
T.check('each diagnostic once, though it is printed twice', { build.errors, build.warnings, #build.entries }, { 2, 1, 3 })
T.check('in the order the compiler found them, not the order of the summary', shown(build.entries, 'lnum'), { 5, 6, 7 })
T.check('with the column', shown(build.entries, 'col'), { 13, 13, 20 })
T.check('and the kind', shown(build.entries, 'type'), { 'E', 'E', 'W' })
T.check('in the file, which exists', relative(build.entries[1].filename), 'src/Lib/Broken.cs')
T.check('the code and the message, without the project the line ends with', build.entries[1].text, "CS0103: The name 'missing' does not exist in the current context")
T.check('a warning too', build.entries[3].text, "CS0168: The variable 'unused' is declared but never used")
T.check('and valid', build.entries[1].valid, 1)

local nothing = dotnet.parse_build(fixture('build-no-project.txt'), root)
T.check('an error that has no file is an entry that has none', { #nothing.entries, nothing.entries[1].filename, nothing.entries[1].lnum }, { 1, nil, 0 })
T.ok('with its code and what it says', nothing.entries[1].text:find('^MSB1003: Specify a project or solution file'), nothing.entries[1].text)

local other = dotnet.parse_build(table.concat({
    broken .. '(10,5,10,9): error CS1002: ; expected [' .. root .. '/src/Lib/Lib.csproj]',
    root .. '/src/Lib/Lib.csproj : error NU1101: Unable to find package Foo. No packages exist with this id [' .. root .. '/App.sln]',
    'src/Lib/Broken.cs(3,1): warning CS8618: relative [' .. root .. '/src/Lib/Lib.csproj]',
    broken .. '(4,2): error CS0000: ends in something that is not a project [not a project]',
    broken .. '(4,2): info CS0001: not a problem',
    'Build FAILED.',
    '    2 Error(s)',
}, '\n'), root)
T.check('a range gives its start', { other.entries[1].lnum, other.entries[1].col }, { 10, 5 })
T.check('a package that cannot be found is reported on the project file', { relative(other.entries[2].filename), other.entries[2].lnum, other.entries[2].type }, { 'src/Lib/Lib.csproj', 0, 'E' })
T.check('a relative path is read from where the command ran', relative(other.entries[3].filename), 'src/Lib/Broken.cs')
T.check('brackets that are not a project stay in the message', other.entries[4].text, 'CS0000: ends in something that is not a project [not a project]')
T.check('"info" is not an error or a warning', #other.entries, 4)
T.check('and nothing else in the output is taken for one', other.errors + other.warnings, 4)
T.check('output with no diagnostics has none', #dotnet.parse_build('Build succeeded.\n    0 Warning(s)\n    0 Error(s)\n', root).entries, 0)
T.check('test output has its warnings too', dotnet.parse_build(fixture('vstest-mstest.txt'), root).warnings, 1)
T.ok('and a URL in a message does not trouble it', dotnet.parse_build(fixture('vstest-mstest.txt'), root).entries[1].text:find('^MSTEST0032: Review or remove the assertion'))

----------------------------------------------------------------------------
T.section('which solution, which project')
write('Sol/Big.sln')
write('Sol/src/App/App.csproj')
write('Sol/src/App/Deep/Thing.cs')
write('Sol/tests/App.Tests/App.Tests.csproj')
write('Sol/tests/App.Tests/ThingTests.cs')
write('Two/B.sln')
write('Two/A.slnx')
write('Two/p/Two.csproj')
write('Lone/Lone.csproj')
write('Lone/Lone.cs')
write('Nothing/readme.txt')

local function where(path, prefer)
    local target = dotnet.target(root .. '/' .. path, prefer)
    return target and { target.kind, relative(target.path), relative(target.dir) } or nil
end
T.check('a file under a solution gets the solution', where('Sol/src/App/Deep/Thing.cs'), { 'solution', 'Sol/Big.sln', 'Sol' })
T.check('or its project, if that is asked for', where('Sol/src/App/Deep/Thing.cs', 'project'), { 'project', 'Sol/src/App/App.csproj', 'Sol/src/App' })
T.check('the tests\' own project, for a test file', where('Sol/tests/App.Tests/ThingTests.cs', 'project'), { 'project', 'Sol/tests/App.Tests/App.Tests.csproj', 'Sol/tests/App.Tests' })
T.check('with no solution, the project', where('Lone/Lone.cs'), { 'project', 'Lone/Lone.csproj', 'Lone' })
T.check('and the project even if a solution was preferred', where('Lone/Lone.cs', 'solution'), { 'project', 'Lone/Lone.csproj', 'Lone' })
T.check('asked for a project where there is none above, the solution is what there is', where('Two/B.sln', 'project'), { 'solution', 'Two/A.slnx', 'Two' })
T.check('two solutions in one directory: the first by name, so it is the same one every time', where('Two/p/x.cs'), { 'solution', 'Two/A.slnx', 'Two' })
T.check('no solution or project above is nothing', where('Nothing/readme.txt'), nil)
vim.cmd.cd(root .. '/Lone')
T.check('a buffer with no file starts from the working directory', { dotnet.target('').kind, relative(dotnet.target('').path) }, { 'project', 'Lone/Lone.csproj' })

----------------------------------------------------------------------------
T.section('which runner')
write('Vs/global.json', { '{ "sdk": { "version": "10.0.100" } }' })
write('Vs/sub/x.txt')
write('Mtp/global.json', { '{ "test": { "runner": "Microsoft.Testing.Platform" } }' })
write('Mtp/a/b/x.txt')
write('Caps/global.json', { '{ "test": { "runner": "microsoft.testing.platform" } }' })
write('Bom/global.json', { '\239\187\191{ "test": { "runner": "Microsoft.Testing.Platform" } }' })
write('Broken/global.json', { '{ "test": { "runner": ' })
write('Comments/global.json', { '{ // a comment, which JSON does not have', '  "test": { "runner": "Microsoft.Testing.Platform" } }' })
write('Vstest/global.json', { '{ "test": { "runner": "VSTest" } }' })
T.check('no global.json is VSTest', dotnet.uses_mtp(root .. '/Nothing'), false)
T.check('a global.json that says nothing about it is too', dotnet.uses_mtp(root .. '/Vs/sub'), false)
T.check('one that names VSTest is', dotnet.uses_mtp(root .. '/Vstest'), false)
T.check('Microsoft.Testing.Platform in global.json is that', dotnet.uses_mtp(root .. '/Mtp'), true)
T.check('found from a directory below it', dotnet.uses_mtp(root .. '/Mtp/a/b'), true)
T.check('whatever the case', dotnet.uses_mtp(root .. '/Caps'), true)
T.check('with a byte order mark in front, which Windows editors write', dotnet.uses_mtp(root .. '/Bom'), true)
T.check('a file that is not JSON says nothing', dotnet.uses_mtp(root .. '/Broken'), false)
T.check('and neither does one with comments, which .NET accepts and Neovim\'s decoder does not', dotnet.uses_mtp(root .. '/Comments'), false)

T.section('the command for each')
local sln = { kind = 'solution', path = root .. '/Sol/Big.sln', dir = root .. '/Sol' }
local csproj = { kind = 'project', path = root .. '/Sol/src/App/App.csproj', dir = root .. '/Sol/src/App' }
T.check('VSTest takes the path as it is', dotnet.test_command(sln), { 'dotnet', 'test', sln.path })
T.check('and a filter after it', dotnet.test_command(csproj, 'FullyQualifiedName~X'), { 'dotnet', 'test', csproj.path, '--filter', 'FullyQualifiedName~X' })
local mtp_sln = { kind = 'solution', path = root .. '/Mtp/M.sln', dir = root .. '/Mtp' }
local mtp_proj = { kind = 'project', path = root .. '/Mtp/a/M.csproj', dir = root .. '/Mtp/a' }
T.check('Microsoft Testing Platform wants --solution', dotnet.test_command(mtp_sln), { 'dotnet', 'test', '--solution', mtp_sln.path })
T.check('or --project, and takes the filter the same way', dotnet.test_command(mtp_proj, 'F'), { 'dotnet', 'test', '--project', mtp_proj.path, '--filter', 'F' })
T.check('neither is given -nologo: the test program refuses it', vim.tbl_contains(dotnet.test_command(mtp_proj), '-nologo') or vim.tbl_contains(dotnet.test_command(csproj), '-nologo'), false)

T.section('the arguments of :Run')
T.check('words', dotnet.split_args('one two  three'), { 'one', 'two', 'three' })
T.check('none', dotnet.split_args(''), {})
T.check('only spaces', dotnet.split_args('   '), {})
T.check('a double-quoted one stays together', dotnet.split_args('--name "John Smith" --age 3'), { '--name', 'John Smith', '--age', '3' })
T.check('so does a single-quoted one', dotnet.split_args("a 'b c' d"), { 'a', 'b c', 'd' })
T.check('an apostrophe inside double quotes is a character', dotnet.split_args([["it's fine" ok]]), { "it's fine", 'ok' })
T.check('and a double quote inside single quotes', dotnet.split_args([['say "hi"' ok]]), { 'say "hi"', 'ok' })
T.check('an escaped space is part of the word', dotnet.split_args([[a\ b c]]), { 'a b', 'c' })
T.check('an escaped quote is a quote', dotnet.split_args([[say \"hi\"]]), { 'say', '"hi"' })
T.check('inside double quotes, \\" is a quote and \\\\ a backslash', dotnet.split_args([["a \"b\" c\\"]]), { 'a "b" c\\' })
T.check('an empty pair of quotes is an argument', dotnet.split_args('a "" b'), { 'a', '', 'b' })
T.check('quotes in the middle of a word join', dotnet.split_args([[--x="a b"c]]), { '--x=a bc' })
T.check('an unclosed quote runs to the end', dotnet.split_args('a "b c'), { 'a', 'b c' })
T.check('a trailing backslash is kept', dotnet.split_args([[a\]]), { 'a\\' })

T.section('picking tests by name needs a syntax tree')
-- Even a Neovim started with -u NONE has the parsers nvim-treesitter built, in
-- the data directory's site/, which is on the runtimepath whatever the config says.
-- Left to itself this test would pass or fail by what is installed.
vim.o.runtimepath = vim.env.VIMRUNTIME
vim.cmd('enew')
vim.bo.filetype = 'cs'
local filter, label, err = dotnet.filter_for(0, 'nearest')
T.ok('with no c_sharp parser it says what is missing instead of failing', filter == nil and err:find('c_sharp parser', 1, true) ~= nil, { filter, err })
vim.bo.filetype = 'lua'
filter, label, err = dotnet.filter_for(0, 'file')
T.check('another kind of file is refused', err, 'This is not a C# file')

T.finish()
