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

-- Qt apps were the only thing on this desktop still opening in light mode. GTK
-- is already dark by three separate routes and needs nothing: .gtkrc-2.0 names
-- Breeze-Dark outright, GTK3 reads `gtk-application-prefer-dark-theme` and
-- picks Breeze's gtk-dark.css, and libadwaita asks the portal, which reports
-- prefer-dark. Qt6 was the gap because it loads *no* platform theme plugin
-- unless told to, and bare Fusion never consults the portal at all -- so it
-- stayed at its built-in light default no matter what the rest of the session
-- agreed on.
--
-- `kde` of the three available plugins. It renders window #202326 on #fcfcfc,
-- which is pixel-for-pixel what GTK3 resolves to, so the two toolkits match
-- instead of merely both being dark. `gtk3` was rejected for making Qt apps
-- wear GTK widgets, and `xdgdesktopportal` for setting only colours and
-- dialogs, leaving the widget style at Fusion.
--
-- The catch, and the reason this is worth spelling out: the colours themselves
-- are not in this repo. They live in ~/.config/kdeglobals as [Colors:Window]
-- and friends, written by a Plasma install that is no longer used. Pointed at
-- an empty XDG_CONFIG_HOME this exact variable renders light (#eff0f1), so on
-- a fresh machine the env var alone does not produce a dark desktop -- it only
-- works here because that leftover file happens to still exist.
--
-- Needs plasma-integration for the plugin and breeze for the style; both were
-- only present as Plasma dependencies, so packages/pacman.txt now declares
-- them. Set here rather than in .zshrc for the same reason as PATH and EDITOR
-- above. Already-running apps keep the old value until restarted.
hl.env("QT_QPA_PLATFORMTHEME", "kde")


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
