{ pkgs, ... }:

{
  # The campus/ISP does not allow inbound IPv6, so the public IPv4 host `hw`
  # runs the existing frps instance and forwards artex traffic through an
  # outbound-only frpc tunnel. No listener or certificate is added on `hw`;
  # TLS is passed through to this host's Caddy.
  #
  # The token-bearing config and the public frps CA are runtime files under
  # /etc/frp. Only this module (the service definition) belongs in the store.
  systemd.tmpfiles.rules = [
    "d /etc/frp 0700 root root -"
  ];

  systemd.services.frpc-artex = {
    description = "frp client for artex through the hw public ingress";
    documentation = [ "https://github.com/calendar0917/nixos-infra/blob/main/docs/SERVER_INGRESS.md" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Keep retrying if /etc/frp/frpc-artex.toml has not been installed yet or
    # the public server is temporarily unreachable.
    startLimitIntervalSec = 0;

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.frp}/bin/frpc -c /etc/frp/frpc-artex.toml";
      Restart = "always";
      RestartSec = 10;

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
  };

  # Keep the client available for `frpc verify` and manual inspection; the
  # systemd unit uses the same package by absolute store path.
  environment.systemPackages = [ pkgs.frp ];
}
