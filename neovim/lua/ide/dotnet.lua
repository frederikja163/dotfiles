-- Building, testing and running .NET code without leaving the editor: :Build,
-- :Test, :Run and :Watch, and the keys for them (<leader>b and <leader>t).
--
-- Not `:make`. It is the obvious thing and it is wrong for this: it blocks the
-- editor for as long as the build takes, which for a solution is a minute and
-- sometimes several, and it pushes its list after the current one and frees every
-- newer list (the quickfix stack problem lists.lua is about), so a build in the
-- middle of reading references or a review threw those away. Here the command runs
-- in the background, its output is read when it ends, and the result goes into a
-- list that this module owns by id and updates in place -- one for builds, one for
-- tests -- so the stack does not fill with a new list per run, and the one that is
-- there is the latest.
--
-- What the output looks like was found by running the tools, and the parsers are
-- tested against what they printed (tests/nvim/test_dotnet.lua). Three things in it
-- are not what one would guess:
--
--   * Every diagnostic of a failed build is printed twice, once as it happens and
--     again under "Build FAILED.", so a naive parse doubles the list. They are
--     deduplicated, keeping the first, which is in the order the compiler found them.
--   * A failed test is a block: a header, the message, the stack. The header is
--     `  Failed Name [3 ms]` from VSTest and `failed Name (3ms)` from Microsoft
--     Testing Platform, and the name of a theory has spaces and brackets in it, so it
--     is taken as everything between the word and the time. The stack frames say
--     `in /path/File.cs:line 12` in one and `in /path/File.cs:12` in the other.
--     A frame inside the test framework has a path too (`/_/src/...`, from a build
--     with deterministic paths) which is not a file; the first frame whose file
--     exists is the test's own.
--   * The runner is chosen by global.json, and the two take different arguments.
--     Microsoft Testing Platform mode (`"test": { "runner": "Microsoft.Testing.Platform" }`)
--     wants `--project` or `--solution` where VSTest takes the path as it is, and
--     passes anything it does not know -- `-nologo` -- to the test program, which
--     refuses it. So no -nologo is passed to `dotnet test`; DOTNET_NOLOGO says it
--     for both. `--filter` works in both for MSTest and NUnit. xunit v3 has filters
--     of its own (`--filter-class` and so on) that this does not know: `:Test nearest`
--     and `:Test file` have no effect on a project that uses them, and `:Test` and
--     `:Test last` do.
--
-- Also tried and rejected: a TRX file (`--logger trx`), which has the file and line
-- of every failure as data and needs no parsing of prose. It is VSTest only, needs
-- a results directory made and read back, and the prose parse is needed anyway for
-- the runner that has no TRX and for the build errors that come before any test.
--
-- Which tests. `all` is the solution above the file (the project, with no solution).
-- `file` and `nearest` are chosen by name, from the syntax tree: the namespace, the
-- class and the method that contain the cursor, joined as the runner names them
-- (`Ns.Outer+Inner.Method`). A method is matched exactly (`=`), and also with a
-- bracket after it (`~Name\(`), because a theory's rows are one test to xunit and
-- MSTest and several, each named with its arguments, to NUnit. A class is matched
-- with a dot after its name, so that `CalcTests` is not also `CalcTestsExtra`.
--
-- English only. DOTNET_CLI_UI_LANGUAGE is set so that the SDK and the compiler
-- print English, which is what the parsers read. The runtime's own words in a
-- stack trace (`in`, `line`) follow the system language and are not under that
-- setting: in another language a failure is still listed, with its message and
-- without a place to go to, and :DotnetOutput has the whole of what was printed.
-- Changing the language of the test run itself would change what the tests do --
-- their culture -- and a test run that behaves differently here than anywhere
-- else is worse than a list that has to be read.
--
-- :Run and :Watch are terminals, in a window at the bottom, because they are
-- programs that run until stopped and talk back. Focus stays in the editor: most
-- of what they print is read, not answered. Running again replaces the terminal,
-- in the same window, and stops the old process. They are closed when the editor
-- quits, *before* the session is written (so this module is loaded before
-- ide.sessions, which is why init.lua has it there): a terminal window in a
-- session is restored as `:edit term://...`, which starts the program again -- by
-- its executable alone, without the arguments -- every time the project is opened.
--
-- Not here: debugging (ide.debug), a choice between several solutions in one
-- directory (the first, by name, is used), and a startup project: :Run runs the
-- project of the file you are in.

