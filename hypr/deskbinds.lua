-- Monitors and desktops: what the screen and desktop keys actually do.
--
-- This file holds no binds. modes.lua owns every key and calls the actions
-- exported at the bottom, because the same action is reached two ways -- as a
-- chord in normal mode (SUPER+3) and as a motion inside a mode (SUPER+M then
-- 3) -- and neither should have to know how the other is typed.
--
-- Every monitor gets a number, 1..0, in the order pinned by
-- bin/dotfiles-monitor-order -- never in physical or connector order, which
-- Hyprland's monitor ids reflect only by chance and reshuffle on every redock
-- (DP-4 came back as DP-5). Monitors that have never been pinned trail the
-- pinned ones, in id order; see the pin loading below.
--
-- A screen number is overloaded on whether it is the screen you are already
-- on, and the overload is the same at every scope: acting "towards" the screen
-- you are on means acting towards a brand-new desktop on it.
--
--   #n = a screen you are not on             #f = the screen you are on
--
--   focus_screen            go there         a new desktop, kept while empty
--   move_window_to_screen   window there     window to a new desktop
--   move_column_to_screen   column there     column to a new desktop
--   move_desktop_to_screen  desktop there    nothing (it is already here)
--   toggle_mirror_screen    duplicate it     nothing (cannot mirror itself)
--
-- Cycling desktops is a separate axis -- focus_neighbour_desktop and friends,
-- on Tab -- so nothing here depends on how many desktops happen to exist. The
-- two "only one desktop, so make a second" special cases this file used to
-- carry are gone with it: creating and going-to are different keys now.
--
-- "desktop" is a Hyprland workspace. Empty non-persistent workspaces are
-- cleaned up by Hyprland automatically, so nothing here has to remove them.
--
-- Everything is built on focus({workspace=id}) and window.move({workspace=id}),
-- which are the primitives already used elsewhere in this config. Focusing a
-- monitor is done by focusing the workspace it currently shows.

local columns = require("columns")
local monitorpin = require("monitorpin")

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
-- bin/dotfiles-monitor-order writes one monitor identity per line into a plain
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

-- Which desktops have been asked to stay: [id] = true. Kept because nothing
-- reads the rules back -- a workspace object does not say whether it is
-- persistent, and `hyprctl workspacerules` has no Lua counterpart -- and
-- session.lua has to write the flag down to put it back after a restart.
local persisted = {}

-- Every desktop id this session has ever seen, so the ones that go can be
-- noticed. Not the same as "desktops that exist": that is what it is compared
-- against.
local seen = {}

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

-- Where a desktop sits in its screen's row: [workspace id] = sort key.
--
-- Desktops are ordered by workspace id, which is the order they were made in
-- and so the order you expect. That stops being true the moment a desktop
-- moves between screens: its id is fixed, so it inserts itself wherever that
-- id happens to fall in the row it arrives in -- landing in the middle and
-- renumbering the desktops either side of it.
--
-- Renumbering the desktop instead was the obvious answer and is a trap.
-- workspace.change_id does not rename a workspace: it creates one under the
-- new id and moves the windows across, leaving the old one behind, and the
-- desktop's quake terminal stays in "special:quake-<old id>" where nothing
-- will ever find it again. Verified in a nested instance; the terminal was
-- still sitting in the orphaned special workspace afterwards.
--
-- So the id is left alone and the *position* is remembered instead. Only
-- desktops that have actually been moved get an entry; everything else falls
-- back to its id, so this table is empty until something happens. Stale
-- entries are pruned in the renumbering pass, because ids get reused and a new
-- desktop must not inherit a retired one's place in the row.
local position = {}

local function sort_key(ws)
    return position[ws.id] or ws.id
end

-- A name a desktop has been given outright: [workspace id] = title.
--
-- bin/title writes these. A desktop is otherwise named after whatever it is
-- being used for -- the directory its quake terminal is sitting in, through
-- the labeller below -- which is right until you want a desktop called
-- something the filesystem has no word for. A title replaces that and then
-- holds: the labeller is not consulted again until the title is cleared, so a
-- `cd` no longer renames the desktop, which is the whole point of asking for
-- one.
--
-- The number in front is not part of the title. It is put back by every
-- renumbering pass, so a titled desktop shuffled along its row or sent to
-- another screen is renumbered like any other and keeps its name.
--
-- Keyed by workspace id like everything else here, and forgotten with the
-- desktop in forget_desktop -- ids are reused, and a new desktop must not come
-- up wearing a dead one's name.
local titles = {}

