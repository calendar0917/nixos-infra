# Arch 主力机 NixOS 双系统安装手册

> **现场唯一入口：仓库根目录的 `START_HERE.txt`，以及 Ventoy 上的
> `<VENTOY>/nixos-install/START_HERE.txt`。**
> 进入 ISO 后只打开这一份速查表，按 A/B/C/D 阶段执行；不要在现场通读本文。
> 本文保留背景、边界、完整命令和恢复步骤，供排障时查阅。

本文是 **Arch 主力机** 的安装操作手册，不是通用教程。目标是在现有 Btrfs
文件系统中新增独立 NixOS，同时原样保留 Arch、Arch Home、Snapper 快照和 Arch
UKI；两套系统共享现有 1 GiB ESP，默认仍启动 Arch。

> **本轮状态（2026-10-27）**
>
> - 已完成只读硬件/启动检查、仓库 host 拆分、`START_HERE.txt` 现场入口和
>   `install-preflight.sh` 只读防误检查。
> - 已复现直连网络故障：两端有线 carrier 都是 1/1000 Mbps，但
>   `direct-nixos`、`direct-arch` 都是 `autoconnect no` 且未激活；临时激活后
>   `10.77.77.1/2` 互通、SSH 22 和主机指纹验证通过。**没有**修改持久网络配置。
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
- 新增现场唯一入口 `START_HERE.txt` 和只读防误检查 `install-preflight.sh`。
- 复现了直连网络故障：两端 carrier=1/1000，但 `direct-*` 都是
  `autoconnect no` 且未激活，自动 DHCP profile 会抢占同一网卡。临时激活后
  `10.77.77.1/2`、SSH 22 和主机指纹验证通过；**没有**修改持久网络配置。
- ESP 备份已复制到小主机并完成解包/校验（见 3.4、18.4）。
- `nix flake check` 通过；`nix build .#nixosConfigurations.nixos.config.system.build.toplevel` 通过。

没有完成（本轮禁止）：

- 没有运行 `nixos-generate-config`，没有生成/提交 `hosts/main/hardware-configuration.nix`。
  没有编造 UUID、subvol、swap 或 CPU 声明。
- 没有创建 `@nixos`、`@nixos-home`、`@nixos-nix`，没有挂载安装目标。
- 没有安装、没有设置密码、没有重启。
- 没有修改 `direct-nixos`/`direct-arch` 的持久 autoconnect 配置；没有物理拔插
  ISO 内的网线测试。

### 0.3 真正安装前需要用户二次授权的操作

以下每一项都必须单独确认后再执行：

1. 修改 `direct-nixos`/`direct-arch` 的持久 `autoconnect`/priority（见 4.3.2）。
2. 向 U 盘写 NixOS ISO（会覆盖该 U 盘）。
3. 在 Btrfs 顶层创建三个 `@nixos*` 子卷。
4. 挂载 `/mnt`、`/mnt/home`、`/mnt/nix`、`/mnt/boot` 作为安装目标。
5. 运行 `nixos-install --flake .#main`。
6. 让 NixOS 的 bootloader 步骤写共享 ESP（会更新 systemd-boot 二进制和
   `loader.conf`）。
7. 如需恢复默认启动项，编辑 `loader.conf` 或写 `efibootmgr`。
8. 任何 ESP 恢复、`bootctl install`、`efibootmgr -c/-o/-B`。

