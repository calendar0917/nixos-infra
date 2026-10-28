# 稳定性收尾、数据恢复与 Arch 迁移准备

本文是 2026-10-22 对这台小主机的只读检查和配置审计结果。它记录“现在是什么状态”、
“哪些东西必须自己备份”以及迁移到主力 Arch 主机前还要确认什么；不表示本轮已经
执行 switch、重启或任何磁盘操作。

> 历史快照：本文描述的是 2026-10-22 的小主机状态，其中“niri 仍使用 DMS”等
> 桌面描述不是当前 main 的行为。当前桌面组件和验收步骤见
> [`docs/DESKTOP.md`](../DESKTOP.md) 与根目录 README。

## 1. 当前部署状态

| 项目 | 当前值 |
| --- | --- |
| 检查时 Git HEAD | `28d54e0`（与 `origin/main` 一致，工作区本轮开始时干净） |
| 运行系统 | `sg0mg492...-26.11.20261020.dirty`（之前 `nixos-rebuild test` 的运行时结果） |
| 本次启动的系统 | `b8j6m27...-26.11.19800101.dirty`（gen 3） |
| profile / boot 默认 | `sc2m6nw7...-26.11.19800101.dirty`（gen 4） |
| 最新只构建未激活 | `dandv7nl...-26.11.20261020.dirty` |
| systemd | `running`；system/user 均无 failed unit |
| 登录管理器 | `display-manager.service` 正常，SDDM 使用 X11 greeter |
| SSH / 网络 | `sshd`、`NetworkManager` active；公钥认证实测可用 |
| 图形会话 | 当前停在 SDDM greeter；niri/dms/waybar/fcitx5 未运行 |

**关键问题**：运行系统、本次启动系统、profile/boot 默认三者不是同一个 generation。
`nixos-rebuild switch` 会生成并激活新 generation，但要让“运行系统 = 本次启动系统”
一致还必须重启。本轮没有执行这两步；需要用户明确授权。

`/etc/fstab` 与 `/run/current-system`、`/run/booted-system`、本次构建的
`/etc/fstab` 逐字节一致；根、`/home`、`/nix`、`/boot` 和 swap 的 UUID 与
`hosts/nixos/hardware-configuration.nix` 一致：

- btrfs：`6464e054-adce-4ade-a985-7bdfb353c1c5`（`/`、`subvol=home`、`subvol=nix`）
- ESP：`1421-3BC8`
- swap：`f0378700-910f-4cbb-9576-c530ac0c5d5c`

本轮没有读取或修改 `/boot` 文件，也没有运行 `bootctl`（权限不足）；启动项和
回滚目标以 `/nix/var/nix/profiles/system-*` 和实际 systemd-boot 菜单为准。

## 2. 已生效与未生效的配置

当前 Home Manager 文件仍指向旧的 `5ywjx...`，不是最新构建的 `ipawaj...`：

| 功能 | 当前状态 |
| --- | --- |
| Waybar 模块化 | 旧 test generation 中已有；niri 仍使用 DMS，Sway 未启动 |
| tmux | 新配置 `home/calendar/tmux.nix` 已构建，但 `~/.config/tmux/tmux.conf` 尚未生成 |
| KeePassXC 包 | 当前运行系统 PATH 中没有 `keepassxc`；新 HM generation 的 `home-path/bin/keepassxc` 已构建 |
| Firefox native messaging | 当前 Firefox wrapper 没有 `org.keepassxc.keepassxc_browser.json`；新构建的 wrapper 有，manifest 指向 `keepassxc-proxy` |
| Firefox 默认 MIME | 新 HM 文件未激活；当前仍是旧状态 |
| 新 Neovim/tmux 配置 | 新构建中存在，但运行中的 `~/.config/nvim` 仍指向旧 store |

所以，**最近提交的 KeePassXC、Firefox native messaging 和新 tmux 配置还没有实际
生效**。这需要一次经过授权的 switch（以及为消除 generation 不一致而做的重启）。

## 3. 数据与密钥清单

### 3.1 可以由 Git + Nix 重新生成

