-- Window, layer and workspace rules
-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- and https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

local suppressMaximizeRule = hl.window_rule({
    -- Ignore maximize requests from all apps. You'll probably like this.
    name  = "suppress-maximize-events",
    match = { class = ".*" },

    suppress_event = "maximize",
})
-- suppressMaximizeRule:set_enabled(false)

hl.window_rule({
    -- Fix some dragging issues with XWayland
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },

    no_focus = true,
})

-- A maximized window (SUPER+F, keybinds.lua) fills the screen below the bar
-- with nothing round it: no border, no gaps.
--
-- `fullscreen = true` is the only matcher there is -- `maximized` and
-- `fullscreen_state` are both "unknown match property" -- and it covers true
-- fullscreen as well, where the border is off-screen anyway. Unlike most
-- rules it is re-checked when the state changes, not only at creation:
-- measured in a nested instance, a maximized window went to exactly the
-- screen below the bar (550x310 under a 40px bar on a 550x350 screen; with
-- the 2px border it would have been 546 wide) and got its border back the
-- moment it was unmaximized.
--
-- The gaps are a workspace rule because a window rule has no gaps field.
-- f[1] is a desktop with a maximized window on it, so it reaches the windows
-- underneath too: they re-tile without gaps while hidden and go back when the
-- maximized one does. Nothing sees it happen.
hl.window_rule({
    name  = "no-border-when-fullscreen",
    match = { fullscreen = true },

    border_size = 0,
})
hl.workspace_rule({ workspace = "f[1]", gaps_out = 0, gaps_in = 0 })

-- Hyprland-run windowrule
hl.window_rule({
    name  = "move-hyprland-run",
    match = { class = "hyprland-run" },

    move  = "20 monitor_h-120",
    float = true,
})

-- Layer rules also return a handle.
-- local overlayLayerRule = hl.layer_rule({
--     name  = "no-anim-overlay",
--     match = { namespace = "^my-overlay$" },
--     no_anim = true,
-- })
-- overlayLayerRule:set_enabled(false)

-- "Smart gaps" / "No gaps when only"
-- Uncomment all if you wish to use that.
-- hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0, gaps_in = 0 })
-- hl.workspace_rule({ workspace = "f[1]",   gaps_out = 0, gaps_in = 0 })
-- hl.window_rule({
--     name  = "no-gaps-wtv1",
--     match = { float = false, workspace = "w[tv1]" },
--     border_size = 0,
--     rounding    = 0,
-- })
-- hl.window_rule({
--     name  = "no-gaps-f1",
--     match = { float = false, workspace = "f[1]" },
--     border_size = 0,
--     rounding    = 0,
-- })
