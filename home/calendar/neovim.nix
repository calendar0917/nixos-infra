{
  pkgs,
  ...
}:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    withNodeJs = true;
    withPython3 = false;
    withRuby = false;
    # We provide our own init.lua as a read-only directory symlink. Keep
    # Home Manager's wrapper-only Lua out of that file to avoid a conflict.
    sideloadInitLua = true;

    # Runtime helpers referenced by LazyVim (telescope, treesitter, LSP).
    # Plugin code itself is installed by lazy.nvim under ~/.local/share/nvim.
    extraPackages = with pkgs; [
      curl
      fd
      gcc
      gnumake
      lazygit
      nodejs
      ripgrep
      tree-sitter
      unzip
      wget
    ];
  };

  # The Nix-managed part is read-only. Lazy.nvim's plugin state, cache and
  # lock file live in ~/.local/{share,state,cache}/nvim; see config/nvim.
  xdg.configFile."nvim".source = ../../config/nvim;
}
