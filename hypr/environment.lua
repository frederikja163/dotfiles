-- Environment variables and permissions
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- ~/.local/bin (linked to the dotfiles bin/ folder) holds scripts used by the
-- keybinds. The graphical session never sources the zsh config, so the PATH
-- export there does not apply here and has to be repeated.
-- The guard keeps `hyprctl reload` from prepending the same entry repeatedly.
local localBin = os.getenv("HOME") .. "/.local/bin"
local currentPath = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin"
if not string.find(currentPath, localBin, 1, true) then
    hl.env("PATH", localBin .. ":" .. currentPath)
end


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