----------------------------------------------------------------------------
-- Forgetting a desktop
----------------------------------------------------------------------------
--
-- Everything anyone remembers about a desktop is keyed by its workspace id,
-- and Hyprland reuses ids the moment a desktop goes. Anything left behind is
-- therefore inherited by the next desktop handed that id, which is how a brand
-- new desktop came up on the wrong screen, in the wrong place in the row, and
-- with a previous occupant's terminal and working directory: it was wearing a
-- dead desktop's clothes.
--
-- There were two ways for a desktop to go and only one of them cleaned up.
-- Closing it with SUPER+C did; *lapsing* -- left empty, swept up by Hyprland
-- -- did not, and that is the common one. So cleanup is driven by the only
-- thing that cannot be wrong: whether the workspace still exists.
--
-- Other modules register what they remember, rather than deskbinds knowing
-- their business: quake.lua has the desktop's terminal and name, columns.lua
-- has its layout.
local forget_hooks = {}

local function on_forget(fn)
    table.insert(forget_hooks, fn)
end

-- Hyprland's own note about a desktop is its workspace rule, and it outlives
-- the desktop just as this file's tables do. The rule names a screen, and that
-- binding is read whenever a workspace with that id is *created* -- by
-- getBoundMonitorForWS, before the focused monitor is even considered, and
-- whether or not the rule still asks for persistence. So a dead desktop's rule
-- decides where a live one is born: make a desktop on one screen, close it,
-- then ask for one on another screen, and the new desktop appears back on the
-- first. Verified in a nested instance, and this is the whole reason the rule
-- is dropped here rather than only where persistence is switched off.
--
-- Dropping it means naming a monitor, because there is no way to name none:
-- `monitor = ""` is ignored and leaves the previous binding standing (also
-- verified -- the desktop still came up on the old screen). `monitor =
-- "current"` is the way out: Hyprland resolves it to the monitor in front at
-- the moment the desktop is created, which is exactly what an unbound id does,
-- so the rule stops having an opinion. Harmless for anything else, because
-- persistence goes off in the same breath and nothing else re-reads it.
local function unbind_desktop(id)
    persisted[id] = nil
    hl.workspace_rule({
        workspace = tostring(id),
        persistent = false,
        monitor = "current",
    })
end

-- Unconditional, rather than only for desktops this file believes it made
-- persistent: `persisted` is a belief about a rule and the rule is what
-- matters. Closing a desktop used to clear the flag before getting here, so
-- the check skipped exactly the desktop being closed.
local function forget_desktop(id)
    position[id] = nil
    home[id] = nil
    seen[id] = nil
    titles[id] = nil

    unbind_desktop(id)

    for _, fn in ipairs(forget_hooks) do
        fn(id)
    end
end

-- Regular (non-special) workspaces living on a monitor, in row order.
local function desktops_on(mon)
    local list = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if not ws.special and ws.monitor and ws.monitor.id == mon.id then
            table.insert(list, ws)
        end
    end
    table.sort(list, function(a, b) return sort_key(a) < sort_key(b) end)
    return list
end

-- Put a desktop at the end of a monitor's row, and keep it there.
--
-- The key only has to be larger than everything already on that screen; screens
-- do not share a row, so keys never have to be unique across them.
local function place_at_end_of(mon, ws)
    if not (mon and ws) then
        return
    end

    local highest
    for _, other in ipairs(desktops_on(mon)) do
        if other.id ~= ws.id then
            local key = sort_key(other)
            if not highest or key > highest then
                highest = key
            end
        end
    end

    -- Nothing else there, so its own id will do and no note is needed.
    if highest then
        position[ws.id] = highest + 1
    end
end

