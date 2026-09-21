-- Standalone harness for modes.lua: stubs the hl API, loads the module, and
-- checks the shape of what it registered.
--
-- The point of this file is the cross-product. Every bind in modes.lua is
-- generated from a motion table, so the interesting failure is not "this chord
-- is wrong" but "this verb is missing a motion" -- something a list of
-- hand-written assertions would never notice, because the missing bind is
-- missing from the list too.
--
-- The other thing checked here cannot be seen any other way: a one-shot bind
-- that forgets to leave its mode is silently sticky. Hyprland has a per-bind
-- reset of its own but it is not reachable from Lua (see modes.lua), so the
-- wrapper is hand-rolled, and a wrapper is exactly the kind of thing that gets
-- forgotten when a bind is added in a hurry.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

-- deskbinds reads the pinned monitor order; keep it off the real, local file.
local pin_path = os.getenv("HYPR_MONITOR_ORDER") or "/tmp/hypr-monitor-order-test"
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "HYPR_MONITOR_ORDER" then
        return pin_path
    end
    return real_getenv(name)
end
do
    local f = assert(io.open(pin_path, "w"))
    f:write("")
    f:close()
end

-- Where a bind ends up: normal mode is submap = "".
local binds = {}       -- { [submap] = { [key] = { fn, opts, dispatcher } } }
local submaps = {}     -- declaration order
local dispatched = {}  -- what a bind did when driven

local current_submap = ""

local order = {}          -- { {submap, keys}, ... } in declaration order

local function record(submap, keys, action, opts)
    table.insert(order, { submap = submap, keys = keys })
    binds[submap] = binds[submap] or {}
    binds[submap][keys] = {
        opts = opts or {},
        -- A bind is given either a Lua function or a dispatcher value; keep
        -- whichever it was, since one-shot only applies to the former.
        fn = type(action) == "function" and action or nil,
        dispatcher = type(action) == "table" and action or nil,
    }
end

_G.hl = {
    layout = { register = function() end },
    on = function() end,
    -- Fires immediately and synchronously, which is what lets the idle
    -- countdown be tested at all: modes.lua polls with a chain of oneshot
    -- timers, so running each one inline collapses the whole countdown into
    -- the call that started it. The guard against that becoming an infinite
    -- recursion is get_current_submap below.
    timer = function(cb) cb() end,

    -- modes.lua asks the compositor which mode is in front, so that a
    -- countdown belonging to a mode already left cannot end the next one. Here
    -- that is whatever the harness says it is: "" outside define_submap, which
    -- is also what Hyprland reports in normal mode, so a countdown started by
    -- driving a bind stops on its first tick unless a test says otherwise.
    get_current_submap = function() return current_submap end,
    exec_cmd = function() end,
    workspace_rule = function() end,
    monitor = function() end,
    get_monitors = function() return {} end,
    get_workspaces = function() return {} end,
    get_workspace_windows = function() return {} end,
    get_active_monitor = function() return nil end,
    get_active_window = function() return nil end,

    bind = function(keys, action, opts)
        record(current_submap, keys, action, opts)
    end,

    define_submap = function(name, fn)
        table.insert(submaps, name)
        local previous = current_submap
        current_submap = name
        fn()
        current_submap = previous
    end,

    dispatch = function(d) table.insert(dispatched, d) end,

    dsp = {
        layout = function(m) return { kind = "layout", arg = m } end,
        exec_cmd = function(c) return { kind = "exec", arg = c } end,
        no_op = function() return { kind = "no_op" } end,
        submap = function(name) return { kind = "submap", arg = name } end,
        focus = function(a) return { kind = "focus", arg = a } end,
        window = {
            move = function(a) return { kind = "move", arg = a } end,
            float = function(a) return { kind = "float", arg = a } end,
            fullscreen = function(a) return { kind = "fullscreen", arg = a } end,
        },
        workspace = {
            rename = function(a) return { kind = "rename", arg = a } end,
            move = function(a) return { kind = "wsmove", arg = a } end,
        },
    },
}

local mod = require("modes")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-58s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-58s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

