{
  config,
  lib,
  ...
}:

{
  # The private age key lives outside the repository and outside the Nix
  # store, readable only by root. Install it with:
  #   sudo install -d -m 0700 /var/lib/sops-nix
  #   sudo install -m 0600 ~/.config/sops/age/keys.txt /var/lib/sops-nix/keys.txt
  #
  # The same key file stays in ~/.config/sops/age/keys.txt so secrets can be
  # edited with `sops` without sudo. Back that file up: without it every
  # ciphertext in secrets/secrets.yaml is unrecoverable.
  #
  # Declare `sops.secrets."<name>"` next to the module that consumes it; the
  # ciphertext lives in the default file below. Current secrets:
  #   cloudflared-tunnel-token -- consumed by hosts/main/tunnel.nix
  sops = {
    age.keyFile = "/var/lib/sops-nix/keys.txt";
    defaultSopsFile = ../secrets/secrets.yaml;
    validateSopsFiles = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sops-nix 0700 root root -"
  ];
}
