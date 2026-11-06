-- Theme
--
-- gitsigns is themed as if the background were opaque. With
-- `transparent_background` the integration follows it by default, and that
-- variant paints a diff with foreground colours: every added line of the
-- inline review view (<leader>gr) went solid green text, and every changed
-- word dark text on green, hiding both treesitter and the LSP's semantic
-- highlighting. The opaque variant marks the same lines with background
-- colours only -- DiffAdd, as the side-by-side view does -- so the code
-- underneath keeps its own colours.
vim.pack.add({ { src = "https://github.com/catppuccin/nvim" } })
require('catppuccin').setup({
    transparent_background = true,
    integrations = {
        gitsigns = { enabled = true, transparent = false },
    },
})
vim.cmd.colorscheme "catppuccin-mocha"
