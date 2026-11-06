-- C# beyond what the language server does on its own: documents the server makes
-- up (library code, generated code), the `///` that expands into a documentation
-- comment, and removing the usings nothing needs.
--
-- Where a document comes from, because three kinds are in play and they are not
-- the same:
--
--   a file in the solution       the ordinary case; ide.lsp finds its project
--   library code                 decompiled by the server into a file under
--                                <tmp>/MetadataAsSource; a real file on disk, so
--                                it opens like any other, and ide.lsp's root_dir
--                                attaches the running server to it
--   generated code               a source generator's output, which has no file
--                                at all: the server sends a `roslyn-source-generated://`
--                                URI and keeps the text itself, to be asked for
--
-- Library code is made read-only. It is a temporary file that the server wrote
-- and will write again; an edit to it is lost, and, worse, autosave writes a
-- buffer when focus leaves it and the formatter runs on write, so without this
-- looking at the framework rewrote a file under /tmp every time you looked away.
-- `nomodifiable` is what both of those already check.

local group = require('ide.group')
local registry = require('ide.registry')

local M = {}

----------------------------------------------------------------------------
-- Library code
----------------------------------------------------------------------------

vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = '*/MetadataAsSource/*',
    callback = function(args)
        vim.bo[args.buf].modifiable = false
        vim.bo[args.buf].readonly = true
    end,
})

----------------------------------------------------------------------------
-- Generated code
----------------------------------------------------------------------------

local GENERATED = 'roslyn-source-generated://*'

local function server_for(buf)
    local previous = vim.fn.bufnr('#')
    local candidates = {}
    if previous > 0 and previous ~= buf then
        vim.list_extend(candidates, vim.lsp.get_clients({ bufnr = previous, name = 'roslyn_ls' }))
    end
    vim.list_extend(candidates, vim.lsp.get_clients({ name = 'roslyn_ls' }))
    return candidates[1]
end

-- The text of a generated document, or nil and why. A server's `null` arrives as
-- nil or as vim.NIL depending on where in the answer it was, so what is checked
-- for is the thing wanted, a string, and not for either of those.
local function fetch_generated(client, uri, buf)
    local response, err = client:request_sync('workspace/textDocumentContent', { uri = uri }, 8000, buf)
    if not response then
        return nil, tostring(err or 'no answer from the server')
    elseif response.err then
        return nil, response.err.message or 'the server failed'
    end
    local result = response.result
    if type(result) ~= 'table' or type(result.text) ~= 'string' then
        return nil, 'the server has no text for it'
    end
    return result.text
end

-- Put the server's text in the buffer so that what Neovim sends back is that text
-- to the byte.
--
-- It is sent back: attaching the server to the buffer is a textDocument/didOpen
-- with the buffer's text, and while Roslyn holds a document open it works from
-- what it was told, not from what it generated. If the two differ -- by one
-- trailing newline is enough -- it still answers references, implementations and
-- highlights, but the call hierarchy comes back empty, for every method in the
-- solution and not only for the generated one, until the buffer is closed. Found
-- by asking the real server: callers of an ordinary method went from one to none
-- the moment this buffer was opened, and came back when it was wiped, and a fake
-- server cannot show any of it.
--
-- So the text is taken apart the way Neovim puts it together. A buffer is lines;
-- the text sent is those lines joined, plus a line ending after the last one when
-- 'endofline' is set, and the line ending is the 'fileformat''s. Splitting on
-- every newline leaves an empty last line when the text ends with one, which
-- Neovim then adds a newline after: the extra byte. Taken off, with 'eol' set to
-- say it was there, the two are the same. Text that does not end in a newline gets
-- 'noeol', and text whose newlines are all CRLF gets the dos format. Mixed line
-- endings cannot be put back exactly; a generator that writes them is not known.
--
-- 'fileformat' cannot be changed in a buffer that is not modifiable, so the
-- options are set before it is made one.
local function put_text(buf, text)
    local crlf = text:find('\r\n', 1, true) ~= nil and not text:find('[^\r]\n')
    local body = crlf and text:gsub('\r\n', '\n') or text
    local ends_with_newline = body:sub(-1) == '\n'
    if ends_with_newline then
        body = body:sub(1, -2)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, '\n', { plain = true }))
    vim.bo[buf].eol = ends_with_newline
    vim.bo[buf].fileformat = crlf and 'dos' or 'unix'
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

