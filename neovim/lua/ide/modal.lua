-- Sticky modes: a verb key enters a mode, and inside it a few bare keys repeat
-- until Escape. This is hypr/modes.lua's idea carried over to the editor, and
-- it exists for the same reason there: resizing a window, stepping along a
-- list of hunks or a debugger are nudges you repeat, and one chord per nudge
-- is the wrong shape for them.
--
-- A mode is declared with define(), which also binds the key that enters it,
-- and everything declared is kept in a registry so the cheatsheet
-- (ide.palette) can list it. A key inside a mode either leaves it afterwards
-- (`leave = true`, the one-shot kind: naming a destination is finished the
-- moment it happens) or does not (the default: a nudge). Counts work: `5l`
-- is five nudges, or whatever the key makes of a count.
--
-- It is a loop around getcharstr(), not a layer of temporary keymaps. That was
-- the choice the rest follows from, and the alternatives were looked at:
--
--   * hydra.nvim and submode.nvim are keymap layers. A layer cannot say what
--     an unbound key does -- there is no catch-all mapping in Neovim -- and a
--     buffer-local map shadows a layer's global one, so "h resizes" works in
--     one buffer and moves the cursor in the next. Hydra has not had a commit
--     since May 2025, and its hint breaks under the experimental ui2.
--   * mini.clue's postkeys and which-key's `loop` are loops like this one, but
--     neither has an idle timeout or a name the statusline can show, and a key
--     they do not own is replayed with the prefix still attached.
--   * smart-splits had a resize mode and removed it ("a lot of bugs").
--
-- What the loop has to get right, and how it does:
--
--   * Nothing redraws while getcharstr() blocks, so every handled key ends in
--     :redraw, and entering and leaving redraw the statusline, which is where
--     the mode's name is shown (ide.statusline reads current()).
--   * getcharstr() has no timeout. A mode that is entered and forgotten leaves
--     h/j/k/l meaning something else, and nothing says so but the statusline
--     -- the reasoning that gives Hyprland's modes IDLE_TIMEOUT. A luv timer
--     checks the clock and, when it is up, types <Esc> into the keyboard
--     buffer with nvim_input, which is the one input call that may be made from
--     a timer callback. That wakes the blocked read, and a timed-out mode ends
--     the same way a deliberate one does.
--   * <C-c> makes getcharstr() raise; it is caught, and leaves the mode.
--   * An error in a key's function leaves the mode as well, and says so. A
--     loop that kept running after its action threw would repeat the error on
--     every keypress.
--
-- What a key the mode does not own does is `foreign`, and it is a decision
-- rather than an accident. Hyprland passes such a key on to the focused window
-- and stays in the mode; here that would type into the buffer under a mode
-- label that says nothing is typing. The default, "run", leaves the mode and
-- replays the key as if it had been typed, count included -- so `w` after
-- `<leader>s` is a word motion, not a no-op that costs a keypress. "ignore"
-- swallows it and stays, for a mode where an accidental key must do nothing.
--
-- Keys are compared by vim.fn.keytrans() of both sides, so `<S-Tab>` in a
-- declaration and the bytes getcharstr() hands back are the same string.
--
-- The key source is a parameter (`opts.getchar`) so the logic can be tested
-- with a list of keys; the real thing is only the default.

local M = {}

local DEFAULT_IDLE = 3000

local modes, order = {}, {}
local active = nil

local function canon(key)
    return vim.fn.keytrans(vim.keycode(key))
end

local function now()
    return vim.uv.hrtime() / 1e6
end

