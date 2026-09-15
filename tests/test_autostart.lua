-- Standalone harness for autostart.lua: stubs the hl API, fires the startup
-- events in the order Hyprland does, and asserts how many times the bar is
-- started.
--
-- The order is the point, and the timer is held rather than fired on the spot
-- so the test can reproduce it. A nested instance showed that on boot every
-- monitor.added arrives *before* hyprland.start, and a restart scheduled from
-- those events is what raced the start and left two bars on screen: its pkill
-- ran before the first bar had spawned, killed nothing, and started a second.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

-- autostart.lua does nothing under the sandbox marker; the tests are not the
-- sandbox, so make sure the machine's environment cannot turn it off here.
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "HYPR_SANDBOX" then return nil end
    return real_getenv(name)
end

local events, execs, timers

local function reset()
    events, execs, timers = {}, {}, {}
    _G.hl = {
        on = function(event, fn) events[event] = fn end,
        exec_cmd = function(cmd) table.insert(execs, cmd) end,
        -- Held, not fired: the test decides when the deferred restart runs.
        timer = function(cb) table.insert(timers, cb) end,
    }

    -- Hyprland re-runs the module bodies on `hyprctl reload`, which is why the
    -- state below does not survive one; requiring it fresh is how the test
    -- models that reload.
    package.loaded.autostart = nil
    require("autostart")
end

local function flush()
    while #timers > 0 do
        table.remove(timers, 1)()
    end
end

local function waybar_starts()
    local n = 0
    for _, cmd in ipairs(execs) do
        if cmd == "waybar-main" then n = n + 1 end
    end
    return n
end

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-52s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-52s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

print("scenario: boot adds every monitor before hyprland.start")
reset()
events["monitor.added"]()
events["monitor.added"]()
events["monitor.added"]()
events["monitor.added"]()
events["hyprland.start"]()
check("the bar starts once", waybar_starts(), 1)
flush()
check("the boot monitor events add no second bar", waybar_starts(), 1)

print("scenario: a monitor plugged in after the session is up")
reset()
events["hyprland.start"]()
flush()
check("the bar is up after start", waybar_starts(), 1)
events["monitor.added"]()
flush()
check("a later monitor restarts the bar", waybar_starts(), 2)

print("scenario: a redock's burst of monitor events restarts once")
events["monitor.added"]()
events["monitor.added"]()
events["monitor.added"]()
flush()
check("the burst coalesces into one restart", waybar_starts(), 3)

print("scenario: after hyprctl reload there is no hyprland.start")
-- Hyprland re-runs the file but fires only config.reloaded, never
-- hyprland.start, so a monitor event must still start the bar even though the
-- fresh module has never seen a start.
reset()
events["monitor.added"]()
flush()
check("a monitor after a reload still starts the bar", waybar_starts(), 1)

if fail > 0 then
    print(("%d failed"):format(fail))
    os.exit(1)
end
print(("%d checks passed"):format(pass))
