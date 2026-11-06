-- The small assertion library the Neovim tests share. It prints in the same
-- shape as the other harnesses here, and exits non-zero from finish() when
-- anything failed, because a Lua error inside `nvim -c` would otherwise only be
-- printed and the process would go on to exit with 0.

local M = { pass = 0, fail = 0 }

-- A test that waits for something that never comes -- a picker reading keys
-- nobody is typing, say -- would otherwise sit until the driver's timeout, saying
-- nothing about where. A timer is not stopped by a blocked key read, so it can
-- name the scenario that was running and end the process.
local current_section = '(before the first scenario)'
local budget_ms = (tonumber(os.getenv('NVIM_TEST_BUDGET')) or 150) * 1000
local watchdog = vim.uv.new_timer()
watchdog:start(budget_ms, 0, function()
    io.stdout:write(('\n  FAIL timed out after %d s, in: %s\n'):format(budget_ms / 1000, current_section))
    io.stdout:flush()
    os.exit(3)
end)
watchdog:unref()

local function out(line)
    io.stdout:write(line, "\n")
end

function M.section(title)
    current_section = title
    out('scenario: ' .. title)
end

local function show(value)
    if type(value) == 'string' then
        return value
    end
    return vim.inspect(value, { newline = ' ', indent = '' })
end

--- Compare with vim.deep_equal, so tables work too.
function M.check(label, got, want)
    if vim.deep_equal(got, want) then
        M.pass = M.pass + 1
        out(('  ok   %-62s %s'):format(label, show(got)))
    else
        M.fail = M.fail + 1
        out(('  FAIL %-62s got %s want %s'):format(label, show(got), show(want)))
    end
end

--- For a condition that has no single value to compare against.
function M.ok(label, condition, detail)
    M.check(label, condition and true or false, true)
    if not condition and detail then
        out('       ' .. show(detail))
    end
end

--- Wait for a condition while the event loop runs; false on timeout.
function M.wait(ms, condition)
    return vim.wait(ms, condition, 10)
end

--- A language server written in Lua, for tests that need an LSP answer without
--- a real server: it says what it can do (`capabilities`) and answers each
--- request from `responses`, a table of method -> value, or function(params) ->
--- value. Everything it is asked is recorded in `requests`.
---
--- Neovim accepts a function as a server's `cmd` and talks to what it returns as
--- it would to a process, which is how this works. Replies are scheduled: a
--- request that is answered before it has returned its id is not one Neovim
--- expects.
---@param opts { name?: string, capabilities: table, responses?: table, root_dir?: string, commands?: table<string, function>, delays?: table<string, integer> }
function M.fake_server(opts)
    local server = { requests = {}, notifications = {}, name = opts.name or 'fake_ls' }
    local responses = opts.responses or {}

    local function cmd(dispatchers)
        local closing = false
        local id = 0
        -- A server process that ends says so, and Neovim only forgets the client
        -- when told: without this a stopped client stays registered and goes on
        -- being asked, which no real server does.
        local function exited()
            if closing then
                return
            end
            closing = true
            vim.schedule(function()
                dispatchers.on_exit(0, 0)
            end)
        end
        return {
            request = function(method, params, callback)
                id = id + 1
                table.insert(server.requests, { method = method, params = params })
                local wait = (opts.delays or {})[method]
                local later = wait and function(fn) vim.defer_fn(fn, wait) end or vim.schedule
                later(function()
                    if method == 'initialize' then
                        return callback(nil, { capabilities = opts.capabilities })
                    elseif method == 'shutdown' then
                        return callback(nil, nil)
                    end
                    local answer = responses[method]
                    if type(answer) == 'function' then
                        answer = answer(params)
                    end
                    if type(answer) == 'table' and answer.error then
                        return callback({ code = -32603, message = answer.error }, nil)
                    end
                    -- JSON null is nil by the time a client sees a result (the RPC
                    -- layer decodes with luanil), not vim.NIL, and code written for
                    -- one that sees the other is code for a server that does not exist.
                    callback(nil, answer)
                end)
                return true, id
            end,
            notify = function(method, params)
                table.insert(server.notifications, { method = method, params = params })
                if method == 'exit' then
                    exited()
                end
                return true
            end,
            is_closing = function()
                return closing
            end,
            terminate = function()
                exited()
            end,
        }
    end

    -- For pointing a real config at this server (vim.lsp.config(name, { cmd = server.cmd })),
    -- so that nothing in a test can start the real language server.
    server.cmd = cmd

    --- Start it for a buffer, and wait until it has attached.
    ---@param buf integer
    ---@return vim.lsp.Client?
    function server.attach(buf)
        local client_id = vim.lsp.start({
            name = server.name,
            cmd = cmd,
            root_dir = opts.root_dir or vim.fn.getcwd(),
            commands = opts.commands,
        }, { bufnr = buf })
        local ok = vim.wait(5000, function()
            local client = client_id and vim.lsp.get_client_by_id(client_id)
            return client ~= nil and client.initialized and vim.lsp.buf_is_attached(buf, client_id)
        end, 10)
        return ok and vim.lsp.get_client_by_id(client_id) or nil
    end

    --- Stop every client of this server and wait until Neovim has forgotten it.
    function server.stop()
        local ids = {}
        for _, client in ipairs(vim.lsp.get_clients({ name = server.name })) do
            table.insert(ids, client.id)
            client:stop(true)
        end
        vim.wait(3000, function()
            for _, client_id in ipairs(ids) do
                if vim.lsp.get_client_by_id(client_id) then
                    return false
                end
            end
            return true
        end, 10)
    end

    --- The recorded requests for one method.
    ---@param method string
    ---@return table[]
    function server.asked(method)
        return vim.tbl_filter(function(request)
            return request.method == method
        end, server.requests)
    end

    return server
