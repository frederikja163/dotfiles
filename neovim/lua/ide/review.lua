local augroup = require('ide.group')
local gitrev = require('ide.gitrev')
local modal = require('ide.modal')
local registry = require('ide.registry')

-- Reviewing a diff
--
-- A diff is read here in the file itself, not in a copy of it: the removed
-- lines are drawn as virtual lines between the real ones, so the buffer is
-- the working file with its LSP attached and gd, grr and the rest behave as
-- they do while editing. That inline layout is the default. The other one,
-- side by side (vim's own :diffsplit, on `s` in the mode), puts the old version
-- in a scratch buffer no server attaches to; it is there for when the shape
-- of a change reads better that way, and its right-hand side is still the
-- real file.
--
-- What is compared is always the working tree against one revision, which is
-- the whole of the grammar: `:Review` is HEAD (everything not yet committed),
-- `:Review BASE` is this branch since it left the default branch (what a pull
-- request shows), `:Review BASE:release` the same against another branch, and
-- a branch, tag or commit is that revision as it is. ide.gitrev has the rules,
-- shared with bin/lines-changed. A range -- the second-to-last commit, say --
-- was considered and left out: its right-hand side is not a file on disk, so
-- the buffer would have no language server, and the point of reading a diff
-- here is that gd and grr work in it.
--
-- gitsigns draws both layouts. Its inline view (`diffthis` with
-- `unified = true`) is the one used here; the older `show_deleted` option
-- looked like the same thing for every buffer at once, but it is deprecated
-- upstream. diffview.nvim was the other candidate and was passed over: its
-- newer side is also a real buffer, but it has no inline mode.
--
-- Both layouts belong to one window and file, and on their own neither
-- follows when that window moves on to the next file: gitsigns closes the
-- inline view, and a :diffsplit is left with the old file's revision beside
-- the new file. Review is what makes them follow. While it is on, every
-- git-tracked buffer that lands in a window gets the current layout opened
-- again; for side by side, the old split is closed and a new one made for
-- the new file, so there is only ever one revision window. That window is
-- marked 'winfixbuf', so stepping from inside it lands in the file window
-- instead.
--
-- It is opened from GitSignsUpdate rather than BufWinEnter alone because a
-- freshly loaded buffer is not attached yet when it enters the window.
-- Attaching is not enough either: the first GitSignsUpdate comes with only
-- the branch name, before the file has been diffed, and diffthis fails an
-- assertion if called then. The hunk counts in the status dict are the
-- public sign that the diff is ready, so that is what is waited for.
--
-- Review is on or off, and separately there is the review *mode*, the keys
-- that step through it. Leaving the mode (Escape, or any key it does not own)
-- leaves review running, so that gd and grr and the rest of the editing keys
-- work in the file being read and the mode is one keypress away again.
--
-- What it steps through is a quickfix list of the hunks, because that is what
-- a list of places to go to already is: the quickfix window shows it, `dd`
-- there drops an entry, ]q and [q walk it. Having LSP results land in the same
-- stack was what made the two collide -- a plain setqflist inserts after the
-- list you are on and frees every newer one, and ]q walks whichever is
-- current -- so the review keeps hold of its list by *id*, which does not
-- change when the stack shifts, and selects it before every step. A new list
-- is added at the end of the stack, never in the middle of it, so nothing
-- newer is thrown away. gitsigns builds the entries (every hunk in the repo
-- against the base, untracked files included); it is asked for them after the
-- last list has been selected, which is what puts the new one at the end.
--
-- The list is the user's to edit while reviewing -- an entry dropped (`d`) is
-- one they are done with -- so starting review again with the same base
-- brings the list back as it was, drops and all, and builds one only when
-- there is none or the base has moved. The base is compared as a commit, not
-- as a name, so HEAD moving on (a commit made mid-review) rebuilds, which is
-- right: the hunks against the new HEAD are not the old ones. `R` throws the
-- list away and starts over. Line numbers in the list are a snapshot, as they
-- always were in a quickfix list; ]c and [c (gitsigns) follow the file as it
-- changes and are not part of the mode for that reason.
--
-- Formatting is switched off while review is on, and that is in ide.autosave,
-- where the formatter is: a write that reformats the buffer being read puts
-- changes of its own into the diff being read.
--
-- The list of changed files is a picker in the current window. gitsigns'
-- own file-tree panel (`:Gitsigns diff`) was used for it at first and taken
-- out: it always opens in a tab of its own, and tabs are not part of how
-- this nvim is used.
vim.pack.add({ { src = "https://github.com/lewis6991/gitsigns.nvim" } })
local gitsigns = require('gitsigns')
gitsigns.setup({
    -- A new file is part of the diff too, and belongs in the quickfix list.
    attach_to_untracked = true,
})

-- Same algorithm as git/config, so nvim and `git diff` draw the same hunks.
vim.opt.diffopt:append('algorithm:histogram')

-- `layout` outlives review, so the last one used comes back with it.
-- `split` is the side-by-side pair: the file window and its revision window.
-- `base` is what gitsigns is told to compare against; `commit` is the same
-- thing as a hash, for telling whether a list was built against it; `ref` is
-- what the user typed, for the statusline.
--
-- `on` is set as soon as the base is changed; `ready` only when everything a
-- start does has finished (the list is in place and the first hunk is shown),
-- which is what a caller that needs the whole thing waits for.
--
-- `generation` is how starting stays correct when starts overlap. Starting is a
-- chain of steps that each finish later -- change the base, wait for the diff,
-- build the list, open it -- and the user can start again, or stop, in the
-- middle of it: a base picked and then another picked a moment later, or `q`
-- while the first is still working. Every start and every stop takes a new
-- number, and each step checks the number it began with before it does
-- anything, so what was overtaken quietly gives up. Without it the first start
-- finished against the second one's base and built a list titled for one
-- revision from the other's data.
--
-- Each revision a review has used has a list of its own, kept in `lists` by
-- what was typed, so that looking at HEAD for a moment and coming back to BASE
-- brings back BASE's list with its dropped hunks, not a fresh one. A list is
-- only brought back if it was built against the same commit: HEAD is a different
-- commit after every commit made, and the hunks against the old one are not
-- the hunks now. `list_id` is the list in use, and `dropped` is that list's
-- undo stack.
local review = {
    on = false,
    ready = false,
    generation = 0,
    base = nil,
    commit = nil,
    ref = nil,
    layout = 'unified',
    split = nil,
    list_id = nil,
    lists = {},
    dropped = {},
}

-- Two things have to be true. The status dict has hunk counts, which says the
-- file has been diffed. And, if gitsigns is tracking the buffer, the text it
-- compares against has to be there: changing the base clears that text at once
-- and fills it again in an update that finishes later, while the status dict
-- goes on holding the *old* base's counts until then. Asking for a diff in that
-- gap is the assertion in gitsigns' diffthis -- `assert(bcache.compare_text)` --
-- which is raised inside its own task where nothing here can catch it. Not
-- ready is not lost: the update that fills the text fires GitSignsUpdate, and
-- that is one of the things that opens the view.
--
-- The cache is gitsigns' own, not its public interface, as with gitsigns.unified
-- below; it is asked for with pcall so that a version without it is only less
-- careful, not broken.
local function diff_ready(buf)
    local status = vim.b[buf].gitsigns_status_dict
    if status == nil or status.added == nil then
        return false
    end
    local ok, cache = pcall(require, 'gitsigns.cache')
    local entry = ok and type(cache.cache) == 'table' and cache.cache[buf] or nil
    return entry == nil or entry.compare_text ~= nil
end

local function split_close()
    local split = review.split
    review.split = nil
    if not split then
        return
    end
    if vim.api.nvim_win_is_valid(split.rev) then
        vim.api.nvim_win_close(split.rev, true)
    end
    if vim.api.nvim_win_is_valid(split.file) then
        vim.api.nvim_win_call(split.file, function()
            vim.cmd.diffoff()
        end)
        vim.w[split.file].review_buf = nil
    end
end

-- `vim.w.review_buf` records which buffer this window's view was opened for,
-- so a GitSignsUpdate for a buffer already on show does not open it twice.
-- That matters most inline: diffthis is a toggle there, and a second call
-- would close the view instead.
--
-- diffthis reads the old version from git before it draws, and draws in
-- whichever window is current by then; `done` is how a caller waits for it
-- before moving focus, as opening the quickfix window does.
local function review_open(win, done)
    done = done or function() end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.w[win].review_buf == buf or not diff_ready(buf)
        or (review.split and win == review.split.rev) then
        return done()
    end
    -- A diff the user made by hand is left alone.
    if vim.wo[win].diff and not (review.split and win == review.split.file) then
        return done()
    end

    vim.w[win].review_buf = buf
    if review.layout == 'unified' then
        gitsigns.diffthis(review.base, { unified = true }, vim.schedule_wrap(done))
        return
    end

    split_close()
    vim.w[win].review_buf = buf
    gitsigns.diffthis(review.base, { vertical = true }, vim.schedule_wrap(function()
        for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
            if other ~= win and vim.wo[other].diff then
                vim.wo[other].winfixbuf = true
                review.split = { file = win, rev = other }
            end
        end
        done()
    end))
end

local function review_close_all()
    split_close()
    -- gitsigns has no public way to ask whether a window has the inline view.
    -- Its internal module is asked when it is there, because the record
    -- alone goes wrong if a diffthis ever failed: the "close" would then open
    -- a view, after review mode had ended.
    local ok, unified = pcall(require, 'gitsigns.unified')
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local open = vim.w[win].review_buf == vim.api.nvim_win_get_buf(win)
        if ok and type(unified.get_view) == 'function' then
            open = unified.get_view(win) ~= nil
        end
        if open then
            -- Closing does no git work, so it finishes inside win_call
            -- rather than landing later in whichever window is current.
            vim.api.nvim_win_call(win, function()
                gitsigns.diffthis(nil, { unified = true })
            end)
        end
        vim.w[win].review_buf = nil
    end
end

vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "GitSignsUpdate",
    callback = function(args)
        if review.on and args.data and args.data.buffer == vim.api.nvim_get_current_buf() then
            review_open(vim.api.nvim_get_current_win())
        end
    end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function()
        if review.on then
            review_open(vim.api.nvim_get_current_win())
        end
    end,
})

