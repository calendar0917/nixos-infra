# nixos-infra

`calendar` 的 NixOS 单机配置。仓库只保留一套 `flake.nix` / `flake.lock`，默认基于
`nixos-unstable`（通过 TUNA 镜像拉取），Home Manager 作为 NixOS 模块集成。

## 结构

```text
flake.nix                         # 唯一入口；nixpkgs、home-manager、sops-nix
hosts/nixos/                      # 主机名、用户、桌面开关、hardware-configuration
modules/
  base.nix                        # boot、Nix、locale、keyd、基础工具
  network.nix                     # NetworkManager、systemd-resolved、Tailscale、Mihomo
  secrets.nix                     # sops-nix age key 路径
  backup.nix                      # 手动 Restic USB 备份 + 挂载点安全检查
  desktop/common.nix              # SDDM、PipeWire、Fcitx5、字体、portal
  desktop/niri.nix                # niri + DMS（DMS 绑定 niri.service）
  desktop/sway.nix                # 独立 Sway 备用桌面
  desktop/plasma.nix              # 可选 Plasma 6
home/calendar/                    # Home Manager：shell、Neovim、桌面配置软链
config/niri/                      # niri KDL 配置
config/sway/                      # Sway、Waybar、Mako、Fuzzel
config/nvim/                      # LazyVim 文本配置（插件不进入 Nix store）
secrets/                          # sops 加密文件；明文永不进 Git
docs/                             # 安装、网络、备份、快捷键核对表
```

## 三个独立桌面

`hosts/nixos/default.nix` 中的开关互相独立：

```nix
my.desktop.niri.enable = true;    # 默认主力桌面
my.desktop.sway.enable = true;    # 默认可靠备用桌面
my.desktop.plasma.enable = false; # 可选，默认关闭
my.network.mihomo.enable = false; # 未配置订阅前关闭
```

- niri 会话：niri + DankMaterialShell（DMS）+ Kitty + Fcitx5 + Wayland portal。
  `programs.dms-shell.systemd.target = "niri.service"`，DMS 不会在 Sway 或 Plasma
  会话中启动。
- Sway 会话：Waybar + Fuzzel + Mako + Kitty + Sway 自带的 screen lock 工具；
  不依赖 DMS。Waybar/Mako 只在 `config/sway/config` 中启动。
- Plasma 会话：由 SDDM 直接提供；启用后无需改动另外两个桌面。
- 三个会话都在 SDDM 的会话列表里独立选择，切换桌面不需要重新构建。

## 首次使用（在目标 NixOS 上）

1. **先核对硬件配置。** `hosts/nixos/hardware-configuration.nix` 是从旧仓库继承的
   文件；当前用于验证的 Arch 环境里的 UUID 和它不一致。真正安装/切换前，在目标机
   用 `nixos-generate-config` 重新生成并比对：
   ```bash
   sudo nixos-generate-config --root /mnt
   ```
   不要格式化或覆盖 Windows 分区，也不要复制/删除 Windows 的 EFI 文件。
2. 安装 age 私钥：
   ```bash
   sudo install -d -m 0700 /var/lib/sops-nix
   sudo install -m 0600 /path/to/keys.txt /var/lib/sops-nix/keys.txt
   ```
   该文件只应来自离线介质或密码管理器，不能进 Git、不能进 Nix store。
3. 准备 Restic 密码（与 SOPS 分离）：
   ```bash
   sudo install -d -m 0700 /var/lib/secrets
   sudo install -m 0600 /path/to/restic-password /var/lib/secrets/restic-password
   ```
   旧 dotfiles 中曾有一个被 Git 跟踪的明文 `restic-password`；如果它对应真实仓库，
   必须视为已泄露并轮换，不要复用。
4. 构建并安装：
   ```bash
   sudo nixos-rebuild build --flake .#nixos
   sudo nixos-install --flake .#nixos
   ```
   在已安装系统上切换用 `sudo nixos-rebuild switch --flake .#nixos`；不要在没有核对
   `hardware-configuration.nix` 的情况下执行。
5. 首次登录后设置 Fcitx5（Rime/拼音）、Wi-Fi 和浏览器；Mihomo 另行开启。

## 文档

- [`docs/INSTALL.md`](docs/INSTALL.md)：首次安装、EFI/Windows 边界、生成回滚。
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md)：构建/切换、TTY 恢复、网络排障、
  Restic USB 备份与恢复、重装流程。
- [`docs/NETWORK.md`](docs/NETWORK.md)：NetworkManager / Tailscale / Mihomo /
  systemd-resolved 的职责边界。
- [`docs/SECRETS.md`](docs/SECRETS.md)：sops-nix、age 和 Restic 密码分离。
- [`docs/KEYMAP.md`](docs/KEYMAP.md)：旧 niri 快捷键到新实现的逐项核对表。
- [`docs/VALIDATION.md`](docs/VALIDATION.md)：实际执行过的命令和未验证风险。

## 明确的安全边界

- 没有执行过 `nixos-rebuild switch`、分区、格式化、EFI 写入、真实网络修改或真实
  备份操作。
- 防火墙保持开启；没有 `networking.firewall.enable = false`。
- 没有使用 `systemd-boot.extraInstallCommands` 复制 Windows EFI；systemd-boot 只
  管理 NixOS 自己的 generation，Windows 由固件启动菜单或原生
  `boot.loader.systemd-boot.windows` 选项处理。
- Mihomo 配置文件来自 SOPS secret，构建时不读明文；未配置时保持关闭。