-- Filled on :edit, which is where a jump to a location ends up. Synchronous, and
-- that is not a choice: the jump sets the cursor on the next line, and a buffer
-- filled a moment later has no such line yet. 8 seconds is the longest anything
-- waits on a server in this config; a generator's output is already in memory
-- there and comes back in milliseconds.
--
-- The server is attached by hand, after the text is in. `vim.lsp.enable`, which
-- is what attaches a server when a filetype is set, only ever attaches to buffers
-- that are files (`buftype` empty) -- by design, and this buffer is a `nofile`
-- one, which it has to be, as there is nothing to write it to. So setting the
-- filetype colours it and does nothing else, and without the attach there is no
-- hover and no go to definition from inside generated code.
vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = GENERATED,
    callback = function(args)
        local buf = args.buf
        local client = server_for(buf)
        if not client then
            vim.bo[buf].modifiable = false
            return vim.notify('No language server to ask for ' .. args.match, vim.log.levels.WARN)
        end
        local text, err = fetch_generated(client, args.match, buf)
        vim.bo[buf].buftype = 'nofile'
        vim.bo[buf].swapfile = false
        if not text then
            vim.bo[buf].modifiable = true
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// ' .. err })
            vim.bo[buf].modifiable = false
            return vim.notify('Generated code: ' .. err, vim.log.levels.WARN)
        end
        put_text(buf, text)
        vim.bo[buf].filetype = 'cs'
        vim.lsp.buf_attach_client(buf, client.id)
    end,
})

-- A generator that runs again -- a file it reads changed -- makes the server say
-- so; the open generated buffers are read again.
vim.lsp.config('roslyn_ls', {
    handlers = {
        ['workspace/textDocumentContent/refresh'] = function(_, params, ctx)
            vim.schedule(function()
                local client = vim.lsp.get_client_by_id(ctx.client_id)
                for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    local name = vim.api.nvim_buf_get_name(buf)
                    if client and vim.api.nvim_buf_is_loaded(buf) and vim.startswith(name, 'roslyn-source-generated://')
                        and (params == nil or params.uri == nil or params.uri == name) then
                        local text = fetch_generated(client, name, buf)
                        if text then
                            put_text(buf, text)
                        end
                    end
                end
            end)
            return vim.NIL
        end,
    },
})

----------------------------------------------------------------------------
-- Usings
----------------------------------------------------------------------------

-- Roslyn has no "organize imports" code action: its kinds are quickfix and
-- refactor only. What it does have is a quickfix on a `using` line,
-- "Remove unnecessary usings", offered when there is anything to remove; that is
-- what Rider's optimise does first, and is the half of it that matters. Sorting is
-- a formatting setting (`dotnet_organize_imports_on_format`) that sorts on every
-- write when on, which is not wanted: it rewrites the top of files in repositories
-- that are somebody else's, and a diff against them is what review is for.
--
-- The action is asked for on the first using in the file. The line has to be
-- found, because the request is for a place: with the cursor anywhere else the
-- server offers something else, or nothing. A `using` that is a statement
-- (`using var x = ...`, `using (...)`) is not one, and is skipped.
local USING = {
    '^%s*using%s+static%s+[%w_.]+%s*;',
    '^%s*using%s+[%w_.]+%s*;',
    '^%s*using%s+[%w_]+%s*=%s*[^;]+;',
}

local function first_using(lines)
    for index, line in ipairs(lines) do
        local text = line:gsub('^%s*global%s+', '')
        for _, pattern in ipairs(USING) do
            if text:match(pattern) then
                return index, line
            end
        end
    end
end

local TITLE = 'Remove unnecessary usings'