- 系统模块、桌面配置、Waybar 样式、Neovim 配置、tmux 配置、Shell 配置；
- 已安装的软件包、字体、门户、NetworkManager/SDDM/SSH 的声明式部分；
- `authorized_keys` 中的公钥（公钥不是秘密）；
- `secrets/secrets.yaml` 的密文本身（但没有私钥不能解密）；
- 项目 devShell 和 lock 文件（`flake.lock`、`uv.lock`、`pnpm-lock.yaml`）；
- LazyVim 插件和 Mason 二进制（可以重新下载，不是必须备份）。

### 3.2 必须独立备份

| 内容 | 当前位置/说明 |
| --- | --- |
| 个人文件、下载、项目源码和未提交改动 | `/home/calendar`（当前约 659 MiB，含缓存） |
| KeePassXC 数据库 | 目前还没有 `.kdbx`；创建后必须放在 `/home/calendar` 下或显式加入备份路径 |
| Firefox Profile | `~/.mozilla/firefox`（当前尚未创建；首次使用 Firefox 后生成） |
| Fcitx5 配置和用户词库 | `~/.config/fcitx5`、`~/.local/share/fcitx5` |
| GNOME Keyring | `~/.local/share/keyrings`（当前约 8 KiB） |
| SSH/GPG 私钥（如果以后在主机上创建） | `~/.ssh`、`~/.gnupg`；当前主机只有 `known_hosts` 和空 agent 目录，没有长期私钥 |
| SOPS age 私钥 | `/var/lib/sops-nix/keys.txt`（root-only；当前目录存在，但本轮无权确认文件状态） |
| SOPS 密文 | `secrets/secrets.yaml`；已由 Git 跟踪，但没有 age 私钥无法恢复 |
| Restic 密码 | `/var/lib/secrets/restic-password`；**不在 Restic 仓库内**，必须离线保存（当前文件不存在） |
| Clash Verge profiles、订阅和本地状态 | `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/`（当前约 133 MiB，其中约 104 MiB 是可重新下载的 update cache） |
| DMS 设置、剪贴板历史、PAM 状态 | `~/.config/DankMaterialShell`、`~/.local/state/DankMaterialShell`、`~/.cache/DankMaterialShell` |
| Shell 历史、Yazi/Nautilus 历史 | `/home/calendar` 内的应用状态 |
| Arch 上的研究数据、Windows VM、个人文件 | 不在这台小主机的 `/home/calendar` 中，必须由 Arch 侧单独备份 |

KeePassXC 主密码不在任何文件或备份中；只备份数据库不足以恢复，必须同时保存主密码
的离线记忆/纸质恢复材料。不要把数据库、主密码或 age 私钥放进 Git。

### 3.3 按需备份 / 不必备份

- **按需**：`~/下载`、较大的媒体文件、可以重新下载但重新配置成本高的应用；
- **不必**：`~/.cache`、`.venv`、`node_modules`、`__pycache__`、Neovim lazy/mason
  插件、npm 缓存、Clash 的 update cache/geo 数据库、`.direnv`、Nix store；
- **绝不**：把 `/nix/store` 当普通目录复制，或把 Restic 仓库放在它自己的备份源里。

当前备份配置已按这个范围改为 `/home/calendar` + `/var/lib/sops-nix`，并排除上述
可重建内容；只有显式放在家目录之外的数据库需要额外加入 `my.backup.paths`。

## 4. Restic 备份方案

### 4.1 已做的低风险调整

- 默认备份源从已不存在的 `/home/calendar/life`、`/home/calendar/code/nixos-infra`
  和 `~/.config/sops/age` 改为 `/home/calendar` + `/var/lib/sops-nix`；前三个路径
  在当前主机上不存在，旧默认值会让 `verify-usb-backup-target` 直接失败。
- 排除项只针对可重建内容；保留 `.git`、项目源码、keyrings、SSH/GPG、Firefox、
  Fcitx5、KeePassXC 数据库和 Clash profiles。
- 新仓库目录名 `restic-nixos`，不再使用通用 `restic/`，避免与旧 Arch 备份仓库
  混淆；旧 USB 上的数据不会被读取、修改或初始化。
- 模块仍为 `my.backup.enable = false`，没有 timer，没有自动备份。

### 4.2 存储介质和容量

