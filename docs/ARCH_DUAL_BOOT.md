# Arch 主力机 NixOS 双系统安装手册

本文是 **Arch 主力机** 的安装操作手册，不是通用教程。目标是在现有 Btrfs
文件系统中新增独立 NixOS，同时原样保留 Arch、Arch Home、Snapper 快照和 Arch
UKI；两套系统共享现有 1 GiB ESP，默认仍启动 Arch。

> **本轮状态（2026-10-24）**
>
> - 已完成只读硬件/启动检查、仓库 host 拆分和安装方案。
> - **没有**创建或删除 Btrfs 子卷，**没有**挂载安装目标，**没有**格式化，**没有**
>   写 `/boot`、`loader.conf`、UKI 或 EFI NVRAM，**没有**运行 `nixos-install`，
>   **没有**重启、GC、Restic 写入或自动 push。
> - 文中的 `<BTRFS_UUID>`、`<ESP_UUID>`、`<NVME>`、`<REPO>` 等占位符必须在
>   当前机器上用只读命令确认后替换。**不要把完整 UUID、磁盘序列号或本文的私有机
>   密清单提交到公开仓库/聊天记录。**
> - 所有会修改磁盘、子卷、ESP 或 NVRAM 的命令都标注了
>   **【需要用户二次授权】**。没有授权时只执行只读检查。

---

## 0. 结论与边界

### 0.1 可行性结论

这台机器支持“同一个 Btrfs 文件系统内新增 NixOS，同时保留 Arch”的方案：

- 单块 NVMe、GPT、一个 1 GiB ESP、一个约 952.9 GiB 的 Btrfs 分区。
- Btrfs 顶层已有 `@`、`@home`、`@log`、`@pkg`，默认子卷是 ID 5，Arch 根使用
  `subvol=@`。没有同名冲突，也没有 LUKS。
- 空闲空间约 **633.4 GiB**，ESP 空闲约 **914 MiB**；NixOS 当前闭包约
  **9.5 GiB**，单代 kernel+initrd 约 **43 MiB**。
- Secure Boot 已关闭，Arch UKI 未签名；NixOS 不需要签名即可启动。
- 现有 systemd-boot 的 NVRAM 入口指向共享 ESP 上的
  `/EFI/systemd/systemd-bootx64.efi`，安装 NixOS 后仍可复用。
- Arch 的 UKI 自带 kernel、initramfs 和 cmdline，是独立的 Type #2 启动项；
  NixOS 的 Type #1 条目不会覆盖它。

**关键风险**不是“格式化 ESP”，而是：

1. 挂错 Btrfs 子卷，把 NixOS 装进 `@`；
2. NixOS 的 systemd-boot 安装改写 `loader.conf`，把默认项改成 NixOS；
3. NixOS 的 systemd-boot 二进制替换 Arch 的版本，损坏时 Arch 也无法通过同一
   入口启动；
4. ESP 被 NixOS 多代 kernel/initrd 占满。

本方案分别用“安装前核对 findmnt”“host 级 `extraInstallCommands` 固定 Arch
默认项”“完整 ESP 备份+可恢复演练”“`configurationLimit = 3`”处理这四点。

### 0.2 本轮已经完成 / 没有完成

已经完成：

- 只读检查了 `lsblk -f`、`findmnt`、`blkid`、Btrfs 顶层和子卷、快照、挂载参数、
  Arch UKI、`bootctl status/list`、EFI NVRAM、Secure Boot、CPU/GPU/网卡/蓝牙/无线、
  UID/GID、磁盘和 ESP 可用空间。
- 把原先在 `modules/base.nix` 中的 systemd-boot 配置拆到
  `hosts/nixos/boot.nix`，小主机行为保持不变。
- 新增 `hosts/main/` 骨架和 `hosts/main/boot.nix`。
- `flake.nix` 已准备 `nixosConfigurations.main`，但只在真实
  `hosts/main/hardware-configuration.nix` 存在时才暴露；现在没有该文件，因此
  **main 还不能求值，这是故意的**。
- `nix flake check` 通过；`nixos-rebuild build --flake .#nixos` 通过。

没有完成（本轮禁止）：

- 没有运行 `nixos-generate-config`，没有生成/提交 `hosts/main/hardware-configuration.nix`。
  没有编造 UUID、subvol、swap 或 CPU 声明。
- 没有创建 `@nixos`、`@nixos-home`、`@nixos-nix`。
- 没有把 ESP 备份到小主机（只给出了方法和恢复验证步骤）。
- 没有安装、没有设置密码、没有重启。

### 0.3 真正安装前需要用户二次授权的操作

以下每一项都必须单独确认后再执行：

1. 向 U 盘写 NixOS ISO（会覆盖该 U 盘）。
2. 在 Btrfs 顶层创建三个 `@nixos*` 子卷。
3. 挂载 `/mnt`、`/mnt/home`、`/mnt/nix`、`/mnt/boot` 作为安装目标。
4. 运行 `nixos-install --flake .#main`。
5. 让 NixOS 的 bootloader 步骤写共享 ESP（会更新 systemd-boot 二进制和
   `loader.conf`）。
6. 如需恢复默认启动项，编辑 `loader.conf` 或写 `efibootmgr`。
7. 任何 ESP 恢复、`bootctl install`、`efibootmgr -c/-o/-B`。

**没有第 4 项授权，不要运行 `nixos-install`。**

---

## 1. 真实硬件与启动状态（本次只读检查）

以下数值来自当前 Arch 会话；完整 UUID、序列号、PARTUUID 只保存在私有清单中，
不写入本文。

### 1.1 主机与硬件

| 项目 | 检查结果 |
| --- | --- |
| 系统 | Arch Linux，内核 `6.18.57-2-lts`，UEFI |
| 主机角色 | Arch 主力机（笔记本），有电池 `BAT1` |
| CPU | AMD Ryzen 7 8845H，8 核 16 线程，AMD-V |
| GPU | AMD Radeon 780M，`amdgpu` |
| 有线网卡 | Realtek RTL8111/8168/8211/8411，`r8169` |
| 无线网卡 | Realtek RTL8852BE，`rtw89_8852be` |
| 蓝牙 | `hci0` 存在；Arch 当前 rfkill soft blocked |
| 内存 | 约 27 GiB 可见 |
| 用户 | `calendar`，UID 1000，GID 1000；主组 `calendar` gid 1000 |
| 附加组 | `wheel` 998、`docker` 964、`video` 983、`render` 987（Arch 实际 GID） |

NixOS 的 `main` host 已显式设置 `uid = 1000`、`group = "calendar"`、
`users.groups.calendar.gid = 1000`。**不要**照抄小主机的 `group = "users"`
（gid 100），否则 NixOS 用户无法读取 Arch 的 0700 家目录。

### 1.2 磁盘和文件系统

| 项目 | 检查结果 |
| --- | --- |
| 磁盘 | 单块 NVMe，约 953.9 GiB，GPT，无 LUKS |
| ESP | 分区 1，1 GiB，vfat/FAT32，挂载 `/boot`，已用约 109 MiB，空闲约 914 MiB |
| Btrfs | 分区 2，约 952.9 GiB，已用约 319 GiB，空闲约 633.4 GiB |
| Btrfs 顶层 | 默认子卷 ID 5（FS_TREE）；`@`、`@home`、`@log`、`@pkg` |
| 嵌套子卷 | `@/var/lib/portables`、`@/var/lib/machines`、`@/.snapshots`、`@home/.snapshots` |
| Arch 根 | `subvol=@`，`rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2` |
| Arch Home | `subvol=@home`，同上 |
| Arch `/var/log` | `subvol=@log` |
| Arch pacman 缓存 | `subvol=@pkg` |
| ESP 挂载 | `rw,relatime,fmask=0077,dmask=0077` |
| Windows | 没有物理 Windows 分区；Windows 是 Docker VM |

本次检查没有发现 `@nixos`、`@nixos-home`、`@nixos-nix`，也没有同名冲突。

### 1.3 Snapper 快照

- `snapper list-configs`：`root`（`/`）和 `home`（`/home`）。
- `snapper-timeline.timer`、`snapper-cleanup.timer` 正常存在。
- 检查时 root/home 最新快照编号为 **1133**；`@/.snapshots` 和
  `@home/.snapshots` 中有大量历史快照。
- 本轮没有创建、删除、修改任何快照，也没有改 Snapper 配置。
- 新增的 `@nixos*` 是顶层兄弟子卷，不会被 Snapper 的 `root`/`home` 配置自动
  快照；这是预期行为，不代表 NixOS 数据受 Arch Snapper 保护。

### 1.4 启动链

| 项目 | 检查结果 |
| --- | --- |
| 固件 | UEFI 2.90，INSYDE |
| Secure Boot | **disabled** |
| TPM2 | 支持，Measured UKI/OS 已启用 |
| systemd-boot | 261.2-1-arch |
| 主引导文件 | `/boot/EFI/systemd/systemd-bootx64.efi` |
| 回退引导文件 | `/boot/EFI/BOOT/BOOTX64.EFI` |
| Arch UKI | `/boot/EFI/Linux/arch-linux-lts.efi`，约 60 MiB |
| UKI cmdline | `root=PARTUUID=... zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs` |
| loader entries | `/boot/loader/entries/` 为空；Arch 使用 Type #2 UKI 自动发现 |
| `loader.conf` | `timeout 3`、`#console-mode keep`；没有 `default` 行 |
| 当前默认项 | `arch-linux-lts.efi`（菜单中唯一可启动项） |
| NVRAM | `Boot0005* Linux Boot Manager` 指向共享 ESP；BootOrder 以 0005 开头 |
| 其他 NVRAM | 0000 硬盘、2001 USB、2002 DVD、2003 网络 |
| ESP 厂商文件 | `/boot/EFI/Lenovo/BIOS/SelfHealing.fd`，约 32 MiB，**不要删除** |
| UKI 签名 | PE security directory 为 0；未使用 sbctl/sbsign，Secure Boot 关闭 |

**重要**：当前 `loader.conf` 没有 `default`，所以 Arch 只是“唯一项”而不是被显式
固定。NixOS 的 builder 会写入 `default nixos-*`（或 `preferred ...`），因此安装
后默认项**会**变成 NixOS，除非 host 配置里的 `extraInstallCommands` 把 Arch 放
回去。`hosts/main/boot.nix` 已经包含这个 hook；安装时仍必须人工核对。

