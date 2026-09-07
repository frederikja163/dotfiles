-- Quake terminal: a terminal that drops down over the desktop and goes away
-- again on the same key (SUPER + `).
--
-- One per desktop, as roadmap.md asks for. Each desktop's terminal lives in its
-- own special workspace, "special:quake-<desktop id>", so every desktop keeps
-- its own shell, scrollback and working directory. The id is used rather than
-- the desktop name because deskbinds.lua renames desktops whenever monitors
-- come and go, while ids stay put.
--
-- Hyprland shows at most one special workspace per monitor, and it keeps
-- showing it across a desktop switch -- desktop 1's terminal would otherwise
-- hang over desktop 2. So nothing here toggles blindly: every change re-syncs
-- the monitor to whatever the focused desktop is supposed to be showing, which
-- also brings the terminal back when you return to a desktop you left it open
-- on.

local programs  = require("programs")
local deskbinds = require("deskbinds")

local mainMod  = programs.mainMod
local terminal = programs.terminal

-- Every quake terminal shares one app id. Which desktop a terminal belongs to
-- is decided by the workspace it is spawned into, not by its class, so a single
-- window rule covers all of them.
local CLASS = "quake"

-- Full width, top 40%, flush to the top edge -- so it covers the bar, like the
-- console in the game. Put it below the bar by raising the y in `move`.
--
-- Percentages are silently ignored in these rules: "100% 40%" leaves the
-- terminal at its default size, with no error anywhere. monitor_w/monitor_h and
-- arithmetic do work, and are the same expression syntax as the move rule in
-- windowrules.lua.
local HEIGHT = 0.4
local SIZE   = ("monitor_w monitor_h*%s"):format(HEIGHT)
local MOVE   = "0 0"

hl.window_rule({
    name  = "quake-terminal",
    match = { class = "^" .. CLASS .. "$" },

    float = true,
    size  = SIZE,
    move  = MOVE,

    -- Both of these are drawn *outside* the window, so on a terminal that is
    -- exactly as wide as its monitor they hang over the edge and show up as a
    -- stripe down the side of the monitor next door: 2px of border and 4px of
    -- shadow, per look.lua. Switching them off keeps the full width, which
    -- shrinking the terminal to make room for them would not.
    border_size = 0,
    no_shadow   = true,
})

local function workspace_for(desktop_id)
    return "quake-" .. desktop_id
end

-- How each desktop was left: [desktop id] = terminal was down when we left it.
-- Only consulted when returning to a desktop, and only ever written from what
-- was actually on screen at the time -- Hyprland hides the terminal by itself
-- when a program is launched out of it, and bookkeeping that assumed otherwise
-- drifted out of step and ate the next keypress.
local down = {}

-- Desktops with a terminal on the way but not on screen yet: [desktop id] =
-- true. Only ever true for the moment between the press and the window
-- appearing, so that a second press in that gap does not start a second one.
local starting = {}

-- The desktop the monitor was last synced to, so a switch can be recognised.
local current = nil

-- The focused desktop. A monitor reports its desktop and its special workspace
-- separately, so this stays the desktop even while the terminal has focus.
local function focused_desktop()
    local mon = hl.get_active_monitor()
    local ws  = mon and mon.active_workspace
    if ws and not ws.special then
        return ws
    end
    return nil
end

-- The quake workspace on the focused monitor, or nil. Any other special
-- workspace belongs to something else and is left alone.
local function showing()
    local sp = hl.get_active_special_workspace()
    -- The id may be negative: Hyprland numbers named workspaces downwards from
    -- -1337, so "quake--1337" is a perfectly ordinary name here.
    return sp and sp.name and sp.name:match("^special:(quake%-%-?%d+)$")
end

-- Has this desktop got a terminal? Asked of Hyprland every time rather than
-- remembered, because remembering it gets this wrong twice over: `hyprctl
-- reload` re-runs this file and forgets every terminal that exists, so the next
-- press starts a duplicate; and closing a terminal by hand leaves the memory
-- insisting one is still there, so the key toggles an empty workspace and
-- nothing ever comes back.
local function terminal_window(desktop_id)
    local name = "special:" .. workspace_for(desktop_id)
    for _, win in ipairs(hl.get_windows() or {}) do
        if win.workspace and win.workspace.name == name and tostring(win.class) == CLASS then
            return win
        end
    end
    return nil
end

-- Showing a workspace is not the same as handing over the keyboard, and
-- follow_mouse is on (input.lua), so focus stays with whatever the pointer
-- happens to be over. A terminal you have to click on before typing is not
-- worth having, so take focus explicitly.
local function focus_terminal(desktop_id)
    local win = terminal_window(desktop_id)
    if win and win.address then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
    end
end

-- Give the terminal the shape of the monitor it is being shown on.
--
-- The size rule above runs once, when the window is created, and a floating
-- window keeps its pixel size when it moves between monitors -- so a terminal
-- made on the ultrawide arrives on the laptop panel still 3440 wide. A desktop
-- can move between monitors and its terminal goes with it, so the size has to
-- be worked out again every time it comes down, not just once.
--
-- Sizes and positions are in layout coordinates: the monitor's own pixels
-- divided by its scale, which is 1 on one of these screens and 1.5 on the
-- other. Both dispatchers take {x=, y=}; resize keeps the window centred, so
-- the move has to follow it rather than lead.
local function fit(desktop_id)
    local win = terminal_window(desktop_id)
    local mon = hl.get_active_monitor()
    if not win or not win.address or not mon then
        return
    end

    local target = "address:" .. win.address
    local scale  = mon.scale or 1

    hl.dispatch(hl.dsp.window.resize({
        window = target,
        x = math.floor(mon.width / scale),
        y = math.floor(mon.height / scale * HEIGHT),
    }))
    hl.dispatch(hl.dsp.window.move({ window = target, x = mon.x, y = mon.y }))
end

-- What each desktop is called on the bar: [desktop id] = directory name, or nil
-- while it is still just a number.
--
-- A desktop is whatever you are working on in it, and the terminal is where
-- that gets decided, so the directory its shell is sitting in is the honest
-- name for it. deskbinds.lua owns desktop names and asks for these through the
-- hook it exposes.
local labels = {}

local HOME = os.getenv("HOME") or ""

-- What home is called, and what a desktop with no terminal is called.
local HOME_LABEL = "~"

-- Where the shell inside a terminal is, given the terminal's pid. Exported for
-- session.lua, which asks the same question about ordinary terminal windows: a
-- kitty stays in the directory it was launched from for its whole life, so its
-- own /proc entry is no use to either of us.
local function terminal_cwd(pid)
    if not pid then
        return nil
    end

    -- bin/terminal-cwd, because the shell holds the directory rather than the
    -- terminal. This shells out from the compositor, so it is kept to one call
    -- per terminal per burst of changes, below.
    local pipe = io.popen(("terminal-cwd %d 2>/dev/null"):format(pid))
    if not pipe then
        return nil
    end
    local cwd = (pipe:read("*a") or ""):gsub("%s+$", "")
    pipe:close()

    return cwd ~= "" and cwd or nil
end

-- The same question asked of a window rather than a pid.
local function cwd_of(win)
    return win and terminal_cwd(win.pid) or nil
end

local function directory_of(win)
    local cwd = cwd_of(win)
    if not cwd then
        return nil -- nothing to go on, so the desktop falls back to "~"
    end

    -- Home and root are written the way a shell writes them; everything else is
    -- the last part of the path, which is what you would call the project.
    if cwd == HOME then
        return HOME_LABEL
    end
    if cwd == "/" then
        return "/"
    end
    return cwd:match("([^/]+)/*$")
end

-- Which desktop a terminal belongs to, read back out of its workspace name.
local function desktop_of(win)
    local ws = win and win.workspace and win.workspace.name
    local id = ws and ws:match("^special:quake%-(%-?%d+)$")
    return id and tonumber(id)
end

local relabelling = {}

local function relabel(desktop_id)
    if relabelling[desktop_id] then
        return -- a burst of title changes is one directory to look up, not ten
    end
    relabelling[desktop_id] = true

    hl.timer(function()
        relabelling[desktop_id] = nil

        local label = directory_of(terminal_window(desktop_id))
        if labels[desktop_id] ~= label then
            labels[desktop_id] = label
            deskbinds.schedule_renumber()
        end
    end, { timeout = 300, type = "oneshot" })
end

-- Always a name, never a number. A desktop with no terminal, or one whose
-- directory could not be read, is called "~": that is where a terminal would
-- start if one were opened on it.
-- Where the focused desktop is, as a path, or nil if it has no terminal.
--
-- This is what a second terminal opened on the desktop starts in, so it lands
-- in the same place as the quake terminal with a shell of its own. Read live
-- rather than from the label cache: it is one keypress, and a cached path that
-- has gone stale would open the wrong directory.
local function directory()
    local ws = focused_desktop()
    if not ws then
        return nil
    end
    return cwd_of(terminal_window(ws.id))
end

local function label_for(desktop_id)
    return labels[desktop_id] or HOME_LABEL
end

-- Where a given desktop's terminal is, as a path, or nil if it has not got one.
-- The per-desktop version of directory() above, for session.lua: writing the
-- session down means asking about every desktop, not only the focused one.
local function cwd_for(desktop_id)
    return cwd_of(terminal_window(desktop_id))
end

deskbinds.set_labeller(function(ws) return label_for(ws.id) end)

-- `hyprctl reload` runs this file again from nothing while the terminals are
-- still open, so the names have to be read back rather than waited for.
-- Otherwise every desktop falls back to a number and stays there until
-- something happens in its terminal to change the title.
--
-- Read straight through, with no timer and no scheduling: both are called while
-- the config is loading, where creating a timer segfaults Hyprland. Renumbering
-- is called at the end rather than left to deskbinds' own hook for the same
-- event, because that hook was registered first and has already run by now.
local function relabel_all()
    for _, win in ipairs(hl.get_windows() or {}) do
        if tostring(win.class) == CLASS then
            local id = desktop_of(win)
            if id then
                labels[id] = directory_of(win)
            end
        end
    end
    deskbinds.renumber_desktops()
end

hl.on("config.reloaded", relabel_all)
hl.on("hyprland.start", relabel_all)

-- The title is not the directory -- oh-my-zsh puts the running command there,
-- so it says "vim" as often as it says a path -- but it does change whenever
-- anything happens in the shell, which makes it a free signal to go and look
-- the directory up properly.
hl.on("window.title", function(win)
    if win and tostring(win.class) == CLASS then
        local id = desktop_of(win)
        if id then
            relabel(id)
        end
    end
end)

-- Gone, so the desktop goes back to being a number. By the time the timer runs
-- the window is no longer listed, which is exactly what clears the label.
hl.on("window.close", function(win)
    if win and tostring(win.class) == CLASS then
        local id = desktop_of(win)
        if id then
            relabel(id)
        end
    end
end)

-- The dispatcher takes the bare name as a positional argument. A table
-- ({workspace = ...} or {name = ...}) is accepted and then ignored, which
-- toggles Hyprland's default "special:special" instead -- no error, just the
-- wrong workspace.
local function toggle_special(name)
    hl.dispatch(hl.dsp.workspace.toggle_special(name))
end

-- Hand the monitor over to the desktop that now has focus: put away the
-- terminal belonging to the desktop being left, remembering whether it was
-- down, and bring back the one belonging to the desktop being entered.
local syncing = false

local function sync()
    if syncing then
        return -- toggling emits workspace events, which land back here
    end
    syncing = true

    -- No desktop to decide for: focus is momentarily inside a special
    -- workspace, which happens while a window is being moved out of one.
    local ws = focused_desktop()
    if ws and ws.id ~= current then
        local have = showing()

        if current then
            down[current] = (have == workspace_for(current))
        end
        if have then
            toggle_special(have)
        end
        if down[ws.id] then
            toggle_special(workspace_for(ws.id))
            fit(ws.id)
        end

        current = ws.id
    end

    syncing = false
end

-- Start a terminal for a desktop, without showing it. `directory` is where its
-- shell should begin, and is only passed when the terminal is being put back by
-- session.lua after a restart -- an ordinary first press has no opinion, and
-- lets kitty start wherever the compositor was started.
--
-- The command lives here rather than at the two call sites so there is one
-- description of what a quake terminal is. Single quoted for the argument
-- splitter, since a directory may contain spaces.
local function spawn(desktop_id, directory)
    -- One terminal per desktop, decided here rather than by each caller: a
    -- second press in the gap before the window appears must not start a
    -- second one, and neither must a session restore run twice.
    if terminal_window(desktop_id) or starting[desktop_id] then
        return
    end

    -- Marked before the spawn, not after: the window turning up is what clears
    -- this, and it must not be able to clear a flag that has not been set yet.
    starting[desktop_id] = true

    -- `silent` keeps focus where it is; the window lands in the special
    -- workspace and it is a toggle that shows it.
    local command = ("[workspace special:%s silent] %s --class %s")
        :format(workspace_for(desktop_id), terminal, CLASS)
    if directory then
        command = ("%s --directory '%s'"):format(command, directory:gsub("'", "'\\''"))
    end
    hl.exec_cmd(command)

    -- Backstop for a terminal that never appears at all, which would otherwise
    -- wedge this desktop shut for the rest of the session.
    hl.timer(function() starting[desktop_id] = nil end,
             { timeout = 5000, type = "oneshot" })
end

local function toggle()
    local ws = focused_desktop()
    if not ws then
        return
    end
    current = ws.id

    -- spawn() is the one place that decides whether a terminal is needed.
    spawn(ws.id)

    local mine = workspace_for(ws.id)
    local have = showing()

    if have == mine then
        toggle_special(mine)
        down[ws.id] = false
    else
        if have then
            toggle_special(have) -- another desktop's, left over
        end
        toggle_special(mine)
        down[ws.id] = true
        -- On the very first press the window does not exist yet; opened()
        -- focuses and fits it when it turns up.
        fit(ws.id)
        focus_terminal(ws.id)
    end
end

-- Showing a special workspace also focuses it, so a program started from the
-- terminal opens *in* the terminal's workspace and is hidden along with it on
-- the next keypress. Send anything that is not itself a quake terminal back out
-- to the desktop the terminal is covering.
local function opened(win)
    if not win then
        return
    end

    local id = desktop_of(win)
    if not id then
        return -- not in a terminal's workspace, so none of our business
    end

    if tostring(win.class) == CLASS then
        -- The terminal itself, which is meant to be there. It was spawned
        -- `silent`, so it has no focus yet: give it some, but only if it is the
        -- one on screen -- a terminal starting on a desktop you have already
        -- moved away from must not steal the keyboard.
        starting[id] = nil
        if showing() == workspace_for(id) and win.address then
            fit(id)
            hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
        end
        relabel(id) -- name the desktop after wherever it starts up
        return
    end

    local desktop = focused_desktop()
    if desktop and win.address then
        hl.dispatch(hl.dsp.window.move({
            workspace = desktop.id,
            window    = "address:" .. win.address,
        }))
    end
end

hl.on("window.open", opened)

-- Nothing here closes a terminal when its desktop merely *goes away*,
-- deliberately.
--
-- A terminal sits in a workspace of its own, which does not count towards
-- making its desktop non-empty, so a desktop whose only content is the terminal
-- is removed by Hyprland the moment you leave it. Tidying up on that signal was
-- tried and is worse than the leak it fixes: drop the terminal on an empty
-- desktop, step away, come back, and it had been killed underneath you.
--
-- So a terminal outlives a desktop that lapsed. Hyprland reuses desktop ids, so
-- a later desktop with the same id inherits it -- which is the same bargain as
-- every other desktop: the id is the identity, and one terminal belongs to it.
--
-- A desktop *closed* with SUPER+C is the other case, and gets the opposite
-- treatment. There the desktop was got rid of on purpose, and inheriting its
-- terminal would hand the next desktop with that id the closed one's shell,
-- working directory and therefore its name on the bar. So closing takes the
-- terminal with it, and the desktop that comes next starts at "~" with nothing
-- behind it.
--
-- Everything remembered per desktop goes at the same time. `down` in
-- particular: left set, sync() would try to show a terminal workspace that no
-- longer exists on a desktop that never had one.
local function closed(desktop_id)
    local win = terminal_window(desktop_id)
    if win and win.address then
        -- By address rather than by focus: the terminal is usually the hidden
        -- side of the desktop being closed, and the focused window is either
        -- nothing at all or something else entirely.
        hl.dispatch(hl.dsp.window.close({ window = "address:" .. win.address }))
    end

    down[desktop_id]     = nil
    starting[desktop_id] = nil
    labels[desktop_id]   = nil

    if current == desktop_id then
        current = nil
    end
end

deskbinds.set_closing_hook(closed)

hl.bind(mainMod .. " + grave", toggle, { description = "App: quake terminal" })

-- Following the focused desktop is the whole point, so this has to react to
-- every way the focus can move, not just the desktop binds.
for _, event in ipairs({ "workspace.active", "monitor.focused" }) do
    hl.on(event, sync)
end

return {
    toggle = toggle,
    closed = closed,
    spawn = spawn,
    cwd_for = cwd_for,
    terminal_cwd = terminal_cwd,
    label_for = label_for,
    directory = directory,
    sync = sync,
    workspace_for = workspace_for,
    CLASS = CLASS,
}
