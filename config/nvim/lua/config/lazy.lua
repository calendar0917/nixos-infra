-- Bootstrap lazy.nvim into the user data directory, then let LazyVim provide
-- the default plugin set. The lock file is kept in the state directory
-- because the Nix-managed config directory is read-only.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if vim.fn.isdirectory(lazypath) == 0 then
  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to clone lazy.nvim:\n" .. out, vim.log.levels.ERROR)
    return
  end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "plugins" },
  },
  defaults = {
    lazy = false,
    version = false,
  },
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = { enabled = false },
  change_detection = { notify = false },
  lockfile = vim.fn.stdpath("state") .. "/lazy-lock.json",
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "matchit",
        "matchparen",
        "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