-- gitsigns closes the inline view on this same event; forget it here as
-- well, or coming back to the buffer would look like the view were open.
vim.api.nvim_create_autocmd("BufWinLeave", {
    group = augroup,
    callback = function(args)
        if vim.w.review_buf == args.buf then
            vim.w.review_buf = nil
        end
    end,
})

-- Closing the revision window by hand ends the pair; the next file still
-- gets a new one while review mode is on.
vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
        local split = review.split
        if split and tonumber(args.match) == split.rev then
            review.split = nil
            if vim.api.nvim_win_is_valid(split.file) then
                vim.schedule(function()
                    if vim.api.nvim_win_is_valid(split.file) then
                        vim.api.nvim_win_call(split.file, function()
                            vim.cmd.diffoff()
                        end)
                    end
                end)
            end
        end
    end,
})

local function review_stop()
    -- Whatever start is still in flight is overtaken.
    review.generation = review.generation + 1
    review.ready = false
    review_close_all()
    review.on, review.base, review.commit, review.ref = false, nil, nil, nil
    gitsigns.toggle_word_diff(false)
    gitsigns.reset_base(true)
    vim.cmd.redrawstatus()
end

----------------------------------------------------------------------------
-- The list of hunks
----------------------------------------------------------------------------

-- The list's place in the stack, or nil if it is gone. Looked up by id every
-- time: the number changes whenever the stack shifts, the id never does.
local function list_nr()
    if not review.list_id then
        return nil
    end
    local nr = vim.fn.getqflist({ id = review.list_id, nr = 0 }).nr
    return nr > 0 and nr or nil