end

--- Run `steps` against the picker once it is open and has items: a string is
--- typed, a function is called, one at a time with a pause between, because the
--- picker reads keys in a loop of its own and acts on each as it arrives. Start
--- the thing that opens the picker *after* calling this, and wait for it to
--- finish: the picker blocks whatever called it, and the steps run from timers
--- while it does.
---@param steps (string|function)[]
---@param gap? integer  milliseconds between steps
function M.picker_script(steps, gap)
    gap = gap or 60
    local function run(i)
        local step = steps[i]
        if step == nil then
            return
        end
        if type(step) == 'function' then
            local ok, err = pcall(step)
            if not ok then
                M.fail = M.fail + 1
                io.stdout:write('  FAIL (a step raised) ' .. tostring(err) .. '\n')
            end
        else
            vim.api.nvim_input(step)
        end
        vim.defer_fn(function() run(i + 1) end, gap)
    end
    local function poll()
        local pick = _G.MiniPick
        if pick and pick.is_picker_active() and #(pick.get_picker_items() or {}) > 0 then
            return run(1)
        end
        vim.defer_fn(poll, 20)
    end
    vim.defer_fn(poll, 20)
end

----------------------------------------------------------------------------
-- Tests that need the real main loop
----------------------------------------------------------------------------
--
-- Insert mode, the completion menu and anything that reacts to typed keys one at
-- a time only exist while Neovim is sitting in its main loop waiting for input;
-- a script that is itself running inside a handler never gives it the chance
-- (feedkeys with 'x' runs keys as :normal does, and ends Insert mode when they
-- run out). So these tests are a coroutine, run from timers while the editor
-- idles in its loop, and `keys` types into that loop with nvim_input. The run
-- file must not quit after the script returns -- test_nvim.sh does not -- and
-- ends itself with finish().

local running

--- Run `fn` as a coroutine inside the main loop; finish() is called when it
--- returns, and a test that raises is counted as a failure rather than hanging.
---@param fn function
function M.async(fn)
    local co = coroutine.create(fn)
    running = co
    local function resume()
        local ok, err = coroutine.resume(co)
        if not ok then
            M.fail = M.fail + 1
            out('  FAIL (the test raised) ' .. tostring(err))
            M.finish()
        elseif coroutine.status(co) == 'dead' then
            M.finish()
        end
    end
    M._resume = resume
    vim.schedule(resume)
end

--- Let the editor run for a while: keys are handled, timers fire, replies arrive.
---@param ms integer
function M.sleep(ms)
    local resume = M._resume
    vim.defer_fn(resume, ms)
    coroutine.yield()
end

--- Type keys (<C-y>, <Esc> and so on are written as in a mapping) and give the
--- loop a moment to act on them.
---@param keys string
---@param settle? integer
function M.keys(keys, settle)
    vim.api.nvim_input(keys)
    M.sleep(settle or 40)
end

--- Wait for a condition, running the editor meanwhile. True if it came true.
---@param ms integer
---@param condition fun(): boolean
function M.until_true(ms, condition)
    local waited = 0
    while waited < ms do
        if condition() then
            return true
        end
        M.sleep(10)
        waited = waited + 10
    end
    return condition()
end

function M.finish()
    out('')
    out(('%d passed, %d failed'):format(M.pass, M.fail))
    io.stdout:flush()
    io.stderr:flush()
    os.exit(M.fail == 0 and 0 or 1)
end

return M
