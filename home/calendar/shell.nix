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
      n = "hx";
      bt = "btop";
      cc = "cd ~/code";
      cdot = "cd ~/life/dotfiles";
      ch = "cd ~";
    };
    # Short git verbs are abbreviations, not aliases: they expand in place, so
    # history keeps the real command and fish's `git` completions still apply
    # after the expansion. Only verbs that forward arguments verbatim are
    # listed; `gp` on a fresh branch depends on push.autoSetupRemote below.
    # `lz` is avoided on purpose: mtools already owns that name on PATH.
    shellAbbrs = {
      gs = "git status";
      ga = "git add";
      gaa = "git add -A";
      gd = "git diff";
      gds = "git diff --staged";
      gl = "git pull";
      gp = "git push";
      gb = "git branch";
      gsw = "git switch";
      gco = "git checkout";
      glog = "git log --graph --oneline --decorate --all";
      lg = "lazygit";
      # `-m` needs the message as a single argument, which an alias cannot do
      # for unquoted words. Expand to empty quotes and park the cursor inside.
      gm = {
        expansion = ''git commit -m "%"'';
        setCursor = true;
      };
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

  # Starship ran on its built-in defaults, whose git status renders as
  # `[!+?⇡]`: one glyph per state regardless of file count, staged and
  # unstaged mixed together, and `$` for stashes. Keep the same modules but
  # add counts and order the groups index -> worktree, plus show merge/rebase
  # progress and the short commit instead of only on a detached HEAD.
  # git_metrics stays disabled: it spawns an extra `git diff --numstat` on
  # every prompt and renders a dangling `[+3/-]` when deletions are zero.
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableInteractive = true;
    settings = {
      git_status = {
        format = ''([\[$staged$modified$untracked$deleted$renamed$conflicted$stashed$ahead_behind\]]($style) )'';
        staged = "+$count";
        modified = "!$count";
        untracked = "?$count";
        deleted = "✘$count";
        renamed = "»$count";
        conflicted = "=$count";
        stashed = "⚑$count";
        ahead = "⇡$count";
        behind = "⇣$count";
        diverged = "⇕⇡$count⇣$count";
        up_to_date = "";
      };
      # Merge/rebase progress. Starship's default already renders this; the
      # block is explicit so a default change cannot silently drop it. Do not
      # wrap the format in extra parentheses: starship parses `(...)` as a
      # style modifier and the module then renders nothing.
      git_state = {
        format = ''\([$state( $progress_current/$progress_total)]($style)\) '';
        style = "bold yellow";
      };
      git_commit = {
        only_detached = false;
        format = ''([\($hash$tag\)]($style) )'';
        style = "bright-black";
      };
    };
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
      # Without this, `git push` on a freshly created branch stops with
      # "no upstream branch"; the `gp` abbreviation depends on it.
      push = {
        autoSetupRemote = true;
      };
      core = {
        editor = "hx";
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
    gcc
    gh
    gnumake
    htop
    jq
    lazygit
    ncdu
    pnpm_10
    ripgrep
    tree
    tree-sitter
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

  # EDITOR and VISUAL are set by programs.helix.defaultEditor. Keep only
  # unrelated shell defaults here so the editor has a single source of truth.
  home.sessionVariables = {
    PAGER = "less";
  };
}
