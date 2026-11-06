-- Language servers: which are enabled, and how C# is split between two of them.
--
-- What was found out about Roslyn here, so that it is not found out again.
--
-- External edits are seen. Neovim does not tell a server about files that change
-- on disk behind its back when it is on Linux (it advertises
-- workspace/didChangeWatchedFiles only on macOS and Windows, "since all the
-- current backends are too limited"), and the worry was that an agent's edit or
-- a `git checkout` of a file that is not open would leave Roslyn working from the
-- old text. It does not: a server that is not offered file watching by its client
-- does its own, and this one does. Measured against the real server by renaming
-- a method in a file nothing had opened -- the error it caused in a file that
-- uses it appeared about a second later, with no help from nvim. Nothing here
-- turns Neovim's watching on, and nothing should: its Linux backends walk every
-- directory, bin/ and obj/ included.
--
-- Whole-solution diagnostics are on (lspconfig's settings, `fullSolution`), but a
-- server only reports a file's diagnostics when asked, and `workspace/diagnostic`
-- reports only the files that are *closed*; the open ones come from the
-- per-document pull. Nothing here asks for the closed ones; the settings are left on
-- because it costs the server nothing to know.
--
-- The telemetry flag exists (`--telemetryLevel`, "all" by default) and is not set
-- here: no sink is configured outside VS Code's, so there is nothing to send to,
-- and changing what a server may report is not this file's decision.

-- LSP
vim.pack.add({ { src = "https://github.com/neovim/nvim-lspconfig" } })
vim.lsp.enable({ "lua_ls", "clangd", "denols", "html", "ts_ls", "roslyn_ls", "omnisharp" })

-- C# is served by two servers and the split is by file, not by project:
-- roslyn_ls for .cs in a real project, OmniSharp for project-less .csx
-- scripts, which roslyn refuses to load at all (see install.sh).
--
-- Both root_dir functions below exist to keep that split exact. Neither
-- server can be told apart by filetype -- nvim gives .csx the filetype `cs`
-- as well -- so the buffer name is the only signal, and with lspconfig's
-- defaults OmniSharp's root pattern (*.sln, *.csproj) matched every ordinary
-- .cs file and started it next to roslyn_ls: two sets of diagnostics, two
-- completion sources, two project loads. A root_dir that returns without
-- calling `on_dir` is how a vim.lsp.config declines to start for a buffer.
local function is_csx(bufnr)
    return vim.api.nvim_buf_get_name(bufnr):match('%.csx$') ~= nil
end

-- Library code, and why it needs a root_dir of its own.
--
-- Go to definition on something from the framework or a package does not fail:
-- Roslyn decompiles the type (ICSharpCode.Decompiler, a thousand lines for
-- System.Console) into a file under <tmp>/MetadataAsSource/<guid>/ and sends
-- its path. That file is an ordinary buffer of filetype `cs`, and with the
-- root_dir this config had it got no language server at all: it lies outside any
-- solution, so the search for one found nothing and declined -- no hover, no
-- usages, no go to definition from inside it, which is exactly where you want
-- to keep following a call. lspconfig declines on purpose (its comment says
-- "don't try to find sln or csproj for files from libraries"), which is right
-- for a lookup that would find some unrelated project, and wrong for a file that
-- belongs to the project that produced it.
--
-- So for those paths the root is the running server's own, which attaches the
-- same client rather than starting another. The client that is used is the one
-- the buffer was jumped from -- the alternate buffer, which is still the previous
-- one when this runs -- and failing that the first Roslyn client, which is the
-- only one in the usual case of one solution per editor. The directory is
-- <TMPDIR>/MetadataAsSource: the server asks .NET for the temp path, and .NET
-- reads TMPDIR, which the server inherits from here. /tmp is also checked, as
-- lspconfig does.
local function metadata_dirs()
    local dirs = { '/tmp/MetadataAsSource' }
    local tmp = os.getenv('TMPDIR')
    if tmp and tmp ~= '' then
        table.insert(dirs, vim.fs.joinpath(vim.fs.normalize(tmp), 'MetadataAsSource'))
    end
    return dirs
end

-- Library code. Generated code is not here: it is not a file, so it never gets
-- as far as asking for a root (see ide.csharp, which attaches it itself).
local function is_server_document(name)
    for _, dir in ipairs(metadata_dirs()) do
        if vim.startswith(name, dir .. '/') then
            return true
        end
    end
    return false
end

local function running_root(bufnr)
    local previous = vim.fn.bufnr('#')
    local candidates = {}
    if previous > 0 and previous ~= bufnr then
        vim.list_extend(candidates, vim.lsp.get_clients({ bufnr = previous, name = 'roslyn_ls' }))
    end
    vim.list_extend(candidates, vim.lsp.get_clients({ name = 'roslyn_ls' }))
    local client = candidates[1]
    return client and client.config.root_dir or nil
end

-- What the references code lens runs when it is chosen. Roslyn does not send the
-- places, only where the lens is: `arguments` is the document's URI and the
-- position of the member, and the client is expected to look the references up
-- itself (VS Code opens its peek window on them). The count in the lens does not
-- include the declaration, so neither does this. The results go where every
-- other lookup's do, through ide.lists. Required inside the function: ide.lists
-- is loaded after this file.
local function peek_references(command, ctx)
    local uri, position = command.arguments[1], command.arguments[2]
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if not (client and uri and position) then
        return
    end
    local buf = vim.uri_to_bufnr(uri)
    vim.fn.bufload(buf)
    local line = vim.api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1] or ''
    local word = line:sub(position.character + 1):match('^[%w_]+') or line:sub(position.character + 1):match('[%w_]+') or '?'

    local lists = require('ide.lists')
    local where = lists.here()
    client:request('textDocument/references', {
        textDocument = { uri = uri },
        position = position,
        context = { includeDeclaration = false },
    }, function(err, result)
        if err then
            return vim.notify('References: ' .. (err.message or 'the server failed'), vim.log.levels.WARN)
        end
        local items = vim.lsp.util.locations_to_items(result or {}, client.offset_encoding)
        if #items == 0 then
            return vim.notify('No references to ' .. word)
        end
        lists.present(items, { title = 'References: ' .. word, where = where })
    end, ctx.bufnr)
end

vim.lsp.config('roslyn_ls', {
    root_dir = function(bufnr, on_dir)
        if is_csx(bufnr) then
            return
        end
        if is_server_document(vim.api.nvim_buf_get_name(bufnr)) then
            local root = running_root(bufnr)
            if root then
                on_dir(root)
            end
            return
        end
        local root = vim.fs.root(bufnr, function(name)
            return name:match('%.slnx?$') ~= nil
        end) or vim.fs.root(bufnr, function(name)
            return name:match('%.csproj$') ~= nil
        end)
        if root then
            on_dir(root)
        end
    end,
    handlers = {
        ['workspace/projectInitializationComplete'] = function(_, _, ctx)
            local client = vim.lsp.get_client_by_id(ctx.client_id)
            if not client then
                return vim.NIL
            end
            local buffers = vim.tbl_keys(client.attached_buffers)
            vim.schedule(function()
                for _, buf in ipairs(buffers) do
                    if vim.api.nvim_buf_is_loaded(buf) then
                        vim.lsp.buf_detach_client(buf, client.id)
                        vim.lsp.buf_attach_client(buf, client.id)
                    end
                end
            end)
            return vim.NIL
        end,
    },
    cmd = {
        'roslyn-language-server',
        '--logLevel',
        'Information',
        '--extensionLogDirectory',
        vim.fs.joinpath(os.getenv('TMPDIR') or '/tmp', 'roslyn_ls/logs'),
        '--stdio',
    },
    -- Merged with lspconfig's own, which already has completionComplexEdit,
    -- nestedCodeAction and fixAllCodeAction.
    commands = {
        ['roslyn.client.peekReferences'] = peek_references,
    },
    -- Merged with lspconfig's settings too (full-solution diagnostics, inlay hints,
    -- the references lens, symbol search in the reference assemblies).
    --
    -- The tests lens is off. It puts "Run Test | Debug Test" above every test and
    -- both run `dotnet.test.run`, a command only a client that starts the test
    -- run itself can answer -- here that is :Test, which does it without a lens.
    -- Left on, turning code lenses on (:Toggle lens) would show two lenses per
    -- test that do nothing when chosen.
    settings = {
        ['csharp|code_lens'] = {
            dotnet_enable_tests_code_lens = false,
        },
    },
})

-- The script's own directory is the right root for a .csx: it has no project
-- to find, and rooting at an enclosing solution would hand OmniSharp the very
-- workspace roslyn_ls is already loading.
vim.lsp.config('omnisharp', {
    root_dir = function(bufnr, on_dir)
        if not is_csx(bufnr) then
            return
        end
        on_dir(vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)))
    end,
})

-- A server that is stuck, or that was started before the project was ready, is
-- fixed by restarting it, and finding out what it is doing is :checkhealth. These
-- are palette entries rather than keys because they are used a few times a month
-- and need to be found when they are, not remembered.
local registry = require('ide.registry')
registry.action('Restart the language server', function()
    vim.cmd('lsp restart')
end, 'for the buffer you are in; a stuck project load, a server that stopped answering')
registry.action('Language server status', function()
    vim.cmd('checkhealth vim.lsp')
end, 'which servers are attached, what they support, whether file watching is on')
registry.action('Language server log', function()
    vim.cmd.edit(vim.lsp.log.get_filename())
end, 'what the servers said; Roslyn\'s own is in <tmp>/roslyn_ls/logs')