end

local function list_info()
    local nr = list_nr()
    if not nr then
        return nil
    end
    local info = vim.fn.getqflist({ id = review.list_id, idx = 0, size = 0 })
    return { nr = nr, idx = info.idx, size = info.size }
end

local function list_items()
    return vim.fn.getqflist({ id = review.list_id, items = 0 }).items
end

-- Plain setqflist, not vim.fn.setqflist: ide.lists wraps that to put test
-- files last, and the order of this list is already settled -- reordering it
-- on every edit would leave `idx` pointing at a different entry.
local function replace_items(items, idx)
    vim.call('setqflist', {}, 'r', { id = review.list_id, items = items, idx = idx })
end

-- A window to show a hunk in: the one being used if it is an ordinary one,
-- else the one used before it. Neither the quickfix window nor the revision
-- window of a side-by-side pair is somewhere to open a file.
local function file_window()
    local function usable(win)
        return win ~= nil and win ~= 0 and vim.api.nvim_win_is_valid(win)
            and vim.api.nvim_win_get_config(win).relative == ''
            and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
            and not (review.split and win == review.split.rev)
    end
    local current = vim.api.nvim_get_current_win()
    if usable(current) then
        return current
    end
    local previous = vim.fn.win_getid(vim.fn.winnr('#'))
    if usable(previous) then
        return previous
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if usable(win) then
            return win
        end
    end
end

