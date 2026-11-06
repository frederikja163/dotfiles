-- The one autocommand group everything in this config puts its autocommands
-- in, so `:autocmd custom` lists all of them.
--
-- It is made here and required by the modules that need it, because
-- nvim_create_augroup clears a group that already exists: if each module
-- created "custom" for itself, the last one loaded would wipe the others.
return vim.api.nvim_create_augroup("custom", { clear = true })
