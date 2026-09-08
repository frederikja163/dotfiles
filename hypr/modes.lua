-- Every key, in one place: normal mode and the modes reachable from it.
--
-- The grammar is verbs and motions, the way vim has operators and motions. A
-- verb says what happens, a motion says where, and the motion vocabulary is
-- the same one used to navigate, so learning it once covers everything:
--
--   h j k l    a direction inside the desktop
--   Tab        the next desktop on this screen; SHIFT+Tab the previous one
--   1 .. 0     screen n -- or, when it is the screen you are already on, a
--              brand-new desktop on it (see deskbinds.lua for that overload)
--
-- Normal mode navigates: SUPER + a motion goes there. A verb key enters a
-- mode, and inside a mode the motions work with or without SUPER held -- see
-- bind_in_mode, which is not a nicety but the difference between the modes
-- working and appearing to do nothing at all.
--
--   SUPER + M            move the window        one-shot
--   SUPER + SHIFT + M    move the column        one-shot
--   SUPER + CTRL + M     move this desktop      one-shot (screens only)
--
-- Inside a move mode a number means a *screen*. `d` there switches to a second
-- mode where it means a desktop on this screen, so SUPER+M d 3 sends the
-- window to desktop 3.
--   SUPER + S            size                   sticky
--   SUPER + D            desktop                one-shot
--   SUPER+SHIFT + D      display                one-shot
--
-- One-shot means the mode ends when the action fires, like `dw`. Sticky means
-- it stays until you leave, which is right for resizing -- a nudge you repeat
-- -- and wrong for a move, which is one decision. Size is the only sticky one,
-- and add_exits below explains why that is load-bearing rather than taste.
--
-- Modifiers therefore carry almost nothing. SHIFT reverses a motion (Tab),
-- widens a verb's scope (M), or marks the harsher variant of a letter
-- (keybinds.lua's SUPER+SHIFT+C). CTRL appears once, on M. ALT is unused.
--
--
-- Things that cost an afternoon each, all verified against Hyprland 0.56.2:
--
-- * A catchall is a *key string*, not an option. `hl.bind("catchall", ...)`
--   works; `hl.bind("", fn, { catchall = true })` registers a bind that can
--   never match and says nothing -- hl.bind validates no option names at all,
--   so a misspelling is silent. Check `hyprctl binds -j` for `catch_all:
--   true` rather than trusting the source. A catchall outside a submap is
--   refused loudly, which tests/run.sh would catch.
--
-- * A catchall only matches when no modifier is held unless it is given
--   `ignore_mods`, because handleKeybinds compares modmasks first. Without it
--   the escape hatch has a hole exactly where a stuck mode is most likely.
--
-- * A catchall does not mean "when nothing else matched". It runs *as well as*
--   the bind that matched, so it belongs only in a one-shot mode -- see
--   add_exits, which is where that is spelled out.
--
-- * hl.dsp.submap takes a bare string. A table -- `{ submap = "move" }` --
--   throws, and pcall reports success while the error surfaces only in the
--   parsing result at the end.
--
-- * There is no way to reach Hyprland's own per-bind submap reset from Lua, so
--   one-shot is hand-rolled: oneshot() below dispatches submap("reset") after
--   the action. A bind that forgets the wrapper silently becomes sticky, which
--   is what tests/test_modes.lua exists to catch.
--
-- * Entering a submap that was never defined is loud and leaves you in the one
--   you were in, so a typo cannot strand you somewhere nameless.
--
-- * hl.define_submap is additive: calling it twice with the same name keeps
--   both sets of binds. Everything is still declared here, so the motion table
--   has one home rather than being scattered across the modules it drives.

local programs = require("programs")
local columns = require("columns")
local deskbinds = require("deskbinds")

local mainMod = programs.mainMod

local RESIZE_STEP = 0.05

----------------------------------------------------------------------------
-- Mode plumbing
----------------------------------------------------------------------------

local SUBMAP_MOVE_WINDOW  = "move"
local SUBMAP_MOVE_COLUMN  = "move column"
local SUBMAP_MOVE_DESKTOP = "move desktop"
local SUBMAP_SIZE         = "size"
local SUBMAP_DESKTOP      = "desktop"
local SUBMAP_DISPLAY      = "display"

-- Names are what Waybar's hyprland/submap module prints, so they are written
-- for reading rather than for code. Spaces are legal in a submap name.

local function leave()
    hl.dispatch(hl.dsp.submap("reset"))
end

-- Bind a key inside a mode, for every way the keys might still be held down.
--
-- Entering a mode is a chord, so the natural thing is to keep holding it and
-- type the motion -- which is how every bind in this config worked before
-- there were modes. A bind with modmask 0 does not match while SUPER is down,
-- so without this every motion silently does nothing for anyone who does not
-- let go first. It does nothing *visible* either: the mode stays on, so it
-- reads as the whole keyboard having died. That is exactly how it felt the
-- first time this config was used for real.
--
-- So each key is bound bare, with SUPER, and with whatever entered this mode
-- (SUPER+SHIFT for the column verb, SUPER+CTRL for the desktop one).
--
-- `taken` guards the one collision this can cause: "SHIFT + Tab" is already
-- the previous-desktop motion, so the column verb -- entered with SHIFT -- must
-- not also claim "SUPER + SHIFT + Tab" for the *next* desktop. First binding
-- wins, and the motions are declared before their variants.
--
-- Variants carry no description, so the cheatsheet lists each motion once.
local mode_prefixes, taken = { "" }, {}

local function bind_in_mode(key, action, opts)
    for i, prefix in ipairs(mode_prefixes) do
        local keys = prefix .. key

        if not taken[keys] then
            taken[keys] = true

            if i == 1 then
                hl.bind(keys, action, opts)
            else
                local variant = {}
                for k, v in pairs(opts or {}) do
                    variant[k] = v
                end
                variant.description = nil
                hl.bind(keys, action, variant)
            end
        end
    end
end

-- Declare a mode, with the chord that enters it, so its keys keep working
-- while that chord is held.
local function define_mode(name, entry, body)
    local prefixes = { "", mainMod .. " + " }

    -- "SUPER + SHIFT + M" -> "SUPER + SHIFT + ", the modifiers minus the verb.
    local held = entry:match("^(.*)%s%+%s%S+$")
    if held and held ~= mainMod then
        table.insert(prefixes, held .. " + ")
    end

    mode_prefixes, taken = prefixes, {}
    hl.define_submap(name, body)
    mode_prefixes, taken = { "" }, {}
end

-- Wrap an action so the mode ends with it. Every bind in a one-shot mode goes
-- through this; see the note at the top about what happens when one does not.
local function oneshot(action)
    return function()
        action()
        leave()
    end
end

-- The ways out of a mode.
--
-- Escape is the deliberate one and is always bound. It works because a bind
-- whose handler is "submap" is the one thing that stops handleKeybinds looking
-- at the rest of the list.
--
-- The catchall is only added to one-shot modes, and that is not a preference.
-- A catchall reads like "fire when nothing else matched", and it is not:
-- handleKeybinds collects every matching bind into a list first and only sets
-- its `found` flag afterwards, when the dispatchers run. So at the moment the
-- catchall is examined, `found` is still false even though the real bind
-- matched a moment earlier -- and both end up in the list, and both run.
--
-- In a one-shot mode that is harmless, and useful: an unbound key cancels, and
-- a bound one would have left anyway. In a sticky mode it is fatal -- every
-- nudge would kick you straight back out, which is exactly what happened when
-- size mode was first built this way and `h` resized once and then left.
--
-- So sticky modes are left by Escape, or by the submap_universal binds in
-- keybinds.lua. An unbound key inside one does nothing to the mode; it is
-- passed on to the focused window, since nothing consumed it.
-- The modifier keys, which have to be held before a shifted motion can be
-- typed at all. A press of one of these is a key event like any other, so the
-- catchall below would treat reaching for SHIFT as "some other key, cancel" --
-- and SHIFT+Tab, the previous-desktop motion, could never be typed: the mode
-- ended the instant SHIFT went down.
--
-- The fix is to bind them to *this* submap, declared AFTER the catchall, and
-- the order is the whole trick. Every matching bind runs, in the order it was
-- declared, so a modifier press first hits the catchall (which drops the mode)
-- and then this (which puts it straight back). The net effect is that nothing
-- happened, which is what reaching for SHIFT should do.
--
-- Declaring them before the catchall does not work, and this cost an evening:
-- Hyprland stops collecting binds when it hits one whose handler is "submap",
-- which would skip the catchall entirely -- but in a Lua config *every* bind
-- is registered as an opaque "__lua" callback, so that short-circuit can never
-- fire here. `hyprctl binds -j` shows it: dispatcher is "__lua" even for
-- hl.dsp.submap. Nothing in a Lua config can stop a later bind from running.
--
-- ignore_mods because the press arrives with whatever is already held: SHIFT
-- pressed while SUPER is down is modmask 64, not 0.
local HELD_KEYS = {
    "Shift_L", "Shift_R",
    "Control_L", "Control_R",
    "Alt_L", "Alt_R",
    "Super_L", "Super_R",
    "Meta_L", "Meta_R",
    "ISO_Level3_Shift", "Caps_Lock",
}

local function add_exits(name, one_shot)
    -- Escape with or without SUPER, for the reason in bind_in_mode. This is
    -- also why the power menu in keybinds.lua is *not* submap_universal: it
    -- sits on SUPER+Escape, and a universal bind matches inside a submap as
    -- well, so both would fire and leaving a mode would offer to log you out.
    bind_in_mode("Escape", hl.dsp.submap("reset"), { description = "Leave this mode" })

    if one_shot then
        hl.bind("catchall", hl.dsp.submap("reset"), { ignore_mods = true })

        -- After the catchall, deliberately. See above.
        for _, key in ipairs(HELD_KEYS) do
            hl.bind(key, hl.dsp.submap(name), { ignore_mods = true })
        end
    end
end

----------------------------------------------------------------------------
-- Motions
----------------------------------------------------------------------------

-- Directions, as the layout names them. `label` is for descriptions, and the
-- resize columns say what h/j/k/l do to a window's size.
local DIRECTIONS = {
    { key = "h", keys = { "h", "left" },  label = "left",  focus = "l", col = "prev", win = nil,    resize = -RESIZE_STEP, axis = "col" },
    { key = "l", keys = { "l", "right" }, label = "right", focus = "r", col = "next", win = nil,    resize =  RESIZE_STEP, axis = "col" },
    { key = "j", keys = { "j", "down" },  label = "down",  focus = "d", col = nil,    win = "down", resize =  RESIZE_STEP, axis = "row" },
    { key = "k", keys = { "k", "up" },    label = "up",    focus = "u", col = nil,    win = "up",   resize = -RESIZE_STEP, axis = "row" },
}

-- Screen slots. Ten of them always, whatever is plugged in: a screen that
-- appears later has to work without a config reload, and deskbinds' actions
-- already do nothing for a slot with no monitor in it.
local SCREENS = 10

local function screen_key(n)
    return tostring(n % 10) -- slot 10 is the "0" key
end

----------------------------------------------------------------------------
-- Normal mode: navigation
----------------------------------------------------------------------------

-- Focus. Wraps inside the desktop and never crosses screens, so these binds do
-- not care how the monitors are arranged -- the number keys are what cross.
for _, d in ipairs(DIRECTIONS) do
    for i, key in ipairs(d.keys) do
        hl.bind(mainMod .. " + " .. key, hl.dsp.layout("focus " .. d.focus),
                { repeating = true,
                  -- The arrow aliases stay out of the cheatsheet rather than
                  -- doubling every entry in it.
                  description = i == 1 and ("Focus the window " .. d.label) or nil })
    end
end

-- The desktop axis. This is the one place SHIFT means "backwards": on a
-- cycler that is what every other program has already taught, and the mouse
-- cycler below has the same shape.
hl.bind(mainMod .. " + Tab", function() deskbinds.focus_neighbour_desktop(1) end,
        { repeating = true, description = "Next desktop on this screen" })
hl.bind(mainMod .. " + SHIFT + Tab", function() deskbinds.focus_neighbour_desktop(-1) end,
        { repeating = true, description = "Previous desktop on this screen" })

hl.bind(mainMod .. " + mouse_down", function() deskbinds.focus_neighbour_desktop(1) end,
        { description = "Next desktop on this screen" })
hl.bind(mainMod .. " + mouse_up", function() deskbinds.focus_neighbour_desktop(-1) end,
        { description = "Previous desktop on this screen" })

-- The screen axis.
for n = 1, SCREENS do
    hl.bind(mainMod .. " + " .. screen_key(n), function() deskbinds.focus_screen(n) end,
            { description = ("Screen %d: go there, or a new desktop if already there"):format(n) })
end

----------------------------------------------------------------------------
-- Move: the window, its column, or the whole desktop
----------------------------------------------------------------------------

-- One table per scope, so a motion added here lands under every verb it makes
-- sense for. `nil` means the motion does not apply at that scope: a column
-- does not move up or down, and a desktop only goes to another screen.
-- "move" -> "move to desktop", "move column" -> "move column to desktop".
-- Waybar prints these, so they are written to be read.
local function desktop_submap_of(scope)
    return scope.submap .. " to desktop"
end

local MOVE_SCOPES = {
    {
        submap = SUBMAP_MOVE_WINDOW,
        entry = mainMod .. " + M",
        noun = "window",
        direction = function(d)
            -- Horizontally a window moves between columns; vertically it moves
            -- within the one it is in.
            local message = d.col and ("movecol " .. d.col) or ("movewin " .. d.win)
            return function() hl.dispatch(hl.dsp.layout(message)) end
        end,
        desktop = function(step) deskbinds.move_window_to_neighbour_desktop(step) end,
        screen = function(n) deskbinds.move_window_to_screen(n) end,
        desktop_index = function(n) deskbinds.move_window_to_desktop_index(n) end,
    },
    {
        submap = SUBMAP_MOVE_COLUMN,
        entry = mainMod .. " + SHIFT + M",
        noun = "column",
        direction = function(d)
            if not d.col then
                return nil
            end
            return function() hl.dispatch(hl.dsp.layout("swapcol " .. d.col)) end
        end,
        desktop = function(step) deskbinds.move_column_to_neighbour_desktop(step) end,
        screen = function(n) deskbinds.move_column_to_screen(n) end,
        desktop_index = function(n) deskbinds.move_column_to_desktop_index(n) end,
    },
    {
        submap = SUBMAP_MOVE_DESKTOP,
        entry = mainMod .. " + CTRL + M",
        noun = "desktop",
        -- Left and right only: a desktop's row is horizontal, and there is
        -- nothing above or below it to swap with.
        direction = function(d)
            if not d.col then
                return nil
            end
            local step = d.col == "prev" and -1 or 1
            return function() deskbinds.move_desktop_in_row(step) end
        end,
        -- A desktop cannot move to a desktop; only to another screen.
        desktop = nil,
        desktop_index = nil,
        screen = function(n) deskbinds.move_desktop_to_screen(n) end,
    },
}

for _, scope in ipairs(MOVE_SCOPES) do
    define_mode(scope.submap, scope.entry, function()
        for _, d in ipairs(DIRECTIONS) do
            -- A scope answers with the action for that direction, or nil where
            -- the direction means nothing to it -- a column does not move up or
            -- down, and a desktop only moves along its row.
            local action = scope.direction(d)
            if action then
                for _, key in ipairs(d.keys) do
                    bind_in_mode(key, oneshot(action),
                                 { description = ("Move the %s %s"):format(scope.noun, d.label) })
                end
            end
        end

        if scope.desktop then
            bind_in_mode("Tab", oneshot(function() scope.desktop(1) end),
                         { description = ("Move the %s to the next desktop"):format(scope.noun) })
            bind_in_mode("SHIFT + Tab", oneshot(function() scope.desktop(-1) end),
                         { description = ("Move the %s to the previous desktop"):format(scope.noun) })
        end

        for n = 1, SCREENS do
            bind_in_mode(screen_key(n), oneshot(function() scope.screen(n) end),
                         { description = ("Move the %s to screen %d, or a new desktop if already there")
                                         :format(scope.noun, n) })
        end

        add_exits(scope.submap, true)

        -- `d` hands over to a second mode where the numbers mean desktops
        -- rather than screens, so "move this to desktop 3" can be said at all.
        --
        -- Declared after add_exits, and that is load-bearing: every matching
        -- bind runs in declaration order, so the catchall would otherwise drop
        -- the mode *after* this had switched to the next one, landing you back
        -- in normal mode. Same reason the modifier keys come last. See the
        -- long note in add_exits.
        if scope.desktop_index then
            bind_in_mode("d", hl.dsp.submap(desktop_submap_of(scope)),
                         { description = ("Move the %s to a desktop by number"):format(scope.noun) })
        end
    end)

    hl.bind(scope.entry, hl.dsp.submap(scope.submap),
            { description = ("Mode: move the %s (h/j/k/l, Tab, 1-0 screens, d desktops)")
                            :format(scope.noun) })
end

----------------------------------------------------------------------------
-- ...and where `d` leads: the numbers now mean desktops on this screen
----------------------------------------------------------------------------
--
-- A second mode rather than a modifier, because a number has to mean one
-- thing at a time: 3 is screen 3 in the move modes and desktop 3 in here, and
-- the key you pressed to get here is what says which.
--
-- Entered from inside another mode, so it cannot be reached by a chord and has
-- no entry bind of its own. Its keys are still bound with the SUPER variants,
-- since SUPER is very likely still held from the verb that started all this.
for _, scope in ipairs(MOVE_SCOPES) do
    if scope.desktop_index then
        define_mode(desktop_submap_of(scope), scope.entry, function()
            for n = 1, SCREENS do
                bind_in_mode(screen_key(n), oneshot(function() scope.desktop_index(n) end),
                             { description = ("Move the %s to desktop %d on this screen")
                                             :format(scope.noun, n) })
            end

            add_exits(desktop_submap_of(scope), true)
        end)
    end
end

----------------------------------------------------------------------------
-- Size: sticky, because resizing is a nudge you repeat
----------------------------------------------------------------------------

define_mode(SUBMAP_SIZE, mainMod .. " + S", function()
    for _, d in ipairs(DIRECTIONS) do
        -- Widening a window is widening its column, which is why the
        -- horizontal keys go through colresize and the vertical ones do not.
        local message = d.axis == "col"
            and ("colresize %.2f"):format(d.resize)
            or ("rowresize %.2f"):format(d.resize)

        local what = d.axis == "col"
            and (d.resize > 0 and "wider" or "narrower")
            or (d.resize > 0 and "taller" or "shorter")

        for _, key in ipairs(d.keys) do
            bind_in_mode(key, hl.dsp.layout(message),
                         { repeating = true, description = "Size: " .. what })
        end
    end

    -- Floating and promoting are both shape, so they live here rather than
    -- spending a chord each in normal mode.
    bind_in_mode("f", hl.dsp.window.float({ action = "toggle" }),
                 { description = "Size: toggle floating" })
    bind_in_mode("p", hl.dsp.layout("cyclemain"),
                 { description = "Size: promote through the widest column" })

    -- Sticky: no catchall, for the reason in add_exits.
    add_exits(SUBMAP_SIZE, false)
end)

hl.bind(mainMod .. " + S", hl.dsp.submap(SUBMAP_SIZE),
        { description = "Mode: size (h/j/k/l, f float, p promote)" })

----------------------------------------------------------------------------
-- Desktop: go to one of this screen's desktops by number
----------------------------------------------------------------------------
--
-- The number keys address *screens* in normal mode, so addressing desktops
-- needs a verb of its own rather than another modifier. SUPER+D then 2 is the
-- second desktop on this screen -- the second button on the bar -- whichever
-- global workspace id it happens to have.
--
-- Tab is here as well as in normal mode, so that having entered the mode you
-- are not forced back out to step one along.
--
-- One-shot: going to a desktop is a single decision.
define_mode(SUBMAP_DESKTOP, mainMod .. " + D", function()
    for n = 1, SCREENS do
        bind_in_mode(screen_key(n), oneshot(function() deskbinds.focus_desktop_index(n) end),
                     { description = ("Desktop %d on this screen"):format(n) })
    end

    bind_in_mode("Tab", oneshot(function() deskbinds.focus_neighbour_desktop(1) end),
                 { description = "The next desktop on this screen" })
    bind_in_mode("SHIFT + Tab", oneshot(function() deskbinds.focus_neighbour_desktop(-1) end),
                 { description = "The previous desktop on this screen" })

    -- Making a desktop without naming a screen.
    --
    -- SUPER+n does this too, but only if n is the screen you are on -- and with
    -- follow_mouse the screen you are on is wherever the *cursor* is, not where
    -- you are looking. Press SUPER+1 while the mouse happens to rest on the
    -- other screen and you get "go to screen 1" instead of a new desktop, which
    -- is why it felt like the desktop appeared at random.
    --
    -- This asks for the same thing without having to be right about which
    -- screen that is.
    bind_in_mode("n", oneshot(function() deskbinds.new_desktop_here(true) end),
                 { description = "A new desktop here, kept while empty" })

    add_exits(SUBMAP_DESKTOP, true)
end)

hl.bind(mainMod .. " + D", hl.dsp.submap(SUBMAP_DESKTOP),
        { description = "Mode: desktop (1-0 by number, Tab to step, n for a new one)" })

----------------------------------------------------------------------------
-- Display: the screens themselves
----------------------------------------------------------------------------

-- One-shot, unlike size: duplicating a screen, re-pinning the order and
-- sending desktops home are each a single decision, not a nudge you repeat.
-- That also keeps it clear of the catchall problem described in add_exits.
define_mode(SUBMAP_DISPLAY, mainMod .. " + SHIFT + D", function()
    for n = 1, SCREENS do
        bind_in_mode(screen_key(n), oneshot(function() deskbinds.toggle_mirror_screen(n) end),
                     { description = ("Display: duplicate/extend screen %d"):format(n) })
    end

    -- Both of these had no key at all before: the first was only ever a script
    -- run by hand, the second only ever fired by the monitor.added event.
    bind_in_mode("o", oneshot(function() hl.dispatch(hl.dsp.exec_cmd("dotfiles-monitor-order")) end),
                 { description = "Display: re-pin the screen order" })
    bind_in_mode("h", oneshot(function() deskbinds.restore_homes() end),
                 { description = "Display: send every desktop back to its own screen" })

    add_exits(SUBMAP_DISPLAY, true)
end)

-- On SHIFT+D rather than D: duplicating a screen and re-pinning the monitor
-- order are things you do when the hardware changes, which is rare, and the
-- plain key is worth more to the desktops you switch between all day.
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.submap(SUBMAP_DISPLAY),
        { description = "Mode: display (1-0 duplicate, o re-pin, h desktops home)" })

-- Exported for tests, which check the cross-product rather than a list of
-- chords: every scope should have every motion that applies to it.
return {
    DIRECTIONS = DIRECTIONS,
    SCREENS = SCREENS,
    MOVE_SCOPES = MOVE_SCOPES,
    submaps = {
        SUBMAP_MOVE_WINDOW,
        SUBMAP_MOVE_COLUMN,
        SUBMAP_MOVE_DESKTOP,
        SUBMAP_MOVE_WINDOW .. " to desktop",
        SUBMAP_MOVE_COLUMN .. " to desktop",
        SUBMAP_SIZE,
        SUBMAP_DESKTOP,
        SUBMAP_DISPLAY,
    },
    screen_key = screen_key,
}