**没有第 5 项授权，不要运行 `nixos-install`。**

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
/run/btrfs-root/@nixos
/run/btrfs-root/@nixos-home
/run/btrfs-root/@nixos-nix
```

创建后必须卸载顶层挂载，不要把它留在 `/run/btrfs-root`。不要执行
`btrfs subvolume set-default`。

---

## 3. 安装前准备

### 3.1 安装介质：Graphical 优先，Minimal 备用

本地已有的两个 26.05 ISO（以实际文件为准；Ventoy 上的文件名可能不同）：

| 用途 | 本地文件 | ISO `version.txt` | 大小（字节） | SHA256 |
| --- | --- | --- | --- | --- |
| 首选 Graphical | `~/Downloads/latest-nixos-graphical-x86_64-linux.iso` | `26.05.12297.cd4ea8d57de1` | 3888513024 | `a0c68e67c70e9698c7a5b5e7ba7d99531773491b09c4d5dbcce88e84d81bedea` |
| 备用 Minimal | `~/Downloads/latest-nixos-minimal-x86_64-linux.iso` | `26.05.12400.da6dc0e7b260` | 1744830464 | `bace94cc43946a95c6252b097cf627dbca6ec4b48d938d405c1043b0a2f0cffb` |

这两个文件都能启动；**现场优先 Graphical ISO，使用终端手动安装，不使用
Calamares 自动分区**。Minimal ISO 只作为备用，操作命令与 START_HERE 相同。

2026-10-27 官方 `channels.nixos.org/nixos-26.05/latest-*` 已更新到
`26.05.12707.718f670e8453`，其 SHA256 与本地文件不同。**不要因为 latest
更新就替换已经启动成功并校验过的文件。** 如果重新下载，必须重新核对官方
SHA256，并确认 `VERSION_ID=26.05`；不要把 26.11 或其他版本当作本次安装介质。

重新校验（只读）：

```bash
sha256sum ~/Downloads/latest-nixos-graphical-x86_64-linux.iso
sha256sum ~/Downloads/latest-nixos-minimal-x86_64-linux.iso
# 与上表逐字比对；官方 latest 变化时不要盲目覆盖已验证文件
```

**为什么是 26.05 而不是 flake 锁定的 26.11 pre**：`system.stateVersion` 取的是
“首次安装时所用介质的发行版本”，与 `flake.lock` 里 nixpkgs 的版本无关。这个
ISO 的 `nixos-generate-config` 写出的就是 `26.05`，因此 `hosts/main/default.nix`
也固定为 `26.05`。升级 nixpkgs 不改变 stateVersion。

Ventoy 使用方式（不需要 `dd`、不需要重装 Ventoy）：

- 只把 ISO 文件复制进 Ventoy 数据分区；
- 不要重建分区表、不要运行 `Ventoy2Disk`、不要执行 `dd`；
- 固件启动菜单里选 `UEFI: <USB>`，进入 Ventoy 菜单后选 Graphical ISO；
- 本机 Secure Boot 关闭，ISO 可以直接启动。

停止条件（任一即停）：

- 本地文件 SHA256 与记录不一致，或下载后没有核对官方值；
- ISO 文件被截断（Graphical 不等于 3888513024，Minimal 不等于 1744830464）；
- `VERSION_ID` 不是 26.05；
- 误把 ISO 写到 NVMe 或 ESP，或准备用 Calamares 自动分区。

### 3.1b Ventoy 上的离线材料（现场入口 + Flake 输入）

Ventoy 数据分区中的目标布局：

```text
<VENTOY>/nixos-install/
├── START_HERE.txt          唯一现场操作入口（先打开它）
├── install-preflight.sh    只读防误检查（从 repo 同步）
├── repo/                   nixos-infra 工作树（无 secrets、无 main hardware；
│                           保留 mini hardware，供 nixosConfigurations.nixos 求值）
└── cache/                  四个 Flake 输入的本地二进制缓存（约 41 MiB）
```

旧的 `README-ISO.txt` 不再作为操作入口；同步时删除它，或只保留一行
“打开 START_HERE.txt”。不要在 ISO 里要求用户先读多个 README。

`cache/` 由 Arch 上执行 `nix copy --to file://...` 生成，内容是
`nix flake archive` 给出的四个 `*-source` 路径：

```text
/nix/store/fkrgkr1glraxczxx0i9gm9zqjd118i2p-source   nixpkgs 26.11pre1097682
/nix/store/3f2hfr82vxncf7ax3d02wh22p0dby1b6-source   home-manager ec80131
/nix/store/9xlfs4fc7h82mkvvnifbhng24082gqin-source   sops-nix 4493170
/nix/store/1pmshh4a1vizyzhzr1x8rv0cz0lgjhnx-source   flake source
```

现场只按 `START_HERE.txt` A2/A3 执行：Ventoy 只读挂载到 `/run/ventoy`，
repo 复制到 `/root/nixos-infra`。如果该目录已有含 main hardware 的工作树，必须
保留，不得用 Ventoy 内容覆盖；也不要 `rm -rf` 或 `git add -A` 把 secrets 加入
Git。A3 会导入全部 cache 并执行离线 metadata。

`--offline` 是关键：它让 Nix 只用本地 store，不去 GitHub 重试。`nix copy --all`
导入 cache 中的全部路径，不依赖本文列出的四个 hash。若 `flake metadata` 仍访问
网络，说明缓存不完整，先回 Arch 重新 `nix flake archive` + `nix copy`。

**这只是 Flake 输入，不是整个闭包。** nixpkgs 的约 9.5 GiB store path 不放进
U 盘，安装/构建时仍从 TUNA 镜像或经 SSH 隧道下载。缓存失效条件：`flake.lock`
变了就重新在 Arch 上生成 cache。

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

从固件启动菜单选择 **UEFI: <USB>**。进入 Graphical ISO（备用：Minimal ISO）后：

```bash
test -d /sys/firmware/efi && echo "UEFI boot"
cat /etc/os-release
bootctl status | sed -n '1,12p'
```

预期：

- `UEFI boot`；
- ISO 版本是 26.05（`VERSION_ID=26.05`；Graphical 26.05.12297 或
  Minimal 26.05.12400 都可），与 `hosts/main/default.nix` 的
  `system.stateVersion = "26.05"` 一致；
- `Secure Boot: disabled`；
- 能联网（`ping`/`curl` 或 `nix flake` 能取输入）。

如果 Secure Boot 显示 enabled：**停止**。当前 Arch UKI 和 NixOS
systemd-boot 都未签名，不能在该状态下继续；先在固件中关闭 Secure Boot，
或另做签名方案（不在本轮范围）。

### 4.3 直连网络：已复现的故障、恢复和 ISO 流程

#### 4.3.1 2026-10-27 的实际状态

| 机器 | 有线口 | carrier | speed | 直连 profile | autoconnect | 检查时 active | IP |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Arch 主力机 | `enp2s0` | 1 | 1000 Mbps | `direct-nixos` | no | disconnected | 无 |
| NixOS 小主机 | `enp2s0` | 1 | 1000 Mbps | `direct-arch` | no | disconnected | 无 |