-- The desktop `step` places along from the one in view, wrapping both ways.
-- step = 1 is the next one, -1 the previous; SUPER+Tab and SUPER+SHIFT+Tab.
local function neighbour_desktop(mon, step)
    local list = desktops_on(mon)
    -- One desktop is its own neighbour, so there is nothing to go to. Saying
    -- so rather than returning it keeps the callers from dispatching a focus
    -- at the desktop already in view, which would churn workspace events (and
    -- a renumbering pass) for nothing. close_desktop_here relies on the same
    -- answer to know it has nowhere to put you.
    if #list < 2 then
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

    -- Lua indexes from 1, so shift into 0-based, wrap, and shift back. The
    -- extra #list keeps a step of -1 on the first desktop out of the negatives.
    return list[((current - 1 + step + #list) % #list) + 1]
end

-- Where focus goes when the desktop in view is closed: the one before it, or
-- the one after when it was the first.
--
-- Deliberately does not wrap. Closing is backing out of somewhere, so the
-- neighbour you came from is where you expect to land -- and the wrapping
-- version put you on desktop 1 from anywhere, which is a long way from where
-- you were with several open.
local function desktop_after_closing(mon, ws)
    local list = desktops_on(mon)

    local current
    for i, other in ipairs(list) do
        if other.id == ws.id then
            current = i
            break
        end
    end

    if not current then
        return nil
    end

    return list[current - 1] or list[current + 1]
end

-- An unused workspace id for a new desktop on `mon`, chosen so the desktop
-- lands at the end of that monitor's row.
--
-- Everything here orders desktops by id (desktops_on sorts by it), so the id is
-- what decides where a new one appears. Taking the lowest free id globally put
-- it *first* whenever a lower id had been freed elsewhere: with the laptop
-- holding id 1 and the other screen holding 3 and 4, a new desktop on the
-- second screen took the free id 2 and arrived ahead of both, renumbering them
-- from under you.
--
-- So start past that monitor's own highest id. Gaps further down are still
-- reused -- they belong to other screens, where they sort correctly -- so ids
-- stay small rather than climbing forever.
--
-- `mon` may be nil, when there is no focused monitor to ask about; then this is
-- the old "lowest free id", which is the best that can be said.
local function unused_desktop_id(mon)
    local used = {}
    local highest = 0

    for _, ws in ipairs(hl.get_workspaces() or {}) do
        used[ws.id] = true

        if mon and not ws.special and ws.monitor and ws.monitor.id == mon.id
           and ws.id > highest then
            highest = ws.id
        end
    end

    local id = highest + 1
    while used[id] do
        id = id + 1
    end
    return id
end

-- Hyprland workspace ids are global: the second monitor can end up owning ids
-- 2 and 3, so they are renamed to encode their position per monitor.
--
-- Every name begins with the desktop's number on its own screen, because that
-- number is a key you press: SUPER+D then 2 goes to the second desktop here.
-- A desktop called only "dotfiles" gave no clue what to press.
--
-- With a title:    "2 comms"      (bin/title, and it stays put)
-- With a label:    "2 dotfiles"   (quake.lua's, the terminal's directory)
-- Without either:  "2.1"          "<desktop>.<screen>"
--
-- Both are deliberately unique across monitors rather than plain "2". Waybar
-- marks a button active when the workspace name equals the globally focused
-- workspace's name, with no monitor check (workspaces.cpp: `isActiveByName`),
-- so two monitors both owning a desktop called "2" makes both light up at
-- once. It resolves a workspace's monitor by name too, which misattributes the
-- `hosting-monitor` class. Where a label and a number still collide across
-- screens -- same position, same directory -- the screen number is appended:
-- "1 dotfiles (2)".
--
-- Both forms lead with the desktop's own number, and that is load-bearing
-- rather than cosmetic: waybar orders its buttons by workspace id by default
-- (workspaces.cpp, "both normal => sort by ID"), which is not the order these
-- names describe -- a desktop shuffled along its row kept its id, so the bar
-- ignored the move entirely. waybar/config.jsonc therefore asks for
-- `sort-by: name`, and a name only sorts into the right place if the number
-- comes first. That is why the unlabelled form is "<desktop>.<screen>" and not
-- the other way round, which is how it read until the row could be reordered.
--
-- Waybar renders the unlabelled form as a plain number through format-icons
-- (waybar/config.jsonc) and prints anything else as-is, which is what shows
-- "2 dotfiles".
--
-- Everything here still addresses workspaces by id.
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

    -- Everything remembered about a desktop is keyed by its workspace id, and
    -- ids are reused the moment a desktop goes. So a desktop that lapses --
    -- left empty, swept up by Hyprland, never going through close_desktop_here
    -- -- leaves its notes behind, and the next desktop handed that id is born
    -- wearing a dead one's clothes: its place in the row, and its home screen,
    -- which is what made a new desktop appear on the other monitor seemingly at
    -- random. The persistence rule is worse, because it names a monitor, and
    -- Hyprland acts on it.
    --
    -- This pass already walks every desktop, so it is the cheapest place to
    -- notice, and it runs on every workspace event.
    -- Anything that has gone since the last pass is forgotten here. This runs
    -- on every workspace event, so a desktop that lapses is cleaned up within
    -- a tick of Hyprland sweeping it.
    do
        local live = {}
        for _, ws in ipairs(hl.get_workspaces() or {}) do
            live[ws.id] = true
        end

        local gone = {}
        for id in pairs(seen) do
            if not live[id] then
                table.insert(gone, id)
            end
        end

        -- Collected first: forget_desktop writes to `seen`.
        for _, id in ipairs(gone) do
            forget_desktop(id)
        end
    end

    -- Names have to stay unique across monitors: waybar marks a button active
    -- by comparing names with no monitor check, so two desktops sharing one
    -- would light each other up. A collision keeps the screen number as well,
    -- which is unique by construction -- only one desktop per screen per slot.
    local taken = {}

    for mon_index, slot in ipairs(monitor_slots()) do
        local mon = slot.monitor
        for index, ws in ipairs(mon and desktops_on(mon) or {}) do
            seen[ws.id] = true

            if mon and not home[ws.id] then
                home[ws.id] = identity(mon)
            end

            -- The name always begins with the desktop's own number, because
            -- that number is a key you press: SUPER+D then 2 goes to the
            -- second desktop on this screen. A desktop called "dotfiles" gave
            -- no clue which number that was.
            --
            -- An unlabelled desktop stays "<screen>.<desktop>", which waybar's
            -- format-icons renders as the bare number (see waybar/config.jsonc);
            -- anything else it does not recognise it prints as-is, which is
            -- what shows "2 dotfiles".
            local want = ("%d.%d"):format(index, mon_index)

            -- A title wins over the labeller and is not asked again: that is
            -- what makes it frozen against the terminal wandering off to
            -- another directory.
            local label = titles[ws.id] or (labeller and labeller(ws))
            if label and label ~= "" then
                want = ("%d %s"):format(index, label)
                if taken[want] then
                    want = ("%d %s (%d)"):format(index, label, mon_index)
                end
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
-- whatever it calls one it knows nothing about. A title cannot apply: the id
-- has only just been minted, and forget_desktop dropped whatever the last
-- desktop to hold it was called.
--
-- Unique, because two desktops sharing a name light up each other's buttons on
-- the bar, and because the renaming pass would only have to undo it.
local function name_for_new_desktop(mon)
    local label = labeller and labeller({})

    local used = {}
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if ws.name then
            used[ws.name] = true
        end
    end

    for mon_index, slot in ipairs(monitor_slots()) do
        if slot.monitor and mon and slot.monitor.id == mon.id then
            -- Not +1: this runs after the desktop has been created, so it is
            -- already in the count, and it sorts last because its id is the
            -- highest. Adding one named it "3" for the ~100ms until the
            -- renumbering pass corrected it to "2".
            local index = #desktops_on(mon)

            -- Same shape as the renumbering pass settles on, so the name does
            -- not visibly change a moment after the desktop appears. An
            -- unlabelled desktop still gets its number here rather than being
            -- left nil: without it the bar shows the raw workspace id for the
            -- ~80ms until the deferred pass runs.
            local candidate
            if label and label ~= "" then
                candidate = ("%d %s"):format(index, label)
                if used[candidate] then
                    candidate = ("%d %s (%d)"):format(index, label, mon_index)
                end
            else
                candidate = ("%d.%d"):format(index, mon_index)
            end

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

-- Whether an empty desktop stays open once you leave it.
--
-- Hyprland removes an empty workspace the moment it stops being visible, and a
-- `persistent` workspace rule is the only thing that stops it -- there is no
-- dispatcher for this. Issuing the rule at runtime works, with three
-- behaviours worth knowing, all established against a nested instance:
--
-- The selector is the desktop's *id* as a string, and it goes on matching
-- after the renumbering pass has renamed the desktop -- the id is the identity
-- here as it is everywhere else in this file. Re-issuing a rule for the same
-- selector replaces the old one rather than adding a second.
--
-- Switching persistence off removes the desktop at once, but only when it is
-- out of view: Hyprland will not destroy the workspace it is showing.
-- close_desktop_here therefore focuses elsewhere first and drops the rule
-- second (through forget_desktop, which is where a rule is dropped), and that
-- order matters.
--
-- None of this survives `hyprctl reload`: the rule list is rebuilt from the
-- config, which knows nothing of what has been created since, so an empty
-- desktop does not outlive a dotfiles-reload. Left that way on purpose.
-- Writing the ids to a file and replaying them was the alternative, and it
-- replays at login too, where it would mint phantom desktops from whatever
-- last happened to be open.
-- The rule has to name the monitor, and leaving it out is the bug this comment
-- exists for: issuing *any* persistent workspace rule makes Hyprland re-place
-- every persistent workspace it knows about, and one whose rule names no
-- monitor is placed on whichever screen has focus at that moment. So making an
-- empty desktop on one screen dragged every empty desktop from the other
-- screen over to join it -- reproduced in a nested instance, three desktops
-- changing screens on a single keypress.
--
-- Naming the monitor pins each one where it belongs, so the re-placement pass
-- puts everything back exactly where it already was. It follows that the name
-- has to be kept current: a persistent desktop that moves screens gets its
-- rule re-issued, or the next pass would haul it back -- and that a desktop
-- which goes has to take its rule with it, because the monitor it names also
-- decides where the *next* desktop born with that id appears. That is
-- unbind_desktop's job, up in the forgetting section.
local function set_persistent(id, persistent, monitor)
    persisted[id] = persistent or nil
    hl.workspace_rule({
        workspace = tostring(id),
        persistent = persistent,
        monitor = monitor,
    })
end

local function is_persistent(id)
    return persisted[id] == true
end

----------------------------------------------------------------------------
-- Titling a desktop
----------------------------------------------------------------------------

-- The desktop in view, or nil when what is in view is not one.
--
-- A monitor reports its desktop and its special workspace separately, so this
-- is still the desktop while the quake terminal has the keyboard -- which is
-- exactly where `title` is typed. It is nil only while focus is inside a
-- special workspace outright, which happens for a moment as a window is moved
-- out of one.
local function focused_desktop()
    local mon = hl.get_active_monitor()
    local ws  = mon and mon.active_workspace
    if ws and not ws.special then
        return ws
    end
    return nil
end

-- Told whenever a title changes, so session.lua can write it down at once.
--
-- A title is the one thing about a desktop that nothing else can reconstruct,
-- and renaming a workspace raises no event of its own -- no workspace.created,
-- no workspace.active -- so without this the session file would not learn
-- about a new title until something unrelated happened to trigger a save. The
-- gap mattered the moment titles had to survive a reload, which is the file
-- handing them over.
local title_hooks = {}

local function on_title_changed(fn)
    table.insert(title_hooks, fn)
end

-- Give a desktop a name of its own. nil or "" clears it, and the desktop goes
-- back to being named after its terminal's directory or the program on it.
--
-- Renames nothing by itself: the caller says when, because one of them --
-- session.lua putting titles back across a reload -- runs while the config is
-- still loading, where creating a timer takes the whole compositor down. Both
-- of the others renumber a moment later anyway.
local function set_title(id, title)
    if title == "" then
        title = nil
    end

    titles[id] = title

    for _, fn in ipairs(title_hooks) do
        fn(id, title)
    end
end

local function title_of(id)
    return titles[id]
end

-- Keep a desktop open although it is empty, as naming one does -- for a
-- desktop that already exists and is already where it belongs.
--
-- The rule is pinned to the screen the desktop is on *now*, read back from
-- Hyprland rather than remembered, because a persistent rule that names no
-- monitor is placed on whichever screen has focus and drags the desktop
-- there. The workspace knows its monitor even during a reload, which is when
-- this is called (session.lua, putting titles back): verified in a nested
-- instance, where get_workspaces() at that moment carries the monitor.
--
-- Creates no timer for the same reason, so it renames nothing; the caller
-- renumbers when it has finished.
local function keep_open(id)
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if ws.id == id and not ws.special then
            set_persistent(id, true, ws.monitor and ws.monitor.name)
            return true
        end
    end
    return false
end

-- The same for the desktop in view, which is what bin/title asks for through
-- `hyprctl repl`. Returns the name the desktop now goes by, number and all,
-- or nil when there was no desktop to name.
--
-- Renamed on the spot rather than left to the deferred pass, so that answer is
-- true by the time the script sees it -- and so a name typed into a terminal
-- appears on the bar with the keypress rather than a tick later.
local function set_title_here(title)
    local ws = focused_desktop()
    if not ws then
        return nil
    end

    set_title(ws.id, title)

    -- Naming a desktop is asking for it, so it is kept open from here on, the
    -- way one made with SUPER+n on the screen you are already on is.
    --
    -- Without this a named desktop can evaporate while you are looking away,
    -- which is exactly what happened the first time this was tried in a nested
    -- instance. A desktop whose only content is its quake terminal counts as
    -- empty -- the terminal sits in a special workspace of its own -- so
    -- stepping to the next desktop had Hyprland sweep the named one up, taking
    -- the name, the terminal and the shell's directory with it.
    --
    -- Clearing a title deliberately does not undo this. Un-persisting an empty
    -- desktop deletes it, and typing `title` to go back to the directory name
    -- is not a request to close anything; SUPER+C is how a desktop goes.
    if titles[ws.id] and not persisted[ws.id] then
        local mon = hl.get_active_monitor()
        set_persistent(ws.id, true, mon and mon.name)
    end

    renumber_desktops()

    -- Read back rather than rebuilt: the pass decides the number, and whether
    -- a name that collides with another screen's gains a "(2)".
    for _, other in ipairs(hl.get_workspaces() or {}) do
        if other.id == ws.id then
            return other.name
        end
    end
    return nil
end

local function monitor_named(wanted)
    for _, m in ipairs(hl.get_monitors() or {}) do
        if identity(m) == wanted then
            return m
        end
    end
end

-- Put a desktop back: make sure it exists, on the screen it was on, and keep it
-- open if it was being kept open. session.lua calls this once per desktop it has
-- written down, before it relaunches anything into them.
--
-- The screen is named by identity rather than connector, as everywhere else
-- here, and one that is not plugged in right now simply leaves the desktop
-- wherever it was born -- `home` is recorded anyway, so plugging the screen
-- back in sends it there.
local function place_desktop(id, wanted, persistent)
    local exists = false
    for _, ws in ipairs(hl.get_workspaces() or {}) do
        if ws.id == id then
            exists = true
        end
    end

    -- Focusing an id that does not exist is what creates it. It is born on the
    -- focused monitor, which is why the move below is unconditional: at login
    -- every desktop would otherwise pile onto whichever screen has focus.
    if not exists then
        hl.dispatch(hl.dsp.focus({ workspace = id }))
    end

    local mon = wanted and monitor_named(wanted)

    if persistent then
        -- The screen it is being put back on, when that screen is plugged in;
        -- otherwise wherever it was born, which is where it stays for now.
        local born = hl.get_active_monitor()
        set_persistent(id, true, mon and mon.name or (born and born.name))
    end

    if wanted then
        home[id] = wanted
        if mon then
            hl.dispatch(hl.dsp.workspace.move({ workspace = id, monitor = mon.name }))
        end
    end

    schedule_renumber()
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
--
-- `persistent` asks for a desktop that stays open while empty, which is what
-- focus_screen makes on the screen you are already on: asked for one outright,
-- you get to leave it and come back to it before there is anything on it. The paths that put a window on the new
-- desktop do not need it -- a desktop with a window on it is never swept up --
-- and would leave the empty husk behind after the window closes.
--
-- The rule goes on after the focus dispatch, not before: it is the focus that
-- decides which monitor the desktop is born on, and a persistent rule naming
-- no monitor would have Hyprland pick.
local function create_new_desktop_here(persistent)
    -- The desktop is born on whichever monitor has focus, so that is the row
    -- it has to land at the end of.
    local id = unused_desktop_id(hl.get_active_monitor())
    hl.dispatch(hl.dsp.focus({ workspace = id }))

    if persistent then
        local mon = hl.get_active_monitor()
        set_persistent(id, true, mon and mon.name)
    end

    local name = name_for_new_desktop(hl.get_active_monitor())
    if name then
        hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = name }))
    end

    schedule_renumber()
    return id
