-- Saving and reloading: what makes a buffer follow its file without being
-- asked. Writes happen when focus leaves, formatting happens on every write,
-- and a change made elsewhere is picked up -- or, when both sides changed,
-- flagged rather than overwritten.

local augroup = require('ide.group')

-- A buffer with unsaved edits whose file also changed on disk is flagged
-- `disk_changed` (see FileChangedShell below), and is not written until the
-- user has chosen: :e! for the disk's version, :w! for the buffer's.
local function write_if_possible()
    if not vim.bo.modifiable then
        return
    end

    local name = vim.api.nvim_buf_get_name(0)

    if name == "" then
        return
    end

    if vim.b.disk_changed then
        return
    end

    if vim.fn.filewritable(name) == 1 then
        vim.cmd.write()
    end
end

-- Not while a review is on. The buffer is being read against a revision, and a
-- write that reformats it -- autosave writes on every focus change -- puts
-- changes of its own into the diff being read, so the hunks stop being the
-- ones that were made. Writing still happens; only the formatter is held off,
-- until the review ends and the next write catches the file up.
--
-- The review module is looked at through package.loaded rather than required:
-- it is loaded after this one, and requiring it from here would pull gitsigns
-- in at startup for a question whose answer is "no" nearly always.
vim.api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    callback = function()
        if not vim.bo.modifiable then
            return
        end

        if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
            return
        end

        local review = package.loaded['ide.review']
        if review and review.state.on then
            return
        end

        -- `:Toggle format`.
        if vim.g.ide_format == false then
            return
        end

        vim.lsp.buf.format()
    end,
})

-- `:Toggle autosave` is vim.g.ide_autosave. It switches off the writes that
-- happen by themselves -- these two -- and not write_if_possible, which
-- <leader>ww also calls: asking for a write must work whatever is switched off.
local function autosave()
    if vim.g.ide_autosave ~= false then
        write_if_possible()
    end
end

vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = autosave,
})

vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    callback = autosave,
})

-- 'autoread' alone only reloads when something runs :checktime, and nothing
-- does by itself; these are the moments a file changed elsewhere (an agent,
-- git checkout) gets picked up. CursorHold is why 'updatetime' is down to
-- 1000: at the default 4000 a buffer stayed stale long enough to edit it
-- and collide on save. Not from the command-line window, where
-- :checktime is an error.
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = augroup,
    callback = function()
        if vim.fn.getcmdwintype() == '' then
            vim.cmd.checktime()
        end
    end,
})

-- Autosaving over a change made elsewhere is how an agent's edit or a git
-- checkout gets lost. 'autoread' reloads only a buffer without edits of its
-- own; when the buffer has some, nvim warns (W12) and leaves both versions, and
-- the next FocusLost or BufLeave write then asks "do you really want to write"
-- -- a question that comes up while the window is not even in front. Here the
-- buffer is flagged instead, which write_if_possible honours, and the choice
-- is said once. Only the conflict is taken over: any other reason is left to
-- nvim's own handling ('ask' is "as if there were no autocommand").
--
-- Closing the choice: :e! reads the disk's version, :w! writes the buffer's.
-- Both are noticed below (BufReadPost, BufWritePost) and clear the flag.
vim.api.nvim_create_autocmd("FileChangedShell", {
    group = augroup,
    callback = function(args)
        if vim.v.fcs_reason ~= "conflict" then
            vim.v.fcs_choice = "ask"
            return
        end
        vim.v.fcs_choice = ""
        vim.b[args.buf].disk_changed = true
        local name = vim.fn.fnamemodify(args.file, ":~:.")
        vim.schedule(function()
            vim.notify(name .. " changed on disk and in nvim, so it is not autosaved. "
                .. ":e! takes the disk's version, :w! keeps this one.", vim.log.levels.WARN)
        end)
    end,
})

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = augroup,
    callback = function(args)
        vim.b[args.buf].disk_changed = nil
    end,
})

return { write = write_if_possible }
