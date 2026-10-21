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
  # Declare `sops.secrets."<name>"` next to the module that consumes it. The
  # old `mihomo-config` ciphertext in secrets/secrets.yaml is intentionally
  # preserved for manual migration to Clash Verge Rev, but nothing decrypts
  # or loads it until a real consumer is added.
  sops = {
    age.keyFile = "/var/lib/sops-nix/keys.txt";
    validateSopsFiles = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sops-nix 0700 root root -"
  ];
}