end

local function new_desktop_here(persistent)
    create_new_desktop_here(persistent)
end

-- Close the desktop in view, if there is nothing on it. This is the other half
-- of SUPER+C, which closes the focused window: an empty desktop is the one
-- occasion that key has no window to close, so it closes the desktop instead
-- (see keybinds.lua). Returns whether it did.
--
-- Refuses on a monitor's last desktop -- Hyprland always shows one, so there
-- would be nothing to put in its place -- and on a special workspace, which is
-- not a desktop at all.
--
-- A desktop whose only content is its quake terminal counts as empty, because
-- the terminal sits in a workspace of its own. The terminal is closed with the
-- desktop, through the hook below -- otherwise it would outlive it and be
-- inherited by whichever desktop is minted with the same id next, bringing that
-- desktop's name and working directory back from a desktop that was closed on
-- purpose. Note that this is the opposite of what happens when Hyprland sweeps
-- an empty desktop up on its own, which quake.lua deliberately does not react
-- to: leaving a desktop is not a decision to be rid of it, and closing it is.
local function close_desktop_here()
    local mon = hl.get_active_monitor()
    local ws = mon and mon.active_workspace
    if not ws or ws.special then
        return false
    end

    if #(hl.get_workspace_windows(ws.id) or {}) > 0 then
        return false
    end

    local target = desktop_after_closing(mon, ws)
    if not target or target.id == ws.id then
        return false
    end

    -- Out of view first: Hyprland will not remove the workspace it is showing,
    -- so un-persisting it while it is in view leaves it standing.
    focus_workspace(target)

    -- The same cleanup a lapsed desktop gets, just without waiting for the
    -- pass to notice. Everything keyed to this id goes: its workspace rule --
    -- which is what un-persists it, so this is not merely tidying and has to
    -- stay after the focus above -- its screen, its place in the row, its
    -- terminal, its layout.
    forget_desktop(ws.id)

    schedule_renumber()
    return true
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

            -- Same reason as the move above: a stale rule would undo this.
            if persisted[ws.id] then
                set_persistent(ws.id, true, target)
            end
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

