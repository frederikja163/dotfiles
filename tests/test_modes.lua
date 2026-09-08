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
    timer = function(cb) cb() end,
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
end

print("scenario: normal mode does NOT keep the old move/resize chords")
-- These are what the modes replaced. A leftover would still half-work, which
-- is worse than it being gone.
for _, keys in ipairs({
    "SUPER + SHIFT + h", "SUPER + SHIFT + l", "SUPER + SHIFT + j", "SUPER + SHIFT + k",
    "SUPER + CTRL + h",  "SUPER + CTRL + l",  "SUPER + CTRL + j",  "SUPER + CTRL + k",
    "SUPER + ALT + SHIFT + h", "SUPER + ALT + SHIFT + 1",
    "SUPER + SHIFT + 1", "SUPER + CTRL + 1", "SUPER + CTRL + SHIFT + 1",
}) do
    check("gone: " .. keys, normal[keys], nil)
end

print("scenario: every mode can be entered, and every entry is a submap switch")
for _, scope in ipairs(mod.MOVE_SCOPES) do
    local entry = binds[""][scope.entry]
    check("entry bound: " .. scope.entry, entry ~= nil, true)
    check("...switches submap", entry and entry.dispatcher and entry.dispatcher.kind, "submap")
    check("...to " .. scope.submap, entry and entry.dispatcher and entry.dispatcher.arg, scope.submap)
    check("...and says so in the cheatsheet", entry and entry.opts.description ~= nil, true)
end

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
-- Escape everywhere. A catchall only in the one-shot modes: it fires alongside
-- the bind that matched rather than instead of it, so in a sticky mode it
-- would throw you out on every keypress. See add_exits in modes.lua.
for _, name in ipairs(mod.submaps) do
    local k = keys_in(name)
    check(name .. ": Escape", k["Escape"], true)
    check(name .. ": Escape with SUPER held", k["SUPER + Escape"], true)

    if name == "size" then
        check(name .. " is sticky, so no catchall", k["catchall"], nil)
    else
        check(name .. ": catchall", k["catchall"], true)
        -- Without ignore_mods the catchall only fires when no modifier is
        -- held, which is a hole exactly where being stuck is most likely.
        check(name .. ": catchall ignores mods",
              binds[name]["catchall"].opts.ignore_mods, true)
    end
end

print("scenario: reaching for a modifier does not cancel a one-shot mode")
-- Pressing SHIFT is a key event like any other, so the catchall sees it and
-- drops the mode -- which made SHIFT+Tab impossible to type. The modifier keys
-- are bound to re-enter the mode, and they must come *after* the catchall:
-- every matching bind runs, in declaration order, so the last one decides.
for _, name in ipairs(mod.submaps) do
    if name ~= "size" then -- sticky, so it has no catchall to work around
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
      size_held.dispatcher.arg, size_bare.dispatcher.arg)
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
    end
end

print("scenario: every move is one-shot -- it fires, then leaves the mode")
-- The one that matters. A bind that forgets the wrapper stays in its mode, and
-- nothing else in the config would ever tell you.
local declared = {}
for _, name in ipairs(mod.submaps) do declared[name] = true end

local oneshots, left_the_mode, stuck, transitions = 0, 0, {}, 0
for _, scope in ipairs(mod.MOVE_SCOPES) do
    for keys, bind in pairs(binds[scope.submap]) do
        if not is_exit(keys) and not is_twin(scope.submap, keys) then
            dispatched = {}
            -- Actions reach into deskbinds and columns, which have no world to
            -- work on here; what matters is only what happens afterwards.
            if bind.fn then pcall(bind.fn) end

            local last = bind.dispatcher or dispatched[#dispatched]
            local switches_to = last and last.kind == "submap" and last.arg

            if switches_to == "reset" then
                oneshots = oneshots + 1
                left_the_mode = left_the_mode + 1
            elseif switches_to and declared[switches_to] then
                -- A handover to another mode rather than an action: `d`, where
                -- the numbers stop meaning screens and start meaning desktops.
                transitions = transitions + 1
            else
                oneshots = oneshots + 1
                table.insert(stuck, scope.submap .. " / " .. keys)
            end
        end
    end
end
check("every one-shot bind leaves its mode", left_the_mode, oneshots)
check("...and there were some to check", oneshots > 0, true)
check("...plus the handovers to the by-desktop modes", transitions, 2)
for _, name in ipairs(stuck) do print("       stays in its mode: " .. name) end

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
        check("...to " .. nested, binds[scope.submap]["d"].dispatcher.arg, nested)
        check("...which exists", binds[nested] ~= nil, true)
        check("...and is declared after the catchall, or it would be undone",
              index_of(scope.submap, "d") > index_of(scope.submap, "catchall"), true)

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

check("size h narrows the column", binds["size"]["h"].dispatcher.arg, "colresize -0.05")
check("size l widens it", binds["size"]["l"].dispatcher.arg, "colresize 0.05")
check("size j grows the row", binds["size"]["j"].dispatcher.arg, "rowresize 0.05")
check("size k shrinks it", binds["size"]["k"].dispatcher.arg, "rowresize -0.05")
check("size p promotes", binds["size"]["p"].dispatcher.arg, "cyclemain")
check("focus left is the layout's own direction letter",
      binds[""]["SUPER + h"].dispatcher.arg, "focus l")
check("focus right", binds[""]["SUPER + l"].dispatcher.arg, "focus r")
check("focus down", binds[""]["SUPER + j"].dispatcher.arg, "focus d")
check("focus up", binds[""]["SUPER + k"].dispatcher.arg, "focus u")

print("scenario: size is sticky, and its keys repeat")
local size = binds["size"]
check("h resizes", size["h"] ~= nil, true)
check("...by dispatching to the layout", size["h"].dispatcher.kind, "layout")
check("...and repeats when held", size["h"].opts.repeating, true)
-- Sticky: nothing in here resets the submap, which is the whole difference
-- from a move.
local sticky = true
for keys, bind in pairs(size) do
    if not is_exit(keys) and not is_twin("size", keys) then
        if bind.dispatcher and bind.dispatcher.kind == "submap" then
            sticky = false
        end
    end
end
check("no key in size leaves it by itself", sticky, true)
check("float lives here now, not on a chord", size["f"] ~= nil, true)
check("so does promote", size["p"] ~= nil, true)

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
