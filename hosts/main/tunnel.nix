# Cloudflare Tunnel for main: publishes local services on the public
# 20050917.xyz zone without opening inbound ports or requiring the phone to
# join the tailnet. See docs/UNIFIED_ACCESS.md.
#
# Ingress rules live in the Cloudflare account (config_src=cloudflare), so the
# hostname -> local service mapping is edited in the dashboard or by API, not
# here. This module only keeps the connector running.
#
# The tunnel token is a deployment credential and must not live in the Nix
# store in plaintext. It is stored encrypted in secrets/secrets.yaml (sops,
# age) and installed to /run/secrets by sops-nix during activation; the service
# only ever sees it through systemd credentials.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  secretName = "cloudflared-tunnel-token";
in
{
  systemd.services.cloudflared-pi = {
    description = "Cloudflare Tunnel (pi.20050917.xyz)";
    documentation = [ "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/" ];

    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      DynamicUser = true;
      LoadCredential = "tunnel-token:${config.sops.secrets.${secretName}.path}";
      ExecStart = "${lib.getExe pkgs.cloudflared} tunnel run --token-file %d/tunnel-token";

      Restart = "always";
      RestartSec = 5;

      # The connector only makes outbound QUIC/HTTP2 connections to the
      # Cloudflare edge and proxies to loopback services.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
    };
  };

  sops.secrets.${secretName} = {
    mode = "0400";
    # Rotating the token should recycle the connector instead of waiting for
    # the next unrelated unit change.
    restartUnits = [ "cloudflared-pi.service" ];
  };
}
