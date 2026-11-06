-- Neovim entry point.
--
-- The configuration lives in the modules below, each a file under lua/ide/.
-- They are loaded in this order, and the order is not arbitrary:
--
--   options      options and the leader key; before anything that makes a
--                mapping, because <leader> is expanded when the mapping is made
--   mapped       which key maps are this config's, told by the script id they
--                carry, which is the one a map made from here has -- so it is
--                loaded here, in this file's context, and read back from a map
--                of no consequence
--   group        the autocommand group the others share
--   registry     what the palette can offer; commands are declared through it
--   autosave     writing when focus leaves, reloading what changed on disk
--   pick         mini.pick and its companions, which the modules after it ask for
--   lsp          language servers, and the C# split between two of them
--   lists        quickfix and location lists, and the picker LSP results go through
--   navigate     going to definitions, usages, implementations, callers
--   csharp       library and generated code, ///, removing unused usings
--   toggles      :Toggle, and the usages highlight
--   dotnet       :Build, :Test, :Run, :Watch; before sessions, whose VimLeavePre
--                has to find the terminals it starts already closed
--   debug        the debugger; before sessions for the same reason, with its
--                REPL and sidebars
--   sessions     one session per directory
--   review       reviewing a diff in the file itself
--   theme        colours; after review, whose highlights it has to cover
--   treesitter   parsers
--   completion   insert-mode completion, Neovim's own
--   modal        the engine for sticky modes
--   modes        the window modes, size and move
--   statusline   what the keyboard is doing, and where the editor is
--   palette      the key cheatsheet and the command palette
--   keys         every key; last, because it binds what the others export
--
-- Each is loaded on its own and a failure is reported rather than raised. One
-- module breaking -- a plugin that cannot be fetched offline, a typo in the
-- file being edited -- would otherwise stop init.lua there and leave the
-- editor without a leader key or a language server, which is a worse place to
-- be than one feature short with the reason on screen. The names that failed
-- are in vim.g.ide_failed, which tests/test_nvim.sh checks is empty.

vim.g.ide_failed = {}

for _, name in ipairs({
    'options',
    'mapped',
    'group',
    'registry',
    'autosave',
    'pick',
    'lsp',
    'lists',
    'navigate',
    'csharp',
    'toggles',
    'dotnet',
    'debug',
    'sessions',
    'review',
    'theme',
    'treesitter',
    'completion',
    'modal',
    'modes',
    'statusline',
    'palette',
    'keys',
}) do
    local ok, err = pcall(require, 'ide.' .. name)
    if not ok then
        local failed = vim.g.ide_failed
        table.insert(failed, name)
        vim.g.ide_failed = failed
        vim.schedule(function()
            vim.notify(('ide.%s failed to load:\n%s'):format(name, err), vim.log.levels.ERROR)
        end)
    end
end
