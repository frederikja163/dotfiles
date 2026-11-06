-- env: full
-- Completion as Neovim's own: the menu that opens as you type, the popup that
-- says what the highlighted item is, accepting with <CR>, snippets, the extra
-- edits and commands an item carries, and the keys around it.
--
-- This runs in the editor's real main loop (T.async in lib.lua), because the
-- completion menu only exists while Insert mode is being read a key at a time.
-- The language server is a fake that answers from a table.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')

-- "-- INSERT --" on every mode change would be printed into the test's output.
vim.o.showmode = false

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
vim.cmd.cd(root)

local file = root .. '/A.cs'
vim.fn.writefile({ 'class A', '{', '    void M()', '    {', '        ', '    }', '}' }, file)

local ran = {}
local function item(label, kind, extra)
    return vim.tbl_extend('force', { label = label, kind = kind, sortText = label }, extra or {})
end
local items = {
    item('WriteLine', 2, { detail = 'void Console.WriteLine()', documentation = { kind = 'markdown', value = '**Writes** a line to the output.' } }),
    item('Write', 2, { detail = 'void Console.Write()' }),
    item('ReadLine', 2, { detail = 'string Console.ReadLine()' }),
    item('Alpha', 7, { additionalTextEdits = { { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } }, newText = 'using System;\n' } } }),
    item('foreach', 15, { insertTextFormat = 2, insertText = 'foreach (var ${1:item} in ${2:items})\n{\n\t$0\n}', detail = 'foreach loop' }),
    item('Complex', 2, { command = { command = 'test.cmd', title = 'x', arguments = { 'payload' } } }),
}

local server = T.fake_server({
    capabilities = {
        completionProvider = { triggerCharacters = { '.' }, resolveProvider = true },
        signatureHelpProvider = { triggerCharacters = { '(', ',' } },
    },
    commands = {
        ['test.cmd'] = function(command) table.insert(ran, { command.command, command.arguments }) end,
    },
    responses = {
        ['textDocument/completion'] = function() return { isIncomplete = false, items = items } end,
        ['completionItem/resolve'] = function(it)
            if not it.documentation then
                it.documentation = { kind = 'markdown', value = ('Documentation for `%s`'):format(it.label) }
            end
            return it
        end,
    },
})

local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function menu() return vim.fn.pumvisible() == 1 end
local function words()
    return vim.tbl_map(function(it) return it.word end, vim.fn.complete_info({ 'items' }).items)
end
local function selected() return vim.fn.complete_info({ 'selected' }).selected end

local BASE = { 'class A', '{', '    void M()', '    {', '        ', '    }', '}' }

-- Every scenario starts from the same text, in Normal mode, with the cursor at
-- the end of line 5 -- an earlier one's edits (an import at the top, a snippet)
-- would otherwise move the line the next one types on -- and goes into Insert
-- mode from there.
local function fresh()
    vim.snippet.stop()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, BASE)
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 5, 8 })
    T.keys('A')
end

local function leave_insert()
    T.keys('<Esc>')
    T.keys('<Esc>')
end