### 1.5 空间和 NixOS 闭包参考

- Btrfs 空闲 **633.4 GiB**；ESP 空闲 **914 MiB**。
- 当前 `nixosConfigurations.nixos` 构建出的闭包约 **9.5 GiB**。
- 单代 NixOS kernel 约 **14 MiB**、initrd 约 **29 MiB**，合计约 **43 MiB**。
- `configurationLimit = 3` 时 NixOS boot 文件约 **130 MiB**，加上 systemd-boot、
  loader entries 和临时文件，预留 200–300 MiB 足够；ESP 仍有约 600 MiB 余量。

---

## 2. 目标布局

### 2.1 子卷规划

| 子卷 | 挂载点 | 内容 | 是否新建 |
| --- | --- | --- | --- |
| `@` | Arch `/` | Arch 根 | 否，保持 |
| `@home` | Arch `/home` | Arch 家目录、科研/个人数据 | 否，保持 |
| `@log` | Arch `/var/log` | Arch 日志 | 否，保持 |
| `@pkg` | Arch pacman 缓存 | Arch 包缓存 | 否，保持 |
| `@nixos` | NixOS `/` | NixOS 根 | **是** |
| `@nixos-home` | NixOS `/home` | NixOS 独立家目录 | **是** |
| `@nixos-nix` | NixOS `/nix` | NixOS store | **是** |

不重新分区，不格式化 Btrfs，不格式化 ESP，不修改 Btrfs 默认子卷。

### 2.2 安装环境挂载表

| 安装环境路径 | 应挂载 | 绝对不能挂载 |
| --- | --- | --- |
| `/mnt` | `subvol=@nixos` | `@`、`@home`、`@nixos-home` |
| `/mnt/home` | `subvol=@nixos-home` | `@home` |
| `/mnt/nix` | `subvol=@nixos-nix` | Arch 的 `@` 内 `/nix` |
| `/mnt/boot` | 现有 ESP | 新建 vfat、Btrfs 目录、其他分区 |
| `/mnt/mnt/arch-home` | **安装时不要挂载** | `@home` |
| NixOS 运行后的 `/mnt/arch-home` | `subvol=@home`，`ro` | 读写 `@home` |

### 2.3 为什么不能从 `/` 直接创建子卷

当前 `/` 已经是 `subvol=@`。如果在 `/` 下执行
`btrfs subvolume create /@nixos`，会得到嵌套的 `@/@nixos`，而不是顶层
`@nixos`。正确方法是临时挂载 **`subvolid=5` 顶层**，在顶层目录下创建：

```text
/mnt/btrfs-root/@nixos
/mnt/btrfs-root/@nixos-home
/mnt/btrfs-root/@nixos-nix
```

创建后必须卸载顶层挂载，不要把它留在 `/mnt/btrfs-root`。不要执行
`btrfs subvolume set-default`。

---

## 3. 安装前准备

### 3.1 已选定的安装介质（Ventoy + NixOS 26.05 Minimal）

本轮不再下载 ISO。已存在的 Ventoy 启动盘（普通数据分区，exFAT）中已经放好：

| 项目 | 值 |
| --- | --- |
| 文件 | `<VENTOY>/latest-nixos-minimal-x86_64-linux.iso` |
| 卷标 | `nixos-minimal-26.05-x86_64` |
| ISO `version.txt` | `26.05.12400.da6dc0e7b260` |
| 大小 | 1744830464 字节（约 1.63 GiB） |
| SHA256 | `bace94cc43946a95c6252b097cf627dbca6ec4b48d938d405c1043b0a2f0cffb` |
| 官方校验值 | `https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso.sha256` 返回同一 SHA256 |

**为什么是 26.05 而不是 flake 锁定的 26.11 pre**：`system.stateVersion` 取的是
“首次安装时所用介质的发行版本”，与 `flake.lock` 里 nixpkgs 的版本无关。这个
ISO 的 `nixos-generate-config` 写出的就是 `26.05`，因此 `hosts/main/default.nix`
也固定为 `26.05`。升级 nixpkgs 不改变 stateVersion。

重新校验（只读，随时可做）：

```bash
sha256sum <VENTOY>/latest-nixos-minimal-x86_64-linux.iso
curl -fsSL https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso.sha256
# 两行哈希必须一致；官方文件第二列是文件名，不需要匹配本地文件名
```

如果官方渠道之后发布了更新的 26.05 构建，SHA256 会变；此时要么重新下载并用新
哈希校验，要么**保留现在这个已验证的文件不动**。不要用未校验的 ISO 安装。

Ventoy 使用方式（不需要 `dd`、不需要重装 Ventoy）：

- 只把 ISO 文件复制进 Ventoy 数据分区；
- 不要重建分区表、不要运行 `Ventoy2Disk`、不要执行 `dd`；
- 固件启动菜单里选 `UEFI: <USB>`，进入 Ventoy 菜单后选该 ISO；
- 本机 Secure Boot 关闭，ISO 可以直接启动。

停止条件：

- SHA256 与官方值不一致；
- ISO 文件在 Ventoy 上被截断（大小不等于 1744830464）；
- 误把 ISO 写到了 NVMe 或 ESP。

### 3.1b Ventoy 上的离线 flake 输入（本轮已准备好）

这台网络访问 `github.com` 不稳定（实测 10 次 HTTPS 请求成功 5 次，失败均为
TLS `unexpected eof`），而 flake 的 `home-manager`、`sops-nix` 输入必须从 GitHub
取。为避免安装时被 GitHub 卡住，Ventoy 数据分区里已经放好：

```text
<VENTOY>/nixos-install/
├── README-ISO.txt          安装环境里的用法说明
├── repo/                   nixos-infra 工作树（无 secrets/、无 hardware 文件）
└── cache/                  四个 flake 输入的本地二进制缓存（约 41 MiB）
```

`cache/` 由 Arch 上执行 `nix copy --to file://...` 生成，内容是
`nix flake archive` 给出的四个 `*-source` 路径：

```text
/nix/store/fkrgkr1glraxczxx0i9gm9zqjd118i2p-source   nixpkgs 26.11pre1097682
/nix/store/3f2hfr82vxncf7ax3d02wh22p0dby1b6-source   home-manager ec80131
/nix/store/9xlfs4fc7h82mkvvnifbhng24082gqin-source   sops-nix 4493170
/nix/store/1pmshh4a1vizyzhzr1x8rv0cz0lgjhnx-source   flake source
```

在 ISO 中把它们导入 live store，之后 `flake metadata` / `nix build` 就不再访问
GitHub：

```bash
V=/run/media/nixos/Ventoy          # 用 lsblk / findmnt 确认真实挂载点
cp -a "$V/nixos-install/repo" /root/nixos-infra
cd /root/nixos-infra
git init -q . && git add -A && git -c user.email=i@i -c user.name=i commit -qm prep

nix copy --from "file://$V/nixos-install/cache" \
  /nix/store/fkrgkr1glraxczxx0i9gm9zqjd118i2p-source \
  /nix/store/3f2hfr82vxncf7ax3d02wh22p0dby1b6-source \
  /nix/store/9xlfs4fc7h82mkvvnifbhng24082gqin-source \
  /nix/store/1pmshh4a1vizyzhzr1x8rv0cz0lgjhnx-source

nix --extra-experimental-features 'nix-command flakes' flake metadata --offline
```

`--offline` 是关键：它让 Nix 只用本地 store，不去 GitHub 重试。本轮已在 Arch
上用“空 store + 仅 Ventoy 缓存 + `--offline`”复现过这套流程，`nixosConfigurations`
能正常求值。

**这只是 flake 输入，不是整个闭包。** nixpkgs 的 1901 个 store path（约 9.5 GiB）
不放进 U 盘，安装时从 TUNA 镜像并行下载（实测 8 并发约 6.3 MiB/s，全量约
25 分钟）。缓存失效条件：`flake.lock` 变了就重新在 Arch 上跑
`nix flake archive` + `nix copy`。

### 3.2 Restic 最新快照和恢复密码 gate

在能访问 Restic 仓库的机器上，安装前重新确认（只读/校验，不写入仓库）：

```bash
export RESTIC_REPOSITORY=<RESTIC_REPOSITORY>
export RESTIC_PASSWORD_FILE=<OFFLINE_PASSWORD_FILE>

restic snapshots --latest 1
restic check --read-data-subset=5%
```

再做一次代表性恢复校验（恢复到临时目录，不覆盖 `/`）：

```bash
VERIFY_DIR=$(mktemp -d /var/tmp/restic-verify.XXXXXX)
restic restore latest --target "$VERIFY_DIR" \
  --include <A_REPRESENTATIVE_FILE_OR_DIR>
sha256sum <ORIGINAL_FILE>
sha256sum "$VERIFY_DIR/<RESTORED_PATH>"
```

如果 Restic 仓库或密码文件只有 root 可读，使用 `sudo -E` 保留
`RESTIC_REPOSITORY`/`RESTIC_PASSWORD_FILE`，或显式传 `--repo` 和
`--password-file`；不要让 `sudo` 在丢掉环境变量后去猜仓库。用 `sudo` 恢复时，
后续 `sha256sum` 也要用 `sudo`，或先把临时目录 `chown` 回当前用户。

要求：

- 最新快照时间/ID 已记录；
- Restic 密码的独立恢复副本可用（不要打印密码）；
- 至少一个代表性文件校验和一致；
- `restic check` 没有数据错误。

本轮的保护边界：

- Arch P0 个人文件、`~/life`、KeePassXC、SSH 私钥、笔记已备份；
- P1 科研数据已备份；
- Windows VM 已备份；
- **P2 的 PostgreSQL、`.rr/pulled`、Yulin 部署备份等不纳入此次迁移保护**，用户
  已接受潜在丢失风险。文档和操作中不要把它们说成“已保护”。
- 不运行 `restic forget`、`prune`、`init` 或任何仓库写入命令。

### 3.3 保存私有 inventory

这些输出包含 UUID、序列号、PARTUUID，只保存在本机/小主机的私有目录，不提交：

