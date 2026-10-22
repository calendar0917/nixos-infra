-- Add personal LazyVim plugin specs here. Plugin downloads and lockfiles live
-- under ~/.local/{share,state}/nvim, not in this Git repository.
return {
  -- Language extras are opt-in in LazyVim. Keep them here so the default
  -- plugin set stays small and both languages share the same LSP/format stack.
  { import = "lazyvim.plugins.extras.lang.python" },
  { import = "lazyvim.plugins.extras.lang.typescript" },
}