- 当前 NixOS 家目录总量约 659 MiB；按现有排除项估算，首次归档约 116 MiB
  （Restic 实际还会压缩/去重），但不要把缓存和依赖算进恢复目标。**不要用现有
  128 GB 旧 USB 做试验**；它仍然保存着 Arch 备份和个人数据。
- 新仓库需要一块**独立、内容可丢弃**的介质。仅这台小主机：64 GB 足够容纳多次
  快照并留出增长空间；如果以后同一仓库还要放 Arch 研究数据和 Windows VM，按
  实际数据量选择更大容量（通常 1 TB 级别），并在 Arch 侧单独制定备份目标。
- 旧 Restic 密码不可信，**不要复用**。新仓库使用新的随机密码，离线保存两份；
  密码文件放在 `/var/lib/secrets/restic-password`（0600，root），不进入 Restic。
- 当前 `/var/lib/secrets` 不存在，`/var/lib/sops-nix` 的密钥状态也无法由普通用户
  确认；在完成密钥恢复检查前不要启用备份服务。

### 4.3 恢复演练（设计，不执行写入）

备份前关闭 KeePassXC 和 Firefox，避免正在写入的数据库/Profile 产生不一致快照；
Clash 保持运行通常可以，但不要同时修改订阅。Windows VM 必须在 VM 层做快照或关机，
不能只依赖宿主文件级备份。

新仓库路径为 `/run/media/calendar/NIXOS-BACKUP/restic-nixos`：

```bash
# 只读挂载/查看，不要初始化旧盘
sudo mkdir -p /mnt/usb /mnt/restore
sudo mount /dev/disk/by-uuid/<NEW_USB_UUID> /mnt/usb

RESTIC_REPOSITORY=/mnt/usb/restic-nixos
RESTIC_PASSWORD_FILE=/media/offline/restic-password

sudo restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots
sudo restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" \
  check --read-data-subset=5%

# 先恢复一个小目录和关键密钥到临时目标，而不是覆盖 /
sudo restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" \
  restore latest --target /mnt/restore \
  --include /home/calendar/.config/fcitx5 \
  --include /home/calendar/.local/share/keyrings \
  --include /var/lib/sops-nix

find /mnt/restore/home/calendar -maxdepth 3 -type f | head
sudo ls -l /mnt/restore/var/lib/sops-nix

# 抽一个文件做校验和对比（示例）
sha256sum /home/calendar/.config/fcitx5/profile
sha256sum /mnt/restore/home/calendar/.config/fcitx5/profile

# 最后才做完整恢复检查
sudo restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" \
  check --read-data
```

恢复演练还必须验证：

1. 能在隔离目录打开 KeePassXC 数据库（只用**虚构测试库/测试密码**，不要动真实库）；
2. 能读出 `keys.txt` 并用 `sops -d` 对一份临时副本解密（不要把明文打印到终端）；
3. 恢复后 `~/.ssh`、`~/.gnupg`、keyrings 的权限没有被放宽；
4. 恢复出的 Firefox profile 和 Fcitx5 词库能启动/加载；
5. 记录恢复耗时和失败项；只看到 `snapshots` 列表不算完成。

## 5. KeePassXC、Firefox 与 DMS 剪贴板

### 5.1 KeePassXC / Firefox

新构建已经包含：

- HM `programs.keepassxc` 安装的 KeePassXC 2.7.12；
- Firefox wrapper 中的
  `lib/mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json`；
- manifest 的 `path` 指向 `keepassxc-proxy`，`allowed_extensions` 只有
  `keepassxc-browser@keepassxc.org`。

当前未激活，因此现在无法在图形会话中验收。`~/.config/keepassxc/keepassxc.ini`
是普通可写文件（644），只有 `[General] ConfigVersion`；没有 autostart，也没有
数据库或自动解锁项。新 HM 不会把 `keepassxc.ini` 链成只读 store 文件。

激活后的人工验收顺序：

1. 启动 KeePassXC，创建**自己的**测试数据库（不要复制 Arch 的 `Passwords.kdbx`）；
2. 在 Firefox 安装 KeePassXC-Browser 扩展并连接；
3. 关闭“启动时更新 native messaging manifest”类的自动写入选项；
4. 验证网页登录填充、KeePassXC 锁定后不能填充、10 秒后剪贴板清空；
5. 只在测试密码上验证，不读取真实密码。