local group = require('ide.group')
local registry = require('ide.registry')

local M = {}

local ERROR, WARN = vim.log.levels.ERROR, vim.log.levels.WARN

local function notify(text, level)
    vim.notify(text, level or vim.log.levels.INFO)
end

local state = {
    job = nil,
    generation = 0,
    output = '',
    output_buf = nil,
    lists = {},
    last_test = nil,
    terminals = {},
}

----------------------------------------------------------------------------
-- What to build
----------------------------------------------------------------------------

local function extension(name)
    return name:match('%.(%w+)$') or ''
end

local function is_project(name)
    local ext = extension(name)
    return ext == 'csproj' or ext == 'fsproj' or ext == 'vbproj'
end

local function is_solution(name)
    local ext = extension(name)
    return ext == 'sln' or ext == 'slnx'
end

-- The first file in `dir` the test accepts, by name, so that two solutions in one
-- directory are at least the same two every time.
local function first_in(dir, accepts)
    local found = {}
    for name, kind in vim.fs.dir(dir) do
        if kind == 'file' and accepts(name) then
            table.insert(found, name)
        end
    end
    table.sort(found)
    return found[1] and vim.fs.joinpath(dir, found[1]) or nil
end

--- What `dotnet` is to be pointed at for the file at `path`: the solution above it,
--- or failing that the project. `prefer = 'project'` takes the file's own project
--- even where a solution is above it, which is what running and testing a file need.
---@param path string
---@param prefer? 'solution'|'project'
---@return { kind: 'solution'|'project', path: string, dir: string }?
function M.target(path, prefer)
    local start = path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd()

    local function find(accepts, kind)
        local dir = vim.fs.root(start, function(name)
            return accepts(name)
        end)
        local file = dir and first_in(dir, accepts)
        return file and { kind = kind, path = file, dir = dir } or nil
    end

    local project = find(is_project, 'project')
    if prefer == 'project' then
        return project or find(is_solution, 'solution')
    end
    return find(is_solution, 'solution') or project
end

--- Whether the tests under `dir` run on Microsoft Testing Platform, which global.json
--- says. A global.json that cannot be read -- it may have comments, which JSON does
--- not -- is taken to say nothing, which is VSTest.
---@param dir string
---@return boolean
function M.uses_mtp(dir)
    local file = vim.fs.find('global.json', { upward = true, path = dir, type = 'file' })[1]
    if not file then
        return false
    end
    local text = table.concat(vim.fn.readfile(file), '\n'):gsub('^\239\187\191', '')
    local ok, decoded = pcall(vim.json.decode, text)
    local runner = ok and type(decoded) == 'table' and type(decoded.test) == 'table' and decoded.test.runner
    return type(runner) == 'string' and runner:lower() == 'microsoft.testing.platform'
end

----------------------------------------------------------------------------
-- Reading what dotnet printed
----------------------------------------------------------------------------

local function lines_of(text)
    local plain = text:gsub('\27%[[%d;?]*%a', ''):gsub('\r\n', '\n')
    return vim.split(plain, '\n', { plain = true })
end

local function absolute(path, cwd)
    if path == '' then
        return nil
    end
    if path:sub(1, 1) ~= '/' then
        path = vim.fs.joinpath(cwd or vim.fn.getcwd(), path)
    end
    path = vim.fs.normalize(path)
    return vim.uv.fs_stat(path) and path or nil
end

-- The project, or the solution, in brackets that MSBuild ends a message with.
local function without_project(message)
    local head, inside = message:match('^(.-)%s+%[([^%]]+)%]%s*$')
    if head and (is_project(inside) or is_solution(inside)) then
        return head
    end
    return message
end

