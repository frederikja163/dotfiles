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
--   SUPER + M            move the window        mixed
--   SUPER + SHIFT + M    move the column        mixed
--   SUPER + CTRL + M     move this desktop      mixed (screens only)
--
-- Inside a move mode a number means a *screen*. `d` there switches to a second
-- mode where it means a desktop on this screen, so SUPER+M d 3 sends the
-- window to desktop 3.
--   SUPER + S            size                   mixed
--   SUPER + D            desktop                one-shot
--   SUPER+SHIFT + D      display                one-shot
--
-- One-shot means the mode ends when the action fires, like `dw`. Sticky means
-- it stays until you leave. The split is not per mode but per key, and it
-- follows one question: is this a nudge you repeat, or a decision you make
-- once?
--
--   sticky    h/j/k/l anywhere, and Tab in a move mode -- shuffling a window
--             along or resizing it is something you do until it looks right
--   one-shot  a screen number, a desktop number, p in size, and everything in
--             the desktop and display modes -- naming a destination is
--             finished the moment it happens
--
-- Mixing the two in one mode is fine, but it costs that mode its catchall, and
-- add_exits explains why that is a consequence rather than a choice.
--
-- Whatever the keys do, a mode also ends on its own after IDLE_TIMEOUT with no
-- input: a mode is invisible apart from the bar, so one entered and forgotten
-- otherwise leaves the motion keys meaning the wrong thing indefinitely.
--
-- Modifiers therefore carry almost nothing. SHIFT reverses a motion (Tab),
-- widens a verb's scope (M), or marks the other variant of a letter
-- (keybinds.lua's SUPER+SHIFT+C for a force kill, SUPER+SHIFT+F for floating
-- beside fullscreen). CTRL appears once, on M. ALT is unused.
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

-- How long a mode waits for you before giving up, and how often it checks.
--
-- A mode is modal: until it ends, h/j/k/l mean something other than what they
-- mean everywhere else, and nothing says so except the submap name in the bar.
-- Enter one, get interrupted, and the keyboard stays in that state -- which
-- reads as the motion keys having broken, the same way a mode whose binds do
-- not match reads (see bind_in_mode).
--
-- Polled from one chain per mode entry rather than a fresh timer per keypress,
-- because an hl.timer cannot be cancelled: the handle has no cancel, stop,
-- kill, destroy or restart method -- probed, not assumed, against 0.56.2 --
-- and only a `__index` function, so there is nothing to enumerate either.
-- Re-arming per key would therefore leave one pending timer per keystroke, and
-- a held motion key repeats around 25 times a second. This way a keypress only
-- zeroes a counter and never allocates.
--
-- The cost is granularity: the tick is what the timeout is rounded to, so a
-- mode ends between IDLE_TIMEOUT - IDLE_TICK and IDLE_TIMEOUT after the last
-- key, not exactly at it.
local IDLE_TIMEOUT = 5000
local IDLE_TICK = 500

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

-- Which mode entry the running countdown belongs to, and how many ticks have
-- passed since a key.
--
-- The counter exists because a chain cannot be stopped, only made irrelevant.
-- Leave a mode and enter another inside the timeout and the first mode's chain
-- is still ticking; without a number to check, it would time the second one
-- out early.
local mode_entries = 0
local idle_ticks = 0

local function leave()
    -- Bumping this is what strands the countdown belonging to the mode being
    -- left. Escape does not come through here -- it is bound straight to the
    -- submap dispatcher -- which is why watch() checks the live submap too.
    mode_entries = mode_entries + 1
    hl.dispatch(hl.dsp.submap("reset"))
end

