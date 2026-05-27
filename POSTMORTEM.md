# Arch Linux → NixOS 迁移全记录

## 最终成果

```
系统：    NixOS unstable (26.05)
桌面：    niri + dms-shell（主力）/ KDE Plasma 6（保险）
显示管理器：SDDM
输入法：  fcitx5 + rime
Shell：   fish + zoxide
终端：    kitty
编辑器：  neovim（默认）
键位：    keyd（Caps → Esc单击 / Ctrl长按）
配置管理：flake + git，/home 跨发行版共享
```

---

## 当前磁盘布局

```
nvme0n1     953.9G
├─nvme0n1p1   260M  EFI (Windows)
├─nvme0n1p2    16M  MSR
├─nvme0n1p3 199.2G  Windows C:    ntfs  → /mnt/c
├─nvme0n1p4   797M  Recovery
├─nvme0n1p5 364.6G  Windows D:    ntfs  → /mnt/d
├─nvme0n1p6   512M  /boot         vfat  ← Arch + NixOS 共用 EFI
├─nvme0n1p7    20G  swap          swap  ← 共用
├─nvme0n1p8 327.9G  @ + @home     btrfs ← /home（共享）
└─nvme0n1p9  40.6G  NixOS /       ext4
```

---

## 一、安装阶段

### 1.1 备份（在 Arch 里）

```bash
pacman -Qe > ~/dotfiles/pkglist.txt
cp /etc/fstab ~/dotfiles/
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID > ~/dotfiles/disk-layout.txt
cd ~/dotfiles && git add -A && git commit -m "pre-nixos backup" && git push
rsync -avh --progress /home/calendar/ /mnt/backup-home/
```

### 1.2 Windows 划分空闲分区

磁盘管理 → 右键 D 盘 → 压缩卷 → 输入 81920（80G）

### 1.3 提前下载（存 U 盘）

| 文件 | 用途 |
|------|------|
| NixOS graphical ISO | 安装镜像 |
| mihomo 内核 | 代理客户端（安装时必备） |
| Country.mmdb | GEOIP 分流 |

用 Ventoy 做启动 U 盘。

### 1.4 分区 + 挂载（在 ISO 终端）

```bash
sudo cfdisk /dev/nvme0n1   # 空白空间 → New → 80G → Write
sudo mkfs.ext4 /dev/nvme0n1p9

sudo mount /dev/nvme0n1p9 /mnt
sudo mkdir -p /mnt/boot && sudo mount /dev/nvme0n1p6 /mnt/boot
sudo mkdir -p /mnt/home && sudo mount /dev/nvme0n1p8 /mnt/home
sudo swapon /dev/nvme0n1p7
```

### 1.5 代理（关键）

图形安装器（calamares）不读取 systemd 代理配置，必须用 `sudo -E` 传递环境变量：

```bash
./mihomo -d .                                      # 终端1：启代理
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
sudo -E calamares                                  # 终端2：走代理启动安装器
```

安装器里：用户 `calendar`（UID 1000，与 Arch 一致），桌面先不选（后续声明式加），引导用 systemd-boot。

---

## 二、安装后修复

### 2.1 `/home` 挂载修复（btrfs subvol）

**问题：** 安装器不知道 btrfs 子卷，把整个 nvme0n1p8 顶层挂到了 `/home`，导致文件出现在 `/home/@home/calendar/`。

**修复：** 在 `hardware-configuration.nix` 里加 `subvol=@home`：

```nix
fileSystems."/home" = {
  device = "/dev/disk/by-uuid/6d5acaf3-799a-4b27-a4e7-cbb450c3095c";
  fsType = "btrfs";
  options = [ "subvol=@home" "compress=zstd:3" "ssd" "discard=async" "space_cache=v2" ];
};
```

### 2.2 国内镜像

**不配镜像 → GitHub 拉不下来，构建必挂。** 清华大学 TUNA 提供 nixpkgs 源码镜像和二进制缓存：

```nix
# flake.nix — nixpkgs 源码
nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";

# configuration.nix — 二进制缓存
nix.settings.substituters = [
  "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
  "https://cache.nixos.org/"
];
```

---

## 三、配置历程（record of failures and fixes）

### 3.1 尝试 1：stable 25.05 + unstable overlay → opencode 工作，niri GPU 崩溃

**策略：** 主系统用 stable，只给 opencode 从 unstable overlay 拿。

