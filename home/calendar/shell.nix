{
  pkgs,
  ...
}:

{
  programs.fish = {
    enable = true;
    shellAliases = {
      ls = "eza --group-directories-first";
      ll = "eza -al --group-directories-first";
      cat = "bat --style=plain";
      g = "git";
      n = "nvim";
    };
    interactiveShellInit = ''
      set -g fish_greeting ""
    '';
  };

  # Yazi is the terminal file manager. The Home Manager module provides the
  # fish `y` function (--cwd-file), so leaving Yazi changes the shell to the
  # last visited directory. Keep only small preview helpers; no plugin or
  # theme collection is installed here.
  programs.yazi = {
    enable = true;
    enableFishIntegration = true;
    shellWrapperName = "y";
    extraPackages = with pkgs; [
      fd
      ffmpegthumbnailer
      file
      fzf
      imagemagick
      poppler-utils
      ripgrep
    ];
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableInteractive = true;
  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableFishIntegration = true;
    enableGitIntegration = true;
  };

  # Keep Git identity declarative, but do not manage credentials or signing
  # keys. Existing ~/.ssh and credential helpers remain untouched.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "calendar";
        email = "1131821081@qq.com";
      };
      init = { defaultBranch = "main"; };
      pull = { rebase = true; };
      core = { editor = "nvim"; };
      color = { ui = "auto"; };
    };
  };

  programs.kitty = {
    enable = true;
    settings = {
      font_family = "JetBrains Mono";
      font_size = 11;
      cursor_shape = "beam";
      scrollback_lines = 10000;
      enable_audio_bell = false;
      confirm_os_window_close = 0;
      copy_on_select = true;
    };
    shellIntegration.mode = "enabled";
  };

  home.packages = with pkgs; [
    bat
    btop
    eza
    fastfetch
    fzf
    gh
    htop
    jq
    lazygit
    ncdu
    pnpm_10
    tree
    unzip
    uv
    wl-clipboard
    yq
    nodejs_22
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
  };
}
