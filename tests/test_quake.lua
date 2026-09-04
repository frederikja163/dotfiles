-- Standalone harness for quake.lua: stubs the hl API, then drives the module
-- and asserts what it toggles, spawns and moves.
--
-- The stub models the two things about special workspaces that the module
-- exists to work around: a monitor shows at most one of them, and it keeps
-- showing it when the desktop underneath changes.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local execs, rules, moved, events, world, mod

-- The special workspace on the focused monitor, as a bare name, or nil.
local function special_name()
    return world.special
end

local function reset()
    execs, rules, moved, events = {}, {}, {}, {}

    world = {
        desktop = { id = 1, name = "1.1", special = false },
        special = nil,   -- bare name, e.g. "quake-1"
        windows = {},
    }

    local next_address = 0

    function world.appear(ws_name)
        next_address = next_address + 1
        local win = {
            class = "quake",
            address = ("0x%x"):format(next_address),
            workspace = { name = ws_name },
        }
        table.insert(world.windows, win)
        if events["window.open"] then
            events["window.open"](win)
        end
        return win
    end

    function world.close(ws_name)
        for i = #world.windows, 1, -1 do
            if world.windows[i].workspace.name == ws_name then
                table.remove(world.windows, i)
            end
        end
    end

    _G.hl = {
        bind = function(keys, fn, opts) world.binds = world.binds or {}; world.binds[keys] = fn end,
        on = function(event, fn) events[event] = fn end,
        -- Fired immediately, except the backstop that clears a stuck spawn --
        -- running that at once would defeat what it is guarding.
        timer = function(cb, opts) if (opts and opts.timeout or 0) < 1000 then cb() end end,
        exec_cmd = function(cmd)
            table.insert(execs, cmd)
            -- The terminal turns up a moment later, in the workspace it was
            -- spawned into. Tests that want the gap call spawn_pending instead.
            local ws = cmd:match("^%[workspace (special:quake%-%d+) silent%]")
            if ws and not world.spawn_pending then
                world.appear(ws)
            end
        end,
        window_rule = function(spec) table.insert(rules, spec) end,
        get_windows = function() return world.windows end,
        get_active_monitor = function()
            return { name = "eDP-1", active_workspace = world.desktop }
        end,
        get_active_special_workspace = function()
            return world.special and { name = "special:" .. world.special } or nil
        end,
        dispatch = function(d) d.apply() end,
        dsp = {
            workspace = {
                -- Model the compositor: toggling the one already shown hides
                -- it, toggling any other shows that one instead.
                toggle_special = function(name)
                    return { kind = "toggle", name = name, apply = function()
                        -- Not `(world.special == name) and nil or name`: in Lua
                        -- that always yields name, because `true and nil` falls
                        -- through to the or.
                        if world.special == name then
                            world.special = nil
                        else
                            world.special = name
                        end
                    end }
                end,
            },
            focus = function(a)
                return { kind = "focus", arg = a, apply = function()
                    world.focused = a.window
                end }
            end,
            window = {
                move = function(a)
                    return { kind = "move", arg = a, apply = function()
                        table.insert(moved, a)
                    end }
                end,
            },
        },
    }

    package.loaded.quake = nil
    package.loaded.programs = nil
    mod = require("quake")
end

-- Switch desktop the way Hyprland does: the special workspace stays put, and
-- the module's sync hook is what has to deal with it.
local function switch_to(id)
    world.desktop = { id = id, name = "1." .. id, special = false }
    events["workspace.active"]()
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