--- Errors and warnings from a build's output, as quickfix entries, each once.
---@param output string
---@param cwd? string  what a relative path in the output is relative to
---@return { entries: table[], errors: integer, warnings: integer }
function M.parse_build(output, cwd)
    local seen, entries, errors, warnings = {}, {}, 0, 0
    for _, line in ipairs(lines_of(output)) do
        -- file(line,col): error CS0103: message [project]
        -- file(line,col,line,col) too, and
        -- file : error NU1101: message      and      MSBUILD : error MSB1003: message
        local path, row, col, kind, code, message =
            line:match('^(.-)%((%d+),(%d+)[%d,]*%): (%a+) ([^:%s]*): (.*)$')
        if not path then
            path, kind, code, message = line:match('^(.-) : (%a+) ([^:%s]*): (.*)$')
        end
        if path and (kind == 'error' or kind == 'warning') then
            message = without_project(message)
            local key = table.concat({ path, row or '', col or '', code, message }, '\0')
            if not seen[key] then
                seen[key] = true
                if kind == 'error' then
                    errors = errors + 1
                else
                    warnings = warnings + 1
                end
                table.insert(entries, {
                    filename = absolute(path, cwd),
                    lnum = tonumber(row) or 0,
                    col = tonumber(col) or 0,
                    type = kind == 'error' and 'E' or 'W',
                    text = code ~= '' and (code .. ': ' .. message) or message,
                    valid = 1,
                })
            end
        end
    end
    return { entries = entries, errors = errors, warnings = warnings }
end

-- "Lib.Tests.CalcTests.Add_one(a: 2, expected: 3)" -> "CalcTests.Add_one (a: 2, expected: 3)".
-- MSTest says only "Rows (2,4)", which has no class to keep.
local function short_name(name)
    local head, arguments = name:match('^([^%(]-)%s*(%(.*)$')
    if not head then
        head, arguments = name, ''
    end
    local parts = vim.split(head, '[%.%+]')
    local kept = #parts >= 2 and (parts[#parts - 1] .. '.' .. parts[#parts]) or head
    return kept .. (arguments ~= '' and (' ' .. arguments) or '')
end

-- A stack frame's file and line, if the file is one that is there.
local function user_frame(line)
    local path, row = line:match('^%s*at%s.-%sin%s+(/.-):line%s+(%d+)%s*$')
    if not path then
        path, row = line:match('^%s*at%s.-%sin%s+(/.-):(%d+)%s*$')
    end
    if path and vim.uv.fs_stat(path) then
        return path, tonumber(row)
    end
end

--- The failed tests in a test run's output, as quickfix entries, and the counts.
---@param output string
---@return { failures: table[], total: integer, failed: integer, passed: integer, skipped: integer, none_matched: boolean }
function M.parse_tests(output)
    local result = { failures = {}, total = 0, failed = 0, passed = 0, skipped = 0, none_matched = false }
    local current, mode, summary

    local function finish()
        if not current then
            return
        end
        local message = #current.message > 0 and table.concat(current.message, ' | ') or 'failed'
        message = message:gsub('%s+', ' ')
        if #message > 400 then
            message = message:sub(1, 400) .. '…'
        end
        table.insert(result.failures, {
            filename = current.path,
            lnum = current.row or 0,
            col = current.path and 1 or 0,
            type = 'E',
            text = ('%s: %s'):format(short_name(current.name), message),
            valid = 1,
        })
        current = nil
    end

    for _, line in ipairs(lines_of(output)) do
        local vstest = line:match('^%s+Failed%s+(.-)%s+%[[^%]]*%]%s*$')
        local mtp = line:match('^failed%s+(.-)%s+%([^)]*%)%s*$')
        local rows = line:match('Failed:%s*(%d+),%s*Passed:%s*(%d+),%s*Skipped:%s*(%d+),%s*Total:%s*(%d+)')

        if vstest or mtp then
            finish()
            summary = false
            -- VSTest says "Error Message:" before the message. MTP has no label:
            -- the message follows the header.
            current, mode = { name = vstest or mtp, message = {} }, mtp and 'message' or 'header'
        elseif rows then
            finish()
            local failed, passed, skipped, total = line:match('Failed:%s*(%d+),%s*Passed:%s*(%d+),%s*Skipped:%s*(%d+),%s*Total:%s*(%d+)')
            result.failed = result.failed + tonumber(failed)
            result.passed = result.passed + tonumber(passed)
            result.skipped = result.skipped + tonumber(skipped)
            result.total = result.total + tonumber(total)
        elseif line:match('^%s*Test run summary:') then
            finish()
            summary = true
        elseif summary and line:match('^%s+%a+:%s*%d+') then
            local label, count = line:match('^%s+(%a+):%s*(%d+)')
            count = tonumber(count)
            if label == 'total' then
                result.total = result.total + count
            elseif label == 'failed' then
                result.failed = result.failed + count
            elseif label == 'succeeded' then
                result.passed = result.passed + count
            elseif label == 'skipped' then
                result.skipped = result.skipped + count
            end
        elseif current then
            if line:match('^%s*Error Message:%s*$') then
                mode = 'message'
            elseif line:match('^%s*Stack Trace:%s*$') then
                mode = 'stack'
            elseif line:match('^%s*Standard [Oo]utput') or line:match('^%s*Standard [Ee]rror') or line:match('^%s*Error output') then
                mode = 'output'
            elseif mode == 'message' and line:match('^%s+from%s') then
                mode = 'after'
            elseif line:match('^%s*at%s') then
                mode = 'stack'
                if not current.path then
                    local path, row = user_frame(line)
                    if path then
                        current.path, current.row = path, row
                    end
                end
            elseif mode == 'message' and line:match('%S') then
                table.insert(current.message, vim.trim(line))
            end
        end
    end
    finish()

    table.sort(result.failures, function(a, b)
        if (a.filename or '') ~= (b.filename or '') then
            return (a.filename or '') < (b.filename or '')
        end
        return a.lnum < b.lnum
    end)

    result.none_matched = output:find('No test matches the given testcase filter', 1, true) ~= nil
        or output:find('No test is available', 1, true) ~= nil
        or output:find('Zero tests ran', 1, true) ~= nil
    return result