-- Run a bind and collect what it dispatched. Actions reach into deskbinds and
-- columns, which have no world to work on here, so a failure part-way through
-- is expected and ignored -- what is being checked is the dispatches, and the
-- mode-keeping ones come from modes.lua itself.
local function drive(bind)
    dispatched = {}
    if bind.fn then pcall(bind.fn) end
    return dispatched
end

-- The submap a bind ends up asking for: "reset" for a one-shot, a mode name
-- for an entry or a handover, and nil for a sticky bind, which asks for none.
local function ends_in_submap(bind)
    local seen = drive(bind)
    local last = bind.dispatcher or seen[#seen]
    if last and last.kind == "submap" then
        return last.arg
    end
    return nil
end

-- What the bind's *action* did, as opposed to what it did to the mode. Sticky
-- and one-shot wrappers both leave the action's own dispatch first.
local function action_arg(bind)
    if bind.dispatcher then
        return bind.dispatcher.arg
    end
    local seen = drive(bind)
    return seen[1] and seen[1].arg
end

-- Inside a mode, "SUPER + x" is the twin of the bare "x" (see bind_in_mode in
-- modes.lua): same action, no description, so the cheatsheet lists it once.
-- Checks that are about actions rather than keys look only at the bare ones.
local function is_twin(submap, keys)
    if submap == "" then
        return false
    end
    -- Every variant of a motion is prefixed with SUPER; the bare one is not.
    -- "SHIFT + Tab" is a motion in its own right, not a variant.
    return keys:match("^SUPER %+ ") ~= nil
end

local MODIFIER_KEYS = {
    Shift_L = true, Shift_R = true, Control_L = true, Control_R = true,
    Alt_L = true, Alt_R = true, Super_L = true, Super_R = true,
    Meta_L = true, Meta_R = true, ISO_Level3_Shift = true, Caps_Lock = true,
}

-- Neither a motion nor a way out: these exist only so that reaching for a
-- modifier does not cancel the mode.
local function is_exit(keys)
    return keys == "Escape" or keys == "SUPER + Escape" or keys == "catchall"
           or MODIFIER_KEYS[keys] == true
end

-- Where a bind sits in declaration order, which decides which of several
-- matching binds has the last word.
local function index_of(submap, keys)
    for i, entry in ipairs(order) do
        if entry.submap == submap and entry.keys == keys then return i end
    end
end

local function keys_in(submap)
    local out = {}
    for keys in pairs(binds[submap] or {}) do
        out[keys] = true
    end
    return out
end

----------------------------------------------------------------------------

print("scenario: the modes exist, and are named for reading")
-- Waybar prints the submap name verbatim, so these are display strings.
for _, name in ipairs(mod.submaps) do
    check("declared " .. name, binds[name] ~= nil, true)
end
check("no more than those five", #submaps, #mod.submaps)

print("scenario: normal mode navigates on every axis")
local normal = keys_in("")
check("focus left", normal["SUPER + h"], true)
check("focus down", normal["SUPER + j"], true)
check("focus up", normal["SUPER + k"], true)
check("focus right", normal["SUPER + l"], true)
check("arrow aliases too", normal["SUPER + left"], true)
check("next desktop", normal["SUPER + Tab"], true)
check("previous desktop", normal["SUPER + SHIFT + Tab"], true)
check("the mouse cycles desktops as well", normal["SUPER + mouse_down"], true)
for n = 1, mod.SCREENS do
    check("screen " .. n, normal["SUPER + " .. mod.screen_key(n)], true)
    -- CTRL is the second reading of a screen number: a desktop on screen n
    -- that does not exist yet. A separate chord rather than the old overload
    -- on "n is the screen you are already on", which with follow_mouse turned
    -- on where the cursor happened to be resting.
    check("a new desktop on screen " .. n, normal["SUPER + CTRL + " .. mod.screen_key(n)], true)
end

print("scenario: normal mode does NOT keep the old move/resize chords")
-- These are what the modes replaced. A leftover would still half-work, which
-- is worse than it being gone.
for _, keys in ipairs({
    "SUPER + SHIFT + h", "SUPER + SHIFT + l", "SUPER + SHIFT + j", "SUPER + SHIFT + k",
    "SUPER + CTRL + h",  "SUPER + CTRL + l",  "SUPER + CTRL + j",  "SUPER + CTRL + k",
    "SUPER + ALT + SHIFT + h", "SUPER + ALT + SHIFT + 1",
    -- SUPER+CTRL+1 is deliberately absent from this list: it is bound again,
    -- but as "a new desktop on screen 1" rather than whatever it once meant.
    "SUPER + SHIFT + 1", "SUPER + CTRL + SHIFT + 1",
}) do
    check("gone: " .. keys, normal[keys], nil)
end

print("scenario: every mode can be entered, and every entry is a submap switch")
-- The move and size entries go through modes.lua's enter(), which switches the
-- submap *and* starts the idle countdown, so they are Lua functions rather than
-- bare dispatchers now and have to be driven to see where they lead.
for _, scope in ipairs(mod.MOVE_SCOPES) do
    local entry = binds[""][scope.entry]
    check("entry bound: " .. scope.entry, entry ~= nil, true)
    check("...switches submap", entry and ends_in_submap(entry) ~= nil, true)
    check("...to " .. scope.submap, entry and ends_in_submap(entry), scope.submap)
    check("...and says so in the cheatsheet", entry and entry.opts.description ~= nil, true)
end
check("size is entered the same way", ends_in_submap(binds[""]["SUPER + S"]), "size")

print("scenario: the desktop verb, and display moved out of its way")
check("SUPER+D enters the desktop mode",
      binds[""]["SUPER + D"].dispatcher.arg, "desktop")
check("SUPER+SHIFT+D enters display",
      binds[""]["SUPER + SHIFT + D"].dispatcher.arg, "display")
local desk = keys_in("desktop")
for n = 1, mod.SCREENS do
    check("desktop " .. n .. " by number", desk[mod.screen_key(n)], true)
end
check("Tab steps to the next", desk["Tab"], true)
check("n makes one without naming a screen", desk["n"], true)
check("SHIFT+Tab to the previous", desk["SHIFT + Tab"], true)
-- Entered with a bare SUPER chord, so SHIFT is free inside it and SHIFT+Tab
-- keeps its meaning rather than being claimed as a held-chord variant.
check("...and they are different binds",
      desk["Tab"] and desk["SHIFT + Tab"] and binds["desktop"]["Tab"] ~= binds["desktop"]["SHIFT + Tab"], true)

print("scenario: every mode can be left")
-- Escape everywhere. A catchall only where *every* bind in the mode leaves on
-- its own: it fires alongside the bind that matched rather than instead of it,
-- so one sticky key is enough to make it cancel the mode mid-nudge. See
-- add_exits in modes.lua.
--
-- Which is why the move modes have none: their h/j/k/l and Tab repeat, even
-- though their screen keys are still one-shot. Only the pure one-shot modes
-- keep it -- the by-desktop twins reached with `d`, and desktop and display.
local HAS_CATCHALL = {
    ["move to desktop"] = true,
    ["move column to desktop"] = true,
    ["desktop"] = true,
    ["display"] = true,
}

for _, name in ipairs(mod.submaps) do
    local k = keys_in(name)
    check(name .. ": Escape", k["Escape"], true)
    check(name .. ": Escape with SUPER held", k["SUPER + Escape"], true)

    if HAS_CATCHALL[name] then
        check(name .. ": catchall", k["catchall"], true)
        -- Without ignore_mods the catchall only fires when no modifier is
        -- held, which is a hole exactly where being stuck is most likely.
        check(name .. ": catchall ignores mods",
              binds[name]["catchall"].opts.ignore_mods, true)
    else
        check(name .. " has a sticky key, so no catchall", k["catchall"], nil)
    end
end

print("scenario: reaching for a modifier does not cancel a one-shot mode")
-- Pressing SHIFT is a key event like any other, so the catchall sees it and
-- drops the mode -- which made SHIFT+Tab impossible to type. The modifier keys
-- are bound to re-enter the mode, and they must come *after* the catchall:
-- every matching bind runs, in declaration order, so the last one decides.
for _, name in ipairs(mod.submaps) do
    if HAS_CATCHALL[name] then -- the others have none to work around
        local catchall = index_of(name, "catchall")
        for _, key in ipairs({ "Shift_L", "Shift_R", "Control_L", "Alt_L", "Super_L" }) do
            local held = binds[name][key]
            check(name .. ": " .. key .. " is bound", held ~= nil, true)
            check(name .. ": " .. key .. " re-enters this mode",
                  held and held.dispatcher and held.dispatcher.arg, name)
            check(name .. ": " .. key .. " ignores mods",
                  held and held.opts.ignore_mods, true)
            check(name .. ": " .. key .. " is declared after the catchall",
                  index_of(name, key) > catchall, true)
        end
    end
end

print("scenario: a mode keeps working while its own chord is held")
-- move column is entered with SUPER+SHIFT+M, so SHIFT is likely still down
-- when the motion is typed; move desktop is entered with SUPER+CTRL+M.
check("move column takes SUPER+SHIFT+h", binds["move column"]["SUPER + SHIFT + h"] ~= nil, true)
check("move column takes SUPER+SHIFT+3", binds["move column"]["SUPER + SHIFT + 3"] ~= nil, true)
check("move desktop takes SUPER+CTRL+3", binds["move desktop"]["SUPER + CTRL + 3"] ~= nil, true)
-- ...but SUPER+SHIFT+Tab must stay "previous desktop" rather than being
-- claimed as a held-chord variant of plain Tab.
dispatched = {}
pcall(binds["move column"]["SUPER + SHIFT + Tab"].fn)
check("SUPER+SHIFT+Tab is still the previous-desktop motion",
      binds["move column"]["SUPER + SHIFT + Tab"] ~= nil, true)
check("...and plain Tab is a separate bind", binds["move column"]["Tab"] ~= nil, true)

print("scenario: every motion works with SUPER still held")
-- The bug this catches: entering a mode is a SUPER chord, so the motion after
-- it is usually typed with SUPER still down. A modmask-0 bind does not match
-- then, and the mode just sits there doing nothing.
local missing_twins = {}
for _, name in ipairs(mod.submaps) do
    for keys, bind in pairs(binds[name]) do
        local bare = not keys:match("^SUPER")
        -- The modifier binds already use ignore_mods, so they match whatever
        -- is held and need no twin.
        if bare and keys ~= "catchall" and not MODIFIER_KEYS[keys] then
            if binds[name]["SUPER + " .. keys] == nil then
                table.insert(missing_twins, name .. " / " .. keys)
            end
        end
    end
end
check("no motion is bare-only", #missing_twins, 0)
for _, name in ipairs(missing_twins) do print("       no SUPER twin: " .. name) end

-- ...and the twin must do the same thing, not merely exist.
local size_bare = binds["size"]["h"]
local size_held = binds["size"]["SUPER + h"]
check("the twin runs the same dispatcher",
      action_arg(size_held), action_arg(size_bare))
check("...and is left out of the cheatsheet", size_held.opts.description, nil)
check("...while the bare one carries it", size_bare.opts.description ~= nil, true)

print("scenario: the move verbs have the whole motion vocabulary")
-- Directions that do not apply are declared nil by the scope, so this asserts
-- what the scope itself says rather than a hardcoded list.
for _, scope in ipairs(mod.MOVE_SCOPES) do
    local k = keys_in(scope.submap)

    for _, d in ipairs(mod.DIRECTIONS) do
        local applies = scope.direction(d) ~= nil
        check(("%s: %s %s"):format(scope.submap, d.key, applies and "moves" or "does not apply"),
              k[d.key] == true, applies)
    end

    check(scope.submap .. ": Tab", k["Tab"] == true, scope.desktop ~= nil)
    check(scope.submap .. ": SHIFT + Tab", k["SHIFT + Tab"] == true, scope.desktop ~= nil)

    for n = 1, mod.SCREENS do
        check(("%s: screen %d"):format(scope.submap, n), k[mod.screen_key(n)], true)
        -- ...and the same number under CTRL, meaning a new desktop there,
        -- wherever the scope says that reading applies. It does not for a
        -- desktop: "send this desktop to a desktop that is not there" says
        -- nothing, so the move desktop mode declares screen_new = nil.
        check(("%s: a new desktop on screen %d"):format(scope.submap, n),
              k["CTRL + " .. mod.screen_key(n)] == true, scope.screen_new ~= nil)
    end
end

print("scenario: in a move mode, a destination leaves and a nudge does not")
-- The one that matters, and it is now a split rather than a rule: naming a
-- screen or a desktop ends the mode, while h/j/k/l and Tab keep it so the move
-- can be repeated. Both halves are silent when wrong -- a destination that
-- forgets oneshot() strands you in the mode, and a nudge that keeps it drops
-- you out after one press -- and nothing else in the config would say so.
--
-- Driven per key against what the key means, rather than counted, so that a
-- wrapper put on the wrong one of the two cannot cancel out in a total.
local declared = {}
for _, name in ipairs(mod.submaps) do declared[name] = true end

-- The motions, which must all keep the mode.
local NUDGES = { "h", "j", "k", "l", "left", "right", "up", "down", "Tab", "SHIFT + Tab" }

for _, scope in ipairs(mod.MOVE_SCOPES) do
    for _, keys in ipairs(NUDGES) do
        local bind = binds[scope.submap][keys]
        if bind then
            check(("%s: %s is a nudge, so the mode stays"):format(scope.submap, keys),
                  ends_in_submap(bind), nil)
        end
    end

    -- ...and the destinations, which must all end it.
    for n = 1, mod.SCREENS do
        local keys = mod.screen_key(n)
        check(("%s: screen %s is a destination, so the mode ends"):format(scope.submap, keys),
              ends_in_submap(binds[scope.submap][keys]), "reset")

        if scope.screen_new then
            check(("%s: a new desktop on screen %s ends it too"):format(scope.submap, keys),
                  ends_in_submap(binds[scope.submap]["CTRL + " .. keys]), "reset")
        end
    end
end

-- Nothing unaccounted for: every non-exit key in a move mode is either a nudge
-- that keeps the mode, a destination that resets it, or the `d` handover. A key
-- added later without a wrapper at all would land here.
local unclassified, handovers = {}, 0
local is_nudge = {}
for _, keys in ipairs(NUDGES) do is_nudge[keys] = true end

for _, scope in ipairs(mod.MOVE_SCOPES) do
    for keys, bind in pairs(binds[scope.submap]) do
        if not is_exit(keys) and not is_twin(scope.submap, keys) then
            local switches_to = ends_in_submap(bind)
            if switches_to and declared[switches_to] then
                handovers = handovers + 1
            elseif switches_to == "reset" then
                if is_nudge[keys] then
                    table.insert(unclassified, scope.submap .. " / " .. keys .. " (nudge that leaves)")
                end
            elseif switches_to == nil then
                if not is_nudge[keys] then
                    table.insert(unclassified, scope.submap .. " / " .. keys .. " (destination that stays)")
                end
            else
                table.insert(unclassified, scope.submap .. " / " .. keys .. " -> " .. tostring(switches_to))
            end
        end
    end
end
check("no move key is on the wrong side of the split", #unclassified, 0)
check("...plus the handovers to the by-desktop modes", handovers, 2)
for _, name in ipairs(unclassified) do print("       miswrapped: " .. name) end

print("scenario: the by-desktop modes stay one-shot all the way through")
-- What was asked for and is easy to lose: `d` then a number is a destination,
-- so it ends the mode even though the motions in the mode it came from do not.
for _, scope in ipairs(mod.MOVE_SCOPES) do
    if scope.desktop_index then
        local nested = scope.submap .. " to desktop"
        for n = 1, mod.SCREENS do
            check(("%s: desktop %s ends the mode"):format(nested, mod.screen_key(n)),
                  ends_in_submap(binds[nested][mod.screen_key(n)]), "reset")
        end
    end
end

print("scenario: the desktop verb can shuffle a desktop along its row")
local md = keys_in("move desktop")
check("h moves it left", md["h"], true)
check("l moves it right", md["l"], true)
check("j does not apply: a row is horizontal", md["j"], nil)
check("nor does k", md["k"], nil)
check("...and with the chord still held", md["SUPER + CTRL + h"], true)

print("scenario: `d` inside a move mode switches to counting desktops")
for _, scope in ipairs(mod.MOVE_SCOPES) do
    local nested = scope.submap .. " to desktop"
    if scope.desktop_index then
        check(scope.submap .. ": d hands over", binds[scope.submap]["d"] ~= nil, true)
        check("...to " .. nested, ends_in_submap(binds[scope.submap]["d"]), nested)
        check("...which exists", binds[nested] ~= nil, true)
        -- It used to have to come after the catchall or the catchall would undo
        -- the handover. These modes have no catchall now, so there is nothing
        -- left to order it against -- asserting the absence instead, since that
        -- is the thing that made the ordering unnecessary.
        check("...and the catchall that constrained its position is gone",
              binds[scope.submap]["catchall"], nil)

        local k = keys_in(nested)
        for n = 1, mod.SCREENS do
            check(nested .. ": desktop " .. n, k[mod.screen_key(n)], true)
        end
        check(nested .. ": Escape", k["Escape"], true)
        check(nested .. ": SUPER twin of a number",
              k["SUPER + " .. mod.screen_key(2)], true)
    else
        check(scope.submap .. ": no d, a desktop has no desktop to go to",
              binds[scope.submap]["d"], nil)
    end
end

print("scenario: the layout messages are spelled the way columns.lua reads them")
-- The sandbox cannot check these: a hidden nested instance has no focused
-- window, so a layout message that does nothing looks identical to one that
-- works. And columns.lua's layout_msg treats an unknown argument as a default
-- rather than an error ("movecol sideways" moves next), so a typo would be
-- silent on a real desktop too. Hence pinning the exact strings here.
local move_window = binds["move"]
local move_column = binds["move column"]

dispatched = {}
pcall(move_window["h"].fn)
check("h moves the window to the previous column", dispatched[1].arg, "movecol prev")
dispatched = {}
pcall(move_window["l"].fn)
check("l to the next", dispatched[1].arg, "movecol next")
dispatched = {}
pcall(move_window["j"].fn)
check("j moves it down inside its column", dispatched[1].arg, "movewin down")
dispatched = {}
pcall(move_window["k"].fn)
check("k moves it up", dispatched[1].arg, "movewin up")
dispatched = {}
pcall(move_column["h"].fn)
check("h swaps the whole column left", dispatched[1].arg, "swapcol prev")
dispatched = {}
pcall(move_column["l"].fn)
check("l swaps it right", dispatched[1].arg, "swapcol next")

check("size h narrows the column", action_arg(binds["size"]["h"]), "colresize -0.05")
check("size l widens it", action_arg(binds["size"]["l"]), "colresize 0.05")
check("size j grows the row", action_arg(binds["size"]["j"]), "rowresize 0.05")
check("size k shrinks it", action_arg(binds["size"]["k"]), "rowresize -0.05")
check("size p promotes", action_arg(binds["size"]["p"]), "cyclemain")
check("focus left is the layout's own direction letter",
      binds[""]["SUPER + h"].dispatcher.arg, "focus l")
check("focus right", binds[""]["SUPER + l"].dispatcher.arg, "focus r")
check("focus down", binds[""]["SUPER + j"].dispatcher.arg, "focus d")
check("focus up", binds[""]["SUPER + k"].dispatcher.arg, "focus u")

print("scenario: size resizes as long as you keep asking, and p ends it")
local size = binds["size"]
check("h resizes", size["h"] ~= nil, true)
check("...by dispatching to the layout", drive(size["h"])[1].kind, "layout")
check("...and repeats when held", size["h"].opts.repeating, true)

-- The split inside size, which is what was asked for: the shaping keys stay,
-- promote leaves. Checked key by key rather than as a blanket "nothing resets
-- the submap", because that blanket is exactly what p now breaks.
check("h keeps the mode", ends_in_submap(size["h"]), nil)
check("j keeps it", ends_in_submap(size["j"]), nil)
check("k keeps it", ends_in_submap(size["k"]), nil)
check("l keeps it", ends_in_submap(size["l"]), nil)
-- Floating moved out to SUPER+SHIFT+F in keybinds.lua, which this harness does
-- not load. Asserted as an absence so it cannot quietly come back: the mode is
-- for changing a window's size by degrees, and floating is not that.
check("float does not live here", size["f"], nil)
check("...nor under the held twin", size["SUPER + f"], nil)
check("promote does", size["p"] ~= nil, true)
check("...but promote leaves, being one decision", ends_in_submap(size["p"]), "reset")
check("...and its description says so", size["p"].opts.description:match("leave") ~= nil, true)

-- Only p. Anything else in here growing a reset would be the old bug coming
-- back, where a resize fired once and dropped the mode.
local leavers = {}
for keys, bind in pairs(size) do
    if not is_exit(keys) and not is_twin("size", keys) then
        if ends_in_submap(bind) == "reset" then
            table.insert(leavers, keys)
        end
    end
end
table.sort(leavers)
check("p is the only key in size that leaves", table.concat(leavers, ","), "p")

print("scenario: a mode gives up after a spell with no input")
-- The countdown is a chain of oneshot timers, and the harness runs each one
-- inline, so the whole thing resolves during the call that starts it -- but
-- only while the compositor still reports that mode as the one in front. That
-- is the guard being checked here as much as the timeout itself.
local real_submap = current_submap

current_submap = "size"
dispatched = {}
pcall(binds[""]["SUPER + S"].fn)
local last = dispatched[#dispatched]
check("a mode left to itself resets", last and last.kind == "submap" and last.arg, "reset")
check("...after entering it in the first place", dispatched[1].arg, "size")

-- The stale-countdown guard: a chain whose mode is no longer in front must do
-- nothing, or leaving one mode for another would end the second one early.
current_submap = "move"
dispatched = {}
pcall(binds[""]["SUPER + S"].fn)
local resets = 0
for _, d in ipairs(dispatched) do
    if d.kind == "submap" and d.arg == "reset" then resets = resets + 1 end
end
check("a countdown for a mode already left does nothing", resets, 0)

current_submap = real_submap

print("scenario: display is one-shot, and every key leaves the mode")
local display_oneshots, display_left = 0, 0
for keys, bind in pairs(binds["display"]) do
    if not is_exit(keys) and not is_twin("display", keys) then
        display_oneshots = display_oneshots + 1
        dispatched = {}
        pcall(bind.fn)
        local last = dispatched[#dispatched]
        if last and last.kind == "submap" and last.arg == "reset" then
            display_left = display_left + 1
        end
    end
end
check("every display key leaves the mode", display_left, display_oneshots)

print("scenario: display covers the screens and the two things that had no key")
local display = binds["display"]
for n = 1, mod.SCREENS do
    check("duplicate screen " .. n, display[mod.screen_key(n)] ~= nil, true)
end
check("re-pin the screen order", display["o"] ~= nil, true)
check("send every desktop home", display["h"] ~= nil, true)

print("scenario: every bind a person can reach has a description")
-- The cheatsheet is generated from these, and a bind without one is invisible
-- in it. The catchall is the deliberate exception: it is not a key.
local undescribed = {}
for submap, set in pairs(binds) do
    for keys, bind in pairs(set) do
        local describable = keys ~= "catchall" and not is_twin(submap, keys)
                            and not MODIFIER_KEYS[keys]
        -- Arrow aliases are deliberately left out so they do not double every
        -- direction entry in the list.
        local alias = keys:match("left$") or keys:match("right$")
                      or keys:match("up$") or keys:match("down$")
        if describable and not alias and not bind.opts.description then
            table.insert(undescribed, (submap == "" and "normal" or submap) .. " / " .. keys)
        end
    end
end
check("none missing", #undescribed, 0)
if #undescribed > 0 then
    for _, name in ipairs(undescribed) do print("       missing: " .. name) end
end

print()
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