两端的直连 profile 本身是正确的：接口绑定到 `enp2s0`，IPv4 手动
`10.77.77.1/30` / `10.77.77.2/30`，IPv6 disabled，gateway/DNS 为空，
`ipv4.never-default yes`。问题不在地址、网线 carrier 或代理。

同一张网卡上还存在 NetworkManager 自动创建的 DHCP profile：

| 机器 | DHCP profile | autoconnect | priority | 结果 |
| --- | --- | --- | --- | --- |
| Arch | `Wired connection 1` | yes | 10 | 直连 profile 停用后会抢占 `enp2s0`，等待 DHCP |
| mini | `有线连接 1` | yes | -999 | 直连 profile 停用后会抢占 `enp2s0`，等待 DHCP |

**实际故障原因**：`direct-nixos`/`direct-arch` 都是 `autoconnect no`。开机时
没有插线、或直连 profile 未被手动激活时，插线不会启用它；同时自动 DHCP
profile 会抢占同一张网卡，在一条没有 DHCP 服务器的直连线上停在
`connecting (getting IP configuration)`，于是看不到 `10.77.77.2`。这不是
“网线没插好”，也不是“代理问题”。网线插着 ≠ NetworkManager 连接已激活。

本轮用只读检查 + 临时激活复现并验证：

```bash
# 在 Arch
sudo nmcli connection up direct-nixos
ping -c 3 10.77.77.2
# 在 mini（本地控制台或 Wi-Fi SSH）
sudo nmcli connection up direct-arch
```

临时激活后：

- Arch `enp2s0` 得到 `10.77.77.1/30`，mini 得到 `10.77.77.2/30`；
- 双向 ping 0% loss，速度为 1000 Mbps；
- SSH 22 开放，ED25519 主机指纹为
  `SHA256:Gd/ovkGpCU0OWv+3WLhfRJGcPeo2HG5yCg7nj7Rk6KU`；
- 两端默认路由仍走 Wi-Fi（Arch `wlp4s0`，mini `wlp1s0`），直连只增加
  `10.77.77.0/30` 路由；
- 两端都没有给直连添加 gateway 或 DNS。

**当前状态**：两个直连 profile 在本轮结束时仍处于 active，但这是运行态，
不是持久配置。重启、重新插线或 NetworkManager 重新选择 profile 后，仍可能
回到 disconnected/DHCP 抢占状态。

为验证“未激活时插线不会自动恢复”，本轮做了 `nmcli connection down` 加
`ip link down/up` 的 carrier flap（没有物理拔插网线）。结果两端都由自动 DHCP
profile 接管并停在 `connecting (getting IP configuration)`，直连 IP 不会自动
出现；重新 `nmcli connection up direct-*` 后立即恢复。物理拔插和 ISO 内行为
仍需现场验证。

#### 4.3.2 持久修复建议（需要用户授权）

优先方案：让直连 profile 自动连接，并让它优先于同网卡的 DHCP profile：

```bash
# 在 Arch 主力机
sudo nmcli connection modify direct-nixos \
  connection.autoconnect yes connection.autoconnect-priority 20

# 在 NixOS 小主机
sudo nmcli connection modify direct-arch \
  connection.autoconnect yes connection.autoconnect-priority 20
```

影响评估：

- 两个 profile 都绑定到各自机器的 `enp2s0`，只在这张网卡有 carrier 时生效；
- 不设置默认网关、不设置 DNS、IPv6 disabled，不会抢走 Wi-Fi 默认路由；
- 不修改 Wi-Fi、Clash Verge/Mihomo、Tailscale、SSH 认证或防火墙；
- 不向局域网或公网开放代理端口；mihomo 仍只监听 `127.0.0.1:7897`；
- 直连 SSH 22 会在对端可达，这是现有设计；仍需密码或公钥认证；
- 直连 profile 优先级高于 DHCP profile 后，如果把这根网线插到普通 DHCP
  局域网，机器会优先使用静态 `10.77.77.x/30`，该口没有默认路由；需要普通
  有线网时手动 `nmcli connection up "Wired connection 1"`（mini 上是
  `有线连接 1`）。这是可接受的取舍，但必须明确。

备选方案（更保守）：只把 mini 的 `direct-arch` 改为 autoconnect yes，Arch 侧
保持手动；或者两边都保留 `autoconnect no`，每次插线后手动 `nmcli connection
up direct-*`。前者仍可能被 DHCP profile 抢占，需要同时提高 priority；后者
最简单但需要人工操作。

**未授权前不要执行上面的 `nmcli connection modify`。** 修改前保留 Wi-Fi SSH
或本地控制台入口；修改后先用 `nmcli device status`、`ip route` 验证 Wi-Fi
默认路由未变，再做一次 physical replug 测试。

#### 4.3.3 ISO 内的连接流程

ISO 不会继承 Arch/mini 的 NetworkManager profile。按 START_HERE 阶段 B 执行，
核心顺序如下：

