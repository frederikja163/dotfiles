-- Standalone harness for monitors.lua: stubs the hl API with a monitor world,
-- then fires the registered handlers and asserts the hl.monitor() calls that
-- place the row.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

-- monitors.lua reads the pinned monitor order from $HYPR_MONITOR_ORDER; the
-- os.getenv patch keeps it on the scratch file and off the machine's real one.
local pin_path = os.getenv("HYPR_MONITOR_ORDER") or "/tmp/hypr-monitor-order-test"
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "HYPR_MONITOR_ORDER" then
        return pin_path
    end
    return real_getenv(name)
end

local function set_pin(contents)
    local f = assert(io.open(pin_path, "w"))
    f:write(contents)
    f:close()
end
set_pin("") -- baseline: nothing pinned, so id order

local monitor_calls, world, events, apply

local function reset(w)
    world = w
    monitor_calls, events = {}, {}

    _G.hl = {
        monitor = function(spec)
            table.insert(monitor_calls, spec)
            for _, m in ipairs(world.monitors) do
                if m.name == spec.output then
                    m.mirroring = (spec.mirror ~= nil and spec.mirror ~= "")
                        and spec.mirror or nil
                end
            end
        end,
        get_monitors = function()
            -- Hyprland returns monitors in id order, and drops a mirroring
            -- output from the list entirely.
            local out = {}
            for _, m in ipairs(world.monitors) do
                if not m.mirroring then table.insert(out, m) end
            end
            table.sort(out, function(a, b) return a.id < b.id end)
            return out
        end,
        on = function(event, fn) events[event] = fn end,
        timer = function(cb) cb() end, -- fire immediately in tests
    }

    package.loaded.monitors = nil
    package.loaded.monitorpin = nil
    mod = require("monitors")
    -- hyprland.start and config.reloaded call apply_pinned directly; the test
    -- drives it through the start handler, as a real boot does.
    apply = events["hyprland.start"]
end

-- A screen: the fields monitors.lua places the row from.
local function screen(name, description, id, width, height, scale)
    return {
        name = name, description = description, id = id,
        width = width, height = height, scale = scale,
    }
end

