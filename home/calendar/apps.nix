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

  wechatWithFcitx = pkgs.symlinkJoin {
    name = "wechat-fcitx";
    paths = [ pkgs.wechat ];
    buildInputs = [ pkgs.makeWrapper ];

    postBuild = ''
      wrapProgram "$out/bin/wechat" \
        --set QT_IM_MODULE fcitx \
        --set XMODIFIERS '@im=fcitx'
    '';
  };

  # DS Bot only ships as an AppImage and the user refreshes it by hand, so
  # there is no release URL/SHA to pin and `wrapType2` is the wrong tool. The
  # wrapper exists for the detached launch: `setsid -f` forks the runner away
  # from the caller's controlling terminal, so a shell prompt returns at once
  # and closing the terminal no longer takes the app down with it. The desktop
  # entry below does not need it (Terminal=false spawns no terminal at all),
  # but both entry points then behave identically.
  dsBot = pkgs.writeShellApplication {
    name = "ds-bot";
    runtimeInputs = [
      pkgs.appimage-run
      pkgs.util-linux
    ];
    text = ''
      image="''${DS_BOT_APPIMAGE:-$HOME/appimage/DS-Bot.AppImage}"
      if [ ! -x "$image" ]; then
        echo "ds-bot: no executable AppImage at $image" >&2
        echo "ds-bot: set DS_BOT_APPIMAGE to use another file" >&2
        exit 1
      fi
      exec setsid -f appimage-run "$image" "$@"
    '';
  };

  qqWithFcitx = pkgs.qq.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];

    postFixup = (old.postFixup or "") + ''
      wrapProgram "$out/bin/qq" \
        --set NIXOS_OZONE_WL "" \
        --set GTK_IM_MODULE fcitx \
        --set XMODIFIERS '@im=fcitx'
    '';
  });
in
{
  config = lib.mkIf isMain {
    home.packages = with pkgs; [
      dsBot
      freerdp
      obsidian
      onlyoffice
      qqWithFcitx
      # Niri binds `xdg-open superproductivity://...` to Mod+A/Mod+S, so both the
      # app and the URL opener must be on the user's PATH.
      super-productivity
      xdg-utils
      wechatWithFcitx
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
      "x-scheme-handler/superproductivity" = "superproductivity.desktop";
    };

    # The launcher entry for the hand-downloaded AppImage. Without it the only
    # way in is running `appimage-run` inside a terminal, which keeps that
    # terminal occupied for the whole session. Terminal=false means the
    # launcher starts the app directly, and StartupWMClass pins the detail that
    # Electron announces `dsbot` as its app_id, so the taskbar groups the
    # window with this entry instead of showing an unrelated icon. The icon is
    # installed under its theme name rather than written as an absolute store
    # path, which is what launchers look up.
    home.file.".local/share/icons/hicolor/256x256/apps/dsbot.png".source =
      ../../config/icons/dsbot.png;

    xdg.desktopEntries.ds-bot = {
      name = "DS Bot";
      comment = "DS Bot desktop app";
      exec = "${dsBot}/bin/ds-bot";
      icon = "dsbot";
      terminal = false;
      categories = [ "Utility" ];
      settings.StartupWMClass = "dsbot";
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