----------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------
--
-- These used to be the bodies of the number-key binds. modes.lua owns the keys
-- now and calls in here, which is why they take a slot number rather than
-- reading a key: the same action is reached from a chord in normal mode and
-- from a motion inside a mode, and neither should know how the other is typed.
--
-- Every one of them takes n = 1..10, a monitor slot, and quietly does nothing
-- when that slot holds no usable monitor -- either because there is no such
-- screen or because it is duplicating another one and so has no desktops of
-- its own.

-- Focus a screen. On the screen you are already on there is nothing to focus,
-- so it makes a desktop instead: "go to a desktop that does not exist yet".
-- Persistent, because a desktop asked for outright should survive being left
-- empty, unlike one passed through on the way somewhere else.
local function focus_screen(n)
    local slot = monitor_for(n)
    if not slot or not slot.monitor then
        return
    end

    if is_focused(slot) then
        new_desktop_here(true)
    else
        focus_workspace(slot.monitor.active_workspace)
    end
end

-- Take the focused window to a screen, or to a fresh desktop on the screen you
-- are on -- the same overload as focus_screen, one scope down.
local function move_window_to_screen(n)
    local slot = monitor_for(n)
    if not slot or not slot.monitor then
        return
    end

    if is_focused(slot) then
        move_focused_window_to_new_desktop()
    else
        move_window_to(slot.monitor.active_workspace)
    end
