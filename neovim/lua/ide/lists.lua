-- Everything that touches the quickfix and location lists: the order entries
-- are put in, how an entry is dropped from one, and the picker that results of
-- an LSP lookup go through on their way into one.
--
-- The three things that used to share one quickfix stack, and how they are kept
-- apart. Review hunks, LSP results and diagnostics all want "the" quickfix
-- list, and a plain setqflist puts its list after the current one and frees
-- every list after that -- so a references lookup in the middle of a review
-- buried the hunks, and ]q then walked the references. The answer is not one
-- clever list but a place for each:
--
--   * review owns one titled list and keeps hold of it by id (ide.review);
--   * an LSP lookup is a picker, which is not a list at all until you ask for
--     one (below): look, drop what is noise, then send what is left;
--   * what is sent goes to the *end* of the stack (nr = '$'), never into the
--     middle of it, so nothing newer is freed.

local augroup = require('ide.group')
local M = {}

-- Quickfix entries from a test file go to the bottom of the list, so the real
-- code comes first. "Test" is matched anywhere in the path, case-sensitively
-- and relative to the working directory: case-insensitive also caught `latest`
-- and `contest`, and the full path would sink every result if the project
-- itself lived under a directory called Test. The order within each half is
-- kept, whatever it was.
--
-- This is done once, where every list passes, rather than per source. The
-- first version gave grr an on_list of its own, which worked for references
-- and would have had to be repeated for gri, grt, workspace symbols, call
-- hierarchy, diagnostics and the hunks list -- and an on_list also switches
-- off the jump nvim makes when a lookup has a single result, so each copy would
-- have had to reimplement that too. Every one of those ends in
-- vim.fn.setqflist, which is looked up at the time of the call and so can be
-- wrapped. The wrapper only touches entries going in; its arguments and
-- result pass through as they came, nil-padding included.
--
-- :grep, :vimgrep, :make and the like fill the list without calling it, and
-- are handled by QuickFixCmdPost below. Location lists are left alone: they
-- belong to one window, and the only LSP one (document symbols) is a single
-- file.
local function tests_last(items)
    local first, last = {}, {}
    for _, item in ipairs(items) do
        local name = item.filename
        if (name == nil or name == '') and item.bufnr and item.bufnr > 0 then
            name = vim.api.nvim_buf_get_name(item.bufnr)
        end
        local path = vim.fn.fnamemodify(name or '', ':.')
        table.insert(path:find('Test', 1, true) and last or first, item)
    end
    return vim.list_extend(first, last)
end

M.tests_last = tests_last

local setqflist = vim.fn.setqflist
vim.fn.setqflist = function(...)
    local args = vim.F.pack_len(...)
    local what = args[3]
    if type(what) == 'table' and type(what.items) == 'table' then
        args[3] = vim.tbl_extend('force', what, { items = tests_last(what.items) })
    elseif what == nil and type(args[1]) == 'table' then
        args[1] = tests_last(args[1])
    end
    return setqflist(vim.F.unpack_len(args))
end

-- Fires after the list is filled and before the jump to its first entry, so
-- reordering here still has the jump land on the new first. Only the
-- quickfix commands: the location-list ones all start with `l`.
vim.api.nvim_create_autocmd("QuickFixCmdPost", {
    group = augroup,
    pattern = "[^l]*",
    callback = function()
        local items = vim.fn.getqflist()
        vim.fn.setqflist({}, 'r', { items = items, idx = 1 })
    end,
})

