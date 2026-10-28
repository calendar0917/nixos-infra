# Shared Waybar settings for the Sway and niri profiles.
#
# This file is plain data, not a Home Manager module: both profile modules
# import it and only differ in their compositor-specific modules. Keeping the
# shared modules here means CPU/memory/volume/network/clock/tray cannot drift
# between the two desktops.
{
  lib,
  hasBattery ? false,
}:

let
  # Geometry and modules shared by every compositor profile. `hasBattery` is
  # supplied by the profile: the laptop's niri profile enables it, while the
  # fallback Sway profile keeps its previous layout.
  bar = {
    layer = "top";
    position = "top";
    height = 34;
    spacing = 4;
  };

  modules = {
    "custom/launcher" = {
      format = "menu";
      tooltip = false;
      on-click = "fuzzel";
    };

    cpu = {
      interval = 5;
      format = "cpu {usage}%";
      tooltip = false;
    };

    memory = {
      interval = 5;
      format = "mem {percentage}%";
      tooltip = false;
    };

    pulseaudio = {
      format = "vol {volume}%";
      format-muted = "vol muted";
      on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%+";
      on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-";
      tooltip = false;
    };

    network = {
      interval = 5;
      format-wifi = "wifi {essid} {signalStrength}%";
      format-ethernet = "eth {ifname}";
      format-disconnected = "net offline";
      tooltip = false;
    };

    # Reserved for laptops. `hasBattery` decides whether it is listed in
    # modules-right; the definition itself is always available.
    battery = {
      interval = 30;
      states = {
        warning = 20;
        critical = 10;
      };
      format = "bat {capacity}%";
      format-charging = "bat {capacity}% +";
      format-plugged = "bat {capacity}% ac";
      tooltip = false;
    };

    clock = {
      interval = 30;
      format = "{:%H:%M  %m-%d}";
      tooltip-format = "{:%Y-%m-%d %H:%M:%S}";
    };

    tray = {
      spacing = 8;
    };
  };

  right =
    [ "custom/launcher" "cpu" "memory" "pulseaudio" "network" ]
    ++ lib.optional hasBattery "battery"
    ++ [ "clock" "tray" ];
in
{
  inherit bar modules right;
}
