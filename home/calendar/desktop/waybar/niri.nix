{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  enabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  hasBattery = osConfig != null && (osConfig.my.desktop.niri.hasBattery or false);
  # The mini host keeps DMS and must not grow the Waybar helper package.
  waybarShell = osConfig != null && (osConfig.my.desktop.niri.shell or "dms") == "waybar";

  waybar = import ./common.nix { inherit lib hasBattery; };

  # Waybar's built-in clock cannot localize %a with this build, and relying on
  # the session PATH for a helper is fragile when the bar is restarted by hand.
  # Bind the module to this absolute path instead.
  clock = pkgs.writeShellApplication {
    name = "niri-waybar-clock";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # The weekday comes from LC_TIME, never a hard-coded English name. The
      # tooltip carries seconds without spawning a second process per tick.
      output="$(date '+%m月%d日 周%a %H:%M|%Y-%m-%d %H:%M:%S %Z')"
      text="''${output%%|*}"
      tooltip="''${output#*|}"
      printf '{"text":"%s","tooltip":"%s"}\n' "$text" "$tooltip"
    '';
  };

  # Nerd Font Symbols glyphs are written as JSON escapes so this file stays
  # plain ASCII. The font itself is installed by the main host configuration.
  icon = {
    launcher = builtins.fromJSON ''"\uF0C9"'';
    volume = builtins.fromJSON ''"\uF028"'';
    wifi = builtins.fromJSON ''"\uF1EB"'';
    bell = builtins.fromJSON ''"\uF0F3"'';
    bellOff = builtins.fromJSON ''"\uF1F6"'';
    battery = builtins.fromJSON ''"\uF240"'';
    charging = builtins.fromJSON ''"\uF0E7"'';
  };

  modules = waybar.modules // {
    # The launcher is a font glyph so it needs no external icon theme.
    "custom/launcher" = {
      format = icon.launcher;
      tooltip = false;
      on-click = "fuzzel";
    };

    # The niri workspace-taskbar renders the real application icons of the
    # windows on each workspace. It is available in Waybar's upstream
    # development branch and is the reason main pins a newer Waybar source.
    "niri/workspaces" = {
      format = "{icon}";
      all-outputs = false;
      workspace-taskbar = {
        enable = true;
        icon-size = 18;
      };
    };

    # Two native network instances: Waybar reads the counters itself, so no
    # polling shell script is involved. `min-length` reserves a fixed width so
    # a changing rate does not shift the modules next to it.
    "network#downspeed" = {
      interval = 1;
      format = "↓ {bandwidthDownBytesCompact}/s";
      min-length = 9;
      tooltip = false;
    };

    "network#upspeed" = {
      interval = 1;
      format = "↑ {bandwidthUpBytesCompact}/s";
      min-length = 9;
      tooltip = false;
    };

    pulseaudio = {
      format = "${icon.volume} {volume}%";
      format-muted = "${icon.volume} muted";
      on-click = "pavucontrol";
      on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
      on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
      tooltip = false;
    };

    "network#status" = {
      interval = 5;
      format-wifi = "${icon.wifi} {essid}";
      format-ethernet = "${icon.wifi} eth {ifname}";
      format-disconnected = "${icon.wifi} offline";
      format-linked = "${icon.wifi} link";
      on-click = "nm-connection-editor";
      tooltip-format = "{ifname}\n{essid}\n{ipaddr}/{cidr}\n{signalStrength}%";
    };

    "custom/notification" = {
      tooltip = false;
      format = "{icon}";
      format-icons = {
        notification = icon.bell;
        none = icon.bellOff;
        dnd-notification = icon.bellOff;
        dnd-none = icon.bellOff;
        inhibited-notification = icon.bellOff;
        inhibited-none = icon.bellOff;
        dnd-inhibited-notification = icon.bellOff;
        dnd-inhibited-none = icon.bellOff;
      };
      return-type = "json";
      exec = "swaync-client -swb";
      on-click = "swaync-client -t -sw";
      on-click-right = "swaync-client -d -sw";
    };

    tray = {
      icon-size = 18;
      spacing = 8;
      show-passive-items = true;
      tooltip = false;
    };

    battery = {
      interval = 30;
      states = {
        warning = 20;
        critical = 10;
      };
      format = "${icon.battery} {capacity}%";
      format-charging = "${icon.charging} {capacity}%";
      format-plugged = "${icon.charging} {capacity}%";
      format-full = "${icon.battery} {capacity}%";
      tooltip-format = "{timeTo}";
    };

    # Waybar's native clock does not localize %a with this build's date
    # library, so use a one-process-per-second helper that delegates the
    # weekday to the system locale (LC_TIME). The helper returns JSON so the
    # tooltip can include seconds.
    "custom/clock" = {
      exec = "${clock}/bin/niri-waybar-clock";
      interval = 1;
      return-type = "json";
    };
  };

  settings = waybar.bar // {
    height = 36;

    modules-left = [
      "custom/launcher"
      "network#downspeed"
      "network#upspeed"
      "niri/workspaces"
    ];
    modules-center = [ "custom/clock" ];
    modules-right =
      [
        "cpu"
        "memory"
        "pulseaudio"
        "network#status"
        "custom/notification"
        "tray"
      ]
      ++ lib.optional hasBattery "battery";
  } // modules;
in
{
  config = lib.mkIf enabled {
    # The clock helper is referenced by absolute store path, so it does not
    # need to be in the session PATH. Only the Waybar host installs it.
    home.packages = lib.optional waybarShell clock;

    # Generate the niri profile only. The Sway profile keeps using
    # ~/.config/waybar/config.jsonc, and the niri shell unit starts this file
    # explicitly. Nothing here enables Waybar's packaged user unit.
    xdg.configFile = {
      "waybar/niri.jsonc".source =
        (pkgs.formats.json { }).generate "waybar-niri-config.json" settings;

      # Same file as the Sway profile; identical path definitions merge.
      "waybar/style.css".source = ../../../../config/waybar/style.css;
    };

    # Waybar is started explicitly by home/calendar/desktop/shell.nix through
    # a niri-bound user service. Do not add it to home.packages here: the
    # shell module owns its package and lifecycle.
  };
}
