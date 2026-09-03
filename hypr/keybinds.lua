-- Keybindings
-- See https://wiki.hypr.land/Configuring/Basics/Binds/
--
-- Every bind carries a description, which is what makes the cheatsheet popup
-- (SUPER + /, see bin/hypr-keybinds) possible: it is generated from
-- `hyprctl binds`, and binds without a description are skipped.

local programs = require("programs")

local mainMod     = programs.mainMod
local terminal    = programs.terminal
local fileManager = programs.fileManager
local menu        = programs.menu


-- Applications and window actions

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal), { description = "App: terminal" })
local closeWindowBind = hl.bind(mainMod .. " + C", hl.dsp.window.close(), { description = "Window: close" })
-- closeWindowBind:set_enabled(false)
-- M+M is "swap with the biggest window", see columns.lua. Exiting Hyprland is
-- handled by the power menu on M+Escape, which asks for confirmation.
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "App: file manager" })
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }), { description = "Window: toggle floating" })
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(menu), { description = "App: launcher" })

-- Keybind cheatsheet (this popup)
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("hypr-keybinds"), { description = "App: this keybind list" })

-- Lock / suspend / log out / reboot / shut down
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("power-menu"), { description = "App: power menu" })


-- Focus, move and resize all belong to the layout, which knows where the
-- columns are, so they live in columns.lua.

-- Workspaces
--
-- The number keys 1..0 are not bound here. They address monitors and desktops
-- instead, in deskbinds.lua.

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }),
        { description = "Screen: next desktop" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }),
        { description = "Screen: previous desktop" })


-- Mouse

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, description = "Window: drag" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Window: resize with the mouse" })


-- Laptop multimedia keys for volume and LCD brightness

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true, description = "Volume down" })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true, description = "Mute audio" })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true, description = "Mute microphone" })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true, description = "Brightness up" })
hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true, description = "Brightness down" })

-- Requires playerctl
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true, description = "Next track" })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Play/pause" })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Play/pause" })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true, description = "Previous track" })
