-- Default applications, shared by autostart.lua and keybinds.lua.
-- Returned as a table so the other modules can require it.

-- SUPER everywhere, including a nested test instance. Swapping it to ALT there
-- used to make binds pressable by hand, but it also collapsed
-- mainMod + ALT + SHIFT onto plain ALT + SHIFT, hiding real collisions. Nested
-- testing goes through `hyprctl dispatch` anyway, which does not need a key.
local mainMod = "SUPER"

return {
    terminal    = "kitty",
    fileManager = "dolphin",
    menu        = "fuzzel",

    mainMod     = mainMod,
}
