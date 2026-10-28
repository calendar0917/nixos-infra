# nixos-infra

`calendar` 的 NixOS 配置，使用单一 `flake.nix` / `flake.lock`、NixOS 原生模块和
NixOS 集成的 Home Manager。仓库同时管理两台机器；日常桌面以 niri 为主，Sway 是
不依赖 DMS 或 Waybar 生命周期的备用会话，Plasma 6 可选。

## 两台主机

| 主机 | 角色 | niri shell | 其他桌面 | 特殊硬件/功能 |
| --- | --- | --- | --- | --- |
| `main` | LENOVO 21LG 笔记本，Arch/NixOS 双系统 | Waybar（Catppuccin Mocha） | Sway 备用，Plasma 关闭 | 电池、蓝牙、Hyprlock、nwg-displays 多屏 |
| `nixos` | KOLOE 小主机，SSH/轻量容器节点 | DMS | Sway 备用，Plasma 关闭 | 无电池、无蓝牙锁屏作用域 |

两个配置都由 `flake.nix` 直接暴露：

```bash
nix eval --raw .#nixosConfigurations.main.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.nixos.config.system.build.toplevel.drvPath
```

`system.stateVersion` 与 `home.stateVersion` 都保持首次安装时的值，不随 nixpkgs
升级而改变。

## 功能作用域

| 功能 | main | nixos |
| --- | --- | --- |
| niri + Waybar | 是，niri 绑定 user services | 否，保留 DMS |
| DMS / `config-dms.kdl` | 关闭但保留 | 是 |
| Sway / Mako / Swaylock | 是，备用 | 是，备用 |
| CPU / 内存 Waybar 模块 | 常驻 | 不启动 Waybar |
| 蓝牙 (BlueZ + Blueman) | 是 | 否 |
| Hyprlock 手动锁屏 | 是，`Alt+L` / power menu | 否，DMS 自己的锁屏 |
| kitty 半透明 Catppuccin | 是 | 否，保持原样 |
| nwg-displays niri null-output 补丁 | 是 | 否，DMS 不需要 |

共享文件中的改动必须在两台机器上求值和构建；小主机的 shell、DMS 配置和快捷键
不会被切换。

## 目录

```text
flake.nix / flake.lock              # 唯一入口和锁定版本
hosts/main/                         # 笔记本 host、Waybar 覆盖、nwg 补丁、蓝牙/PAM
hosts/nixos/                        # 小主机 host
modules/                            # NixOS 基础、网络、备份、桌面模块
home/calendar/                      # Home Manager：shell、终端、编辑器、桌面
  desktop/shell.nix                 # 面板/通知/壁纸/网络 applet 生命周期
  desktop/clipboard.nix             # cliphist 服务和 helper
  desktop/lock.nix                  # Hyprlock 配置、手动锁屏 unit、niri-lock
  desktop/waybar/                   # Sway 与 niri 两套 profile
config/niri/                        # 两套只读 niri KDL
config/waybar/                      # Sway 样式 + niri Catppuccin 样式
patches/                            # nwg-displays 本地补丁
tests/                              # 无 GUI 的 Python 回归检查
docs/DESKTOP.md                     # 桌面组件、显示器、蓝牙、锁屏和实机验收
docs/install/                       # 双系统安装和历史迁移记录
```

`START.sh`、`START_HERE.txt` 和 `install-preflight.sh` 仍是 Arch 现场安装入口；
`docs/install/ARCH_DUAL_BOOT.md` 保留完整背景与恢复步骤。

## nixpkgs 固定与更新

`flake.nix` 固定 NixOS/nixpkgs 的不可变 commit：

```text
31ecbaca1bdefa45dffc409f0250bd8039ea0010   # nixos-unstable, 2026-10-27
```

Home Manager 和 sops-nix 保持各自的锁定 revision，只通过 `follows = "nixpkgs"` 使用
同一组包。升级 nixpkgs 时不要顺带全量更新 inputs：

```bash
# 1. 修改 flake.nix 中 nixpkgs.url 的 commit
# 2. 生成真实锁文件（不要手写 narHash）
nix flake update nixpkgs
# 3. 重新验证
nix flake check --no-build
nix build --no-link .#nixosConfigurations.main.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel
```

如果目标 nixpkgs 与 Home Manager 有明确的兼容错误，只做最小修复；只有错误确实
要求时才更新对应依赖并记录新 revision。`hosts/main/waybar.nix` 仍固定上游 Waybar
`c15ec02ede4343592a59eb5c2ff4443c9c045f7c`，用于 `workspace-taskbar`；不要为了
“清理覆盖”删掉它。

`modules/base.nix` 还通过 `nix.envVars` 把 Nix daemon 和 Nix 客户端的 HTTP(S) 下载
指向本地 Clash `http://127.0.0.1:7897`，并让 loopback 直连。`nix-daemon` 自己执行
store substitution，只在 shell 里临时 export 代理不会影响它；Clash 未运行时远程
fetch/build 会失败。修改后需要一次 `nixos-rebuild switch` 才会写入 daemon 的运行
环境。

## 构建、应用与回滚

```bash
# 只构建，不切换当前系统
nix flake check --no-build
nix build --no-link .#nixosConfigurations.main.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel

# 用户确认后再应用；仓库不会自动执行 switch/boot
sudo nixos-rebuild switch --flake .#main
sudo nixos-rebuild switch --flake .#nixos

# 回滚
sudo nixos-rebuild switch --rollback
sudo nixos-rebuild boot --rollback
nix-env -p /nix/var/nix/profiles/system --list-generations
```

