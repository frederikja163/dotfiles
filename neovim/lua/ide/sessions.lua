local augroup = require('ide.group')

-- Sessions
--
-- Sessions are global files named after the working directory, never a
-- Session.vim beside the code: everything edited here is a git checkout, and
-- a session file in the tree is one more thing to gitignore in every repo.
-- That is why `file` is disabled below rather than left at its default.
--
-- mini.sessions' own `autoread` is deliberately off. With no local
-- Session.vim to find it falls back to the most recently written *global*
-- session, so a bare nvim in one project reopens a different project's
-- windows. The autocommands below key on the working directory instead.
--
-- Opening a directory takes part, in both directions; opening a file does
-- not, so reading one file cannot replace the session for its project -- the
-- usual way an autosaving session manager loses a layout.
--
-- A directory means `nvim` with no arguments, and equally `nvim <dir>`: that
-- is what bin/ide runs as `exec nvim .`, and behind SUPER+I it is the main
-- way a project gets opened here. Keying only on a bare `nvim` looked right
-- and restored nothing in practice.
vim.pack.add({ { src = "https://github.com/nvim-mini/mini.sessions" } })
local sessions = require('mini.sessions')
sessions.setup({
    autoread = false,
    autowrite = false,
    file = '',
})

-- The directory this session belongs to, or nil if this start is not one.
local function session_dir()
    local args = vim.fn.argv()

    if #args > 1 then
        return nil
    end

    if #args == 1 then
        if vim.fn.isdirectory(args[1]) == 0 then
            return nil
        end
        -- normalize also trims the trailing slash that `:p` puts on a
        -- directory, so `nvim .` and a bare `nvim` agree on the name.
        return vim.fs.normalize(vim.fn.fnamemodify(args[1], ':p'))
    end

    if vim.api.nvim_buf_get_name(0) ~= '' then
        return nil
    end
    -- Piped input (`cmd | nvim -`) is already in the first buffer by VimEnter
    -- and leaves no argument or name behind to notice it by.
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines > 1 or (lines[1] or '') ~= '' then
        return nil
    end

    return vim.fs.normalize(vim.fn.getcwd())
end

-- Settled at VimEnter and reused on the way out, rather than worked out twice:
-- a session that restores with `cd` in it, or any `:cd` during the session,
-- would otherwise be written back under a different name than it was read by.
local session_key = nil

vim.api.nvim_create_autocmd("VimEnter", {
    group = augroup,
    nested = true, -- so restored buffers still fire FileType, and LSPs attach
    callback = function()
        local dir = session_dir()
        if not dir then
            return
        end
        session_key = (dir:gsub('/', '%%'))
        if sessions.detected[session_key] then
            sessions.read(session_key, { verbose = false })
        end
    end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
        if session_key then
            sessions.write(session_key, { verbose = false })
        end
    end,
})

-- Starting over: `:Forget` quits and `:Fresh` restarts, and both leave this
-- directory with no session, so the next start opens on an empty layout.
--
-- Clearing `session_key` is what stops VimLeavePre writing the layout back
-- the moment the file is gone. The file is deleted by path rather than with
-- sessions.delete(), which only knows the sessions it detected at startup
-- and errors outright when there were none.
--
-- `:restart!` rather than `:restart`: without the bang nvim saves and
-- restores a session of its own, which would bring the layout straight back.
-- The new instance gets the same argv, so `nvim .` from bin/ide still lands
-- on this directory and goes on to save a new session when it quits.
--
-- If the quit is refused -- an unsaved buffer, a running terminal job --
-- the key is put back, so quitting normally afterwards saves the layout as
-- before instead of silently leaving no session. The refusal is not
-- reported here: vim shows its own E37 even through the pcall.
local function forget_session(quit)
    local key = session_key
    if key then
        vim.fn.delete(vim.fs.joinpath(sessions.config.directory, key))
        sessions.detected[key] = nil
        vim.v.this_session = ''
        session_key = nil
    end
    if not pcall(vim.cmd, quit) then
        session_key = key
    end
end

require('ide.registry').command('Forget', function()
    forget_session('qall')
end, { desc = "Quit and delete this directory's session" })

require('ide.registry').command('Fresh', function()
    forget_session('restart!')
end, { desc = "Restart with this directory's session deleted" })

return {
    select = function()
        sessions.select()
    end,
}