### 5.2 DMS 剪贴板历史

已确认 DMS 会把剪贴板历史持久化到
`~/.cache/DankMaterialShell/clipboard/db`（当前 512 KiB，父目录 700，文件 644）。
本轮没有读取该文件中的条目。DMS 1.6.3 自带配置命令，不需要新增剪贴板服务：

```bash
# 最严格的现有设置：完全停用 DMS 剪贴板跟踪
dms clipboard config set --disable

# 如果确实需要历史，至少缩短保留范围（仍会保存密码，不推荐）
dms clipboard config set --max-history 20 --auto-clear-days 1 --clear-at-startup

# 需要时清理旧历史（会删除历史条目，先确认没有要保留的内容）
dms clipboard clear
```

推荐优先执行 `--disable`；如果必须保留历史，再使用较短保留期，并明确接受复制密码
会进入 DMS 历史的风险。KeePassXC 的“复制后 10 秒清空剪贴板”只能缩短系统剪贴板
暴露时间，**不能阻止 DMS 在复制瞬间保存历史**。以上命令需要 DMS 运行中执行；
本轮没有启动 DMS，也没有清除现有历史。

## 6. SOPS / age

`.sops.yaml` 当前只有一个 recipient：

```text
age1ce6lurdq9acgvd0rzzfmemfgpkty2rtk9muh90lk8cd5x8jnw3cqj9yxyg  # laptop
```

`secrets/secrets.yaml` 仍用这个旧 recipient 加密。当前主机没有可用的用户级
`~/.config/sops/age`；`/var/lib/sops-nix` 存在但普通用户无权确认其中的
`keys.txt`。因此不能假定 SOPS 已经能在本机解密。

安全迁移计划（本轮不执行密钥生成/轮换）：

1. 先从旧 Arch/离线介质确认旧 age 私钥仍可用，并在一份临时副本上验证解密；
   不要删除旧私钥，也不要把私钥贴到终端或 Git。
2. 在新主机生成独立的 age key，私钥只放在 `/var/lib/sops-nix/keys.txt`（0600）
   和一份离线介质；记录对应的公钥 recipient。
3. 把新公钥加入 `.sops.yaml`，保留旧 recipient，运行 `sops updatekeys`；
   验证新、旧私钥都能解密后，才考虑移除旧 recipient。
4. 如果旧私钥曾经泄露或无法找回，不能只换 recipient：必须用新密钥重新生成所有
   secret，并把新密文提交；旧密文不要当作“已轮换”。
5. age 私钥和 Restic 密码分别备份；Restic 恢复不应依赖 SOPS。

## 7. SSH 安全收尾

当前实际生效的 `/etc/ssh/sshd_config`：

```text
AllowUsers calendar
KbdInteractiveAuthentication no
PasswordAuthentication yes
PermitRootLogin no
Port 22
```

`ssh -o PreferredAuthentications=publickey -o BatchMode=yes nixos true` 从 Arch
实测成功；强制只用密码且不提供密码时失败，说明公钥路径正常。主机当前没有自己的
长期 SSH 私钥，GitHub 认证依赖 Arch 的 `ssh -A` 转发；这不影响 NixOS 登录。

建议的最小补丁（**本轮不应用**）：

```nix
services.openssh.settings.PasswordAuthentication = false;
```

应用前必须：

1. 保留当前已登录的 SSH 会话，不要关闭；
2. 从第二个终端用 `-o PreferredAuthentications=publickey -o BatchMode=yes` 再登录
   一次；
3. 确认本地 TTY/SDDM 可以作为恢复入口；
4. `nixos-rebuild build` 后检查构建出的 `/etc/ssh/sshd_config`，再申请授权部署。

如果部署后公钥失效：不要关闭现有会话；在 TTY/SDDM 或旧 generation 中把
`PasswordAuthentication` 改回 `true` 并重建，或从 systemd-boot 选择上一代。
关闭密码登录不影响本地控制台密码和 SDDM 登录。

## 8. 迁移到主力 Arch 主机

### 8.1 可以共享

