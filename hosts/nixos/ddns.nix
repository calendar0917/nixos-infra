{ pkgs, ... }:

let
  # The systemd service only needs requests; iproute2 is added to PATH for the
  # IPv6 default-route and address queries.
  python = pkgs.python3.withPackages (ps: [ ps.requests ]);
in
{
  # The directory is created by Nix. The token and zone ID are installed by the
  # administrator at runtime and are deliberately not part of any store path.
  systemd.tmpfiles.rules = [
    "d /etc/cloudflare 0700 root root -"
  ];

  systemd.services.cloudflare-ddns = {
    description = "Update the Cloudflare AAAA record for nixos.20050917.xyz";
    documentation = [ "https://github.com/calendar0917/nixos-infra/blob/main/docs/SERVER_INGRESS.md" ];

    # The timer is the only trigger. This service must not keep a loop alive,
    # and it must not delay multi-user.target when the campus network is down.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${python}/bin/python3 ${./scripts/cf-ddns.py}";
      TimeoutStartSec = 60;

      # systemd reads the root-only files and exposes private copies to the
      # DynamicUser service. The script never receives a path it can use to
      # read other root files.
      LoadCredential = [
        "token:/etc/cloudflare/token"
        "zone-id:/etc/cloudflare/zone-id"
      ];

      # Optional runtime switch between direct Cloudflare access and the
      # existing loopback Mihomo proxy. The value is checked by the script;
      # it is not a NixOS option, so changing it does not require a rebuild.
      EnvironmentFile = [ "-/etc/cloudflare/ddns.env" ];

      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      ProcSubset = "pid";
      ProtectProc = "invisible";
      RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX AF_NETLINK";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
    };

    # Missing credentials or a temporary campus-network outage should not put
    # the unit into systemd's start-limit failure state. The timer retries.
    startLimitIntervalSec = 0;
    path = [ pkgs.iproute2 ];
  };

  systemd.timers.cloudflare-ddns = {
    description = "Periodic Cloudflare IPv6 DDNS check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Unit = "cloudflare-ddns.service";
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
      RandomizedDelaySec = "45s";
    };
  };
}
