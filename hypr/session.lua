-- What was open, and where, across a restart.
--
-- Wayland has no session protocol: nothing hands a window back to the program
-- that had it, and Hyprland forgets everything when it exits. So this is a
-- snapshot and a relaunch, not a restore in the strict sense. It writes down
-- the desktops, which screen each belongs to, and the command line of every
-- window's process; at the next login it recreates the desktops and starts
-- those command lines again in them.
--
-- What comes back therefore is: the desktops, on the right screens, each
-- keeping its number; the quake terminal of each, in the directory its shell
-- was in, which is also what the desktop is called on the bar; and one window
-- per process, with kitty back in the right directory and Rider back on the
-- right solution.
--
-- What does not, and cannot from here: scrollback, whatever command was
-- running, editor buffers, and window geometry -- the columns are rebuilt by
-- columns.lua from the order the windows arrive in, so a desktop comes back
-- with its windows but not necessarily in its old shape. Programs that keep one
-- process for many windows (Firefox is one pid for all of its) are launched
-- once and left to restore their own windows, which they are better at than
-- this file could be.
--
-- Written as one line per record, tab separated, into
-- ~/.local/share/hypr/session -- machine-local state like the pinned monitor
-- order next to it, not something to be committed. A text format because it
-- has to be readable when a login goes wrong, and because the alternative is
-- writing a JSON encoder in Lua to be read back by a Lua parser.
--
--   desktop <id> <0|1 kept open while empty> <screen identity>
--   title   <id> <name given to it with bin/title>
--   quake   <id> <directory>
--   window  <id> <directory> <argv0> <argv1> ...
--   focus   <id>
--
-- Two rules keep this from eating the thing it is meant to protect:
--
-- The file is read into memory once, at config load, and the restore works
-- from that copy. So a snapshot written before the restore has run -- or
-- during it -- cannot take the session with it.
--
-- Nothing is written until the restore has been done, or has been declined.
-- bin/dotfiles-session-restore is what says so, and if it never runs (it is
-- not started in the sandbox) this file writes nothing at all for the rest of
-- the session. The failure direction is deliberate: a session that was not
-- restored is a session that must not be overwritten.

local monitorpin = require("monitorpin")
local deskbinds  = require("deskbinds")
local quake      = require("quake")
local programs   = require("programs")

local terminal = programs.terminal

local function state_path()
    local data = os.getenv("XDG_DATA_HOME")
    if not data or data == "" then
        data = (os.getenv("HOME") or "") .. "/.local/share"
    end
    -- Overridable so the tests, and a nested instance, can point somewhere
    -- harmless.
    return os.getenv("HYPR_SESSION") or (data .. "/hypr/session")
end

local PATH = state_path()

-- A nested instance must not write down its own two windows as *the* session:
-- the next real login would then put the sandbox back instead of the desktop.
-- tests/sandbox.sh points HYPR_SESSION at a scratch file for exactly this
-- reason, and this is the lock behind that -- without an explicit path of its
-- own, a nested instance keeps its session to itself and writes nothing.
--
-- Not hypothetical: it took the real file once, while this was being written.
local NESTED = os.getenv("HYPR_SANDBOX") == "1" and not os.getenv("HYPR_SESSION")

-- Where the process table is. Only ever /proc on this machine; a variable so
-- the tests can lay out a handful of fake processes and check what is written
-- down for them.
local PROC = os.getenv("HYPR_PROC") or "/proc"

-- How long to wait after a change before writing. Opening a window is several
-- events, and a burst of title changes is how a `cd` is noticed, so this
-- coalesces rather than writing once per event.
local WRITE_DELAY = 3000

-- Between two relaunches at login. Serial on purpose: a dozen programs started
-- in the same millisecond is a thundering herd on a machine that has just
-- booted, and the order windows arrive in is the order columns.lua puts them
-- in, which a race would scramble.
local LAUNCH_DELAY = 400

-- Refuse to relaunch more than this. A file that has grown absurd is a bug in
-- here, and it should not be able to fork-bomb a login.
local LAUNCH_LIMIT = 40

-- Saving is off until something says the restore is settled, see the header.
local armed = false

