-- Shared parsing for the pinned monitor file (~/.local/share/hypr/monitor-order),
-- read both by monitors.lua (which turns each screen the way it is mounted) and
-- deskbinds.lua (which numbers them). bin/dotfiles-monitor-setup writes the
-- file; hand-editing it works too. It is machine-local state, not part of the
-- dotfiles, so each computer describes its own screens.
--
-- Format: one screen per line, monitor 1 first. A line is the screen's
-- identity -- the description when there is one (descriptions carry the serial
-- and survive redocks; a connector name does not, DP-4 came back as DP-5), the
-- name otherwise for headless outputs. Optional key=value settings sit on the
-- same line, separated from the identity by whitespace; the only one so far is
-- transform=0..3, the way monitors.lua turns a screen that was mounted
-- portrait. Position in the file is the slot number, absolutely: line N is
-- monitor N.
--
-- A comment line can also set the row's direction with "# layout = ltr|rtl|ttb"
-- -- where monitor 1 leads (1 leftmost / 1 rightmost / 1 on top). It lives in a
-- comment on purpose: deskbinds.lua reads the same file and would otherwise
-- treat it as another screen's identity.
--
-- Keeping the parsing here, rather than in each reader, is the point: the file
-- has gained a second field, and deskbinds must never treat "transform=1" as
-- part of an identity.

local M = {}

local function default_path()
    local data = os.getenv("XDG_DATA_HOME")
    if not data or data == "" then
        data = (os.getenv("HOME") or "") .. "/.local/share"
    end
    -- Overridable so the tests can point at a scratch file.
    return os.getenv("HYPR_MONITOR_ORDER") or (data .. "/hypr/monitor-order")
end

-- Screen identity: description when there is one, name otherwise (headless
-- outputs have no description).
function M.identity(mon)
    if not mon then
        return nil
    end
    local d = mon.description
    if type(d) == "string" and d ~= "" then
        return d
    end
    return mon.name
end

-- The row's direction, from a comment line "# layout = ltr|rtl|ttb": where
-- monitor 1 sits and the way the slots run -- ltr (default): 1 on the left,
-- slots running right; rtl: 1 on the right, running left; ttb: a column with
-- 1 on top. The last comment that says so wins.
function M.layout(path)
    local f = io.open(path or default_path(), "r")
    if not f then
        return "ltr"
    end
    local dir = "ltr"
    for line in f:lines() do
        local name = line:match("^%s*#%s*layout%s*=%s*(%S+)")
        if name then
            dir = name
        end
    end
    f:close()
    return dir
end

-- The file's entries, in order:
-- { identity = string, transform = number|nil }.
-- Comments (#...) and blank lines are skipped.
function M.load(path)
    local entries = {}
    local f = io.open(path or default_path(), "r")
    if f then
        for line in f:lines() do
            local entry = line:gsub("^%s+", ""):gsub("%s+$", "")
            if entry ~= "" and not entry:match("^#") then
                local ident, transform = entry:match("^(.-)%s+transform=(%d+)$")
                if ident then
                    entries[#entries + 1] =
                        { identity = ident, transform = tonumber(transform) }
                else
                    entries[#entries + 1] = { identity = entry }
                end
            end
        end
        f:close()
    end
    return entries
end

return M