```bash
umask 077
mkdir -p ~/arch-nixos-install-inventory

{
  date -Is
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS
  sudo blkid
  findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
  sudo btrfs subvolume list -a -p -t /
  sudo btrfs subvolume get-default /
  sudo btrfs filesystem usage /
  sudo bootctl status
  sudo bootctl list
  sudo efibootmgr -v
  sudo snapper -c root list
  sudo snapper -c home list
} > ~/arch-nixos-install-inventory/arch-before.txt
```

再单独记录 Arch UKI 和 systemd-boot 的校验和：

```bash
sudo sha256sum /boot/EFI/Linux/arch-linux-lts.efi \
  /boot/EFI/systemd/systemd-bootx64.efi \
  /boot/EFI/BOOT/BOOTX64.EFI \
  /boot/loader/loader.conf \
  > ~/arch-nixos-install-inventory/esp-before.sha256
```

`efibootmgr -v` 的输出是恢复 NVRAM 的依据；ESP tar 备份**不包含 NVRAM**，两者
都要保存。

### 3.4 把 ESP 独立备份到 NixOS 小主机（本轮已执行）

**本轮已经完成**，结果见第 18.4 节；下面是可重复执行的步骤，将来重建时照此操作。

目标：在小主机上保存一份可校验、可解包、可比较的 ESP 全量归档。此操作读取
Arch `/boot`，写入 Arch `/var/tmp` 和小主机家目录；不改 Arch 磁盘。

在 Arch 上：

```bash
set -euo pipefail
umask 077

STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE=/var/tmp/arch-esp-$STAMP.tar.gz

sudo tar --numeric-owner --xattrs --acls -C /boot -cpf - . \
  | gzip -9 > "$ARCHIVE"

(
  cd /var/tmp
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
```

如果 tar/gzip 失败，删除未完成的 `$ARCHIVE` 后重做；不要复制半成品归档。

复制到小主机（小主机已可通过 SSH 登录；主机名/用户按实际替换）：

```bash
ssh nixos 'umask 077; mkdir -p ~/arch-esp-backups'
scp "$ARCHIVE" "$ARCHIVE.sha256" nixos:~/arch-esp-backups/
ssh nixos 'cd ~/arch-esp-backups && sha256sum -c arch-esp-*.sha256'
```

确认归档内容清单（在小主机上）：

```bash
ssh nixos 'cd ~/arch-esp-backups && tar -tzf arch-esp-*.tar.gz | head -40'
```

必须能看到至少这些路径：

```text
./EFI/Linux/arch-linux-lts.efi
./EFI/systemd/systemd-bootx64.efi
./EFI/BOOT/BOOTX64.EFI
./EFI/Lenovo/BIOS/SelfHealing.fd
./loader/loader.conf
./loader/random-seed
./loader/credentials/nvpcr-anchor.*.cred
./amd-ucode.img
./vmlinuz-linux-lts
```

做一次“可恢复”演练。推荐在 **Arch** 上解包到临时目录（**不要解到
`/boot`**），这样可以直接和原始 ESP 比对：

```bash
RESTORE_DIR=$(mktemp -d /var/tmp/esp-restore.XXXXXX)
sudo tar -C "$RESTORE_DIR" --numeric-owner --xattrs --acls \
  -xzf "$ARCHIVE"

sudo sha256sum /boot/EFI/Linux/arch-linux-lts.efi \
  "$RESTORE_DIR/EFI/Linux/arch-linux-lts.efi"
sudo cmp /boot/loader/loader.conf "$RESTORE_DIR/loader/loader.conf"
sudo diff -rq /boot/EFI "$RESTORE_DIR/EFI"
```

如果在小主机上做解包，把 `$ARCHIVE` 换成小主机上的实际路径；小主机没有
Arch 的 `/boot`，因此只做归档自洽检查（解包后关键文件存在、大小合理、SHA256
可复算）。**看到归档列表不算完成恢复验证**；至少要有一次解包和文件校验。

这是**文件级**归档，不是 ESP 分区表/文件系统镜像。它足以恢复 Arch UKI、
systemd-boot 文件、`loader.conf` 和 `EFI/Lenovo` 文件；如果 ESP 分区本身或
GPT 表损坏，需要重建 ESP 后再恢复文件，或另做整盘/分区镜像备份（不在本轮
执行）。

建议再复制一份归档到离线介质。小主机上的副本和离线副本不要放在同一个会随系统
重装的目录里。

补充两条本轮踩到的实操细节：

- 在 Arch 上用绝对路径生成 `.sha256` 会让小主机上的 `sha256sum -c` 去找
  `/var/tmp/...`；校验文件要用 `cd /var/tmp && sha256sum <basename>` 生成。
- `tar` 归档是**文件级**的，不含分区表和 NVRAM；`efibootmgr -v` 的输出要单独
  保存（本轮保存在 `~/arch-nixos-install-inventory/`）。

### 3.5 记录 Arch 默认启动项和 NVRAM

```bash
sudo bootctl status
sudo bootctl list
sudo efibootmgr -v
sudo cat /boot/loader/loader.conf
```

记录：

- `Boot0005* Linux Boot Manager` 是当前引导入口；
- BootOrder 以 0005 开头；
- `loader.conf` 当前没有 `default`；
- Arch UKI 是 `arch-linux-lts.efi`。

**不要**在这一步执行 `efibootmgr -B`、`bootctl install` 或任何写操作。

---

## 4. 安装环境：确认 ISO 以 UEFI 模式启动

### 4.1 前提

- ISO 已写入 U 盘；
- 固件已关闭 CSM/Legacy，Secure Boot 保持关闭；
- 笔记本接电源，避免安装中断电。

### 4.2 操作

从固件启动菜单选择 **UEFI: <USB>**。进入 Minimal ISO 后：

```bash
test -d /sys/firmware/efi && echo "UEFI boot"
cat /etc/os-release
bootctl status | sed -n '1,12p'
```

预期：

- `UEFI boot`；
- ISO 版本是 `26.05.12400.da6dc0e7b260`（`cat /etc/os-release` 的
  `VERSION_ID=26.05`），与 `hosts/main/default.nix` 的
  `system.stateVersion = "26.05"` 一致；
- `Secure Boot: disabled`；
- 能联网（`ping`/`curl` 或 `nix flake` 能取输入）。

如果 Secure Boot 显示 enabled：**停止**。当前 Arch UKI 和 NixOS
systemd-boot 都未签名，不能在该状态下继续；先在固件中关闭 Secure Boot，
或另做签名方案（不在本轮范围）。

### 4.3 网络：直连小主机 + 镜像/代理

ISO 不会继承 Arch 的 NetworkManager 配置（两端的直连 profile 都是
`autoconnect no`），必须在 ISO 里重新配置。

**第一步：认出直连网卡**（笔记本有线和无线两张卡，名字以实际为准）：

```bash
ip -brief link
nmcli device status
```

**第二步：给有线网卡配置 `10.77.77.1/30`，不设网关和 DNS**：

```bash
sudo nmcli connection add type ethernet ifname <WIRED_IF> con-name direct-nixos \
  ipv4.method manual ipv4.addresses 10.77.77.1/30 \
  ipv4.never-default yes ipv6.method disabled
sudo nmcli connection up direct-nixos
ping -c 2 10.77.77.2
```

`ipv4.never-default yes` 很重要：它保证这条直连不会抢走默认路由，Wi-Fi/DHCP
仍然是唯一出口。如果之后要用 Wi-Fi 上网，另建一个普通 DHCP profile。

**第三步：验证 SSH 主机指纹**（不要 `StrictHostKeyChecking=no`）：

```bash
ssh-keyscan -t ed25519 10.77.77.2 2>/dev/null | ssh-keygen -lf -
# 与 Arch 上记录的指纹逐字比对；不要用 StrictHostKeyChecking=no
```

本轮记录的指纹保存在私有 inventory 里（`arch-esp-state.*.txt` 之外单独一条），
不写进本文，避免公开主机指纹。

**第四步：选择出口**，两条路互不依赖：

| 方案 | 适用 | 命令 |
| --- | --- | --- |
| A. 直连公网 + TUNA 镜像 | 有线/无线能直接上网 | 见下方 `substituters` |
| B. SSH 隧道用小主机代理 | 直连 GitHub 失败，但小主机代理可用 | 见下方隧道命令 |

方案 A（推荐，实测最快）：

```bash
export NIX_CONFIG="substituters = https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
"
```

方案 B（只在需要 GitHub 或 cache.nixos.org 直连很慢时用）：

```bash
# 在 ISO 里把本机 17897 转发到小主机的 loopback 代理 7897
ssh -N -L 127.0.0.1:17897:127.0.0.1:7897 calendar@10.77.77.2 &
export http_proxy=http://127.0.0.1:17897
export https_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$http_proxy"
export NO_PROXY=localhost,127.0.0.1,10.77.77.0/30
curl -I --max-time 15 -x "$http_proxy" https://github.com
```

小主机的 mihomo 只监听 `127.0.0.1:7897`，没有开放到局域网，也没有改防火墙；
SSH 隧道是唯一入口，走的是已验证的主机指纹和公钥认证。**不要**为了省事去改
`allow-lan`、监听 `0.0.0.0` 或关防火墙。

**第五步：确认 Nix 真的走了代理**（`nix` 会读 `http_proxy`，但要用真实下载验证）：

```bash
nix --version
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 20 \
  https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info
```

如果 `nix build` 仍报 GitHub 错误，说明 `--offline` 没加或 flake 输入没导入，
回到 3.1b 检查 `nix copy --from file://...`。

---

## 5. 确认设备、文件系统和已有子卷

### 5.1 前提

- 已从 UEFI 启动 ISO；
- 没有挂载任何目标子卷到 `/mnt`。