-- ---------------------------------------------------------------------------
-- Reading the file

local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        table.insert(fields, field)
    end
    return fields
end

local function load_file()
    local saved = { desktops = {}, titles = {}, quake = {}, windows = {}, focus = nil }

    local file = io.open(PATH, "r")
    if not file then
        return saved
    end

    for line in file:lines() do
        local fields = split(line)
        local kind = fields[1]

        if kind == "desktop" then
            local id = tonumber(fields[2])
            if id then
                table.insert(saved.desktops, {
                    id         = id,
                    persistent = fields[3] == "1",
                    -- Empty rather than absent for a screen with no identity,
                    -- which is what an unnamed headless output looks like.
                    identity   = fields[4] ~= "" and fields[4] or nil,
                })
            end
        elseif kind == "title" then
            -- Keyed by desktop rather than appended in order: a title belongs
            -- to the desktop record above it, and only desktops that are put
            -- back have any use for one.
            local id = tonumber(fields[2])
            if id and fields[3] and fields[3] ~= "" then
                saved.titles[id] = fields[3]
            end
        elseif kind == "quake" then
            local id = tonumber(fields[2])
            if id and fields[3] and fields[3] ~= "" then
                table.insert(saved.quake, { desktop = id, cwd = fields[3] })
            end
        elseif kind == "window" then
            local id = tonumber(fields[2])
            local argv = {}
            for i = 4, #fields do
                if fields[i] ~= "" then
                    table.insert(argv, fields[i])
                end
            end
            if id and #argv > 0 then
                table.insert(saved.windows, {
                    desktop = id,
                    cwd     = fields[3] ~= "" and fields[3] or nil,
                    argv    = argv,
                })
            end
        elseif kind == "focus" then
            saved.focus = tonumber(fields[2])
        end
    end
    file:close()

    return saved
end

-- The session as it was at login, read before anything can overwrite it.
local saved = load_file()

-- ---------------------------------------------------------------------------
-- Writing the file

-- One shell for the whole snapshot rather than one per window: bin/proc-cwd
-- takes every pid at once. Lua cannot read a symlink, which is what
-- /proc/<pid>/cwd is, so this cannot be done with io.open.
local function cwds_of(pids)
    local answers = {}
    if #pids == 0 then
        return answers
    end

    local pipe = io.popen("proc-cwd " .. table.concat(pids, " ") .. " 2>/dev/null")
    if not pipe then
        return answers
    end
    for line in pipe:lines() do
        local pid, cwd = line:match("^(%d+)\t(.+)$")
        if pid then
            answers[tonumber(pid)] = cwd
        end
    end
    pipe:close()

    return answers
end

local function argv_of(pid)
    local file = io.open(("%s/%d/cmdline"):format(PROC, pid), "rb")
    if not file then
        return nil
    end
    local raw = file:read("*a") or ""
    file:close()

    local argv = {}
    for arg in raw:gmatch("([^%z]+)") do
        table.insert(argv, arg)
    end
    return #argv > 0 and argv or nil
end

-- A tab or a newline in a field would be read back as a field boundary, so a
-- record carrying one is dropped rather than written and misparsed later. Paths
-- and command lines can technically contain either; in practice this never
-- fires, and a missing window beats a corrupt file.
local function writable(fields)
    for _, field in ipairs(fields) do
        if tostring(field):find("[\t\n]") then
            return false
        end
    end
    return true
end

local function record(lines, fields)
    if writable(fields) then
        table.insert(lines, table.concat(fields, "\t"))
    end
end

-- Which screen each monitor id is, by identity. Taken from get_monitors()
-- rather than from a workspace's own monitor field, which carries the name but
-- not the description the identity is built from.
local function screens()
    local by_id = {}
    for _, mon in ipairs(hl.get_monitors() or {}) do
        by_id[mon.id] = monitorpin.identity(mon)
    end
    return by_id
end