-- dd in the quickfix window drops the entry under the cursor (a count or a
-- visual selection, several), so a list can be worked through. Vim has no
-- command for it: the list is read, cut and written back, with the cursor
-- left on the entry that slid up into the gap.
vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "qf",
    callback = function(args)
        local function remove(first, last)
            local loc = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].loclist == 1
            local get = loc and function(what) return vim.fn.getloclist(0, what) end
                or function(what) return vim.fn.getqflist(what) end
            local items = get({ items = 0 }).items
            last = math.min(last, #items)
            for i = last, first, -1 do
                table.remove(items, i)
            end
            local what = { items = items, idx = math.min(first, #items) }
            if loc then
                vim.fn.setloclist(0, {}, 'r', what)
            else
                vim.fn.setqflist({}, 'r', what)
            end
            if #items > 0 then
                vim.api.nvim_win_set_cursor(0, { math.min(first, #items), 0 })
            end
        end

        vim.keymap.set('n', 'dd', function()
            local row = vim.api.nvim_win_get_cursor(0)[1]
            remove(row, row + vim.v.count1 - 1)
        end, { buffer = args.buf, desc = 'Remove this entry from the list' })

        vim.keymap.set('x', 'd', function()
            local first, last = vim.fn.line('v'), vim.fn.line('.')
            vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
            remove(math.min(first, last), math.max(first, last))
        end, { buffer = args.buf, desc = 'Remove the selected entries from the list' })
    end,
})

----------------------------------------------------------------------------
-- A picker over a list of places
----------------------------------------------------------------------------

-- What an LSP lookup shows, as a picker rather than a quickfix list. The keys
-- are the point of it:
--
--   <CR>      go there (and <C-t> comes back: the jump goes on the tag stack)
--   <Tab>     preview it
--   <C-x>     mark one, <C-a> all of them (mini.pick's own)
--   <C-d>     drop the one under the cursor from the picker, or every marked one
--   <C-q>     send everything listed to the quickfix list, and go to its first
--   <M-q>     the same for this window's location list
--   <M-CR>    send only the marked ones to the quickfix list (mini.pick's own)
--
-- "Everything listed" is what the query on the prompt leaves, not what the
-- server returned: typing narrows the list, and <C-q> sends the narrowed one.
-- Dropping is about noise (a result in generated code, a string that only
-- looks like a call), and a list of them can be worked through with ]q.
--
-- A single result does not open a picker: it is jumped to, as the default
-- go-to-definition does. If that single result is where the cursor already is
-- -- a symbol nothing else uses, found from its own declaration -- there is
-- nowhere to go, and it says so instead of doing nothing.
--
-- The entries are quickfix entries (filename, lnum, col, text) and travel
-- through the picker untouched, in `entry`, so what is sent is exactly what the
-- server said and nothing is rebuilt from the text on screen. Their order is
-- the order Neovim's own conversion gives them (by file, then position), with
-- the tests-last rule above applied, so a lookup reads the same in the picker
-- and in the list it becomes.

local function entry_path(entry)
    local name = entry.filename
    if (name == nil or name == '') and entry.bufnr and entry.bufnr > 0 then
        name = vim.api.nvim_buf_get_name(entry.bufnr)
    end
    return name or ''
end

local function squash(text)
    text = (text or ''):gsub('[\r\n\t]+', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    return text
end

local function to_item(entry)
    local path = entry_path(entry)
    return {
        path = path,
        lnum = entry.lnum,
        col = entry.col,
        end_lnum = entry.end_lnum,
        end_col = entry.end_col,
        text = ('%s:%d:%d  %s'):format(vim.fn.fnamemodify(path, ':.'), entry.lnum or 1, entry.col or 1, squash(entry.text)),
        entry = entry,
    }
end

-- The cursor position as the tag stack wants it, taken before anything moves.
local function here()
    local from = vim.fn.getpos('.')
    from[1] = vim.api.nvim_get_current_buf()
    return { win = vim.api.nvim_get_current_win(), from = from, tagname = vim.fn.expand('<cword>') }
end
M.here = here

local function push_tag(where)
    if where and where.from and where.win and vim.api.nvim_win_is_valid(where.win) then
        local stack = { { tagname = where.tagname or '', from = where.from } }
        vim.fn.settagstack(where.win, { items = stack }, 't')
    end
end

local function at_cursor(entry, where)
    if not (where and where.from) or vim.api.nvim_get_current_buf() ~= where.from[1] then
        return false
    end
    local name = vim.api.nvim_buf_get_name(where.from[1])
    if entry_path(entry) ~= name or entry.lnum ~= where.from[2] then
        return false
    end
    local col = where.from[3]
    local same_line = entry.end_lnum == nil or entry.end_lnum == entry.lnum
    return not same_line or (col >= (entry.col or 1) and col <= (entry.end_col or entry.col or 1))
end

--- Go to one entry: the jump is recorded in the jump list and the tag stack.
---@param entry table
---@param where? table  from M.here(), taken before the lookup started
function M.jump(entry, where)
    local win = where and where.win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd("normal! m'")
    push_tag(where)
    local buf = entry.bufnr
    if not (buf and buf > 0 and vim.api.nvim_buf_is_valid(buf)) then
        buf = vim.fn.bufadd(entry_path(entry))
    end
    vim.bo[buf].buflisted = true
    -- Loaded first, here, and not left to nvim_win_set_buf: that shows the buffer
    -- and loads it later, so the line to put the cursor on does not exist yet, and
    -- for a buffer whose text comes from a BufReadCmd -- generated code, which has
    -- no file -- the text arrived after the cursor had been placed on a line that
    -- was not there.
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { entry.lnum or 1, math.max((entry.col or 1) - 1, 0) })
    vim.api.nvim_win_call(win, function()
        vim.cmd('normal! zv')
        vim.cmd('normal! zz')
    end)
end

--- Fill a list at the end of the stack and show it on its first entry.
---@param entries table[]
---@param title string  without the count, which is added
---@param where 'quickfix'|'location'
---@param win integer  the window the lookup was made from
function M.send(entries, title, where, win)
    if #entries == 0 then
        return
    end
    if not (win and vim.api.nvim_win_is_valid(win)) then
        win = vim.api.nvim_get_current_win()
    end
    local what = { title = ('%s (%d)'):format(title, #entries), items = entries, nr = '$' }
    vim.api.nvim_set_current_win(win)
    if where == 'location' then
        vim.fn.setloclist(win, {}, ' ', what)
        vim.cmd('lopen')
        vim.api.nvim_set_current_win(win)
        vim.cmd('lfirst')
    else
        vim.fn.setqflist({}, ' ', what)
        vim.cmd('botright copen')
        vim.api.nvim_set_current_win(win)
        vim.cmd('cfirst')
    end
end

--- Look at entries in the picker described above.
---@param entries table[]
---@param opts { title: string, where?: table }
function M.pick(entries, opts)
    local pick = require('mini.pick')
    local where = opts.where or here()
    local items = vim.tbl_map(to_item, M.tests_last(entries))

    local function name(count)
        return ('%s (%d)'):format(opts.title, count)
    end

    local function send(kind)
        return function()
            local matched = pick.get_picker_matches()
            local listed = matched and matched.all or {}
            if #listed == 0 then
                return
            end
            local win = pick.get_picker_state().windows.target
            local chosen = vim.tbl_map(function(item) return item.entry end, listed)
            -- After the picker has gone: it puts focus back where it found it
            -- as it closes, and a window opened before that would lose it.
            vim.schedule(function()
                M.send(chosen, opts.title, kind, win)
            end)
            return true
        end
    end

    local function drop()
        local matched = pick.get_picker_matches()
        if not matched or not matched.current_ind then
            return
        end
        local gone = {}
        if #matched.marked_inds > 0 then
            for _, ind in ipairs(matched.marked_inds) do
                gone[ind] = true
            end
        else
            gone[matched.current_ind] = true
        end
        local kept = {}
        for ind, item in ipairs(pick.get_picker_items()) do
            if not gone[ind] then
                table.insert(kept, item)
            end
        end
        pick.set_picker_items(kept)
        pick.set_picker_opts({ source = { name = name(#kept) } })
    end

    local function choose(item)
        push_tag(where)
        pick.default_choose(item)
    end

    pick.start({
        source = { name = name(#items), items = items, choose = choose },
        mappings = {
            drop = { char = '<C-d>', func = drop },
            to_quickfix = { char = '<C-q>', func = send('quickfix') },
            to_location = { char = '<M-q>', func = send('location') },
        },
    })
end

--- What an LSP lookup does with its results: nothing found is the caller's to
--- say, one result is jumped to, several are picked from.
---@param entries table[]
---@param opts { title: string, where?: table }
function M.present(entries, opts)
    local where = opts.where or here()
    if #entries == 0 then
        return
    end
    if #entries == 1 then
        if at_cursor(entries[1], where) then
            return vim.notify('Only this one: ' .. opts.title, vim.log.levels.INFO)
        end
        return M.jump(entries[1], where)
    end
    M.pick(entries, vim.tbl_extend('force', opts, { where = where }))
end

----------------------------------------------------------------------------
-- The stack itself
----------------------------------------------------------------------------

-- Every list in the quickfix stack (or this window's location lists), to go
-- back to one. The stack is `'chistory'` deep (ide.options makes it thirty) and a
-- list that was pushed off the end is gone; this is how the ones that are still
-- there are found without counting `:colder`s. The current one is marked, and the preview is
-- the list's own entries, so the right one can be told from its title alone.
---@param kind 'quickfix'|'location'
function M.stack(kind)
    local loc = kind == 'location'
    local function get(what)
        if loc then
            return vim.fn.getloclist(0, what)
        end
        return vim.fn.getqflist(what)
    end

    local count = get({ nr = '$' }).nr
    if count == 0 then
        return vim.notify(('No %s lists yet'):format(kind), vim.log.levels.INFO)
    end
    local current = get({ nr = 0 }).nr
    local win = vim.api.nvim_get_current_win()

    local items = {}
    for nr = count, 1, -1 do
        local info = get({ nr = nr, title = 0, size = 0 })
        table.insert(items, {
            nr = nr,
            text = ('%s %d  %s (%d)'):format(nr == current and '▸' or ' ', nr, info.title ~= '' and info.title or '(untitled)', info.size),
        })
    end

    local function preview(buf, item)
        local lines = {}
        for _, entry in ipairs(get({ nr = item.nr, items = 0 }).items) do
            table.insert(lines, ('%s:%d  %s'):format(vim.fn.fnamemodify(entry_path(entry), ':.'), entry.lnum or 1, squash(entry.text)))
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '(empty)' })
    end

    require('mini.pick').start({
        source = {
            name = loc and 'Location lists' or 'Quickfix lists',
            items = items,
            preview = preview,
            choose = function(item)
                vim.schedule(function()
                    if not vim.api.nvim_win_is_valid(win) then
                        return
                    end
                    vim.api.nvim_set_current_win(win)
                    vim.cmd(item.nr .. (loc and 'lhistory' or 'chistory'))
                    vim.cmd(loc and 'lopen' or 'botright copen')
                end)
            end,
        },
    })
end

return M
