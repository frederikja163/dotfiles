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
local browser     = programs.browser
local menu        = programs.menu


-- Applications and window actions

-- A second terminal on the desktop starts where the quake terminal is, so it
-- comes up in the same place with a shell and history of its own rather than in
-- $HOME. A desktop with no quake terminal has nowhere in particular to be, and
-- gets a plain one.
--
-- quake is required in here rather than at the top of the file: it pulls in
-- deskbinds and columns, and this file is loaded before either of them.
hl.bind(mainMod .. " + Q", function()
    local directory = require("quake").directory()

    local command = terminal
    if directory then
        -- Single quoted for the shell that runs this, since a path may contain
        -- spaces. --directory is kitty's, as --class already is in quake.lua.
        command = ("%s --directory '%s'"):format(terminal, directory:gsub("'", "'\\''"))
    end

    hl.dispatch(hl.dsp.exec_cmd(command))
end, { description = "App: terminal (where this desktop is)" })
-- Closes the focused window; on an empty desktop it closes the desktop, which
-- is the counterpart to SUPER+#f making one. Focusing an empty desktop clears the
-- focused window, so no active window is exactly that case -- and a quake
-- terminal in view is a focused window like any other, so that still closes the
-- terminal rather than the desktop underneath it. deskbinds refuses when the
-- desktop is a monitor's last one, or has anything on it.
--
-- deskbinds is required inside the callback for the same reason quake is above:
-- this file is loaded before it.
local closeWindowBind = hl.bind(mainMod .. " + C", function()
    if hl.get_active_window() then
        hl.dispatch(hl.dsp.window.close())
    else
        require("deskbinds").close_desktop_here()
    end
end, { description = "Window: close (polite), or an empty desktop" })
-- SHIFT here is the letter-key rule at work: on a letter a modifier marks a
-- variant of that letter's action, and a force kill is exactly the brutal
-- variant of a close. It deliberately did not move when everything else did --
-- this is the one destructive key in the config, and relearning it by accident
-- is how you lose unsaved work.
hl.bind(mainMod .. " + SHIFT + C", function()
    hl.dispatch(hl.dsp.exec_cmd("kill -9 $(hyprctl activewindow | awk '/^\tpid:/ { print $2 }')"))
end, { description = "Window: force kill (abrupt)" })
-- closeWindowBind:set_enabled(false)
-- Promoting a window through the widest column used to be SUPER+M; it is `p`
-- in the size mode now, and M is the move verb. Exiting Hyprland is handled by
-- the power menu on M+Escape, which asks for confirmation.
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "App: file manager" })
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd(browser),      { description = "App: browser" })

-- bin/ide: Rider if the directory holds a .NET solution, nvim otherwise. Given
-- the desktop's directory, so it opens whatever that desktop is for. It brings
-- up a terminal of its own when it needs one, which a keybind cannot give it.
hl.bind(mainMod .. " + I", function()
    local directory = require("quake").directory() or os.getenv("HOME") or "."
    hl.dispatch(hl.dsp.exec_cmd(("ide '%s'"):format(directory:gsub("'", "'\\''"))))
end, { description = "App: editor (where this desktop is)" })

-- opencode is a TUI, so it gets a terminal of its own on this desktop — the
-- same trick as SUPER+Q, just with a program to run once kitty is there. Its
-- desktop directory is the one thing a keybind-launched process does not get
-- from the shell, hence the explicit --directory.
hl.bind(mainMod .. " + O", function()
    local directory = require("quake").directory() or os.getenv("HOME") or "."
    hl.dispatch(hl.dsp.exec_cmd(
        ("%s --directory '%s' opencode"):format(terminal, directory:gsub("'", "'\\''"))))
end, { description = "App: opencode (where this desktop is)" })
-- Fullscreen stays a chord because it is pressed constantly. Floating is the
-- rarer shape change and lives in the size mode, in modes.lua.
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ action = "toggle" }), { description = "Window: toggle fullscreen" })
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(menu), { description = "App: launcher" })

-- Screenshot of a mouse-selected region, onto the clipboard. In bin/ rather
-- than inline because it is a pipeline: hl.exec_cmd does not run a shell, so
-- the "|" into wl-copy would be passed to grim as an argument.
-- On Print rather than SUPER+S, which is the size mode now. Print is where
-- this belongs anyway, and it needs no modifier at all.
hl.bind("Print", hl.dsp.exec_cmd("screenshot-region"),
        { description = "Screenshot: region to clipboard" })

-- Keybind cheatsheet (this popup)
--
-- submap_universal, so it works from inside a mode too: being unsure which
-- keys are live is exactly when this is wanted, and the list is grouped by
-- mode. Nothing in modes.lua binds slash, so there is nothing for it to
-- collide with.
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("hypr-keybinds"),
        { submap_universal = true, description = "App: this keybind list" })

-- Lock / suspend / log out / reboot / shut down
--
-- Deliberately NOT submap_universal, unlike the cheatsheet above. A universal
-- bind still matches inside a submap, and every mode binds SUPER+Escape to
-- leave itself -- so both would fire and getting out of a mode would offer to
-- log you out. Leaving a mode wins; press it again from normal mode for this.
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("power-menu"),
        { description = "App: power menu" })


-- Everything on an axis key -- h/j/k/l, Tab, the numbers 1..0 -- is in
-- modes.lua, along with the modes those keys work inside and the mouse
-- cyclers. This file is the letter keys: apps, and one-shot actions on the
-- window in front of you.


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