T.async(function()
    T.section('the config loads, and the server attaches')
    T.check('no module failed', vim.g.ide_failed, {})
    vim.cmd('edit ' .. file)
    local client = server.attach(vim.api.nvim_get_current_buf())
    T.ok('the fake server attached', client ~= nil)

    T.section('how it is set up')
    T.check('the menu opens with the first item highlighted, not inserted, with a documentation popup', vim.o.completeopt,
        'menu,menuone,noinsert,popup,fuzzy')
    local triggers = client.server_capabilities.completionProvider.triggerCharacters
    T.check('what the server says it triggers on is left as it said', triggers, { '.' })
    for _, name in ipairs({ 'nvim-cmp', 'cmp-nvim-lsp', 'cmp-path', 'cmp-vsnip', 'vim-vsnip', 'lspkind.nvim' }) do
        local present = vim.uv.fs_stat(vim.fn.stdpath('data') .. '/site/pack/core/opt/' .. name) ~= nil
        T.check(name .. ' is gone', present, false)
    end

    T.section('the menu opens as you type')
    fresh()
    T.keys('Wri', 400)
    T.ok('a menu is showing', T.until_true(2000, menu))
    local shown = words()
    table.sort(shown)
    T.check('with the items that match, fuzzily, and not the one that does not', shown, { 'Write', 'WriteLine' })
    T.check('the first is highlighted', selected(), 0)
    T.check('but not inserted: what was typed is still all there', vim.api.nvim_get_current_line(), '        Wri')
    local first = words()[1]
    T.check('the server was asked once for the three letters', #server.asked('textDocument/completion'), 1)
    T.check('as an invocation, not a trigger character: Roslyn answers a letter sent as one with nothing', server.asked('textDocument/completion')[1].params.context.triggerKind, 1)

    local kinds = vim.tbl_map(function(it) return it.kind end, vim.fn.complete_info({ 'items' }).items)
    T.ok('each kind has an icon and its name', #kinds == 2 and kinds[1]:find('Method', 1, true) ~= nil and #kinds[1] > #'Method', kinds)

    T.section('the popup that says what it is')
    T.ok('a documentation window opened', T.until_true(3000, function()
        local info = vim.fn.complete_info({ 'selected' })
        return info.preview_winid and info.preview_winid ~= 0 and vim.api.nvim_win_is_valid(info.preview_winid)
    end))
    local popup = vim.fn.complete_info({ 'selected' })
    T.ok('the server was asked to resolve the highlighted item', #server.asked('completionItem/resolve') > 0)
    local text = table.concat(vim.api.nvim_buf_get_lines(popup.preview_bufnr, 0, -1, false), '\n')
    T.ok('and its documentation is in the window', text:find('Write', 1, true) ~= nil, text)
    T.check('with the markup concealed, not shown', vim.wo[popup.preview_winid].conceallevel, 2)
    T.ok('rendered as markdown by tree-sitter', vim.b[popup.preview_bufnr].ts_highlight == true)

    T.section('moving about in it')
    T.keys('<Tab>')
    T.check('Tab goes to the next item', selected(), 1)
    T.keys('<S-Tab>')
    T.check('Shift-Tab goes back', selected(), 0)
    -- Selecting with Tab inserts the match, so the line is not what was typed.
    local line = vim.api.nvim_get_current_line()
    T.keys('<C-d>')
    T.ok('Ctrl-d scrolls the documentation and leaves the menu and the line alone', menu() and vim.api.nvim_get_current_line() == line, vim.api.nvim_get_current_line())
    T.keys('<C-u>')
    T.ok('and Ctrl-u too', menu() and vim.api.nvim_get_current_line() == line, vim.api.nvim_get_current_line())

    T.section('accepting')
    local before = #lines()
    T.keys('<CR>')
    T.check('Enter accepts the highlighted item', vim.api.nvim_get_current_line(), '        ' .. first)
    T.check('and does not add a line', #lines(), before)
    T.ok('the menu is closed', not menu())
    T.keys('<CR>')
    T.check('with no menu, Enter is a new line', #lines(), before + 1)
    leave_insert()

    T.section('an item that adds an import')
    leave_insert()
    fresh()
    T.keys('Alp', 400)
    T.ok('the menu is open', T.until_true(2000, menu))
    T.keys('<CR>')
    T.ok('the edit that came with it was applied: the first line is the import', T.until_true(2000, function() return lines()[1] == 'using System;' end), lines())
    T.ok('and the item itself was inserted', table.concat(lines(), '\n'):find('Alpha', 1, true) ~= nil)
    leave_insert()

    T.section('an item that is a snippet')
    leave_insert()
    fresh()
    T.keys('fore', 400)
    T.ok('the menu is open', T.until_true(2000, menu))
    T.keys('<CR>')
    T.ok('the snippet was expanded', T.until_true(2000, function()
        return table.concat(lines(), '\n'):find('foreach (var item in items)', 1, true) ~= nil
    end), lines())
    T.check('and is active, so its placeholders can be jumped between', vim.snippet.active(), true)
    T.keys('<Tab>')
    T.check('Tab jumps to the next placeholder, selected', vim.fn.mode(), 's')
    T.keys('xs')
    T.ok('and typing replaces it', table.concat(lines(), '\n'):find('in xs)', 1, true) ~= nil, lines())
    T.keys('<S-Tab>')
    T.check('Shift-Tab goes back to the first', vim.fn.mode(), 's')
    T.keys('<Esc>')
    vim.snippet.stop()
    leave_insert()

    T.section('an item that runs a command')
    vim.snippet.stop()
    leave_insert()
    fresh()
    T.keys('Compl', 400)
    T.ok('the menu is open', T.until_true(2000, menu))
    T.keys('<CR>')
    T.ok('the command ran, in the client, with its arguments', T.until_true(2000, function() return #ran == 1 end), ran)
    T.check('as the server named it', ran[1], { 'test.cmd', { 'payload' } })
    leave_insert()

    T.section('asking for completions by hand')
    leave_insert()
    fresh()
    local asked = #server.asked('textDocument/completion')
    T.keys('<C-Space>', 300)
    T.ok('Ctrl-Space asks', T.until_true(2000, function() return #server.asked('textDocument/completion') > asked end))
    T.check('as an invocation, not a trigger character', server.asked('textDocument/completion')[asked + 1].params.context.triggerKind, 1)
    leave_insert()

    T.section('the keys keep their usual meaning with no menu')
    leave_insert()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '    foo' })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    T.keys('A')
    T.ok('no menu', not menu())
    T.keys('<C-d>')
    T.check('Ctrl-d dedents', vim.api.nvim_get_current_line(), 'foo')
    T.keys('<C-u>')
    T.check('Ctrl-u deletes to the start of the line', vim.api.nvim_get_current_line(), '')
    T.keys('<Tab>')
    T.check('Tab is a tab (or its spaces)', vim.api.nvim_get_current_line():match('^%s+$') ~= nil, true)
    leave_insert()

    T.section('the cheatsheet lists them')
    local sheet = table.concat(require('ide.palette').key_lines(), '\n')
    T.ok('Enter, Tab and Ctrl-Space are listed, with what they do', sheet:find('Accept the highlighted completion', 1, true) ~= nil
        and sheet:find('Next completion or snippet placeholder', 1, true) ~= nil and sheet:find('Ask for completions now', 1, true) ~= nil)
end)