end

----------------------------------------------------------------------------
-- Which tests
----------------------------------------------------------------------------

local CLASSES = {
    class_declaration = true,
    record_declaration = true,
    struct_declaration = true,
    record_struct_declaration = true,
}

local function name_of(node, buf)
    local field = node:field('name')[1]
    return field and vim.treesitter.get_node_text(field, buf) or nil
end

-- A block namespace is an ancestor. A file-scoped one (`namespace A.B;`) is not: it
-- is a sibling, before the classes, which belong to it by coming after.
local function namespace_of(node, buf, root)
    local parts = {}
    local ancestor = node:parent()
    while ancestor do
        if ancestor:type() == 'namespace_declaration' then
            table.insert(parts, 1, name_of(ancestor, buf))
        end
        ancestor = ancestor:parent()
    end
    for child in root:iter_children() do
        if child:type() == 'file_scoped_namespace_declaration' then
            table.insert(parts, 1, name_of(child, buf))
            break
        end
    end
    return table.concat(parts, '.')
end

-- Outer+Inner, as the runners name a nested class.
local function class_of(node, buf)
    local names = {}
    local current = node
    while current do
        if CLASSES[current:type()] then
            table.insert(names, 1, name_of(current, buf))
        end
        current = current:parent()
    end
    return table.concat(names, '+')
end

local function qualified(namespace, name)
    return namespace ~= '' and (namespace .. '.' .. name) or name
end

-- A filter value has characters of its own: \ ( ) & | = ! ~.
local function escape(text)
    return (text:gsub('([\\()&|=!~])', '\\%1'))
end

local function ancestor_of_type(node, wanted)
    while node and not wanted(node:type()) do
        node = node:parent()
    end
    return node
end

local function syntax_root(buf)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'c_sharp')
    if not ok or not parser then
        return nil
    end
    local trees = parser:parse()
    return trees and trees[1] and trees[1]:root() or nil
end

