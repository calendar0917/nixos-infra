# nixos-infra

`calendar` 的 NixOS 配置，使用单一 `flake.nix` / `flake.lock`、NixOS 原生模块和
NixOS 集成的 Home Manager。仓库同时管理两台机器；日常桌面以 niri 为主，Sway 是
不依赖 DMS 或 Waybar 生命周期的备用会话，Plasma 6 可选。

## 两台主机

| 主机 | 角色 | niri shell | 其他桌面 | 特殊硬件/功能 |
| --- | --- | --- | --- | --- |
| `main` | LENOVO 21LG 笔记本，Arch/NixOS 双系统 | Waybar（Catppuccin Mocha） | Sway 备用，Plasma 关闭 | 电池、蓝牙、Hyprlock、nwg-displays 多屏、主力应用 |
| `nixos` | KOLOE 小主机，SSH/轻量容器节点 | DMS | Sway 备用，Plasma 关闭 | 无电池、无蓝牙锁屏作用域，不装 Office/会议/OBS |

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
| 挂起前等待锁屏就绪 | 是，`swayidle -w` + logind LockedHint | 否 |
| 电源菜单 | 是，`Alt+Shift+L`，`niri-power-menu` | 否 |
| kitty 完整 Catppuccin Mocha/半透明 | 是 | 否，保持原样 |
| Helix 默认编辑器 | 是，`hx` | 是，`hx` |
| Obsidian/腾讯会议/QQ/微信/ONLYOFFICE/OBS | 是，仅 `main` | 否 |
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
  apps.nix                          # main-only 应用、OBS 和 MIME 默认程序
  helix.nix                         # Helix 配置、主题和语言服务器
  desktop/shell.nix                 # 面板/通知/壁纸/网络 applet 生命周期
  desktop/power.nix                  # 电源菜单、布局计算和 wlogout 样式
  desktop/clipboard.nix             # cliphist 服务和 helper
  desktop/lock.nix                  # Hyprlock、锁屏等待和 swayidle 睡眠钩子
  desktop/waybar/                   # Sway 与 niri 两套 profile
config/niri/                        # 两套只读 niri KDL
config/waybar/                      # Sway 样式 + niri Catppuccin 样式
patches/                            # nwg-displays 本地补丁
tests/                              # 无 GUI 的 Python 回归检查
docs/DESKTOP.md                     # 桌面组件、显示器、蓝牙、锁屏和实机验收
docs/APPS.md                        # 主力机应用、默认打开方式和 OBS
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

## 分支与部署

Git 的 `main` 分支和 flake 的 `#main` 主机是两件事：前者是代码分支，后者是
`nixosConfigurations.main` 这台笔记本。应用命令中的 `.#main` 指主机名，不是
Git 分支名。小主机对应 `.#nixos`。

当前工作流是功能分支 `daily-desktop-polish` 完成后创建 PR，通过检查再合入
Git `main`；不在功能分支上直接长期部署。系统切换、重启和挂起仍由用户主动执行。

## 当前桌面行为

### main：niri + Waybar

- 启动链：niri 的 user services 启动 Waybar、SwayNC、nm-applet、swaybg、cliphist；
  DMS 不启动。所有 unit 都 `PartOf`/`BindsTo`/`After` niri.service，并保留 no-DMS
  过渡守卫。Waybar 没有第二个 systemd unit，也没有 XDG autostart。
- 布局：左侧 `custom/launcher` + `niri/workspaces`（含每个工作区的真实应用图标和
  点击行为）+ `network#traffic`；中间 `custom/clock`；右侧依次 CPU、RAM、音量、
  网络状态、蓝牙、电池、通知、`group/tray`。
- CPU 每 3 秒显示 `CPU {usage}%`，内存每 5 秒显示 `RAM {percentage}%`，二者固定
  宽度并常驻；点击打开 `kitty -e btop`，tooltip 显示原生负载或内存用量。
- 网速使用一个原生 `network#traffic`，每 2 秒更新，放在工作区右侧并用次要色；
  网络状态图标常驻，SSID/IP/信号放在 tooltip，避免长 SSID 挤压时钟。
- 样式为 Catppuccin Mocha、蓝色强调：整条底栏使用连续的
  `rgba(30,30,46,0.94)` 背景、1px 蓝色细边框和 10px 圆角，左右/中间区域不再各自
  画胶囊；CPU/RAM 固定宽度，红色/黄色只用于断网、静音、蓝牙关闭、低电量等状态。
- 托盘使用 Waybar 原生 `group/tray` drawer：默认只显示 `⋯`，悬停展开真实图标，
  点击应用图标仍可操作；没有杀掉 nm-applet、Blueman 或 Fcitx5 的进程。
- 时钟每 30 秒更新，格式 `%m月%d日 %a %H:%M`，中文 `LC_TIME`；tooltip 只有到分钟
  的时间，不显示每秒变化的秒数。
- 蓝牙：BlueZ 开机上电，Blueman 管理设备；Waybar 原生 bluetooth 模块左键打开
  `blueman-manager`。未检测到适配器时显示 no-controller 状态，不会导致 Waybar
  崩溃。
