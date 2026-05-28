{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # 根分区（新安装后的 UUID）
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/09f6b90d-0a61-467e-a0cc-a8e456a17818";
    fsType = "ext4";
  };

  # 启动分区（新 /boot，UUID 已更新）
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/4878-D833";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # 家目录分区，挂载到 @home 子卷，保留原有优化选项
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

  # Windows C 盘（假设 UUID 未变，请用 lsblk -f 确认）
  fileSystems."/mnt/c" = {
    device = "/dev/disk/by-uuid/7A0C392C0C38E533";
    fsType = "ntfs3";
    options = [ "uid=1000" "gid=1000" "dmask=022" "fmask=133" ];
  };

  # Windows D 盘（假设 UUID 未变）
  fileSystems."/mnt/d" = {
    device = "/dev/disk/by-uuid/4A0EEC030EEBE5C3";
    fsType = "ntfs3";
    options = [ "uid=1000" "gid=1000" "dmask=022" "fmask=133" ];
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/762ff8bf-f013-440d-b5c4-3c2dfae695b9"; }
  ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
