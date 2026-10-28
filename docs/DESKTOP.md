# 桌面组件与实机验收

本文记录仓库中的桌面职责边界、显示器文件管理、蓝牙入口、手动锁屏和 main 的实机
验收步骤。当前 checkout 的离线结果不能代替图形会话测试；未实际执行的检查均标为
“待实机验证”。

## 1. 作用域与组件归属

| 组件 | 位置 | main | nixos |
| --- | --- | --- | --- |
| niri 主配置 | `config/niri/config.kdl` / `config-dms.kdl` | Waybar profile | DMS profile |
| Waybar 面板 | `home/calendar/desktop/waybar/` | 启动 | 只生成文件，不启动 |
| 面板/通知/壁纸/applet 生命周期 | `home/calendar/desktop/shell.nix` | 启动 | 跳过 |
| 剪贴板 watcher 和菜单 | `home/calendar/desktop/clipboard.nix` | 启动 | 跳过 |
| Hyprlock 与 `niri-lock` | `home/calendar/desktop/lock.nix` | 启动/安装 | 跳过 |
| nwg-displays 补丁 | `hosts/main/nwg-displays.nix`、`patches/` | 覆盖包 | 使用原包 |
| 蓝牙 | `hosts/main/default.nix` | 开启 | 不开启 |
| kitty 配色/透明 | `home/calendar/terminal.nix` | 透明 | 不透明 |

共享 Nix 文件在 `nixos` 上仍必须能求值和构建，但不会因此启用 main 的面板、蓝牙或
Hyprlock。`modules/desktop/niri.nix` 的 `shell = "dms" | "waybar"` 是主机级选择；
不要删除 DMS、`config-dms.kdl`、Sway 或可选 Plasma 模块。

## 2. Waybar 生命周期

main 上只有 `niri.service` 绑定的 user units，没有第二个 Waybar 服务，也没有
`spawn-at-startup waybar` 或 XDG autostart：

```bash
systemctl --user status waybar.service swaync.service nm-applet.service swaybg.service niri-cliphist.service
systemctl --user status niri-lock-screen.service
```

`waybar.service` 读取 `~/.config/waybar/niri.jsonc` 和 `style-niri.css`。Sway 仍由
`config/sway/config` 直接执行 `waybar`，读取 `~/.config/waybar/config.jsonc` 和
`style.css`；两套样式独立。不要在 niri 中同时启动 DMS 面板。

`niri-lock-screen.service` 没有 `WantedBy`，不会开机或登录时自动启动；它只由
`niri-lock` 或 `niri-power lock` 触发。

## 3. 显示器与 `monitor.kdl`

- `config/niri/config.kdl` 使用 `include "monitor.kdl"`。该文件由 nwg-displays 写入
  实际输出布局，Home Manager 只在它**缺失**时创建一个普通可写空文件，不把它变成
  store 软链，也不覆盖已有内容。
- 不要为了 GUI 写回而把整个 `config.kdl` 改成可变文件；主配置仍由仓库只读管理。
- `Mod+P` 打开补丁后的 `nwg-displays`。`Mod+Alt+P` 是恢复内屏 `eDP-1` 的逃生键。
- 补丁保留禁用输出：有 modes 的禁用显示器会出现在 GUI 中，可重新启用；没有 modes
  的异常输出跳过并记录，不拖垮正常输出。Sway/Hyprland 的解析分支不变。
- 实机先核对：

  ```bash
  niri msg -j outputs | jq
  command -v nwg-displays
  nwg-displays --version 2>&1 || true
  ```

  若实际故障不是 `current_mode`/`logical` 为 null，应保留本补丁并另行记录真实
  stderr，不要把假设写成诊断结论。

## 4. 蓝牙

main 上启用 `hardware.bluetooth`（含 `powerOnBoot`）和 `services.blueman`。Waybar
使用原生 `bluetooth` 模块，不在后台每秒执行 `bluetoothctl`：

```bash
systemctl status bluetooth --no-pager
rfkill list bluetooth
bluetoothctl show
bluetoothctl devices
```

- 关闭、开启、已连接状态通过原生类和图标区分；无适配器时显示 no-controller 状态。
- 左键打开绝对路径的 `blueman-manager`；设备名和连接详情在 tooltip。
- 不额外添加第二个 Blueman applet 启动项；Blueman 包/DBus 自启动由模块管理。
- 音频仍只走 PipeWire/WirePlumber，没有新增 PulseAudio、hsphfpd 或实验性 BlueZ
  参数。
- 待实机验证：适配器开关、配对/连接、断开后 Waybar tooltip、无设备时的显示。

## 5. 手动锁屏（main）

入口统一为 `niri-lock`：

