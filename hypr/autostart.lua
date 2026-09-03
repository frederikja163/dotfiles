-- Processes started with the session
-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- When running nested for testing (HYPR_SANDBOX=1), start nothing. hypridle in
-- particular would lock or suspend the *host* session from inside the sandbox,
-- and a second waybar/hyprpaper would fight the real ones.
if os.getenv("HYPR_SANDBOX") == "1" then
    return
end

hl.on("hyprland.start", function ()
    -- Polkit authentication agent (not on $PATH, must use the full path)
    hl.exec_cmd("/usr/lib/hyprpolkitagent/hyprpolkitagent")

    -- Status bar on the main monitor (see bin/waybar-main)
    hl.exec_cmd("waybar-main")

    -- Wallpaper
    hl.exec_cmd("hyprpaper")

    -- Idle timeouts: dim, lock, displays off, suspend (see hypridle.conf)
    hl.exec_cmd("hypridle")

    -- dunst is started on demand over dbus, so it needs no entry here.
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
