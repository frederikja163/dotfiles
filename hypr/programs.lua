-- Default applications, shared by autostart.lua and keybinds.lua.
-- Returned as a table so the other modules can require it.

-- When running nested for testing (HYPR_SANDBOX=1) the host Hyprland grabs
-- every SUPER combination before the nested instance can see it, so the
-- sandbox uses ALT instead and the binds become testable.
local mainMod = os.getenv("HYPR_SANDBOX") == "1" and "ALT" or "SUPER"

return {
    terminal    = "kitty",
    fileManager = "dolphin",
    menu        = "fuzzel",

    mainMod     = mainMod,
}
