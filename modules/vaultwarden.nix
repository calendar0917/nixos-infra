# Vaultwarden: the password manager, published as vault.20050917.xyz through
# the same Cloudflare Tunnel as pi-web (see docs/UNIFIED_ACCESS.md).
#
# The workload itself is tiny (tens of MB of RAM), so it shares the laptop with
# pi-web rather than adding a machine. Data lives in /var/lib/vaultwarden and
# the module's own timer keeps a daily sqlite dump in /var/backup/vaultwarden,
# ready for whatever backup job gets settled on later.
{ config, lib, pkgs, ... }:

let
  adminSecret = "vaultwarden-admin-token";
in
{
  services.vaultwarden = {
    enable = true;

    # Clients derive their API base and WebAuthn origin from this, so it must
    # be the URL people actually type.
    domain = "vault.20050917.xyz";
    dbBackend = "sqlite_system";

    # The secret holds a whole `ADMIN_TOKEN=...` line, which is what
    # EnvironmentFile expects; the value is never rendered into the store.
    environmentFile = config.sops.secrets.${adminSecret}.path;

    # Daily sqlite dump at 23:00, kept outside the data directory.
    backupDir = "/var/backup/vaultwarden";

    config = {
      # The module default is ::1, but cloudflared reaches it over 127.0.0.1.
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;

      # cloudflared terminates TLS at the edge, so every request arrives from
      # loopback carrying the visitor's address in CF-Connecting-IP. Without
      # this, the login rate limiter would count the whole internet as one
      # client: one attacker could lock everyone else out, and per-IP limits
      # would stop meaning anything.
      IP_HEADER = "CF-Connecting-IP";

      # The one account exists, so registration is closed and stays closed.
      # Opening it again is a deliberate edit + switch, not a runtime toggle.
      # With no SMTP both signups and invitations are unavailable, which is the
      # intended state: nobody else can get in.
      SIGNUPS_ALLOWED = false;
      INVITATIONS_ALLOWED = false;
      SHOW_PASSWORD_HINT = false;

      # Vaultwarden's own login limiter, spelled out instead of relying on the
      # defaults: 10 tries per 60s per client IP, then a 60s lockout that grows
      # on repeat. SPAs on the same NAT still get their own address via
      # CF-Connecting-IP.
      LOGIN_RATELIMIT_MAX_BURST = 10;
      LOGIN_RATELIMIT_SECONDS = 60;
    };
  };

  sops.secrets.${adminSecret} = {
    owner = "vaultwarden";
    mode = "0400";
    restartUnits = [ "vaultwarden.service" ];
  };
}
