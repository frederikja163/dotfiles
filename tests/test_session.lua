-- Standalone harness for session.lua: stubs the hl API, the modules it asks
-- about the session, and a small /proc, then checks what gets written down and
-- what gets started again.
--
-- The two halves are tested from opposite ends. Writing: build a world, call
-- snapshot(), read the lines. Putting it back: write a session file, load the
-- module so it reads it, call restore(), and assert on the desktops placed and
-- the commands run.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local TMP  = (os.getenv("TMPDIR") or "/tmp") .. "/hypr-session-test"
local FILE = TMP .. "/session"
local PROC = TMP .. "/proc"

os.execute(("rm -rf '%s' && mkdir -p '%s'"):format(TMP, PROC))

-- session.lua reads both of these, so the test never touches the real session
-- file or the real process table.
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "HYPR_SESSION" then return FILE end
    if name == "HYPR_PROC" then return PROC end
    return real_getenv(name)
end

-- A fake process: argv as the kernel presents it, NUL separated.
local function process(pid, argv)
    os.execute(("mkdir -p '%s/%d'"):format(PROC, pid))
    local f = assert(io.open(("%s/%d/cmdline"):format(PROC, pid), "wb"))
    f:write(table.concat(argv, "\0") .. "\0")
    f:close()
end

-- bin/proc-cwd and bin/terminal-cwd are the only shells session.lua runs.
local cwds, terminal_cwds = {}, {}
local real_popen = io.popen
io.popen = function(command)
    local pids = command:match("^proc%-cwd ([%d ]+)")
    if pids then
        local out = {}
        for pid in pids:gmatch("%d+") do
            if cwds[tonumber(pid)] then
                table.insert(out, pid .. "\t" .. cwds[tonumber(pid)])
            end
        end
        local text = table.concat(out, "\n") .. "\n"
        return { lines = function() return text:gmatch("([^\n]+)") end,
                 read = function() return text end,
                 close = function() end }
    end
    return real_popen(command)
end

local world, execs, dispatched, events, timers, placed, spawned, titled, shell_lookups
local title_hook, renumbers, kept, mod

-- Timers fire immediately, in order, so a staggered restore runs to completion
-- inside the call. The real ones are 400ms apart; nothing here depends on the
-- delay, only on the order.
local function run_timers()
    local guard = 0
    while #timers > 0 and guard < 200 do
        guard = guard + 1
        local next_timer = table.remove(timers, 1)
        next_timer()
    end
end