-- Go to entry `idx` of the review list, in a window fit to show it.
local function goto_entry(idx)
    local nr = list_nr()
    if not nr then
        return false
    end
    -- Selecting the list is what makes :cc mean this list, whatever the user
    -- has been looking at since.
    vim.cmd(nr .. 'chistory')
    local win = file_window()
    if win then
        vim.api.nvim_set_current_win(win)
    end
    local ok, err = pcall(vim.cmd, idx .. 'cc')
    if not ok then
        vim.notify('Review: ' .. tostring(err), vim.log.levels.WARN)
        return false
    end
    vim.cmd('normal! zz')
    return true
end

local function say(text)
    vim.api.nvim_echo({ { text, 'WarningMsg' } }, false, {})
end

-- Build the list again from what the repository says now. It is added at the
-- end of the stack: the last list is selected first, so that "after the current
-- one" is the end, and nothing newer is freed.
local function build_list(generation, done)
    local last = vim.fn.getqflist({ nr = '$' }).nr
    if last > 0 then
        vim.cmd(last .. 'chistory')
    end
    local commit, label = review.commit, review.ref
    gitsigns.setqflist('all', { open = false }, vim.schedule_wrap(function()
        if generation ~= review.generation then
            return
        end
        local record = { id = vim.fn.getqflist({ id = 0 }).id, commit = commit, dropped = {} }
        review.lists[label] = record
        review.list_id, review.dropped = record.id, record.dropped
        vim.call('setqflist', {}, 'a', { id = record.id, title = 'Review: ' .. label })
        done(true)
    end))
end

-- The list for this revision is brought back if it is still there and was built
-- against this commit, or built now.
local function ensure_list(rebuild, generation, done)
    local record = review.lists[review.ref]
    if not rebuild and record and record.commit == review.commit
        and vim.fn.getqflist({ id = record.id, nr = 0 }).nr > 0 then
        review.list_id, review.dropped = record.id, record.dropped
        return done(false)
    end
    build_list(generation, function()
        done(true)
    end)
end

local function step(direction)
    return function(count)
        local info = list_info()
        if not info then
            say('The list of hunks is gone: R builds it again')
            return
        end
        if info.size == 0 then
            say('No hunks left: q stops the review')
            return
        end
        local target = info.idx
        for _ = 1, count do
            local next_idx = target + direction
            if next_idx < 1 then
                say('First hunk')
                break
            elseif next_idx > info.size then
                say('Last hunk')
                break
            end
            target = next_idx
        end
        goto_entry(target)
    end
end

-- The first entry of the next file, or of the previous one. "File" is what
-- the entries say it is: they are in file order, so a change of buffer is a
-- change of file.
local function by_file(direction)
    return function(count)
        local info = list_info()
        if not info or info.size == 0 then
            return step(direction)(1)
        end
        local items = list_items()
        local target = info.idx
        for _ = 1, count do
            local here = items[target].bufnr
            local i = target
            while true do
                i = i + direction
                if i < 1 or i > #items then
                    say(direction > 0 and 'Last file' or 'First file')
                    i = nil
                    break
                end
                if items[i].bufnr ~= here then
                    break
                end
            end
            if not i then
                break
            end
            target = i
            -- Going backwards lands on the first entry of that file, not the last.
            if direction < 0 then
                while target > 1 and items[target - 1].bufnr == items[target].bufnr do
                    target = target - 1
                end
            end
        end
        goto_entry(target)
    end
end

