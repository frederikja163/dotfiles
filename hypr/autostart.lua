-- Processes started with the session
-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- When running nested for testing (HYPR_SANDBOX=1), start nothing. hypridle in
-- particular would lock or suspend the *host* session from inside the sandbox,
-- and a second waybar/hyprpaper would fight the real ones.
if os.getenv("HYPR_SANDBOX") == "1" then
    return
end

-- The bar is started once at hyprland.start and restarted when a monitor comes
-- or goes. Both go through here, so the restart below can tell whether a start
-- has already happened since the monitor event it is answering.
local launches = 0

local function start_waybar()
    launches = launches + 1
    hl.exec_cmd("waybar-main")
end

hl.on("hyprland.start", function ()
    -- Notification daemon, started explicitly and first.
    --
    -- Relying on dbus to activate it on demand was tried and silently ate every
    -- notification for a whole session. Three installed packages ship a service
    -- file for org.freedesktop.Notifications, and plasma-workspace wins:
    -- /usr/share/dbus-1/services/org.kde.plasma.Notifications.service runs
    -- `plasma_waitforname`, which does not start a daemon at all -- it waits
    -- for plasmashell to claim the name. There is no plasmashell here, so it
    -- blocks until dbus times out and dunst is never reached. The only symptom
    -- is notify-send printing "Timeout was reached" to a stderr nobody reads.
    --
    -- Starting it here takes the name before anything can ask dbus for it, so
    -- the plasma stub is never consulted. First in this function for that
    -- reason: an entry below it that notifies on failure would lose it.
    -- Via the unit rather than the bare binary so it stays supervised and dbus
    -- sees the name as taken.
    hl.exec_cmd("systemctl --user start dunst.service")

    -- Polkit authentication agent (not on $PATH, must use the full path)
    hl.exec_cmd("/usr/lib/hyprpolkitagent/hyprpolkitagent")

    -- Status bar on the main monitor (see bin/waybar-main)
    start_waybar()

    -- Wallpaper
    hl.exec_cmd("hyprpaper")

    -- Idle timeouts: dim, lock, displays off, suspend (see hypridle.conf)
    hl.exec_cmd("hypridle")

    -- Start writing the session down, and -- only if this is not the first
    -- compositor since the machine came up -- put the last one back (see
    -- bin/dotfiles-session-restore and hypr/session.lua). Booting does not
    -- restore anything; Hyprland crashing and coming back does.
    --
    -- A script rather than work done here: the monitor list is still empty at
    -- this point, and creating a timer while the config loads takes the
    -- compositor down. It waits for the screens and then hands back.
    --
    -- It must run in every one of those cases, restoring or not: session.lua
    -- writes no session at all until this has told it the matter is settled.
    hl.exec_cmd("dotfiles-session-restore")

    -- Say if this repo is behind its remote (see bin/dotfiles-check-updates).
    -- It checks at once and then once a minute for the whole session, so unlike
    -- the rest of this list it does not finish: it is one sleeping process
    -- watching for commits pushed after login, which a single check at start
    -- would never see. Deliberate, and the only entry here that stays.
    hl.exec_cmd("dotfiles-check-updates")
end)

-- Which monitor is the main one can change: docking, undocking, a cable moving
-- to another port. Put the bar back on whichever it is now.
--
-- The trap is boot. Hyprland adds every monitor *before* it fires
-- hyprland.start, so the monitor.added events arrive while the config is still
-- coming up and schedule a restart a second later. That restart raced the start
-- hyprland.start had just issued: its `pkill` ran before the first bar had
-- spawned, killed nothing, and left a second bar on screen. So a restart is
-- only worth making if nothing has started the bar since the event that asked
-- for it; `restart_generation` records the count at that moment and the timer
-- does nothing once it has moved on. A real hotplug, and every monitor event
-- after an `hyprctl reload` (which re-runs this file, resetting the count, but
-- fires no hyprland.start), leaves the count alone, so the bar still restarts.
local restart_pending = false
local restart_generation = 0

local function restart_waybar()
    -- Kept current even while a restart is already pending: a monitor added
    -- after a start should still be answered, and only the latest request
    -- counts once the timer fires.
    restart_generation = launches

    if restart_pending then
        return
    end
    restart_pending = true

    -- Deferred, so the monitor list has settled, and coalesced, because a
    -- redock emits several events in a row.
    hl.timer(function()
        restart_pending = false
        if launches ~= restart_generation then
            return
        end
        start_waybar()
    end, { timeout = 1000, type = "oneshot" })
end

for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
    hl.on(event, restart_waybar)
end
