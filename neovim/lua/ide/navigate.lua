-- Going somewhere with the language server: definition, usages, implementations,
-- the type of a thing, who calls it, what it calls, what it derives from.
--
-- Every one ends in ide.lists.present: a single result is jumped to, several are
-- looked at in the picker (drop the noise, send what is left to a list). That is
-- the whole point of this file, and it is why these are not just the default
-- `vim.lsp.buf` functions bound to keys. The defaults put every result in the
-- quickfix list and open it, which is what made an LSP lookup in the middle of a
-- review bury the review's list -- see lists.lua for the other half of that.
--
-- The keys are Neovim's own vocabulary and are kept: `grr` usages, `gri`
-- implementations, `grt` the type, `gd` the definition. Only where the results
-- go has changed. The hierarchies have no default key, so they are on the same
-- `gr` prefix, with the letter for the question:
--
--   grb   base types: what this derives from
--   grc   callers: who calls this
--   grC   callees: what this calls (shift widens: the other direction)
--
-- `gd` is not bound everywhere. Without a language server it is Vim's own `gd`,
-- a textual search for the first occurrence of the word, which is the right thing
-- to do in a text file and a shell script; binding it globally would take that
-- away for the sake of buffers that have a server. It is bound in a buffer when
-- a server that can answer attaches, on LspAttach. The `gr` keys are Neovim's own
-- global defaults, which fail with a message when nothing is attached, so
-- rebinding those globally loses nothing.
--
-- The lookups that Neovim has an `on_list` hook for use it; those without one
-- (the hierarchies) make their own requests, in two steps -- prepare, which says
-- what is under the cursor, then the question about it -- and ask which one when
-- there is more than one, through vim.ui.select, which mini.pick has taken over.
--
-- The tag stack is pushed for every jump, so <C-t> comes back from any of them,
-- as it does for Neovim's own go-to-definition.

local lists = require('ide.lists')
local group = require('ide.group')

local M = {}

