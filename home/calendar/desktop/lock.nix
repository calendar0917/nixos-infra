{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  niriEnabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  enabled = niriEnabled && shell == "waybar";
  niriLib = import ./lib.nix { inherit pkgs lib; };
  wallpaper = ../../../config/wallpapers/background.jpg;

  hyprlock = "${config.programs.hyprlock.package}/bin/hyprlock";
  hyprlockConfig = "${config.xdg.configHome}/hypr/hyprlock.conf";
in
{
  config = lib.mkIf enabled {
    # Home Manager owns the package and configuration. The NixOS
    # programs.hyprlock module is intentionally not enabled because it also
    # starts Hypridle for the whole session.
    programs.hyprlock = {
      enable = true;
      settings = {
        general = {
          hide_cursor = true;
          ignore_empty_input = true;
        };

        animations.enabled = false;

        background = [
          {
            monitor = "";
            path = "${wallpaper}";
            color = "rgb(1e1e2e)";
            blur_passes = 3;
            blur_size = 7;
            brightness = 0.60;
          }
        ];

        label = [
          {
            monitor = "";
            text = "$TIME";
            font_family = "JetBrains Mono";
            font_size = 72;
            color = "rgb(cdd6f4)";
            position = "0, 120";
            halign = "center";
            valign = "center";
          }
          {
            monitor = "";
            text = "cmd[update:60000] ${pkgs.coreutils}/bin/date '+%Y年%m月%d日 %A'";
            font_family = "Noto Sans CJK SC";
            font_size = 18;
            color = "rgb(a6adc8)";
            position = "0, 35";
            halign = "center";
            valign = "center";
          }
        ];

        input-field = [
          {
            monitor = "";
            size = "320, 52";
            position = "0, -70";
            halign = "center";
            valign = "center";
            rounding = 12;
            outline_thickness = 2;
            fade_on_empty = false;
            inner_color = "rgba(313244dd)";
            outer_color = "rgb(89b4fa)";
            font_color = "rgb(cdd6f4)";
            check_color = "rgb(a6e3a1)";
            fail_color = "rgb(f38ba8)";
            capslock_color = "rgb(f9e2af)";
            placeholder_text = "输入密码";
            fail_text = "验证失败，请重试";
            font_family = "Noto Sans CJK SC";
          }
        ];
      };
    };

    home.packages = [
      niriLib.niriLock
      niriLib.niriLockWait
    ];

    # Main uses logind's real LockedHint. There is no automatic idle timeout
    # here: this only covers manual lock and the logind sleep path. `-w` makes
    # swayidle hold the logind delay inhibitor until before-sleep finishes.
    services.swayidle = {
      enable = true;
      systemdTargets = [ "niri.service" ];
      extraArgs = [ "-w" ];
      events = {
        before-sleep = "${niriLib.niriLockWait}/bin/niri-lock-wait";
        lock = "${niriLib.niriLock}/bin/niri-lock";
      };
    };

    # Home Manager already binds swayidle to niri.service and requires
    # WAYLAND_DISPLAY. Add the same BindsTo/transition guard as the other niri
    # helpers so a session that is still running DMS cannot start a second
    # sleep handler.
    systemd.user.services.swayidle = {
      Unit.BindsTo = [ "niri.service" ];
      Service.ExecCondition = niriLib.noDmsGuard;
    };

    # Manual lock only: no WantedBy/Install and no Restart. A second start
    # while the unit is active is handled by systemd, so the key binding does
    # not need a pgrep race.
    systemd.user.services.niri-lock-screen = {
      Unit = niriLib.niriUnit // {
        Description = "Manual Hyprlock screen lock for the niri session";
        ConditionEnvironment = [
          "WAYLAND_DISPLAY"
          "NIRI_SOCKET"
        ];
      };
      Service = {
        Type = "simple";
        ExecCondition = niriLib.noDmsGuard;
        ExecStart = "${hyprlock} --config ${hyprlockConfig} --grace 0 --no-fade-in";
        Restart = "no";
        Environment = [
          "LANG=${osConfig.i18n.defaultLocale}"
          "LC_TIME=${osConfig.i18n.defaultLocale}"
          "LOCALE_ARCHIVE=${osConfig.i18n.glibcLocales}/lib/locale/locale-archive"
        ];
      };
    };
  };
}
