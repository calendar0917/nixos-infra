{ pkgs, ... }:

{
  # Docker is local-only: the NixOS module keeps the API on the systemd Unix
  # socket, and no user is added to the docker group. Manage containers with
  # `sudo docker compose` from the deploy/ directory.
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;

    # Docker 29 manages nftables rules, but the NixOS docker unit's minimal
    # PATH does not include the nft CLI. Match main's compatibility setting;
    # do not switch the firewall backend or disable the NixOS firewall.
    extraPackages = [ pkgs.nftables ];

    # Use bounded local JSON logs instead of unbounded journald container logs.
    # The module's default is journald; the container-level Compose config also
    # sets the same limits.
    logDriver = "json-file";
    daemon.settings = {
      log-opts = {
        "max-size" = "10m";
        "max-file" = "3";
      };
    };
  };

  # dockerd, not the compose CLI, performs image pulls. Keep the proxy scoped
  # to the daemon and send private/Tailscale ranges directly. There is no
  # Requires/After on mihomo: Docker must still start and run existing images if
  # the proxy is unavailable.
  systemd.services.docker.environment = {
    HTTP_PROXY = "http://127.0.0.1:7897";
    HTTPS_PROXY = "http://127.0.0.1:7897";
    NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,.local";
  };

  environment.systemPackages = with pkgs; [
    docker-compose
    # Used by the Rakazo computer egress ruleset and its systemd unit.
    iptables
    # Used by the published-images installer when it generates secrets.
    openssl
  ];

  # Compose files normally live in Git; runtime bind mounts live here. Only the shared
  # root is created here. Each service owns its UID/GID and subdirectories;
  # never recursively chown existing application data from this module.
  systemd.tmpfiles.rules = [
    "d /srv/containers 0755 root root -"
  ];
}
