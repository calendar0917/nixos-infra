{ config, lib, pkgs, ... }:

let
  # Only the Python standard library is needed: the CLI never parses Compose or
  # talks to Docker. It writes a route fragment and asks Caddy to validate and
  # reload the generated Caddyfile.
  ingressctl = pkgs.writeShellScriptBin "ingressctl" ''
    # The Caddy package is installed as a service dependency, not necessarily
    # in root's PATH. Use the exact package that services.caddy runs.
    export INGRESSCTL_CADDY=${lib.getExe config.services.caddy.package}
    exec ${pkgs.python3}/bin/python3 ${./scripts/ingressctl.py} "$@"
  '';
in
{
  # The wildcard certificate is obtained with the NixOS ACME module and
  # lego's Cloudflare DNS-01 provider. No HTTP-01 listener or Caddy plugin is
  # involved. The token file is loaded as a systemd credential, so the token
  # never enters the Nix store or this generated Caddyfile.
  security.acme = {
    acceptTerms = true;

    certs."20050917.xyz" = {
      domain = "*.20050917.xyz";
      dnsProvider = "cloudflare";
      group = "caddy";
      # nixpkgs split the single dnsPropagationCheck switch into an
      # authoritative and a recursive check. Keep both enabled, which is what
      # the previous single switch did.
      dnsAuthoritativePropagationCheck = true;
      dnsRecursivePropagationCheck = true;

      credentialFiles = {
        "CLOUDFLARE_DNS_API_TOKEN_FILE" = "/etc/cloudflare/token";
      };

      # Caddy reads the renewed files from disk; this hook only reloads it.
      reloadServices = [ "caddy.service" ];
    };
  };

  # Business sites are intentionally not listed here. The NixOS-generated
  # Caddyfile imports runtime fragments from /etc/caddy/sites-enabled, so a
  # Compose service can be published or removed without nixos-rebuild.
  services.caddy = {
    enable = true;
    enableReload = true;
    globalConfig = ''
      admin 127.0.0.1:2019
    '';
    extraConfig = ''
      import /etc/caddy/sites-enabled/*.caddy

      # Keep Caddy valid and observable when no dynamic route exists yet. This
      # is loopback-only and is not opened in the firewall.
      http://127.0.0.1:2080 {
        bind 127.0.0.1
        respond /health 200
        respond 404
      }
    '';
  };

  # Only the public HTTP/HTTPS entry points are opened. Caddy's openFirewall
  # option would also open UDP 443 for HTTP/3, which this stage does not use.
  # allowedTCPPorts applies to both IPv4 and IPv6; the firewall is not
  # "IPv6-only" and this file does not claim otherwise.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  systemd.tmpfiles.rules = [
    "d /etc/caddy 0755 root root -"
    "d /etc/caddy/sites-enabled 0755 root root -"
  ];

  environment.systemPackages = [
    ingressctl
    # Also make `caddy validate`/`caddy adapt` available for manual
    # troubleshooting of the generated runtime configuration.
    pkgs.caddy
  ];
}