-- One tick of a mode's idle countdown, re-arming itself until the mode ends.
-- `type = "repeating"` would be the obvious way and never fires at all, so the
-- chain is hand-rolled; see the note in tests/run.sh.
local function watch(name, entry)
    hl.timer(function()
        -- Three ways this chain is no longer wanted: a newer entry has
        -- superseded it, the mode was left by hand (get_current_submap gives
        -- "" in normal mode), or some other mode is in front now. Checking the
        -- compositor rather than only our own counter means Escape and the
        -- catchall, neither of which runs any Lua of ours, still stop it.
        if mode_entries ~= entry or hl.get_current_submap() ~= name then
            return
        end

        idle_ticks = idle_ticks + 1
        if idle_ticks * IDLE_TICK >= IDLE_TIMEOUT then
            leave()
        else
            watch(name, entry)
        end
    end, { timeout = IDLE_TICK, type = "oneshot" })
end

-- Enter a mode and start its countdown.
--
-- Every way in goes through this, the handover from a move mode to its
-- by-desktop twin included: the countdown belongs to the mode you are now in,
-- not the one you came from. Only ever called from a bind, so no timer is
-- created while the config is loading -- which segfaults the compositor
-- outright, and is not catchable with pcall.
local function enter(name)
    mode_entries = mode_entries + 1
    idle_ticks = 0
    hl.dispatch(hl.dsp.submap(name))
    watch(name, mode_entries)
end

-- Report that the mode was just used, so its countdown starts over. Deliberately
-- just an assignment: this runs on every motion, including auto-repeat.
local function touch()
    idle_ticks = 0
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

-- The counterpart: an action that leaves the mode up, and restarts its
-- countdown. A nudge you repeat rather than a decision you make once.
--
-- Both wrappers take a function, so a bind that would otherwise be a bare
-- dispatcher value has to be wrapped in one -- `sticky(function()
-- hl.dispatch(hl.dsp.layout(m)) end)` rather than `sticky(hl.dsp.layout(m))`.
-- The latter is not callable and fails at the keypress, not at load.
local function sticky(action)
    return function()
        action()
        touch()
    end
end

-- The ways out of a mode.
--
-- Escape is the deliberate one and is always bound. It works because a bind
-- whose handler is "submap" is the one thing that stops handleKeybinds looking
-- at the rest of the list.
--
-- The catchall goes only in a mode where *every* bind is one-shot, and that is
-- not a preference. A catchall reads like "fire when nothing else matched",
-- and it is not: handleKeybinds collects every matching bind into a list first
-- and only sets its `found` flag afterwards, when the dispatchers run. So at
-- the moment the catchall is examined, `found` is still false even though the
-- real bind matched a moment earlier -- and both end up in the list, and both
-- run.
--
-- Where everything is one-shot that is harmless, and useful: an unbound key
-- cancels, and a bound one would have left anyway. Next to a sticky bind it is
-- fatal -- every nudge would kick you straight back out, which is exactly what
-- happened when size mode was first built this way and `h` resized once and
-- then left.
--
-- One sticky bind is therefore enough to disqualify a whole mode, which is why
-- the move modes no longer take a catchall: their motions repeat now, even
-- though their screen and by-desktop keys are still one-shot. The mixture is
-- fine -- oneshot() leaves on its own and needs no catchall to do it -- but the
-- escape hatch had to go with it. What that costs is real and was accepted
-- deliberately: an unbound key inside a move mode no longer cancels, it is
-- passed on to the focused window, so a stray keystroke types into whatever is
-- in front. Escape, the idle countdown and keybinds.lua's submap_universal
-- binds are the ways out that remain.
--
-- There is a way to have both, and it was rejected as too subtle to keep
-- right: leave the catchall in place and have each sticky bind re-assert its
-- own submap afterwards, declared after the catchall, exactly as HELD_KEYS
-- does below. It works -- the ordering is the same trick -- but it makes every
-- motion silently dependent on being declared in the right place, and the
-- failure mode is a mode that drops on one key and not another.
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

