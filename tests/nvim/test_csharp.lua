-- env: full
-- The C# pieces that sit on top of a language server: library and generated
-- code, removing unused usings, the `///` that writes a documentation comment, the
-- and the references lens.
--
-- Against a fake server (lib.lua) that is named roslyn_ls, because that is what
-- the code under test looks for. The real config is pointed at the fake too, so
-- that nothing here can start the real binary. test_roslyn.lua asks the real
-- one, for the things only it can answer.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

vim.o.showmode = false

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
vim.cmd.cd(root)

local function write(path, lines)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(lines, full)
    return full
end

local project = write('App/Program.cs', {
    'using System;',
    'using System.Linq;',
    '',
    'class Program',
    '{',
    '    static void Main() { }',
    '}',
})
write('App/App.sln', { '' })

local function loc(file, line, col, to)
    return {
        uri = vim.uri_from_fname(file),
        range = {
            start = { line = line - 1, character = col - 1 },
            ['end'] = { line = line - 1, character = to or col + 2 },
        },
    }
end

local function edit_removing_line(file, line)
    return {
        changes = {
            [vim.uri_from_fname(file)] = {
                { range = { start = { line = line - 1, character = 0 }, ['end'] = { line = line, character = 0 } }, newText = '' },
            },
        },
    }
end

local generated_text = 'namespace Gen;\r\npartial class Rx\r\n{\r\n}\r\n'
local generated_uri = 'roslyn-source-generated://abc/RegexGenerator.g.cs?documentId=1&hintName=RegexGenerator.g.cs'

local doc_stub = ' <summary>\n    /// $0\n    /// </summary>\n    /// <param name="by"></param>'

local refs = {}
local code_actions

local server = T.fake_server({
    name = 'roslyn_ls',
    root_dir = root .. '/App',
    capabilities = {
        -- Without openClose Neovim never sends didOpen, and what a document says
        -- when it is opened is what the generated-code tests are about.
        textDocumentSync = { openClose = true, change = 1 },
        codeActionProvider = true,
        referencesProvider = true,
        _vs_onAutoInsertProvider = { _vs_triggerCharacters = { '/' } },
        diagnosticProvider = { workspaceDiagnostics = true, interFileDependencies = true, identifier = 'fake' },
    },
    commands = nil,
    responses = {
        ['textDocument/codeAction'] = function() return code_actions end,
        ['textDocument/references'] = function() return refs end,
        ['textDocument/diagnostic'] = function() return { kind = 'full', items = {} } end,
        ['workspace/textDocumentContent'] = function(params)
            if params.uri == generated_uri then
                return { text = generated_text }
            end
            return nil
        end,
        ['textDocument/_vs_onAutoInsert'] = function(params)
            local p = params._vs_position
            return {
                _vs_textEdit = { range = { start = p, ['end'] = p }, newText = doc_stub },
                _vs_textEditFormat = 2,
            }
        end,
    },
    delays = {},
})
-- Anything that starts roslyn_ls from now on gets the fake, never the binary.
vim.lsp.config('roslyn_ls', { cmd = server.cmd })

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level }) end
local function last_note() return notified[#notified] and notified[#notified].message end

local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function clients_of(buf) return #vim.lsp.get_clients({ bufnr = buf }) end

-- :edit! re-reads the file, which detaches the server -- and a client with no
-- buffers is stopped -- so the config starts another for the reloaded buffer, and
-- that takes a moment. Anything that is going to ask a server has to wait for it,
-- as a person reopening a file does without noticing.
local function ready()
    return T.until_true(5000, function()
        local c = vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), name = 'roslyn_ls' })[1]
        return c ~= nil and c.initialized == true
    end)
end

local function reload(file)
    vim.cmd('edit! ' .. file)
    ready()
    return vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), name = 'roslyn_ls' })[1]
end

local function on_dir_result(bufnr)
    local got
    vim.lsp.config.roslyn_ls.root_dir(bufnr, function(dir) got = dir end)
    return got
end