local function snapshot()
    local lines = {}
    local identity_of = screens()

    -- Desktops, lowest id first, so they are put back in the same order and
    -- end up numbered the same way on the bar.
    local desktops = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if not ws.special then
            table.insert(desktops, ws)
        end
    end
    table.sort(desktops, function(a, b) return a.id < b.id end)

    for _, ws in ipairs(desktops) do
        record(lines, {
            "desktop",
            ws.id,
            deskbinds.is_persistent(ws.id) and "1" or "0",
            (ws.monitor and identity_of[ws.monitor.id]) or "",
        })

        -- A name given with bin/title, which is a decision about what the
        -- desktop is *for* and so outlives the session that made it. Nothing
        -- else can reconstruct it: unlike the directory below, a title has no
        -- source to be read back from.
        local title = deskbinds.title_of(ws.id)
        if title then
            record(lines, { "title", ws.id, title })
        end

        -- The terminal's directory is what the desktop is called and where
        -- SUPER+Q opens the next one, so it is the one piece of a desktop worth
        -- keeping beyond its windows.
        local cwd = quake.cwd_for(ws.id)
        if cwd then
            record(lines, { "quake", ws.id, cwd })
        end
    end

    -- Windows, in the order Hyprland lists them, which is the order they were
    -- opened in and so the order to open them in again.
    --
    -- One line per *process*, not per window: a second window of a program that
    -- runs one process would be a second launch of a command that is already
    -- running, and what that does is the program's business, not ours.
    local windows, pids, seen = {}, {}, {}
    for _, win in ipairs(hl.get_windows() or {}) do
        local ws = win.workspace
        if ws and not ws.special and win.pid and not seen[win.pid] then
            seen[win.pid] = true
            table.insert(windows, win)
            table.insert(pids, win.pid)
        end
    end

    -- Command lines first, because which of these windows is a terminal is
    -- decided by the command being run, and the terminals have to be known
    -- before they can be asked about together. Reading /proc/<pid>/cmdline is
    -- an ordinary file read; the two questions below are not.
    --
    -- Both shell out, and io.popen blocks the compositor for as long as the
    -- program it starts takes -- no frame is drawn and no key is answered
    -- meanwhile. So each is asked exactly once, about every pid at once. This
    -- used to be one bin/terminal-cwd per terminal window, and with a handful
    -- of terminals open it froze the desktop for most of a second every time
    -- the session was written, which is every three seconds while anything is
    -- happening.
    local argv_by_pid, terminal_pids = {}, {}
    for _, win in ipairs(windows) do
        local argv = argv_of(win.pid)
        argv_by_pid[win.pid] = argv

        -- Recognised by the command being run rather than by the window's
        -- class: the two happen to be the same word for kitty, and there is
        -- no reason to rely on that.
        if argv and argv[1]:match("([^/]+)$") == terminal then
            table.insert(terminal_pids, win.pid)
        end
    end

    local cwd_of       = cwds_of(pids)
    local shell_cwd_of = quake.terminal_cwds(terminal_pids)

    for _, win in ipairs(windows) do
        local argv = argv_by_pid[win.pid]
        if argv then
            local cwd = cwd_of[win.pid]

            -- A terminal is put back where its *shell* is, not where it is:
            -- kitty stays in the directory it was launched from for the whole
            -- session, so its own cwd would send every restored terminal back
            -- to wherever the last login started. bin/terminal-cwd knows the
            -- difference. The directory then goes on the command line, because
            -- that is what kitty reads -- and any --directory already there is
            -- from the last launch and would win over it.
            do
                local shell_cwd = shell_cwd_of[win.pid]
                if shell_cwd then
                    local rebuilt = {}
                    local skip = false
                    for i, arg in ipairs(argv) do
                        if skip then
                            skip = false
                        elseif arg == "--directory" or arg == "-d" then
                            skip = true -- and its value
                        elseif i == 1 then
                            table.insert(rebuilt, arg)
                            table.insert(rebuilt, "--directory")
                            table.insert(rebuilt, shell_cwd)
                        else
                            table.insert(rebuilt, arg)
                        end
                    end
                    argv = rebuilt
                    cwd = shell_cwd
                end
            end

            local fields = { "window", win.workspace.id, cwd or "" }
            for _, arg in ipairs(argv) do
                table.insert(fields, arg)
            end
            record(lines, fields)
        end
    end

    local focused = hl.get_active_workspace()
    if focused and not focused.special then
        record(lines, { "focus", focused.id })
    end

    return lines
