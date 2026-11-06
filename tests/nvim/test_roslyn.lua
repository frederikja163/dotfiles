-- env: full
-- The real roslyn-language-server, on a solution this test makes. Everything
-- else in tests/nvim talks to a fake server, which proves what this config does
-- with an answer and nothing about whether the answer is the shape Roslyn gives.
-- This is where that is found out: library code, generated code, `///`, unused
-- usings, the hierarchies, the references lens, completion
-- with an import, and a file changed behind the editor's back.
--
-- It is slow -- the server has to start and load a project -- and needs .NET and
-- the roslyn-language-server tool, so it says SKIPPED, loudly, where they are
-- not installed, as the other tests that depend on a program do.
--
-- Autosave and format-on-write are off for the whole run: both write buffers back
-- and the formatter would move the lines this test counts.

vim.env.NVIM_TEST_BUDGET = '420'
local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

if vim.fn.executable('roslyn-language-server') == 0 or vim.fn.executable('dotnet') == 0 then
    print('  SKIPPED: roslyn-language-server and dotnet are needed (install.sh installs the tool; ~/.dotnet/tools on PATH)')
    T.finish()
end

vim.o.showmode = false
vim.g.ide_autosave = false
vim.g.ide_format = false

----------------------------------------------------------------------------
-- A solution to talk about
----------------------------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/Lib', 'p')
root = vim.uv.fs_realpath(root)

local function write(path, lines)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines, full)
    return full
end

local function run(cmd)
    local result = vim.system(cmd, { cwd = root, text = true }):wait()
    assert(result.code == 0, table.concat(cmd, ' ') .. ': ' .. (result.stderr or '') .. (result.stdout or ''))
end

write('Lib/Lib.csproj', {
    '<Project Sdk="Microsoft.NET.Sdk">',
    '  <PropertyGroup>',
    '    <TargetFramework>net10.0</TargetFramework>',
    '    <ImplicitUsings>disable</ImplicitUsings>',
    '    <Nullable>enable</Nullable>',
    '  </PropertyGroup>',
    '</Project>',
})
local class1 = write('Lib/Class1.cs', {
    'using System;',
    'using System.Linq;',
    '',
    'namespace Lib;',
    '',
    'public interface IShape',
    '{',
    '    double Area();',
    '}',
    '',
    'public class Square : IShape',
    '{',
    '    public double Side { get; set; }',
    '',
    '    public double Area() => Side * Side;',
    '',
    '    public double Grow(double by, int times)',
    '    {',
    '        Side = Side + by;',
    '        return Side;',
    '    }',
    '}',
    '',
    'public class Program',
    '{',
    '    public static void Main()',
    '    {',
    '        var s = new Square { Side = 2 };',
    '        Console.WriteLine(s.Area());',
    '    }',
    '}',
})
local other = write('Lib/Other.cs', {
    'namespace Lib;', '', 'public static class Other', '{', '    public static int Foo() => 1;', '}',
})
local user = write('Lib/User.cs', {
    'namespace Lib;', '', 'public class User', '{', '    public int X = Other.Foo();', '}',
})
local rx = write('Lib/Rx.cs', {
    'using System.Text.RegularExpressions;',
    '',
    'namespace Lib;',
    '',
    'public static partial class Rx',
    '{',
    '    [GeneratedRegex("a+b")]',
    '    public static partial Regex Ab();',
    '}',
    '',
    'public class UseRx',
    '{',
    '    public bool Check(string s) => Rx.Ab().IsMatch(s);',
    '}',
})
local scratch = write('Lib/Scratch.cs', {
    'using System;',
    '',
    'namespace Lib;',
    '',
    'public class Scratch',
    '{',
    '    public void Go()',
    '    {',
    '        ',
    '    }',
    '}',
})
run({ 'dotnet', 'new', 'sln', '-n', 'Demo', '--format', 'sln' })
run({ 'dotnet', 'sln', 'Demo.sln', 'add', 'Lib/Lib.csproj' })
run({ 'dotnet', 'restore', 'Demo.sln', '-nologo', '-v', 'q' })
vim.cmd.cd(root)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end

-- (row, col) of the first place the current buffer has `text`, col 1-based.
local function find(text)
    for row, line in ipairs(lines()) do
        local col = line:find(text, 1, true)
        if col then
            return row, col
        end
    end
end

local function put_cursor_on(text, offset)
    local row, col = find(text)
    assert(row, 'not in the buffer: ' .. text)
    vim.api.nvim_win_set_cursor(0, { row, col - 1 + (offset or 0) })
end

local function server()
    return vim.lsp.get_clients({ name = 'roslyn_ls' })[1]
end

local function request(client, method, params, buf, timeout)
    local done, result, err = false, nil, nil
    client:request(method, params, function(e, r) err, result, done = e, r, true end, buf)
    T.until_true(timeout or 30000, function() return done end)
    return result, err
