-- Environment variables and permissions
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- The graphical session never sources the zsh config, so the PATH exports there
-- do not apply here and have to be repeated:
--
--   ~/dotfiles/bin                    scripts used by the keybinds
--   ~/.local/bin                      anything installed there by pipx, uv or
--                                     pip --user, and scripts not in the repo
--   bob/nvim-bin                      the bob-managed neovim, which is the only
--                                     nvim on this machine
--   JetBrains/Toolbox/scripts         rider
--   ~/.dotnet/tools                   dotnet global tools (dotnet-script,
--                                     roslyn-language-server)
--
-- The last three are what bin/ide reaches for, and it is started from a keybind,
-- where nothing has sourced a shell profile. Missing, the editor simply never
-- appeared -- Rider is launched detached with its output discarded, so "command
-- not found" went nowhere at all -- and nvim could not start the dotnet-tool
-- language servers either.
--
-- The guard keeps `hyprctl reload` from prepending the same entries repeatedly.
--
-- The repo's bin/ is named by its real path. It used to be symlinked onto
-- ~/.local/bin, but that is where pipx, uv and `pip install --user` write, so
-- their shims were landing inside the working tree of a public repo. zsh/.zshrc
-- carries the same pair of entries and the same reasoning at more length. The
-- repo goes last in this list and so ends up first on PATH, ahead of
-- ~/.local/bin: `ide`, `title` and `proc-cwd` are names an installed tool could
-- collide with, and a keybind running the wrong one is silent.
local home = os.getenv("HOME")
local dataHome = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
local currentPath = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin"

for _, dir in ipairs({
    dataHome .. "/JetBrains/Toolbox/scripts",
    dataHome .. "/bob/nvim-bin",
    home .. "/.dotnet/tools",
    home .. "/.local/bin",
    home .. "/dotfiles/bin",
}) do
    if not string.find(currentPath, dir, 1, true) then
        currentPath = dir .. ":" .. currentPath
    end
end

hl.env("PATH", currentPath)

-- EDITOR belongs here for the same reason PATH does, and specifically so yazi
-- opens files in nvim. Nothing in yazi needed configuring for that: its stock
-- `edit` opener is already `${EDITOR:-vi} %s`, and its stock rules send text,
-- code, empty files and folders to it. EDITOR was simply never set anywhere on
-- this machine, so every one of those landed in `vi`.
--
-- Setting it in zsh would not have fixed it. SUPER+E runs `kitty --directory
-- <dir> yazi`, and a kitty given a command to run never starts a login or
-- interactive shell, so no profile is sourced and no export from .zshrc is in
-- scope -- the same trap the PATH entries above fall into. Coming from the
-- compositor it reaches yazi directly, and interactive shells inherit it too,
-- being children of a kitty that Hyprland started.
--
-- Bare `nvim` rather than a full path because bob/nvim-bin is on the PATH built
-- just above; git/config spells the same choice out for its own editor setting.
-- A shell on a TTY outside the graphical session is the one gap and still gets
-- `vi`, which is not worth a second copy of this in .zshrc to close.
hl.env("EDITOR", "nvim")


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