-- `every_bind_leaves`, not "is this a one-shot mode": a mode with even one
-- sticky bind cannot have the catchall, whatever the rest of it looks like.
-- Spelled out because passing `true` from a mode that has since grown a sticky
-- key is the one way to reintroduce the bug described above.
local function add_exits(name, every_bind_leaves)
    -- Escape with or without SUPER, for the reason in bind_in_mode. This is
    -- also why the power menu in keybinds.lua is *not* submap_universal: it
    -- sits on SUPER+Escape, and a universal bind matches inside a submap as
    -- well, so both would fire and leaving a mode would offer to log you out.
    bind_in_mode("Escape", hl.dsp.submap("reset"), { description = "Leave this mode" })

    if every_bind_leaves then
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
                    -- Sticky: shuffling a window along is a nudge you repeat
                    -- until it looks right, and having to retype SUPER+M
                    -- between each one made a two-column move feel like work.
                    bind_in_mode(key, sticky(action),
                                 { repeating = true,
                                   description = ("Move the %s %s"):format(scope.noun, d.label) })
                end
            end
        end

        if scope.desktop then
            -- Sticky as well, and for the same reason: stepping a window
            -- across three desktops is Tab Tab Tab, not three trips through
            -- the verb.
            bind_in_mode("Tab", sticky(function() scope.desktop(1) end),
                         { description = ("Move the %s to the next desktop"):format(scope.noun) })
            bind_in_mode("SHIFT + Tab", sticky(function() scope.desktop(-1) end),
                         { description = ("Move the %s to the previous desktop"):format(scope.noun) })
        end

        for n = 1, SCREENS do
            -- One-shot, unlike the motions above: naming a screen is a
            -- destination, not a nudge, and there is nothing to repeat once you
            -- are there.
            bind_in_mode(screen_key(n), oneshot(function() scope.screen(n) end),
                         { description = ("Move the %s to screen %d, or a new desktop if already there")
                                         :format(scope.noun, n) })
        end

        -- No catchall: the motions above are sticky now, and it would cancel
        -- the mode on every one of them. See add_exits.
        add_exits(scope.submap, false)

        -- `d` hands over to a second mode where the numbers mean desktops
        -- rather than screens, so "move this to desktop 3" can be said at all.
        --
        -- It used to have to be declared after add_exits, because the catchall
        -- would otherwise drop the mode *after* this had switched to the next
        -- one and land you in normal mode. These modes have no catchall any
        -- more, so that constraint is gone and the position is now only
        -- habit -- but the one below still holds it, so it stays put rather
        -- than inviting the question again.
        if scope.desktop_index then
            bind_in_mode("d", function() enter(desktop_submap_of(scope)) end,
                         { description = ("Move the %s to a desktop by number"):format(scope.noun) })
        end
    end)

    hl.bind(scope.entry, function() enter(scope.submap) end,
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
            bind_in_mode(key, sticky(function() hl.dispatch(hl.dsp.layout(message)) end),
                         { repeating = true, description = "Size: " .. what })
        end
    end

    -- Floating is deliberately not here. It was, on `f`, on the grounds that it
    -- is a shape change like the rest -- but nothing in this mode changes a
    -- window's size by degrees except the four motions, and floating takes the
    -- window out of the layout rather than resizing it. It sits next to
    -- fullscreen on SUPER+SHIFT+F now; see keybinds.lua.

    -- Promote is the one one-shot key in here, which is not an inconsistency:
    -- h/j/k/l and f are nudges you repeat until the shape is right, and moving
    -- a window to the front of the widest column is a single decision that is
    -- finished the moment it happens. Repeating it just cycles the stack past
    -- where you wanted it.
    --
    -- Safe next to the sticky keys above only because oneshot() leaves by
    -- itself. Doing this with a catchall instead would have broken every
    -- resize in the mode -- see add_exits.
    bind_in_mode("p", oneshot(function() hl.dispatch(hl.dsp.layout("cyclemain")) end),
                 { description = "Size: promote through the widest column, and leave" })

    -- Mostly sticky, so no catchall, for the reason in add_exits.
    add_exits(SUBMAP_SIZE, false)
end)

hl.bind(mainMod .. " + S", function() enter(SUBMAP_SIZE) end,
        { description = "Mode: size (h/j/k/l, p promote and leave)" })

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
