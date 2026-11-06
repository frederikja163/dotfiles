-- Parsers and tree-sitter highlighting, from nvim-treesitter's `main` branch.
--
-- This used to track the plugin's `master`, which is archived and was the cause
-- of a bug that looked like a markdown problem. master defines its own
-- `#set-lang-from-info-string!` directive for markdown's injections, and that
-- directive reads a capture as one node where Neovim 0.12 hands it a list.
-- Every markdown buffer with a fenced block that names a language then failed
-- to parse -- "attempt to call method 'range' (a nil value)" -- and since the
-- parse is what draws bold, code spans and links, the whole buffer went flat.
-- Hover and completion popups are markdown buffers too, so they were hit by the
-- same thing. `main` has no such directive left and ships the same markdown
-- injections as Neovim itself, which is why moving was the fix rather than
-- copying core's query over master's.
--
-- `main` is a different plugin with the same name. It needs the
-- `tree-sitter-cli` package (packages/pacman.txt) to build a parser, and it
-- leaves everything to the caller: nothing is started, nothing is installed
-- until asked. The two things master's `auto_install` and `highlight` settings
-- did are written out below, because without them a language Neovim does not
-- bundle gets neither a parser nor colours.
--
-- Moving an existing checkout. vim.pack only compares a plugin's source, never
-- its branch, so a machine that already has master on disk keeps it however the
-- spec reads; and `vim.pack.update` would need the network and a confirmation
-- buffer. The one-off migration is to delete the checkout and let `add` clone
-- again, which asks the usual "these plugins will be installed" question and is
-- what a machine with nothing yet does anyway. The lockfile then records
-- main's head on the machine that migrated; commit it, and every machine that
-- starts from that lockfile gets the same revision.
--
-- The parsers master compiled lived inside its checkout, so deleting it deletes
-- them, and `main` installs into stdpath('data')/site/parser instead. They are
-- rebuilt in the background at the next start, which needs the CLI. Without it
-- a notice says so once and the editor carries on: the parsers Neovim bundles
-- (lua, vim, vimdoc, markdown, markdown_inline, query, c) need nothing.
--
-- Tried and rejected: keeping the old parsers by copying them across. They are
-- built from master's grammar revisions, and `main` ships queries for its own;
-- a query naming a node the old parser does not have fails when the buffer
-- opens, which is a worse failure than a few seconds of rebuilding.

local augroup = require('ide.group')

local NAME = 'nvim-treesitter'
local SRC = 'https://github.com/nvim-treesitter/nvim-treesitter'

-- What every machine gets whether or not a file of that kind has been opened,
-- so the first one is not the one that waits for a compile. The same list the
-- master setup had grown into, plus markdown_inline: master leaned on the copy
-- Neovim bundles, but `main`'s markdown queries are only safe beside its own.
local ENSURE = {
    'bash', 'c_sharp', 'css', 'csv', 'gitcommit', 'hyprlang', 'json', 'lua',
    'markdown', 'markdown_inline', 'typescript', 'vim', 'vimdoc', 'xml', 'yaml',
}

local data = vim.fn.stdpath('data')
local plugin_dir = vim.fs.joinpath(data, 'site', 'pack', 'core', 'opt', NAME)
local parser_dir = vim.fs.joinpath(data, 'site', 'parser')

local function has_cli()
    return vim.fn.executable('tree-sitter') == 1
end

-- master and main share a name and nothing else; this file exists only in
-- master, which is how the old layout is told from the new one.
local function archived_layout()
    return vim.uv.fs_stat(vim.fs.joinpath(plugin_dir, 'lua', 'nvim-treesitter', 'configs.lua')) ~= nil
end

local warned = false
local function warn_cli()
    if warned then
        return
    end
    warned = true
    vim.schedule(function()
        vim.notify('tree-sitter-cli is not installed, so parsers cannot be built. '
            .. 'Run ./install.sh packages in the dotfiles. Highlighting for languages '
            .. 'Neovim bundles is unaffected.', vim.log.levels.WARN)
    end)
end

-- After the plugin changes, its parsers have to be rebuilt to match: the plugin
-- is only guaranteed to work with the revisions its own table names. Declared
-- before `add`, so the install it may trigger is seen too -- though an install
-- has no parsers to update yet, and the FileType handler below builds them.
vim.api.nvim_create_autocmd('PackChanged', {
    group = augroup,
    callback = function(ev)
        local data = ev.data
        if data.spec.name ~= NAME or data.kind ~= 'update' then
            return
        end
        if not data.active then
            vim.cmd.packadd(NAME)
        end
        if has_cli() then
            vim.cmd('TSUpdate')
        else
            warn_cli()
        end
    end,
})

if archived_layout() then
    vim.notify('nvim-treesitter: leaving the archived master branch for main', vim.log.levels.INFO)
    local ok, err = pcall(vim.pack.del, { NAME }, { force = true })
    if not ok then
        vim.notify('nvim-treesitter: could not remove the old checkout: ' .. tostring(err), vim.log.levels.ERROR)
    end
end

vim.pack.add({ { src = SRC, version = 'main' } })

local ok, ts = pcall(require, NAME)
if not ok or type(ts.install) ~= 'function' then
    -- Still master, or nothing at all: say so rather than fail in some
    -- handler later with a message about a nil value.
    error('nvim-treesitter is not the main branch: ' .. tostring(ts))
end

-- What the plugin can build, asked for once: listing it fires the TSUpdate
-- event and loads a table of some three hundred parsers.
local available
local function can_build(lang)
    if not available then
        available = {}
        for _, name in ipairs(ts.get_available()) do
            available[name] = true
        end
    end
    return available[lang] == true
end

local function missing(languages)
    return vim.tbl_filter(function(lang)
        return not vim.uv.fs_stat(vim.fs.joinpath(parser_dir, lang .. '.so'))
    end, languages)
end

-- After startup rather than during it: the build is asynchronous, but looking
-- is not free, and nothing at startup depends on the answer.
vim.api.nvim_create_autocmd('VimEnter', {
    group = augroup,
    once = true,
    callback = function()
        vim.schedule(function()
            local todo = missing(ENSURE)
            if #todo == 0 then
                return
            end
            if has_cli() then
                ts.install(todo)
            else
                warn_cli()
            end
        end)
    end,
})

-- Highlighting is off until something turns it on, and master's `highlight`
-- setting was never set here, so only Neovim's own ftplugins did (markdown,
-- lua, vim, help). C# was coloured by the regex syntax file and the language
-- server's semantic tokens. Now every language with a parser gets it, which is
-- what the plugin's README tells a config to do.
--
-- A language with no parser anywhere on the runtimepath is built, when main
-- knows it and the compiler is there, and started when that finishes: the
-- other half of what `auto_install` was for. Nothing is said when it cannot
-- be: most filetypes (text, gitignore, ...) have no grammar and never will.
--
-- Once per language per session. A grammar that fails to compile would
-- otherwise be rebuilt for every buffer of that kind that opens, each one
-- taking seconds to fail the same way; the build says why on its own.
local tried = {}

vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    callback = function(args)
        local buf, ft = args.buf, args.match
        local lang = vim.treesitter.language.get_lang(ft)
        if not lang then
            return
        end

        local function start()
            if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == ft then
                pcall(vim.treesitter.start, buf, lang)
            end
        end

        if vim.treesitter.language.add(lang) then
            return start()
        end
        if tried[lang] or not has_cli() or not can_build(lang) then
            return
        end
        tried[lang] = true
        ts.install({ lang }):await(function()
            vim.schedule(start)
        end)
    end,
})

return { ensure = ENSURE }
