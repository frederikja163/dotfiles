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
--   keybinds     every bind, each with a description for the cheatsheet
--   deskbinds    monitor + desktop binds on the number keys
--   columns      column behaviour: new column, sizing, swap-biggest
--   quake        drop-down terminal, one per desktop
--   autostart    processes launched with the session

require("monitors")
require("environment")
require("look")
require("input")
require("windowrules")
require("keybinds")
require("deskbinds")
require("columns")
require("quake")

-- Last, so anything it launches sees the environment set above.
require("autostart")
