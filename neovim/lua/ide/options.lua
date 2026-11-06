-- Options and the leader key. Loaded first: <leader> in a mapping is expanded
-- when the mapping is made, so keys.lua has to come after this.

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
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.swapfile = false
vim.opt.winborder = "rounded"
vim.opt.signcolumn = "yes"
vim.opt.autoread = true
vim.opt.autowriteall = true
vim.opt.updatetime = 1000
vim.g.mapleader = " "

-- How many quickfix lists, and location lists, are kept. The default is ten, and
-- the stack is shared: what a references lookup was sent to, the hunks of a
-- review, the last build and the last test run each hold a place, and a list
-- pushed off the end is gone. Ten went quickly. A list that is gone is rebuilt
-- where there is a way to (the review does), and this is so that it rarely comes
-- to that.
vim.opt.chistory = 30
vim.opt.lhistory = 30