### 5.2 只读确认

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS
sudo blkid
sudo btrfs filesystem show
```

逐项确认：

- 只有一块约 953.9 GiB 的 NVMe；
- 分区 1 是约 1 GiB 的 vfat ESP；
- 分区 2 是约 952.9 GiB 的 Btrfs；
- 没有 LUKS/crypt 层；
- 没有 Windows 物理分区；
- UUID 与私有 inventory 一致。

挂载 Btrfs 顶层只读检查子卷：

```bash
sudo mkdir -p /mnt/btrfs-root
sudo mount -o subvolid=5,ro /dev/disk/by-uuid/<BTRFS_UUID> /mnt/btrfs-root
sudo btrfs subvolume list -a -p -t /mnt/btrfs-root
sudo btrfs subvolume get-default /mnt/btrfs-root
sudo btrfs filesystem usage /mnt/btrfs-root
sudo umount /mnt/btrfs-root
```

预期：

- 顶层有 `@`、`@home`、`@log`、`@pkg`；
- 有 `@/.snapshots`、`@home/.snapshots` 及其快照；
- 没有 `@nixos`、`@nixos-home`、`@nixos-nix`；
- 默认子卷仍是 ID 5；
- Btrfs 没有错误/缺失设备。

**停止条件**（任一即停，不创建子卷）：

- 设备数量、大小或分区表与记录不符；
- 出现 LUKS、mdraid、多设备 Btrfs 或缺失设备；
- 已有 `@nixos*` 同名子卷；
- 默认子卷不是 ID 5；
- `btrfs filesystem show` 报错或 `btrfs device stats` 有错误；
- 无法确认 `<BTRFS_UUID>` 就是分区 2。

---

## 6. 创建 NixOS 专属 Btrfs 子卷

**【需要用户二次授权】** 本节会写入 Btrfs，但只创建三个新顶层子卷，不修改
`@`、`@home`、`@log`、`@pkg`、快照或默认子卷。

### 6.1 前提

- 第 5 节全部通过；
- 已记录 `btrfs subvolume list` 和默认子卷；
- 没有同名子卷；
- 没有运行任何安装/格式化命令。

### 6.2 操作

```bash
set -euo pipefail

sudo mkdir -p /mnt/btrfs-root
sudo mount -o subvolid=5 /dev/disk/by-uuid/<BTRFS_UUID> /mnt/btrfs-root

# 名字必须不存在；任何 test 失败都停止
test ! -e /mnt/btrfs-root/@nixos
test ! -e /mnt/btrfs-root/@nixos-home
test ! -e /mnt/btrfs-root/@nixos-nix

sudo btrfs subvolume create /mnt/btrfs-root/@nixos
sudo btrfs subvolume create /mnt/btrfs-root/@nixos-home
sudo btrfs subvolume create /mnt/btrfs-root/@nixos-nix

sudo btrfs subvolume list -a -p -t /mnt/btrfs-root
sudo btrfs subvolume get-default /mnt/btrfs-root

sudo umount /mnt/btrfs-root
```

### 6.3 预期结果

- 三个新子卷的 parent/top level 都是 5；
- 新 ID 不与现有 `@` 等冲突；
- 默认子卷仍然是 ID 5；
- `@`、`@home`、`@log`、`@pkg` 的 ID 和快照没有变化；
- 没有创建 `@/@nixos` 这类嵌套路径。

### 6.4 停止条件

- 任一 `test` 失败（已存在同名子卷）；失败时先
  `sudo umount /mnt/btrfs-root`，不要继续创建；
- `btrfs subvolume create` 报错；
- 默认子卷发生变化；
- 看到任何现有子卷/快照被修改；
- 磁盘空间不足或 Btrfs 报错。

**不要**执行 `btrfs subvolume delete`、`btrfs subvolume set-default`、
`btrfs balance`、`btrfs scrub` 或任何“清理”命令。

---

## 7. 挂载安装目标

**【需要用户二次授权】** 本节只在安装环境创建挂载，不格式化。它不会删除现有
数据，但挂错子卷会导致后续安装写入错误位置。

### 7.1 前提

- 第 6 节创建了三个子卷；
- Arch UKI 仍在 ESP 上；
- 已再次确认 `<BTRFS_UUID>` 和 `<ESP_UUID>`。

### 7.2 操作

```bash
set -euo pipefail

# 目标根：@nixos
sudo mount -o subvol=@nixos,compress=zstd:3,ssd,discard=async,space_cache=v2 \
  /dev/disk/by-uuid/<BTRFS_UUID> /mnt

sudo mkdir -p /mnt/home /mnt/nix /mnt/boot

# NixOS 独立 Home
sudo mount -o subvol=@nixos-home,compress=zstd:3,ssd,discard=async,space_cache=v2 \
  /dev/disk/by-uuid/<BTRFS_UUID> /mnt/home

# NixOS 独立 store
sudo mount -o subvol=@nixos-nix,compress=zstd:3,ssd,discard=async,space_cache=v2 \
  /dev/disk/by-uuid/<BTRFS_UUID> /mnt/nix

# 现有 ESP；不要 mkfs
sudo mount -o fmask=0077,dmask=0077 \
  /dev/disk/by-uuid/<ESP_UUID> /mnt/boot
```

### 7.3 必须逐项确认

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt /mnt/home /mnt/nix /mnt/boot
```

预期：

- `/mnt` 的 `OPTIONS` 含 `subvol=/@nixos`（或 `subvol=@nixos`）；
- `/mnt/home` 含 `subvol=/@nixos-home`；
- `/mnt/nix` 含 `subvol=/@nixos-nix`；
- `/mnt/boot` 是 `vfat`，设备是现有 ESP；
- `/mnt/boot` 不是 Btrfs 目录。

再确认 Arch 启动文件仍在：

```bash
sudo test -f /mnt/boot/EFI/Linux/arch-linux-lts.efi \
  && echo "Arch UKI present"
sudo test -f /mnt/boot/EFI/Lenovo/BIOS/SelfHealing.fd \
  && echo "Lenovo self-healing file present"
```

空间检查：

```bash
df -hT /mnt /mnt/home /mnt/nix /mnt/boot
```

要求：

- `/mnt`、`/mnt/home`、`/mnt/nix` 都显示 Btrfs；
- `/mnt/boot` 空闲至少 300 MiB（当前约 914 MiB）；
- 不要把 `@home` 挂到 `/mnt/home`；
- 不要把 `@` 挂到 `/mnt`；
- 不要挂载 `/mnt/mnt/arch-home` 或 Arch 的 `@log`/`@pkg`。

### 7.4 停止条件

- `/mnt` 显示 `subvol=/@`；
- `/mnt/home` 显示 `subvol=/@home`；
- `/mnt/nix` 显示 `subvol=/@` 或不是 `@nixos-nix`；
- `/mnt/boot` 不是 vfat，或找不到 Arch UKI；
- ESP 空闲小于 300 MiB；
- 任一挂载命令报错。

一旦发现挂错，**不要运行 `nixos-install`**。先卸载：

```bash
sudo umount /mnt/boot /mnt/nix /mnt/home /mnt
```

然后从第 5 节重新确认。不要在错误挂载上“修一修继续装”。

---

## 8. 生成并检查主力机 hardware configuration

### 8.1 前提

- 第 7 节全部通过；
- `/mnt` 是 `@nixos`，`/mnt/home` 是 `@nixos-home`，`/mnt/nix` 是
  `@nixos-nix`，`/mnt/boot` 是现有 ESP；
- 没有把 Arch `@home` 挂到安装目标。

### 8.2 生成

```bash
sudo nixos-generate-config --root /mnt
```

它会写：

```text
/mnt/etc/nixos/hardware-configuration.nix
/mnt/etc/nixos/configuration.nix
```

**不要**把 `configuration.nix` 复制进仓库；仓库的 `hosts/main/default.nix` 才是
权威配置。`hardware-configuration.nix` 只提供硬件/文件系统事实。

### 8.3 逐项检查

```bash
sudo sed -n '1,260p' /mnt/etc/nixos/hardware-configuration.nix
```

必须确认：

1. `fileSystems."/"` 的 device 是 `<BTRFS_UUID>`，`fsType = "btrfs"`，
   options 含 `subvol=@nixos` 或 `subvol=/@nixos`；**不能**是 `subvol=@`。
2. `fileSystems."/home"` 含 `subvol=@nixos-home`；**不能**是 `@home`。
3. `fileSystems."/nix"` 含 `subvol=@nixos-nix`。
4. `fileSystems."/boot"` 的 device 是 `<ESP_UUID>`，`fsType = "vfat"`，
   options 含 `fmask=0077`、`dmask=0077`。
5. `swapDevices` 为空，或只包含你明确要用的 swap；**不要**把 Arch 的 zram
   或不存在于 NixOS 的 swap 分区抄进来。
6. 没有 Arch 的 `@`、`@home`、`@log`、`@pkg` 挂载项。
7. `boot.initrd.availableKernelModules` 至少包含 NVMe/存储所需模块（通常会有
   `nvme`、`xhci_pci`、`usbhid`、`usb_storage`、`sd_mod`）。如果缺少 `nvme`，
   先确认生成器输出，再人工补上；不要凭猜测添加一堆模块。
8. `hardware.cpu.amd.updateMicrocode` 为 `true`（或等价配置）；没有则补上。
9. `nixpkgs.hostPlatform = "x86_64-linux"`。
10. 没有 Windows/NTFS 物理分区；没有 LUKS/crypttab 项。

再交叉核对挂载：

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt /mnt/home /mnt/nix /mnt/boot
```

如果生成文件与 `findmnt` 不一致，**停止**。不要通过改 hardware 文件“掩盖”错误
挂载；先修正挂载，再重新生成。

### 8.4 放入仓库

```bash
# <REPO> 是安装环境中可写的仓库副本，例如 /root/nixos-infra 或 U 盘路径
sudo cp /mnt/etc/nixos/hardware-configuration.nix \
  <REPO>/hosts/main/hardware-configuration.nix

sudo chown "$USER:$USER" <REPO>/hosts/main/hardware-configuration.nix
chmod 0644 <REPO>/hosts/main/hardware-configuration.nix

