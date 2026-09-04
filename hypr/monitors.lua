-- Monitors
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
--
-- Which screen is where -- and which way it is mounted -- is this machine's
-- business, not the repo's: connector names lie (DP-4 came back as DP-5), so
-- the per-screen settings live in the pinned monitor file that
-- bin/hypr-monitor-order writes and monitorpin.lua parses. Orientation is the
-- one setting kept there so far: "transform=1" on a screen's line stands it up
-- after the panel was physically turned.
--
-- The layout comes from the same file. A comment in it sets the direction --
-- "# layout = ltr|rtl|ttb" -- and the screens make a row or column in number
-- order from wherever monitor 1 leads: ltr (the default) puts monitor 1 on the
-- left and runs the slots right, rtl puts it on the right and runs left, ttb
-- stands the screens in a column with monitor 1 on top. Screens nobody has
-- pinned yet go to the far end in id order, exactly where deskbinds.lua puts
-- their numbers. Positions are logical pixels (a screen's pixels divided by
-- its scale, with a rotated one standing on its end), which is the coordinate
-- space hl.monitor()'s position field works in -- it takes a "WxH"-formatted
-- string here, not the old x@y token, verified in tests/sandbox.sh.
--
-- The catch-all below configures every screen that has no line in the file,
-- and has to come first: a later hl.monitor() call wins for the output it
-- names, so the per-screen calls that follow override it.

local monitorpin = require("monitorpin")

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

-- Apply the pinned settings to whatever is connected right now. Monitors are
-- not enumerable at module load -- hl.get_monitors() is empty until
-- hyprland.start, verified in tests/sandbox.sh -- so this runs from the
-- events below, never at the top level.
local function apply_pinned()
    local entries = monitorpin.load()
    local by_identity, slot = {}, {}
    for i, entry in ipairs(entries) do
        by_identity[entry.identity] = entry
        slot[entry.identity] = i
    end

    local direction = monitorpin.layout()
    -- rtl runs the slots right-to-left (monitor 1 rightmost); ltr and ttb run
    -- them up from the left or the top, the reading order. Unpinned screens go
    -- to the end away from monitor 1, which for rtl is to its left and for
    -- ltr/ttb to its right/bottom. Hyprland drops a mirroring output from
    -- get_monitors(), so a duplicating screen is simply absent here and the
    -- row packs without it.
    local ascending = direction ~= "rtl"
    local vertical = direction == "ttb"

    local pinned, unpinned = {}, {}
    for _, mon in ipairs(hl.get_monitors() or {}) do
        if slot[monitorpin.identity(mon)] then
            pinned[#pinned + 1] = mon
        else
            unpinned[#unpinned + 1] = mon
        end
    end
    table.sort(pinned, function(a, b)
        local sa, sb = slot[monitorpin.identity(a)], slot[monitorpin.identity(b)]
        if ascending then
            return sa < sb
        end
        return sa > sb
    end)

    local row = {}
    local first, last = unpinned, pinned
    if ascending then
        first, last = pinned, unpinned
    end
    for _, mon in ipairs(first) do
        row[#row + 1] = mon
    end
    for _, mon in ipairs(last) do
        row[#row + 1] = mon
    end

    local x, y = 0, 0
    for _, mon in ipairs(row) do
        local entry = by_identity[monitorpin.identity(mon)]
        local transform = entry and entry.transform or 0

        -- Logical size: the monitor's pixels over its scale, with a rotated
        -- (portrait) screen standing on its end.
        local w, h = mon.width or 0, mon.height or 0
        if transform == 1 or transform == 3 then
            w, h = h, w
        end
        local scale = mon.scale
        if not scale or scale <= 0 then
            scale = 1
        end

        local spec = {
            output   = mon.name,
            mode     = "preferred",
            scale    = "auto",
        }
        if vertical then
            spec.position = string.format("0x%d", y - y % 1)
            y = y + h / scale
        else
            spec.position = string.format("%dx0", x - x % 1)
            x = x + w / scale
        end
        if transform ~= 0 then
            spec.transform = transform
        end
        hl.monitor(spec)
    end
end

-- hyprland.start and config.reloaded fire while the config is loading, where a
-- timer crashes Hyprland outright, so both call apply_pinned directly.
-- hyprland.start is when the monitors are first enumerable on boot;
-- config.reloaded is what a hand-edited pin file (or a re-run of
-- hypr-monitor-order) lands on. monitor.added is a runtime event, on hotplug
-- and on replug, where the monitors have been seen before but a reconnect must
-- be re-armed -- and it is the fallback that puts a rotated screen back after
-- a mirror was toggled off (deskbinds.lua re-issues hl.monitor() there without
-- a transform). monitor.removed re-packs the row when a screen goes away; both
-- wait for the monitor to finish changing before configuring it.
local function defer_apply()
    hl.timer(apply_pinned, { timeout = 200, type = "oneshot" })
end

hl.on("hyprland.start", apply_pinned)
hl.on("config.reloaded", apply_pinned)
hl.on("monitor.added", defer_apply)
hl.on("monitor.removed", defer_apply)