--- The filter that selects the tests at the cursor (`nearest`) or in the file.
---@param buf integer
---@param scope 'nearest'|'file'
---@return string? filter
---@return string? label  what it selects, for the title
---@return string? err
function M.filter_for(buf, scope)
    if vim.bo[buf].filetype ~= 'cs' then
        return nil, nil, 'This is not a C# file'
    end
    local root = syntax_root(buf)
    if not root then
        return nil, nil, 'No syntax tree for this file: the c_sharp parser is needed to pick tests by name'
    end

    if scope == 'file' then
        local filters, names = {}, {}
        local function walk(node)
            if CLASSES[node:type()] then
                local fqn = qualified(namespace_of(node, buf, root), class_of(node, buf))
                table.insert(filters, 'FullyQualifiedName~' .. escape(fqn) .. '.')
                table.insert(names, fqn)
            end
            for child in node:iter_children() do
                walk(child)
            end
        end
        walk(root)
        if #filters == 0 then
            return nil, nil, 'No class in this file'
        end
        return table.concat(filters, '|'), vim.fs.basename(vim.api.nvim_buf_get_name(buf)), nil
    end

    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local node = vim.treesitter.get_node({ bufnr = buf, pos = { row - 1, col } })
    local method = node and ancestor_of_type(node, function(kind)
        return kind == 'method_declaration'
    end)
    if method then
        local class = ancestor_of_type(method, function(kind)
            return CLASSES[kind] == true
        end)
        if class then
            local fqn = qualified(namespace_of(method, buf, root), class_of(class, buf)) .. '.' .. name_of(method, buf)
            return ('FullyQualifiedName=%s|FullyQualifiedName~%s\\('):format(escape(fqn), escape(fqn)), fqn, nil
        end
    end
    -- Not in a method: the class the cursor is in is the nearest thing there is.
    local class = node and ancestor_of_type(node, function(kind)
        return CLASSES[kind] == true
    end)
    if class then
        local fqn = qualified(namespace_of(class, buf, root), class_of(class, buf))
        return 'FullyQualifiedName~' .. escape(fqn) .. '.', fqn, nil
    end
    return nil, nil, 'No test method or class at the cursor'
end

----------------------------------------------------------------------------
-- Running a command and showing what came of it
----------------------------------------------------------------------------

local function set_job(name)
    vim.g.ide_job = name
    pcall(vim.cmd.redrawstatus)
end

--- Stop the build or test run that is going, and forget it.
function M.cancel()
    if not state.job then
        return notify('No build or test run is going')
    end
    state.generation = state.generation + 1
    pcall(function()
        state.job:kill(15)
    end)
    state.job = nil
    set_job(nil)
    notify('Stopped')
end

-- Run a command in the background and call `done` with how it went. A command
-- started while one is going replaces it: what was wanted is the result of the
-- code as it is now, and the generation says that what comes back from the old one
-- is not that.
local function start(name, cmd, cwd, done)
    if state.job then
        state.generation = state.generation + 1
        pcall(function()
            state.job:kill(15)
        end)
    end
    state.generation = state.generation + 1
    local generation = state.generation
    local began = vim.uv.hrtime()
    local out, err = {}, {}

    set_job(name)
    local ok, handle = pcall(vim.system, cmd, {
        cwd = cwd,
        text = true,
        env = { DOTNET_NOLOGO = '1', DOTNET_CLI_UI_LANGUAGE = 'en' },
        stdout = function(_, data)
            if data then
                table.insert(out, data)
            end
        end,
        stderr = function(_, data)
            if data then
                table.insert(err, data)
            end
        end,
    }, function(result)
        vim.schedule(function()
            if generation ~= state.generation then
                return
            end
            state.job = nil
            set_job(nil)
            state.output = table.concat(out) .. table.concat(err)
            done({
                code = result.code,
                output = state.output,
                seconds = (vim.uv.hrtime() - began) / 1e9,
            })
        end)
    end)
    if not ok then
        set_job(nil)
        return notify(('dotnet could not be started: %s'):format(tostring(handle)), ERROR)
    end
    state.job = handle
end

--- The raw output of the last build or test run, in a window of its own.
function M.show_output()
    if state.output == '' then
        return notify('No build or test output yet')
    end
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        pcall(vim.api.nvim_buf_delete, state.output_buf, { force = true })
    end
    vim.cmd('botright 16split')
    local buf = vim.api.nvim_create_buf(false, true)
    state.output_buf = buf
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_of(state.output))
    vim.bo[buf].modifiable = false
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, desc = 'Close the output' })
end

