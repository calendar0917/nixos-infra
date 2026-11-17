{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  # The enhanced Yazi profile is main-only. The mini host keeps the small
  # shared setup from shell.nix (enable + fish wrapper) unchanged.
  isMain = osConfig != null && (osConfig.networking.hostName or "") == "main";

  # Save the live Wayland clipboard image into Yazi's current directory. This
  # is unrelated to cliphist: it reads the real clipboard through wl-paste and
  # never changes the user's clipboard contents.
  pasteImage = pkgs.writeShellApplication {
    name = "yazi-paste-image";
    runtimeInputs = with pkgs; [
      coreutils
      file
      libnotify
      wl-clipboard
    ];
    text = builtins.readFile ./desktop/yazi-paste-image.sh;
  };
in
{
  config = lib.mkIf isMain {
    home.packages = [ pasteImage ];

    programs.yazi = {
      # Keep the preview tool set from shell.nix and add the pieces needed for
      # video thumbnails, SVG previews and a terminal image fallback. ouch is
      # the compressor/lister behind the ouch plugin; udisksctl, lsblk and
      # eject are the commands the mount plugin drives, and gdbus is its
      # authenticated fallback. udisks2 is already a system service
      # (modules/base.nix); these entries only pin the tools to Yazi's wrapper
      # PATH.
      extraPackages = with pkgs; [
        ffmpeg
        resvg
        chafa
        ouch
        udisks2
        util-linux
        glib
      ];

      settings = {
        mgr = {
          ratio = [ 1 3 4 ];
          sort_by = "natural";
          sort_dir_first = true;
          show_hidden = true;
          show_symlink = true;
          linemode = "size";
          scrolloff = 5;
        };

        preview = {
          wrap = "yes";
          max_width = 1000;
          max_height = 1000;
        };

        # ouch both lists archive contents in the preview pane and creates
        # archives. The same plugin is used for compression, so no separate
        # compress.yazi is installed.
        plugin.prepend_previewers = [
          {
            mime = "application/{*zip*,*7z*,*rar*,*tar*,*gzip*,*xz*,*zstd*,*bzip2*,*lz4*,*lzma*,*lzo*,*java-archive*}";
            run = "ouch";
          }
        ];

        # Only the edit opener is replaced. Images, PDFs, videos and other
        # files keep their default/Yazi desktop opener behaviour.
        opener.edit = [
          {
            run = "nvim %s";
            block = true;
            for = "unix";
          }
        ];
      };

      plugins = {
        "smart-enter" = pkgs.yaziPlugins.smart-enter;
        "full-border" = pkgs.yaziPlugins.full-border;
        "toggle-pane" = pkgs.yaziPlugins.toggle-pane;

        git = pkgs.yaziPlugins.git;
        chmod = pkgs.yaziPlugins.chmod;
        ouch = pkgs.yaziPlugins.ouch;
        mount = pkgs.yaziPlugins.mount;
        smart-paste = pkgs.yaziPlugins.smart-paste;
      };

      initLua = ''
        require("full-border"):setup()
        require("git"):setup()
      '';

      keymap.mgr.prepend_keymap = [
        {
          on = "<Enter>";
          run = "plugin smart-enter";
          desc = "Enter directory or open file";
        }
        {
          on = "T";
          run = "plugin toggle-pane max-preview";
          desc = "Maximize or restore preview";
        }
        {
          on = "<A-p>";
          run = "plugin toggle-pane min-preview";
          desc = "Hide or show preview";
        }
        {
          on = [
            "c"
            "m"
          ];
          run = "plugin chmod";
          desc = "Change file permissions";
        }
        {
          on = [
            "c"
            "p"
          ];
          run = "plugin smart-paste";
          desc = "Paste into hovered directory";
        }
        {
          on = [
            "c"
            "i"
          ];
          run = "shell -- yazi-paste-image";
          desc = "Save clipboard image to current directory";
        }
        {
          on = [
            "c"
            "t"
          ];
          run = "shell -- yazi-pin-image %h";
          desc = "Pin hovered image with Mark Shot";
        }
        # d -> trash, D -> permanent delete and g t -> trash are Yazi's own
        # bindings. They are deliberately not duplicated here.
        {
          on = "C";
          run = "plugin ouch";
          desc = "Compress selected files";
        }
        {
          on = "E";
          run = "shell -- ya pub extract --list %s";
          desc = "Extract selected archives";
        }
        {
          on = "M";
          run = "plugin mount";
          desc = "Mount and unmount drives";
        }
        {
          on = [
            "g"
            "c"
          ];
          run = "cd ~/code";
          desc = "Go to ~/code";
        }
        {
          on = [
            "g"
            "h"
          ];
          run = "cd ~";
          desc = "Go home";
        }
        {
          on = [
            "g"
            "p"
          ];
          run = "cd ~/Pictures";
          desc = "Go to ~/Pictures";
        }
        {
          on = [
            "g"
            "s"
          ];
          run = "cd ~/Pictures/Screenshots";
          desc = "Go to ~/Pictures/Screenshots";
        }
        # g d (~/Downloads) already exists in Yazi's default keymap.
        {
          on = [
            "g"
            "r"
          ];
          run = ''shell -- ya emit cd "$(git rev-parse --show-toplevel)"'';
          desc = "Go to git repository root";
        }
      ];
    };
  };
}