end

-- Take the focused window's whole column across.
--
-- The window has to be read before anything moves: creating a desktop means
-- focusing it, and the column is identified by the focused window's stable id,
-- which would by then be gone (or be a different window).
local function move_column_to_screen(n)
    local slot = monitor_for(n)
    if not slot or not slot.monitor then
        return
    end

    local win = hl.get_active_window()
    if not win or win.floating or not win.workspace then
        return
    end

    local target_id
    if is_focused(slot) then
        target_id = create_new_desktop_here()
    else
        local target = slot.monitor.active_workspace
        target_id = target and target.id
    end

    if target_id then
        columns.move_column_to_workspace(win.workspace.id, target_id, win.stable_id)
    end
end

-- Send the whole desktop in view to another screen, and record that it now
-- belongs there so a replug puts it back. Nothing to do on the screen it is
-- already on.
local function move_desktop_to_screen(n)
    local slot = monitor_for(n)
    if not slot or not slot.monitor or is_focused(slot) then
        return
    end

    local mon = hl.get_active_monitor()
    local ws = mon and mon.active_workspace
    if not ws or ws.special then
        return
    end

    home[ws.id] = identity(slot.monitor)

    -- Remembered before the move, while the target's row can still be read
    -- without this desktop in it. Hyprland has not moved it yet either way --
    -- the dispatch below is what does that -- so desktops_on(target) is exactly
    -- the row it is about to join.
    place_at_end_of(slot.monitor, ws)

    hl.dispatch(hl.dsp.workspace.move({ workspace = ws.id, monitor = slot.monitor.name }))

    -- Its rule still names the screen it came from, which the next
    -- re-placement pass would act on and drag it straight back.
    if persisted[ws.id] then
        set_persistent(ws.id, true, slot.monitor.name)
    end

    schedule_renumber()
