-- Keep this file deliberately small: LazyVim already provides the standard
-- leader maps. Only the search-highlight reset is repeated here.
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })
