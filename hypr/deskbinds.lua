-- Monitor and desktop keybinds (roadmap.md lines 36-44).
--
-- Every monitor gets a number, 1..0, ordered by monitor id. The number keys
-- are overloaded on whether the target monitor is the focused one:
--
--   #n = a monitor that is NOT focused        #f = the focused monitor
--
--   M   + #n  focus that monitor             M   + #f  next desktop (wraps)
--   M+S + #n  move window to that monitor    M+S + #f  move window to next desktop
--   M+C + #n  toggle mirror with focused     M+C + #f  new desktop, focused
--
-- "desktop" is a Hyprland workspace. Empty non-persistent workspaces are
-- cleaned up by Hyprland automatically, so nothing here has to remove them.
--
-- Everything is built on focus({workspace=id}) and window.move({workspace=id}),
-- which are the primitives already used elsewhere in this config. Focusing a
-- monitor is done by focusing the workspace it currently shows.

local programs = require("programs")
local mainMod = programs.mainMod

-- Monitors in a stable order, so the numbering does not shuffle between calls.
local function ordered_monitors()
    local mons = hl.get_monitors() or {}
    table.sort(mons, function(a, b) return a.id < b.id end)
    return mons
end

local function monitor_for(index)
    return ordered_monitors()[index]
end

