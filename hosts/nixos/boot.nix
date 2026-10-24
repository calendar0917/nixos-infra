{ ... }:

{
  # /boot is the NixOS ESP from hardware-configuration.nix. Windows keeps its
  # own ESP; nothing in this repository copies or deletes Windows EFI files.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 3;

  # If Windows and NixOS use different ESPs, systemd-boot cannot auto-detect
  # Windows. After checking the device handle from the EDK2 UEFI shell, add:
  # boot.loader.systemd-boot.windows."11".efiDeviceHandle = "HD0c1";
  # The firmware boot menu remains a safe fallback until that is verified.
}
