-- Debugging C#: build, launch under a debugger, stop at a breakpoint, step, look
-- at values. The verb is <leader>D, which enters a mode (ide.modal), and the same
-- things are :Debug, :DebugAttach and :Breakpoints.
--
-- Two pieces do the work. nvim-dap is the client: Neovim has no Debug Adapter
-- Protocol client of its own, and this is the only plugin in the config that is
-- not there to avoid writing something -- there is nothing smaller to write.
-- netcoredbg is the adapter. It is Samsung's open debugger for .NET, and the
-- alternative is vsdbg, which Microsoft licenses for use in its own products only
-- and which the C# extension for VS Code downloads at runtime for that reason.
-- netcoredbg is in the AUR (packages/aur.txt) and is looked for on PATH.
--
-- nvim-dap-ui, which most guides add, is not used. nvim-dap's own widgets
-- (dap.ui.widgets) show the variables, the call stack and a value under the
-- cursor, and the REPL it opens is where the program's output goes (below), which
-- covers what that plugin's windows would show for one more dependency and a
-- layout of its own to keep in step with this one.
--
-- What a launch is.
--
-- Debugging runs the program that was built, so the project is built first, the
-- way Rider does it, and nothing is launched if that fails (the errors are in the
-- quickfix list, as for :Build). Which program that is, and what its
-- launchSettings.json says to run it with, is ide.launch's business. `:Debug
-- <name>` picks a profile other than the default.
--
-- Which project: the one the current file belongs to, as for :Run, and not the
-- solution. A solution has no program.
--
-- What it cannot do, found by running it.
--
--   * The program's input. netcoredbg does not ask the editor for a terminal (the
--     DAP request for one, runInTerminal, is not in it, and `console =
--     "integratedTerminal"` is silently ignored), so a program's output is sent to
--     the editor as events and its input has nowhere to come from: a program that
--     reads from the console waits for ever. Its output is shown in nvim-dap's
--     REPL, which is opened below when a session begins. For a program that needs
--     input, run it (:Run) and attach to it.
--   * Attaching to a program that is not the debugger's own. The kernel allows a
--     process to be debugged only by its parent, unless
--     kernel.yama.ptrace_scope is 0, and it is 1 on a stock Arch kernel. An attach
--     that is refused says so; changing the setting is a decision for the person
--     who owns the machine and is not made here.
--   * Logpoints and hit counts. netcoredbg does not list them among what it can do
--     (supportsLogPoints and supportsHitConditionalBreakpoints are absent from its
--     answer to `initialize`), so a logpoint is sent to it as a plain breakpoint and
--     stops the program: the opposite of what one is for. There is no key for one
--     rather than a key that does that. A condition is supported, and `B` with
--     `i == 3` is how to stop the third time round.
--   * Breakpoints are not kept between sessions of the editor. nvim-dap holds them
--     in memory.
--
-- The mode. h, j and k are left, down and up everywhere in this config, and here
-- they walk the program: j steps over the line (down), l into the call (in), h out
-- of it (back out), as they walk hunks in review. Stepping backwards is not
-- something netcoredbg can do, so k is free and is not used: it is a key that ends
-- the mode and moves the cursor, like any other the mode does not own. Counts are
-- not used either: five steps over would be five requests that each have to wait
-- for the program to stop, and the number is not worth the state that needs.
-- Leaving the mode leaves the session as it is; q stops it.
--
-- Finishing. The REPL and the sidebars are windows with no file, and a session
-- file remembers a window as a split: a project opened tomorrow would have an empty
-- one where they were. So when the editor quits the session is ended, with the
-- program killed if it was launched here and left alone if it was attached to, and
-- those windows are closed first. That is why this module is loaded before
-- ide.sessions, whose VimLeavePre writes the file.

local group = require('ide.group')
local modal = require('ide.modal')
local registry = require('ide.registry')
local dotnet = require('ide.dotnet')
local launch = require('ide.launch')

-- Upstream is also on Codeberg, at the same commit; this is the mirror, so that
-- every plugin comes from one place.
vim.pack.add({ { src = 'https://github.com/mfussenegger/nvim-dap' } })

local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

local function notify(text, level)
    vim.notify(text, level or vim.log.levels.INFO)
end

local state = {
    ready = false,
    token = nil,
    sidebars = {},
}

----------------------------------------------------------------------------
-- The client
----------------------------------------------------------------------------

local SIGNS = {
    DapBreakpoint = { text = '●', texthl = 'DiagnosticError' },
    DapBreakpointCondition = { text = '◆', texthl = 'DiagnosticWarn' },
    DapLogPoint = { text = '◆', texthl = 'DiagnosticInfo' },
    DapBreakpointRejected = { text = '○', texthl = 'DiagnosticHint' },
    DapStopped = { text = '▶', texthl = 'DiagnosticOk', linehl = 'Visual' },
}

-- Everything that needs nvim-dap goes through here, so that the plugin is not
-- loaded until a key that needs it is pressed: most sessions of the editor never
-- debug anything.
local function ensure()
    local dap = require('dap')
    if state.ready then
        return dap
    end
    state.ready = true
    dap.adapters.coreclr = { type = 'executable', command = 'netcoredbg', args = { '--interpreter=vscode' } }
    for name, definition in pairs(SIGNS) do
        vim.fn.sign_define(name, definition)
    end

    -- The statusline says whether a session is running or stopped, which it can
    -- only say if it is drawn again when that changes.
    local function redraw()
        vim.schedule(function()
            pcall(vim.cmd.redrawstatus)
        end)
    end
    for _, event in ipairs({ 'initialized', 'stopped', 'continued', 'terminated', 'exited' }) do
        dap.listeners.after['event_' .. event]['ide.status'] = redraw
    end
    dap.listeners.after.disconnect['ide.status'] = redraw

    -- Where the program's output goes, since it is not given a terminal (see the
    -- top). Opened when a session has begun, not when one is asked for, so that
    -- an attach that is abandoned at the process picker leaves nothing behind.
    dap.listeners.after.event_initialized['ide.repl'] = function()
        if vim.fn.bufwinid('dap-repl') ~= -1 then
            return
        end
        local origin = vim.api.nvim_get_current_win()
        pcall(dap.repl.open, { height = 12 }, 'belowright split')
        if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
        end
    end
    return dap
end

--- Whether a session is going, and if so whether the program is stopped.
---@return 'stopped'|'running'|nil
function M.status()
    local dap = package.loaded['dap']
    local session = dap and dap.session()
    if not session then
        return nil
    end
    return session.stopped_thread_id and 'stopped' or 'running'
end

local function netcoredbg_here()
    if vim.fn.executable('netcoredbg') == 1 then
        return true
    end
    notify('netcoredbg is not installed. It is in packages/aur.txt: run ./install.sh packages', WARN)
    return false
end

--- Build the project of this file and run it under the debugger.
---@param profile_name? string  a launch profile, by name
function M.start(profile_name)
    local dap = ensure()
    if dap.session() then
        return notify('Already debugging: c continues, q stops it')
    end
    if not netcoredbg_here() then
        return
    end
    local target = dotnet.target(vim.api.nvim_buf_get_name(0), 'project')
    if not target or target.kind ~= 'project' then
        return notify('No project above this file', WARN)
    end
    local name = vim.fn.fnamemodify(target.path, ':t:r')

    -- A start is replaced by the next one, not refused: a flag that said "one is
    -- going" would stay set for ever if the build were replaced or stopped, and
    -- there is no moment at which it could be cleared.
    local token = {}
    state.token = token

    dotnet.build('project', function(built)
        if not built or state.token ~= token then
            return
        end
        launch.find_program(target.path, function(found, err)
            if state.token ~= token then
                return
            end
            if not found then
                return notify('Could not tell what to run: ' .. err, ERROR)
            end
            if found.kind ~= 'Exe' and found.kind ~= 'WinExe' then
                return notify(('%s is a library, not a program: open a file of a project that runs'):format(name), WARN)
            end
            if not vim.uv.fs_stat(found.program) then
                return notify('The build did not make ' .. found.program, ERROR)
            end

            local config = {
                type = 'coreclr',
                request = 'launch',
                name = name,
                program = found.program,
                cwd = target.dir,
                stopAtEntry = false,
            }
            local profile_note = ''
            local settings = vim.fs.joinpath(target.dir, 'Properties', 'launchSettings.json')
            if vim.uv.fs_stat(settings) then
                local list, problem = launch.parse_profiles(table.concat(vim.fn.readfile(settings), '\n'))
                if not list then
                    notify(problem .. ': ' .. settings .. '; starting without a profile', WARN)
                else
                    local entry, missing = launch.choose_profile(list, profile_name)
                    if missing then
                        return notify(missing, ERROR)
                    end
                    if entry then
                        local options = launch.launch_options(entry, target.dir)
                        config.env, config.cwd = options.env, options.cwd
                        config.args = #options.args > 0 and options.args or nil
                        profile_note = (' with the "%s" profile'):format(entry.name)
                    elseif profile_name and profile_name ~= '' then
                        return notify('No launch profile called ' .. profile_name, ERROR)
                    end
                end
            elseif profile_name and profile_name ~= '' then
                return notify(('%s has no launchSettings.json, so no profile called %s'):format(name, profile_name), WARN)
            end

            notify(('Debugging %s%s'):format(name, profile_note))
            dap.run(config)
        end)
    end)
end

--- Debug a program that is already running, chosen from the processes.
function M.attach()
    local dap = ensure()
    if dap.session() then
        return notify('Already debugging: q stops it')
    end
    if not netcoredbg_here() then
        return
    end
    dap.run({
        type = 'coreclr',
        request = 'attach',
        name = 'Attach to a process',
        processId = function()
            return require('dap.utils').pick_process()
        end,
    })
end

--- End the session. A program that was started here is stopped; one that was
--- attached to is let go and left running, which is what was wanted of it.
function M.stop()
    local dap = package.loaded['dap']
    local session = dap and dap.session()
    if not session then
        return notify('Not debugging')
    end
    if session.config and session.config.request == 'attach' then
        dap.disconnect({ terminateDebuggee = false })
    else
        dap.terminate()
    end
end

----------------------------------------------------------------------------
-- The keys of the mode
----------------------------------------------------------------------------

-- A step, if there is a session to take it in.
local function stepper(name)
    return function()
        local dap = ensure()
        if not dap.session() then
            return notify('Not debugging: c starts the project of this file')
        end
        dap[name]()
    end
end

local function continue()
    local dap = ensure()
    local session = dap.session()
    if not session then
        return M.start()
    end
    if not session.stopped_thread_id then
        return notify('Running: p pauses it')
    end
    dap.continue()
end

local function pause()
    local dap = ensure()
    if not dap.session() then
        return notify('Not debugging')
    end
    dap.pause()
end

local function toggle_breakpoint()
    ensure().toggle_breakpoint()
end

local function ask(prompt, apply)
    vim.ui.input({ prompt = prompt }, function(answer)
        if answer and answer ~= '' then
            apply(answer)
        end
    end)
end

local function conditional_breakpoint()
    local dap = ensure()
    ask('Break when: ', function(condition)
        dap.set_breakpoint(condition)
    end)
end

local function run_to_cursor()
    local dap = ensure()
    if not dap.session() then
        return notify('Not debugging: c starts the project of this file')
    end
    dap.run_to_cursor()
end

-- The value of what is under the cursor, in a float next to it.
--
-- nvim-dap's float takes focus and never closes by itself: it is a window to
-- expand a structure in, and left alone it stays over the code for ever. Here it
-- is a look, which is what a step is usually followed by, so focus goes back to
-- the code and the float is closed by the next movement of the cursor -- which a
-- step makes, when the program stops somewhere else. To explore a structure, the
-- variables sidebar (s) is a tree that can be walked, and <C-l> goes into it.
local function evaluate()
    local dap = ensure()
    if not dap.session() then
        return notify('Not debugging')
    end
    local origin = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_win_get_buf(origin)
    local view = require('dap.ui.widgets').hover()
    local float = view and view.win
    if vim.api.nvim_win_is_valid(origin) then
        vim.api.nvim_set_current_win(origin)
    end
    if float then
        vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave' }, {
            group = group,
            buffer = origin_buf,
            once = true,
            callback = function()
                if vim.api.nvim_win_is_valid(float) then
                    pcall(vim.api.nvim_win_close, float, true)
                end
            end,
        })
    end
end

local function frame(direction)
    return function()
        local dap = ensure()
        if not dap.session() then
            return notify('Not debugging')
        end
        dap[direction]()
    end
end

-- A sidebar is made once and toggled, and focus stays where it was: it is
-- something to look at while stepping, and stepping happens in the code.
local function sidebar(key, widget_name)
    return function()
        ensure()
        local widgets = require('dap.ui.widgets')
        local bar = state.sidebars[key]
        if not bar then
            bar = widgets.sidebar(widgets[widget_name], { width = 48 }, 'belowright vsplit')
            state.sidebars[key] = bar
        end
        local origin = vim.api.nvim_get_current_win()
        bar.toggle()
        if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
        end
    end
end

local function repl()
    ensure().repl.toggle({ height = 12 }, 'belowright split')
end

-- Run after the mode has ended: a picker reads keys with a loop of its own, and
-- one started inside the mode's loop would run nested in it.
local function later(fn)
    return function()
        vim.schedule(fn)
    end
end

modal.define('debug', {
    desc = 'Debug the program, step by step',
    entry = '<leader>D',
    hint = 'j over · l into · h out · c continue or start · b breakpoint · r to cursor · u/d stack · K value · s vars · f stack list · q stop',
    -- As long as review's, for the same reason: it is a mode for reading, and the
    -- program being looked at does not stop to be looked at.
    idle = 30000,
    keys = {
        { { 'j', '<Down>' }, stepper('step_over'), desc = 'Step over this line' },
        { { 'l', '<Right>' }, stepper('step_into'), desc = 'Step into the call' },
        { { 'h', '<Left>' }, stepper('step_out'), desc = 'Step out of this function' },
        { 'c', continue, desc = 'Continue; or build and start the project of this file' },
        { 'p', pause, desc = 'Pause the running program' },
        { 'r', run_to_cursor, desc = 'Run to the line the cursor is on' },
        { 'b', toggle_breakpoint, desc = 'Toggle a breakpoint on this line' },
        { 'B', conditional_breakpoint, desc = 'Breakpoint on this line that stops only when a condition is true' },
        { 'u', frame('up'), desc = 'Up the call stack, to the caller' },
        { 'd', frame('down'), desc = 'Down the call stack, back toward where it stopped' },
        { 'K', evaluate, desc = 'Show the value of the expression under the cursor' },
        { 's', sidebar('scopes', 'scopes'), desc = 'Show or hide the variables' },
        { 'f', sidebar('frames', 'frames'), desc = 'Show or hide the call stack' },
        { 'R', repl, desc = 'Show or hide the REPL: the output, and expressions to evaluate', leave = true },
        { 'a', later(M.attach), desc = 'Attach to a running program', leave = true },
        { 'q', M.stop, desc = 'Stop debugging, and leave', leave = true },
    },
})

----------------------------------------------------------------------------
-- Breakpoints
----------------------------------------------------------------------------

--- Every breakpoint there is, in a picker; with `clear`, remove them all.
---@param clear? boolean
function M.breakpoints(clear)
    local dap = package.loaded['dap']
    if clear then
        if dap then
            dap.clear_breakpoints()
        end
        return notify('Breakpoints cleared')
    end
    local items = {}
    for buf, list in pairs(dap and require('dap.breakpoints').get() or {}) do
        local path = vim.api.nvim_buf_get_name(buf)
        for _, bp in ipairs(list) do
            local code = vim.api.nvim_buf_get_lines(buf, bp.line - 1, bp.line, false)[1] or ''
            local extra = bp.condition and ('   when %s'):format(bp.condition) or ''
            table.insert(items, {
                path = path,
                lnum = bp.line,
                text = ('%s:%d  %s%s'):format(vim.fn.fnamemodify(path, ':.'), bp.line, vim.trim(code), extra),
            })
        end
    end
    if #items == 0 then
        return notify('No breakpoints')
    end
    table.sort(items, function(a, b)
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.lnum < b.lnum
    end)
    require('mini.pick').start({ source = { name = ('Breakpoints (%d)'):format(#items), items = items } })
end

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

local function profile_names()
    local target = dotnet.target(vim.api.nvim_buf_get_name(0), 'project')
    local file = target and vim.fs.joinpath(target.dir, 'Properties', 'launchSettings.json')
    if not (file and vim.uv.fs_stat(file)) then
        return {}
    end
    local list = launch.parse_profiles(table.concat(vim.fn.readfile(file), '\n')) or {}
    return vim.tbl_map(function(entry) return entry.name end, list)
end

registry.command('Debug', function(opts)
    if opts.bang then
        return M.stop()
    end
    M.start(vim.trim(opts.args))
end, {
    nargs = '*',
    bang = true,
    desc = 'Build the project of this file and debug it, with a launchSettings profile if you name one; ! ends the session',
    complete = function(lead)
        return vim.tbl_filter(function(name)
            return vim.startswith(name, lead)
        end, profile_names())
    end,
})

registry.command('DebugAttach', M.attach, {
    desc = 'Debug a program that is already running, chosen from the processes',
})

registry.command('Breakpoints', function(opts)
    M.breakpoints(opts.bang)
end, {
    bang = true,
    desc = 'Every breakpoint, in a picker to go to one; ! removes them all',
})

----------------------------------------------------------------------------
-- Leaving
----------------------------------------------------------------------------

--- End the session, close what only a session needs, and leave nothing for a
--- session file to remember. Quick when there is nothing to do, which is nearly
--- always: it does not load nvim-dap to find out.
function M.shutdown()
    local dap = package.loaded['dap']
    if not dap then
        return
    end
    for key, bar in pairs(state.sidebars) do
        pcall(bar.close)
        state.sidebars[key] = nil
    end
    pcall(dap.repl.close)
    local session = dap.session()
    if session then
        if session.config and session.config.request == 'attach' then
            dap.disconnect({ terminateDebuggee = false })
        else
            dap.terminate()
        end
        vim.wait(2000, function()
            return dap.session() == nil
        end, 20)
    end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = M.shutdown,
})

return M