**结果：** niri 26.04（来自 unstable）链接了 unstable 的 mesa/libdrm，但系统跑的是 stable 的内核和 GPU 驱动 → DRM 接口不匹配：

```
error adding device: Failed to open device: Invalid request descriptor (os error 53)
```

**教训：** Wayland 合成器这种底层程序和系统 GPU 栈不能跨 nixpkgs 版本混用。要么全 stable，要么全 unstable。

### 3.2 尝试 2：全量切 unstable → PAM 崩溃，无法登录

**策略：** `nixpkgs.url = ".../nixos-unstable/..."`，整个系统一起升。

**结果：** systemd 257→260、linux-pam 1.6→1.7、pam_lastlog→pam_lastlog2，这些底层组件集体升级后 PAM 会话初始化失败：

```
pam open session module is unknown
policy plugin failed session initialization
```

GDM 能显示但任何用户都无法登录（包括 TTY 的 login PAM 也有 gkr-pam 警告）。

**教训：** stable→unstable 的全量切换要准备应对底层系统组件（systemd、PAM）的 breaking changes。NixOS 的 rollback 机制（boot 菜单选旧世代）是救命稻草。

### 3.3 尝试 3：hybrid（stable base + unstable niri）→ niri 正常但配置混乱

**策略：** 只把 niri 从 unstable overlay 拿，其余保持 stable。

**结果：** 这次 niri 用了 stable 版（不是 26.04），GPU 兼容，可以启动。但 dms-shell 的 NixOS 模块在 stable 里不存在，需要从 unstable 源码手动引入，又引发 `lib.teams.danklinux` 不存在等问题。

**教训：** 跨版本引入模块时，`flake check` 会暴露缺失的依赖和 API。不要跳过 check。

### 3.4 尝试 4：全量 unstable + GNOME → GNOME 50 上游 bug

**策略：** 再去 unstable，桌面用 GNOME。