--- Declare a mode. See the header for the shape; `spec` is
---   desc     one line, what the mode is for (shown in the cheatsheet)
---   entry    the normal-mode key that enters it, or nil
---   open     what the entry key and the palette run instead of enter(), for a
---            mode that has something to do first (review starts reviewing)
---   hint     the keys, as one short line, echoed on entry
---   foreign  "run" (default) or "ignore"
---   pass     keys that are run as ordinary Normal-mode commands and leave the
---            mode as it is: scrolling, in a mode that is for reading
---   idle     milliseconds without a key before it ends itself
---   keys     { { lhs, fn, desc = ..., leave = bool }, ... }, where lhs may be
---            a list: the first is the one the cheatsheet shows, the rest are
---            aliases (a motion on h and on <Left>) that it does not repeat
---   on_enter, on_leave  optional
---@param name string
---@param spec table
function M.define(name, spec)
    assert(not modes[name], 'mode defined twice: ' .. name)
    spec.name = name
    spec.foreign = spec.foreign or 'run'
    spec.idle = spec.idle or DEFAULT_IDLE
    spec.map = {}
    spec.pass_map = {}
    for _, key in ipairs(spec.pass or {}) do
        spec.pass_map[canon(key)] = true
    end
    for _, key in ipairs(spec.keys) do
        local aliases = type(key[1]) == 'table' and key[1] or { key[1] }
        local lhs = aliases[1]
        local entry = { lhs = lhs, fn = key[2], desc = key.desc, leave = key.leave == true }
        assert(entry.desc, ('mode %s: key %s has no desc'):format(name, lhs))
        for _, alias in ipairs(aliases) do
            assert(spec.map[canon(alias)] == nil, ('mode %s binds %s twice'):format(name, alias))
            spec.map[canon(alias)] = entry
        end
    end
    modes[name] = spec
    table.insert(order, name)
    if spec.entry then
        vim.keymap.set('n', spec.entry, function()
            M.open(name)
        end, { desc = 'Mode: ' .. spec.desc })
    end
end

--- What the entry key does: the mode's own `open`, or just entering it.
---@param name string
function M.open(name)
    local spec = modes[name]
    assert(spec, 'no such mode: ' .. tostring(name))
    if spec.open then
        return spec.open()
    end
    return M.enter(name)
end

--- The mode that is running, or nil.
---@return string?
function M.current()
    return active and active.name or nil
end

--- Every mode that has been declared, in order, for the cheatsheet.
---@return table[]
function M.list()
    local out = {}
    for _, name in ipairs(order) do
        local spec = modes[name]
        local keys = {}
        for _, key in ipairs(spec.keys) do
            local lhs = type(key[1]) == 'table' and key[1][1] or key[1]
            table.insert(keys, { lhs = lhs, desc = key.desc, leave = key.leave == true })
        end
        if spec.pass and #spec.pass > 0 then
            table.insert(keys, {
                lhs = table.concat(spec.pass, ' '),
                desc = 'Scroll; the mode stays',
                leave = false,
            })
        end
        table.insert(out, { name = name, desc = spec.desc, entry = spec.entry, keys = keys })
    end
    return out
end

local function echo_hint(spec)
    -- With no UI there is nobody to read it, and a headless run would print it
    -- into its own output with no newline.
    if #vim.api.nvim_list_uis() == 0 then
        return
    end
    local text = ('%s  %s  Esc leaves'):format(spec.name:upper(), spec.hint or '')
    local room = vim.o.columns - 12
    if vim.fn.strdisplaywidth(text) > room then
        text = vim.fn.strcharpart(text, 0, math.max(room, 1))
    end
    vim.api.nvim_echo({ { text, 'ModeMsg' } }, false, {})
end

-- Redrawing is a courtesy and must never be what ends a mode: a statusline
-- function that throws (a client with no name, a plugin mid-update) would
-- otherwise raise out of the loop and leave the mode "running" for good, with
-- every later entry refused as busy.
local function repaint()
    pcall(vim.cmd.redrawstatus)
    pcall(vim.cmd.redraw)
end

