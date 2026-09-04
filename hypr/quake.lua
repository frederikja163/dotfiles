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

local programs = require("programs")

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
local SIZE = "monitor_w monitor_h*0.4"
local MOVE = "0 0"

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
    return sp and sp.name and sp.name:match("^special:(quake%-%d+)$")
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
        end

        current = ws.id
    end

    syncing = false
end

local function toggle()
    local ws = focused_desktop()
    if not ws then
        return
    end
    current = ws.id

    if not terminal_window(ws.id) and not starting[ws.id] then
        -- Marked before the spawn, not after: the window turning up is what
        -- clears this, and it must not be able to clear a flag that has not
        -- been set yet.
        starting[ws.id] = true

        -- `silent` keeps focus where it is; the window lands in the special
        -- workspace and the toggle below is what actually shows it.
        hl.exec_cmd(("[workspace special:%s silent] %s --class %s")
            :format(workspace_for(ws.id), terminal, CLASS))

        -- Backstop for a terminal that never appears at all, which would
        -- otherwise wedge this desktop shut for the rest of the session.
        hl.timer(function() starting[ws.id] = nil end,
                 { timeout = 5000, type = "oneshot" })
    end

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
        -- focuses it when it turns up.
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

    local ws = win.workspace and win.workspace.name
    local id = ws and ws:match("^special:quake%-(%d+)$")
    if not id then
        return -- not in a terminal's workspace, so none of our business
    end

    if tostring(win.class) == CLASS then
        -- The terminal itself, which is meant to be there. It was spawned
        -- `silent`, so it has no focus yet: give it some, but only if it is the
        -- one on screen -- a terminal starting on a desktop you have already
        -- moved away from must not steal the keyboard.
        id = tonumber(id)
        starting[id] = nil
        if showing() == workspace_for(id) and win.address then
            hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
        end
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

-- Nothing here closes a terminal when its desktop goes away, deliberately.
--
-- A terminal sits in a workspace of its own, which does not count towards
-- making its desktop non-empty, so a desktop whose only content is the terminal
-- is removed the moment you leave it. Tidying up on that signal was tried and
-- is worse than the leak it fixes: drop the terminal on an empty desktop, step
-- away, come back, and it had been killed underneath you.
--
-- So a terminal outlives its desktop. Hyprland reuses desktop ids, so a later
-- desktop with the same id inherits it -- which is the same bargain as every
-- other desktop: the id is the identity, and one terminal belongs to it.

hl.bind(mainMod .. " + grave", toggle, { description = "App: quake terminal" })

-- Following the focused desktop is the whole point, so this has to react to
-- every way the focus can move, not just the desktop binds.
for _, event in ipairs({ "workspace.active", "monitor.focused" }) do
    hl.on(event, sync)
end

return {
    toggle = toggle,
    sync = sync,
    workspace_for = workspace_for,
    CLASS = CLASS,
}