local function trim(text)
    return ((text or ''):gsub('[\r\n\t]+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function say(text, level)
    vim.notify(text, level or vim.log.levels.INFO)
end

----------------------------------------------------------------------------
-- Lookups Neovim has a hook for
----------------------------------------------------------------------------

local function via_hook(label, call)
    return function()
        local where = lists.here()
        local title = ('%s: %s'):format(label, where.tagname ~= '' and where.tagname or '?')
        call({
            on_list = function(list)
                lists.present(list.items, { title = title, where = where })
            end,
        })
    end
end

M.definition = via_hook('Definitions', function(opts) vim.lsp.buf.definition(opts) end)
M.implementation = via_hook('Implementations', function(opts) vim.lsp.buf.implementation(opts) end)
M.type_definition = via_hook('Type of', function(opts) vim.lsp.buf.type_definition(opts) end)
M.references = via_hook('References', function(opts) vim.lsp.buf.references(nil, opts) end)

----------------------------------------------------------------------------
-- Hierarchies
----------------------------------------------------------------------------

local KINDS = {
    callers = {
        prepare = 'textDocument/prepareCallHierarchy',
        method = 'callHierarchy/incomingCalls',
        label = 'Callers',
        what = 'call hierarchy',
    },
    callees = {
        prepare = 'textDocument/prepareCallHierarchy',
        method = 'callHierarchy/outgoingCalls',
        label = 'Callees',
        what = 'call hierarchy',
    },
    supertypes = {
        prepare = 'textDocument/prepareTypeHierarchy',
        method = 'typeHierarchy/supertypes',
        label = 'Base types',
        what = 'type hierarchy',
    },
    subtypes = {
        prepare = 'textDocument/prepareTypeHierarchy',
        method = 'typeHierarchy/subtypes',
        label = 'Derived types',
        what = 'type hierarchy',
    },
}

-- The text of an entry becomes "<name>  │  <what is on that line>": the name
-- is who calls or what is called, which the line alone does not say.
local function named(entries, name)
    for _, entry in ipairs(entries) do
        entry.text = ('%s  │  %s'):format(name, trim(entry.text))
    end
    return entries
end

-- A call hierarchy answer as quickfix entries. The ranges are where the calls
-- are: in the caller, for incoming calls, and in the item that was asked about,
-- for outgoing ones -- the callee is named by `to` but is not where the call
-- happens.
local function call_entries(kind, result, root, encoding)
    local entries = {}
    for _, call in ipairs(result or {}) do
        local side, uri, name
        if kind == 'callers' then
            side, uri = call.from, call.from.uri
        else
            side, uri = call.to, root.uri
        end
        name = side.name
        local places = {}
        for _, range in ipairs(call.fromRanges or {}) do
            table.insert(places, { uri = uri, range = range })
        end
        if #places == 0 then
            table.insert(places, { uri = side.uri, range = side.selectionRange or side.range })
        end
        vim.list_extend(entries, named(vim.lsp.util.locations_to_items(places, encoding), name))
    end
    -- One call at a time was converted, so the entries are in the order the
    -- server listed the calls. Neovim's conversion orders a *set* of places by
    -- file and position, and a list of call sites reads best that way: the
    -- calls in the order they are in the code. The index breaks ties, because
    -- table.sort is not stable.
    local order = {}
    for i, entry in ipairs(entries) do
        order[entry] = i
    end
    table.sort(entries, function(a, b)
        if a.filename ~= b.filename then
            return a.filename < b.filename
        elseif a.lnum ~= b.lnum then
            return a.lnum < b.lnum
        elseif a.col ~= b.col then
            return a.col < b.col
        end
        return order[a] < order[b]
    end)
    return entries
end

local function type_entries(result, encoding)
    local entries = {}
    for _, item in ipairs(result or {}) do
        local place = { uri = item.uri, range = item.selectionRange or item.range }
        local name = item.detail and item.detail ~= '' and ('%s %s'):format(item.name, item.detail) or item.name
        vim.list_extend(entries, named(vim.lsp.util.locations_to_items({ place }, encoding), name))
    end
    return entries
end

local function hierarchy(kind)
    local spec = KINDS[kind]
    return function()
        local where = lists.here()
        local buf = vim.api.nvim_get_current_buf()
        local clients = vim.lsp.get_clients({ bufnr = buf, method = spec.prepare })
        if #clients == 0 then
            return say(('No language server here supports the %s'):format(spec.what), vim.log.levels.WARN)
        end
        local title = ('%s: %s'):format(spec.label, where.tagname ~= '' and where.tagname or '?')

        local function follow(root)
            local client = vim.lsp.get_client_by_id(root.client_id)
            if not client then
                return
            end
            client:request(spec.method, { item = root.item }, function(err, result)
                if err then
                    return say(('%s: %s'):format(spec.label, err.message or 'the server failed'), vim.log.levels.WARN)
                end
                local entries
                if spec.what == 'call hierarchy' then
                    entries = call_entries(kind, result, root.item, client.offset_encoding)
                else
                    entries = type_entries(result, client.offset_encoding)
                end
                if #entries == 0 then
                    return say('Nothing found: ' .. title)
                end
                lists.present(entries, { title = title, where = where })
            end, buf)
        end

        vim.lsp.buf_request_all(buf, spec.prepare, function(client)
            return vim.lsp.util.make_position_params(where.win, client.offset_encoding)
        end, function(results)
            local roots = {}
            for client_id, res in pairs(results) do
                if res.err then
                    say(res.err.message or 'the server failed', vim.log.levels.WARN)
                elseif res.result then
                    for _, item in ipairs(res.result) do
                        table.insert(roots, { client_id = client_id, item = item })
                    end
                end
            end
            if #roots == 0 then
                return say('Nothing under the cursor has a ' .. spec.what)
            elseif #roots == 1 then
                return follow(roots[1])
            end
            vim.ui.select(roots, {
                prompt = ('Which one (%s)?'):format(spec.what),
                format_item = function(root)
                    local detail = root.item.detail
                    return detail and detail ~= '' and ('%s  %s'):format(root.item.name, detail) or root.item.name
                end,
            }, function(root)
                if root then
                    follow(root)
                end
            end)
        end)
    end
end

M.base_types = hierarchy('supertypes')
M.derived_types = hierarchy('subtypes')
M.callers = hierarchy('callers')
M.callees = hierarchy('callees')

----------------------------------------------------------------------------
-- gd, where there is something to ask
----------------------------------------------------------------------------

vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client:supports_method('textDocument/definition', args.buf) then
            vim.keymap.set('n', 'gd', M.definition, {
                buffer = args.buf,
                desc = 'Go to the definition: one result jumps, several are picked from',
            })
        end
    end,
})

return M
