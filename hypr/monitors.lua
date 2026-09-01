-- Monitors
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
--
-- This machine has eDP-1 (1920x1200 laptop panel) and DP-4 (3440x1440
-- ultrawide). The catch-all below lets Hyprland place them automatically;
-- waybar/config.jsonc does refer to the names explicitly.

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})