```bash
niri-lock                                      # systemctl --user start niri-lock-screen.service
systemctl --user status niri-lock-screen.service
journalctl --user -u niri-lock-screen.service -b --no-pager
```

- `Alt+L`（`config/niri/config.kdl`）和 power menu 的 Lock 都调用它。
- 当前仓库**没有**把 `Mod+Shift+L` 改成锁屏；它是 `move-column-right`。用户口述的
  快捷键可能来自另一份运行中的配置或旧会话，应用本分支后以 `Alt+L` 为准。
- Hyprlock 由 Home Manager 安装，配置为 `~/.config/hypr/hyprlock.conf`；main 的
  `security.pam.services.hyprlock = {}` 提供 PAM 认证。没有启用 NixOS
  `programs.hyprlock.enable`，因此不会隐式启用 Hypridle。
- 服务与 niri 生命周期绑定，并检查 `WAYLAND_DISPLAY`、`NIRI_SOCKET` 和 no-DMS 守卫；
  没有 `Restart`，systemd 负责防止重复启动。
- 测试会锁住当前屏幕。只有在用户明确授权、并确认可以输入密码解锁时才执行；不要
  在远程 agent 会话里直接运行。
- 以下行为本轮**未新增**：自动空闲锁屏、自动息屏、自动休眠、suspend 前强制锁屏、
  指纹/人脸认证。手动 Alt+L 与 power menu 已有统一入口，但 suspend 路径没有因此
  自动锁屏。

Sway 继续使用 `config/sway/config` 中的 `swaylock`，Sway 的 PAM 配置保留；小主机
niri 继续使用 DMS 自带的锁屏。DMS 运行时 `niri-lock-screen.service` 会被守卫拒绝，
避免过渡期间两套锁屏竞争。

## 6. 终端与视觉

- kitty 的基础字体、fish 集成、复制和 scrollback 不变；main 的 niri Waybar 作用域
  增加 90% 背景不透明度、动态背景透明度、8px padding 和 Catppuccin Mocha 颜色。
  不设置整个窗口的不透明度，文字保持清晰。
- Waybar 视觉：`height = 34`，顶部 8px、左右 10px 外边距；三个区域为
  `rgba(30,30,46,0.92)` 圆角底色和蓝色细边界；普通模块单色，不用彩色胶囊、装饰
  箭头或重阴影。
- 时钟字体加粗，日期使用中文 locale；CPU/内存固定宽度常驻，1280 逻辑像素下优先
  缩短网速/托盘留白，不能隐藏 CPU 或内存来“通过”验收。

## 7. main 实机验收清单

在用户主动应用新 generation 并重新登录后执行；先确认当前会话可以回滚：

```bash
# 会话与 unit
systemctl --user --failed
systemctl --user status waybar.service niri-lock-screen.service
pgrep -a -u "$USER" -f 'waybar|dms|mako|swaync|nm-applet|hyprlock'

# 配置生成
jq . ~/.config/waybar/niri.jsonc >/dev/null
test -s ~/.config/hypr/hyprlock.conf && echo hyprlock.conf-ok
test -w ~/.config/niri/monitor.kdl && echo monitor.kdl-writable
readlink -f ~/.config/niri/config.kdl

# niri 快捷键和输出（只读）
niri msg -j outputs | jq
niri msg -j workspaces | jq

# 锁屏只在明确授权后测试；解锁后检查没有残留进程
niri-lock
systemctl --user status niri-lock-screen.service
```

逐项确认：

1. CPU、RAM、时钟、网速、音量、网络、蓝牙、电池、通知和 tray 都在预期区域；
   1280 宽度下中间时钟不被挤压，工作区图标和点击行为正常。
2. 点击 CPU/RAM 打开 kitty + btop；音量滚轮和 pavucontrol 正常。
3. 蓝牙关闭/开启/连接状态可区分，点击打开 Blueman，设备详情在 tooltip。
4. `Alt+L` 只启动一个 Hyprlock；错误密码显示失败提示，正确密码可 PAM 解锁；
   power menu Lock 行为相同。
5. nwg-displays 能打开；禁用有 modes 的输出后仍出现在 GUI 中并可重新启用；
   `monitor.kdl` 是普通可写文件，不覆盖手工布局。
6. kitty 背景半透明而文字清晰；Sway 会话仍使用原 Waybar/Mako 样式和 swaylock。
7. 重启/重新登录后没有 DMS 与 Waybar 双面板、双通知服务或残留锁屏进程。

构建失败、缓存不可用或没有图形会话时，记录具体命令和错误，不要把“未执行”写成
“已通过”。系统切换、重启和锁屏测试都由用户主动执行。
