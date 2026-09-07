-- Monitor and desktop keybinds (roadmap.md lines 36-44).
--
-- Every monitor gets a number, 1..0, in the order pinned by
-- bin/dotfiles-monitor-setup -- never in physical or connector order, which
-- Hyprland's monitor ids reflect only by chance and reshuffle on every redock
-- (DP-4 came back as DP-5). Monitors that have never been pinned trail the
-- pinned ones, in id order; see the pin loading below. The number keys are
-- overloaded on whether the target monitor is the focused one:
--
--   #n = a monitor that is NOT focused        #f = the focused monitor
--
--   M   + #n  focus that monitor             M   + #f  next desktop (wraps)
--   M+S + #n  move window to that monitor    M+S + #f  move window to next desktop
--   M+C + #n  toggle mirror with focused     M+C + #f  new desktop, focused
--
-- On a #f monitor with only one desktop, M+S+#f makes a second desktop and
-- takes the window onto it (the plain M+#f key makes one in that situation but
-- has nothing to move). Likewise M+C+#f always mints a fresh desktop, so
-- M+C+S+#f moves the window onto a fresh one; on a #n monitor M+C+S moves the
-- whole desktop across, below.
--
-- "desktop" is a Hyprland workspace. Empty non-persistent workspaces are
-- cleaned up by Hyprland automatically, so nothing here has to remove them.
--
-- Everything is built on focus({workspace=id}) and window.move({workspace=id}),
-- which are the primitives already used elsewhere in this config. Focusing a
-- monitor is done by focusing the workspace it currently shows.

local programs = require("programs")
local columns = require("columns")
local monitorpin = require("monitorpin")
local mainMod = programs.mainMod

-- Monitors we have set to mirror another one:
-- [name] = { id = n, source = name, pin = n|nil }
--
-- This bookkeeping is necessary because a mirroring monitor disappears from
-- hl.get_monitors() entirely -- hl.get_monitor(name) returns nil for it too, so
-- there is no way to ask Hyprland about it. Without remembering it, its number
-- would stop working and the mirror could never be switched off again.
-- (`hyprctl monitors all` does list it, but calling hyprctl from inside the
-- config deadlocks: the compositor is busy running this Lua.)
local mirrored = {}

-- Which screen a desktop belongs to: [workspace id] = screen identity.
--
-- Unplugging a screen makes Hyprland move its desktops onto whatever is left,
-- and plugging it back in does not send them home again, so they pile up on one
-- screen. Remembering where each one came from lets them be put back.
--
-- The identity is defined once, in monitorpin.lua: description when there is
-- one (a screen comes back under a different connector, DP-4 became DP-5 after
-- a redock, HEADLESS-1 came back as HEADLESS-2, so a name is worthless for
-- recognising it again -- descriptions are stable and carry the serial,
-- "Dell Inc. DELL P3424WE DVYH6T3"), name otherwise.
local function identity(mon)
    return monitorpin.identity(mon)
end

-- The pinned monitor order, loaded once at config time.
--
-- bin/dotfiles-monitor-setup writes one monitor identity per line into a plain
-- text file and reloads Hyprland; hand-editing the file works too. The file is
-- machine-local state (~/.local/share/hypr/monitor-order), not part of the
-- dotfiles, so each computer pins its own screens. monitorpin.lua owns both the
-- path and the parsing, including the per-screen transform= field; the slot
-- order here is all deskbinds needs from it.
--
-- The position in the file is the slot number, absolutely: line N is monitor N.
-- A pinned screen that is currently unplugged simply leaves its number unused
-- until it comes back, and a screen no one has pinned yet joins at the end in
-- id order, so a new monitor is usable the moment it is plugged in.
local pin_slot = {}
do
    for i, entry in ipairs(monitorpin.load()) do
        pin_slot[entry.identity] = i
    end
end

local home = {}

