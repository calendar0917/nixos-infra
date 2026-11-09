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
in
{
  config = lib.mkIf isMain {
    programs.yazi = {
      # Keep the preview tool set from shell.nix and add the pieces needed for
      # video thumbnails, SVG previews and a terminal image fallback.
      extraPackages = with pkgs; [
        ffmpeg
        resvg
        chafa
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

        # Only the edit opener is replaced. Images, PDFs, videos and other
        # files keep their default/Yazi desktop opener behaviour.
        opener.edit = [
          {
            run = "env NVIM_APPNAME=lazyvim nvim %s";
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
            "r"
          ];
          run = ''shell -- ya emit cd "$(git rev-parse --show-toplevel)"'';
          desc = "Go to git repository root";
        }
      ];
    };
  };
}
