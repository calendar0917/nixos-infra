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
      bt = "btop";
      cc = "cd ~/code";
      cdot = "cd ~/life/dotfiles";
      ch = "cd ~";
    };
    functions = {
      pon.body = ''
        set -gx http_proxy http://127.0.0.1:7897
        set -gx https_proxy http://127.0.0.1:7897
        set -gx all_proxy socks5://127.0.0.1:7897
        set -gx HTTP_PROXY http://127.0.0.1:7897
        set -gx HTTPS_PROXY http://127.0.0.1:7897
        echo 终端代理已开启
      '';
      poff.body = ''
        set -e http_proxy
        set -e https_proxy
        set -e all_proxy
        set -e HTTP_PROXY
        set -e HTTPS_PROXY
        echo 终端代理已关闭
      '';
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

  # Keep Git identity declarative. The GitHub credential helper delegates to
  # the user-owned `gh` login in ~/.config/gh; no token is stored here. SSH
  # keys remain user-managed files under ~/.ssh.
  programs.git = {
    enable = true;
    settings = {
      credential = {
        "https://github.com".helper = [
          ""
          "!${pkgs.gh}/bin/gh auth git-credential"
        ];
        "https://gist.github.com".helper = [
          ""
          "!${pkgs.gh}/bin/gh auth git-credential"
        ];
      };
      user = {
        name = "calendar";
        email = "1131821081@qq.com";
      };
      init = {
        defaultBranch = "main";
      };
      pull = {
        rebase = true;
      };
      core = {
        editor = "nvim";
      };
      color = {
        ui = "auto";
      };
    };
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
    # `rr` (the remote-research-runner CLI) is a stdlib-only Python program
    # whose launcher is `python3 -m rr`. Arch had a system python3 on PATH;
    # NixOS does not, so provide one explicitly. Project venvs keep using
    # uv-managed interpreters (see .python-version); this one only serves
    # tooling scripts such as `rr`.
    python312
  ];

  # NixOS does not put ~/.local/bin on PATH by default. `rr` is installed
  # there as a symlink to the repo-tracked skill launcher, so add it
  # declaratively instead of patching shell rc files.
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    PAGER = "less";
  };
}