cd <REPO>
git add hosts/main/hardware-configuration.nix   # 只暂存，不提交、不 push
```

注意：

- 该文件包含 UUID；仓库是私有仓库，不要粘贴到公开 issue/聊天。
- 不要为了“让 flake 通过”而手写假 UUID。
- 如果仓库不是 git 仓库，确保该文件实际存在即可；flake 会直接读取。
- 优先把 `<REPO>` 放在 Linux 文件系统上。FAT/NTFS 上 `chown`/`chmod` 可能失败；
  如果仓库是 root 复制的，确保 `.git` 和文件对当前用户可写，或统一用 `sudo`
  执行 `git add`，不要留下 root 拥有的 index。

### 8.5 停止条件

- 任一子卷/ESP 不对；
- 生成文件包含 `subvol=@`、`@home`、Arch UUID 或错误 swap；
- `boot.initrd` 缺少必要存储模块；
- 无法确认 `/mnt/boot` 是现有 ESP；
- 复制/暂存时覆盖了已有文件。

---

## 9. 完成 Flake `main` host 集成

### 9.1 当前仓库设计

`flake.nix` 的条件：

```nix
mainHardware = ./hosts/main/hardware-configuration.nix;

nixosConfigurations =
  { nixos = mkHost ./hosts/nixos; }
  // nixpkgs.lib.optionalAttrs (builtins.pathExists mainHardware) {
    main = mkHost ./hosts/main;
  };