--- Run a mode until it ends, and say how it did.
---
--- `opts.getchar` replaces getcharstr for tests. Returns
--- `{ reason = ..., keys = n }` where reason is one of "escape", "timeout",
--- "interrupt", "error", "foreign" (a key that was not the mode's left it) or
--- "key" (a one-shot key did), and `next` names a mode to enter after this one
--- when a key asked for that.
---
--- However it ends -- a key that throws, something unexpected inside the loop
--- itself -- the clock is stopped and the mode is marked as no longer running
--- before anything is raised or returned.
---@param name string
---@param opts? { getchar?: fun(): string }
---@return { reason: string, keys: integer, next?: string }
function M.enter(name, opts)
    local spec = modes[name]
    assert(spec, 'no such mode: ' .. tostring(name))
    if active then
        return { reason = 'busy', keys = 0 }
    end
    opts = opts or {}

    local getchar = opts.getchar or vim.fn.getcharstr
    local synthetic = opts.getchar ~= nil
    local running, timed_out, last = true, false, now()
    local timer

    -- A scripted key source never blocks, so it needs neither the clock nor
    -- the keyboard buffer: the timer is only for the real thing.
    if not synthetic then
        timer = vim.uv.new_timer()
        local tick = math.max(20, math.min(250, math.floor(spec.idle / 3)))
        timer:start(tick, tick, function()
            if running and now() - last >= spec.idle then
                running, timed_out = false, true
                timer:stop()
                vim.api.nvim_input('<Esc>')
            end
        end)
    end

    active = spec
    local result = { reason = 'escape', keys = 0 }

    local function fail(problem)
        result.reason = 'error'
        vim.schedule(function()
            vim.notify(('%s mode: %s'):format(name, tostring(problem)), vim.log.levels.ERROR)
        end)
    end

    local function loop()
        if spec.on_enter then
            spec.on_enter()
        end
        repaint()
        echo_hint(spec)

        local digits = ''
        while true do
            local ok, char = pcall(getchar)
            last = now()
            if not ok then
                -- Ctrl-C raises, and is the user. Anything else was thrown by
                -- something that ran while the read was waiting (an event
                -- handler, a callback) and surfaced here; that is reported
                -- rather than taken for an interrupt.
                if tostring(char):find('Keyboard interrupt', 1, true) then
                    result.reason = 'interrupt'
                    return
                end
                return fail(char)
            end
            local key = vim.fn.keytrans(char)

            if char == '' or key == '<Esc>' then
                result.reason = timed_out and 'timeout' or 'escape'
                return
            end

            if key:match('^[1-9]$') or (key == '0' and digits ~= '') then
                digits = digits .. key
            else
                local entry = spec.map[key]
                if entry then
                    result.keys = result.keys + 1
                    local count = tonumber(digits) or 1
                    digits = ''
                    local fine, returned = pcall(entry.fn, count)
                    if not fine then
                        return fail(returned)
                    end
                    if type(returned) == 'table' and returned.switch then
                        result.reason, result.next = 'key', returned.switch
                        return
                    end
                    if entry.leave or returned == 'leave' then
                        result.reason = 'key'
                        return
                    end
                elseif spec.pass_map[key] then
                    -- Run as typed, and stay: a mode for reading has to let the
                    -- page move without ending.
                    local fine, problem = pcall(vim.cmd.normal, { digits .. char, bang = true })
                    digits = ''
                    if not fine then
                        return fail(problem)
                    end
                elseif spec.foreign == 'run' then
                    result.reason = 'foreign'
                    if not synthetic then
                        vim.api.nvim_feedkeys(digits .. char, 'mit', false)
                    else
                        result.replayed = digits .. char
                    end
                    return
                else
                    digits = ''
                end
            end
            repaint()
        end
    end

    local survived, unexpected = pcall(loop)

    running = false
    if timer then
        timer:stop()
        timer:close()
    end
    if spec.on_leave then
        pcall(spec.on_leave)
    end
    active = nil
    pcall(vim.api.nvim_echo, { { '' } }, false, {})
    repaint()

    if not survived then
        fail(unexpected)
    end

    if result.next then
        local follow = M.enter(result.next, opts)
        follow.previous = result
        return follow
    end
    return result
end

return M
