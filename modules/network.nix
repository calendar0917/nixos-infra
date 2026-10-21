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
          Tailscale cannot silently override routes that the local proxy needs.
        '';
      };

      acceptDns = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let Tailscale manage DNS through systemd-resolved. Disabled by
          default: systemd-resolved remains the single DNS owner, avoiding a
          second resolver and a possible Clash Verge TUN DNS loop.
        '';
      };
    };

    clashVerge = {
      enable = lib.mkEnableOption "Clash Verge Rev GUI proxy";

      tunInterface = lib.mkOption {
        type = lib.types.str;
        default = "Meta";
        description = ''
          Linux TUN interface name created by the bundled Mihomo core. The
          current package defaults to `Meta`; verify with
          `ip -brief link show type tun` after enabling TUN in the GUI. The
          firewall trusts only this interface, so change this option if the
          GUI or a profile overrides `tun.device`.
        '';
      };
    };
  };

  config = {
    # NetworkManager owns interfaces and Wi-Fi/Ethernet profiles. systemd-
    # resolved is the only local DNS stub; the proxy must not bind the host
    # port 53.
    networking.networkmanager.enable = true;
    networking.networkmanager.dns = "systemd-resolved";

    services.resolved = {
      enable = true;
      settings.Resolve = {
        FallbackDNS = [ "223.5.5.5" "119.29.29.29" ];
        DNSSEC = "allow-downgrade";
      };
    };

    # Keep one firewall implementation so the narrow TUN exceptions below use
    # the same nftables ruleset that protects the rest of the host. The
    # firewall itself is never disabled.
    networking.nftables.enable = true;
    networking.firewall.enable = true;

    networking.firewall.trustedInterfaces =
      lib.optionals cfg.tailscale.enable [ "tailscale0" ]
      ++ lib.optionals cfg.clashVerge.enable [ cfg.clashVerge.tunInterface ];

    # nixpkgs issue #477636: TUN packets are dropped by the nftables rpfilter
    # chain and input chain unless the TUN interface is explicitly trusted.
    # Keep the exception limited to the single interface created by Clash
    # Verge's bundled Mihomo core.
    networking.firewall.extraReversePathFilterRules = lib.mkIf cfg.clashVerge.enable ''
      iifname "${cfg.clashVerge.tunInterface}" accept comment "clash-verge tun"
    '';

    # programs.clash-verge.tunMode requires this; do not set `false`, which
    # would disable reverse-path filtering for every interface.
    networking.firewall.checkReversePath = lib.mkIf cfg.clashVerge.enable "loose";

    # Do not let NetworkManager try to manage the TUN device.
    networking.networkmanager.unmanaged = lib.mkIf cfg.clashVerge.enable [
      "interface-name:${cfg.clashVerge.tunInterface}"
    ];

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

    # Clash Verge Rev is a GUI application. NixOS installs the package and the
    # privileged service; subscriptions, profiles, nodes and rules are managed
    # by the GUI under the user's data directory, not by this file.
    programs.clash-verge = lib.mkIf cfg.clashVerge.enable {
      enable = true;
      package = pkgs.clash-verge-rev;
      serviceMode = true;
      tunMode = true;
      autoStart = true;
      group = "clash-verge";
    };

    # Dedicated group for the service-mode IPC socket. The host adds only the
    # interactive user to this group; ordinary users get no access.
    users.groups.clash-verge = lib.mkIf cfg.clashVerge.enable { };

    systemd.services.clash-verge.serviceConfig = lib.mkIf cfg.clashVerge.enable {
      RuntimeDirectoryMode = "0750";
    };
  };
}
