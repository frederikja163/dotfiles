-- The picker everything else is built on, and the two small plugins that make
-- it more than a file finder. Other modules ask for it by requiring mini.pick,
-- which is on the runtimepath once this has run.
--
--   mini.pick   the picker itself
--   mini.extra  pickers for things Neovim already knows -- diagnostics, the
--               jump list, recent files, LSP symbols, a live workspace-symbol
--               search -- so none of them is written here. Its `lsp` picker is
--               *not* what references and implementations go through: it sorts
--               by path, which would undo the tests-last order lists.lua gives
--               every list (see there), and it cannot delete an entry.
--   mini.icons  the icons in the pickers, and in the completion menu's kinds
--
-- Same author and the same conventions as the picker this config already
-- used, which is why these and not telescope, snacks or fzf-lua: one family,
-- no required dependency beyond Neovim.

vim.pack.add({
    { src = "https://github.com/nvim-mini/mini.pick" },
    { src = "https://github.com/nvim-mini/mini.extra" },
    { src = "https://github.com/nvim-mini/mini.icons" },
})
require('mini.icons').setup()
require('mini.pick').setup()
require('mini.extra').setup()