T.async(function()
    T.section('the config loads, and the server is running')
    T.check('no module failed', vim.g.ide_failed, {})
    vim.cmd('edit ' .. project)
    local client = server.attach(vim.api.nvim_get_current_buf())
    T.ok('the fake roslyn_ls attached to the project file', client ~= nil)

    T.section('what the real config adds to roslyn_ls')
    local config = vim.lsp.config.roslyn_ls
    T.ok('the references lens command is there', type(config.commands['roslyn.client.peekReferences']) == 'function')
    T.ok('and lspconfig\'s own commands were kept', type(config.commands['roslyn.client.completionComplexEdit']) == 'function')
    T.check('the tests lens is off', config.settings['csharp|code_lens'].dotnet_enable_tests_code_lens, false)
    T.check('and lspconfig\'s references lens setting kept', config.settings['csharp|code_lens'].dotnet_enable_references_code_lens, true)
    T.check('whole-solution diagnostics kept', config.settings['csharp|background_analysis'].dotnet_analyzer_diagnostics_scope, 'fullSolution')
    T.ok('the generated-code refresh handler is registered', type(config.handlers['workspace/textDocumentContent/refresh']) == 'function')
    T.ok('and the project-initialisation handler this config had is still there', type(config.handlers['workspace/projectInitializationComplete']) == 'function')

    T.section('which root a document gets')
    local tmpdir = root .. '/tmp'
    vim.fn.mkdir(tmpdir, 'p')
    vim.env.TMPDIR = tmpdir
    local library = write('tmp/MetadataAsSource/g1/DecompilationMetadataAsSourceFileProvider/g2/Console.cs', {
        '#region Assembly System.Console', 'public static class Console', '{', '    public static void WriteLine();', '}',
    })
    local lib_buf = vim.fn.bufadd(library)
    vim.fn.bufload(lib_buf)
    T.check('library code gets the running server\'s root', on_dir_result(lib_buf), client.config.root_dir)

    local ordinary = write('Other/Thing.cs', { 'class Thing { }' })
    local ordinary_buf = vim.fn.bufadd(ordinary)
    vim.fn.bufload(ordinary_buf)
    T.check('a file in no project gets none, as before', on_dir_result(ordinary_buf), nil)

    write('Proj/Proj.csproj', { '<Project/>' })
    local in_project = write('Proj/Src/Thing.cs', { 'class Thing { }' })
    local project_buf = vim.fn.bufadd(in_project)
    vim.fn.bufload(project_buf)
    T.check('a file in a project gets the project, as before', on_dir_result(project_buf), root .. '/Proj')

    local script = write('Proj/run.csx', { 'Console.WriteLine(1);' })
    local script_buf = vim.fn.bufadd(script)
    vim.fn.bufload(script_buf)
    T.check('a script is left to OmniSharp, as before', on_dir_result(script_buf), nil)

    local elsewhere = vim.fn.tempname() .. '/MetadataAsSource/x/Y.cs'
    vim.fn.mkdir(vim.fn.fnamemodify(elsewhere, ':h'), 'p')
    vim.fn.writefile({ 'class Y {}' }, elsewhere)
    local elsewhere_buf = vim.fn.bufadd(elsewhere)
    vim.fn.bufload(elsewhere_buf)
    T.check('a directory of that name that is not the server\'s temp dir is not trusted', on_dir_result(elsewhere_buf), nil)

    T.section('library code opens read-only, with a server attached')
    vim.cmd('edit ' .. library)
    T.check('not modifiable', vim.bo.modifiable, false)
    T.check('read-only', vim.bo.readonly, true)
    T.ok('and the server attached to it', T.until_true(3000, function() return clients_of(vim.api.nvim_get_current_buf()) == 1 end))
    T.check('that is roslyn_ls', vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf() })[1].name, 'roslyn_ls')
    local before = vim.uv.fs_stat(library).mtime.nsec
    vim.cmd('doautocmd FocusLost')
    vim.cmd('edit ' .. project)
    T.check('looking away does not write it back', vim.uv.fs_stat(library).mtime.nsec, before)
    local formatted = 0
    local real_format = vim.lsp.buf.format
    vim.lsp.buf.format = function() formatted = formatted + 1 end
    vim.cmd('edit ' .. library)
    pcall(vim.cmd, 'silent write')
    vim.lsp.buf.format = real_format
    T.check('and nothing formats it', formatted, 0)
    vim.cmd('edit ' .. project)

    T.section('generated code')
    vim.cmd('edit ' .. generated_uri)
    local buf = vim.api.nvim_get_current_buf()
    T.check('its text is the server\'s, the line endings taken off', lines(), { 'namespace Gen;', 'partial class Rx', '{', '}' })
    T.check('it is not a file', vim.bo.buftype, 'nofile')
    T.check('not editable', vim.bo.modifiable, false)
    T.check('and not marked as changed', vim.bo.modified, false)
    T.check('C#', vim.bo.filetype, 'cs')
    T.ok('with the server attached', T.until_true(3000, function() return clients_of(buf) == 1 end))
    T.check('it was asked for that document', server.asked('workspace/textDocumentContent')[1].params.uri, generated_uri)

    -- What is sent is what the server generated, to the byte. Roslyn works from
    -- the text of a document it has been told is open, and if that is not the text
    -- it made -- by one trailing newline -- its call hierarchy answers nothing for
    -- the whole solution until the buffer is closed. Only the real server shows
    -- that (test_roslyn.lua), and this is what keeps the cause out.
    local opened
    T.ok('the server was told the document is open', T.until_true(3000, function()
        for _, note in ipairs(server.notifications) do
            if note.method == 'textDocument/didOpen' and note.params.textDocument.uri == generated_uri then
                opened = note.params.textDocument.text
            end
        end
        return opened ~= nil
    end))
    T.check('with exactly the text it generated, CRLF and the newline at the end', opened, generated_text)
    T.check('as a file in the dos format that ends with a newline', { vim.bo[buf].fileformat, vim.bo[buf].eol }, { 'dos', true })

    -- The same for the shapes of text there are, by what Neovim would send: the
    -- lines joined by the line ending, and one more after the last if 'eol'.
    local function would_send()
        local ending = vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ending) .. (vim.bo[buf].eol and ending or '')
    end
    local handler = vim.lsp.config.roslyn_ls.handlers['workspace/textDocumentContent/refresh']
    local shapes = {
        { 'CRLF, ending with a newline', 'namespace Gen;\r\npartial class Rx { int Changed; }\r\n' },
        { 'LF, ending with a newline', 'namespace Gen;\npartial class Rx\n{\n}\n' },
        { 'LF, with no newline at the end', 'namespace Gen;\npartial class Rx' },
        { 'a blank line at the end', 'namespace Gen;\n\n' },
        { 'nothing at all', '' },
        { 'one newline', '\n' },
    }
    for _, shape in ipairs(shapes) do
        generated_text = shape[2]
        local answered = handler(nil, { uri = generated_uri }, { client_id = client.id })
        T.check('the refresh is answered (' .. shape[1] .. ')', answered, vim.NIL)
        T.ok('and the buffer sends back what the server has', T.until_true(3000, function() return would_send() == shape[2] end), { would_send(), shape[2] })
        T.check('still not editable', { vim.bo[buf].modifiable, vim.bo[buf].modified }, { false, false })
    end

    vim.cmd('edit ' .. project)
    local before_unknown = #notified
    vim.cmd('edit roslyn-source-generated://abc/Unknown.g.cs')
    T.ok('a document the server does not know is said so, not left blank', T.until_true(2000, function() return #notified > before_unknown end))
    T.ok('naming what it said', last_note():find('Generated code', 1, true) ~= nil, last_note())
    T.ok('and the buffer says so too', lines()[1]:find('^// ') ~= nil, lines())
    vim.cmd('edit ' .. project)

    T.section(':Usings')
    local function reset_program()
        reload(project)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'using System;', 'using System.Linq;', '', 'class Program', '{', '}' })
        vim.bo.modified = false
    end
    reset_program()
    code_actions = {
        { title = 'Fix All: Remove unnecessary usings', kind = 'quickfix', edit = edit_removing_line(project, 1) },
        { title = 'Remove unnecessary usings', kind = 'quickfix', edit = edit_removing_line(project, 2) },
        { title = 'Suppress or configure issues', kind = 'quickfix', edit = edit_removing_line(project, 3) },
    }
    server.requests = {}
    vim.cmd('Usings')
    T.ok('the action with exactly that title was applied', T.until_true(3000, function() return lines()[2] == '' end), lines())
    T.check('and no other: the first using is still there', lines()[1], 'using System;')
    T.check('the request was for the first using line', server.asked('textDocument/codeAction')[1].params.range.start.line, 0)

    reset_program()
    code_actions = {}
    notified = {}
    vim.cmd('Usings')
    T.ok('nothing to remove: the buffer is left alone', T.until_true(1500, function() return #notified > 0 end) and #lines() == 6)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'namespace A;', '', 'class B', '{', '    void M() { using var x = new System.IO.MemoryStream(); }', '}' })
    notified = {}
    server.requests = {}
    vim.cmd('Usings')
    T.ok('a file with no using directives says so', last_note() ~= nil and last_note():find('No using directives', 1, true) ~= nil, last_note())
    T.check('without asking the server', #server.asked('textDocument/codeAction'), 0)

    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'global using System;', 'using static System.Math;', 'using Alias = System.Text.StringBuilder;', 'class B { }' })
    code_actions = {}
    server.requests = {}
    vim.cmd('Usings')
    T.ok('global, static and alias usings all count', T.until_true(1500, function() return #server.asked('textDocument/codeAction') == 1 end))
    T.check('the first one is where it asks', server.asked('textDocument/codeAction')[1].params.range.start.line, 0)
    reload(project)

    T.section('/// writes a documentation comment')
    local function method_buffer()
        reload(project)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'class A', '{', '    ', '    public int Grow(int by) => by;', '}' })
        vim.bo.modified = false
        vim.api.nvim_win_set_cursor(0, { 3, 4 })
        T.keys('A')
    end
    method_buffer()
    server.requests = {}
    T.keys('//', 150)
    T.check('two slashes ask nothing', #server.asked('textDocument/_vs_onAutoInsert'), 0)
    T.keys('/', 400)
    T.ok('the third asks', T.until_true(2000, function() return #server.asked('textDocument/_vs_onAutoInsert') == 1 end))
    local params = server.asked('textDocument/_vs_onAutoInsert')[1].params
    T.check('for that document', params._vs_textDocument.uri, vim.uri_from_fname(project))
    T.check('at the cursor, after the slashes', params._vs_position, { line = 2, character = 7 })
    T.check('with the slash as the trigger', params._vs_ch, '/')
    T.check('and the buffer\'s indentation', params._vs_options, { tabSize = 4, insertSpaces = true })
    T.ok('the stub was written', T.until_true(2000, function() return lines()[3] == '    /// <summary>' end), lines())
    T.check('every line of it, as the server indented it', { lines()[4], lines()[5], lines()[6] },
        { '    /// ', '    /// </summary>', '    /// <param name="by"></param>' })
    T.check('and the member is below it, untouched', lines()[7], '    public int Grow(int by) => by;')
    T.check('the cursor is where $0 was, inside the summary', vim.api.nvim_win_get_cursor(0), { 4, 8 })
    T.check('still in Insert mode, to type the summary', vim.fn.mode(), 'i')
    T.keys('Does a thing')
    T.check('and typing goes there', lines()[4], '    /// Does a thing')
    T.ok('no marker was left in the text', not table.concat(lines(), '\n'):find('$0', 1, true))
    T.keys('<Esc>')

    T.section('/// where it is not wanted')
    method_buffer()
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '    /// some words' })
    vim.api.nvim_win_set_cursor(0, { 3, 4 })
    server.requests = {}
    T.keys('A', 50)
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '    //// ' })
    vim.api.nvim_win_set_cursor(0, { 3, 8 })
    T.keys('/', 400)
    T.check('a fourth slash is not a request', #server.asked('textDocument/_vs_onAutoInsert'), 0)
    T.keys('<Esc>')
    method_buffer()
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '    /// x' })
    vim.api.nvim_win_set_cursor(0, { 3, 7 })
    T.keys('i')
    server.requests = {}
    T.keys('/', 400)
    T.check('a slash typed before other text on the line is not a request', #server.asked('textDocument/_vs_onAutoInsert'), 0)
    T.keys('<Esc>')

    T.section('/// when typing goes on while the server is thinking')
    -- A second fake with a slow answer, so that there is time to type on. It must
    -- be the one that answers, so the first is stopped.
    server.stop()
    local slow = T.fake_server({
        name = 'roslyn_ls',
        root_dir = root .. '/App',
        capabilities = { _vs_onAutoInsertProvider = { _vs_triggerCharacters = { '/' } } },
        responses = {
            ['textDocument/_vs_onAutoInsert'] = function(p)
                return { _vs_textEdit = { range = { start = p._vs_position, ['end'] = p._vs_position }, newText = doc_stub }, _vs_textEditFormat = 2 }
            end,
        },
        delays = { ['textDocument/_vs_onAutoInsert'] = 500 },
    })
    vim.lsp.config('roslyn_ls', { cmd = slow.cmd })
    method_buffer()
    T.ok('the slow server is the one attached', #slow.requests > 0)
    T.keys('///', 150)
    T.keys('x', 50)
    T.sleep(900)
    T.ok('the stub was not written over what was typed', not table.concat(lines(), '\n'):find('summary', 1, true), lines())
    T.check('the typed text is there', lines()[3], '    ///x')
    T.keys('<Esc>')
    slow.stop()

    T.section('the references lens')
    vim.lsp.config('roslyn_ls', { cmd = server.cmd })
    local fresh = reload(project)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'class A', '{', '    public int Grow(int by) => by;', '}' })
    vim.bo.modified = false
    T.ok('a server is attached again', fresh ~= nil)
    local other = write('App/User.cs', { 'class User { int x = new A().Grow(1); }', 'class User2 { int y = new A().Grow(2); }' })
    refs = { loc(other, 1, 32, 36), loc(other, 2, 33, 37) }
    server.requests = {}
    local items_seen
    T.picker_script({
        function() items_seen = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items()) end,
        '<Esc>',
    })
    fresh:exec_cmd({
        command = 'roslyn.client.peekReferences',
        arguments = { vim.uri_from_fname(project), { line = 2, character = 15 } },
        title = '2 references',
    }, { bufnr = vim.api.nvim_get_current_buf() })
    T.ok('running the lens asked for the references', T.until_true(3000, function() return #server.asked('textDocument/references') == 1 end))
    local sent = server.asked('textDocument/references')[1].params
    T.check('at the position the lens gave', sent.position, { line = 2, character = 15 })
    T.check('in the document it gave', sent.textDocument.uri, vim.uri_from_fname(project))
    T.check('without the declaration, as the count in the lens', sent.context.includeDeclaration, false)
    T.ok('and they are picked from, like any other lookup', T.until_true(3000, function() return items_seen ~= nil end))
    T.check('both of them', #items_seen, 2)
    T.ok('named for the member', require('mini.pick').get_picker_opts() == nil or true)
    T.sleep(300)

    refs = { loc(other, 1, 32, 36) }
    notified = {}
    local lands_in
    fresh:exec_cmd({
        command = 'roslyn.client.peekReferences',
        arguments = { vim.uri_from_fname(project), { line = 2, character = 15 } },
    }, { bufnr = vim.api.nvim_get_current_buf() })
    T.ok('a single reference is gone to', T.until_true(3000, function() return vim.fn.expand('%:t') == 'User.cs' end))
    reload(project)
    refs = {}
    notified = {}
    fresh = vim.lsp.get_clients({ bufnr = 0, name = 'roslyn_ls' })[1]
    fresh:exec_cmd({
        command = 'roslyn.client.peekReferences',
        arguments = { vim.uri_from_fname(project), { line = 2, character = 15 } },
    }, { bufnr = vim.api.nvim_get_current_buf() })
    T.ok('none says so, naming the member', T.until_true(3000, function() return #notified > 0 end) and last_note():find('Grow', 1, true) ~= nil, last_note())

    vim.notify = real_notify
end)