`hosts/main` 与 `hosts/nixos` 都暂时用 `nix.gc.automatic = lib.mkForce false` 保留
generation，直到至少一次成功重启和回滚验证完成。不要用删除 generation 的方式
腾空间。

## 当前桌面行为

### main：niri + Waybar

- 启动链：niri 的 user services 启动 Waybar、SwayNC、nm-applet、swaybg、cliphist；
  DMS 不启动。所有 unit 都 `PartOf`/`BindsTo`/`After` niri.service，并保留 no-DMS
  过渡守卫。Waybar 没有第二个 systemd unit，也没有 XDG autostart。
- 布局：左侧 `custom/launcher` + `niri/workspaces`（含每个工作区的真实应用图标和
  点击行为）；中间 `custom/clock`；右侧依次 CPU、RAM、合并网速、音量、网络状态、
  蓝牙、电池、通知、托盘。
- CPU 每 3 秒显示 `CPU {usage}%`，内存每 5 秒显示 `RAM {percentage}%`，二者固定
  宽度并常驻；点击打开 `kitty -e btop`，tooltip 显示原生负载或内存用量。
- 网速使用一个原生 `network#traffic`，每 2 秒更新；网络状态图标常驻，SSID/IP/
  信号放在 tooltip，避免长 SSID 挤压时钟。
- 样式为 Catppuccin Mocha、蓝色强调：透明 bar、三个半透明圆角区域、单色模块；
  红色/黄色只用于断网、静音、蓝牙关闭、低电量等状态。
- 时钟每 30 秒更新，格式 `%m月%d日 %a %H:%M`，中文 `LC_TIME`；tooltip 只有到分钟
  的时间，不显示每秒变化的秒数。
- 蓝牙：BlueZ 开机上电，Blueman 管理设备；Waybar 原生 bluetooth 模块左键打开
  `blueman-manager`。未检测到适配器时显示 no-controller 状态，不会导致 Waybar
  崩溃。
- 锁屏：`Alt+L` 调用 `niri-lock`，通过 systemd user unit 启动 Hyprlock；power menu
  的 Lock 也是同一入口。当前仓库仍是 `Alt+L`，不是 `Mod+Shift+L`；后者保持
  `move-column-right`，以免覆盖常用移动键。Hyprlock 由 Home Manager 安装和配置，
  PAM 只在 main 上启用；没有启用全局 Hypridle。
- 终端：kitty 背景 90% 不透明度，文字保持不透明，配色与 Waybar 一致。
- 显示器：`config/niri/config.kdl` include 用户可写的 `~/.config/niri/monitor.kdl`；
  Home Manager 只在该文件缺失时创建空文件，不覆盖已有布局。`Mod+P` 打开补丁版
  nwg-displays，`Mod+Alt+P` 强制打开内屏。
- Sway 仍使用独立的 `config/sway/config`、Mako、Fuzzel、Waybar `config.jsonc` 和
  原 teal 样式；不会加载 niri Waybar 的 Catppuccin 样式。

### nixos：niri + DMS

- niri 默认使用 DMS；`config-dms.kdl` 仍是只读 Home Manager 链接，`Alt+L` 仍是
  DMS 锁屏，`Mod+P`/`Mod+Alt+P` 保持原行为。
- Waybar 只保留生成的 profile 文件，不启动；没有蓝牙、Hyprlock 或 kitty 半透明
  作用域。Sway 备用会话和可选 Plasma 模块保留。

### 待实机验收

本轮只做离线求值、构建、补丁回归和配置检查；以下项目需要用户在 main 的图形会话
中确认，不能在 agent 会话里自动锁屏或断屏测试：

- Hyprlock 背景、时间/日期、输入框、PAM 解锁和失败提示；
- Waybar 在 1280 逻辑像素宽度下的实际不重叠、图标字体和托盘；
- 蓝牙适配器开关、配对、连接和 Blueman 入口；
- nwg-displays 禁用输出后重新启用、热插拔、分数缩放和 `monitor.kdl` 写回；
- kitty 透明度与文字可读性。

自动空闲锁屏、自动息屏、自动休眠以及 suspend 前统一锁屏没有在本轮新增；它们需要
单独确定时长和会话行为。Hyprlock 只统一了现有手动锁屏入口。

## 网络、密钥与备份

- NetworkManager、systemd-resolved、Tailscale 和 Clash Verge Rev 的边界见
  [`docs/RECOVERY.md`](docs/RECOVERY.md)；订阅、节点、Token 不进入仓库或 Nix store。
- SOPS 密文在 `secrets/secrets.yaml`，age 私钥只在每台机器本地；备份默认关闭，
  启用前必须填写真实 USB UUID 并完成恢复演练。
- OpenSSH、公钥和密码认证加固的注意事项见 [`docs/RECOVERY.md`](docs/RECOVERY.md)
  与 `hosts/nixos/default.nix`。不要在未验证第二登录路径前关闭密码认证。

## 更多文档

- 桌面组件、显示器文件、蓝牙、手动锁屏和实机验收：
  [`docs/DESKTOP.md`](docs/DESKTOP.md)
- TTY 恢复、网络、SOPS、Restic、SSH：
  [`docs/RECOVERY.md`](docs/RECOVERY.md)
- 开发环境、Python/Node、tmux、容器：
  [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- Arch/NixOS 双系统安装与恢复：
  [`docs/install/ARCH_DUAL_BOOT.md`](docs/install/ARCH_DUAL_BOOT.md)
- 历史迁移记录（2026-10-22，非当前桌面状态）：
  [`docs/install/MIGRATION.md`](docs/install/MIGRATION.md)