end

-- Duplicate/extend. Note the missing `slot.monitor` check: a slot that is
-- currently mirroring has no monitor object at all, and switching it back off
-- has to keep working, which is the whole reason `mirrored` is remembered.
local function toggle_mirror_screen(n)
    local slot = monitor_for(n)
    if not slot then
        return
    end

    toggle_mirror(slot, hl.get_active_monitor())
end

-- The nth desktop on the screen in view, addressed by position rather than by
-- Hyprland's global workspace id.
--
-- The position is the one you can see: desktops_on sorts by id, which is the
-- same order renumber_desktops names them in ("1.1", "1.2", ...) and therefore
-- the order Waybar shows. So "the second button on the bar" is n = 2, on every
-- screen, regardless of what global ids those desktops happen to hold.
--
-- Does nothing when there is no such desktop. Going somewhere that is not
-- there is not a request to create it -- SUPER+n on the screen you are on is
-- how a desktop gets made, and it stays deliberately separate.
local function desktop_at(n)
    local mon = hl.get_active_monitor()
    return mon and desktops_on(mon)[n]
end

local function focus_desktop_index(n)
    focus_workspace(desktop_at(n))
end

-- How many desktops the screen in view has, so a mode can describe only the
-- ones that exist.
local function desktop_count()
    local mon = hl.get_active_monitor()
    return mon and #desktops_on(mon) or 0
end

