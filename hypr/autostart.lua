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

    -- Status bars (one per monitor, see waybar/config.jsonc)
    hl.exec_cmd("waybar")

    -- Wallpaper
    hl.exec_cmd("hyprpaper")

    -- Idle timeouts: dim, lock, displays off, suspend (see hypridle.conf)
    hl.exec_cmd("hypridle")

    -- dunst is started on demand over dbus, so it needs no entry here.
end)
