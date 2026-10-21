# 日常构建、恢复与备份

## 1. 构建与切换

在仓库根目录：

```bash
nix flake show
nix flake check
nix eval .#nixosConfigurations.nixos.config.system.build.toplevel.drvPath
nix build .#nixosConfigurations.nixos.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#nixos
```

`nix build` 只构建，不激活；`nixos-rebuild switch` 才会改系统。切换前先确认
`hosts/nixos/hardware-configuration.nix` 与目标机一致。

## 2. 图形界面失败时（TTY 恢复）

按 `Ctrl+Alt+F2` 进入 TTY，登录后：

```bash
# 看本次启动失败的单元
systemctl --failed
journalctl -b -u display-manager -u sddm -u niri -u dms --no-pager

# 回到上一个 NixOS generation
sudo nixos-rebuild switch --rollback

# 或直接重启并在 systemd-boot 菜单选择旧 generation
sudo reboot
```

如果只是 DMS 崩溃：

```bash
systemctl --user status dms.service
systemctl --user restart dms.service
journalctl --user -b -u dms.service --no-pager
```

如果 niri 起不来，可以在 SDDM 选择 Sway 会话；Sway 不依赖 DMS，可用于下载日志、
编辑配置和重新构建。

## 3. Mihomo / 网络排障

Mihomo 故障时不要关闭整个防火墙，也不要把系统切成“无防火墙”状态。先停掉代理
服务，保留 SSH/本地登录和直连网络：

```bash
systemctl status mihomo --no-pager
journalctl -b -u mihomo --no-pager

# 临时停止，不删除配置
sudo systemctl stop mihomo

# 确认直连 DNS 和路由
resolvectl status
ip route
curl -I https://cache.nixos.org
```

如果 Tailscale 与 Mihomo 冲突：

```bash
sudo tailscale status
sudo tailscale netcheck

# 只停客户端，不动防火墙
sudo systemctl stop tailscaled
```

本配置没有给 `tailscaled` 设置 `HTTP_PROXY/HTTPS_PROXY`，Tailscale 流量不应经过
Mihomo 的 HTTP 代理。Mihomo 的 TUN 配置在 SOPS secret 中，需确认它不会在宿主
网络命名空间抢占 `:53`；推荐让 `systemd-resolved` 继续监听 `127.0.0.53:53`，让
Mihomo 只做 TUN 内的 DNS hijack。

临时下载需要代理时，只对当前命令设置环境变量，不要写进 `tailscaled`：

```bash
https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 \
  curl -I https://github.com
```

防火墙保持：

```bash
sudo systemctl status firewall.service   # 若你的 NixOS 版本使用该 unit
sudo nft list ruleset | head
```

不要用 `networking.firewall.enable = false` 作为排障手段；本仓库没有这个设置。

## 4. Restic USB 备份（手动）

备份盘只在手动执行时挂载。以下操作在目标 NixOS 上执行，不要在本验证环境执行真实
备份。

### 4.1 首次准备

```bash
# 示例设备名；先 lsblk 确认，绝不能选错盘
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
sudo mkfs.ext4 -L NIXOS-BACKUP /dev/sdX1

sudo mkdir -p /run/media/calendar/NIXOS-BACKUP
sudo mount /dev/disk/by-uuid/<USB_UUID> /run/media/calendar/NIXOS-BACKUP
sudo touch /run/media/calendar/NIXOS-BACKUP/.nixos-backup-target
```

把真实 UUID 写到 `hosts/nixos/default.nix` 的 `my.backup.usbUuid`；这样即使另一个
磁盘恰好挂到同一路径，wrapper 也会拒绝。

### 4.2 密码

```bash
sudo install -d -m 0700 /var/lib/secrets
sudo install -m 0600 /offline/media/restic-password /var/lib/secrets/restic-password
```

该密码不能依赖 SOPS。恢复时即使 age key 丢失，也能先取回备份。

### 4.3 执行与验证

```bash
# 首次会初始化 <USB>/restic 仓库，然后运行 oneshot 服务
sudo backup-to-usb

# 只查看快照
sudo backup-to-usb --snapshots

# 抽样校验（会读取一部分数据）
sudo backup-to-usb --check
```

`backup-to-usb` 会验证：

- 目标确实是 mount point；
- 底层设备是 USB/可移动设备；
- 不是根文件系统所在磁盘；
- 存在 `.nixos-backup-target`；
- 若配置了 UUID，UUID 必须匹配；
- `/var/lib/secrets/restic-password` 可读。

`services.restic.backups.usb.timerConfig = null`，没有定时器；只有手动启动才会备份。

默认包含：

- `/home/calendar/life`
- `/home/calendar/code/nixos-infra`
- `/var/lib/sops-nix`
- `/home/calendar/.config/sops/age`
- `/home/calendar/.ssh`
- `/home/calendar/.gnupg`
- `/home/calendar/.local/share/keyrings`

排除项只有缓存和构建目录（`.cache`、`.direnv`、`.venv`、`node_modules` 等）；
**没有**排除 `life`、`code`、`.git` 或整个仓库。若新增重要路径，必须审查
`modules/backup.nix` 的 `paths`。

## 5. 从 USB 恢复（不依赖 SOPS）

在 NixOS installer 或任意有 restic 的 Linux 上：

```bash
sudo mkdir -p /mnt/usb /mnt/restore
sudo mount /dev/disk/by-uuid/<USB_UUID> /mnt/usb

# 密码从离线介质读取，不要从待恢复的系统读取
sudo restic -r /mnt/usb/restic --password-file /offline/media/restic-password snapshots
sudo restic -r /mnt/usb/restic --password-file /offline/media/restic-password \
  restore latest --target /mnt/restore
```

恢复后按需复制：

- `life/`、`code/` 回家目录；
- `.ssh/`、`.gnupg/`、keyrings；
- `/var/lib/sops-nix/keys.txt` 从离线介质恢复（不是从 restic 仓库单独解密）；
- `secrets/secrets.yaml` 在仓库中本来就是密文，恢复后仍需 age key 才能解密。

如果系统已经重装，先安装 NixOS 基础系统，再恢复 home 数据；不要直接覆盖新系统的
`/etc` 或 `/boot`。

## 6. 重装后的顺序

1. 安装 NixOS（`nixos-install --flake .#nixos`），不要格式化 Windows 分区。
2. 从离线介质恢复 age 私钥到 `/var/lib/sops-nix/keys.txt`。
3. 从离线介质恢复 Restic 密码到 `/var/lib/secrets/restic-password`。
4. 首次登录后恢复 home 数据；再挂载 USB 执行 `sudo backup-to-usb --snapshots` 验证
   仓库可读。
5. 最后再启用 Mihomo；首次启用前用直连网络确认系统可以构建和登录。