- 锁屏：`Alt+L` 调用 `niri-lock`；`Alt+Shift+L` 打开 `niri-power-menu`，五张卡片
  依次是锁屏、挂起、退出、重启、关机。退出/重启/关机继续用 Fuzzel 二次确认，
  默认“取消”。当前仓库**没有**把 `Mod+Shift+L` 改成菜单，它仍是
  `move-column-right`；实际菜单快捷键是 `Alt+Shift+L`。
- 挂起：电源菜单的“挂起”先运行 `niri-lock-wait`，只有 logind 报告
  `LockedHint=yes` 才执行 `systemctl suspend`。main 的 `swayidle -w` 绑定同一个
  `before-sleep`，覆盖正常 logind 挂起/合盖路径；没有新增自动空闲或自动休眠。
  logind delay inhibitor 有最大时限，不能保证外部强制挂起永远被阻止。
- Hyprlock 由 Home Manager 安装和配置，PAM 只在 main 上启用；没有启用全局
  Hypridle，也没有使用 niri 未实现的 `hyprland-lock-notify-v1`。
- 终端：kitty 使用完整 `Catppuccin-Mocha` 主题文件，背景 90% 不透明度、文字不透明，
  `hide_window_decorations yes`、`tab_bar_style hidden`，不再手写局部前景/背景色。
- 编辑器：Helix 是默认编辑器；`hx --health` 已验证 nil/nixfmt、pyright、
  bash-language-server、JSON 和 YAML server 的入口，Neovim 专属声明已移除。
- 应用：Obsidian、腾讯会议、QQ、微信、ONLYOFFICE 和 OBS 只在 main 安装；
  PDF/常见图片/MP4/WebM 默认由 Firefox 打开，Office 文档由 ONLYOFFICE 打开。
- 显示器：`config/niri/config.kdl` include 用户可写的 `~/.config/niri/monitor.kdl`；
  Home Manager 只在该文件缺失时创建空文件，不覆盖已有布局。`Mod+P` 打开补丁版
  nwg-displays，`Mod+Alt+P` 强制打开内屏。
- Sway 仍使用独立的 `config/sway/config`、Mako、Fuzzel、Waybar `config.jsonc` 和
  原 teal 样式；不会加载 niri Waybar 的 Catppuccin 样式。

### nixos：niri + DMS

- niri 默认使用 DMS；`config-dms.kdl` 仍是只读 Home Manager 链接，`Alt+L` 仍是
  DMS 锁屏，`Mod+P`/`Mod+Alt+P` 保持原行为。
- Waybar 只保留生成的 profile 文件，不启动；没有蓝牙、Hyprlock、swayidle、
  电源菜单或 kitty 半透明作用域。Sway 备用会话和可选 Plasma 模块保留。
- 默认编辑器与 main 共享 Helix，但 DMS、Sway、显示器修复和应用作用域不变。

### 待实机验收

本轮已做离线求值、两台主机构建、应用 derivation 构建、配置解析和无 GUI 模拟；
以下项目仍需要用户在 main 的图形会话中确认，不能在 agent 会话里自动锁屏或断屏：

- QQ/微信/Obsidian/腾讯会议/ONLYOFFICE 的中文输入、缩放、打开/收发文件；
- 腾讯会议音视频和双向屏幕共享；
- OBS 一分钟带声音录屏、MKV remux 和 Firefox 回放；
- kitty 新窗口的标题栏/标签栏消失、完整 Catppuccin 配色和透明度；
- Waybar 在 1280/1536/1920 逻辑宽度下的连续底栏、网速位置、托盘悬停和菜单；
- 电源菜单居中卡片、图标、中文标签、Esc 关闭和确认取消；
- `Alt+L`、电源菜单挂起、正常 logind 挂起/合盖唤醒后的解锁和 LockedHint。

自动空闲锁屏、自动息屏和自动休眠仍未新增；本轮只补齐挂起前锁屏和电源菜单。

## 网络、密钥与备份

- NetworkManager、systemd-resolved、Tailscale 和 Clash Verge Rev 的边界见
  [`docs/RECOVERY.md`](docs/RECOVERY.md)；订阅、节点、Token 不进入仓库或 Nix store。
- SOPS 密文在 `secrets/secrets.yaml`，age 私钥只在每台机器本地；备份默认关闭，
  启用前必须填写真实 USB UUID 并完成恢复演练。
- OpenSSH、公钥和密码认证加固的注意事项见 [`docs/RECOVERY.md`](docs/RECOVERY.md)
  与 `hosts/nixos/default.nix`。不要在未验证第二登录路径前关闭密码认证。

## 更多文档

- 桌面组件、显示器文件、蓝牙、手动锁屏、挂起和实机验收：
  [`docs/DESKTOP.md`](docs/DESKTOP.md)
- 主力机应用、默认打开方式、OBS 录屏和待实机项：
  [`docs/APPS.md`](docs/APPS.md)
- TTY 恢复、网络、SOPS、Restic、SSH：
  [`docs/RECOVERY.md`](docs/RECOVERY.md)
- 开发环境、Python/Node、tmux、容器：
  [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- Arch/NixOS 双系统安装与恢复：
  [`docs/install/ARCH_DUAL_BOOT.md`](docs/install/ARCH_DUAL_BOOT.md)
- 历史迁移记录（2026-10-22，非当前桌面状态）：
  [`docs/install/MIGRATION.md`](docs/install/MIGRATION.md)
