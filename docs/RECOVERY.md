# 安装、恢复与安全边界

本文合并了首次安装、TTY/桌面恢复、网络排障、Secrets 恢复和 Restic 演练。命令默认
在目标 NixOS 上执行；标注为安装介质的命令在 Live ISO 中执行。

## 1. 首次安装前必须核对

### 1.1 磁盘、UUID、ESP 和 Windows

先确认设备型号、序列号和分区，不要凭 `/dev/sdX` 猜：

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,UUID,MOUNTPOINTS
sudo blkid
sudo efibootmgr -v          # 只查看，不要用 -B 删除启动项
```

必须逐项核对：

- 根分区 UUID、`/home` UUID、`/boot`（ESP）UUID、swap UUID 与
  `hosts/nixos/hardware-configuration.nix` 中的 `fileSystems`/`swapDevices` 一致。
- `/boot` 是 NixOS 的 vfat ESP；不要格式化 Windows 的 ESP。若两者共用 ESP，确认
  `/boot/EFI/Microsoft/Boot/bootmgfw.efi` 存在，且没有把 Windows 分区挂到
  `/boot`。
- 如果 Windows 在另一个 ESP，先确认 `boot.loader.systemd-boot.windows` 的
  `efiDeviceHandle`。这个值必须从实机 EDK2 UEFI shell 的 `map -r` 得到；不要用
  `cp -r /mnt/EFI/Microsoft ...` 之类的方式复制 Windows EFI 文件。
- Windows 若启用 BitLocker，先确认恢复密钥可用再改启动项；若使用 NTFS 数据盘，
  先在 Windows 关闭“快速启动/休眠”，不要自动挂载休眠中的 NTFS。
- 备份盘 UUID 不能使用根、`/home` 或 ESP 的 UUID；Restic 的 USB 校验会拒绝系统
  盘，但配置前仍要人工核对。

**不要执行** `mkfs`、`parted`、`sgdisk`、`dd`、`wipefs` 或任何“修复”分区的命令，
除非你已经确认设备型号、序列号和目标分区，并明确要重建那块盘。本文不提供日常
格式化 USB 的命令。

### 1.2 生成并比对 hardware-configuration.nix

在安装介质中挂载目标系统后：

```bash
sudo mount /dev/disk/by-uuid/<ROOT_UUID> /mnt
sudo mkdir -p /mnt/boot /mnt/home
sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt/boot
sudo mount /dev/disk/by-uuid/<HOME_UUID> /mnt/home
# 如果使用 swap 分区：sudo swapon /dev/disk/by-uuid/<SWAP_UUID>

sudo nixos-generate-config --root /mnt
diff -u hosts/nixos/hardware-configuration.nix \
  /mnt/etc/nixos/hardware-configuration.nix
