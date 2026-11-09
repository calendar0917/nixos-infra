{
  lib,
  ...
}:

{
  # Neovim is the only editor on both hosts. `defaultEditor` exports
  # EDITOR and VISUAL as `nvim`, so git, sudoedit, tmux and other CLI tools
  # agree without repeating the name per tool. The mini host gets plain
  # Neovim; main additionally loads the LazyVim configuration from
  # lazyvim.nix, which writes into the same ~/.config/nvim.
  programs.neovim = {
    enable = true;
    defaultEditor = true;

    # With home.stateVersion 25.05 and Home Manager's 26.05 defaults, an
    # unset provider option warns and pulls both wrappers in. This repo uses
    # neither Ruby nor (outside LazyVim) Python plugins, so pin the smaller
    # set; main's LazyVim module overrides withPython3 = true.
    withRuby = lib.mkDefault false;
    withPython3 = lib.mkDefault false;
  };
}