```bash
# 1. 识别真实有线口；不要固定假设 enp2s0
mapfile -t WIRED < <(for d in /sys/class/net/*; do n=${d##*/}; \
  [ -e "$d/device" ] || continue; [ -d "$d/wireless" ] && continue; echo "$n"; done)
printf '%s\n' "${WIRED[@]}"
test "${#WIRED[@]}" -eq 1 || { echo "STOP: exactly one wired NIC expected"; exit 1; }
W=${WIRED[0]}

# 2. 检查物理链路
ip -brief link show "$W"
cat "/sys/class/net/$W/carrier"   # 必须是 1
cat "/sys/class/net/$W/speed"     # 期望 1000

# 3. 只给 ISO 的直连口配置 IP；无 gateway、无 DNS
sudo nmcli connection add type ethernet ifname "$W" con-name iso-direct-nixos \
  ipv4.method manual ipv4.addresses 10.77.77.1/30 \
  ipv4.never-default yes ipv6.method disabled
sudo nmcli connection up iso-direct-nixos
ip -4 addr show "$W"
ip route

# 4. 先验证链路和 IP，再验证 SSH
ping -c 3 -W 2 10.77.77.2
ssh-keyscan -t ed25519 10.77.77.2 2>/dev/null | ssh-keygen -lf -
timeout 5 bash -c '</dev/tcp/10.77.77.2/22' && echo "SSH port open"
ssh calendar@10.77.77.2 hostname    # 应输出 nixos
```

如果 `carrier=0`：停在物理层，检查网线、网口、协商；不要继续配 IP。
如果有 carrier、有 `10.77.77.1/30` 但 ping 不通：优先在 mini 上确认
`direct-arch` 是否 active；如果 mini 的自动 DHCP profile 正卡在
`connecting`，先 `sudo nmcli connection up direct-arch`。如果 mini 无法通过
Wi-Fi SSH 或本地控制台登录，按 4.3.4 分层排障，不要先重启。

#### 4.3.4 ISO 的 SSH 认证

ISO 是全新 Live 环境，不继承 Arch 的 SSH 私钥或 agent。顺序：

1. 优先用 mini 的 `calendar` 密码登录。当前 NixOS 的
   `PasswordAuthentication` 仍是默认开启；密码只输入到当前 SSH 会话，不写入
   Ventoy 或仓库。
2. 只有在密码登录不可用时，才从原系统只读访问 Arch 私钥：在 ISO 中只读挂载
   Btrfs `@home` 到 `/run/arch-home`，然后原地引用
   `/run/arch-home/calendar/life/secrets/ssh/id_rsa`。**不要**把私钥复制到 `/root`、
   Ventoy 或任何 U 盘目录。
3. 首次连接必须核对主机指纹；不要使用
   `StrictHostKeyChecking=no`，也不要先接受再检查。
4. SSH 隧道只在需要 mini 的 `127.0.0.1:7897` 代理时建立；不需要时不要开。

#### 4.3.5 代理和 Nix 下载的优先级

1. **ISO 自身网络 + TUNA / cache.nixos.org**：先用
   `curl -sS -o /dev/null -w '%{http_code}\n' --max-time 20 \
   https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info`
   验证返回 200；能直接下载就不启用代理。
2. **SSH 隧道 + mini 的 `127.0.0.1:7897`**：只有 ISO 自身无外网、但 mini 的
   代理可用时才使用。隧道命令和 `http_proxy`/`https_proxy` 设置见
   START_HERE B5；不要改 mihomo 的 `allow-lan`、监听地址或防火墙。
3. **停止点**：如果 ISO 自身网络和 SSH 隧道都不可用，停止在只读检查，不要
   反复修改网络、关闭防火墙或猜测代理配置。Flake 输入缓存只解决 Flake
   metadata，不等于 9.5 GiB 软件包闭包；没有可用的 substituter 就不能构建/安装。

故障分层（不要把一切都归为“代理问题”）：

| 现象 | 先查 |
| --- | --- |
| 没有 carrier / `LOWER_UP` | 网线、网口、协商、换线换口 |
| 有 carrier 但没有 `10.77.77.1/30` | NetworkManager profile 是否创建/激活；DHCP profile 是否抢占 |
| 有 IP 但 ping 不通 | 另一端 `direct-arch`/`direct-nixos` 是否 active、路由、防火墙 |
| 能 ping 但 SSH 拒绝 | sshd、22 端口、用户、主机密钥 |
| SSH 正常但代理失败 | 隧道是否建立、mihomo 是否监听 `127.0.0.1:7897` |
| 代理正常但 Nix 下载失败 | Nix daemon、substituter、Flake 缓存、代理环境变量 |

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
sudo mkdir -p /run/btrfs-root
sudo mount -o subvolid=5,ro /dev/disk/by-uuid/<BTRFS_UUID> /run/btrfs-root
sudo btrfs subvolume list -a -p -t /run/btrfs-root
sudo btrfs subvolume get-default /run/btrfs-root
sudo btrfs filesystem usage /run/btrfs-root
sudo umount /run/btrfs-root
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

sudo mkdir -p /run/btrfs-root
sudo mount -o subvolid=5 /dev/disk/by-uuid/<BTRFS_UUID> /run/btrfs-root

# 名字必须不存在；任何 test 失败都停止
test ! -e /run/btrfs-root/@nixos
test ! -e /run/btrfs-root/@nixos-home
test ! -e /run/btrfs-root/@nixos-nix

