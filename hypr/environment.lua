-- Environment variables and permissions
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- The graphical session never sources the zsh config, so the PATH exports there
-- do not apply here and have to be repeated:
--
--   ~/.local/bin                      scripts used by the keybinds, linked to
--                                     the dotfiles bin/ folder
--   bob/nvim-bin                      the bob-managed neovim, which is the only
--                                     nvim on this machine
--   JetBrains/Toolbox/scripts         rider
--
-- The last two are what bin/ide reaches for, and it is started from a keybind,
-- where nothing has sourced a shell profile. Missing, the editor simply never
-- appeared: Rider is launched detached with its output discarded, so "command
-- not found" went nowhere at all.
--
-- The guard keeps `hyprctl reload` from prepending the same entries repeatedly.
local home = os.getenv("HOME")
local dataHome = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
local currentPath = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin"

for _, dir in ipairs({
    dataHome .. "/JetBrains/Toolbox/scripts",
    dataHome .. "/bob/nvim-bin",
    home .. "/.local/bin",
}) do
    if not string.find(currentPath, dir, 1, true) then
        currentPath = dir .. ":" .. currentPath
    end
end

hl.env("PATH", currentPath)


-- Permissions
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Permissions/
-- Note: changes here require a Hyprland restart and are not applied
-- on-the-fly, for security reasons.

-- hl.config({
--   ecosystem = {
--     enforce_permissions = true,
--   },
-- })

-- hl.permission("/usr/(bin|local/bin)/grim", "screencopy", "allow")
-- hl.permission("/usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland", "screencopy", "allow")
-- hl.permission("/usr/(bin|local/bin)/hyprpm", "plugin", "allow")