-- The list for `kind` ('build' or 'test'): updated where it is if it is still in
-- the stack, else put at the end of it. Plain setqflist, not vim.fn's: ide.lists
-- wraps that to put test files last, and these are in the order the tool found
-- them, which is the order of the build or of the run.
local function put_list(kind, title, entries)
    local id = state.lists[kind]
    local nr = id and vim.fn.getqflist({ id = id, nr = 0 }).nr or 0
    if nr > 0 then
        vim.call('setqflist', {}, 'r', { id = id, title = title, items = entries })
        return nr
    end
    vim.call('setqflist', {}, ' ', { title = title, items = entries, nr = '$' })
    local made = vim.fn.getqflist({ nr = '$', id = 0 })
    state.lists[kind] = made.id
    return made.nr
end

-- Show it, without taking focus from where the work is: the result of something
-- that took a while arrives when you are in the middle of something else.
local function reveal(nr)
    local from = vim.api.nvim_get_current_win()
    vim.cmd(nr .. 'chistory')
    vim.cmd('botright copen')
    if vim.api.nvim_win_is_valid(from) then
        vim.api.nvim_set_current_win(from)
    end
end

-- A list that holds the last result and has nothing in it now: emptied, and its
-- window closed if that is what it was showing.
local function clear_list(kind, title)
    local id = state.lists[kind]
    if not (id and vim.fn.getqflist({ id = id, nr = 0 }).nr > 0) then
        return
    end
    vim.call('setqflist', {}, 'r', { id = id, title = title, items = {} })
    local shown = vim.fn.getqflist({ winid = 0, id = 0 })
    if shown.winid ~= 0 and shown.id == id then
        vim.cmd.cclose()
    end
end

local function plural(count, word)
    return ('%d %s%s'):format(count, word, count == 1 and '' or 's')
end

local function seconds(value)
    return ('%.1f s'):format(value)
end

----------------------------------------------------------------------------
-- Build
----------------------------------------------------------------------------

--- Build the solution above the current file, or its project.
---
--- `after(ok)` is called when the build is over, with whether it worked: what
--- debugging waits for. It is not called for a build that was replaced by another
--- command or stopped, which says nothing either way.
---@param scope? 'solution'|'project'
---@param after? fun(ok: boolean)
function M.build(scope, after)
    local target = M.target(vim.api.nvim_buf_get_name(0), scope == 'project' and 'project' or 'solution')
    if not target then
        notify('No solution or project above this file', WARN)
        return after and after(false)
    end
    local name = vim.fs.basename(target.path)
    local function over(ok)
        if after then
            after(ok)
        end
    end
    start('Build', { 'dotnet', 'build', target.path, '-nologo', '-v', 'q' }, target.dir, function(result)
        local parsed = M.parse_build(result.output, target.dir)
        local title = ('Build %s: %s, %s'):format(name, plural(parsed.errors, 'error'), plural(parsed.warnings, 'warning'))

        if result.code ~= 0 and #parsed.entries == 0 then
            M.show_output()
            notify(('Build of %s failed (exit %d); the output is open'):format(name, result.code), ERROR)
            return over(false)
        end

        if parsed.errors > 0 then
            reveal(put_list('build', title, parsed.entries))
            notify(('Build FAILED: %s, %s (%s)'):format(plural(parsed.errors, 'error'), plural(parsed.warnings, 'warning'), seconds(result.seconds)), ERROR)
            return over(false)
        end

        if parsed.warnings > 0 then
            put_list('build', title, parsed.entries)
            notify(('Build succeeded: %s (%s); <leader>fq has them'):format(plural(parsed.warnings, 'warning'), seconds(result.seconds)))
            return over(true)
        end
        clear_list('build', title)
        notify(('Build succeeded (%s)'):format(seconds(result.seconds)))
        over(true)
    end)
end

----------------------------------------------------------------------------
-- Test
----------------------------------------------------------------------------

--- The command that runs the tests of `target`, for the runner its directory uses.
---@param target { kind: string, path: string, dir: string }
---@param filter? string
---@return string[]
function M.test_command(target, filter)
    local cmd = { 'dotnet', 'test' }
    if M.uses_mtp(target.dir) then
        vim.list_extend(cmd, { target.kind == 'solution' and '--solution' or '--project', target.path })
    else
        table.insert(cmd, target.path)
    end
    if filter then
        vim.list_extend(cmd, { '--filter', filter })
    end
    return cmd