local function reset(w)
    world = w or {}
    execs, dispatched, events, timers, placed, spawned, titled, shell_lookups =
        {}, {}, {}, {}, {}, {}, {}, {}
    title_hook, renumbers, kept = nil, 0, {}

    _G.hl = {
        on = function(event, fn) events[event] = fn end,
        timer = function(cb) table.insert(timers, cb) end,
        exec_cmd = function(cmd) table.insert(execs, cmd) end,
        dispatch = function(d) table.insert(dispatched, d) end,
        get_monitors = function() return world.monitors or {} end,
        get_workspaces = function() return world.workspaces or {} end,
        get_windows = function() return world.windows or {} end,
        get_active_workspace = function() return world.focused end,
        dsp = {
            focus = function(a) return { kind = "focus", arg = a } end,
            no_op = function() return { kind = "no_op" } end,
        },
    }

    -- The modules session.lua asks about the session, stubbed: what it does
    -- with their answers is what is being tested, not the answers themselves.
    package.loaded.monitorpin = {
        identity = function(mon) return mon and (mon.description ~= "" and mon.description or mon.name) end,
    }
    package.loaded.deskbinds = {
        is_persistent = function(id) return (world.persistent or {})[id] == true end,
        place_desktop = function(id, identity, persistent)
            table.insert(placed, { id = id, identity = identity, persistent = persistent })
        end,
        title_of = function(id) return (world.titles or {})[id] end,
        set_title = function(id, title) table.insert(titled, { id = id, title = title }) end,
        -- Renaming a workspace raises no event of its own, so deskbinds says
        -- so directly and this file writes the session down for it.
        on_title_changed = function(fn) title_hook = fn end,
        renumber_desktops = function() renumbers = renumbers + 1 end,
        keep_open = function(id) table.insert(kept, id) return true end,
    }
    package.loaded.quake = {
        cwd_for = function(id) return (world.quake_cwds or {})[id] end,
        -- Asked about every terminal at once, because io.popen blocks the
        -- compositor: one call for the lot costs about what one call costs.
        terminal_cwds = function(pids)
            local answers = {}
            for _, pid in ipairs(pids) do
                answers[pid] = terminal_cwds[pid]
            end
            table.insert(shell_lookups, #pids)
            return answers
        end,
        spawn = function(id, directory)
            table.insert(spawned, { desktop = id, directory = directory })
        end,
    }
    package.loaded.programs = { terminal = "kitty", mainMod = "SUPER" }

    package.loaded.session = nil
    mod = require("session")
end

local function write_session(text)
    os.execute(("mkdir -p '%s'"):format(TMP))
    local f = assert(io.open(FILE, "w"))
    f:write(text)
    f:close()
end

local function read_session()
    local f = io.open(FILE, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-56s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-56s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

-- A session worth writing down: two screens, three desktops, a terminal and an
-- editor on one of them, a browser on another.
local function two_screens()
    local mon0 = { id = 0, name = "eDP-1", description = "BOE 0x0DBB" }
    local mon1 = { id = 1, name = "DP-4", description = "Dell DELL P3424WE DVYH6T3" }
    local ws1 = { id = 1, special = false, monitor = mon0 }
    local ws2 = { id = 2, special = false, monitor = mon0 }
    local ws3 = { id = 3, special = false, monitor = mon1 }
    local special = { id = -99, special = true, monitor = mon0 }

    return {
        monitors = { mon0, mon1 },
        workspaces = { ws3, ws1, ws2, special }, -- deliberately out of order
        persistent = { [2] = true },
        quake_cwds = { [1] = "/home/fredandr/dotfiles" },
        focused = ws1,
        windows = {
            { pid = 100, class = "kitty", workspace = ws1 },
            { pid = 200, class = "jetbrains-rider", workspace = ws3 },
            { pid = 300, class = "quake", workspace = special },
        },
    }
end

local function lines_of(list)
    local by_kind = {}
    for _, line in ipairs(list) do
        local kind = line:match("^([^\t]+)")
        by_kind[kind] = by_kind[kind] or {}
        table.insert(by_kind[kind], line)
    end
    return by_kind
end

print("scenario: writing the session down")
reset(two_screens())
process(100, { "kitty", "--directory", "/home/fredandr/old", "opencode" })
process(200, { "/opt/rider/bin/rider", "Runner.slnx" })
process(300, { "kitty", "--class", "quake" })
cwds[100] = "/home/fredandr"
cwds[200] = "/home/fredandr/Projects/runner"
terminal_cwds[100] = "/home/fredandr/Projects/runner/main"

local snap = lines_of(mod.snapshot())

check("one line per desktop", #(snap.desktop or {}), 3)
check("lowest id first", snap.desktop[1], "desktop\t1\t0\tBOE 0x0DBB")
check("the kept one carries the flag", snap.desktop[2], "desktop\t2\t1\tBOE 0x0DBB")
check("and the screen is the description, not the connector",
      snap.desktop[3], "desktop\t3\t0\tDell DELL P3424WE DVYH6T3")
check("the special workspace is not a desktop", #(snap.desktop or {}), 3)

check("the terminal's directory is the desktop's", #(snap.quake or {}), 1)
check("...as a path, for the desktop that had one",
      snap.quake[1], "quake\t1\t/home/fredandr/dotfiles")

-- A quake terminal is not an ordinary window: it is restored by quake.lua from
-- the record above, and would otherwise come back twice.
check("windows, without the one in the special workspace", #(snap.window or {}), 2)

-- The shell has moved since kitty was started, so where the shell is wins and
-- the stale --directory from the last launch is dropped.
check("a terminal is put back where its shell is",
      snap.window[1],
      "window\t1\t/home/fredandr/Projects/runner/main\tkitty\t--directory\t"
      .. "/home/fredandr/Projects/runner/main\topencode")
check("anything else keeps its own command line and directory",
      snap.window[2],
      "window\t3\t/home/fredandr/Projects/runner\t/opt/rider/bin/rider\tRunner.slnx")
check("the focused desktop is noted", (snap.focus or {})[1], "focus\t1")
check("an untitled desktop writes no title", snap.title, nil)

-- A title is a decision about what a desktop is for, and nothing can
-- reconstruct it the way the terminal's directory reconstructs a label.
print("scenario: a desktop that has been given a name")
local named = two_screens()
named.titles = { [2] = "comms" }
reset(named)
snap = lines_of(mod.snapshot())
check("written down, by desktop", (snap.title or {})[1], "title\t2\tcomms")
check("only the one that has a name", #(snap.title or {}), 1)

-- Every shell-out blocks the compositor: io.popen runs inside Hyprland's own
-- loop, so nothing is drawn and no key is answered until it returns. The
-- count is therefore not an efficiency detail but the length of the freeze --
-- asking per terminal is what made the desktop lock up for the better part of
-- a second every three seconds.
print("scenario: the terminals are asked about together")
local many = two_screens()
table.insert(many.windows, { pid = 400, class = "kitty", workspace = many.workspaces[2] })
reset(many)
process(400, { "kitty", "--directory", "/home/fredandr" })
terminal_cwds[400] = "/home/fredandr/Projects/other"
mod.snapshot()
check("asked once, however many terminals there are", #shell_lookups, 1)
check("...about both of them, in the one call", shell_lookups[1], 2)

print("scenario: two windows of one process")
local w = two_screens()
table.insert(w.windows, { pid = 100, class = "kitty", workspace = w.workspaces[2] })
reset(w)
snap = lines_of(mod.snapshot())
check("written once, not once per window", #(snap.window or {}), 2)

print("scenario: a process that has gone between the event and the write")
local g = two_screens()
g.windows = { { pid = 999, class = "kitty", workspace = g.workspaces[2] } }
reset(g)
snap = lines_of(mod.snapshot())
check("no /proc entry, so nothing to write", snap.window, nil)

-- A tab in a field would be read back as a field boundary: the record goes
-- rather than the file being left corrupt.
print("scenario: a command line with a tab in it")
local t = two_screens()
t.windows = { { pid = 400, class = "kitty", workspace = t.workspaces[2] } }
reset(t)
process(400, { "kitty", "--title", "a\tb" })
cwds[400] = "/home/fredandr"
snap = lines_of(mod.snapshot())
check("dropped", snap.window, nil)
check("and the desktops are still written", #(snap.desktop or {}), 3)

-- Nothing may be written until the restore has happened or been declined,
-- otherwise the first snapshot of a fresh login overwrites the session it is
-- supposed to be putting back.
print("scenario: nothing is written before the restore")
write_session("desktop\t1\t1\tBOE 0x0DBB\n")
reset(two_screens())
events["window.open"]()
run_timers()
check("the file is untouched", read_session(), "desktop\t1\t1\tBOE 0x0DBB\n")

print("scenario: and everything is written once it is armed")
mod.arm()
run_timers()
check("the session has been written", (read_session() or ""):match("^desktop\t1") ~= nil, true)

print("scenario: a reload arms it, a fresh start does not")
reset(two_screens())
events["config.reloaded"]()
events["window.open"]()
run_timers()
check("a reload writes", (read_session() or ""):match("desktop") ~= nil, true)

-- A reload re-runs every module from nothing, and a title is the one thing
-- about a desktop that cannot be worked out again from what is on screen.
-- The file was written seconds ago and still has it.
print("scenario: titles survive a reload")
write_session("desktop\t1\t0\tBOE 0x0DBB\ntitle\t1\tcomms\ntitle\t7\tgone\n")
reset(two_screens())
events["config.reloaded"]()
check("the named desktop is named again", #titled, 1)
check("...the one that is still there", titled[1] and titled[1].id, 1)
check("...with the name it had", titled[1] and titled[1].title, "comms")
check("and renamed on the spot, not on a timer", renumbers, 1)
-- The other half of having been named: the rule that keeps an empty desktop
-- open is rebuilt from the config on a reload, so it has to be re-issued or
-- the desktop is swept up the moment it is empty and out of view.
check("kept open again too", #kept, 1)
check("...the same desktop", kept[1], 1)

-- Ids are reused. A title from a session that has ended must not land on a
-- stranger's desktop, so a record with no desktop to go with it is dropped --
-- which is also what makes this harmless at the first load, where Hyprland
-- has no workspaces at all yet.
print("scenario: a fresh start, where the file describes a session that is over")
write_session("desktop\t1\t0\tBOE 0x0DBB\ntitle\t1\tcomms\n")
local empty = two_screens()
empty.workspaces = {}
reset(empty)
events["config.reloaded"]()
check("nothing to put a title on, so none is", #titled, 0)

-- Writing it down cannot wait for an unrelated event, or a reload in the gap
-- would lose it.
print("scenario: a title is written down as soon as it is set")
write_session("")
reset(two_screens())
mod.arm()
run_timers()
local before = read_session()
world.titles = { [2] = "comms" }
title_hook(2, "comms")
run_timers()
check("the session was rewritten for it", read_session() ~= before, true)
check("...with the title in it", (read_session() or ""):match("title\t2\tcomms") ~= nil, true)

write_session("desktop\t9\t1\tBOE 0x0DBB\n")
reset(two_screens())
events["config.reloaded"]()   -- fires at a real start too, before...
events["hyprland.start"]()    -- ...this one, which means a restore is due
events["window.open"]()
run_timers()
check("a real start does not", read_session(), "desktop\t9\t1\tBOE 0x0DBB\n")

print("scenario: putting a session back")
write_session(table.concat({
    "desktop\t1\t0\tBOE 0x0DBB",
    "desktop\t2\t1\tBOE 0x0DBB",
    "desktop\t3\t0\tDell DELL P3424WE DVYH6T3",
    "title\t3\tcomms",
    "quake\t1\t/home/fredandr/dotfiles",
    "quake\t3\t/home/fredandr/Projects/runner",
    "window\t1\t/home/fredandr/dotfiles\tkitty\t--directory\t/home/fredandr/dotfiles",
    "window\t3\t/home/fredandr/Projects/runner\t/opt/rider/bin/rider\tRunner.slnx",
    "focus\t3",
}, "\n") .. "\n")
reset(two_screens())
local summary = mod.restore()

-- Desktop 2 has nothing on it, but it was being kept open, so it comes back
-- too. A desktop that was neither kept nor has anything to put on it would be
-- swept up the moment focus moved, so it is not worth recreating.
check("desktops placed before anything is launched", #placed, 3)
check("...in id order", placed[1].id, 1)
check("...on the screen they were on", placed[3].identity, "Dell DELL P3424WE DVYH6T3")
check("...and the kept one is kept again", placed[2].persistent, true)
check("summary counts them", summary, "3 desktops, 2 windows")

-- Before the terminals are started, or the desktop would come back called
-- after its directory and be renamed a moment later.
check("the titled desktop is named again", #titled, 1)
check("...the same desktop", titled[1].id, 3)
check("...with the name it was given", titled[1].title, "comms")

run_timers()

check("both terminals started", #spawned, 2)
check("...for the right desktop", spawned[1].desktop, 1)
check("...in the directory its shell was in", spawned[1].directory, "/home/fredandr/dotfiles")

check("both windows started", #execs, 3) -- two windows plus the notification
check("onto the desktop it was on, silently, through a shell for the cd",
      execs[1],
      "[workspace 1 silent] sh -c \"cd '/home/fredandr/dotfiles' && exec "
      .. "'kitty' '--directory' '/home/fredandr/dotfiles'\"")
check("a relative path still means the same thing",
      execs[2],
      "[workspace 3 silent] sh -c \"cd '/home/fredandr/Projects/runner' && exec "
      .. "'/opt/rider/bin/rider' 'Runner.slnx'\"")
check("and it says what it did", execs[3]:match("^notify%-send") ~= nil, true)

check("focus goes back where it was, last of all",
      dispatched[#dispatched].arg.workspace, 3)

-- A desktop whose only content was its terminal is the common case here: a
-- project you are not editing in a window right now, but which is a desktop
-- because of the directory its shell is in.
print("scenario: a desktop that had nothing but its terminal")
write_session(table.concat({
    "desktop\t1\t0\tBOE 0x0DBB",
    "desktop\t2\t0\tBOE 0x0DBB",
    "quake\t2\t/home/fredandr/dotfiles",
    "window\t1\t\tfirefox",
}, "\n") .. "\n")
reset(two_screens())
mod.restore()
check("it comes back", #placed, 2)
check("...and is kept open, or it would lapse at once", placed[2].persistent, true)
check("while a desktop with a window on it needs no keeping", placed[1].persistent, false)
run_timers()
check("its terminal is put back", spawned[1] and spawned[1].desktop, 2)

print("scenario: a desktop with neither windows nor a terminal")
write_session("desktop\t1\t0\tBOE 0x0DBB\ndesktop\t7\t0\tBOE 0x0DBB\nwindow\t1\t\tfirefox\n")
reset(two_screens())
check("nothing to put on it, so it is not recreated", mod.restore(), "1 desktops, 1 windows")
check("only the one", #placed, 1)
check("...which is the one with the window", placed[1].id, 1)

print("scenario: a desktop that was on a screen that is not here now")
write_session("desktop\t4\t1\tSome Other Screen\nwindow\t4\t\tfirefox\n")
reset(two_screens())
mod.restore()
run_timers()
check("placed anyway, with the screen it wants", placed[1].identity, "Some Other Screen")
check("and its window started", execs[1],
      "[workspace 4 silent] sh -c \"exec 'firefox'\"")

print("scenario: no session file at all")
os.remove(FILE)
reset(two_screens())
check("nothing to restore", mod.restore(), "0 desktops, 0 windows")
run_timers()
check("and it says nothing", #execs, 1) -- only the notification
events["window.open"]()
run_timers()
check("but saving is armed, so this session is kept",
      (read_session() or ""):match("desktop") ~= nil, true)

-- A path with a space or a quote in it has to survive the shell that runs the
-- cd. Single quotes, with an embedded quote closed and reopened.
print("scenario: awkward paths")
write_session("desktop\t5\t1\tBOE 0x0DBB\n"
    .. "window\t5\t/home/fredandr/dir with space\tkitty\t--title\tit's\n")
reset(two_screens())
mod.restore()
run_timers()
check("quoted for the shell", execs[1],
      "[workspace 5 silent] sh -c \"cd '/home/fredandr/dir with space' && exec "
      .. "'kitty' '--title' 'it'\\''s'\"")

-- Making the directory is a shell, and a shell inside the compositor is a
-- frozen frame, so it is only run when a write has actually failed -- which
-- means the failing write has to be retried. Last, because it takes the fake
-- /proc with it.
print("scenario: the state directory does not exist yet")
os.execute(("rm -rf '%s'"):format(TMP))
reset(two_screens())
mod.arm()
run_timers()
check("made on the way, so the session is still written",
      (read_session() or ""):match("^desktop") ~= nil, true)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