-- Monitor slots in a stable order, one per number key. Pinned monitors lead,
-- in file order; everything else trails, in id order. Mirroring monitors are
-- spliced back in at their pinned slot so the numbers of the others do not
-- shift.
--
-- A slot is { name, id, pin, monitor = HL.Monitor|nil, source = name|nil },
-- where monitor is nil exactly when the slot is currently mirroring (source is
-- set) and pin is the monitor's pinned slot number, or nil for unpinned ones.
local function monitor_slots()
    local slots = {}

    for _, m in ipairs(hl.get_monitors() or {}) do
        table.insert(slots, {
            name = m.name,
            id = m.id,
            pin = pin_slot[identity(m)],
            monitor = m,
        })
        -- It is live again, so any stale mirror note is wrong.
        mirrored[m.name] = nil
    end

    for name, info in pairs(mirrored) do
        table.insert(slots, {
            name = name,
            id = info.id,
            pin = info.pin,
            source = info.source,
        })
    end

    table.sort(slots, function(a, b)
        if a.pin and b.pin then
            return a.pin < b.pin
        end
        if a.pin then
            return true
        end
        if b.pin then
            return false
        end
        return a.id < b.id
    end)
    return slots
end

local function monitor_for(index)
    return monitor_slots()[index]
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
--
-- A desktop that has something better to call itself says so through this hook
-- -- quake.lua names one after the directory its terminal is sitting in, so the
-- bar reads "dotfiles" rather than "2". Waybar shows the workspace name for
-- anything its format-icons does not cover, so nothing is needed at that end.
--
-- Returns a name, or nil to leave the desktop numbered. Set through
-- set_labeller, below, once schedule_renumber exists to be called.
local labeller = nil

local renaming = false

local function renumber_desktops()
    -- Renaming can itself emit workspace events; do not recurse.
    if renaming then
        return
    end
    renaming = true

    -- Names have to stay unique across monitors, so a label that is already
    -- spoken for keeps its number alongside it. Two desktops open on the same
    -- directory is unusual but not wrong, and sharing a name would light both
    -- their buttons up at once.
    local taken = {}

    for mon_index, slot in ipairs(monitor_slots()) do
        local mon = slot.monitor
        for index, ws in ipairs(mon and desktops_on(mon) or {}) do
            if mon and not home[ws.id] then
                home[ws.id] = identity(mon)
            end

            local number = ("%d.%d"):format(mon_index, index)
            local want   = number

            local label = labeller and labeller(ws)
            if label and label ~= "" then
                want = taken[label] and (label .. " " .. number) or label
            end
            taken[want] = true

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

-- The name a brand-new desktop on this monitor should be born with.
--
-- The name has to be settled before the desktop exists, so the labeller is
-- called with a desktop that has no id yet and is expected to answer with
-- whatever it calls one it knows nothing about.
--
-- Unique, because two desktops sharing a name light up each other's buttons on
-- the bar, and because the renaming pass would only have to undo it.
local function name_for_new_desktop(mon)
    if not labeller then
        return nil
    end

    local label = labeller({})
    if not label or label == "" then
        return nil
    end

    local used = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if ws.name then
            used[ws.name] = true
        end
    end
    if not used[label] then
        return label
    end

    -- Taken, so fall back to the same "<label> <monitor>.<desktop>" the
    -- renumbering pass would settle on anyway.
    for mon_index, slot in ipairs(monitor_slots()) do
        if slot.monitor and mon and slot.monitor.id == mon.id then
            -- Not +1: this runs after the desktop has been created, so it is
            -- already in the count, and it sorts last because its id is the
            -- highest. Adding one named it "1.3" for the ~100ms until the
            -- renumbering pass corrected it to "1.2".
            local candidate = ("%s %d.%d"):format(label, mon_index, #desktops_on(mon))
            return not used[candidate] and candidate or nil
        end
    end
    return nil
end

local function focus_workspace(ws)
    if ws then
        hl.dispatch(hl.dsp.focus({ workspace = ws.id }))
    end
end

-- Focusing an id that does not exist yet creates the desktop on the focused
-- monitor, so this only works for the monitor that currently has focus.
--
-- Created by id and renamed in the same breath, rather than left to the
-- deferred pass, which would show the bare id on the bar for the ~80ms until it
-- ran. The desktop exists by the time the focus dispatch returns, so there is
-- nothing to wait for.
--
-- Asking for the name directly -- "name:~" -- looks tidier and is a trap.
-- Hyprland numbers named workspaces from -1337 downwards, and those negative
-- ids sort ahead of every ordinary desktop, so a new desktop would insert
-- itself before the ones already there and quietly renumber them.
-- Create a new desktop on the focused monitor and return its id. The caller may
-- then move the focused window onto it, so a move-and-make-a-desktop key does
-- not have to create it twice.
local function create_new_desktop_here()
    local id = unused_desktop_id()
    hl.dispatch(hl.dsp.focus({ workspace = id }))

    local name = name_for_new_desktop(hl.get_active_monitor())
    if name then
        hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = name }))
    end

    schedule_renumber()
    return id