end

local function run_tests(target, filter, label)
    start('Test', M.test_command(target, filter), target.dir, function(result)
        local parsed = M.parse_tests(result.output)
        local build = M.parse_build(result.output, target.dir)
        local errors = vim.tbl_filter(function(entry)
            return entry.type == 'E'
        end, build.entries)

        if #errors > 0 then
            reveal(put_list('test', ('Test: build failed, %s'):format(plural(#errors, 'error')), errors))
            return notify(('Tests not run, the build failed: %s'):format(plural(#errors, 'error')), ERROR)
        end

        if #parsed.failures > 0 then
            reveal(put_list('test', ('Tests (%s): %d failed of %d'):format(label, parsed.failed, parsed.total), parsed.failures))
            return notify(('Tests: %d failed, %d passed (%s)'):format(parsed.failed, parsed.passed, seconds(result.seconds)), WARN)
        end

        if parsed.failed > 0 then
            -- It said some failed and no block was recognised: it is not shown as
            -- though it were fine, and the reason is in what was printed.
            M.show_output()
            return notify(('Tests: %d failed, but they could not be listed; the output is open'):format(parsed.failed), ERROR)
        end

        if parsed.none_matched or (parsed.total == 0 and result.code == 0) then
            return notify(('No tests matched (%s)'):format(label), WARN)
        end

        if result.code ~= 0 then
            M.show_output()
            return notify(('dotnet test failed (exit %d); the output is open'):format(result.code), ERROR)
        end

        clear_list('test', ('Tests (%s): passed'):format(label))
        notify(('Tests passed: %d (%s, %s)'):format(parsed.passed, label, seconds(result.seconds)))
    end)
end

--- Run tests: all of them, or those in this file, or the one at the cursor, or
--- whatever was run last.
---@param scope? 'all'|'file'|'nearest'|'last'
function M.test(scope)
    scope = scope or 'all'
    if scope == 'last' then
        if not state.last_test then
            return notify('No test run to repeat yet', WARN)
        end
        return run_tests(state.last_test.target, state.last_test.filter, state.last_test.label)
    end
    if scope ~= 'all' and scope ~= 'file' and scope ~= 'nearest' then
        return notify('Test: all, file, nearest or last', WARN)
    end

    local path = vim.api.nvim_buf_get_name(0)
    local target = M.target(path, scope == 'all' and 'solution' or 'project')
    if not target then
        return notify('No solution or project above this file', WARN)
    end

    local filter, label = nil, 'all tests'
    if scope ~= 'all' then
        local err
        filter, label, err = M.filter_for(0, scope)
        if not filter then
            return notify(err, WARN)
        end
    end
    state.last_test = { target = target, filter = filter, label = label }
    run_tests(target, filter, label)
end

----------------------------------------------------------------------------
-- Run and watch
----------------------------------------------------------------------------

-- A terminal window for a command that goes on running. One for each name:
-- running again stops the old one and takes over its window.
local function terminal(slot, cmd, cwd)
    local origin = vim.api.nvim_get_current_win()
    local previous = state.terminals[slot]
    local win
    if previous then
        pcall(vim.fn.jobstop, previous.job)
        if vim.api.nvim_buf_is_valid(previous.buf) then
            win = vim.fn.win_findbuf(previous.buf)[1]
        end
    end

    local buf = vim.api.nvim_create_buf(false, false)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, buf)
    else
        vim.cmd('botright 14split')
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    end

    local job
    vim.api.nvim_win_call(win, function()
        job = vim.fn.jobstart(cmd, { term = true, cwd = cwd })
        vim.cmd('normal! G')
    end)
    if previous and previous.buf ~= buf and vim.api.nvim_buf_is_valid(previous.buf) then
        pcall(vim.api.nvim_buf_delete, previous.buf, { force = true })
    end
    state.terminals[slot] = { buf = buf, job = job }
    if vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    return buf
end

local function project_here()
    local target = M.target(vim.api.nvim_buf_get_name(0), 'project')
    if not target or target.kind ~= 'project' then
        notify('No project above this file', WARN)
        return nil
    end
    return target
end

--- Words as a shell would split them: on spaces, with single or double quotes
--- keeping their contents together and a backslash taking the next character as it
--- is. A command's own `<f-args>` splits on spaces and nothing else, so the
--- `"John Smith"` in `:Run --name "John Smith"` would have reached the program as
--- two arguments. An unclosed quote runs to the end.
---@param text string
---@return string[]
function M.split_args(text)
    local args, current, quote, started = {}, {}, nil, false
    local i = 1
    while i <= #text do
        local char = text:sub(i, i)
        if quote then
            if char == quote then
                quote = nil
            elseif char == '\\' and quote == '"' and text:sub(i + 1, i + 1):match('["\\]') then
                i = i + 1
                table.insert(current, text:sub(i, i))
            else
                table.insert(current, char)
            end
        elseif char == '"' or char == "'" then
            quote, started = char, true
        elseif char == '\\' and i < #text then
            i = i + 1
            table.insert(current, text:sub(i, i))
            started = true
        elseif char:match('%s') then
            if started then
                table.insert(args, table.concat(current))
                current, started = {}, false
            end
        else
            table.insert(current, char)
            started = true
        end
        i = i + 1
    end
    if started then
        table.insert(args, table.concat(current))
    end
    return args
end

--- Run the project of this file, in a terminal below. `args` go to the program.
---@param args? string[]
function M.run(args)
    local target = project_here()
    if not target then
        return
    end
    local cmd = { 'dotnet', 'run', '--project', target.path }
    if args and #args > 0 then
        table.insert(cmd, '--')
        vim.list_extend(cmd, args)
    end
    return terminal('run', cmd, target.dir)
end

--- Run the project of this file under `dotnet watch`, which restarts it when the
--- code changes. `verb` is run (the default), test or build.
---@param verb? string
function M.watch(verb)
    local target = project_here()
    if not target then
        return
    end
    return terminal('watch', { 'dotnet', 'watch', '--project', target.path, verb ~= '' and verb or 'run' }, target.dir)
end

----------------------------------------------------------------------------
-- Leaving
----------------------------------------------------------------------------

--- Stop what is running and close the terminals. For the end of the editor, and for
--- the tests.
function M.shutdown()
    if state.job then
        pcall(function()
            state.job:kill(15)
        end)
        state.job = nil
        set_job(nil)
    end
    for slot, term in pairs(state.terminals) do
        pcall(vim.fn.jobstop, term.job)
        if vim.api.nvim_buf_is_valid(term.buf) then
            for _, win in ipairs(vim.fn.win_findbuf(term.buf)) do
                pcall(vim.api.nvim_win_close, win, true)
            end
            pcall(vim.api.nvim_buf_delete, term.buf, { force = true })
        end
        state.terminals[slot] = nil
    end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = M.shutdown,
})

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

local function completing(words)
    return function(lead)
        return vim.tbl_filter(function(word)
            return vim.startswith(word, lead)
        end, words)
    end
end

registry.command('Build', function(opts)
    if opts.bang then
        return M.cancel()
    end
    M.build(opts.args ~= '' and opts.args or nil)
end, {
    nargs = '?',
    bang = true,
    desc = 'Build the solution above this file (or its project); errors go to a quickfix list; ! stops a build that is going',
    complete = completing({ 'solution', 'project' }),
})

registry.command('Test', function(opts)
    if opts.bang then
        return M.cancel()
    end
    M.test(opts.args ~= '' and opts.args or nil)
end, {
    nargs = '?',
    bang = true,
    desc = 'Run tests: all, file, nearest or last; failures go to a quickfix list; ! stops a run that is going',
    complete = completing({ 'all', 'file', 'nearest', 'last' }),
})

registry.command('Run', function(opts)
    M.run(M.split_args(opts.args))
end, {
    nargs = '*',
    desc = 'Run the project of this file in a terminal below; the arguments go to the program, quoted as in a shell',
})

registry.command('Watch', function(opts)
    M.watch(opts.args)
end, {
    nargs = '?',
    desc = 'Run the project of this file under dotnet watch: run (the default), test or build',
    complete = completing({ 'run', 'test', 'build' }),
})

registry.command('DotnetOutput', M.show_output, {
    desc = 'Show everything the last build or test run printed',
})

return M
