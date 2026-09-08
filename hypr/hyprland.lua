-- Hyprland entry point.
-- https://wiki.hypr.land/Configuring/Start/
--
-- The actual configuration lives in the modules below, each a separate file in
-- this directory. Hyprland puts the config directory on Lua's package.path, so
-- require() finds them by name.
--
--   programs     shared app names and the main modifier (a table, required by
--                the other modules rather than listed here)
--   monitors     display layout
--   environment  env vars, PATH, permissions
--   look         gaps, borders, decoration, animations, layouts
--   input        keyboard, mouse, touchpad, gestures
--   windowrules  window, layer and workspace rules
--   keybinds     the letter keys: apps and one-shot window actions
--   deskbinds    what the screen and desktop keys do, as callable actions
--   columns      column behaviour: new column, sizing, swap-biggest
--   modes        every axis key, and the modes they work inside
--   quake        drop-down terminal, one per desktop
--   session      what was open and where, written down and put back at login
--   autostart    processes launched with the session

require("monitors")
require("environment")
require("look")
require("input")
require("windowrules")
require("keybinds")
require("deskbinds")
require("columns")

-- After both of the above: it binds the keys that call into them.
require("modes")

require("quake")

-- After quake and deskbinds, both of which it asks about the session it is
-- writing down.
require("session")

-- Last, so anything it launches sees the environment set above.
require("autostart")