sudo btrfs subvolume create /run/btrfs-root/@nixos
sudo btrfs subvolume create /run/btrfs-root/@nixos-home
sudo btrfs subvolume create /run/btrfs-root/@nixos-nix

sudo btrfs subvolume list -a -p -t /run/btrfs-root
sudo btrfs subvolume get-default /run/btrfs-root

sudo umount /run/btrfs-root
```

### 6.3 预期结果

- 三个新子卷的 parent/top level 都是 5；
- 新 ID 不与现有 `@` 等冲突；
- 默认子卷仍然是 ID 5；
- `@`、`@home`、`@log`、`@pkg` 的 ID 和快照没有变化；
- 没有创建 `@/@nixos` 这类嵌套路径。

### 6.4 停止条件

- 任一 `test` 失败（已存在同名子卷）；失败时先
  `sudo umount /run/btrfs-root`，不要继续创建；
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

### 8.1b 为什么现在 `nix flake show` 只有 `nixos`

这是本轮最容易误判的地方：

- NixOS ISO 的 Live hostname 也是 `nixos`；`nixosConfigurations.nixos` 指的是
  **小主机** 的 `hosts/nixos`，不是“当前 ISO”，也不是主力机。
- `hosts/main/hardware-configuration.nix` 尚不存在；`flake.nix` 只有在
  `builtins.pathExists` 为真时才暴露 `main`。因此 `nix flake show` 只出现
  `nixos` 是**预期行为**，不是通用 flake error，更不表示 `main` 使用了小主机的
  hardware。
- 在这个状态下绝对不能执行 `nixos-install --flake .#nixos`；那会安装小主机的
  配置，而不是 Arch 主力机的 NixOS。

正确的顺序是：

1. 先完成第 6、7 节：创建并挂载三个 NixOS 专属子卷；`findmnt` 全部通过。
2. 只有挂载检查通过才运行 `nixos-generate-config --root /mnt`。
3. 把真实生成的 hardware 文件放入 `hosts/main/hardware-configuration.nix`。
4. 如果是 Git Flake，`git add` 该文件，确保 Flake 能看到它。
5. 再运行 `nix flake show`，确认出现 `main`。
6. `./install-preflight.sh --target main` 必须通过；然后才构建 `#main`。
7. 只允许 `nixos-install --flake .#main`，且必须另行授权。

**绝不复制 `hosts/nixos/hardware-configuration.nix` 到 `hosts/main`。绝不为了让
main 出现而创建虚假 UUID、空白文件或占位 subvolume。**

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
git add hosts/main/hardware-configuration.nix
# 可做本地 commit，便于 Git Flake 看到该文件；不要 push
```

注意：

- 该文件包含 UUID；仓库是私有仓库，不要粘贴到公开 issue/聊天。
- 不要为了“让 flake 通过”而手写假 UUID。
- 如果仓库不是 git 仓库，确保该文件实际存在即可；flake 会直接读取。
- 优先把 `<REPO>` 放在 Linux 文件系统上。FAT/NTFS 上 `chown`/`chmod` 可能失败；
  如果仓库是 root 复制的，确保 `.git` 和文件对当前用户可写，或统一用 `sudo`
  执行 `git add`，不要留下 root 拥有的 index。
- 第 10.2 节会把完整非敏感仓库保存到 `/mnt/etc/nixos`；hardware 文件必须先进入
  `<REPO>`，否则持久配置里没有 `main`。

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

`hosts/main/boot.nix` 的 hook 在 NixOS 的 bootloader builder **之后**执行，做四件事：

1. 拒绝在不是独立文件系统的 `/boot` 上运行（Live ISO 的 `/boot` 属于 Live
   root，设备号与 `/` 相同）；
2. 如果 `/mnt/etc/nixos` 和 `/mnt/boot` 存在（`nixos-install` chroot 的 bind
   root），拒绝 `/boot` 与 `/mnt/boot` 设备号不一致的情况；
3. 删掉 `loader.conf` 里以 `default ` / `preferred ` 开头的行，追加
   `default arch-linux-lts.efi`；
4. 自校验：必须恰好一行 `default`，且内容等于 `default arch-linux-lts.efi`；
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

#### 执行上下文和 ESP 路径（源码核对）

本轮不是只做了 shell 语法检查，而是核对了实际生成脚本和 ISO 的安装器源码：

- Graphical ISO 26.05.12297 中的 `nixos-install` 在 bootloader 阶段执行
  `NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt -c '... switch-to-configuration boot'`；
  `nixos-enter` 最后 `exec chroot /mnt ...`。因此 hook 运行时 `/` 是目标
  `@nixos`，`/boot` 是目标 ESP。
- `nixos-install` 在 chroot 内先执行 `mount --rbind --mkdir / /mnt`，所以
  `/mnt` 是目标 root 的 bind，`/mnt/etc/nixos` 与 `/mnt/boot` 指向同一目标。
- flake 锁定的 nixpkgs 26.11 中，systemd-boot 模块把
  `extraInstallCommands` 追加在 `systemd-boot-builder` **之后**；
  `boot.loader.efi.efiSysMountPoint` 已显式设为 `/boot`。
- 用临时 main fixture 渲染出的 `install-systemd-boot.sh` 中，
  `efiSysMountPoint=/boot`，hook 使用 `/boot/loader/loader.conf`，并包含上面的
  设备号 guard。fixture 只用于验证渲染，不是真实 hardware，也没有进入仓库。

**残余风险**：本轮没有运行真实 `nixos-install`，所以“chroot 内 `/boot` 就是
目标 ESP”仍标记为**待 ISO 安装时验证**。D5/D6 之前必须再次执行
`findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt /mnt/boot` 和
`sudo test -f /mnt/boot/EFI/Linux/arch-linux-lts.efi`。如果 hook 报
“/boot is not a separate ESP”或“/boot and /mnt/boot are different filesystems”，
立即 STOP，不要绕过 guard，也不要手动运行生成的 install script。

已知取舍：hook 会覆盖你在 systemd-boot 菜单里手动设置的默认项。将来若想让 NixOS
当默认，先删掉这段 `extraInstallCommands`，再设置默认，否则下次 rebuild 会改回
Arch。

本轮用临时目录 + 真实渲染出的脚本验证过：

- 正常情况：`timeout 5` / `console-mode keep` / 自定义注释都保留，只多一行
  `default arch-linux-lts.efi`；
- 连续执行 3 次结果不变（幂等）；
- UKI 缺失时 `exit 1`，`loader.conf` 不被修改；
- 新增 guard 已出现在渲染脚本中；但 Live ISO 内的实际执行仍待验证。

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

先把非敏感仓库保存到目标系统，再从这份持久配置构建：

```bash
test ! -e <REPO>/secrets
sudo cp -a <REPO>/. /mnt/etc/nixos/
sudo rm -rf /mnt/etc/nixos/.git /mnt/etc/nixos/result /mnt/etc/nixos/result-*