end

local function new_desktop_here()
    create_new_desktop_here()
end

local function move_window_to(ws)
    if ws then
        hl.dispatch(hl.dsp.window.move({ workspace = ws.id }))
    end
end

-- Move the focused window onto a brand-new desktop and name it there.
--
-- Creating a desktop means focusing it, which hands the active view over to an
-- empty desktop, so hl.get_active_window() would answer with nothing (or the
-- wrong window) afterwards. The address has to be captured before the desktop
-- exists; the move then targets that window explicitly.
local function move_focused_window_to_new_desktop()
    local win = hl.get_active_window()
    if not (win and win.address) then
        return
    end

    local id = create_new_desktop_here()
    hl.dispatch(hl.dsp.window.move({ workspace = id, window = "address:" .. win.address }))
end

-- Waybar builds one bar per output, keyed by monitor name, and its workspace
-- buttons come from the desktop names -- both of which change when a monitor
-- starts or stops duplicating. SIGUSR2 makes it re-read the config and rebuild
-- its bars from the current state.
--
-- Deferred a moment so the monitor change has landed before waybar looks, and
-- followed by a check: a bar that fails to come back leaves the desktop with no
-- status bar at all, so start one if the reload lost it.
--
-- Note that pkill matches every waybar on the machine, which matters only when
-- running a nested Hyprland for testing: the host's bar gets reloaded too.
local function reload_waybar()
    hl.timer(function()
        -- Restart rather than reload: duplicating can change which monitor is
        -- the largest, and bin/waybar-main puts the bar on that one.
        hl.exec_cmd("waybar-main")
    end, { timeout = 300, type = "oneshot" })
end

-- Send every desktop back to the screen it belongs to.
--
-- Called when a screen appears: its desktops were pushed elsewhere while it was
-- gone, and nothing brings them back on its own.
local function restore_homes()
    -- Where each remembered screen is plugged in right now.
    local where = {}
    for _, m in ipairs(hl.get_monitors() or {}) do
        where[identity(m)] = m.name
    end

    for _, ws in ipairs(hl.get_workspaces() or {}) do
        local belongs = home[ws.id]
        local target = belongs and where[belongs]
        if target and not ws.special and ws.monitor and ws.monitor.name ~= target then
            hl.dispatch(hl.dsp.workspace.move({ workspace = ws.id, monitor = target }))
        end
    end
end

-- Toggle duplicate/extend for a monitor slot.
--
-- Mirroring is a monitor property rather than a dispatcher, so it re-issues
-- hl.monitor(). `mirror = ""` is what switches it back off; the monitor then
-- reappears in hl.get_monitors().
local function toggle_mirror(slot, focused)
    if not slot then
        return
    end

    local ok, err
    if slot.source then
        -- Currently duplicating: go back to extending.
        ok, err = pcall(hl.monitor, {
            output   = slot.name,
            mode     = "preferred",
            position = "auto",
            scale    = "auto",
            mirror   = "",
        })
        if ok then
            mirrored[slot.name] = nil
            reload_waybar()
        end
    else
        if not focused or focused.name == slot.name then
            return -- nothing to duplicate onto
        end

        ok, err = pcall(hl.monitor, {
            output = slot.name,
            mirror = focused.name,
        })
        if ok then
            -- Remember it: from here on Hyprland will not report this monitor
            -- at all, so this table is the only record that it exists. The pin
            -- keeps its slot number while it is hidden.
            mirrored[slot.name] = { id = slot.id, source = focused.name, pin = slot.pin }
            reload_waybar()
        end
    end

    if not ok then
        hl.exec_cmd(("notify-send 'Hyprland' 'Mirror toggle failed: %s'")
            :format(tostring(err):gsub("'", "")))
    end
end

-- Is this slot the focused monitor? A mirroring slot never is: it has no
-- monitor object of its own.
local function is_focused(slot)
    local active = hl.get_active_monitor()
    return active and slot and slot.monitor and active.id == slot.monitor.id
end