end

local function position(client)
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
end

local function attached(buf)
    return #vim.lsp.get_clients({ bufnr = buf, name = 'roslyn_ls' })
end

local function open(file)
    vim.cmd('edit ' .. file)
    T.until_true(15000, function() return attached(vim.api.nvim_get_current_buf()) > 0 end)
end

local function name_of() return vim.api.nvim_buf_get_name(0) end

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level }) end

T.async(function()
    ------------------------------------------------------------------------
    T.section('the server starts and loads the solution')
    T.check('no module failed', vim.g.ide_failed, {})
    local t0 = vim.uv.hrtime()
    vim.cmd('edit ' .. user)
    local started = T.until_true(120000, function() return server() ~= nil end)
    T.ok('roslyn_ls started for a file in the solution', started)
    local client = server()
    T.check('rooted at the solution', client.config.root_dir, root)
    put_cursor_on('Foo')
    local loaded = T.until_true(120000, function()
        client = server()
        if not client then return false end
        return request(client, 'textDocument/hover', position(client), vim.api.nvim_get_current_buf(), 5000) ~= nil
    end)
    T.ok(('the project loaded (%.1fs)'):format((vim.uv.hrtime() - t0) / 1e9), loaded)
    T.sleep(1500)
    client = server()

    ------------------------------------------------------------------------
    T.section('what it can do')
    local caps = client.server_capabilities
    for _, name in ipairs({
        'definitionProvider', 'implementationProvider', 'referencesProvider', 'typeDefinitionProvider',
        'callHierarchyProvider', 'typeHierarchyProvider', 'documentHighlightProvider', 'codeActionProvider',
        'codeLensProvider', 'signatureHelpProvider', 'completionProvider', 'inlayHintProvider', 'renameProvider',
    }) do
        T.ok(name, caps[name] ~= nil and caps[name] ~= false)
    end
    T.ok('and the ///', caps._vs_onAutoInsertProvider ~= nil)
    T.ok('completion triggers on punctuation, and not on letters: those are asked for as invocations', vim.tbl_contains(caps.completionProvider.triggerCharacters, '.'))

    ------------------------------------------------------------------------
    T.section('library code: go to definition, read it, follow it')
    open(class1)
    put_cursor_on('WriteLine')
    vim.api.nvim_feedkeys('gd', 'x', false)
    T.ok('gd went into the framework', T.until_true(30000, function() return name_of():find('MetadataAsSource', 1, true) ~= nil end), name_of())
    local library = vim.api.nvim_get_current_buf()
    T.ok('the decompiled text is there', #lines() > 100, #lines())
    T.check('it is C#', vim.bo.filetype, 'cs')
    T.check('read-only', { vim.bo.modifiable, vim.bo.readonly }, { false, true })
    T.ok('and the server attached, which it did not before', T.until_true(15000, function() return attached(library) > 0 end))
    -- The overload the solution calls: Area() is a double. Usages of another one
    -- would be none, and say nothing about whether the search works from here.
    local row = find('public static void WriteLine(double')
    T.ok('it has Console.WriteLine(double) in it', row ~= nil)
    put_cursor_on('public static void WriteLine(double', 24)
    local hover = request(server(), 'textDocument/hover', position(server()), library, 30000)
    T.ok('hover works inside library code', hover ~= nil and vim.inspect(hover):find('WriteLine', 1, true) ~= nil, hover)
    local refs = request(server(), 'textDocument/references', vim.tbl_extend('force', position(server()), { context = { includeDeclaration = true } }), library, 30000)
    local in_solution = false
    for _, ref in ipairs(refs or {}) do
        in_solution = in_solution or vim.uri_to_fname(ref.uri) == class1
    end
    T.ok('and so does find usages: the call in the solution is found from here', in_solution, refs)
    vim.cmd('edit ' .. class1)

    ------------------------------------------------------------------------
    T.section('generated code: go to implementation of a partial method')
    open(rx)
    put_cursor_on('Rx.Ab()', 3)
    vim.api.nvim_feedkeys('gri', 'x', false)
    -- Waits for the text, not only for the name. Loading the buffer asks the server
    -- for it and waits for the answer, and waiting runs the event loop; during it
    -- the buffer being loaded is the current one, already with its name and with
    -- nothing in it, which is a moment this test can be resumed in.
    T.ok('gri went to a document that is not a file, and it has its text', T.until_true(30000, function()
        return name_of():find('^roslyn%-source%-generated://') ~= nil and #lines() > 10
    end), { name_of(), #lines() })
    local generated = vim.api.nvim_get_current_buf()
    T.ok('with the generator\'s text', table.concat(lines(), '\n'):find('Regex', 1, true) ~= nil and #lines() > 10, #lines())
    T.check('not a file, not editable', { vim.bo.buftype, vim.bo.modifiable }, { 'nofile', false })
    T.check('C#', vim.bo.filetype, 'cs')
    T.ok('with the server attached', attached(generated) > 0)
    T.ok('and the cursor is on the method it implements', vim.api.nvim_win_get_cursor(0)[1] > 1)
    vim.cmd('edit ' .. class1)
    -- The generated document stays open, attached, in the background from here on,
    -- on purpose: see the callers check below.

    ------------------------------------------------------------------------
    T.section(':Usings')
    open(class1)
    T.check('the file starts with two usings', { lines()[1], lines()[2] }, { 'using System;', 'using System.Linq;' })
    T.sleep(1500)
    vim.cmd('Usings')
    T.ok('the one nothing uses is removed', T.until_true(30000, function() return lines()[2] == '' end), lines())
    T.check('and the one that is used is kept', lines()[1], 'using System;')
    vim.cmd('edit! ' .. class1)
    T.until_true(15000, function() return attached(vim.api.nvim_get_current_buf()) > 0 end)

    ------------------------------------------------------------------------
    T.section('/// above a member')
    open(class1)
    local grow = find('public double Grow')
    vim.api.nvim_buf_set_lines(0, grow - 1, grow - 1, false, { '    ' })
    vim.api.nvim_win_set_cursor(0, { grow, 4 })
    T.sleep(1200)
    T.keys('A', 100)
    T.keys('///', 300)
    T.ok('the stub was written', T.until_true(30000, function() return (lines()[grow] or ''):find('<summary>', 1, true) ~= nil end), lines())
    local text = table.concat(lines(), '\n')
    T.ok('a parameter for each of the two', text:find('<param name="by"></param>', 1, true) ~= nil and text:find('<param name="times"></param>', 1, true) ~= nil)
    T.ok('and what it returns', text:find('<returns></returns>', 1, true) ~= nil)
    T.check('the cursor is inside the summary, in Insert mode', { vim.api.nvim_win_get_cursor(0)[1], vim.fn.mode() }, { grow + 1, 'i' })
    T.keys('Grows it')
    T.check('and typing goes there', lines()[grow + 1], '    /// Grows it')
    T.keys('<Esc>')
    vim.cmd('edit! ' .. class1)
    T.until_true(15000, function() return attached(vim.api.nvim_get_current_buf()) > 0 end)

    ------------------------------------------------------------------------
    T.section('the hierarchies')
    open(class1)
    T.sleep(1000)
    put_cursor_on('class Square', 8)
    vim.api.nvim_feedkeys('grb', 'x', false)
    T.ok('base types: a single one is gone to', T.until_true(30000, function()
        return vim.api.nvim_win_get_cursor(0)[1] == 6
    end), vim.api.nvim_win_get_cursor(0))
    T.ok('it is the interface', lines()[6]:find('IShape', 1, true) ~= nil, lines()[6])

    -- Also the check that an open generated document does no harm. It is still open
    -- and attached (above). With its text differing from the generator's by a
    -- trailing newline -- as it was sent once -- this returned nothing for every
    -- method in the solution, not only for the generated one: ide.csharp, put_text.
    put_cursor_on('Area() => Side', 1)
    notified = {}
    vim.api.nvim_feedkeys('grc', 'x', false)
    T.ok('callers: the one call is gone to', T.until_true(30000, function()
        return (lines()[vim.api.nvim_win_get_cursor(0)[1]] or ''):find('s.Area()', 1, true) ~= nil
    end), { cursor = vim.api.nvim_win_get_cursor(0), said = notified })

    put_cursor_on('interface IShape', 12)
    local before = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_feedkeys('gri', 'x', false)
    T.ok('implementations: the class that implements it', T.until_true(30000, function()
        return vim.api.nvim_win_get_cursor(0)[1] ~= before
    end))
    T.ok('is Square', lines()[vim.api.nvim_win_get_cursor(0)[1]]:find('Square', 1, true) ~= nil, lines()[vim.api.nvim_win_get_cursor(0)[1]])

    ------------------------------------------------------------------------
    T.section('the usages highlight tells reads from writes')
    put_cursor_on('return Side', 8)
    local highlights = request(server(), 'textDocument/documentHighlight', position(server()), vim.api.nvim_get_current_buf())
    local kinds = {}
    for _, h in ipairs(highlights or {}) do kinds[h.kind or 0] = true end
    T.ok('Roslyn reports both kinds: reads', kinds[2] == true)
    T.ok('and writes', kinds[3] == true)

    ------------------------------------------------------------------------
    T.section('the references lens')
    local lenses = request(server(), 'textDocument/codeLens', { textDocument = { uri = vim.uri_from_bufnr(0) } }, vim.api.nvim_get_current_buf())
    T.ok('there are lenses', lenses ~= nil and #lenses > 0, lenses and #lenses)
    local area_row = find('public double Area() => Side')
    local target
    for _, lens in ipairs(lenses or {}) do
        if lens.range.start.line == area_row - 1 then target = lens end
    end
    T.ok('one is on Area', target ~= nil)
    local resolved = request(server(), 'codeLens/resolve', target, vim.api.nvim_get_current_buf())
    T.check('resolved to the command this config handles', resolved.command.command, 'roslyn.client.peekReferences')
    T.ok('with a count', resolved.command.title:find('reference', 1, true) ~= nil, resolved.command.title)
    server():exec_cmd(resolved.command, { bufnr = vim.api.nvim_get_current_buf() })
    T.ok('running it goes to the one reference', T.until_true(30000, function()
        return (lines()[vim.api.nvim_win_get_cursor(0)[1]] or ''):find('s.Area()', 1, true) ~= nil
    end), vim.api.nvim_win_get_cursor(0))

    ------------------------------------------------------------------------
    T.section('completion, with the menu and the documentation beside it')
    open(scratch)
    T.sleep(1500)
    vim.api.nvim_win_set_cursor(0, { 9, 8 })
    T.keys('A', 100)
    T.keys('Console.Wri', 500)
    T.ok('a menu opens', T.until_true(30000, function() return vim.fn.pumvisible() == 1 end))
    local words = vim.tbl_map(function(item) return item.word end, vim.fn.complete_info({ 'items' }).items)
    T.ok('with WriteLine in it', vim.tbl_contains(words, 'WriteLine'), words)
    local kinds_shown = vim.tbl_map(function(item) return item.kind end, vim.fn.complete_info({ 'items' }).items)
    T.ok('each with an icon and a kind', kinds_shown[1] ~= nil and kinds_shown[1]:find('Method', 1, true) ~= nil, kinds_shown[1])
    T.ok('the documentation window opens for the highlighted one', T.until_true(30000, function()
        local info = vim.fn.complete_info({ 'selected' })
        return info.preview_winid ~= nil and info.preview_winid ~= 0 and vim.api.nvim_win_is_valid(info.preview_winid)
    end))
    for _ = 1, 10 do
        local items = vim.fn.complete_info({ 'items', 'selected' })
        if items.selected >= 0 and items.items[items.selected + 1].word == 'WriteLine' then break end
        T.keys('<Tab>', 80)
    end
    T.keys('<CR>', 300)
    T.check('Enter takes it', lines()[9], '        Console.WriteLine')
    T.keys('(', 400)
    T.keys('<Esc>')
    T.keys('<Esc>')

    vim.api.nvim_buf_set_lines(0, 8, 9, false, { '        ' })
    vim.api.nvim_win_set_cursor(0, { 9, 8 })
    T.keys('A', 100)
    T.keys('StringBui', 500)
    T.ok('a type from a namespace that is not imported is offered', T.until_true(30000, function() return vim.fn.pumvisible() == 1 end))
    for _ = 1, 10 do
        local items = vim.fn.complete_info({ 'items', 'selected' })
        if items.selected >= 0 and items.items[items.selected + 1].word == 'StringBuilder' then break end
        T.keys('<Tab>', 80)
    end
    T.keys('<CR>', 300)
    T.ok('and taking it adds the using', T.until_true(30000, function()
        return table.concat(lines(), '\n'):find('using System.Text;', 1, true) ~= nil
    end), lines())
    T.ok('with the type written where it was', table.concat(lines(), '\n'):find('StringBuilder', 1, true) ~= nil)
    T.keys('<Esc>')
    T.keys('<Esc>')

    ------------------------------------------------------------------------
    T.section('a file changed behind the editor\'s back')
    open(user)
    T.sleep(1000)
    local diagnostics = request(server(), 'textDocument/diagnostic', { textDocument = { uri = vim.uri_from_bufnr(0) } }, vim.api.nvim_get_current_buf())
    T.check('no errors to begin with', diagnostics and #(diagnostics.items or {}), 0)
    vim.fn.writefile({ 'namespace Lib;', '', 'public static class Other', '{', '    public static int Bar() => 1;', '}' }, other)
    local noticed = T.until_true(30000, function()
        local report = request(server(), 'textDocument/diagnostic', { textDocument = { uri = vim.uri_from_bufnr(0) } }, vim.api.nvim_get_current_buf())
        for _, d in ipairs(report and report.items or {}) do
            if d.message:find("'Other' does not contain a definition for 'Foo'", 1, true) then return true end
        end
        return false
    end)
    T.ok('the server saw the change to a file that is not open, with no help from nvim', noticed)

    ------------------------------------------------------------------------
    vim.notify = real_notify
    for _, c in ipairs(vim.lsp.get_clients()) do c:stop(true) end
    T.until_true(10000, function() return #vim.lsp.get_clients() == 0 end)
end)
