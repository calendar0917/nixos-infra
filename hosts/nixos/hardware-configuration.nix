{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/a484a800-2fa9-4843-9883-5d5a93893971";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/097B-77CA";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/6d5acaf3-799a-4b27-a4e7-cbb450c3095c";
    fsType = "btrfs";
    options = [
      "subvol=@home"
      "compress=zstd:3"
      "ssd"
      "discard=async"
      "space_cache=v2"
    ];
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/762ff8bf-f013-440d-b5c4-3c2dfae695b9"; }
  ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