```

含义：

- 没有真实 hardware 文件时，`nixosConfigurations.main` **不存在**；
- 生成并 `git add` 后，`main` 自动出现；
- 这样 `nix flake check` 不会被假 UUID 污染，也避免误装一个没有根文件系统的
  NixOS。

`hosts/main/default.nix` 的关键点：

- `./hardware-configuration.nix` + `./boot.nix`；
- 复用 `modules/base.nix`、`modules/network.nix`、`modules/secrets.nix`、
  `modules/desktop/*`；
- `networking.hostName = "main"`；
- `users.users.calendar.uid = 1000`、`group = "calendar"`、
  `users.groups.calendar.gid = 1000`；
- Home Manager 使用 `../../home/calendar`，但家目录在独立 `@nixos-home`；
- `/mnt/arch-home` 只读挂载 `@home`，设备复用
  `config.fileSystems."/".device`，不重复写 UUID；
- `nix.gc.automatic = lib.mkForce false`；
- `system.stateVersion = "26.05"`，与所选 ISO 的 `VERSION_ID` 一致。

### 9.2 集成检查

```bash
cd <REPO>
git status --short
git diff --stat

# 确认 main 出现
nix flake show

# 确认 stateVersion 与 ISO
grep -n 'system.stateVersion' hosts/main/default.nix
grep '^VERSION_ID=' /etc/os-release

# 确认 UID/GID
id calendar
getent group calendar

# 确认 boot 拆分
grep -R 'configurationLimit\|canTouchEfiVariables\|extraInstallCommands' \
  hosts modules
```

预期：

- `nix flake show` 中出现 `nixosConfigurations.main`；
- `system.stateVersion` 与 ISO 的 `VERSION_ID` 一致（`26.05`）；
- Arch 用户 UID/GID 为 1000:1000；
- `modules/base.nix` 不再包含 systemd-boot 设置；
- `hosts/nixos/boot.nix` 保持小主机原行为（limit 20、canTouch true、timeout 3）；
- `hosts/main/boot.nix` 使用 limit 3、canTouch false、timeout 5、固定 Arch 默认。

如果 `nix flake show` 没有 `main`：

- `hosts/main/hardware-configuration.nix` 不存在；
- 或文件未 `git add`，Nix 的 git flake 看不到它；
- 不要通过创建空文件/假文件解决。

### 9.2b `extraInstallCommands` 的行为和边界

`hosts/main/boot.nix` 的 hook 在 NixOS 的 bootloader builder **之后**执行，做三件事：

1. 删掉 `loader.conf` 里以 `default ` / `preferred ` 开头的行；
2. 追加 `default arch-linux-lts.efi`；
3. 自校验：必须恰好一行 `default`，且内容等于 `default arch-linux-lts.efi`；
   否则 `exit 1`，让安装/重建当场失败。

它**只改 `loader.conf` 的 default 行**，不创建、不改名、不删除任何启动项，也不
碰 `EFI/Linux`、`EFI/nixos`、`loader/entries`。Arch 的 UKI 和 NixOS 的 Type #1
条目都保持原样。

`arch-linux-lts.efi` 是 `bootctl list` 对 `/boot/EFI/Linux/arch-linux-lts.efi`
报告的 entry id（Type #2 UKI 的 id 就是文件名）。如果 Arch 改了 UKI 文件名，
hook 会因 `grep -qx` 失败而报错，而不是静默把默认项指向一个不存在的条目。

找不到 Arch UKI 或 `loader.conf` 时，hook 现在**直接失败**（而不是只打 warning
继续），因为那意味着 Arch 可能根本起不来。此时先检查 `/boot`、从 ESP 备份恢复，
再重跑 bootloader 步骤。

已知取舍：hook 会覆盖你在 systemd-boot 菜单里手动设置的默认项。将来若想让 NixOS
当默认，先删掉这段 `extraInstallCommands`，再设置默认，否则下次 rebuild 会改回
Arch。

本轮用临时目录 + 真实渲染出的脚本验证过：

- 正常情况：`timeout 5` / `console-mode keep` / 自定义注释都保留，只多一行
  `default arch-linux-lts.efi`；
- 连续执行 3 次结果不变（幂等）；
- UKI 缺失时 `exit 1`，`loader.conf` 不被修改。

### 9.3 不要升级输入

本轮不要运行：

```text
nix flake update
nix flake lock --update-input ...
```

`flake.lock` 保持原样。仓库锁定的 nixpkgs（26.11 pre）与安装介质（26.05）
是两件独立的事：介质决定 `stateVersion` 和 `nixos-generate-config` 的输出，
`flake.lock` 决定实际构建的软件版本。这种组合是正常的，不需要把两者对齐。

---

## 10. 安装前检查和构建

### 10.1 前提

- 第 8 节 hardware 文件已放入仓库；
- 第 9 节 `main` 已出现；
- ESP 备份和 Restic gate 已完成；
- 目标挂载仍是正确的三个子卷 + ESP。

### 10.2 检查命令

```bash
cd <REPO>

nix flake check --show-trace

# NixOS ISO 通常带 nixos-rebuild；如果命令不存在，用下面的 nix build
sudo nixos-rebuild build --flake .#main
# 或者：
nix build '.#nixosConfigurations.main.config.system.build.toplevel'
```

预期：

- `nix flake check` 通过；
- `nixos-rebuild build` 输出 `Done. The new configuration is /nix/store/...`；
- 不出现 `subvol=@`、Arch UUID、错误 swap 的警告。

### 10.3 检查构建出的 fstab

```bash
cat result/etc/fstab
grep -E 'subvol=|by-uuid' result/etc/fstab
```

必须看到：

- `/` 使用 NixOS Btrfs UUID + `subvol=@nixos`；
- `/home` 使用 `subvol=@nixos-home`；
- `/nix` 使用 `subvol=@nixos-nix`；
- `/boot` 使用 ESP UUID；
- `/mnt/arch-home` 使用 `subvol=@home`，选项含 `ro`、`nofail`。

### 10.4 空间和对象确认

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt /mnt/home /mnt/nix /mnt/boot
df -hT /mnt /mnt/home /mnt/nix /mnt/boot
```

要求：

- `/mnt` 是 `@nixos`；
- `/mnt/home` 是 `@nixos-home`；
- `/mnt/nix` 是 `@nixos-nix`；
- `/mnt/boot` 是现有 ESP；
- ESP 空闲 ≥ 300 MiB；
- Btrfs 空闲 ≥ 100 GiB；
- 笔记本已接电源。

### 10.5 停止条件

- `nix flake check` 失败；
- 构建出的 fstab 有 `subvol=@` 或 `@home` 作为 NixOS 根/home；
- 目标挂载与第 7 节不一致；
- ESP 空闲 < 300 MiB；
- Restic/ESP 备份未验证；
- 不能确认 `<BTRFS_UUID>`/`<ESP_UUID>`；
- 用户没有对第 11 节安装命令给出明确授权。

---

## 11. 执行 `nixos-install --flake ...#main`

**【需要用户二次授权】** 本节会写 `@nixos`、`@nixos-home`、`@nixos-nix` 和
共享 ESP，并安装 NixOS。Arch 的 `@`/`@home` 不会被写入，但 ESP 的
systemd-boot 和 `loader.conf` 会被更新。

### 11.1 前提

- 第 10 节全部通过；
- 已明确告知用户：会覆盖共享 ESP 上的 systemd-boot 文件、会写
  `loader.conf`、会新增 NixOS boot 文件；
- 已确认 `canTouchEfiVariables = false`，不会主动写 NVRAM；
- 已确认 ESP 备份可恢复（见 3.4 与第 16 节）；
- 已导入 Ventoy 上的 flake 输入（3.1b），或网络能稳定访问 GitHub；
- 笔记本接电源。

### 11.2 命令

```bash
cd <REPO>
# 如果 flake 输入来自 Ventoy 缓存，加 --offline 避免 Nix 去 GitHub 重试
sudo nixos-install --flake .#main --option substituters \
  "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/"
```

`--option substituters` 只影响本次调用；它让 9.5 GiB 闭包从镜像并行下载，而不是
逐个去 `cache.nixos.org`。如果坚持只用官方缓存，去掉这一段即可，只是会慢很多。

默认 root 是 `/mnt`；如果使用自定义 root，加 `--root <MOUNT>`。不要加
`--no-bootloader`：本次需要 NixOS 的 bootloader 步骤生成 Type #1 条目。

安装器会：

- 构建/复制 NixOS 闭包到 `/mnt/nix`；
- 写 `/mnt/etc`、`/mnt/home`；
- 调用 bootloader builder，更新 `/mnt/boot` 上的 systemd-boot 和 NixOS 条目；
- 由 `canTouchEfiVariables = false` 传入 `--variables=no`，不改 NVRAM；
- 由 `extraInstallCommands` 把 `loader.conf` 的默认项改回 Arch UKI。

安装器可能提示设置 root 密码。建议设置一个强密码并离线保存；如果使用
`--no-root-passwd`，root 将保持锁定，必须确保 `calendar` 的 sudo 密码可用。

### 11.3 安装过程中必须观察

- 构建/复制阶段没有 disk full；
- `installing the boot loader` 没有报错；
- `bootctl install --variables=no` 没有失败；
- `extraInstallCommands` 没有报错（尤其是找不到 Arch UKI 的 warning）；
- 没有出现 `subvol=@` 的 NixOS 根提示。

### 11.4 安装后、重启前检查

```bash
# Arch UKI 仍在
sudo test -f /mnt/boot/EFI/Linux/arch-linux-lts.efi && echo "Arch UKI OK"

# NixOS 文件存在
sudo find /mnt/boot/EFI/nixos -maxdepth 1 -type f -printf '%s %p\n' | head
sudo ls -la /mnt/boot/loader/entries

# loader.conf 默认项
sudo cat /mnt/boot/loader/loader.conf

# NVRAM 没有意外变化
sudo efibootmgr -v

# Arch UKI 校验和与安装前一致
sudo sha256sum /mnt/boot/EFI/Linux/arch-linux-lts.efi
```

预期：

- `loader.conf` 有 `default arch-linux-lts.efi`，没有 `default nixos-*` /
  `preferred`；
- `/mnt/boot/loader/entries/` 有 `nixos-*.conf`；
- `/mnt/boot/EFI/nixos/` 有 kernel/initrd；
- `efibootmgr` 的 BootOrder 仍以 0005 开头，没有新增的 NixOS 项；
- Arch UKI 的 SHA256 与安装前记录一致；
- `/mnt/boot/EFI/systemd/systemd-bootx64.efi` 和
  `/mnt/boot/EFI/BOOT/BOOTX64.EFI` 存在（版本可能变成 NixOS 的 262.x）。

如果 `loader.conf` 仍然默认 NixOS，**不要重启**，先修：

```bash
sudo sed -i -e '/^default /d' -e '/^preferred /d' \
  /mnt/boot/loader/loader.conf
printf 'default arch-linux-lts.efi\n' | sudo tee -a /mnt/boot/loader/loader.conf
sudo cat /mnt/boot/loader/loader.conf
```

如果 Arch UKI 校验和不一致或文件丢失：**停止**，不要重启；按第 15 节从 ESP
备份恢复。

如果 NVRAM 顺序意外改变：不要用 `-B` 删除；先用 `efibootmgr -v` 确认各 ID 和
路径，再用 `efibootmgr -o` 恢复原顺序（见第 15 节）。

### 11.5 停止条件

- bootloader 步骤失败；
- Arch UKI 丢失/校验和不一致；
- `loader.conf` 无法固定为 Arch；
- NVRAM 出现无法解释的新项/顺序变化；
- `/mnt/nix` 或 `/mnt/home` 不再是正确子卷；
- 安装器写入了 `/mnt/boot` 之外的 ESP 位置；
- 磁盘空间不足。

---

## 12. 设置用户密码

### 12.1 前提

- `nixos-install` 已成功；
- 第 11.4 节检查通过；
- `/mnt` 仍挂载着目标系统。

### 12.2 命令

```bash
sudo nixos-enter --root /mnt -c 'passwd calendar'
```

如果安装器已经设置了 root 密码，确认 root 状态（不要打印 hash）：

```bash
sudo nixos-enter --root /mnt -c 'passwd -S root'
```

验证用户和家目录：

```bash
sudo nixos-enter --root /mnt -c 'id calendar'
sudo nixos-enter --root /mnt -c 'getent passwd calendar'
sudo nixos-enter --root /mnt -c 'getent group calendar'
sudo nixos-enter --root /mnt -c 'stat -c "%u:%g %a" /home/calendar'
```

预期：

- `uid=1000(calendar) gid=1000(calendar)`；
- 家目录 `/home/calendar` 属主 `1000:1000`，权限 `700`；
- 不是 `users` gid 100；
- `/home` 是 `@nixos-home`，不是 `@home`。

`nixos-enter` 会先运行 activation，通常此时会创建家目录；如果 `stat` 失败，
先检查 activation 输出、`/mnt/home` 挂载和磁盘空间，不要直接重装。首次启动
后仍按第 13.2 节复核。

如果 UID/GID 不对：

- 不要重启；
- 修改 `hosts/main/default.nix` 的 `uid`/`group`/`users.groups.calendar.gid`；
- 重新 `nixos-install --flake .#main`（或修正后重新安装）；
- 否则 NixOS 用户读不了 Arch 的 0700 家目录。

### 12.3 停止条件

- `passwd` 失败；
- UID/GID 不是 1000:1000；
- `/home/calendar` 不是 700 或属主不对（且 activation 已成功）；
- 无法进入 `nixos-enter`。

---

## 13. 验证 NixOS 启动

### 13.1 第一次重启

```bash
sudo reboot
```

在 systemd-boot 菜单中：

- 默认项应为 **Arch Linux**；
- 用方向键选择 NixOS 条目（名称类似 `NixOS` 或 `NixOS (generation 1)`）；
- 如果直接进入 Arch，这是预期默认行为；重启并在 5 秒 timeout 内选择 NixOS。

不要在这一步把 NixOS 设为默认。

### 13.2 NixOS 内检查

```bash
cat /proc/cmdline
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS / /home /nix /boot /mnt/arch-home
sudo btrfs subvolume list -a -p /
df -hT
sudo bootctl status
sudo bootctl list
sudo efibootmgr -v
cat /boot/loader/loader.conf
id
getent passwd calendar
getent group calendar
stat -c "%u:%g %a" /home/calendar
systemctl --failed
```

预期：

- `/` 是 `subvol=/@nixos`；
- `/home` 是 `subvol=/@nixos-home`；
- `/nix` 是 `subvol=/@nixos-nix`；
- `/mnt/arch-home` 是 `subvol=/@home`，选项含 `ro`；
- `/boot` 是原 ESP；
- `bootctl list` 同时有 Arch 和 NixOS；
- `loader.conf` 默认 Arch；
- `id` 为 1000:1000；
- `/home/calendar` 属主 `1000:1000`，权限 `700`；
- 没有 failed units。

验证只读 Arch 家目录：

```bash
sudo -u calendar test -r /mnt/arch-home/calendar/life \
  && echo "Arch ~/life readable"
findmnt -no OPTIONS /mnt/arch-home
```

预期看到 `ro`。不要尝试写入；不要 `mount -o remount,rw /mnt/arch-home`。

验证 Arch UKI 未被改动：

```bash
sudo sha256sum /boot/EFI/Linux/arch-linux-lts.efi
```

与安装前记录比较，必须一致。

### 13.3 网络、GPU 和桌面

```bash
ip -brief addr
nmcli device status
lspci -nnk | grep -A3 -Ei 'vga|3d|display'
```

预期：

- 有线 `r8169` 或无线 `rtw89_8852be` 至少一个可用；
- GPU 使用 `amdgpu`；
- 能访问网络。

登录 SDDM，选择 niri 或 Sway。首次登录只验证能进入桌面、终端、文件管理器和
输入法；不要在这时导入 Arch 的浏览器 profile、Clash 订阅或 Docker 数据。

### 13.4 停止条件

- NixOS 根不是 `@nixos`；
- `/home` 是 `@home` 或挂载失败；
- `/mnt/arch-home` 不是只读；
- NixOS 读不到 Arch 家目录；
- Arch 条目在 `bootctl list` 中消失；
- Arch UKI 校验和不一致；
- `/boot/loader/loader.conf` 默认不是 Arch；
- NVRAM 顺序异常；
- 有 failed units 或无法登录。

任一情况：不要删除 NixOS 或 Arch；按第 15 节恢复，必要时直接启动 Arch。

---

## 14. 再次启动 Arch，验证原有环境

### 14.1 操作

重启，选择 Arch（当前默认项）。进入 Arch 后检查：

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS / /home /boot
sudo btrfs subvolume list -a -p -t /
sudo btrfs subvolume get-default /
sudo snapper -c root list | tail
sudo snapper -c home list | tail
systemctl --failed
docker ps
virsh list --all 2>/dev/null || true
sudo sha256sum /boot/EFI/Linux/arch-linux-lts.efi
sudo cat /boot/loader/loader.conf
```

预期：

- Arch `/` 仍是 `subvol=@`；
- `/home` 仍是 `@home`；
- 默认子卷仍是 ID 5；
- Snapper 原有快照仍在（可以有新快照，但不能少了旧的）；
- Docker 容器/Windows VM 状态与安装前一致（不要自动启动/停止）；
- Arch UKI 校验和不变；
- `loader.conf` 默认 Arch。

### 14.2 数据检查（只读）

```bash
ls -la /home/calendar
ls -la /home/calendar/life | head
readlink -f /home/calendar/.ssh
readlink -f /home/calendar/dotfiles
```

确认：

- `~/life`、`~/code`、个人文件、KeePassXC 数据库、SSH 私钥路径仍可访问；
- `~/.ssh -> ~/life/secrets/ssh` 和 `dotfiles -> ~/life/dotfiles` 仍然有效；
- 没有把 Arch 家目录挂到 NixOS，也没有把 NixOS 文件写进 Arch 家目录。

### 14.3 停止条件

- Arch 无法启动；
- Arch 根/home 子卷不对；
- Snapper 快照缺失；
- `/boot` 下 Arch UKI 缺失或校验和不一致；
- Docker/VM 数据目录异常；
- 默认启动项不是 Arch。

Arch 启动失败时，按第 15 节从 ESP 备份/Live ISO 恢复；**不要重装 Arch**。

---

## 15. 失败时如何停止并恢复 Arch 启动

### 15.1 通用原则

- 任何时候不确定，**停止写入**，先启动 Arch。
- 不要用 `rm -rf`、`mkfs`、`parted`、`sgdisk`、`wipefs` 或 `btrfs subvolume delete`
  作为“修复”。
- 不要删除 NixOS 子卷来“回退”；Arch 默认项恢复不需要删除 NixOS。
- 不要删除 `/boot/EFI/Lenovo`、Arch UKI、`loader/random-seed` 或
  `loader/credentials`。
- ESP 备份不包含 NVRAM；NVRAM 恢复要用私有 inventory 中的 `efibootmgr -v`。

### 15.2 默认项变成 NixOS

在 Arch 或 Live ISO 中挂载 ESP：

```bash
sudo mkdir -p /mnt
sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt
sudo cat /mnt/loader/loader.conf
```

**【需要用户二次授权】** 修改默认项：

```bash
sudo sed -i -e '/^default /d' -e '/^preferred /d' /mnt/loader/loader.conf
printf 'default arch-linux-lts.efi\n' | sudo tee -a /mnt/loader/loader.conf
sudo cat /mnt/loader/loader.conf
sync
sudo umount /mnt
```

如果 Arch UKI 文件名已变化，先 `find /mnt/EFI/Linux -maxdepth 1 -type f` 确认，
不要照抄旧名字。

### 15.3 Arch UKI 丢失或损坏

先确认 ESP 挂载点和文件：

```bash
sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt
sudo ls -l /mnt/EFI/Linux
sudo sha256sum /mnt/EFI/Linux/arch-linux-lts.efi
```

**【需要用户二次授权】** 只从备份恢复该文件：

```bash
sudo tar -C /mnt -xzf <ARCH_ESP_BACKUP> ./EFI/Linux/arch-linux-lts.efi
sudo sha256sum /mnt/EFI/Linux/arch-linux-lts.efi
sync
sudo umount /mnt
```

如果整个 `EFI` 目录损坏，可恢复整个归档；这不会删除 NixOS 的
`EFI/nixos`，但会用备份版本覆盖 `EFI/systemd`、`EFI/BOOT` 和
`loader/loader.conf`：

```bash
sudo tar -C /mnt --numeric-owner --xattrs --acls -xzf <ARCH_ESP_BACKUP>
```

恢复后确认：

```bash
sudo find /mnt/EFI/Linux /mnt/EFI/systemd /mnt/EFI/BOOT -maxdepth 2 -type f -printf '%s %p\n'
sudo cat /mnt/loader/loader.conf
```

### 15.4 systemd-boot 损坏

现象：固件能识别“Linux Boot Manager”，但选择后黑屏/报错；或 `bootctl` 报
ESP 上的 systemd-boot 无效。

从 **Arch Live ISO** 启动（UEFI），确认设备后：

```bash
lsblk -o NAME,SIZE,FSTYPE,PARTUUID,MOUNTPOINTS
sudo mount -o subvol=@ /dev/disk/by-uuid/<BTRFS_UUID> /mnt
sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt/boot
sudo arch-chroot /mnt
```

在 chroot 内 **【需要用户二次授权】**：

```bash
# 先恢复文件，再安装引导器
# 如果归档在外部介质，先把它挂载/复制进 chroot
tar -C /boot --numeric-owner --xattrs --acls -xzf /path/to/arch-esp-backup.tar.gz
bootctl install
exit
```

`bootctl install` 会写 ESP 和 NVRAM；如果只想恢复文件、不动 NVRAM，先只做 tar
恢复，再重启看固件原入口是否恢复。

如果 `arch-chroot`/`bootctl` 不可用，可用 NixOS ISO 的 `bootctl` 做临时恢复，
但 Arch 的 systemd-boot 版本可能不同；优先使用 Arch ISO。

### 15.5 NVRAM 入口丢失/顺序改变

先只读确认：

```bash
sudo efibootmgr -v
```

找到指向共享 ESP 的 `Linux Boot Manager` 项和它的 `Boot####`。如果项还在但顺序
不对，**【需要用户二次授权】**：

```bash
# 假设原顺序是 0005,2001,0000,2002,2003；以实际 efibootmgr 输出为准
sudo efibootmgr -o 0005,2001,0000,2002,2003
```

如果项被删除，需要重新创建。**不要猜设备名/分区号**；先用 `lsblk` 和
`efibootmgr -v` 确认：

```bash
sudo efibootmgr -c -d <NVME_DISK> -p 1 \
  -L "Linux Boot Manager" -l '\EFI\systemd\systemd-bootx64.efi'
```

`<NVME_DISK>` 必须是实际系统盘，`-p 1` 必须是 ESP 分区号。创建后用
`efibootmgr -v` 检查路径和顺序。若不确定，优先在 Arch chroot 中运行
`bootctl install`，让它生成正确入口。

### 15.6 NixOS 启动失败，但 Arch 仍可启动

1. 重启，选择 Arch（默认项）。
2. 检查 ESP：

   ```bash
   sudo bootctl list
   sudo find /boot/EFI/nixos /boot/loader/entries -maxdepth 2 -type f -printf '%s %p\n'
   sudo cat /boot/loader/loader.conf
   ```

3. 如果只是 NixOS 条目缺失/损坏，**不要删除 Arch**；可以先继续用 Arch。需要修
   NixOS 时，从 Live ISO 重新挂载 `@nixos` 并重跑 `nixos-install`，或进入 NixOS
   的旧 generation（如果菜单里有）。
4. 如果 ESP 的 systemd-boot 也损坏，按 15.4 恢复；Arch 启动优先。

### 15.7 Arch 启动失败，但 NixOS 可启动

1. 启动 NixOS。
2. 只读检查 ESP 和 Arch UKI：

   ```bash
   sudo mount /dev/disk/by-uuid/<ESP_UUID> /mnt
   sudo ls -l /mnt/EFI/Linux /mnt/loader/loader.conf
   sudo cat /mnt/loader/loader.conf
   ```

3. 按 15.2/15.3 恢复默认项或 UKI。
4. 如需从 NixOS 访问 Arch 根做恢复，**【需要用户二次授权】** 只读/按需挂载：

   ```bash
   sudo mkdir -p /mnt/arch-root
   sudo mount -o subvol=@,ro /dev/disk/by-uuid/<BTRFS_UUID> /mnt/arch-root
   ```

   确认对象后再决定是否读写；不要直接格式化或删除 Arch 子卷。
5. 如果 systemd-boot 也损坏，使用 Arch Live ISO 按 15.4 恢复。

### 15.8 挂错子卷/安装到一半

- 发现 `/mnt` 是 `@`、`/mnt/home` 是 `@home` 时：立即停止，卸载
  `/mnt/boot /mnt/nix /mnt/home /mnt`，不要运行 `nixos-install`。
- 已经误写：不要执行 `rm -rf`。先确认哪些文件被写到了哪个子卷；Arch 的
  `@`/`@home` 是否只是多了目录。把情况记录下来，向用户申请恢复授权。
- 如果 `@nixos` 被误装但 Arch 未受影响：可以保留 `@nixos` 供检查，或经授权后
  删除并重建；不要在未确认前删除。
- 如果 ESP 被部分写入：用 ESP 备份恢复，按 15.3/15.4 处理。

---

## 16. ESP 与 Arch 回退细节

### 16.1 Arch UKI、systemd-boot 和 loader 文件位置

本次检查确认：

```text
/boot/EFI/Linux/arch-linux-lts.efi          Arch UKI，约 60 MiB
/boot/EFI/systemd/systemd-bootx64.efi       systemd-boot 主文件
/boot/EFI/BOOT/BOOTX64.EFI                  systemd-boot 回退文件
/boot/EFI/Lenovo/BIOS/SelfHealing.fd        Lenovo 厂商文件，约 32 MiB
/boot/loader/loader.conf                    timeout 3，无 default
/boot/loader/entries/                       空；Arch 用 Type #2 UKI
/boot/loader/entries.srel
/boot/loader/random-seed
/boot/loader/credentials/nvpcr-anchor.*.cred
/boot/loader/keys/                          空
/boot/amd-ucode.img
/boot/vmlinuz-linux-lts
```

NixOS 安装后新增：

```text
/boot/EFI/nixos/...                          NixOS kernel/initrd
/boot/loader/entries/nixos-*.conf            NixOS Type #1 条目
```

NixOS builder 只清理 `nixos-*` 条目和 `EFI/nixos` 下的旧文件；它不会主动删除
Arch UKI、`EFI/Lenovo`、`loader/random-seed` 或 `loader/credentials`。但它会
覆盖 `EFI/systemd/systemd-bootx64.efi`、`EFI/BOOT/BOOTX64.EFI` 和
`loader/loader.conf`，所以 ESP 备份必须包含整个 `/boot`。

### 16.2 如何避免 NixOS 占满 ESP

- `hosts/main/boot.nix` 固定 `configurationLimit = 3`；
- 不启用 NixOS UKI；不使用 boot counting；不添加大量 specialisation；
- 每次重建后检查 `df -h /boot`；
- ESP 空闲低于 200 MiB 时，先确认旧 NixOS generation 不再需要，再通过 NixOS
  GC/减少 generation 释放；不要手动删 Arch 文件；
- 不要运行 `bootctl cleanup`，除非你确认它不会删除 Arch 的自动发现 UKI；
- 不要把 NixOS kernel/initrd 手工复制到 ESP。

按当前 43 MiB/代、limit 3 计算，NixOS 约占 130 MiB；ESP 现有 914 MiB 空闲，
余量充足。

### 16.3 安装后如何验证 Arch 启动项仍存在

```bash
sudo bootctl list
sudo cat /boot/loader/loader.conf
sudo find /boot/EFI/Linux /boot/EFI/nixos /boot/loader/entries \
  -maxdepth 2 -type f -printf '%s %p\n'
```

必须看到：

- Arch UKI 的 Type #2 条目；
- 至少一个 NixOS 条目；
- `loader.conf` 默认 Arch；
- `EFI/Lenovo/BIOS/SelfHealing.fd` 仍在。

### 16.4 如果默认启动项改变

优先在 systemd-boot 菜单中选中 Arch，按 `d` 设置默认（如果当前 systemd-boot
支持）；或按 15.2 直接编辑 `loader.conf`。编辑后 `sync`，并确认：

```bash
grep -n '^default ' /boot/loader/loader.conf
```

### 16.5 如果 systemd-boot 损坏

见 15.4。核心顺序：

1. 从 Arch Live ISO UEFI 启动；
2. 挂载 Arch `@` 和 ESP；
3. `arch-chroot`；
4. 从 ESP 备份恢复文件；
5. `bootctl install`（写 ESP/NVRAM，需授权）；
6. 退出、sync、重启，确认 Arch。

---

## 17. Arch 数据共享方案（NixOS 运行后）

### 17.1 只读挂载

`hosts/main/default.nix` 已声明：

```nix
fileSystems."/mnt/arch-home" = {
  device = config.fileSystems."/".device;
  fsType = "btrfs";
  options = [ "ro" "relatime" "subvol=@home" "nofail" ];
};
```

- 设备复用 NixOS 根设备字符串，不重复写 UUID；
- `subvol=@home`；
- `ro` 默认只读；
- `nofail`：Arch 家目录不可用时 NixOS 仍能启动；
- 不挂载 `@`、`@log`、`@pkg`；
- 不把 `/mnt/arch-home` 作为 `/home`；
- 不让 Home Manager 管理 `/mnt/arch-home`；
- 不在 `/mnt/arch-home` 下创建/修改文件。

### 17.2 权限

NixOS 用户 UID/GID 必须是 1000:1000，才能读取 Arch 的 0700 家目录。检查：

```bash
id
getent group calendar
sudo -u calendar test -r /mnt/arch-home/calendar/life && echo readable
```

本配置只对齐 **primary** UID/GID 1000:1000。Arch 的附加组 GID（`wheel` 998、
`docker` 964、`video` 983、`render` 987）与 NixOS 同名组的默认 GID 不一定相同；
如果 Arch 家目录里有仅靠这些组权限可读的文件，NixOS 用户可能读不到。不要为了
读取而 `chmod -R`；需要时再单独评估附加组 GID 映射。

如果读不到：

- 确认 `hosts/main/default.nix` 的 `uid`/`group`；
- 确认重新安装后 `/home/calendar` 属主；
- 不要 `chmod -R` 放宽 Arch 家目录权限。

### 17.3 明确不共享的内容

- 不复制 Arch 整个 `~/.config`、`~/.local`；
- 不复用 Arch 的 Python `.venv`、`node_modules`、`.direnv`；
- 不直接共享运行中的 Docker 数据（`/var/lib/docker`、`/var/lib/containerd`）；
- 不共享 Windows VM 磁盘/快照；
- 不自动向 Arch 科研目录写入结果；
- 不把 Arch 的 SSH/GPG/age 私钥复制到 NixOS；需要时用独立密钥或 SSH agent
  转发。

将来如果决定长期使用 NixOS，再单独设计读写共享（独立数据子卷、明确的 UID/GID
映射、备份策略）。本轮不创建共享数据子卷，不移动 Arch 目录。

---

## 18. 仓库变更和验证结果

### 18.1 配置变更

| 文件 | 变更 |
| --- | --- |
| `modules/base.nix` | 移除 systemd-boot 设置，只保留通用 `boot.supportedFilesystems` |
| `hosts/nixos/boot.nix` | 新增；原样保留小主机 systemd-boot 行为 |
| `hosts/nixos/default.nix` | 导入 `./boot.nix` |
| `hosts/main/default.nix` | 新增主力机 host 骨架；独立 hostname、UID/GID、只读 Arch home、无 fake hardware |
| `hosts/main/boot.nix` | 新增；limit 3、canTouch false、`extraInstallCommands` 只改 `loader.conf` 的 default 行并自校验 |
| `flake.nix` | host 工厂函数；`main` 仅在真实 hardware 文件存在时暴露 |
| `docs/ARCH_DUAL_BOOT.md` | 本文 |

小主机 `nixosConfigurations.nixos` 的 boot 选项保持：

```text
systemd-boot.enable = true
configurationLimit = 20
canTouchEfiVariables = true
timeout = 3
```

### 18.2 本轮实际验证

已执行：

```bash
nix flake check --show-trace
# all checks passed!

nixos-rebuild build --flake .#nixos
# Done. The new configuration is /nix/store/...-nixos-system-nixos-...

git diff --check
# 通过（无输出）
```

说明：

- `nix flake check` 检查的是当前可见的 `nixosConfigurations.nixos`；
- `nixosConfigurations.main` 因为 `hosts/main/hardware-configuration.nix` 尚不
  存在而**故意没有求值**；生成该文件并 `git add` 后，`nix flake show` 会出现
  `main`，届时再跑 `nix flake check` 和 `nixos-rebuild build --flake .#main`；
- 没有在真实 NixOS 子卷上安装，也没有验证 NixOS 首次启动；
- `main` 的结构已用**一次性临时 UUID**在 `/tmp` 的仓库副本里验证过（`main`
  会出现，UID/GID 1000:1000、`limit 3`、`canTouch false`、`timeout 5`、
  `gc.automatic false`、`/mnt/arch-home` 只读 `@home` 都符合预期）。那份
  hardware 文件**没有**进入仓库，也不能当作真实硬件配置使用；
- 安装时 `hosts/main/hardware-configuration.nix` 仍必须由 ISO 里的
  `nixos-generate-config` 生成。

### 18.3 安装前最终 Go/No-Go

Go 必须同时满足：

- [x] Restic 最新快照存在，`restic check` 通过（`ac6daca1`，2% 抽样无错）；
- [ ] Restic 密码独立恢复副本可用（本轮只确认 `~/.local/state/restic-arch/password`
  能解锁仓库；**离线/异地副本仍需你自己确认**）；
- [x] ESP 全量归档已复制到小主机，SHA256 校验通过，且在临时目录解包并比对；
- [x] `efibootmgr -v` 和 `bootctl status/list` 已保存；
- [x] Ventoy 中有经过校验的 NixOS Minimal ISO（26.05，SHA256 与官方一致）；
- [x] Ventoy 中有可读取的最新配置副本（`nixos-install/repo`，无 secrets）；
- [x] flake 输入已离线化（`nixos-install/cache`，已用空 store + `--offline` 验证）；
- [ ] ISO 中直连小主机的网络方案已实测（步骤见 4.3，**尚未在 ISO 内执行**）；
- [ ] ISO 内代理/镜像下载已实测（Arch 侧已验证 TUNA 与 SSH 隧道，**ISO 内仍待验证**）；
- [ ] 第 5 节设备/子卷/默认子卷确认通过；
- [ ] 第 6 节三个子卷创建成功，默认子卷仍为 5；
- [ ] 第 7 节 `findmnt` 显示 `@nixos`/`@nixos-home`/`@nixos-nix`/ESP；
- [ ] 第 8 节 hardware 文件无 `subvol=@`、无 Arch home；
- [ ] 第 9 节 `nixosConfigurations.main` 出现；
- [ ] 第 10 节 `nix flake check` 和 main 构建通过；
- [ ] ESP 空闲 ≥ 300 MiB，Btrfs 空闲 ≥ 100 GiB；
- [ ] 笔记本接电源；
- [ ] 用户明确授权 `nixos-install`。

No-Go（任一即停）：

- 任何设备/UUID/子卷与记录不符；
- 出现 `@nixos` 同名子卷；
- 默认子卷不是 5；
- `/mnt` 挂到 `@` 或 `/mnt/home` 挂到 `@home`；
- 找不到 Arch UKI；
- ESP 空闲不足；
- Secure Boot 意外开启；
- 构建出的 fstab 含错误 subvol；
- Restic/ESP 备份未验证；
- 用户未授权安装。

---

### 18.4 本轮（安装前最后准备）实际完成的操作

在 Arch 上以只读 + 新增备份的方式完成，没有改动 Arch 的磁盘布局、ESP、UKI 或
NVRAM（`/boot` 的树哈希在操作前后完全一致）。

| 项目 | 结果 |
| --- | --- |
| ESP 归档 | `/var/tmp/arch-esp-20261024-130607.tar.gz`，96081799 字节，22 个条目 |
| ESP 归档 SHA256 | `9cf3b524e43b4d943d6926d9e1b4d88cc44515a55e9472e8fd0b6edecde3ca4d` |
| 小主机副本 | `~/arch-esp-backups/`，`sha256sum -c` 通过 |
| 解包验证 | 临时目录解包后 `diff -rq /boot <restore>` 无差异，`loader.conf` 与 UKI 哈希一致 |
| 状态记录 | `~/arch-nixos-install-inventory/arch-esp-state.20261024-130607.txt`（含 `bootctl status/list`、`efibootmgr -v`、子卷列表、默认子卷） |
| Ventoy 离线 flake 输入 | `<VENTOY>/nixos-install/cache`（41 MiB）+ `repo/`（2.0 MiB）+ `README-ISO.txt` |
| Restic | 新增 P0 快照 `ac6daca1`（8.940 GiB，父 `9c4175de`），`check --read-data-subset=2%` 无错误 |

Restic 快照现状（未执行 forget/prune/unlock/repair）：

```text
b26c577f  arch-p0          8.869 GiB
2e35889c  arch-research   84.462 GiB
6b560fb6  arch-windows-vm 64.004 GiB
9c4175de  arch-p0          8.922 GiB
ac6daca1  arch-p0          8.940 GiB
```

仓库里有两个 2026-10-24 10:22 的非独占锁（`6c62a55e`、`bb66bc7e`），对应的
PID 948858/948886 已不存在。本轮全程用 `--no-lock` 读取，**没有执行
`restic unlock`**；下次正常 `restic backup` 时 restic 会自动清理陈旧锁。

## 19. 首次安装后的待办（不在本轮）

- 为 NixOS 单独配置 Restic/备份介质，不复用 Arch 的 Restic 仓库，不把 NixOS
  数据写进 Arch 的备份目标。
- 确认 NixOS 首次启动和至少一次 rollback 后，再启用 `nix.gc.automatic` 或调整
  `configurationLimit`。
- 需要 SSH 时，单独启用 `services.openssh` 并安装用户公钥；不要复制 Arch 私钥。
- 需要 Tailscale 时，运行 `sudo tailscale up`；不要把 auth key 写进 Nix store。
- 需要 Clash Verge 时，在 NixOS 中单独导入订阅；不要复用 Arch 的运行目录。
- 需要蓝牙时，再启用 `hardware.bluetooth.enable` 和相应桌面工具。
- 需要 Secure Boot 时，另做 UKI/systemd-boot 签名方案；当前未签名，Secure Boot
  必须保持关闭。
- 需要读写共享 Arch 数据时，另建数据子卷/明确挂载策略，不要直接把
  `/mnt/arch-home` 改成 `rw`。

---

## 20. 相关文档

- `docs/RECOVERY.md`：安装、TTY/桌面恢复、网络、SOPS、Restic 演练。
- `docs/MIGRATION.md`：稳定性收尾、密钥/备份清单、Arch 迁移边界。
- `docs/DEVELOPMENT.md`：devShell、tmux、容器评估。
- `README.md`：日常构建、更新、回滚和远程登录。