for n = 1, 10 do
    local key = tostring(n % 10) -- 10 is bound to the "0" key

    hl.bind(mainMod .. " + " .. key, function()
        local slot = monitor_for(n)
        if not slot or not slot.monitor then
            -- No such monitor, or it is duplicating another one and so has
            -- nothing of its own to focus.
            return
        end

        if is_focused(slot) then
            -- Only one desktop here: there is nothing to cycle to, so make a
            -- second one rather than doing nothing.
            if #desktops_on(slot.monitor) < 2 then
                new_desktop_here()
            else
                focus_workspace(next_desktop(slot.monitor))
            end
        else
            focus_workspace(slot.monitor.active_workspace)
        end
    end, { description = "Screen " .. n .. ": go there, or next desktop if already there" })

    hl.bind(mainMod .. " + SHIFT + " .. key, function()
        local slot = monitor_for(n)
        if not slot or not slot.monitor then
            return
        end

        if is_focused(slot) then
            -- Only one desktop here, so there is nothing to move to; the plain
            -- M+n key makes a second one in this case, so move the window onto
            -- a freshly made desktop to match.
            if #desktops_on(slot.monitor) < 2 then
                move_focused_window_to_new_desktop()
            else
                move_window_to(next_desktop(slot.monitor))
            end
        else
            move_window_to(slot.monitor.active_workspace)
        end
    end, { description = "Screen " .. n .. ": move window there, or to a new desktop if only one" })

    hl.bind(mainMod .. " + CTRL + " .. key, function()
        local slot = monitor_for(n)
        if not slot then
            return
        end

        -- Duplicating already: this key switches it back off, which has to work
        -- even though Hyprland no longer reports the monitor.
        if slot.source then
            toggle_mirror(slot, hl.get_active_monitor())
        elseif is_focused(slot) then
            new_desktop_here()
        else
            toggle_mirror(slot, hl.get_active_monitor())
        end
    end, { description = "Screen " .. n .. ": duplicate onto it, or new desktop if already there" })

    -- CTRL is the screen itself: with SHIFT that is a screen-sized move, so the
    -- whole desktop goes across. Doing this by hand also changes where the
    -- desktop belongs, so it stays there after a replug.
    hl.bind(mainMod .. " + CTRL + SHIFT + " .. key, function()
        local slot = monitor_for(n)
        if not slot or not slot.monitor then
            return
        end

        -- M+C+n always makes a brand-new desktop here, so its SHIFT twin moves
        -- the focused window onto one as well.
        if is_focused(slot) then
            move_focused_window_to_new_desktop()
            return
        end

        local mon = hl.get_active_monitor()
        local ws = mon and mon.active_workspace
        if not ws or ws.special then
            return
        end

        home[ws.id] = identity(slot.monitor)
        hl.dispatch(hl.dsp.workspace.move({ workspace = ws.id, monitor = slot.monitor.name }))
        schedule_renumber()
    end, { description = "Screen " .. n .. ": move this whole desktop there" })

    -- ALT scopes the move up from the window to its whole column.
    hl.bind(mainMod .. " + ALT + SHIFT + " .. key, function()
        local slot = monitor_for(n)
        if not slot or not slot.monitor then
            return
        end

        local target = is_focused(slot) and next_desktop(slot.monitor)
                       or slot.monitor.active_workspace
        if not target then
            return
        end

        local win = hl.get_active_window()
        if not win or win.floating or not win.workspace then
            return
        end

        columns.move_column_to_workspace(win.workspace.id, target.id, win.stable_id)
    end, { description = "Screen " .. n .. ": move column there" })
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

-- A screen coming back gets its own desktops back. Deferred, because the
-- monitor is not usable the instant the event fires, and the desktops have to
-- be moved before they are renumbered.
hl.on("monitor.added", function()
    hl.timer(function()
        restore_homes()
        schedule_renumber()
    end, { timeout = 500, type = "oneshot" })
end)

-- These two fire during config load, where creating a timer would crash, so
-- they rename straight away.
hl.on("config.reloaded", renumber_desktops)
hl.on("hyprland.start", renumber_desktops)

-- Set by quake.lua, which knows what each desktop is being used for.
--
-- Deliberately does not renumber: this is called while the config is still
-- loading, and creating a timer there segfaults Hyprland outright. The
-- hyprland.start hook below does the first pass, by which time this is set.
local function set_labeller(fn)
    labeller = fn
end

return {
    set_labeller = set_labeller,
    new_desktop_here = new_desktop_here,
    renumber_desktops = renumber_desktops,
    schedule_renumber = schedule_renumber,
    desktops_on = desktops_on,
    monitor_slots = monitor_slots,
    restore_homes = restore_homes,
    identity = identity,
    toggle_mirror = toggle_mirror,
}
