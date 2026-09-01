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

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal), { description = "Open terminal" })
local closeWindowBind = hl.bind(mainMod .. " + C", hl.dsp.window.close(), { description = "Close window" })
-- closeWindowBind:set_enabled(false)
-- M+M is "swap with the biggest window", see columns.lua. Exiting Hyprland is
-- handled by the power menu on M+Escape, which asks for confirmation.
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "Open file manager" })
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating" })
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(menu), { description = "Application launcher" })
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo(), { description = "Toggle pseudo-tiling" })
hl.bind(mainMod .. " + T", hl.dsp.layout("togglesplit"), { description = "Toggle split direction" })

-- Keybind cheatsheet (this popup)
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("hypr-keybinds"), { description = "Show this keybind list" })

-- Lock / suspend / log out / reboot / shut down
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("power-menu"), { description = "Power menu" })


-- Focus, swap and resize
-- Vim-style directional binds (hjkl), with arrow keys as aliases.
--   mainMod          + hjkl -> move focus
--   mainMod + SHIFT  + hjkl -> swap window in that direction
--   mainMod + CTRL   + hjkl -> resize active window
-- neovim/init.lua mirrors this scheme, using <leader> in place of SUPER.

-- Horizontal resizing changes the *column* width, which is what left/right
-- means in a column layout. Vertical resizing still resizes the window inside
-- its column.
local resizeStep = 60

-- Vertical SHIFT binds swap the window with its neighbour inside the column.
-- The horizontal ones are column operations (move between columns, swap whole
-- columns) and live in columns.lua instead.
--
-- Horizontal CTRL binds resize the column and are in columns.lua, because they
-- have to know how much room is left on the monitor.
--
-- Focus uses the scrolling layout's own `focus` rather than
-- focus({ direction = ... }). The latter steps onto the neighbouring monitor
-- once it runs out of windows, which ties the binds to how the monitors happen
-- to be arranged; the layout version wraps within the workspace instead.
-- Monitors are switched deliberately with the number keys, see deskbinds.lua.
local directions = {
    { dir = "left",  keys = { "H", "left"  }, focus = "l" },
    { dir = "down",  keys = { "J", "down"  }, focus = "d",
      resize = hl.dsp.window.resize({ x = 0, y =  resizeStep, relative = true }),
      swap = hl.dsp.window.swap({ direction = "down" }) },
    { dir = "up",    keys = { "K", "up"    }, focus = "u",
      resize = hl.dsp.window.resize({ x = 0, y = -resizeStep, relative = true }),
      swap = hl.dsp.window.swap({ direction = "up" }) },
    { dir = "right", keys = { "L", "right" }, focus = "r" },
}

for _, d in ipairs(directions) do
    for _, key in ipairs(d.keys) do
        hl.bind(mainMod .. " + " .. key,
                hl.dsp.layout("focus " .. d.focus),
                { repeating = true, description = "Focus window " .. d.dir })
        if d.swap then
            hl.bind(mainMod .. " + SHIFT + " .. key,
                    d.swap,
                    { repeating = true, description = "Swap window " .. d.dir })
        end
        if d.resize then
            hl.bind(mainMod .. " + CTRL + " .. key,
                    d.resize,
                    { repeating = true, description = "Resize window " .. d.dir })
        end
    end
end


-- Workspaces
--
-- The number keys 1..0 are not bound here. They address monitors and desktops
-- instead, in deskbinds.lua.

-- Special workspace (scratchpad)
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"),
        { description = "Toggle scratchpad" })
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }),
        { description = "Move window to scratchpad" })

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }),
        { description = "Next workspace" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }),
        { description = "Previous workspace" })


-- Mouse

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, description = "Drag window" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Resize window with mouse" })


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