print("scenario: the window rule")
reset()
check("one rule registered", #rules, 1)
local rule = rules[1] or {}
check("matches the quake class", rule.match and rule.match.class, "^quake$")
check("floating", rule.float, true)
check("full width, top 40%", rule.size, "monitor_w monitor_h*0.4")
check("flush to the top edge", rule.move, "0 0")
-- Both are drawn outside the window, so on a full-width terminal they spill
-- onto the monitor next door.
check("no border to spill sideways", rule.border_size, 0)
check("no shadow to spill sideways", rule.no_shadow, true)

print("scenario: first press spawns and shows")
reset()
mod.toggle()
check("spawned one terminal", #execs, 1)
check("into its desktop's own workspace",
      execs[1], "[workspace special:quake-1 silent] kitty --class quake")
check("and it is showing", special_name(), "quake-1")

print("scenario: pressing again hides, and does not spawn a second one")
mod.toggle()
check("hidden", special_name(), nil)
check("still one terminal", #execs, 1)
mod.toggle()
check("shown again", special_name(), "quake-1")
check("still one terminal", #execs, 1)

print("scenario: the terminal takes the keyboard")
reset()
mod.toggle()
-- follow_mouse would otherwise leave focus wherever the pointer is.
check("focused when it first appears", world.focused, "address:0x1")
world.focused = nil
mod.toggle()                         -- hide
check("not refocused on the way down", world.focused, nil)
mod.toggle()                         -- show again
check("focused again on the way back up", world.focused, "address:0x1")

print("scenario: a terminal appearing on a desktop you have left")
reset()
world.spawn_pending = true
mod.toggle()                         -- pressed, window not up yet
switch_to(2)                         -- moved on before it appeared
world.appear("special:quake-1")      -- it turns up now
check("does not steal the keyboard", world.focused, nil)

print("scenario: the terminal is closed by hand")
reset()
mod.toggle()
world.close("special:quake-1")
world.special = nil
mod.toggle()
check("a new one is started", #execs, 2)
check("and shown", special_name(), "quake-1")

print("scenario: hyprctl reload, which forgets every table in this file")
reset()
mod.toggle()
local windows_before = world.windows
local special_before = world.special
reset()                              -- the config is re-run from scratch
world.windows = windows_before       -- but the terminal is still on screen
world.special = special_before
mod.toggle()
check("no duplicate is started", #execs, 0)

print("scenario: two presses before the terminal has appeared")
reset()
world.spawn_pending = true           -- the window does not turn up yet
mod.toggle()
mod.toggle()
check("only one is started", #execs, 1)

print("scenario: Hyprland hid it behind our back (a program was launched)")
reset()
mod.toggle()
world.special = nil                -- what launching a program does
mod.toggle()
check("one press brings it back, not two", special_name(), "quake-1")

print("scenario: one terminal per desktop")
reset()
mod.toggle()
switch_to(2)
check("the terminal of the desktop left behind is put away", special_name(), nil)
mod.toggle()
check("desktop 2 gets its own", special_name(), "quake-2")
check("which is a second terminal", #execs, 2)
check("in its own workspace",
      execs[2], "[workspace special:quake-2 silent] kitty --class quake")

print("scenario: coming back to a desktop")
switch_to(1)
check("desktop 1 gets its own back, as it was left down", special_name(), "quake-1")
switch_to(2)
check("and desktop 2's returns too", special_name(), "quake-2")

print("scenario: a desktop left with the terminal up stays that way")
reset()
mod.toggle()
mod.toggle()                       -- hidden before leaving
switch_to(2)
switch_to(1)
check("nothing comes back", special_name(), nil)

print("scenario: programs launched from the terminal are evicted")
reset()
mod.toggle()
local win = { class = "firefox", address = "0xabc",
              workspace = { name = "special:quake-1" } }
events["window.open"](win)
check("moved out of the terminal's workspace", #moved, 1)
check("...onto the desktop", moved[1] and moved[1].workspace, 1)
check("...addressed by address", moved[1] and moved[1].window, "address:0xabc")

print("scenario: the terminal itself is left where it belongs")
reset()
mod.toggle()
events["window.open"]({ class = "quake", address = "0xdef",
                        workspace = { name = "special:quake-1" } })
check("not evicted", #moved, 0)
events["window.open"]({ class = "firefox", address = "0x111",
                        workspace = { name = "1.1" } })
check("an ordinary window is left alone", #moved, 0)

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
