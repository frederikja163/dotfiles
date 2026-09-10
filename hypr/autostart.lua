-- Processes started with the session
-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- When running nested for testing (HYPR_SANDBOX=1), start nothing. hypridle in
-- particular would lock or suspend the *host* session from inside the sandbox,
-- and a second waybar/hyprpaper would fight the real ones.
if os.getenv("HYPR_SANDBOX") == "1" then
    return
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
    hl.exec_cmd("waybar-main")

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
    -- It checks at once and then every 30 seconds until the fetch works, so
    -- unlike the rest of this list it can outlive the login by a long way: on a
    -- machine that never gets online it retries for the whole session. That is
    -- deliberate, and it is one sleeping process, but it is the only entry here
    -- that does not simply start something and finish.
    hl.exec_cmd("dotfiles-check-updates")
end)

-- Which monitor is the main one can change: docking, undocking, a cable moving
-- to another port. Put the bar back on whichever it is now.
local restart_pending = false

local function restart_waybar()
    if restart_pending then
        return
    end
    restart_pending = true

    -- Deferred, so the monitor list has settled, and coalesced, because a
    -- redock emits several events in a row.
    hl.timer(function()
        restart_pending = false
        hl.exec_cmd("waybar-main")
    end, { timeout = 1000, type = "oneshot" })
end

for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
    hl.on(event, restart_waybar)
end
