{
  pkgs,
  ...
}:

let
  # Keep requests inside a pinned Python environment. The service never
  # invokes pip, uv, a login shell or anything from /home/calendar.
  python = pkgs.python3.withPackages (ps: [ ps.requests ]);
in
{
  # Credentials are installed by the administrator, not by Nix. They are
  # root-only runtime files and are never copied into the Nix store. The
  # directory itself may be created here; the files deliberately are not.
  systemd.tmpfiles.rules = [
    "d /etc/campus-network 0700 root root -"
  ];

  systemd.services.campus-login = {
    description = "Ruijie campus network login and keep-alive";
    documentation = [ "https://github.com/calendar0917/nixos-infra/blob/main/docs/SERVER_NETWORK.md" ];

    wantedBy = [ "multi-user.target" ];

    # Start after NetworkManager has started, but never require campus
    # authentication or Internet connectivity to succeed first. The daemon
    # polls and retries on its own after link changes.
    wants = [ "NetworkManager.service" ];
    after = [ "NetworkManager.service" ];

    # The long-running daemon performs the keep-alive loop itself. There is no
    # timer, so a link loss is noticed on the next normal check interval.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${python}/bin/python3 ${./scripts/campus-login.py} --daemon";
      Restart = "always";
      RestartSec = 15;

      LoadCredential = [
        "username:/etc/campus-network/username"
        "password:/etc/campus-network/password"
      ];

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
      RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
    };

    # Missing credentials are a configuration error, not a reason to enter
    # systemd's start-limit failure state. Retry so installing the files is
    # enough to recover without a manual reset-failed.
    startLimitIntervalSec = 0;
  };
}