cd /mnt/etc/nixos
nix flake show --offline
bash ./install-preflight.sh --repo /mnt/etc/nixos --target main
nix flake check --offline --show-trace
sudo nixos-rebuild build --flake /mnt/etc/nixos#main
```

预期：

- `/mnt/etc/nixos` 是完整、非敏感、可离线求值的 Flake；
- `nix flake show` 出现 `main`，`nixos` 仍然存在；
- `install-preflight.sh --target main` 必须通过；它要求 LENOVO 21LG、真实 main
  hardware、`/mnt`/`/mnt/home`/`/mnt/nix`/`/mnt/boot` 四项挂载和原 Arch ESP；
  缺少任一挂载会返回非零，不再是 pre-Phase-D PASS；
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
# 只从持久配置安装，确保重启后 /etc/nixos 与安装内容一致
sudo nixos-install --flake /mnt/etc/nixos#main --no-root-passwd --option substituters \
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
ls -l /etc/nixos/flake.nix /etc/nixos/hosts/main/hardware-configuration.nix
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
| `hosts/main/boot.nix` | limit 3、canTouch false、`efiSysMountPoint=/boot`；`extraInstallCommands` 增加 `/boot` 独立文件系统 guard，再固定 Arch 默认项并自校验 |
| `flake.nix` | host 工厂函数；`main` 仅在真实 hardware 文件存在时暴露 |
| `START_HERE.txt` | 唯一现场入口，Graphical 优先，A/B/C/D/E 全流程，341 行 |
| `install-preflight.sh` | 新增；只读检查 ISO/UEFI/main hardware/flake/git/目标挂载和 boot hook，拒绝 `#nixos` 目标 |
| `docs/ARCH_DUAL_BOOT.md` | 背景、网络复现、hardware 混淆说明、boot hook 上下文和验证结果 |
| `README.md` | 指向 `START_HERE.txt` 和 preflight，避免多份操作入口 |

小主机 `nixosConfigurations.nixos` 的 boot 选项保持：

```text
systemd-boot.enable = true
configurationLimit = 20
canTouchEfiVariables = true
timeout = 3
```

### 18.2 本轮实际验证（2026-10-27，Arch 环境）

已执行：

```bash
git diff --check
# 通过（无输出）

bash -n install-preflight.sh
# 通过

nix flake show
# 只有 nixosConfigurations.nixos；main 不存在是预期

nix flake check --show-trace
# all checks passed!

nix build --no-link '.#nixosConfigurations.nixos.config.system.build.toplevel'
# 成功，输出 nixos-system-nixos-26.11...（Arch 上没有 nixos-rebuild 命令，
# 因此用等价的 nix build；没有 activation/switch）
```

`install-preflight.sh` 的正常/失败路径：

| 场景 | 结果 |
| --- | --- |
| 当前仓库，无 `hosts/main/hardware-configuration.nix` | exit 10；输出 `MAIN HARDWARE NOT GENERATED — EXPECTED BEFORE INSTALLATION`；flake 只列 nixos |
| `--target nixos` | exit 2；明确拒绝，不退回小主机配置 |
| `/tmp` 仓库副本 + 真实 Arch UUID 的 main fixture，不带 `--target` | exit 0；只读报告 PASS，flake 出现 main |
| 同一 fixture + `--target main`，但 `/mnt` 未挂载 | exit 1；明确要求 `/mnt`/`/mnt/home`/`/mnt/nix`/`/mnt/boot` 四项挂载 |
| `/tmp` 仓库副本 + 直接复制 mini hardware | exit 1；检测到 byte-identical、UUID 不存在、`subvol=@` 错误 |
| `hosts/main` 存在但未 `git add` | 实测 exit 1；同时报 “flake does not expose main” 和 “not in the git index” |

