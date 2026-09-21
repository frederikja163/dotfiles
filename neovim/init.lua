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
vim.lsp.enable({ "lua_ls", "clangd", "denols", "html", "ts_ls", "roslyn_ls", "omnisharp" })
vim.lsp.config('roslyn_ls', {
  -- roslyn (Microsoft.CodeAnalysis.LanguageServer) is the server VS Code's C#
  -- extension uses by default. It needs a loaded project to be useful (the
  -- editor side tells it which sln/csproj to open); a project-less file gets
  -- nothing back, so it is gated on a project marker and a loose .cs file
  -- gets no server rather than a dead or silent one. A .csx script is
  -- OmniSharp's job -- it has a real scripting engine -- so roslyn never
  -- attaches there either.
  --
  -- root_dir must be the directory the sln/slnx/csproj is *in*, not the
  -- buffer's own directory. Nothing about the protocol makes the server look
  -- for a project itself: lspconfig's on_init lists root_dir, and sends
  -- solution/open or project/open only for a marker sitting directly there.
  -- Handing it the buffer's directory was tried and looks like it works,
  -- because the client still attaches and hover still answers out of roslyn's
  -- miscellaneous-files fallback -- but no project is ever opened, so
  -- workspace/projectInitializationComplete never fires and the file reports
  -- zero diagnostics. Only a .cs file sitting next to its own .csproj
  -- happened to load anything, and then the project rather than the solution,
  -- so a multi-project .slnx was never read at all.
  --
  -- Solution before project, so a .slnx at the repo root wins over the
  -- nearest .csproj and cross-project navigation works.
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    if fname == '' or fname:match('%.csx$') then
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
    -- A file opened while the solution is still loading gets its diagnostics
    -- computed against a compilation with no references resolved, so every
    -- using in it comes back as a single IDE0005 "Using directive is
    -- unnecessary" spanning the whole block. It is tagged Unnecessary, so the
    -- whole block renders greyed out, and it is wrong -- delete the usings and
    -- the build fails with CS0103.
    --
    -- The server will not recompute for a document that has not changed, so
    -- simply asking again does not help: lspconfig's own handler here re-runs
    -- textDocument/diagnostic and gets the same stale answer back, and the
    -- greying then survives for as long as the file is left untouched. Any
    -- real edit clears it, which is what makes it look like a rendering quirk
    -- rather than a wrong answer.
    --
    -- Re-attaching makes nvim send didClose then didOpen, so the server drops
    -- the document and analyses it again, now against the loaded solution.
    -- Editing the buffer and undoing it fixes the diagnostics too, but leaves
    -- 'modified' set on a file the user never touched; this does not.
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
  -- The server shim from the dotnet global tool is named roslyn-language-server,
  -- not the Microsoft.CodeAnalysis.LanguageServer binary lspconfig's default cmd
  -- reaches for off PATH.
  cmd = {
    'roslyn-language-server',
    '--logLevel',
    'Information',
    '--extensionLogDirectory',
    vim.fs.joinpath(os.getenv('TMPDIR') or '/tmp', 'roslyn_ls/logs'),
    '--stdio',
  },
})
vim.lsp.config('omnisharp', {
  -- OmniSharp for one thing only: .csx scripts, which roslyn cannot serve. Its
  -- scripting engine loads a lone script as a submission (script globals, #load,
  -- #r "nuget:..." resolved), which is exactly what dotnet-script files need.
  -- real project-backed .cs files go to roslyn, so this server refuses to start
  -- on anything but a .csx -- same gate, inverted.
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    if fname:match('%.csx$') then
      on_dir(vim.fn.fnamemodify(fname, ':h'))
    end
  end,
})
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
