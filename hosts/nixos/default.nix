{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./campus.nix
    ./proxy.nix
    ../../modules/base.nix
    ../../modules/network.nix
    ../../modules/secrets.nix
    ../../modules/backup.nix
    ../../modules/desktop/common.nix
    ../../modules/desktop/niri.nix
    ../../modules/desktop/sway.nix
    ../../modules/desktop/plasma.nix
  ];

  networking.hostName = "nixos";

  # ---------- Remote access ----------
  # Keep this block in sync with the running machine. The public key below is
  # the one already installed in /etc/ssh/authorized_keys.d/ on this host; a
  # public key is not a secret. Private keys never enter this repository.
  #
  # PasswordAuthentication is deliberately left at the NixOS default (enabled)
  # because it is the current, working login path. Verify key-only login from
  # a second terminal before disabling it; see docs/RECOVERY.md.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
      AllowUsers = [ "calendar" ];
    };
  };

  users.users.calendar.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCb+DxDxln+bDHP0A1RW3xarqom9QRhovsJdOs+2aU25Ruwj82QRtPqhjkgb93FPg0sF8p+usakMv9LAusYdCrFTSbDbU4JBvGOA+CqJExrG5ocNC6iugS6aL38M1KE+DdvAca4mpOACbXXgbf9IWeMBPAFX9v4Gqy6q+gCge+UnXvNe8LSthDkTS/j2KYaego/iElBolW/lGL+vpP0ctaEdTVqx+i+mBgjn/dn0HHiLGUyPG82JRcK7f683+6y6Qrdu8OPzQvFQ24rDXnMeW6m++dWg3FOfucQQVJU/1MP2VVnOVXF5FCxJ0FiOYg+5Pjx4ORHbAoFG01xaXMwH8atTD0OoMqv4uAJKPedsyByyCdjXXK77ctmd1e20FpCT/GhgmC4/fIrrSM7ESKRVizXrDbj8gjx9ls65TlpSl2CyccEZ+5smJpacBOm+8IxyoBI+k8SzivzQPxFa6Ybj6qlxgxQDY0aybmP7y00Jq3pcGrtL4tOZUqjKoWCR6MGF59DYw1qUF8rsOsQzsRExXfLNlLEFrvbYpnKU/fxLZIaVSEo0iH2Fr1CYFpkkUZTF7hH3ZIkxu4zmShzHqkMaAf+qsDcGJVh6J+fgo1FPR9RUKmnGSHQuqHOcUgdG6PN7gJyAfTIBQ+YhOr0M3yLEt97qlHkNpmVSPT+QuxAq9IHtQ== 1131821081@qq.com"
  ];

  # The desktop switches are deliberately independent. All enabled sessions
  # appear in SDDM and can be selected at login without rebuilding.
  my.desktop = {
    niri.enable = true;
    sway.enable = true;
    plasma.enable = false;
  };

  # The mini host is headless and no longer runs the Clash Verge GUI.
  # Mihomo (hosts/nixos/proxy.nix) owns the local 7897 proxy and is managed
  # with `proxyctl`; the shared Clash Verge module remains for main.
  my.network.clashVerge.enable = false;

  # Restic is manual-only and intentionally disabled until the real backup USB
  # UUID is known. Enable it only after setting usbUuid below; the module
  # refuses to configure the service with a null UUID.
  my.backup = {
    enable = false;
    mountPoint = "/run/media/calendar/NIXOS-BACKUP";
    repositoryName = "restic-nixos";
    usbUuid = null;
  };

  users.users.calendar = {
    isNormalUser = true;
    description = "calendar";
    shell = pkgs.fish;
    extraGroups = [
      "networkmanager"
      "wheel"
      "video"
      "render"
    ]
    ++ lib.optionals config.my.network.clashVerge.enable [ "clash-verge" ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    users.calendar = import ../../home/calendar;
  };

  # Keep automatic GC disabled until this installation has rebooted
  # successfully and at least one rollback candidate has been tested. The base
  # policy uses --delete-older-than 30d and deletes old generations; see
  # README/RECOVERY before re-enabling it.
  nix.gc.automatic = lib.mkForce false;

  # First installation version. Do not bump this when upgrading nixpkgs.
  # This machine was installed from a NixOS 26.05 image
  # (/etc/nixos/configuration.nix and system generation 1 both say 26.05).
  system.stateVersion = "26.05";
}