- `flake.nix` 的 nixpkgs/HM/sops-nix 输入和大部分 `modules/`；
- `home/calendar/` 的 Fish、Git、direnv、tmux、Neovim、桌面配置；
- 桌面/输入法/字体/portal/SSH 的通用模块；
- devShell 模板、lock 文件和项目级工具链。

### 8.2 必须按主机拆分

| 内容 | 原因 |
| --- | --- |
| `hosts/<host>/hardware-configuration.nix` | 磁盘 UUID、Btrfs 子卷、swap、ESP、CPU/GPU |
| bootloader / ESP / Windows 双启动 | `modules/base.nix` 目前固定 systemd-boot 和 `canTouchEfiVariables`，第二台机器可能用 GRUB/不同 ESP |
| GPU、显示器和输出 | 不要把本机的 HDMI/eDP 或缩放写死到共享配置 |
| hostName、Tailscale/Clash 运行参数 | 主机名、TUN 名称、网络接口和订阅状态不同 |
| 备份挂载点和 USB UUID | 每台机器应有独立仓库/介质 |
| `system.stateVersion` | 按首次安装版本分别设置 |
| 用户 UID/GID、家目录 | Arch 主力的用户可能与 1000 不同；不要共享同一个 `/home` 给两套系统 |

`modules/base.nix` 里的 bootloader 设置应移到 host profile；共享模块只保留 Nix、
locale、keyd、Firefox、nix-ld 等通用部分。`modules/backup.nix` 的
`repositoryName`/`mountPoint` 应在新 host 覆盖，不要复用旧仓库目录。

### 8.3 无法由 Flake 恢复的用户状态

SSH/GPG/age 私钥、KeePassXC 数据库和主密码、Firefox profile、Fcitx5 词库、
keyring、Clash 订阅/节点/localstorage、DMS 剪贴板、Shell/Yazi/Nautilus 历史、
Git/gh 凭据、Restic 密码、Arch 研究数据、Windows VM 镜像和 VM 配置。它们必须
通过离线备份或应用自身导出恢复。

### 8.4 Arch 数据、Windows VM 和双系统

当前仓库的 Restic 配置只覆盖 NixOS 的 `/home/calendar`，**不能覆盖 Arch 上的
研究数据、Windows VM 或个人文件**。迁移前需要：

- 在 Arch 侧单独建立备份任务，或把 Arch 数据挂载到独立备份主机；不要把 Arch
  数据直接混入小主机的 `/home`；
- 确认 Windows VM 的磁盘镜像、快照链、XML/libvirt 配置和 Windows 激活信息；
- 对运行中的 VM 先做快照/关机，再备份磁盘镜像，避免不一致；
- 新介质容量按 Arch 研究数据 + VM 实际大小预留，旧 128 GB USB 不参与。

如果保留 Arch Btrfs 与 NixOS 双系统，先只读确认：

- 物理磁盘型号/序列号、分区表、每个 ESP 的所有者、Windows 分区和 BitLocker 状态；
- Arch 的 Btrfs 子卷布局、挂载选项、快照和可用空间；
- 给 NixOS 的独立分区/子卷（不要直接复用 Arch 的 `/home`）、`/nix` 空间、swap；
- 启动顺序和 systemd-boot/GRUB 的共存方式；不要先写主力机的 hardware 配置。

## 9. 本轮结论与待授权动作

本轮没有执行 switch/test/boot、重启、GC、分区、格式化、Restic 初始化或备份写入；
没有读取真实密码、私钥或剪贴板条目。

需要用户明确授权/决定：

1. 是否执行 `nixos-rebuild switch` 并重启，以消除运行/启动/profile 三个
   generation 的不一致；
2. 是否关闭 SSH 密码登录（先按第 7 节验证）；
3. 是否在 DMS 中执行 `clipboard config set --disable` 和清理旧历史；
4. 是否生成新的 age key、创建新的 Restic 介质/密码/仓库；
5. Arch 迁移前是否先完成 Arch 侧研究数据和 Windows VM 的独立备份。

在这些动作完成前，当前系统的可靠性边界是：**声明式配置可构建，核心系统服务正常，
公钥 SSH 可用；但最新 KeePassXC/Firefox/tmux 配置尚未激活，SOPS 密钥和 Restic
密码的可用性未确认，且没有进行过真实恢复演练。**
