-- Default applications, shared by autostart.lua and keybinds.lua.
-- Returned as a table so the other modules can require it.

return {
    terminal    = "kitty",
    fileManager = "dolphin",
    menu        = "fuzzel",

    -- "Windows" key as the main modifier for every keybind.
    mainMod     = "SUPER",
}