-- The placement calls only, in the order they were issued, with the catch-all
-- (output = "") left out.
local function placed()
    local out = {}
    for i, s in ipairs(monitor_calls) do
        if i > 1 then out[#out + 1] = s end -- call 1 is the catch-all
    end
    return out
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

local function mon(name)
    for _, s in ipairs(placed()) do
        if s.output == name then return s end
    end
end

print("scenario: monitorpin parses the layout directive")
local layout = require("monitorpin").layout
set_pin("# layout = rtl\n")
check("a directive line sets the direction", layout(), "rtl")
set_pin("# nothing here\n# layout = ttb\nDell DELL P3424WE DVYH6T3\n")
check("ttb read past a plain comment and a screen", layout(), "ttb")
set_pin("# layout = ttb\n# layout = ltr\n")
check("the last directive line wins", layout(), "ltr")
set_pin("# nothing here\nDell DELL P3424WE DVYH6T3\n")
check("no directive means ltr", layout(), "ltr")

print("scenario: monitor 1 is the leftmost (default ltr)")
-- Dell (2560) is slot 1, BOE (1920) slot 2. Left to right: Dell, BOE.
set_pin("Dell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("leftmost is slot 1", placed()[1].output, "DP-4")
check("slot 1 starts at 0", mon("DP-4").position, "0x0")
check("slot 2 sits on its right", mon("eDP-1").position, "2560x0")
check("no transform issued", mon("DP-4").transform, nil)

print("scenario: # layout = rtl makes monitor 1 the rightmost")
set_pin("# layout = rtl\nDell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("leftmost is slot 2", placed()[1].output, "eDP-1")
check("slot 2 starts at 0", mon("eDP-1").position, "0x0")
check("slot 1 sits on its right", mon("DP-4").position, "1920x0")

print("scenario: positions are logical pixels, width over scale")
-- 4K scaled by 2 is 1920 logical wide, so slot 2 lands 1920 in.
set_pin("Dell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 3840, 2160, 2),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("slot 2 past slot 1's logical width", mon("eDP-1").position, "1920x0")

print("scenario: a rotated screen stands on its end")
-- Portrait panel (transform=1) is 1080 logical wide once turned, so the slot
-- 2 screen beside it sits 1080 in, not 1920.
set_pin("Dell DELL P3424WE DVYH6T3 transform=1\nBOE 0x0DBB\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 1920, 1080, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("portrait slot 1 leads, swung round", placed()[1].transform, 1)
check("it starts at 0", mon("DP-4").position, "0x0")
check("slot 2 placed past the portrait's short side", mon("eDP-1").position, "1080x0")

print("scenario: # layout = ttb stands the screens in a column")
set_pin("# layout = ttb\nDell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("slot 1 on top at the origin", mon("DP-4").position, "0x0")
check("slot 2 below it, down slot 1's logical height", mon("eDP-1").position, "0x1440")
check("x stays at the left edge", mon("eDP-1").position:match("^(%d+)"), "0")

print("scenario: unpinned screens lead at the far end, in id order")
-- Only two of three were ever pinned; BOE trails after the pinned slot.
set_pin("Dell DELL P3424WE DVYH6T3\nSamsung U28E590 0xAA00\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 1920, 1080, 1),
    screen("HDMI-1", "Samsung U28E590 0xAA00", 2, 1920, 1080, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("slot 1 leads", placed()[1].output, "DP-4")
check("then slot 3", placed()[2].output, "HDMI-1")
check("unpinned BOE brings up the rear", placed()[3].output, "eDP-1")
check("slot 3 clears slot 1's width", mon("HDMI-1").position, "1920x0")
check("BOE clears both", mon("eDP-1").position, "3840x0")

print("scenario: nothing pinned, id order")
set_pin("")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
    screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
} }
apply()
check("id 0 first", placed()[1].output, "eDP-1")
check("id 1 next", placed()[2].output, "DP-4")
check("slot offsets accumulate", mon("DP-4").position, "1920x0")

print("scenario: a duplicating screen is out of the row")
-- DP-4 is mirroring eDP-1, so Hyprland does not report it; the row re-packs
-- without leaving a gap for it.
set_pin("Dell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
local m = {
    monitors = {
        screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
        screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
    },
}
m.monitors[1].mirroring = "eDP-1" -- hidden, like a live mirror
reset(m)
apply()
check("only the live screen is placed", #placed(), 1)
check("BOE at 0 again", mon("eDP-1").position, "0x0")

print("scenario: the row is re-issued on the events that matter")
check("hyprland.start hooked", type(events["hyprland.start"]), "function")
check("config.reloaded hooked", type(events["config.reloaded"]), "function")
check("monitor.added hooked", type(events["monitor.added"]), "function")
check("monitor.removed hooked", type(events["monitor.removed"]), "function")

-- Re-issue through the deferred path (fire its timer) on removal.
set_pin("Dell DELL P3424WE DVYH6T3\nBOE 0x0DBB\n")
local r = {
    monitors = {
        screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 2560, 1440, 1),
        screen("eDP-1", "BOE 0x0DBB", 0, 1920, 1080, 1),
    },
}
reset(r)
apply()
r.monitors = { r.monitors[2] } -- DP-4 unplugged
monitor_calls = { monitor_calls[1] } -- keep the catch-all
events["monitor.removed"]()
check("the remaining screen gets placed", #placed(), 1)
check("BOE back at 0", mon("eDP-1").position, "0x0")

-- monitorpin.layout is looked up through the patched os.getenv from inside
-- monitors.lua; this scenario clears it up after the file-relative reads above.
print("scenario: layout() honours the patched pin path")
set_pin("# layout = ttb\nDell DELL P3424WE DVYH6T3\n")
reset { monitors = {
    screen("DP-4", "Dell DELL P3424WE DVYH6T3", 1, 1920, 1080, 1),
} }
apply()
check("ttb layout from the file drove the column", mon("DP-4").position, "0x0")

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)