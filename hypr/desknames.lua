-- What a desktop is called, when nobody has named it outright.
--
-- Three files each hold a piece of a desktop's name, and this one decides
-- between them. deskbinds.lua owns the number in front and the title bin/title
-- sets; quake.lua knows the directory that desktop's terminal is sitting in;
-- the program on the desktop is read here. The first source with something to
-- say wins:
--
--   1. a title           "2 comms"      deskbinds, and it beats everything
--   2. the directory     "2 dotfiles"   quake, unless the terminal is at ~
--   3. the one program   "2 firefox"    here
--   4. nothing           "2.1"          shown by waybar as a bare number
--
-- (3) sits *below* (2) on purpose. Taking the terminal to a directory is a
-- deliberate act and says what the desktop is for; the program on it is a
-- guess, however good a one. Putting the program first would rename desktops
-- that are correctly named today -- a browser open beside a checkout would
-- stop reading as the checkout -- so this only fills in the desktops that show
-- a bare number.
--
-- The reverse of the order above is also true and worth saying: a name from
-- here is not sticky. It follows the windows, so opening a terminal on a
-- desktop that reads "firefox" takes the name off again until that window
-- goes. `title` is how a name is made to stay.

local deskbinds = require("deskbinds")
local quake     = require("quake")

-- Programs whose desktop is about *where* it is rather than *what* it is.
-- These never lend their own name: the desktop keeps the one its terminal's
-- directory gives it, which is the whole reason that name exists.
--
-- kitty covers more than a terminal -- nvim, opencode and anything else bin/ide
-- starts are windows of the terminal they run in, and carry its class.
-- jetbrains-rider is the same argument for the same reason, with its siblings
-- matched by the prefix so a second JetBrains IDE needs no line here.
--
-- Lua patterns, matched against the window's class. Add a program here when
-- being told which directory it is in would be more use than being told the
-- program's name.
local DIRECTORY_APPS = {
    "^kitty$",
    "^quake$",       -- the drop-down terminal, which is never on a desktop
                     -- anyway: it lives in a special workspace of its own.
    "^jetbrains%-",  -- rider, and whatever else Toolbox installs
    "^code$",
    "^codium$",
    "^dolphin$",     -- a file manager is a directory with a window around it
}

-- Where a class is not the program's name. Empty until something needs it:
-- the classes on this machine (firefox, steam, dolphin) are already the word
-- you would use. This is the escape hatch for one that is not.
local NAMES = {}

-- The last part of a reverse-DNS class is usually the program
-- ("org.gnome.Nautilus" -> "nautilus") and sometimes filler, in which case the
-- part before it is the program ("org.telegram.desktop" -> "telegram").
local GENERIC = {
    desktop = true,
    app     = true,
    gui     = true,
    client  = true,
    bin     = true,
}

local function directory_app(class)
    for _, pattern in ipairs(DIRECTORY_APPS) do
        if class:match(pattern) then
            return true
        end
    end
    return false
end

-- The program's name, from its window class.
local function name_of(class)
    if NAMES[class] then
        return NAMES[class]
    end

    local parts = {}
    for part in class:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end

    local name = parts[#parts] or class
    if #parts > 1 and GENERIC[name:lower()] then
        name = parts[#parts - 1]
    end

    -- Lower case throughout, so a desktop named after a program sits beside
    -- one named after a directory without shouting.
    return name:lower()
end

-- The program a desktop is, or nil when it is not just the one.
--
-- Every window has to agree. A desktop with a browser and a terminal on it is
-- a desktop being worked on rather than a desktop that *is* the browser, and
-- it falls back to the directory like any other -- which is also why the
-- terminal does not have to be filtered out here.
local function app_label(id)
    local class

    for _, win in ipairs(hl.get_workspace_windows(id) or {}) do
        local this = win.class and tostring(win.class) or ""

        -- A window with no class at all is XWayland's drag surface (see the
        -- rule in windowrules.lua) and one or two splash screens: transient,
        -- unfocusable, and not what the desktop is. Counting them as a second
        -- program would take the name off for as long as one existed.
        if this ~= "" then
            if class and this ~= class then
                return nil
            end
            class = this
        end
    end

    if not class or directory_app(class) then
        return nil
    end

    return name_of(class)
end

-- quake.lua used to set this itself, back when the directory was the only
-- thing a desktop could be named after.
--
-- `ws` is a workspace, except when deskbinds is working out what to call a
-- desktop it has not created yet, where it is empty: a desktop with no id has
-- no windows and no terminal, so there is nothing to say about it.
deskbinds.set_labeller(function(ws)
    local id = ws and ws.id
    if not id then
        return nil
    end

    local directory = quake.label_for(id)
    if directory and directory ~= quake.HOME_LABEL then
        return directory
    end

    return app_label(id)
end)

-- A name from here follows the windows, so it has to be redone whenever they
-- change. deskbinds already renames on every workspace event; these are the
-- window ones it has no reason to care about.
--
-- window.move_to_workspace is the one that matters most and the one that is
-- easy to miss: SUPER+M sends a window to another desktop without opening or
-- closing anything, and without focus following it, so both desktops would
-- otherwise keep the names they had before the window moved. It fires with the
-- window already on its new desktop, which is all this needs -- the pass reads
-- the world rather than the event.
for _, event in ipairs({
    "window.open",
    "window.close",
    "window.move_to_workspace",
}) do
    hl.on(event, deskbinds.schedule_renumber)
end
