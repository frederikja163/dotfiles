-- env: full
-- The debug mode and what it drives (lua/ide/debug.lua), in two parts.
--
-- The first needs nothing but the config: that each key of the mode asks nvim-dap
-- for the right thing, with nvim-dap's functions replaced by ones that write down
-- how they were called, and that a key with no session behind it says so.
--
-- The second is a real session, with the real netcoredbg, on a solution made here:
-- build, launch with a launchSettings profile, stop at a breakpoint, step over,
-- into another file, out; up and down the stack; a value under the cursor; run to
-- the cursor; a condition; the variables sidebar; the program's output;
-- stopping; another profile; a library that cannot be run; and what is left behind
-- when the editor quits. It says SKIPPED, loudly, where netcoredbg or dotnet is
-- not installed (netcoredbg is in packages/aur.txt).

vim.env.NVIM_TEST_BUDGET = '600'
local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

vim.o.showmode = false
vim.g.ide_autosave = false
vim.g.ide_format = false

local modal = require('ide.modal')
local debug_module = require('ide.debug')

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level or vim.log.levels.INFO }) end
local function last_note() return notified[#notified] and notified[#notified].message or '' end

-- Run the mode with keys typed into it, as a person would, and Escape to end it.
--
-- Not Escape when the last key ends the mode by itself (q, a, R, or one the mode
-- does not own): the Escape would be left in the keyboard buffer for the next call
-- to read as its first key, which ends that one before its own keys arrive, and
-- every call after it is one behind.
local function mode(keys, ends_itself)
    vim.defer_fn(function() vim.api.nvim_input(keys .. (ends_itself and '' or '<Esc>')) end, 80)
    return modal.enter('debug')
end

T.async(function()
    ------------------------------------------------------------------------
    T.section('the config loads, and the mode is there')
    T.check('no module failed', vim.g.ide_failed, {})
    T.check('<leader>D enters it', vim.fn.maparg(vim.keycode('<Space>D'), 'n', false, true).desc, 'Mode: Debug the program, step by step')
    local listed
    for _, entry in ipairs(modal.list()) do
        if entry.name == 'debug' then listed = entry end
    end
    T.ok('it is in the registry the cheatsheet reads', listed ~= nil)
    local keys = vim.tbl_map(function(key) return key.lhs end, listed.keys)
    T.check('with its keys', keys, { 'j', 'l', 'h', 'c', 'p', 'r', 'b', 'B', 'u', 'd', 'K', 's', 'f', 'R', 'a', 'q' })
    T.check('and no key for a logpoint, which netcoredbg cannot do: it would stop like any other', vim.tbl_contains(keys, 'L'), false)
    T.check('and the ones that end it are marked', vim.tbl_map(function(key) return key.leave end, vim.tbl_filter(function(key) return key.leave end, listed.keys)), { true, true, true })
    local sheet = table.concat(require('ide.palette').key_lines(), '\n')
    T.ok('the cheatsheet lists them', sheet:find('debug ▸ j', 1, true) ~= nil and sheet:find('Step into the call', 1, true) ~= nil)
    local palette = table.concat(require('ide.palette').palette_lines(), '\n')
    T.ok('the palette has the mode and the commands', palette:find('Mode: debug', 1, true) and palette:find(':Debug', 1, true)
        and palette:find(':DebugAttach', 1, true) and palette:find(':Breakpoints', 1, true), palette)
    T.check('nothing is going on', debug_module.status(), nil)
    T.check('nvim-dap is not loaded until a key needs it', package.loaded['dap'], nil)

    ------------------------------------------------------------------------
    T.section('with no session, a key says so instead of failing')
    for key, expected in pairs({ j = 'Not debugging', l = 'Not debugging', h = 'Not debugging', r = 'Not debugging', u = 'Not debugging', d = 'Not debugging', K = 'Not debugging', p = 'Not debugging' }) do
        notified = {}
        mode(key)
        T.ok(key .. ' says ' .. expected, last_note():find(expected, 1, true) ~= nil, last_note())
    end
    notified = {}
    mode('q', true)
    T.ok('q says there is nothing to stop', last_note() == 'Not debugging', last_note())

    ------------------------------------------------------------------------
    T.section('each key asks nvim-dap for the right thing')
    local dap = require('dap')
    local calls = {}
    local real = {}
    -- The original is kept the first time only: replacing a function twice and
    -- keeping the second "original" would put back the first replacement.
    local function replace(name, fn)
        real[name] = real[name] or dap[name]
        dap[name] = fn
    end
    for _, name in ipairs({ 'step_over', 'step_into', 'step_out', 'up', 'down', 'continue', 'pause', 'run_to_cursor', 'toggle_breakpoint' }) do
        replace(name, function() table.insert(calls, name) end)
    end
    replace('set_breakpoint', function(condition, hit, message) table.insert(calls, { 'set_breakpoint', condition, hit, message }) end)
    local stopped = true
    replace('session', function() return { stopped_thread_id = stopped and 1 or nil, config = { request = 'launch' } } end)

    local function pressed(typed)
        calls = {}
        mode(typed)
        return calls
    end
    T.check('j steps over', pressed('j'), { 'step_over' })
    T.check('l steps into', pressed('l'), { 'step_into' })
    T.check('h steps out', pressed('h'), { 'step_out' })
    T.check('the arrow keys are the same as j, l, h', { pressed('<Down>')[1], pressed('<Right>')[1], pressed('<Left>')[1] }, { 'step_over', 'step_into', 'step_out' })
    T.check('u goes up the stack', pressed('u'), { 'up' })
    T.check('d goes down it', pressed('d'), { 'down' })
    T.check('c continues a program that is stopped', pressed('c'), { 'continue' })
    T.check('r runs to the cursor', pressed('r'), { 'run_to_cursor' })
    T.check('b toggles a breakpoint', pressed('b'), { 'toggle_breakpoint' })
    T.check('p pauses', pressed('p'), { 'pause' })
    T.check('the mode stays: three steps in one go are three steps', pressed('jjj'), { 'step_over', 'step_over', 'step_over' })
    T.check('and a count is not a count of steps: it is one', pressed('5j'), { 'step_over' })

    stopped = false
    notified = {}
    T.check('c on a program that is running does not continue it', pressed('c'), {})
    T.ok('it says how to stop it instead', last_note():find('p pauses', 1, true) ~= nil, last_note())
    stopped = true

    local real_input = vim.ui.input
    vim.ui.input = function(opts, callback) callback('i == 3') end
    T.check('B asks for a condition, and sets a breakpoint with it', pressed('B'), { { 'set_breakpoint', 'i == 3' } })
    vim.ui.input = function(opts, callback) callback('') end
    T.check('an empty answer sets nothing', pressed('B'), {})
    vim.ui.input = function(opts, callback) callback(nil) end
    T.check('and neither does giving up', pressed('B'), {})
    vim.ui.input = real_input

    T.check('k is not a key of the mode: it ends it', mode('k', true).reason, 'foreign')
    vim.api.nvim_feedkeys('', 'x', false)
    T.check('and so is w', (function() calls = {}; return mode('w', true).reason end)(), 'foreign')
    vim.api.nvim_feedkeys('', 'x', false)
    T.check('which asked nvim-dap for nothing', calls, {})
    T.check('q with a launched session ends it', (function()
        local terminated
        replace('terminate', function() terminated = true end)
        mode('q', true)
        dap.terminate = real.terminate
        return terminated
    end)(), true)
    T.check('q with an attached one lets it go and leaves it running', (function()
        local result
        replace('session', function() return { config = { request = 'attach' } } end)
        replace('disconnect', function(opts) result = opts end)
        mode('q', true)
        dap.disconnect = real.disconnect
        return result
    end)(), { terminateDebuggee = false })

    for name, fn in pairs(real) do dap[name] = fn end

    ------------------------------------------------------------------------
    T.section('breakpoints, with nothing running')
    local scratch = vim.fn.tempname() .. '.cs'
    vim.fn.writefile({ 'class A', '{', '    int M() { return 1; }', '    int N() { return 2; }', '}' }, scratch)
    vim.cmd('edit ' .. scratch)
    local buf = vim.api.nvim_get_current_buf()
    local function breakpoints()
        local found = {}
        for b, list in pairs(require('dap.breakpoints').get()) do
            for _, bp in ipairs(list) do found[#found + 1] = { vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':t'), bp.line, bp.condition } end
        end
        table.sort(found, function(a, b) return a[2] < b[2] end)
        return found
    end
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    mode('b')
    T.check('b puts one on this line', #breakpoints(), 1)
    T.check('as a sign in the margin', #vim.fn.sign_getplaced(buf, { group = '*' })[1].signs, 1)
    T.check('a sign this config defined, not the plugin\'s letter', vim.fn.sign_getdefined('DapBreakpoint')[1].text:gsub('%s+$', ''), '●')
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.ui.input = function(opts, callback) callback('x > 1') end
    mode('B')
    vim.ui.input = real_input
    T.check('B adds one that has a condition', breakpoints(), {
        { vim.fn.fnamemodify(scratch, ':t'), 3 }, { vim.fn.fnamemodify(scratch, ':t'), 4, 'x > 1' } })

    local listed_items
    T.picker_script({
        function() listed_items = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items()) end,
        '<Esc>',
    })
    vim.schedule(function() vim.cmd('Breakpoints') end)
    T.ok(':Breakpoints lists them in a picker', T.until_true(5000, function() return listed_items ~= nil end))
    T.check('each with its place and its line, and its condition', listed_items, {
        vim.fn.fnamemodify(scratch, ':.') .. ':3  int M() { return 1; }',
        vim.fn.fnamemodify(scratch, ':.') .. ':4  int N() { return 2; }   when x > 1',
    })
    T.sleep(300)
    vim.cmd('Breakpoints!')
    T.check(':Breakpoints! clears them all', breakpoints(), {})
    notified = {}
    vim.cmd('Breakpoints')
    T.check('and with none the command says so', last_note(), 'No breakpoints')

    ------------------------------------------------------------------------
    -- A real session
    ------------------------------------------------------------------------
    if vim.fn.executable('netcoredbg') == 0 or vim.fn.executable('dotnet') == 0 then
        print('  SKIPPED: the real session needs netcoredbg and dotnet (netcoredbg-bin is in packages/aur.txt)')
        return
    end

    -- The C# files opened below are in a solution, and Roslyn would start for them:
    -- seconds of work this test has no use for, and noise in its messages.
    vim.lsp.enable('roslyn_ls', false)
    vim.env.MSBUILDDISABLENODEREUSE = '1'
    vim.env.UseSharedCompilation = 'false'
    vim.env.DOTNET_CLI_TELEMETRY_OPTOUT = '1'

    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    root = vim.uv.fs_realpath(root)
    local function write(path, lines)
        local full = root .. '/' .. path
        vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
        vim.fn.writefile(lines, full)
        return full
    end
    local function run(cmd)
        local result = vim.system(cmd, { cwd = root, text = true }):wait()
        return result.code == 0, (result.stdout or '') .. (result.stderr or '')
    end

    local calc = write('src/Lib/Calc.cs', {
        'namespace Lib;',                        -- 1
        '',                                      -- 2
        'public static class Calc',              -- 3
        '{',                                     -- 4
        '    public static int Add(int a, int b)', -- 5
        '    {',                                 -- 6
        '        var sum = a + b;',              -- 7
        '        return sum;',                   -- 8
        '    }',                                 -- 9
        '}',                                     -- 10
    })
    write('src/Lib/Lib.csproj', {
        '<Project Sdk="Microsoft.NET.Sdk">',
        '  <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>disable</ImplicitUsings></PropertyGroup>',
        '</Project>',
    })
    write('src/App/App.csproj', {
        '<Project Sdk="Microsoft.NET.Sdk">',
        '  <PropertyGroup>',
        '    <OutputType>Exe</OutputType>',
        '    <TargetFramework>net10.0</TargetFramework>',
        '    <AssemblyName>Acme.App</AssemblyName>',
        '    <ImplicitUsings>disable</ImplicitUsings>',
        '  </PropertyGroup>',
        '  <ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup>',
        '</Project>',
    })
    local program = write('src/App/Program.cs', {
        'using System;',                                                                                   -- 1
        'using Lib;',                                                                                      -- 2
        '',                                                                                                -- 3
        'var profile = Environment.GetEnvironmentVariable("DOTNET_LAUNCH_PROFILE");',                      -- 4
        'var url = Environment.GetEnvironmentVariable("ASPNETCORE_URLS");',                                -- 5
        'var total = 0;',                                                                                  -- 6
        'for (var i = 1; i <= 3; i++)',                                                                    -- 7
        '{',                                                                                               -- 8
        '    total = Calc.Add(total, i);',                                                                 -- 9
        '}',                                                                                               -- 10
        'Console.WriteLine($"total={total} profile={profile} url={url} env={Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT")} args={string.Join(",", args)}");', -- 11
    })
    write('src/App/Properties/launchSettings.json', {
        '{',
        '  "profiles": {',
        '    "http": {',
        '      "commandName": "Project",',
        '      "commandLineArgs": "--verbose \\"two words\\"",',
        '      "applicationUrl": "http://localhost:5123;https://localhost:7123",',
        '      "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Development" }',
        '    },',
        '    "IIS Express": { "commandName": "IISExpress" },',
        '    "other": { "commandName": "Project", "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Staging" } }',
        '  }',
        '}',
    })
    run({ 'dotnet', 'new', 'sln', '-n', 'App', '--format', 'sln' })
    run({ 'dotnet', 'sln', 'App.sln', 'add', 'src/Lib/Lib.csproj', 'src/App/App.csproj' })
    local restored, restore_output = run({ 'dotnet', 'restore', 'App.sln', '-nologo', '-v', 'q' })
    if not restored then
        print('  SKIPPED: the solution could not be restored here: ' .. restore_output:sub(1, 200):gsub('\n', ' '))
        return
    end
    vim.cmd.cd(root)

    -- Helpers for what a session does, which it does in its own time.
    local function session() return dap.session() end
    local function frame() local s = session(); return s and s.current_frame end
    local function stopped_at(file, line)
        return T.until_true(30000, function()
            local s = session()
            local f = s and s.stopped_thread_id and s.current_frame
            if not f or not f.source then return false end
            return vim.fn.fnamemodify(f.source.path or '', ':t') == file and (line == nil or f.line == line)
        end)
    end
    local function ended() return T.until_true(30000, function() return session() == nil end) end
    local function evaluate(expression)
        local s = session()
        local answer
        s:request('evaluate', { expression = expression, context = 'repl', frameId = frame().id }, function(err, response) answer = response or err end)
        T.until_true(10000, function() return answer ~= nil end)
        return answer and answer.result
    end
    local function repl_text()
        local out = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(b):find('dap-repl', 1, true) then
                vim.list_extend(out, vim.api.nvim_buf_get_lines(b, 0, -1, false))
            end
        end
        return table.concat(out, '\n')
    end
    local function lingering()
        local found = {}
        local result = vim.system({ 'pgrep', '-f', '[A]cme\\.App\\.dll' }, { text = true }):wait()
        for pid in (result.stdout or ''):gmatch('%d+') do
            local file = io.open('/proc/' .. pid .. '/cmdline')
            local cmdline = file and file:read('*a') or ''
            if file then file:close() end
            if cmdline:find(root, 1, true) then found[#found + 1] = tonumber(pid) end
        end
        return found
    end
    local function code_window()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local b = vim.api.nvim_win_get_buf(win)
            if vim.bo[b].buftype == '' then return win end
        end
    end
    local function floats()
        local found = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(win).relative ~= '' then found[#found + 1] = win end
        end
        return found
    end
    local function windows() return #vim.api.nvim_tabpage_list_wins(0) end

    vim.cmd('silent only!')
    vim.cmd('edit ' .. program)
    T.ok('nothing is running that should not be', #lingering() == 0)

    ------------------------------------------------------------------------
    T.section('starting: build, then launch with the default profile')
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    mode('b')
    T.check('there is a breakpoint on the call', breakpoints(), { { 'Program.cs', 9 } })
    notified = {}
    local origin = vim.api.nvim_get_current_win()
    mode('c')
    T.check('c with no session starts one, which begins with a build', vim.g.ide_job, 'Build')
    T.ok('and the statusline says so', require('ide.statusline').render(origin):find('BUILD', 1, true) ~= nil)
    T.ok('it stopped at the breakpoint', stopped_at('Program.cs', 9))
    T.ok('the build said it worked', (function()
        for _, n in ipairs(notified) do if n.message:find('Build succeeded', 1, true) then return true end end
    end)(), notified)
    T.ok('and what is being debugged, and with which profile', (function()
        for _, n in ipairs(notified) do if n.message == 'Debugging App with the "http" profile' then return true end end
    end)(), vim.tbl_map(function(n) return n.message end, notified))
    T.check('the first profile that runs the project, from a launchSettings.json', session().config.env.DOTNET_LAUNCH_PROFILE, 'http')
    T.check('its environment', session().config.env.ASPNETCORE_ENVIRONMENT, 'Development')
    T.check('its applicationUrl as the one ASP.NET reads', session().config.env.ASPNETCORE_URLS, 'http://localhost:5123;https://localhost:7123')
    T.check('its command line, a quoted argument as one', session().config.args, { '--verbose', 'two words' })
    T.check('the program that MSBuild named, from the AssemblyName', vim.fn.fnamemodify(session().config.program, ':t'), 'Acme.App.dll')
    T.check('run from the project', session().config.cwd, root .. '/src/App')
    T.check('the statusline says it is stopped', require('ide.statusline').render(origin):find('DEBUG stopped', 1, true) ~= nil, true)
    T.check('and status() agrees', debug_module.status(), 'stopped')
    T.check('the debugger moved the cursor to the line it stopped on', { vim.fn.expand('%:t'), vim.api.nvim_win_get_cursor(0)[1] }, { 'Program.cs', 9 })
    T.ok('the REPL opened below, for the program\'s output', T.until_true(5000, function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('dap-repl', 1, true) then return true end
        end
        return false
    end))
    T.check('and focus is still in the code', vim.bo[vim.api.nvim_win_get_buf(0)].buftype, '')
    T.check('the first time round the loop, i is 1', evaluate('i'), '1')

    T.section('stepping')
    mode('j')
    T.ok('j: over the line', T.until_true(30000, function() local f = frame(); return f and session().stopped_thread_id and f.line ~= 9 end))
    T.check('still in this file', vim.fn.expand('%:t'), 'Program.cs')
    local after_step = frame().line
    T.ok('and forward in it', after_step > 9, after_step)
    mode('c')
    T.ok('c: on to the breakpoint, round the loop again', stopped_at('Program.cs', 9))
    T.check('i is 2', evaluate('i'), '2')

    -- Line 6, the opening brace, and not 7 where the first statement is: a method
    -- has a sequence point at its `{`, and a step into it stops there first.
    mode('l')
    T.ok('l: into Calc.Add, which is in another file, and the editor follows', stopped_at('Calc.cs', 6))
    T.check('showing it', vim.fn.expand('%:t'), 'Calc.cs')
    T.check('on that line', vim.api.nvim_win_get_cursor(0)[1], 6)
    T.check('where the arguments are the ones passed', { evaluate('a'), evaluate('b') }, { '1', '2' })
    mode('u')
    T.ok('u: up the stack, to the caller', T.until_true(10000, function() return vim.fn.expand('%:t') == 'Program.cs' end))
    T.check('the editor shows the caller\'s line', vim.api.nvim_win_get_cursor(0)[1], 9)
    mode('d')
    T.ok('d: and back down', T.until_true(10000, function() return vim.fn.expand('%:t') == 'Calc.cs' end))
    T.check('at the line it stopped on', vim.api.nvim_win_get_cursor(0)[1], 6)
    mode('h')
    T.ok('h: out, to the caller', stopped_at('Program.cs'))
    T.check('in the file the call is in', vim.fn.expand('%:t'), 'Program.cs')

    T.section('a value, and what is in scope')
    local here = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 9, 4 })
    local floats_before = #floats()
    mode('K')
    T.ok('K: a window opens next to the word under the cursor', T.until_true(10000, function() return #floats() > floats_before end))
    local function hover_float()
        for _, win in ipairs(floats()) do
            local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
            if name:find('dap-hover-', 1, true) then return win, name end
        end
    end
    local float, float_name = hover_float()
    T.ok('it is for total', float_name ~= nil and float_name:find(': total', 1, true) ~= nil, float_name)
    T.ok('and shows its value, which is one by now: the first time round added one', T.until_true(10000, function()
        local win = hover_float()
        return win ~= nil and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1] == '1'
    end))
    T.check('focus is back in the code', vim.api.nvim_get_current_win(), here)
    vim.api.nvim_win_set_cursor(0, { 9, 5 })
    T.ok('moving the cursor closes it', T.until_true(5000, function() return hover_float() == nil end))

    local windows_before = windows()
    mode('s')
    T.check('s: the variables open beside', windows(), windows_before + 1)
    T.check('without taking focus from the code', vim.bo[vim.api.nvim_win_get_buf(0)].buftype, '')
    mode('s')
    T.check('and the next s closes them', windows(), windows_before)
    mode('f')
    T.check('f: the call stack opens', windows(), windows_before + 1)
    mode('f')
    T.check('and closes', windows(), windows_before)

    T.section('run to the cursor, and a condition')
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    mode('b')
    T.check('b on a line that has one takes it off', breakpoints(), {})
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    mode('r')
    T.ok('r: runs to the line the cursor is on', stopped_at('Program.cs', 11))
    T.check('all three times round the loop are done', evaluate('total'), '6')
    T.check('the window did not move on its own', vim.api.nvim_win_get_cursor(0)[1], 11)

    -- Not the same session: a condition has to be set before the line is reached.
    mode('c')
    T.ok('c: to the end', ended())
    T.check('the status goes with the session', debug_module.status(), nil)
    T.ok('and the statusline has no DEBUG in it', require('ide.statusline').render(origin):find('DEBUG', 1, true) == nil)
    T.ok('the program\'s output reached the REPL, with the profile, the arguments and the environment it was given', repl_text():find(
        'total=6 profile=http url=http://localhost:5123;https://localhost:7123 env=Development args=--verbose,two words', 1, true) ~= nil, repl_text())
    T.check('and nothing is left running', #lingering(), 0)

    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    vim.ui.input = function(opts, callback) callback('i == 3') end
    mode('B')
    vim.ui.input = real_input
    T.check('a breakpoint with a condition on the call', breakpoints(), { { 'Program.cs', 9, 'i == 3' } })
    mode('c')
    T.ok('it stops only when the condition is true', stopped_at('Program.cs', 9))
    T.check('which is the third time', evaluate('i'), '3')
    T.check('and the first two times it did not', evaluate('total'), '3')
    mode('c')
    T.ok('on to the end: nothing else stops it', ended())
    vim.cmd('Breakpoints!')

    ------------------------------------------------------------------------
    T.section('another profile, one that is not there')
    notified = {}
    vim.cmd('Debug other')
    T.ok('a profile is asked for by name', T.until_true(60000, function() return session() ~= nil or last_note():find('Debugging App', 1, true) ~= nil end))
    T.ok('the program ran to its end with that one', T.until_true(60000, function()
        return repl_text():find('profile=other url= env=Staging args=', 1, true) ~= nil
    end), repl_text())
    T.ok('and said which', (function()
        for _, n in ipairs(notified) do if n.message == 'Debugging App with the "other" profile' then return true end end
    end)(), vim.tbl_map(function(n) return n.message end, notified))
    ended()
    notified = {}
    vim.cmd('Debug nope')
    T.ok('a profile that is not there is refused, naming the ones that are', T.until_true(60000, function() return last_note():find('No launch profile called nope', 1, true) ~= nil end), last_note())
    T.ok('with all three', last_note():find('http, IIS Express, other', 1, true) ~= nil, last_note())
    T.check('and nothing was started', session(), nil)
    T.check('the profiles complete, in the order written', vim.fn.getcompletion('Debug ', 'cmdline'), { 'http', 'IIS Express', 'other' })
    T.check('narrowed by what is typed', vim.fn.getcompletion('Debug o', 'cmdline'), { 'other' })

    ------------------------------------------------------------------------
    T.section('a library cannot be run')
    vim.cmd('edit ' .. calc)
    notified = {}
    vim.cmd('Debug')
    T.ok('it says so, and why', T.until_true(60000, function() return last_note():find('is a library, not a program', 1, true) ~= nil end), last_note())
    T.check('and does not start', session(), nil)
    vim.cmd('edit ' .. program)

    T.section('a project that does not build is not launched')
    local broken = write('src/App/Broken.cs', { 'namespace App; class Broken { int a = missing; }' })
    notified = {}
    vim.cmd('Debug')
    T.ok('the build fails', T.until_true(60000, function() return last_note():find('Build FAILED', 1, true) ~= nil end), last_note())
    T.check('and nothing is debugged', session(), nil)
    T.check('the errors are where :Build puts them', vim.fn.getqflist({ title = 0 }).title:find('Build App.csproj: 1 error', 1, true) ~= nil, true)
    os.remove(broken)
    vim.cmd('cclose')

    ------------------------------------------------------------------------
    T.section('q stops it, and the program with it')
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    mode('b')
    vim.cmd('Debug')
    T.ok('stopped at the breakpoint again', stopped_at('Program.cs', 9))
    T.check('the program is running, under the debugger', #lingering() > 0, true)
    mode('q', true)
    T.ok('q: the session is over', ended())
    T.ok('and the program is gone', T.until_true(10000, function() return #lingering() == 0 end), lingering())
    T.check('the mode ended too', modal.current(), nil)

    T.section(':Debug! ends a session as well')
    vim.cmd('Debug')
    T.ok('stopped', stopped_at('Program.cs', 9))
    vim.cmd('Debug!')
    T.ok('and the bang stops it', ended())
    T.ok('with nothing left behind', T.until_true(10000, function() return #lingering() == 0 end))

    T.section('starting twice')
    vim.cmd('Debug')
    T.ok('the first stopped', stopped_at('Program.cs', 9))
    notified = {}
    vim.cmd('Debug')
    T.ok('a second start while one is going says so, and does not start another', last_note():find('Already debugging', 1, true) ~= nil, last_note())
    T.check('there is one session', vim.tbl_count(dap.sessions()), 1)

    ------------------------------------------------------------------------
    T.section('quitting the editor with a session going')
    vim.api.nvim_set_current_win(code_window())
    mode('s')
    mode('f')
    T.check('the REPL, which the session opened, and the two sidebars are open with the code', windows(), 4)
    T.check('so R, which toggles it, closes the REPL', (function() mode('R', true); return windows() end)(), 3)
    T.check('and opens it again', (function() mode('R', true); return windows() end)(), 4)
    vim.api.nvim_set_current_win(code_window())
    T.check('and a session is stopped at a breakpoint', debug_module.status(), 'stopped')
    vim.api.nvim_exec_autocmds('VimLeavePre', {})
    T.ok('the session is over', session() == nil)
    T.check('so is the program', #lingering(), 0)
    T.check('the windows that have no file are closed, so that a session file has no empty splits to restore', windows(), 1)
    local session_file = vim.fn.tempname()
    vim.cmd('mksession! ' .. session_file)
    local saved = table.concat(vim.fn.readfile(session_file), '\n')
    T.check('and the session file knows nothing of them', { saved:find('dap-repl', 1, true), saved:find('DAP ', 1, true) }, {})

    ------------------------------------------------------------------------
    T.section('attach')
    vim.cmd('edit ' .. program)
    local sleeper = vim.system({ 'sleep', '60' }, { text = true })
    local picked_label
    local real_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
        for _, item in ipairs(items) do
            if item.pid == sleeper.pid then picked_label = opts.label and opts.label(item) or item.name; return on_choice(item) end
        end
        on_choice(nil)
    end
    notified = {}
    mode('a', true)
    T.ok('a: the processes are offered, to choose from', T.until_true(15000, function() return picked_label ~= nil end))
    vim.ui.select = real_select
    -- `sleep` is not a .NET program and this kernel may refuse the debugger anyway,
    -- so what is checked is how far this config gets it: to an attach request for
    -- the process that was chosen. Whether the debugger then manages to attach is
    -- for netcoredbg and the kernel.
    T.ok('and it was a request to attach, with the process that was chosen', T.until_true(15000, function()
        local s = session()
        return s ~= nil and s.config.request == 'attach'
    end))
    local s = session()
    T.check('the session is an attach, to the pid chosen', s and { s.config.request, s.config.processId }, { 'attach', sleeper.pid })
    mode('q', true)
    T.ok('q lets go of it', ended())
    T.check('and the process that was attached to is still alive: letting go is not killing it', pcall(vim.uv.kill, sleeper.pid, 0), true)
    pcall(vim.uv.kill, sleeper.pid, 'sigterm')

    ------------------------------------------------------------------------
    T.section('nothing is left')
    T.check('no program of this test is running', #lingering(), 0)
    T.check('no session', session(), nil)
    vim.notify = real_notify
end)