-- Regular (non-special) workspaces living on a monitor, lowest id first.
local function desktops_on(mon)
    local list = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if not ws.special and ws.monitor and ws.monitor.id == mon.id then
            table.insert(list, ws)
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Next desktop on a monitor, wrapping back to the first.
local function next_desktop(mon)
    local list = desktops_on(mon)
    if #list == 0 then
        return nil
    end

    local active = mon.active_workspace
    local current = 1
    for i, ws in ipairs(list) do
        if active and ws.id == active.id then
            current = i
            break
        end
    end

    return list[(current % #list) + 1]
end

-- Lowest unused positive workspace id, for creating a new desktop.
local function unused_desktop_id()
    local used = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        used[ws.id] = true
    end

    local id = 1
    while used[id] do
        id = id + 1
    end
    return id
end

-- Hyprland workspace ids are global: the second monitor can end up owning ids
-- 2 and 3, so they are renamed to encode their position per monitor.
--
-- The name is "<monitor>.<desktop>", e.g. 1.1, 1.2, 2.1 -- deliberately unique
-- across monitors rather than just "1", "2". Waybar marks a button active when
-- the workspace name equals the globally focused workspace's name, with no
-- monitor check (workspaces.cpp: `isActiveByName`), so two monitors both owning
-- a desktop called "1" makes both light up at once. It resolves a workspace's
-- monitor by name too, which misattributes the `hosting-monitor` class.
--
-- Waybar turns these into plain 1, 2, 3 for display via format-icons, see
-- waybar/config.jsonc. Everything here still addresses workspaces by id.
local renaming = false

local function renumber_desktops()
    -- Renaming can itself emit workspace events; do not recurse.
    if renaming then
        return
    end
    renaming = true

    for mon_index, mon in ipairs(ordered_monitors()) do
        for index, ws in ipairs(desktops_on(mon)) do
            local want = ("%d.%d"):format(mon_index, index)
            if ws.name ~= want then
                hl.dispatch(hl.dsp.workspace.rename({ workspace = ws.id, name = want }))
            end
        end
    end

    renaming = false
end

-- A freshly created workspace is not attached to its monitor yet at the moment
-- the event fires, so renaming immediately would skip it (this was observed:
-- a new desktop kept its global id 12 as its name). Deferring by a tick lets
-- Hyprland finish, and coalesces bursts of events into one pass.
--
-- Only for runtime events: creating a timer while the config is still being
-- parsed crashes Hyprland outright (`--verify-config` dumps core), and a
-- segfault cannot be caught with pcall, so the load-time hooks below call
-- renumber_desktops directly instead.
local renumber_pending = false

local function schedule_renumber()
    if renumber_pending then
        return
    end
    renumber_pending = true

    hl.timer(function()
        renumber_pending = false
        renumber_desktops()
    end, { timeout = 50, type = "oneshot" })
end

local function focus_workspace(ws)
    if ws then
        hl.dispatch(hl.dsp.focus({ workspace = ws.id }))
    end
end

-- Focusing an id that does not exist yet creates the desktop on the focused
-- monitor, so this only works for the monitor that currently has focus.
local function new_desktop_here()
    hl.dispatch(hl.dsp.focus({ workspace = unused_desktop_id() }))
    schedule_renumber()
end

local function move_window_to(ws)
    if ws then
        hl.dispatch(hl.dsp.window.move({ workspace = ws.id }))
    end
end

-- Extend/duplicate. Mirroring is a monitor property rather than a dispatcher,
-- so this re-issues hl.monitor() at runtime. Wrapped because that is the one
-- part of this file not proven by existing config.
local function toggle_mirror(target, focused)
    if not (target and focused) then
        return
    end

    local ok, err
    if target.is_mirror then
        -- Back to extending: clear the mirror and let it lay out normally.
        ok, err = pcall(hl.monitor, {
            output   = target.name,
            mode     = "preferred",
            position = "auto",
            scale    = "auto",
            mirror   = "",
        })
    else
        ok, err = pcall(hl.monitor, {
            output = target.name,
            mirror = focused.name,
        })
    end

    if not ok then
        hl.exec_cmd(("notify-send 'Hyprland' 'Mirror toggle failed: %s'")
            :format(tostring(err):gsub("'", "")))
    end
end

-- Is this monitor the focused one?
local function is_focused(mon)
    local active = hl.get_active_monitor()
    return active and mon and active.id == mon.id
end

for n = 1, 10 do
    local key = tostring(n % 10) -- 10 is bound to the "0" key

    hl.bind(mainMod .. " + " .. key, function()
        local mon = monitor_for(n)
        if not mon then
            return -- no such monitor, do nothing
        end

        if is_focused(mon) then
            -- Only one desktop here: there is nothing to cycle to, so make a
            -- second one rather than doing nothing.
            if #desktops_on(mon) < 2 then
                new_desktop_here()
            else
                focus_workspace(next_desktop(mon))
            end
        else
            focus_workspace(mon.active_workspace)
        end
    end, { description = "Monitor " .. n .. ": focus, or next/new desktop if focused" })

    hl.bind(mainMod .. " + SHIFT + " .. key, function()
        local mon = monitor_for(n)
        if not mon then
            return
        end

        if is_focused(mon) then
            move_window_to(next_desktop(mon))
        else
            move_window_to(mon.active_workspace)
        end
    end, { description = "Monitor " .. n .. ": move window there, or to next desktop" })

    hl.bind(mainMod .. " + CTRL + " .. key, function()
        local mon = monitor_for(n)
        if not mon then
            return
        end

        if is_focused(mon) then
            new_desktop_here()
        else
            toggle_mirror(mon, hl.get_active_monitor())
        end
    end, { description = "Monitor " .. n .. ": toggle mirror, or new desktop if focused" })
end

-- Keep the per-monitor numbering correct as desktops and monitors come and go.
-- These all fire while Hyprland is running, so the debounced version is safe.
for _, event in ipairs({
    "workspace.created",
    "workspace.removed",
    "workspace.active",
    "workspace.move_to_monitor",
    "monitor.added",
    "monitor.removed",
}) do
    hl.on(event, schedule_renumber)
end

-- These two fire during config load, where creating a timer would crash, so
-- they rename straight away.
hl.on("config.reloaded", renumber_desktops)
hl.on("hyprland.start", renumber_desktops)

return {
    renumber_desktops = renumber_desktops,
    schedule_renumber = schedule_renumber,
    desktops_on = desktops_on,
    ordered_monitors = ordered_monitors,
}
