{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  # These are full desktop applications for the laptop. The mini host keeps
  # its small DMS/Sway profile and must not pull in Office, meetings, OBS or
  # chat clients just because Home Manager is shared.
  isMain = osConfig != null && (osConfig.networking.hostName or "") == "main";

  # ONLYOFFICE's package copies extra font files into its own font directory.
  # Keep the list explicit: no Microsoft fonts or other unverified downloads
  # are added here.
  onlyoffice = pkgs.onlyoffice-desktopeditors.override {
    extraFontPackages = with pkgs; [
      carlito
      liberation_ttf
      noto-fonts-cjk-serif
    ];
  };
in
{
  config = lib.mkIf isMain {
    home.packages = with pkgs; [
      obsidian
      onlyoffice
      qq
      wechat
      wemeet
    ];

    # Home Manager's module installs the wrapped OBS package. Do not also add
    # pkgs.obs-studio to home.packages: that would create a second unwrapped
    # entry point and bypass the module's plugin/Browser setup.
    programs.obs-studio = {
      enable = true;
      plugins = [ ];
    };

    # Default handlers for the document, image and video types the user
    # actually asked for. Firefox deliberately remains the HTTP(S) browser and
    # Nautilus remains the directory handler. Do not add a video/* wildcard:
    # these entries only claim MP4 and WebM, which Firefox can play.
    xdg.mimeApps.defaultApplications = {
      "application/pdf" = "firefox.desktop";

      "image/png" = "firefox.desktop";
      "image/jpeg" = "firefox.desktop";
      "image/webp" = "firefox.desktop";
      "image/gif" = "firefox.desktop";
      "image/svg+xml" = "firefox.desktop";

      "video/mp4" = "firefox.desktop";
      "video/webm" = "firefox.desktop";

      "application/msword" = "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-excel" = "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-powerpoint" = "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.oasis.opendocument.text" = "onlyoffice-desktopeditors.desktop";
      "application/vnd.oasis.opendocument.spreadsheet" = "onlyoffice-desktopeditors.desktop";
      "application/vnd.oasis.opendocument.presentation" = "onlyoffice-desktopeditors.desktop";

      "x-scheme-handler/obsidian" = "md.obsidian.Obsidian.desktop";
    };

    # OBS expects this directory to exist before the first recording. Create
    # it only when absent; never move, overwrite or delete existing footage.
    home.activation.niriRecordingsDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      recordings="$HOME/Videos/Recordings"
      if [ ! -d "$recordings" ]; then
        run mkdir -p "$recordings"
      fi
    '';
  };
}