end

local function write(lines)
    -- Written beside and moved into place, so a session that is interrupted
    -- half way through writing leaves the last good file rather than half a
    -- new one.
    local temporary = PATH .. ".new"
    local file = io.open(temporary, "w")

    if not file then
        -- The directory is shared with the pinned monitor order, and may not
        -- exist on a machine where nothing has written state yet. Making it
        -- is a shell, and os.execute blocks the compositor like any other --
        -- so it happens when the write actually fails rather than before
        -- every one of them, which on a working machine is never.
        local dir = PATH:match("^(.*)/[^/]+$")
        if not dir then
            return
        end
        os.execute(("mkdir -p '%s' 2>/dev/null"):format(dir:gsub("'", "'\\''")))

        file = io.open(temporary, "w")
    end

    if not file then
        return
    end
    file:write(table.concat(lines, "\n"), "\n")
    file:close()

    os.rename(temporary, PATH)
end

local pending = false

local function save()
    if not armed or pending or NESTED then
        return
    end
    pending = true

    hl.timer(function()
        pending = false
        if armed then
            write(snapshot())
        end
    end, { timeout = WRITE_DELAY, type = "oneshot" })
end

-- ---------------------------------------------------------------------------
-- Putting it back

-- Shell quoting, for the one place a shell is involved: relaunching has to run
-- `cd` before the program, and hl.exec_cmd does not run a shell, so the whole
-- thing is handed to `sh -c`. Single quotes, because the string is itself
-- inside the double quotes Hyprland's argument splitter understands.
local function quoted(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function launch(desktop_id, cwd, argv)
    local command = {}
    for _, arg in ipairs(argv) do
        table.insert(command, quoted(arg))
    end
    local program = table.concat(command, " ")

    -- `cd` first, so a command line with a relative path in it -- `rider
    -- Runner.slnx`, saved with the directory it was run from -- means the same
    -- thing again. `exec`, so no shell is left hanging around the program.
    local shell = ("exec %s"):format(program)
    if cwd then
        shell = ("cd %s && exec %s"):format(quoted(cwd), program)
    end

    -- `silent` so a login does not drag the focus from desktop to desktop as
    -- each window turns up.
    hl.exec_cmd(('[workspace %d silent] sh -c "%s"'):format(desktop_id, shell))
end

-- Run a list of thunks, one every LAUNCH_DELAY, then call `done`.
--
-- A oneshot timer that arms the next one: `type = "repeating"` is accepted and
-- never fires.
local function serially(steps, done)
    local index = 0

    local function step()
        index = index + 1
        local this = steps[index]
        if not this then
            if done then done() end
            return
        end

        this()
        hl.timer(step, { timeout = LAUNCH_DELAY, type = "oneshot" })
    end

    hl.timer(step, { timeout = LAUNCH_DELAY, type = "oneshot" })
end

-- Start saving from here on. Called when the restore is over, and when there
-- was nothing to restore.
local function arm()
    armed = true
    save()
end

-- Recreate last session's desktops and start its programs again.
--
-- Driven from outside, by bin/dotfiles-session-restore, once the compositor is
-- up and its monitors are known -- none of this can run from the hyprland.start
-- hook, where get_monitors() is still empty and creating a timer segfaults
-- Hyprland outright.
--
-- Says what it did in a notification, and returns the same summary. The
-- notification is raised from in here rather than by the script, which is long
-- gone by the time the last program has been started.
local function restore()
    -- Desktops first, all of them, before anything is launched into them: a
    -- window whose desktop does not exist yet would create it on whichever
    -- screen happens to have focus.
    --
    -- A desktop with nothing on it and no rule keeping it would be swept up
    -- again the moment focus moved on, so it is only worth putting back if
    -- there is something to go on it: windows, or a quake terminal.
    --
    -- A desktop whose only content was its terminal has to be *kept* open to
    -- come back at all, even if it was not being kept before. A terminal sits
    -- in a workspace of its own and does not count towards its desktop being
    -- occupied, so without the rule the desktop would lapse the moment focus
    -- moved and take the directory it is named after with it. That desktop
    -- existed because of where its shell was, which is exactly the thing worth
    -- restoring, so it comes back as a kept one and SUPER+C closes it.
    local wanted, terminals = {}, {}
    for _, window in ipairs(saved.windows) do
        wanted[window.desktop] = true
    end
    for _, entry in ipairs(saved.quake) do
        terminals[entry.desktop] = true
    end

    local restored, desktops = {}, 0
    for _, desktop in ipairs(saved.desktops) do
        local only_terminal = terminals[desktop.id] == true and wanted[desktop.id] ~= true
        local keep = desktop.persistent or only_terminal
        if keep or wanted[desktop.id] then
            deskbinds.place_desktop(desktop.id, desktop.identity, keep)
            -- A titled desktop always reaches here, with no condition of its
            -- own to add above: naming one keeps it open (deskbinds.lua), so
            -- it is written down with the kept flag set and comes back for
            -- that reason.
            --
            -- Named before the terminal is started rather than after: the
            -- terminal coming up names its desktop after its directory, and a
            -- desktop that was titled must not flicker through that name on
            -- the way back.
            if saved.titles[desktop.id] then
                deskbinds.set_title(desktop.id, saved.titles[desktop.id])
            end
            restored[desktop.id] = true
            desktops = desktops + 1
        end
    end

    local steps, windows = {}, 0

    -- The quake terminals, before the windows: they are the slowest thing to
    -- become useful (the desktop is not named until its shell has answered)
    -- and the cheapest to start.
    for _, entry in ipairs(saved.quake) do
        if restored[entry.desktop] and #steps < LAUNCH_LIMIT then
            table.insert(steps, function()
                quake.spawn(entry.desktop, entry.cwd)
            end)
        end
    end

    for _, window in ipairs(saved.windows) do
        if #steps < LAUNCH_LIMIT then
            windows = windows + 1
            table.insert(steps, function()
                launch(window.desktop, window.cwd, window.argv)
            end)
        end
    end

    local summary = ("%d desktops, %d windows"):format(desktops, windows)

    local function finished()
        -- Focus last: every launch above was silent, so nothing has moved the
        -- view, and the desktop that was in view at the end of the last session
        -- is the one to come back to.
        if saved.focus and restored[saved.focus] then
            hl.dispatch(hl.dsp.focus({ workspace = saved.focus }))
        end

        -- Only now start writing, and not before: a snapshot taken half way
        -- through this would be a session with half its windows.
        arm()

        -- Said out loud, because a login that quietly relaunches a dozen
        -- programs is otherwise indistinguishable from one that has gone wrong.
        -- dotfiles-session-restore --off turns the whole thing off.
        hl.exec_cmd(("notify-send --urgency=low Session 'restored %s'"):format(summary))
    end

    if #steps == 0 then
        finished()
    else
        serially(steps, finished)
    end

    return summary
end

-- ---------------------------------------------------------------------------
-- When to write

for _, event in ipairs({
    "window.open",
    "window.close",
    "window.title",       -- how a `cd` in a terminal is noticed
    "workspace.created",
    "workspace.removed",
    "workspace.active",
    "workspace.move_to_monitor",
    "monitor.added",
    "monitor.removed",
}) do
    hl.on(event, save)
end

-- `hyprctl reload` re-runs this file, which forgets that the restore has
-- already happened, and nothing will say so again -- the restore script runs
-- once per compositor, not once per config load. So a reload arms saving
-- itself.
--
-- config.reloaded fires at the first load as well, before hyprland.start, so
-- that alone would arm the session at login and let a snapshot of the empty
-- pre-restore desktop be written. hyprland.start disarms it again, and only
-- happens on a real start, which is exactly the case where a restore is still
-- to come. The order of the two is Hyprland's and was checked against a nested
-- instance: config.reloaded, then hyprland.start.
hl.on("config.reloaded", function()
    armed = true
end)

hl.on("hyprland.start", function()
    armed = false
end)

return {
    restore = restore,
    arm = arm,
    -- For the tests: the file as it was read, and the snapshot as it would be
    -- written.
    saved = saved,
    snapshot = snapshot,
}