```

btrfs 子卷必须按目标机实际布局挂载；不要假设仓库里继承的 subvol 路径正确。确认
无误后再继续。`nix build` 成功不代表这些 UUID 属于当前机器。

本机（2026-10-22 首次部署）已核对的基线，仓库中的
`hosts/nixos/hardware-configuration.nix` 与 `/etc/nixos/hardware-configuration.nix`
以及运行系统的 `/etc/fstab` 三者一致：

| 项目 | UUID / 挂载参数 |
| --- | --- |
| btrfs（`/`、`/home`、`/nix` 同一分区） | `6464e054-adce-4ade-a985-7bdfb353c1c5` |
| `/boot`（ESP，vfat） | `1421-3BC8` |
| swap | `f0378700-910f-4cbb-9576-c530ac0c5d5c` |

根分区是 btrfs 顶层子卷（不是 `subvol=@`）；`/home` 使用 `subvol=home`，`/nix`
使用 `subvol=nix`。旧仓库里曾有一份 `subvol=@` 的硬件配置，属于错误数据，已按本机
实际布局替换。更换磁盘或重装后必须重新生成并比对，不要照抄上面的 UUID。

## 2. 首次安装和首次登录

把仓库放到安装介质可访问的位置，先只构建：

```bash
cd /path/to/nixos-infra
sudo nixos-rebuild build --flake .#nixos
```

构建通过且 hardware 文件已核对后：

```bash
sudo nixos-install --flake .#nixos
```

`nixos-install` 会安装引导器，但不会替你格式化 Windows 或数据分区。安装完成后
重启，从 SDDM 选择 niri；Sway 和 Plasma 是否出现取决于
`hosts/nixos/default.nix` 中的开关。

SDDM 的 greeter 刻意运行在 X11 后端
（`services.displayManager.sddm.wayland.enable = false`）。这是本机修好鼠标/输入
问题后的稳定配置；登录后的 niri/Sway 仍然是 Wayland。不要为了“统一 Wayland”把
它改回 `true`，除非重新做过完整的登录、鼠标和键盘实机测试。

首次登录后依次检查：

1. `Mod+E` 打开 Nautilus；`inode/directory` 的默认应用是
   `org.gnome.Nautilus.desktop`。
2. Fish 中运行 `y`，退出后当前目录变成 Yazi 最后选中的目录。
3. main 的 niri 使用 Waybar + SwayNC；小主机的 niri 使用 DMS；Sway 使用
   Waybar + Mako。三套 shell 不应在同一个会话里混跑。
4. Fcitx5 能在 niri 和 Sway 中输入中文。
5. Clash Verge GUI 能启动、能导入订阅；TUN 接口和防火墙规则见第 4 节。
6. Restic 在填入真实 USB UUID 前保持关闭；启用前按第 6 节做完整演练。

age 私钥和 Restic 密码不要在首次安装时放进 Nix store。安装完成后按第 5、6 节从
离线介质安装。

## 3. TTY 恢复与桌面故障

### 3.1 进入 TTY 和查看故障

按 `Ctrl+Alt+F2`（或 F3）进入 TTY，登录后：

```bash
systemctl --failed
journalctl -b -u display-manager -u sddm --no-pager
journalctl --user -b -u niri -u dms -u fcitx5 --no-pager
loginctl list-sessions
```

如果只是图形会话坏了，SDDM 仍在运行：

```bash
sudo systemctl restart sddm
```

如果 niri 起不来，在 SDDM 中选择 Sway；Sway 不依赖 DMS，可用于下载日志、编辑
配置和重新构建。Sway 的会话初始化由：

```bash
systemctl --user status sway-session.target
```

确认。自定义 `config/sway/config` 通过 `include /etc/sway/config.d/*` 加载 NixOS
生成的 `/etc/sway/config.d/nixos.conf`，后者负责导入环境并启动/停止
`sway-session.target`。

### 3.2 回滚

```bash
nix-env -p /nix/var/nix/profiles/system --list-generations
sudo nixos-rebuild switch --rollback
sudo nixos-rebuild boot --rollback
sudo reboot
```

也可以在重启时进入 systemd-boot 菜单选择旧 generation。回滚后仍要检查
`hardware-configuration.nix` 没有被误改。

GC 注意：`nix.gc.options = "--delete-older-than 30d"` 会删除超过 30 天的 profile
generation，不只是 store 路径；删掉的 generation 不能再回滚。当前
`hosts/nixos/default.nix` 用 `nix.gc.automatic = lib.mkForce false` 暂停了首次部署
阶段的自动 GC。确认成功重启且至少有一个可用旧 generation 后，再删除该覆盖，或
手动运行：

```bash
sudo nix-collect-garbage --delete-older-than 30d
```

### 3.3 DMS、Mako、Waybar 和 Fcitx5 隔离

期望状态：

| 会话 | 应运行 | 不应运行 |
| --- | --- | --- |
| main 的 niri | Waybar、SwayNC、nm-applet、Fcitx5 | DMS、Mako |
| 小主机的 niri | DMS、Fcitx5 | Mako、Waybar |
| Sway | Waybar、Mako、Fcitx5 | DMS |

小主机的 DMS 单元由 `programs.dms-shell.systemd.target = "niri.service"` 绑定，
并且额外设置了 `partOf = [ "niri.service" ]`。main 的 Waybar/SwayNC 由
`home/calendar/desktop/shell.nix` 的 niri user units 启动。Mako 由 Sway 配置启动；
它的 D-Bus 激活文件在 Sway 之外被替换为带 `SWAYSOCK`/`WAYLAND_DISPLAY` 检查的
守卫，避免在 niri 里被通知请求自动拉起。

检查（Mako 由 Sway 直接启动，不是 systemd 用户服务）：

```bash
systemctl --user status dms.service fcitx5.service
pgrep -a -u "$USER" -f 'dms|mako|waybar|fcitx5'
```

若在 niri 中误出现 Mako，可临时停止（只影响当前用户）：

```bash
pkill -u "$USER" -x mako || true
```

若 DMS 崩溃：

```bash
systemctl --user status dms.service
systemctl --user restart dms.service
journalctl --user -b -u dms.service --no-pager
```

Fcitx5 使用 `Type=simple` 且 `ExecStart` **不带 `-d`**，由 systemd 管理前台进程，
不会因守护化而反复重启。确认：

```bash
systemctl --user status fcitx5
journalctl --user -b -u fcitx5 --no-pager
fcitx5-diagnose
```

切换桌面后应重新登录，让 graphical session target 重新建立；不要用全局
`graphical-session.target` 服务启动 DMS 或 Mako。

## 4. 网络、Clash Verge Rev 和 Tailscale

### 4.1 四个独立状态

不要把“服务起来了”“GUI 起来了”“系统代理可用”“TUN 流量可用”混为一谈：

1. **Service Mode 可用**：`systemctl status clash-verge.service` 为 active；
   `/run/clash-verge-rev/service.sock` 存在，`id -nG` 中包含 `clash-verge`。
2. **GUI 可用**：`pgrep -af clash-verge` 有进程，窗口可打开。
3. **系统代理可用**：GUI 中的系统代理开关；niri/Sway 没有 GNOME/KDE 的
   gsettings/kconfig 后端，不能把“系统代理”当成 TUN 可用。
4. **TUN 流量可用**：`ip -brief link show type tun` 出现 `Meta`，路由、DNS 和
   实际请求均正常。

Clash Verge Rev 的 NixOS 配置只负责安装 GUI、`clash-verge.service`、TUN 能力和
专用组。订阅、节点、策略和规则由 GUI 管理，不写入 Nix store。

### 4.2 Service Mode 权限

```bash
systemctl show clash-verge.service -p User -p Group -p ExecStart
ls -l /run/clash-verge-rev/service.sock
id -nG
```

服务以 root 运行，但 `Group=clash-verge`，IPC socket 权限为 `0660`，只有
`clash-verge` 组成员可访问。不要把普通用户全部加入该组；本仓库只把
`calendar` 加入。不要对 `/nix/store` 中的二进制手工 `setcap`，也不要在 GUI 中
重新运行服务安装脚本。

### 4.3 TUN、防火墙和 DNS

当前 Mihomo 核心默认 TUN 名是 `Meta`。启用 TUN 后：

```bash
ip -brief link show type tun
ip route
resolvectl status
nft list ruleset | grep -E 'Meta|clash-verge'
nft list chain inet nixos-fw rpfilter
nft list chain inet nixos-fw rpfilter-allow
```

`modules/network.nix` 只对实际 TUN 接口做最小放行：

- `trustedInterfaces` 加入 `Meta` 和 `tailscale0`；
- nftables rpfilter 链加入 `iifname "Meta" accept`；
- `checkReversePath = "loose"`（`programs.clash-verge.tunMode` 的要求）；
- NetworkManager 将 `Meta` 标记为 unmanaged。

nixpkgs issue #477636 的原因就是 TUN 被 rpfilter 和 input 链丢弃。不要通过关闭
整个防火墙解决；如果实际接口名不是 `Meta`，先确认：

```bash
ip -brief link show type tun
```

然后修改 `my.network.clashVerge.tunInterface` 并重建。TUN 不可用时先看：

```bash
journalctl -b -u clash-verge.service --no-pager
tail -n 100 ~/.local/share/io.github.clash-verge-rev.clash-verge-rev/logs/latest.log
```

DNS 边界：`systemd-resolved` 继续监听 `127.0.0.53`，NetworkManager 的 DNS 后端
是 `systemd-resolved`。Clash 的 DNS 只应劫持进入 TUN 的查询，不要把 Clash 的
nameserver 指向 `127.0.0.53`，否则会形成解析循环。检查：

```bash
readlink -f /etc/resolv.conf
resolvectl status
resolvectl query example.com
```

`/etc/resolv.conf` 应指向 systemd-resolved 的 stub 文件。若代理停止后 DNS 仍异常：

```bash
sudo systemctl restart systemd-resolved
sudo systemctl restart NetworkManager
```

### 4.4 停止代理后恢复直连

先关闭 GUI，再停止服务：

```bash
pkill -u "$USER" -x clash-verge || true
sudo systemctl stop clash-verge.service
ip route
resolvectl status
curl -I https://cache.nixos.org
```

TUN 进程退出后内核路由和接口通常会自动删除。只有在确认没有 Clash 进程、接口仍然
残留时，才考虑 `sudo ip link delete Meta`，然后重启 NetworkManager 和
systemd-resolved。不要为了让网络恢复而设置 `networking.firewall.enable = false`。

### 4.5 Tailscale 边界

默认保持：

```bash
sudo tailscale status
sudo tailscale netcheck
resolvectl query <machine>.tailnet.ts.net
ip route get 100.64.0.1
```

`my.network.tailscale.acceptDns` 和 `acceptRoutes` 默认都是 `false`，避免
MagicDNS 与 systemd-resolved/Clash DNS 争抢，也避免 subnet router 改写 TUN 的
默认路由。若必须开启 MagicDNS/subnet routes，先为 `100.64.0.0/10` 和
`*.ts.net` 在 Clash 中配置 DIRECT 规则，并检查 `resolvectl query`。不要给
`tailscaled` 设置 `HTTP_PROXY`/`HTTPS_PROXY`；只对当前命令临时设置代理环境变量。

### 4.6 直连小主机（10.77.77.0/30）

Arch 与小主机之间的有线直连不是“插线即通”：两端 `direct-nixos`/`direct-arch`
目前是 `autoconnect no`，同一网卡的自动 DHCP profile 还会抢占接口并等待 DHCP。
2026-10-27 的复现、临时恢复、持久修复建议（需授权）和 ISO 内流程见
`docs/install/ARCH_DUAL_BOOT.md` 4.3。ISO 现场只按 `START_HERE.txt` 阶段 B 执行，不要
把代理问题当成链路问题，也不要为了连通而关闭防火墙或开放 mihomo 的局域网监听。

## 5. age / SOPS 密钥恢复

age 私钥路径：

```text
/var/lib/sops-nix/keys.txt
```

安装/恢复：

```bash
sudo install -d -m 0700 /var/lib/sops-nix
sudo install -m 0600 /media/offline/age-keys.txt /var/lib/sops-nix/keys.txt
```

检查（不要打印文件内容）：

```bash
sudo test -r /var/lib/sops-nix/keys.txt && echo "age key readable"
```

编辑密文：

```bash
sops secrets/secrets.yaml
```

`sops` 只应在受控终端或编辑器中解密；不要 `cat` 密钥、不要把明文复制到聊天记录、
日志或 `/home` 后提交。`.sops.yaml` 中的 age recipient 必须与目标机私钥一致。
更换 recipient 时：

```bash
# 在确认旧私钥仍可用后
sops updatekeys secrets/secrets.yaml
```

**重要**：如果旧 age 私钥完全丢失，`sops updatekeys` 无法解密已有 `secrets.yaml`；
必须先从离线介质恢复旧私钥，或从服务提供商重新生成所有 secret。不要把旧密文删除
当作“换密钥”。

`secrets/secrets.yaml` 中仍保留旧的 `mihomo-config` 密文；它可能包含尚未迁移的
订阅信息。本仓库不再声明其 consumer（不会自动解密/加载），但**不要未经确认删除**。
需要迁移时，只在离线、受控的 `sops` 编辑环境中查看，并把订阅手动导入 Clash Verge
GUI；不要把 URL 或节点写回 `.nix`、Git 或 Nix store。

Restic 密码独立于 SOPS：

```text
/var/lib/secrets/restic-password
```

安装：

```bash
sudo install -d -m 0700 /var/lib/secrets
sudo install -m 0600 /media/offline/restic-password /var/lib/secrets/restic-password
```

Restic 恢复不要求 age key；反过来，age 私钥丢失也不应阻止读取 Restic 仓库。

## 6. USB Restic 备份、检查和恢复演练

### 6.1 安全前提

- 不要格式化、分区或“清理”任何现有 USB。先在目标机确认设备型号、序列号和 UUID。
- 备份盘 UUID 必须写入 `my.backup.usbUuid`；没有 UUID 时模块拒绝启用，service
  start 也会拒绝运行。
- 仓库初始化是显式的一次性动作 `backup-to-usb --init`，不会在找不到仓库时静默
  创建新仓库。
- 没有自动定时器；只手动备份。
- 现有约 128 GB 的旧 USB 仍保存 Arch 备份和个人数据：**不要格式化、初始化或
  覆盖它**；新仓库必须有独立介质和独立密码。
- 新仓库目录使用 `my.backup.repositoryName`（默认 `restic-nixos`），不要复用旧盘
  上的通用 `restic/`。

准备一个**已经确认内容可丢弃**的备份 USB（外部完成分区/文件系统），然后：

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,UUID
sudo mkdir -p /run/media/calendar/NIXOS-BACKUP
sudo mount /dev/disk/by-uuid/<USB_UUID> /run/media/calendar/NIXOS-BACKUP
sudo touch /run/media/calendar/NIXOS-BACKUP/.nixos-backup-target
```

在 `hosts/nixos/default.nix` 写入相同 UUID 并启用：

```nix
my.backup = {
  enable = true;
  mountPoint = "/run/media/calendar/NIXOS-BACKUP";
  repositoryName = "restic-nixos";
  usbUuid = "<USB_UUID>";
};
```

然后：

```bash
sudo nixos-rebuild switch --flake .#nixos
```

### 6.2 密码、初始化、备份

Restic 密码文件不在备份范围内，必须单独离线保存：

```bash
sudo install -d -m 0700 /var/lib/secrets
sudo install -m 0600 /media/offline/restic-password /var/lib/secrets/restic-password
```

先运行身份预检，再显式初始化一次：

```bash
sudo verify-usb-backup-target
sudo backup-to-usb --init
```

之后手动备份和查看：

```bash
sudo backup-to-usb
sudo backup-to-usb --snapshots
sudo backup-to-usb --check        # 抽取 5% 数据校验
```

也可以直接启动 systemd 服务；它同样会执行 UUID、USB、marker、密码和关键路径
校验，不会绕过检查：

```bash
sudo systemctl start restic-backups-usb.service
journalctl -b -u restic-backups-usb.service --no-pager
```

默认备份内容包括 `/home/calendar`（个人文件、项目源码、KeePassXC 数据库、
Firefox/Fcitx5/GNOME Keyring/SSH/GPG 用户状态、Clash profiles）和 root-only 的
`/var/lib/sops-nix`。可重建的缓存、`.venv`、`node_modules`、Neovim lazy/mason
插件、npm 缓存以及 Clash 的 `logs/`、`clash-verge-rev-backup/`、`update_cache/`
和 geo 数据库被排除；`.git` 和未提交源码没有被排除。任何配置的关键路径缺失都会
中止备份。Restic 密码 `/var/lib/secrets/restic-password` 不在备份内，必须单独离线
保存。

仓库目录由 `my.backup.repositoryName` 决定，默认是 `restic-nixos`，不要改成旧盘
上的通用 `restic/`。当前 `my.backup.enable = false`，且 `/var/lib/secrets` 尚不
存在；在密钥和介质准备好之前不要启用。

### 6.3 实际恢复演练

不要直接恢复到运行中的 `/`。在安装介质或另一个目录演练：

```bash
sudo mkdir -p /mnt/usb /mnt/restore
sudo mount /dev/disk/by-uuid/<USB_UUID> /mnt/usb

sudo restic -r /mnt/usb/restic-nixos --password-file /media/offline/restic-password snapshots
sudo restic -r /mnt/usb/restic-nixos --password-file /media/offline/restic-password \
  check --read-data-subset=5%

sudo restic -r /mnt/usb/restic-nixos --password-file /media/offline/restic-password \
  restore latest --target /mnt/restore

find /mnt/restore/home/calendar -maxdepth 3 -type f | head
ls -la /mnt/restore/var/lib/sops-nix
```

恢复路径会保留绝对路径（例如 `/mnt/restore/home/calendar/.config/fcitx5/profile`）。
随机挑选文件与原文件比对：

```bash
sha256sum /home/calendar/.config/fcitx5/profile
sha256sum /mnt/restore/home/calendar/.config/fcitx5/profile
```

完整检查可以定期执行（耗时更长）：

```bash
sudo restic -r /mnt/usb/restic-nixos --password-file /media/offline/restic-password \
  check --read-data
```

恢复演练必须至少验证：快照可列出、`check` 通过、关键目录可打开、文件校验和一致。
只看到 `snapshots` 列表不算完成恢复演练。

## 7. 重装 NixOS 的安全顺序

1. 先完成一次新的 Restic 备份并执行第 6.3 节的恢复演练；确认 USB 可读且密码在
   离线介质中。
2. 记录目标磁盘的型号、序列号、分区 UUID、ESP UUID 和 Windows 分区；再次确认
   没有把 Windows ESP 或数据盘当成 NixOS 目标。
3. 从安装介质启动，只挂载目标根、`/home` 和 NixOS 的 ESP。Windows 若使用独立
   ESP，不要挂载/格式化它；若共用，确认 Microsoft 目录仍在。
4. 运行 `nixos-generate-config --root /mnt`，与仓库中的
   `hosts/nixos/hardware-configuration.nix` 比对，更新 UUID 和 btrfs subvol。
5. `sudo nixos-install --flake .#nixos`。不要覆盖 Windows 分区，不要用
   `efibootmgr -B` 清理不确定的启动项。
6. 首次启动后，从离线介质恢复：
   - `/var/lib/sops-nix/keys.txt`；
   - `/var/lib/secrets/restic-password`；
   - 需要时从 Restic 恢复 home、SOPS age 目录、SSH/GPG 和 Clash Verge 数据。
7. 先验证 TTY、SDDM、niri/Sway、Fcitx5 和直连网络，再启用 Clash Verge/TUN；
   最后执行一次 `sudo backup-to-usb --snapshots` 和 `--check`。

重装不会自动恢复应用内状态；Nautilus 书签、Yazi 历史、Fcitx5 词库和 Clash Verge
订阅都依赖你自己的备份/离线材料。
