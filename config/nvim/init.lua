-- Neovim entry point. Only text configuration is managed by Nix; plugins are
-- installed by lazy.nvim under ~/.local/share/nvim and never enter the store.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

require("config.options")
require("config.keymaps")
require("config.lazy")
