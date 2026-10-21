# 安装与首次切换

## 1. 不要先动磁盘

本仓库包含 `hosts/nixos/hardware-configuration.nix`，但它是旧仓库继承文件。用于验证
本仓库的 Arch 环境当前磁盘 UUID 与该文件不同，因此**不能把“eval/build 通过”当成
“可以直接 switch”**。在目标机安装前：

```bash
sudo nixos-generate-config --root /mnt
diff -u hosts/nixos/hardware-configuration.nix /mnt/etc/nixos/hardware-configuration.nix
```

确认根、`/home`、`/boot`、swap 和 ESP 的 UUID 与目标机一致后再继续。不要执行
`mkfs`、分区、`sgdisk`、`dd`、`wipefs` 或任何 EFI 复制/删除命令来“修好”差异。

## 2. Windows 双启动

- Windows 的 EFI 分区不要格式化，也不要挂载到 NixOS 的 `/boot`。
- 旧配置里的 `mount /dev/nvme0n1p1 /mnt && cp -r /mnt/EFI/Microsoft /boot/EFI/`
  已删除。它既脆弱又可能覆盖/递归复制 EFI 内容。
- 如果 Windows 和 NixOS 共用同一个 ESP，先确认该 ESP 上确实存在
  `/EFI/Microsoft/Boot/bootmgfw.efi`；systemd-boot 的自动探测可能已经足够。
- 如果 Windows 在另一个 ESP，使用 systemd-boot 原生选项，而不是复制文件：
  ```nix
  boot.loader.systemd-boot.windows."11" = {
    efiDeviceHandle = "HD0c1"; # 先用 UEFI shell 的 `map -r` 核实 handle
  };
  ```
  真实 handle 必须实机确认；未确认前，固件启动菜单（F12/F2）是安全回退。
- 不要使用 `efibootmgr -b ... -B` 清理不确定的启动项。
- 旧配置的 `/mnt/c`、`/mnt/d` 自动 NTFS 挂载已移除。需要读取 Windows 盘时，
  先在 Windows 里关闭“快速启动/休眠”，再手动 `udisksctl mount -b <设备>` 或
  `mount -t ntfs3`；不要加入开机自动挂载，避免休眠中的 NTFS 被写入。

## 3. 首次安装

从 NixOS 安装介质启动，联网后：

```bash
# 1. 挂载目标根分区（示例，按实际设备/UUID 调整）
sudo mount /dev/disk/by-uuid/<ROOT_UUID> /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt/boot

# 2. 生成并核对 hardware-configuration.nix
sudo nixos-generate-config --root /mnt
# 将生成结果与仓库中的 hosts/nixos/hardware-configuration.nix 对照

# 3. 把仓库放到 /mnt 可访问的位置（示例）
sudo cp -a /path/to/nixos-infra /mnt/tmp/nixos-infra

# 4. 先只构建，不写引导
cd /mnt/tmp/nixos-infra
sudo nixos-rebuild build --flake .#nixos

# 5. 安装
sudo nixos-install --flake .#nixos
```

如果使用 btrfs 子卷，必须按目标机的 subvol 布局挂载；不要假设仓库里的旧 UUID 或
子卷路径正确。

## 4. 生成与回滚

- `boot.loader.systemd-boot.configurationLimit = 20`，保留最近 20 个 generation。
- 回滚：
  ```bash
  sudo nixos-rebuild switch --rollback
  # 或重启，在 systemd-boot 菜单选择旧 generation
  ```
- 不要为了省空间把 `configurationLimit` 降得很低；升级内核/桌面后至少保留 5 个
  可用 generation。
- `nix.gc` 每周清理 30 天前的 store path，不删除 boot generation。

## 5. 首次登录后

1. 选择 niri 会话登录；确认 DMS 只在 niri 中出现。
2. 用 `niri msg outputs` 查看实际输出名。若内置屏不是 `eDP-1`，修改
   `config/niri/config.kdl` 里的 `Mod+P` / `Mod+Alt+P`。
3. 在 Fcitx5 设置中添加 Rime 或拼音，确认 `Ctrl+Space` 可用。
4. 在 Sway 会话中确认 Waybar/Fuzzel/Mako 正常；如果 niri 会话里出现 Waybar，说明
   有旧的 autostart 或全局 systemd 服务残留，应删除旧配置而不是关闭当前配置。
5. 启用 Plasma 时只改 `my.desktop.plasma.enable = true`，重新构建；不要新增全局
   显示管理器或改动 niri 的 DMS target。

## 6. 不要做的事

- 不要在未核对 hardware 文件时执行 `nixos-rebuild switch`。
- 不要执行分区、格式化、EFI 写入、真实网络切换。
- 不要把 age 私钥、Restic 密码、Mihomo 订阅放进 Nix store 或 Git。
- 不要把 DMS 设置成 `graphical-session.target` 的全局服务。