说明：

- `/tmp` fixture **没有**进入仓库，不能当作真实 hardware，也没有用于安装；
- `main` 因为 `hosts/main/hardware-configuration.nix` 尚不存在而**故意没有求值**；
  生成该文件并 `git add` 后，`nix flake show` 才会出现 `main`；
- 已用 fixture 渲染 `install-systemd-boot.sh`，确认 `efiSysMountPoint=/boot`、
  hook 使用 `/boot/loader/loader.conf`，并包含 `stat -c %d` 的 ESP guard；
- 已只读挂载 Graphical/Minimal ISO 的 `nix-store.squashfs`，确认两个 ISO 的
  `system-path/bin` 都有 `git`、`nix`、`curl`、`ssh`、`nmcli`、`nixos-rebuild`、
  `nixos-install`、`nixos-generate-config`、`nixos-enter`、`btrfs`、`parted`、
  `bootctl`、`efibootmgr`、`rsync`；A3 的 `git init`、D4 的 generate、D5 的 build、
  D7 的 install 都可在两种 ISO 上执行。Minimal 未找到 GNU `install`，但现场流程
  不需要它；Ventoy 同步在 Arch 上完成。
- 没有在真实 NixOS 子卷上安装，也没有验证 NixOS 首次启动；
- 安装时 `hosts/main/hardware-configuration.nix` 仍必须由 ISO 里的
  `nixos-generate-config` 生成。

**待 ISO 验证（不能把 Arch 测试当作 ISO 成功）**：

- [ ] `ID=nixos`、`VERSION_ID=26.05`、`/nix/.ro-store` 为 squashfs；
- [ ] Ventoy 只读挂载、`START_HERE.txt`/repo/cache 可读；
- [ ] ISO 内自动识别有线口、carrier=1、配置 `10.77.77.1/30`；
- [ ] ISO 内 ping `10.77.77.2`、SSH 22、主机指纹、密码/密钥认证；
- [ ] ISO 内 TUNA 下载或 SSH 隧道代理；
- [ ] boot hook 在真实 `nixos-install` chroot 中的 `/boot` 行为。

### 18.3 安装前最终 Go/No-Go

Go 必须同时满足：

- [x] Restic 最新快照存在，`restic check` 通过（`ac6daca1`，2% 抽样无错）；
- [ ] Restic 密码独立恢复副本可用（本轮只确认 `~/.local/state/restic-arch/password`
  能解锁仓库；**离线/异地副本仍需你自己确认**）；
- [x] ESP 全量归档已复制到小主机，SHA256 校验通过，且在临时目录解包并比对；
- [x] `efibootmgr -v` 和 `bootctl status/list` 已保存；
- [x] 本机 Graphical/Minimal ISO 都是 26.05，SHA256 已记录（见 3.1）；
- [x] Ventoy 当前内容已重新核对：Graphical/Minimal ISO 的 SHA256 与本机文件一致；
  `cache/` 保留；`START_HERE.txt`、preflight、repo 与当前工作树同步；旧
  `README-ISO.txt` 和两个空垃圾文件已移除（见 18.5）；
- [x] 仓库内 `START_HERE.txt` 存在，341 行，唯一现场入口；
- [x] `install-preflight.sh` 无 main、错误 target、复制 mini hardware、未 git add、
  `--target main` 缺 target mounts 五条路径已实测；安装阶段要求 21LG、NixOS Live
  ISO、完整 `/mnt` 四挂载和原 Arch ESP；
- [x] Arch/mini 两端直连 profile 临时激活后 `10.77.77.1/2` ping、SSH 22、主机指纹
  通过；
- [ ] `direct-nixos`/`direct-arch` 的持久 autoconnect/priority 修改已获授权并完成；
- [ ] 物理拔插网线后两端能自动恢复到 `10.77.77.1/2`（当前 `autoconnect no` 不满足）；
- [ ] ISO 中直连小主机的网络方案已实测（步骤见 4.3/START_HERE，**尚未在 ISO 内执行**）；
- [ ] ISO 内代理/镜像下载已实测（Arch 侧已验证 TUNA 与 SSH 隧道，**ISO 内仍待验证**）；
- [ ] 第 5 节设备/子卷/默认子卷确认通过；
- [ ] 第 6 节三个子卷创建成功，默认子卷仍为 5；
- [ ] 第 7 节 `findmnt` 显示 `@nixos`/`@nixos-home`/`@nixos-nix`/ESP；
- [ ] 第 8 节 hardware 文件无 `subvol=@`、无 Arch home；
- [ ] 第 9 节 `nixosConfigurations.main` 出现；
- [ ] 第 10 节 `nix flake check` 和 main 构建通过；
- [ ] boot hook 在真实 ISO `nixos-install` chroot 中的 `/boot` 行为已验证；
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
- `install-preflight.sh` 报 FAIL，或目标不是 `main`；
- Restic/ESP 备份未验证；
- boot hook 的 `/boot` guard 报错；
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
| Ventoy 离线 flake 输入 | `<VENTOY>/nixos-install/cache`（41 MiB）+ `repo/`（2.1 MiB）；`README-ISO.txt` 已在 18.5 移除 |
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