**结果：** NixOS unstable 的 GNOME 50 有一个已知上游 bug（[GNOME GitLab #190](https://gitlab.gnome.org/GNOME/gnome-session/-/work_items/190)）：`gnome-session-init-worker` 在已有用户 profile 下 SIGABRT 崩溃。新建用户可登录，已存在用户不行。清 dconf、删 `~/.cache` 都无效。这是 GNOME 50 的 race condition / profile 兼容问题，非 NixOS 特有。

**教训：** 切 rolling release 前搜一下最新 GNOME/Plasma 的上游 issue。rolling release = 最新软件 = 最新 bug。

### 3.5 成功：全量 unstable + KDE Plasma 保险 + niri 主力

**最终架构：**

```
nixos-unstable（整系统一个 nixpkgs）
├── KDE Plasma 6（SDDM 登录管理器）→ 保险桌面
├── niri → 主力 Wayland 合成器
├── dms-shell → 桌面 shell（通知、启动器）
├── keyd → 键盘重映射
├── fcitx5 + rime → 中文输入
├── fish + zoxide + kitty + neovim → 终端环境
├── kanshi → systemd 用户服务自启动
├── tailscale → 网络
├── Docker + VirtualBox → 容器/虚拟化
└── noto + maple-mono 字体
```

**为什么 KDE 而不是 GNOME：** 避开 GNOME 50 的登录崩溃 bug。KDE Plasma 6 在 unstable 上表现稳定。

**为什么 niri 这次能工作：** 整个系统包括内核、mesa、libdrm、niri 全来自同一个 unstable nixpkgs，版本一致，DRM 接口兼容。

---

## 四、可复用的配置模式

### 4.1 模块化目录结构

```
code/nixos/
├── flake.nix              # 入口：声明输入源 + 输出系统
├── flake.lock             # 锁定版本（提交到 git）
├── clash.yaml             # mihomo 代理配置
├── hosts/
│   └── nixos/
│       ├── default.nix    # imports [ ./configuration.nix ]
│       ├── configuration.nix  # 主配置
│       └── hardware-configuration.nix  # 分区/硬件（自动生成）
└── modules/
    ├── features/niri/     # niri 模块（default.nix + config.kdl）
    └── fonts/             # 字体模块
```

- 每个目录的 `default.nix` 通过 `imports` 自动加载同目录模块
- 新增特性：在 `modules/features/` 下新建目录，写 `default.nix`，在 `configuration.nix` 的 `imports` 里加一行

### 4.2 flake.nix 模板（国内 TUNA 镜像版）

```nix
{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";
  };
  outputs = { nixpkgs, ... } @ inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/nixos ];
    };
  };
}
```

### 4.3 没有 NixOS 模块的软件怎么配

绝大多数软件 NixOS 没有现成 module，用以下组合即可覆盖全部需求：

```nix
# ① 只需要安装 → systemPackages
environment.systemPackages = with pkgs; [ xxx ];

# ② 需要 systemd 服务 → systemd.services
systemd.user.services.kanshi = {
  wantedBy = [ "graphical-session.target" ];
  serviceConfig.ExecStart = "${pkgs.kanshi}/bin/kanshi";
};

# ③ 需要写配置文件到 /etc → environment.etc
environment.etc."niri/config.kdl".source = ./config.kdl;

# ④ 需要创建运行时目录 → tmpfiles
systemd.tmpfiles.rules = [ "d /var/lib/myapp 0750 myuser mygroup" ];

# ⑤ 不在 nixpkgs 里 → 自己写 derivation
my-pkg = pkgs.stdenvNoCC.mkDerivation {
  pname = "..."; version = "...";
  src = pkgs.fetchurl { url = "..."; hash = "..."; };
  installPhase = "mkdir -p $out/bin && cp ...";
};
```

### 4.4 如何搜索可用选项

| 方法 | 命令 / 地址 |
|------|------------|
| Web | https://search.nixos.org/options |
| 命令行 | `nixos-option services.xxx` |
| 读源码 | https://github.com/NixOS/nixpkgs/tree/nixos-unstable/nixos/modules |
| 交互探索 | `nix repl --file '<nixpkgs/nixos>'` |

### 4.5 调试工作流

```bash
nix flake check                        # 1. 验证语法，不构建
sudo nixos-rebuild test --flake ...    # 2. 构建+测试（重启还原）
sudo nixos-rebuild switch --flake ...  # 3. 确认无误，永久应用

# 出问题
journalctl -b -p3                      # 看系统错误
sudo nixos-rebuild list-generations    # 列世代
sudo nixos-rebuild switch --rollback   # 回滚
# 或者重启在 boot 菜单选旧世代
```

---

## 五、常见坑总结

| 场景 | 坑 | 解 |
|------|-----|-----|
| 安装 | `/home` btrfs subvol 丢失 | `hardware-configuration.nix` 加 `subvol=@home` |
| 国内 | GitHub 拉不下来 | flake input 用 TUNA 镜像 URL |
| 国内 | 下载慢 | `substituters` 加 TUNA 缓存 |
| 跨版本 | 只给 niri 用 unstable | GPU 驱动版本不匹配 → 全量切 |
| 全量切 | stable→unstable | systemd/PAM 底层可能 breaking |
| GNOME 50 | 官方 bug | 等上游修，或用 KDE |
| 自定义包 | nixpkgs 没有 | `fetchzip` + `mkDerivation`，注意 `stripRoot` |
| 磁盘 | /nix/store 膨胀 | `nix-collect-garbage --delete-older-than 7d` |
| 回滚 | 系统崩了 | boot 菜单选旧世代 / `nixos-rebuild --rollback` |
| 代理 | calamares 不走代理 | `sudo -E` 传环境变量 |
| 字体 | fetchzip 报单文件错误 | 加 `stripRoot = false` |
| UNFREE | 包不存在 | `nixpkgs.config.allowUnfree = true` |

---

## 六、最终文件结构

```
~/code/nixos/
├── flake.nix
├── flake.lock
├── clash.yaml
├── NIX-GUIDE.md           # NixOS 学习指南
├── POSTMORTEM.md          # 本文档
├── hosts/nixos/
│   ├── default.nix
│   ├── configuration.nix
│   └── hardware-configuration.nix
└── modules/
    ├── features/niri/
    │   ├── default.nix    # niri 模块（swaylock/cliphist/polkit/waypaper等）
    │   └── config.kdl     # niri 原生键位（kitty/kanshi/工作区等）
    └── fonts/
        └── default.nix    # noto + maple-mono NF CN
```

## 七、日常维护

```bash
# 更新 nixpkgs 到最新
nix flake update
sudo nixos-rebuild switch --flake ~/code/nixos#nixos

# 清理旧世代（保留最近 7 天）
sudo nix-collect-garbage --delete-older-than 7d

# git 管理配置
cd ~/code/nixos
git add -A && git commit -m "描述改了什么"
```
