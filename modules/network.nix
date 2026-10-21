{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.network;
in
{
  options.my.network = {
    tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the Tailscale client daemon.";
      };

      authKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional runtime auth key file. When null, run `sudo tailscale up`
          once after installation. Do not put an auth key in the Nix store.
        '';
      };

      acceptRoutes = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Accept subnet routes advertised by Tailscale. Disabled by default so
          Tailscale cannot silently override routes that Mihomo needs.
        '';
      };

      acceptDns = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let Tailscale manage DNS through systemd-resolved. Disabled by
          default: systemd-resolved remains the single DNS owner, avoiding a
          second resolver and a possible Mihomo TUN DNS loop.
        '';
      };
    };

    mihomo = {
      enable = lib.mkEnableOption "Mihomo system proxy with TUN mode";

      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional override for the Mihomo config. By default the SOPS secret
          `mihomo-config` is used and is never copied into the Nix store.
        '';
      };

      webui = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the metacubexd web UI for the local controller.";
      };
    };
  };

  config = {
    # NetworkManager owns interfaces and Wi-Fi/Ethernet profiles. systemd-
    # resolved is the only local DNS stub; Tailscale and Mihomo must not bind
    # port 53 on the same addresses.
    networking.networkmanager.enable = true;
    networking.networkmanager.dns = "systemd-resolved";

    services.resolved = {
      enable = true;
      settings.Resolve = {
        FallbackDNS = [ "223.5.5.5" "119.29.29.29" ];
        DNSSEC = "allow-downgrade";
      };
    };

    # The host firewall stays enabled. Tailscale traffic is trusted on its own
    # interface; no global firewall bypass is needed.
    networking.firewall.enable = true;
    networking.firewall.trustedInterfaces = lib.mkIf cfg.tailscale.enable [ "tailscale0" ];

    services.tailscale = lib.mkIf cfg.tailscale.enable {
      enable = true;
      useRoutingFeatures = "client";
      openFirewall = true;
      authKeyFile = cfg.tailscale.authKeyFile;
      extraUpFlags =
        [ "--accept-dns=${if cfg.tailscale.acceptDns then "true" else "false"}" ]
        ++ lib.optionals cfg.tailscale.acceptRoutes [ "--accept-routes=true" ]
        ++ lib.optionals (!cfg.tailscale.acceptRoutes) [ "--accept-routes=false" ];
    };

    # Mihomo is opt-in: it needs a real subscription and an age key. Keeping
    # it disabled leaves a fully usable direct network for builds and rescue.
    services.mihomo = lib.mkIf cfg.mihomo.enable {
      enable = true;
      tunMode = true;
      configFile =
        if cfg.mihomo.configFile != null
        then cfg.mihomo.configFile
        else config.sops.secrets."mihomo-config".path;
      webui = if cfg.mihomo.webui then pkgs.metacubexd else null;
    };

    sops.secrets."mihomo-config" = lib.mkIf (cfg.mihomo.enable && cfg.mihomo.configFile == null) {
      sopsFile = ../secrets/secrets.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "mihomo.service" ];
    };
  };
}