--- Remove the usings the compiler says nothing uses.
function M.usings()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local row, line = first_using(lines)
    if not row then
        return vim.notify('No using directives in this file', vim.log.levels.INFO)
    end
    vim.lsp.buf.code_action({
        -- Exactly this title: "Fix All: Remove unnecessary usings" is offered
        -- beside it, and is for the whole project.
        filter = function(action)
            return action.title == TITLE
        end,
        apply = true,
        range = { start = { row, 0 }, ['end'] = { row, #line } },
    })
end

registry.command('Usings', M.usings, {
    desc = 'Remove the using directives nothing in this file needs',
})

----------------------------------------------------------------------------
-- ///
----------------------------------------------------------------------------

-- Typing the third slash of `///` above a member should write the documentation
-- comment: `<summary>`, a `<param>` for each parameter, `<returns>`, with the
-- cursor inside the summary. Roslyn can do it -- it advertises
-- `_vs_onAutoInsert` -- but that is a Visual Studio extension that Neovim's
-- client never calls, so it is asked for here, when the third slash is typed.
--
-- The answer is a text edit whose `newText` has `$0` where the cursor goes. It is
-- applied as plain text, with the marker taken out and the cursor put there by
-- hand, and not through vim.snippet: the server has already written the
-- indentation of every line it returns, and vim.snippet indents multi-line
-- snippets again, which put each added line one level too deep.
--
-- Dropped if the buffer changed while the server was working, because the edit's
-- range is positions in the text as it was when asked: typing on past the slashes
-- would apply it in the wrong place.
local AUTO_INSERT = 'textDocument/_vs_onAutoInsert'

local function byte_to_encoded(line, col, encoding)
    local ok, index = pcall(vim.str_utfindex, line, encoding, col, false)
    return ok and index or col
end

local function encoded_to_byte(line, character, encoding)
    local ok, index = pcall(vim.str_byteindex, line, encoding, character, false)
    return ok and index or math.min(character, #line)
end

local function apply_doc_edit(client, buf, edit)
    local encoding = client.offset_encoding or 'utf-16'
    local body = (edit.newText or ''):gsub('\r\n', '\n')
    local caret = body:find('$0', 1, true)
    local before = caret and body:sub(1, caret - 1) or body
    edit.newText = caret and (before .. body:sub(caret + 2)) or body

    local start = edit.range.start
    local start_line = vim.api.nvim_buf_get_lines(buf, start.line, start.line + 1, false)[1] or ''
    local start_byte = encoded_to_byte(start_line, start.character, encoding)

    vim.lsp.util.apply_text_edits({ edit }, buf, encoding)

    if caret then
        local newlines = select(2, before:gsub('\n', ''))
        local last = before:match('[^\n]*$') or ''
        local row = start.line + newlines + 1
        local col = newlines == 0 and (start_byte + #last) or #last
        vim.api.nvim_win_set_cursor(0, { row, col })
    end
end

local function expand_doc_comment(client, buf)
    if vim.api.nvim_get_current_buf() ~= buf then
        return
    end
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    -- Three slashes and nothing else on the line, and nothing after them: typing
    -- `///` inside a comment that has words in it is not asking for a stub.
    if not line:sub(1, col):match('^%s*///$') or line:sub(col + 1):match('%S') then
        return
    end

    local tick = vim.b[buf].changedtick
    client:request(AUTO_INSERT, {
        _vs_textDocument = { uri = vim.uri_from_bufnr(buf) },
        _vs_position = { line = row - 1, character = byte_to_encoded(line, col, client.offset_encoding or 'utf-16') },
        _vs_ch = '/',
        _vs_options = {
            tabSize = vim.bo[buf].shiftwidth ~= 0 and vim.bo[buf].shiftwidth or vim.bo[buf].tabstop,
            insertSpaces = vim.bo[buf].expandtab,
        },
    }, function(err, result)
        if err or not (result and result._vs_textEdit) then
            return
        end
        if vim.b[buf].changedtick ~= tick or vim.api.nvim_get_current_buf() ~= buf then
            return
        end
        apply_doc_edit(client, buf, result._vs_textEdit)
    end, buf)
end

M.expand_doc_comment = expand_doc_comment

-- One handler for a buffer, and the client is chosen when the slash is typed.
-- It was once one per buffer and client, which left the old client's handler
-- behind every time a server was restarted, each asking its own dead client; the
-- group for the buffer is made again on every attach, so there is only ever one.
local function docs_client(buf)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        if client.server_capabilities._vs_onAutoInsertProvider then
            return client
        end
    end
end

vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if not (client and client.server_capabilities._vs_onAutoInsertProvider) then
            return
        end
        local buf = args.buf
        local local_group = vim.api.nvim_create_augroup('ide.docs.' .. buf, { clear = true })
        vim.api.nvim_create_autocmd('InsertCharPre', {
            group = local_group,
            buffer = buf,
            callback = function()
                if vim.v.char ~= '/' then
                    return
                end
                -- After the character is in the line: at InsertCharPre it is not.
                vim.schedule(function()
                    local current = vim.api.nvim_buf_is_valid(buf) and docs_client(buf)
                    if current then
                        expand_doc_comment(current, buf)
                    end
                end)
            end,
        })
    end,
})

return M
