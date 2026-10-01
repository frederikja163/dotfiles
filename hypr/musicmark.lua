-- A note on the desktop the music is playing from.
--
-- bin/music registers the window it was started in, and this adds a marker to
-- that desktop's name in the bar: "1 Music" becomes "1 Music 🎵". The pill on
-- the right says *what* is playing; this says *where* from, which is the thing
-- the pill cannot say -- it is the same bar on every screen.
--
-- Nothing here polls, and nothing here asks what is playing. A desktop's name
-- is rebuilt by deskbinds on every workspace event and on window.open / close
-- / move_to_workspace, and this is consulted during that pass, so the marker
-- keeps up without watching anything.
--
-- A playerctl daemon was the first design and is worse. It would have had to
-- watch playback, re-resolve the player's position on every Hyprland event and
-- push the answer back in -- a long-running process, two event streams to keep
-- in step, and all of it to answer a question already answered by which
-- desktop a window is on.
--
-- Why a window and not a PipeWire sink: audio leaves through a sink, and a
-- sink has no desktop and no monitor. There is no true answer to "which screen
-- is this coming from", and mpv under `music` has no window of its own either,
-- being started with --no-video. The terminal it was typed in is the honest
-- proxy, and it is the one the user is thinking of.
--
-- THE QUAKE TERMINAL IS THE WHOLE DIFFICULTY, and getting it wrong is what
-- made the first version of this file do nothing at all. The drop-down
-- terminal is where a command actually gets typed on this machine, and it does
-- not live on a desktop: quake.lua parks each one in a special workspace of
-- its own, "special:quake-<desktop>". So the focused window's workspace id is
-- the *terminal's*, not the desktop's, and a rule like "mark the desktop
-- holding this window" can never match -- the window is not on a desktop and
-- never will be. The first version refused special workspaces outright, which
-- is correct for a window transiting out of one and catastrophic for the only
-- terminal the user types in: set_here returned nil every time, silently.
--
-- Hence two ways of being marked, below, because the two cases are genuinely
-- different and not one case with a special path:
--
--   * a quake terminal is *bound* to its desktop by name, permanently, and
--     cannot be moved to another, so the desktop id is resolved once and kept.
--   * any other window can be sent anywhere, so what is kept is the window,
--     and the desktop is whichever one currently holds it. The note then
--     follows SUPER+M for free.
--
-- Two consequences worth stating, because they are deliberate:
--
--   * `music` started from a keybind rather than a terminal has no window to
--     register, so no desktop is marked. There is no sensible answer in that
--     case and inventing one -- the focused desktop, say -- would put the note
--     somewhere the music is not.
--   * The note means "playing from here", not "playing". It stays up while
--     `music` is paused, because pausing does not move it and the pill already
--     shows the pause.

local deskbinds = require("deskbinds")
local quake     = require("quake")

-- Noto Color Emoji is installed (packages/pacman.txt), which is what renders
-- this; waybar's JetBrainsMono Nerd Font has no colour glyph for it and falls
-- back. Swap it for the nerd font's own "\u{f001}" if a monochrome note would
-- sit better beside the other pills -- it is this one string either way.
local MARK = "🎵"

-- Exactly one of these is set. `desktop` is a quake terminal's desktop, fixed
-- at registration; `address` is an ordinary window, looked up every pass.
local desktop = nil
local address = nil

-- The pid of the bin/music that registered the mark.
local owner = nil

-- Whether that bin/music is still running.
--
-- This is what makes a stale marker impossible. bin/music clears the mark on
-- its way out, but a SIGKILL leaves no chance to -- so the mark is also only
-- believed while its owner is alive. Reading /proc is a stat, not a fork, and
-- happens once per renaming pass.
local function owner_alive()
    if not owner then
        return false
    end
    local proc = io.open("/proc/" .. owner .. "/stat", "r")
    if not proc then
        return false
    end
    proc:close()
    return true
end

local function forget()
    desktop, address, owner = nil, nil, nil
end

-- Is the registered ordinary window on this desktop?
local function holds_window(id)
    for _, win in ipairs(hl.get_workspace_windows(id) or {}) do
        if win.address and tostring(win.address) == address then
            return true
        end
    end
    return false
end

local function marked(id)
    if desktop then
        return id == desktop
    end
    if address then
        return holds_window(id)
    end
    return false
end

deskbinds.set_decorator(function(ws, label)
    if not (desktop or address) then
        return label
    end

    if not owner_alive() then
        forget()
        return label
    end

    local id = ws and ws.id
    if not id or not marked(id) then
        return label
    end

    -- An unnamed desktop becomes "1 🎵" rather than "1.1 🎵": deskbinds treats
    -- a label as the whole of the name after the number.
    if label and label ~= "" then
        return label .. " " .. MARK
    end
    return MARK
end)

local M = {}

-- Mark the desktop in front, on behalf of the bin/music running as `pid`.
--
-- The window is taken from what is focused, the way deskbinds.set_title_here
-- does: `music` has just been typed into a terminal, so that terminal is what
-- is in front.
--
-- Answers with the desktop's id, or nil when there is nothing in front to mark
-- -- a window in some other special workspace, or a compositor with no active
-- window at all, which is every nested instance in tests/sandbox.sh unless it
-- has been given a headless output.
function M.set_here(pid)
    local win = hl.get_active_window()
    if not (win and win.address) then
        return nil
    end

    -- A quake terminal first: it is in a special workspace, so the branch
    -- below would reject it, and it is the case that matters most.
    local quake_desktop = quake.desktop_of(win)

    local ws = win.workspace
    if not quake_desktop and not (ws and ws.id and not ws.special) then
        return nil
    end

    owner = tonumber(pid) or nil

    -- Nothing to mark without an owner to vouch for it: owner_alive() would
    -- drop the mark on the first pass anyway, so refuse it here where the
    -- caller can see.
    if not owner then
        forget()
        return nil
    end

    if quake_desktop then
        desktop, address = quake_desktop, nil
    else
        desktop, address = nil, tostring(win.address)
    end

    deskbinds.schedule_renumber()
    return quake_desktop or ws.id
end

function M.clear()
    if not (desktop or address) then
        return false
    end
    forget()
    deskbinds.schedule_renumber()
    return true
end

return M