### 18.5 2026-10-27 排障与现场入口（本轮）

| 项目 | 结果 |
| --- | --- |
| 现场入口 | `START_HERE.txt`，341 行；Graphical ISO 优先；A/B/C/D/E 全流程；D 需逐项授权 |
| 防误检查 | `install-preflight.sh`；默认只读；只接受 `--target main`；无 main 时 exit 10 并输出预期提示 |
| 网络根因 | 两端 `direct-*` 为 `autoconnect no` 且未激活；同网卡 DHCP profile 会抢占并等待 DHCP；拔插网线不会自动启用直连 |
| 网络临时验证 | Arch/mini 手动 `nmcli connection up direct-*` 后 10.77.77.1/2 互通、SSH 22 和 ED25519 指纹通过；默认路由仍在 Wi-Fi |
| 持久网络 | **未修改**；`autoconnect yes` + priority 20 的建议见 4.3.2，等待用户授权 |
| Hardware 混淆 | 已确认 ISO hostname 也是 nixos；`nixosConfigurations.nixos` 是小主机；main hardware 缺失时只显示 nixos 是预期 |
| Boot hook | 已核对 ISO 26.05 installer 的 `nixos-enter`/chroot 上下文，并渲染 main fixture 的 `install-systemd-boot.sh`；新增 `/boot` 设备号 guard。真实安装仍待 ISO 验证 |
| Ventoy 同步 | **已完成（2026-10-27 21:57）**：只读挂载 `/dev/disk/by-label/Ventoy` 后核对，两个 NixOS ISO 的 SHA256 与本机文件完全一致；`cache/` 保留；`START_HERE.txt` 341 行、preflight（SHA256 `00787369…`）、repo 已同步；`README-ISO.txt` 和 repo 根目录两个空垃圾文件已移除 |
| Ventoy 内容 | `nixos-install/repo` 含 mini hardware（`nixosConfigurations.nixos` 求值需要），不含 `secrets/`、不含 `hosts/main/hardware-configuration.nix`；`repo-commit.txt` 记录 base commit `fe146b7` + 未提交工作树快照、START_HERE/preflight 哈希 |
| 禁止操作 | 没有创建/删除子卷、没有格式化、没有挂载安装目标、没有写 ESP/UKI/NVRAM、没有 `nixos-install`、没有重启/GC/Restic 写入 |

Ventoy 同步/复核步骤（已执行一次；以后 U 盘重新挂载时按此复核）：

1. 用 `lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS` 确认 exfat 数据分区，不能
   假设 `/dev/sda1`；
2. 只读核对现有 `nixos-install/`，展示与仓库的差异后再写入；
3. 复制 `START_HERE.txt`、`install-preflight.sh`、最新 `repo/`；保留
   `cache/`，除非 `flake.lock` 已变化；repo 必须保留
   `hosts/nixos/hardware-configuration.nix`（否则 nixos 无法求值）；
4. 删除或改成一行指针的旧 `README-ISO.txt`，确保第一眼只看到 `START_HERE.txt`；
5. 不写入密码、私钥、Restic 凭据、KeePassXC 数据库；不重装 Ventoy、不 `dd`、
   不格式化。

U 盘以可写方式挂载后，可执行（把 `VNT` 换成 `findmnt`/`lsblk` 显示的
真实挂载点；先看 diff，确认只包含非敏感文件）：

```bash
cd /home/calendar/code/nixos-infra
VNT=/run/media/calendar/Ventoy          # 示例，必须按实际挂载点修改
test -d "$VNT/nixos-install" || { echo "STOP: wrong VNT"; exit 1; }
test -f "$VNT/nixos-install/cache/nix-cache-info" && echo "PASS cache exists"

diff -rq --exclude .git --exclude result --exclude 'result-*' \
  --exclude secrets --exclude hosts/main/hardware-configuration.nix \
  . "$VNT/nixos-install/repo" | sed -n '1,80p'

install -m 0644 START_HERE.txt "$VNT/nixos-install/START_HERE.txt"
install -m 0755 install-preflight.sh "$VNT/nixos-install/install-preflight.sh"
rsync -a --no-perms --no-owner --no-group --delete --delete-excluded \
  --exclude .git --exclude result --exclude 'result-*' --exclude secrets \
  --exclude hosts/main/hardware-configuration.nix \
  ./ "$VNT/nixos-install/repo/"
rm -f "$VNT/nixos-install/README-ISO.txt"
sync
```

`--delete-excluded` 会从 Ventoy 的 repo 副本中删除 `secrets/` 和 main 的
`hardware-configuration.nix`（如果旧副本里有）；但**保留** mini 的
`hosts/nixos/hardware-configuration.nix`，因为 `nixosConfigurations.nixos`
需要它才能求值。Ventoy 上不写密码、私钥、Restic 凭据、KeePassXC 数据库。
`cache/` 不参与 repo 的 `--delete`，保留原样；只有 `flake.lock` 变化时才在
Arch 上重新生成 cache。

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
