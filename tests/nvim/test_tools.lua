-- env: full
-- The small tools: :Toggle and the things it flips.

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

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level) table.insert(notified, { message = message, level = level }) end
local function last_note() return notified[#notified] and notified[#notified].message end

local toggles = require('ide.toggles')

T.async(function()
    T.section('the config loads')
    T.check('no module failed', vim.g.ide_failed, {})

    ------------------------------------------------------------------------
    T.section(':Toggle')
    T.check('the usages highlight starts on', toggles.items[3].get(), true)
    T.check('format and autosave start on', { toggles.items[4].get(), toggles.items[5].get() }, { true, true })
    T.check('hints and the lens start off, as they add text to the screen', { toggles.items[1].get(), toggles.items[2].get() }, { false, false })

    vim.cmd('Toggle hints')
    T.check('hints flip on', vim.lsp.inlay_hint.is_enabled(), true)
    T.ok('and it says so', last_note() == 'Inlay hints: on', last_note())
    vim.cmd('Toggle hints')
    T.check('and off', vim.lsp.inlay_hint.is_enabled(), false)
    vim.cmd('Toggle hints on')
    vim.cmd('Toggle hints on')
    T.check('"on" sets rather than flips', vim.lsp.inlay_hint.is_enabled(), true)
    vim.cmd('Toggle hints off')
    T.check('"off" too', vim.lsp.inlay_hint.is_enabled(), false)

    vim.cmd('Toggle lens')
    T.check('the lens flips on', vim.lsp.codelens.is_enabled(), true)
    vim.cmd('Toggle lens')
    T.check('and off', vim.lsp.codelens.is_enabled(), false)

    vim.cmd('Toggle nonsense')
    T.ok('an unknown one is refused, and the real ones listed', last_note():find('No toggle called nonsense', 1, true) ~= nil
        and last_note():find('autosave', 1, true) ~= nil, last_note())

    local completions = vim.fn.getcompletion('Toggle h', 'cmdline')
    T.check('the names complete', completions, { 'hints', 'highlight' })

    local palette = table.concat(require('ide.palette').palette_lines(), '\n')
    T.ok('each is in the palette with the way it is set now', palette:find('Toggle: Inlay hints (off)', 1, true) ~= nil
        and palette:find('Toggle: Usages highlight (on)', 1, true) ~= nil, palette)
    vim.cmd('Toggle hints')
    palette = table.concat(require('ide.palette').palette_lines(), '\n')
    T.ok('and it follows when it changes', palette:find('Toggle: Inlay hints (on)', 1, true) ~= nil)
    vim.cmd('Toggle hints')
    T.ok(':Toggle is in the palette too', palette:find(':Toggle', 1, true) ~= nil)

    local picked
    T.picker_script({
        function()
            picked = vim.tbl_map(function(i) return i.text end, require('mini.pick').get_picker_items())
        end,
        '<C-n><C-n><C-n><CR>',
    })
    vim.cmd('Toggle')
    T.ok('with no argument it is a picker', T.until_true(3000, function() return picked ~= nil end))
    T.check('of all five, each with its state', #picked, 5)
    T.ok('and what it does', picked[1]:find('hints', 1, true) == 1 and picked[1]:find('off', 1, true) ~= nil, picked[1])
    T.ok('choosing one flips it', T.until_true(3000, function() return toggles.items[4].get() == false end))
    toggles.set('format', true)

    ------------------------------------------------------------------------
    T.section('format and autosave switches')
    local file = write('Switch.cs', { 'class A { }' })
    vim.cmd('edit ' .. file)
    local formatted = 0
    local real_clients, real_format = vim.lsp.get_clients, vim.lsp.buf.format
    local function write_buffer()
        vim.lsp.get_clients = function() return { { name = 'stub_ls' } } end
        vim.lsp.buf.format = function() formatted = formatted + 1 end
        local ok, err = pcall(vim.cmd, 'silent write')
        vim.lsp.get_clients, vim.lsp.buf.format = real_clients, real_format
        assert(ok, err)
    end
    write_buffer()
    T.check('a write formats', formatted, 1)
    vim.cmd('Toggle format')
    write_buffer()
    T.check('with format off it does not', formatted, 1)
    T.check('and the file is still written', vim.fn.readfile(file), { 'class A { }' })
    vim.cmd('Toggle format')

    local function disk() return vim.fn.readfile(file)[1] end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'class B { }' })
    vim.cmd('doautocmd FocusLost')
    T.check('losing focus writes', disk(), 'class B { }')
    vim.cmd('Toggle autosave')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'class C { }' })
    vim.cmd('doautocmd FocusLost')
    T.check('with autosave off it does not', disk(), 'class B { }')
    vim.cmd('doautocmd BufLeave')
    T.check('nor on leaving the buffer', disk(), 'class B { }')
    vim.api.nvim_input('<Space>ww')
    T.sleep(100)
    T.check('but <leader>ww always writes', disk(), 'class C { }')
    vim.cmd('Toggle autosave')

    ------------------------------------------------------------------------
    T.section('the usages highlight')
    vim.o.updatetime = 60
    local highlighter = T.fake_server({
        name = 'fake_highlight',
        capabilities = { documentHighlightProvider = true },
        responses = {
            ['textDocument/documentHighlight'] = function()
                return { { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 7 } }, kind = 3 } }
            end,
        },
    })
    vim.cmd('edit! ' .. file)
    T.ok('a server that can highlight attached', highlighter.attach(vim.api.nvim_get_current_buf()) ~= nil)
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    T.keys('l', 50)
    T.keys('h', 50)
    T.ok('resting the cursor asks for the other uses', T.until_true(3000, function() return #highlighter.asked('textDocument/documentHighlight') >= 1 end))
    local asked = #highlighter.asked('textDocument/documentHighlight')
    vim.cmd('Toggle highlight')
    T.check('it can be switched off', toggles.items[3].get(), false)
    T.keys('l', 50)
    T.keys('h', 50)
    T.sleep(500)
    T.check('and then it does not ask', #highlighter.asked('textDocument/documentHighlight'), asked)
    vim.cmd('Toggle highlight')
    T.keys('l', 50)
    T.keys('h', 50)
    T.ok('and asks again once it is back on', T.until_true(3000, function() return #highlighter.asked('textDocument/documentHighlight') > asked end))
    highlighter.stop()
    vim.o.updatetime = 1000

    vim.notify = real_notify
end)
