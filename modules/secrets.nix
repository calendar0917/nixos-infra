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
  # `sops` secrets are declared where they are consumed (e.g. mihomo in
  # modules/network.nix), so a build without that feature needs no key.
  sops = {
    age.keyFile = "/var/lib/sops-nix/keys.txt";
    validateSopsFiles = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sops-nix 0700 root root -"
  ];
}