-- Done with this hunk: out of the list, and on to the one that slid up into
-- its place. What was dropped is kept, newest last, for `u`.
local function drop()
    local info = list_info()
    if not info or info.size == 0 then
        return say('No hunks left: q stops the review')
    end
    local items = list_items()
    local entry = table.remove(items, info.idx)
    table.insert(review.dropped, { entry = entry, idx = info.idx })
    local idx = math.min(info.idx, #items)
    replace_items(items, math.max(idx, 1))
    if #items == 0 then
        return say('Every hunk is done: q stops the review')
    end
    goto_entry(idx)
end

local function undrop()
    local last = table.remove(review.dropped)
    if not last or not list_nr() then
        return say('Nothing dropped to bring back')
    end
    local items = list_items()
    local idx = math.min(last.idx, #items + 1)
    table.insert(items, idx, last.entry)
    replace_items(items, idx)
    goto_entry(idx)
end

--- "3/12" and which base, for the statusline; nil when no review is on.
---@return string?
local function status()
    if not review.on then
        return nil
    end
    local info = list_info()
    if not info then
        return review.ref
    end
    if info.size == 0 then
        return review.ref .. ' done'
    end
    return ('%s %d/%d'):format(review.ref, math.max(info.idx, 1), info.size)
end

local function toggle_list_window()
    if vim.fn.getqflist({ winid = 0 }).winid ~= 0 then
        return vim.cmd.cclose()
    end
    local nr = list_nr()
    if nr then
        vim.cmd(nr .. 'chistory')
    end
    local from = vim.api.nvim_get_current_win()
    vim.cmd.copen()
    -- Opening it is not leaving the file.
    if vim.api.nvim_win_is_valid(from) then
        vim.api.nvim_set_current_win(from)
    end
end

----------------------------------------------------------------------------
-- Starting, and the layouts
----------------------------------------------------------------------------

--- Compare the working tree with `spec` (see ide.gitrev), and open the list.
--- `opts.rebuild` throws the list away; `opts.enter` goes into the mode once
--- the review is ready.
---@param spec? string
---@param opts? { rebuild?: boolean, enter?: boolean }
local function review_start(spec, opts)
    opts = opts or {}
    local resolved, err = gitrev.resolve(spec)
    if not resolved then
        return vim.notify('Review: ' .. err, vim.log.levels.ERROR)
    end

    review.generation = review.generation + 1
    local generation = review.generation
    local function current()
        return generation == review.generation
    end

    -- Off until the new base is in place: the GitSignsUpdate that changing
    -- it fires would otherwise open views against the old one, and race the
    -- quickfix window for focus.
    review_close_all()
    review.on, review.ready = false, false
    review.base = resolved.label == 'HEAD' and 'HEAD' or resolved.commit
    review.commit, review.ref = resolved.commit, resolved.label
    -- Set here and nowhere else in review mode: changing word_diff makes
    -- gitsigns throw away every buffer's diff and recompute it, and a
    -- diffthis in that window fails the assertion described at the top. Turning it
    -- off for side by side, where vim already marks changed words, did that
    -- on every switch of layout.
    gitsigns.toggle_word_diff(true)
    gitsigns.change_base(review.base, true, function(change_err)
        if not current() then
            return
        end
        if change_err then
            vim.notify('Review: ' .. change_err, vim.log.levels.ERROR)
            vim.schedule(review_stop)
            return
        end
        vim.schedule(function()
            if not current() then
                return
            end
            review.on = true
            review_open(vim.api.nvim_get_current_win(), function()
                if not current() then
                    return
                end
                ensure_list(opts.rebuild, generation, function(built)
                    if not current() then
                        return
                    end
                    -- A list that was only brought back is left where it was;
                    -- a new one is where reviewing starts, on its first entry,
                    -- in the file window.
                    local from = vim.api.nvim_get_current_win()
                    local nr = list_nr()
                    if nr and not built then
                        vim.cmd(nr .. 'chistory')
                    end
                    vim.cmd.copen()
                    if built and #list_items() > 0 then
                        goto_entry(1)
                    elseif vim.api.nvim_win_is_valid(from) then
                        vim.api.nvim_set_current_win(from)
                    end
                    review.ready = true
                    vim.cmd.redrawstatus()
                    if opts.enter then
                        modal.enter('review')
                    end
                end)
            end)
        end)
    end)
end

local function review_layout(layout)
    review.layout = layout
    if not review.on then
        return review_start()
    end
    -- The window the file is in, not the revision window, if that has focus.
    local win = vim.api.nvim_get_current_win()
    if review.split and win == review.split.rev then
        win = review.split.file
    end
    review_close_all()
    vim.api.nvim_set_current_win(win)
    review_open(win)
end

local function toggle_layout()
    review_layout(review.layout == 'split' and 'unified' or 'split')
end

-- Against the review base when reviewing, HEAD otherwise, and new files too.
local function changed_files()
    local root = vim.trim(vim.fn.system({ 'git', 'rev-parse', '--show-toplevel' }))
    if vim.v.shell_error ~= 0 then
        return vim.notify('Not in a git repository', vim.log.levels.WARN)
    end
    local paths = vim.fn.systemlist({ 'git', '-C', root, 'diff', '--name-only', review.base or 'HEAD' })
    vim.list_extend(paths, vim.fn.systemlist({ 'git', '-C', root, 'ls-files', '--others', '--exclude-standard' }))
    local items = vim.tbl_map(function(path)
        return vim.fn.fnamemodify(root .. '/' .. path, ':.')
    end, paths)
    require('mini.pick').start({ source = { items = items, name = 'Changed files' } })
end

-- Every hunk still in the list, to jump to one. The items carry the position
-- as well as a path and line, so the default preview shows the file there.
local function hunk_picker()
    local info = list_info()
    if not info or info.size == 0 then
        return say('No hunks left: q stops the review')
    end
    local items = {}
    for i, entry in ipairs(list_items()) do
        local path = vim.fn.fnamemodify(vim.fn.bufname(entry.bufnr), ':.')
        table.insert(items, {
            idx = i,
            path = path,
            lnum = entry.lnum,
            text = ('%s:%d  %s'):format(path, entry.lnum, entry.text),
        })
    end
    require('mini.pick').start({
        source = {
            name = ('Hunks (%d)'):format(#items),
            items = items,
            choose = function(item)
                vim.schedule(function()
                    goto_entry(item.idx)
                end)
            end,
        },
    })
end

-- What to compare with: HEAD, BASE, the branches, tags and recent commits.
local function base_picker()
    require('mini.pick').start({
        source = {
            name = 'Review against',
            items = gitrev.picker_items(),
            choose = function(item)
                vim.schedule(function()
                    review_start(item.ref)
                end)
            end,
        },
    })
end

-- Throw the list away and build it from what the repository says now.
local function rebuild()
    if not review.on then
        return
    end
    build_list(review.generation, function()
        local nr = list_nr()
        if nr then
            vim.cmd(nr .. 'chistory')
        end
        if #list_items() > 0 then
            goto_entry(1)
        end
        vim.cmd.redrawstatus()
    end)
end

-- Into the mode, starting the review first if there is not one.
local function enter()
    if review.on then
        return modal.enter('review')
    end
    review_start(nil, { enter = true })
end

-- The picker keys leave the mode and start the picker afterwards: a picker
-- reads keys with a loop of its own, and one started from inside this mode's
-- loop would run nested in it.
local function later(fn)
    return function()
        vim.schedule(fn)
    end
end

modal.define('review', {
    desc = 'Review the diff, hunk by hunk',
    entry = '<leader>r',
    open = enter,
    hint = 'j/k hunk · Tab/S-Tab file · d drop · u undo · l list · / hunks · f files · b base · s side-by-side · q stop',
    -- Long, because it is a mode for reading: a hunk takes as long as it takes,
    -- and having the keys turn back into ordinary ones mid-sentence is worse
    -- than a mode left on for a while, which the statusline shows.
    idle = 30000,
    pass = { '<C-d>', '<C-u>', '<C-e>', '<C-y>', '<C-f>', '<C-b>' },
    keys = {
        { { 'j', '<Down>' }, step(1), desc = 'Next hunk' },
        { { 'k', '<Up>' }, step(-1), desc = 'Previous hunk' },
        { '<Tab>', by_file(1), desc = 'First hunk of the next file' },
        { '<S-Tab>', by_file(-1), desc = 'First hunk of the previous file' },
        { 'd', drop, desc = 'Done with this hunk: drop it, and go to the next' },
        { 'u', undrop, desc = 'Bring back the hunk dropped last' },
        { 'l', toggle_list_window, desc = 'Show or hide the list of hunks' },
        { 's', toggle_layout, desc = 'Inline, or side by side' },
        { 'p', function() gitsigns.preview_hunk_inline() end, desc = 'Preview this hunk inline' },
        { 'R', rebuild, desc = 'Start over: every hunk again' },
        { '/', later(hunk_picker), desc = 'Pick a hunk from the list', leave = true },
        { 'f', later(changed_files), desc = 'Pick a changed file', leave = true },
        { 'b', later(base_picker), desc = 'Pick what to compare with', leave = true },
        { 'q', review_stop, desc = 'Stop reviewing', leave = true },
    },
})

registry.command('Review', function(opts)
    if opts.bang then
        review_stop()
    else
        review_start(opts.args ~= '' and opts.args or nil)
    end
end, {
    nargs = '?',
    bang = true,
    desc = 'Review the working tree against HEAD, BASE, BASE:<branch>, a branch, a tag or a commit; ! to stop',
    complete = function(lead)
        return gitrev.complete(lead)
    end,
})

return {
    state = review,
    start = review_start,
    stop = review_stop,
    enter = enter,
    status = status,
    layout = review_layout,
    changed_files = changed_files,
    -- For the tests, which drive the steps without typing them.
    step = step,
    by_file = by_file,
    drop = drop,
    undrop = undrop,
    rebuild = rebuild,
    list_info = list_info,
    list_items = list_items,
}
