{ pkgs, ... }:

{
  # Docker is enabled only on the main workstation. The mini host keeps its
  # existing configuration. Data stays in Docker's default /var/lib/docker on
  # the NixOS root subvolume; never move it to Arch's @home or the backup USB.
  virtualisation.docker = {
    enable = true;

    # Docker 29 manages nftables rules, but the NixOS docker unit's minimal
    # PATH does not include the nft CLI. Add only the tool; this does not
    # replace or disable the host's networking.nftables/firewall configuration.
    extraPackages = [ pkgs.nftables ];

    # Deliberately no "registry-mirrors". The public accelerators used here
    # (docker.1ms.run, docker.1panel.live, docker.m.ixdev.cn, hub.rat.dev,
    # docker.xuanyuan.me) now answer 401/403/404 on the manifest HEAD or hang
    # for 30s, so dockerd burned the whole pull timeout on mirrors before ever
    # reaching the real registry. Worse, dockerd re-fetches the digest-pinned
    # manifest from whichever host served the index, so a dead mirror can stall
    # the pull even after falling back. Pulls now go straight to
    # registry-1.docker.io through the daemon proxy below.
  };

  # Docker pulls images in dockerd, not in the CLI. Shell proxy variables do
  # not reach it, so give the daemon its own proxy environment. Keep localhost
  # and private/Docker/Tailscale ranges direct.
  systemd.services.docker.environment = {
    HTTP_PROXY = "http://127.0.0.1:7897";
    HTTPS_PROXY = "http://127.0.0.1:7897";
    NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,.local";
  };

  # Keep the standalone Compose v2 CLI available. Use `sudo docker compose`
  # (or `sudo docker-compose` if the CLI plugin is not discovered) instead of
  # adding the interactive user to the docker group.
  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}
