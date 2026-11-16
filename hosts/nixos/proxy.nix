{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Stable entry point for profile imports, validation and rollback. The
  # script is public code; all profiles, URLs and secrets stay in /etc/mihomo.
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  # Geodata is pinned in the store and seeded into the private state directory
  # before Mihomo starts. This keeps geodata-mode profiles usable without a
  # first-run download, which is unavailable on an unauthenticated network.
  geosite = "${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat";
  geoip = "${pkgs.v2ray-geoip}/share/v2ray/geoip.dat";

  proxyctl = pkgs.writeShellScriptBin "proxyctl" ''
    export PROXYCTL_MIHOMO=${lib.getExe config.services.mihomo.package}
    export PROXYCTL_GEOSITE=${geosite}
    export PROXYCTL_GEOIP=${geoip}
    exec ${python}/bin/python3 ${./scripts/proxyctl.py} "$@"
  '';
in
{
  # Services and the local CLI run without a graphical login. Mihomo owns only
  # loopback ports; TUN/TProxy/redir stay disabled and no firewall port is
  # opened for 7897 or 9090.
  services.mihomo = {
    enable = true;
    configFile = "/etc/mihomo/active.yaml";
    tunMode = false;
  };

  systemd.tmpfiles.rules = [
    "d /etc/mihomo 0700 root root -"
    "d /etc/mihomo/profiles 0700 root root -"
    "d /etc/mihomo/sources 0700 root root -"
  ];

  systemd.services.mihomo = {
    # The upstream module already loads the runtime file through
    # LoadCredential and persists providers/rules in StateDirectory. Add only
    # restart and permission policy here.
    startLimitIntervalSec = 0;
    preStart = ''
      install -m 0644 ${geosite} "''${STATE_DIRECTORY}/GeoSite.dat"
      install -m 0644 ${geoip} "''${STATE_DIRECTORY}/GeoIP.dat"
    '';
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 10;
      StateDirectoryMode = "0700";
    };
  };

  environment.systemPackages = [
    proxyctl
  ];
}