-- Move the desktop in view one place along its own screen's row.
--
-- Swapping the two sort keys is the whole operation: it gives both desktops an
-- explicit position even if they were until now relying on their ids, and
-- leaves every other desktop alone. The workspace id never changes, so windows,
-- the quake terminal and the persistence rule all stay where they are.
--
-- Deliberately does not wrap. At either end there is nowhere further to go, and
-- silently teleporting a desktop to the other side of the row is not what
-- "move it left" should do.
local function move_desktop_in_row(step)
    local mon = hl.get_active_monitor()
    local ws = mon and mon.active_workspace
    if not ws or ws.special then
        return
    end

    local list = desktops_on(mon)

    local current
    for i, other in ipairs(list) do
        if other.id == ws.id then
            current = i
            break
        end
    end

    local target = current and list[current + step]
    if not target then
        return
    end

    position[ws.id], position[target.id] = sort_key(target), sort_key(ws)
    schedule_renumber()
end

-- The desktop axis. step = 1 is the next desktop, -1 the previous; both wrap.
local function focus_neighbour_desktop(step)
    local mon = hl.get_active_monitor()
    if mon then
        focus_workspace(neighbour_desktop(mon, step))
    end
end

local function move_window_to_neighbour_desktop(step)
    local mon = hl.get_active_monitor()
    if mon then
        move_window_to(neighbour_desktop(mon, step))
    end
end

-- Take the focused window's whole column to an existing desktop.
--
-- A floating window is in no column, and with nothing focused there is no
-- column to name, so both do nothing rather than guessing.
local function move_column_to(ws)
    if not ws then
        return
    end

    local win = hl.get_active_window()
    if not win or win.floating or not win.workspace then
        return
    end

    columns.move_column_to_workspace(win.workspace.id, ws.id, win.stable_id)
end

local function move_column_to_neighbour_desktop(step)
    local mon = hl.get_active_monitor()
    move_column_to(mon and neighbour_desktop(mon, step))
end

-- Send the window, or its column, to the nth desktop on this screen -- the
-- counterpart of focus_desktop_index, and numbered the same way. Nothing
-- happens when there is no such desktop: these move to a desktop, they do not
-- mint one, which is what keeps them predictable when the count changes.
local function move_window_to_desktop_index(n)
    move_window_to(desktop_at(n))
end

local function move_column_to_desktop_index(n)
    move_column_to(desktop_at(n))
end

-- How many screens are addressable right now, so modes.lua can say "screen 3"
-- in a description without inventing screens that are not there. The keys are
-- bound for all ten slots regardless: a screen plugged in later has to work
-- without a reload.
local function screen_count()
    return #monitor_slots()
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

-- columns.lua keeps a layout per desktop, keyed by workspace id like
-- everything else, so a recycled id used to come back with a dead desktop's
-- columns. Registered here rather than in columns.lua because that file is
-- required by this one and knows nothing about desktops coming and going.
on_forget(function(id) columns.forget(id) end)

-- Set by quake.lua, which knows what each desktop is being used for.
--
-- Deliberately does not renumber: this is called while the config is still
-- loading, and creating a timer there segfaults Hyprland outright. The
-- hyprland.start hook below does the first pass, by which time this is set.
local function set_labeller(fn)
    labeller = fn
end

return {
    -- Actions, called by modes.lua, which owns the keys.
    focus_screen = focus_screen,
    move_window_to_screen = move_window_to_screen,
    move_column_to_screen = move_column_to_screen,
    move_desktop_to_screen = move_desktop_to_screen,
    move_desktop_in_row = move_desktop_in_row,
    toggle_mirror_screen = toggle_mirror_screen,
    focus_desktop_index = focus_desktop_index,
    move_window_to_desktop_index = move_window_to_desktop_index,
    move_column_to_desktop_index = move_column_to_desktop_index,
    desktop_count = desktop_count,
    focus_neighbour_desktop = focus_neighbour_desktop,
    move_window_to_neighbour_desktop = move_window_to_neighbour_desktop,
    move_column_to_neighbour_desktop = move_column_to_neighbour_desktop,
    screen_count = screen_count,

    set_labeller = set_labeller,
    -- Naming a desktop outright: set_title_here is bin/title's entry point,
    -- the rest are session.lua writing titles down and putting them back.
    set_title_here = set_title_here,
    set_title = set_title,
    title_of = title_of,
    on_title_changed = on_title_changed,
    keep_open = keep_open,
    on_forget = on_forget,
    new_desktop_here = new_desktop_here,
    close_desktop_here = close_desktop_here,
    is_persistent = is_persistent,
    place_desktop = place_desktop,
    renumber_desktops = renumber_desktops,
    schedule_renumber = schedule_renumber,
    desktops_on = desktops_on,
    monitor_slots = monitor_slots,
    restore_homes = restore_homes,
    identity = identity,
    toggle_mirror = toggle_mirror,
}
