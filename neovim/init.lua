-- Options
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.number = true
vim.opt.splitright = true
vim.opt.scrolloff = 5
vim.opt.cursorline = true
vim.opt.inccommand = 'split'
vim.opt.relativenumber = true
vim.opt.wrap = false
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.swapfile = false
vim.opt.winborder = "rounded"
vim.opt.signcolumn = "yes"
vim.g.mapleader = " "

-- Keymaps
vim.keymap.set('n', '<leader>r', '<cmd>update<CR> <cmd>source<CR>')
vim.keymap.set('n', '<leader>c', '<cmd>quit<CR>')
vim.keymap.set('n', '<leader>w', '<cmd>write<CR>')
vim.keymap.set('n', '<leader>t', '<cmd>terminal<CR>')
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('t', '<Esc>', '<C-\\><C-n>')
vim.keymap.set('i', '<C-j>', '<C-o>j')
vim.keymap.set('i', '<C-k>', '<C-o>k')
vim.keymap.set('i', '<C-h>', '<C-o>h')
vim.keymap.set('i', '<C-l>', '<C-o>l')
-- focus a window (kept as-is; these do not clash with Hyprland, which grabs
-- SUPER). Despite the old comment here, wincmd h/j/k/l moves the *cursor*
-- between windows -- moving a window is wincmd H/J/K/L, which is <leader>m
-- below.
vim.keymap.set('n', '<C-j>', '<cmd>wincmd j<CR>')
vim.keymap.set('n', '<C-k>', '<cmd>wincmd k<CR>')
vim.keymap.set('n', '<C-h>', '<cmd>wincmd h<CR>')
vim.keymap.set('n', '<C-l>', '<cmd>wincmd l<CR>')

-- Window binds mirroring hypr/modes.lua, with <leader> standing in for SUPER.
--
-- The compositor is modal: a verb key enters a mode and a motion says where.
-- Here the same grammar is just a two-key mapping, which is nvim's native
-- idiom -- no mode to be in, but the keys you press are the same ones:
--
--   <leader>  + hjkl   focus a window        (SUPER + hjkl)
--   <leader>m + hjkl   move it there         (SUPER+M then the motion)
--   <leader>s + hjkl   resize it             (SUPER+S then the motion)
--   <leader><Tab>      next buffer           (SUPER+Tab, next desktop)
--
-- Buffers stand in for desktops: they are the thing you cycle through with
-- Tab, and SHIFT reverses it, exactly as in the compositor.
--
-- What is deliberately gone: <leader>HJKL (move) and <leader><C-hjkl>
-- (resize). Those were the old chord grammar, where SHIFT meant move and CTRL
-- meant resize. Keeping them would mean two ways to do the same thing, one of
-- which contradicts the compositor.
local resizeStep = 5

local directions = {
	{ key = 'h', focus = 'h', move = 'H', resize = 'vertical resize -' .. resizeStep },
	{ key = 'j', focus = 'j', move = 'J', resize = 'resize +' .. resizeStep },
	{ key = 'k', focus = 'k', move = 'K', resize = 'resize -' .. resizeStep },
	{ key = 'l', focus = 'l', move = 'L', resize = 'vertical resize +' .. resizeStep },
}

for _, d in ipairs(directions) do
	vim.keymap.set('n', '<leader>' .. d.key, '<cmd>wincmd ' .. d.focus .. '<CR>',
		{ desc = 'Focus the window ' .. d.key })
	vim.keymap.set('n', '<leader>m' .. d.key, '<cmd>wincmd ' .. d.move .. '<CR>',
		{ desc = 'Move the window ' .. d.key })
	vim.keymap.set('n', '<leader>s' .. d.key, '<cmd>' .. d.resize .. '<CR>',
		{ desc = 'Resize the window ' .. d.key })
end

-- The desktop axis, which here is the buffer list.
vim.keymap.set('n', '<leader><Tab>', '<cmd>bnext<CR>', { desc = 'Next buffer' })
vim.keymap.set('n', '<leader><S-Tab>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })

-- new window
vim.keymap.set('n', '<leader>ws', '<cmd>wincmd s<CR>')
vim.keymap.set('n', '<leader>wv', '<cmd>wincmd v<CR>')

-- File browser
vim.pack.add({ { src = "https://github.com/nvim-mini/mini.pick" } })
require('mini.pick').setup()
vim.keymap.set('n', '<leader>ff', '<cmd>Pick files<CR>')
vim.keymap.set('n', '<leader>fb', '<cmd>Pick buffers<CR>')
vim.keymap.set('n', '<leader>fh', '<cmd>Pick help<CR>')

-- LSP
vim.pack.add({ { src = "https://github.com/neovim/nvim-lspconfig" } })
vim.lsp.enable({ "lua_ls", "clangd", "denols", "html", "ts_ls" })
vim.keymap.set('n', '<leader>d', vim.diagnostic.open_float)
vim.keymap.set('n', '<leader>cf', vim.lsp.buf.format)
vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action)

-- Theme
vim.pack.add({ { src = "https://github.com/catppuccin/nvim" } })
vim.cmd.colorscheme "catppuccin-mocha"

vim.pack.add({ { src = "https://github.com/nvim-treesitter/nvim-treesitter" } })
require('nvim-treesitter.configs').setup({
	auto_install = true
})

-- Auto complete
vim.pack.add({
	{ src = "https://github.com/hrsh7th/nvim-cmp" },
	{ src = "https://github.com/hrsh7th/vim-vsnip" },
	{ src = "https://github.com/hrsh7th/cmp-vsnip" },
	{ src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
	{ src = "https://github.com/hrsh7th/cmp-path" },
	{ src = "https://github.com/onsails/lspkind.nvim" },
})
local cmp = require("cmp")
cmp.setup({
	snippet = {
		expand = function(args)
			vim.fn["vsnip#anonymous"](args.body)
		end,
	},
	mapping = {
		["<C-p>"] = cmp.mapping.select_prev_item(),
		["<C-n>"] = cmp.mapping.select_next_item(),
		["<C-d>"] = cmp.mapping.scroll_docs(-4),
		["<C-f>"] = cmp.mapping.scroll_docs(4),
		["<C-Space>"] = cmp.mapping.complete(),
		["<C-e>"] = cmp.mapping.close(),
		["<CR>"] = cmp.mapping.confirm({
			behavior = cmp.ConfirmBehavior.Replace,
			select = true,
		}),
		["<Tab>"] = cmp.mapping(cmp.mapping.select_next_item(), { "i", "s" }),
		["<S-Tab>"] = cmp.mapping(cmp.mapping.select_prev_item(), { "i", "s" }),
	},
	formatting = {
		format = function(_, vim_item)
			vim.cmd("packadd lspkind-nvim")
			vim_item.kind = require("lspkind").presets.codicons[vim_item.kind]
					.. "  "
					.. vim_item.kind
			return vim_item
		end,
	},
	sources = {
		{ name = "nvim_lsp" },
		{ name = "vsnip" },
		{ name = "path" },
	},
})
