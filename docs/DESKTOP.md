# 桌面组件与实机验收

本文记录仓库中的桌面职责边界、显示器文件管理、蓝牙入口、编辑器、锁屏/挂起和
main 的实机验收步骤。当前 checkout 的离线结果不能代替图形会话测试；未实际执行的
检查均标为“待实机验证”。

## 1. 作用域与组件归属

| 组件 | 位置 | main | nixos |
| --- | --- | --- | --- |
| niri 主配置 | `config/niri/config.kdl` / `config-dms.kdl` | Waybar profile | DMS profile |
| Waybar 面板 | `home/calendar/desktop/waybar/` | 启动 | 只生成文件，不启动 |
| 面板/通知/壁纸/applet 生命周期 | `home/calendar/desktop/shell.nix` | 启动 | 跳过 |
| 电源菜单 | `home/calendar/desktop/power.nix` | `Alt+Shift+L` | 跳过 |
| 剪贴板 watcher 和菜单 | `home/calendar/desktop/clipboard.nix` | 启动 | 跳过 |
| Hyprlock、锁屏等待、swayidle | `home/calendar/desktop/lock.nix`、`lib.nix` | 启动/安装 | 跳过 |
| Helix | `home/calendar/helix.nix` | 默认编辑器 | 默认编辑器 |
| 主力机应用 | `home/calendar/apps.nix` | 安装 | 不安装 |
| nwg-displays 补丁 | `hosts/main/nwg-displays.nix`、`patches/` | 覆盖包 | 使用原包 |
| 蓝牙 | `hosts/main/default.nix` | 开启 | 不开启 |
| kitty 完整配色/透明 | `home/calendar/terminal.nix` | 完整 Catppuccin | 不透明，保持原样 |

共享 Nix 文件在 `nixos` 上仍必须能求值和构建，但不会因此启用 main 的面板、电源
菜单、蓝牙或 Hyprlock。`modules/desktop/niri.nix` 的 `shell = "dms" | "waybar"` 是
主机级选择；不要删除 DMS、`config-dms.kdl`、Sway 或可选 Plasma 模块。

## 2. Waybar 生命周期与布局

main 上只有 `niri.service` 绑定的 user units，没有第二个 Waybar 服务，也没有
`spawn-at-startup waybar` 或 XDG autostart：

```bash
systemctl --user status waybar.service swaync.service nm-applet.service swaybg.service niri-cliphist.service
systemctl --user status swayidle.service niri-lock-screen.service
```

`waybar.service` 读取 `~/.config/waybar/niri.jsonc` 和 `style-niri.css`。Sway 仍由
`config/sway/config` 直接执行 `waybar`，读取 `~/.config/waybar/config.jsonc` 和
`style.css`；两套样式独立。不要在 niri 中同时启动 DMS 面板。

main 的布局：

```text
左: custom/launcher -> niri/workspaces -> network#traffic
中: custom/clock
右: cpu -> memory -> pulseaudio -> network#status -> bluetooth -> battery
    -> custom/notification -> group/tray
```

- 左侧工作区仍包含每个工作区的真实应用图标和点击行为；网速移到工作区右侧。
- CPU 每 3 秒、内存每 5 秒更新，固定宽度常驻，点击打开 `kitty -e btop`。
- `network#traffic` 每 2 秒更新，使用次要色；完整 SSID/IP/信号仍放在
  `network#status` 的 tooltip。
- `group/tray` 默认只显示 `⋯`，悬停展开；drawer 参数为 150ms 过渡、150ms
  reveal-delay、从右向左、非点击展开、启动时折叠。
- CPU/RAM 不能为了 1280 宽度而隐藏；需要缩短的是网速/托盘留白。
- 不通过杀掉 nm-applet、Blueman 或 Fcitx5 进程来减少托盘图标；菜单、配对和输入法
  代理功能必须保留。

视觉上 `window#waybar` 是连续底栏：`rgba(30,30,46,0.94)` 背景、1px
`rgba(137,180,250,0.12)` 边框、10px 圆角，顶部外边距 6px、左右 8px，
`height = 34`。`modules-left/center/right` 背景透明，不再各自画圆角胶囊。

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

## 5. 锁屏、电源菜单与挂起

### 手动锁屏

入口统一为 `niri-lock`：

```bash
niri-lock                                      # systemctl --user start niri-lock-screen.service
systemctl --user status niri-lock-screen.service
journalctl --user -u niri-lock-screen.service -b --no-pager
```

- `Alt+L` 调用 `niri-lock`；电源菜单的“锁屏”也是同一入口。
- 当前仓库**没有**把 `Mod+Shift+L` 改成锁屏或菜单；它是 `move-column-right`。
  用户口述的快捷键可能来自另一份运行中的配置或旧会话。实际电源菜单快捷键是
  `Alt+Shift+L`。
- Hyprlock 由 Home Manager 安装，配置为 `~/.config/hypr/hyprlock.conf`；main 的
  `security.pam.services.hyprlock = {}` 提供 PAM 认证。没有启用 NixOS
  `programs.hyprlock.enable`，因此不会隐式启用 Hypridle。
- 服务与 niri 生命周期绑定，并检查 `WAYLAND_DISPLAY`、`NIRI_SOCKET` 和 no-DMS 守卫；
  没有 `Restart`，systemd 负责防止重复启动。
- 测试会锁住当前屏幕。只有在用户明确授权、并确认可以输入密码解锁时才执行；不要
  在远程 agent 会话里直接运行。

### 电源菜单

`Alt+Shift+L` 调用唯一入口 `niri-power-menu`。它从
`niri msg -j focused-output` 读取当前输出的 `logical.width`/`logical.height`，
而不是 `current_mode` 的物理像素，然后按以下规则计算 wlogout 参数：

- 宽屏（W >= 760 且 H >= 320）：一行五张，卡片内容 688x152（5×128 + 4×12），
  `-b 5 -c 12 -r 0`。
- 窄屏：一列五张，`contentW = min(320, W-32)`、`contentH = min(432, H-32)`，
  `-b 1 -c 0 -r 8`。五个 80px 卡片加四个 8px 间距需要 432px，无法容纳时显示
  错误，不传负外边距。窄屏使用独立的紧凑 CSS（26px 图标、34px 上内边距），
  避免把 40px 图标裁进 80px 卡片。
- 左右/上下使用对称余数：
  `L=floor((W-contentW)/2)`、`R=W-contentW-L`，`T/B` 同理。
- 只传 `-L/-R/-T/-B`，不再使用 `-m 10`；`-p layer-shell -n` 保证菜单只出现在
  计算过大小的 focused output 上。
- `--layout` 和 `--css` 使用生成的绝对 store 路径；菜单用
  `$XDG_RUNTIME_DIR/niri-power-menu.lock` 和 flock 保证单实例。

五张卡片依次是锁屏 L、挂起 U、退出 E、重启 R、关机 S。Escape 直接关闭；退出、
重启、关机用 Fuzzel 二次确认，默认选中“取消”，Esc 或选择其他项都不执行动作。
锁屏不二次确认。样式为 Mocha 半透明遮罩、`#1e1e2e` 卡片、40px 图标和中文标签。

### 挂起前锁屏

`niri-lock-wait` 不伪造 `LockedHint`：

1. 从会话环境读取 `XDG_SESSION_ID`；缺失时直接报错，不猜第一个 session。
2. 用 `loginctl show-session ... -p UID --value` 核实 session 属于当前 UID。
3. 启动现有 `niri-lock-screen.service`。
4. 每约 50ms 读取一次 `LockedHint`，最多约 3 秒；同时要求 unit 保持
   active/activating，失败立即退出。
5. 只有 logind 真正报告 `yes` 才返回成功。

main 在 niri Waybar 作用域内启用 `services.swayidle`：

- `systemdTargets = [ "niri.service" ]`，额外 `BindsTo=niri.service`；
- 复用 no-DMS `ExecCondition`；
- `extraArgs = [ "-w" ]`；
- `before-sleep` 使用 `niri-lock-wait` 的绝对路径，`lock` 使用 `niri-lock`；
- 没有 idle timeout，不新增自动息屏/自动挂起，也不启动第二个 Hypridle。

电源菜单的“挂起”先同步执行 `niri-lock-wait`；失败则取消本次挂起。正常 logind
挂起/合盖由 `swayidle -w` 的 `before-sleep` 持有 delay inhibitor 后执行同一等待。
**边界**：logind delay inhibitor 有最大时限，不能宣称“任何锁屏失败都能阻止所有
外部挂起”；本方案保证菜单路径明确失败即取消，其他 logind 路径需实机验证。

## 6. 终端、编辑器与视觉

### kitty

main 使用完整 `Catppuccin-Mocha` 主题文件（`themeFile`），不再手写局部
foreground/background/selection 颜色。保留的行为设置：

```text
background_opacity 0.90
dynamic_background_opacity yes
window_padding_width 10
hide_window_decorations yes
tab_bar_style hidden
font_family JetBrains Mono
font_size 11.5
```

文字保持不透明；只让窗口背景半透明。标题栏和 kitty 标签栏在**新开**窗口中验证，
热重载不一定能改变已有窗口装饰。若仍有顶部条，先检查它是否是 niri 的 tabbed
column 指示器，不要为了修 kitty 关闭 Waybar 或移除所有焦点提示。小主机保持原有
不透明终端外观。

### Helix

`hx` 是 main 和 nixos 的默认编辑器；`programs.git.core.editor`、Fish 的 `n`、
`EDITOR`/`VISUAL` 都指向它。配置包括相对行号、cursorline、color-modes、
true-color 和 cursor-shape；主题为 `catppuccin_mocha_terminal`，只把
`ui.background` 清空以透出 kitty 背景，状态栏/选区仍使用原主题。

语言服务器通过 `extraPackages` 提供并写入 `languages.toml`：

```text
nix    -> nil
Python -> pyright-langserver --stdio
Bash   -> bash-language-server start
JSON   -> vscode-json-language-server --stdio
YAML   -> yaml-language-server --stdio
Nix formatter -> nixfmt
```

已验证 `hx --version`、`hx --health` 和上表五类语言的 server/formatter 入口。语法
高亮和语言服务器是不同检查项；不要在只启动 `hx` 后声称 LSP 可用。

旧 Neovim 专属声明、`config/nvim/` 和 LazyVim lock 激活逻辑已从仓库移除，但没有
删除 `~/.local/share/nvim`、`~/.local/state/nvim` 或用户自行维护的
`~/.config/nvim` 运行时目录。`modules/base.nix` 的救援 `vim` 保留。

## 7. 应用与默认打开方式

main 的 Obsidian、腾讯会议、QQ、微信、ONLYOFFICE 和 OBS 由
`home/calendar/apps.nix` 安装；小主机不安装。PDF、PNG/JPEG/WebP/GIF/SVG、
`video/mp4`、`video/webm` 默认由 Firefox 打开；DOC/DOCX、XLS/XLSX、PPT/PPTX、
ODT/ODS/ODP 由 `onlyoffice-desktopeditors.desktop` 打开；`obsidian://` 分派给
`md.obsidian.Obsidian.desktop`。没有设置 `video/*` 通配符。

应用细节、ONLYOFFICE 字体和 OBS 录屏步骤见
[`docs/APPS.md`](APPS.md)。

## 8. 离线检查命令

```bash
git diff --check
nix flake check --no-build
nix build --no-link .#nixosConfigurations.main.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.main.config.home-manager.users.calendar.home.activationPackage
nix build --no-link .#nixosConfigurations.nixos.config.home-manager.users.calendar.home.activationPackage

# niri validate：临时复制配置和空 monitor.kdl，不覆盖用户布局
tmp=$(mktemp -d)
cp config/niri/config.kdl "$tmp/config.kdl"
: > "$tmp/monitor.kdl"
niri validate -c "$tmp/config.kdl"
cp config/niri/config-dms.kdl "$tmp/config-dms.kdl"
niri validate -c "$tmp/config-dms.kdl"
rm -rf "$tmp"

# 生成物检查
jq . <home-manager-generation>/home-files/.config/waybar/niri.jsonc
test -s <home-manager-generation>/home-files/.config/kitty/kitty.conf
jq -r '.theme, .editor["line-number"]' <home-manager-generation>/home-files/.config/helix/config.toml
```

电源菜单布局和无 GUI 的锁屏等待/挂起取消路径已由
`tests/test_desktop_polish.py` 用 stub 命令覆盖；没有调用真实 `systemctl suspend`
或锁住当前桌面。该脚本需要传入 activation generation 中的脚本和生成文件：

```bash
gen=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.main.config.home-manager.users.calendar.home.activationPackage)
hp="$gen/home-path/bin"
layout=$(grep -o '/nix/store/[a-z0-9]*-niri-wlogout-layout' "$hp/niri-power-menu")
wide=$(grep -o '/nix/store/[a-z0-9]*-niri-wlogout-style-wide.css' "$hp/niri-power-menu")
narrow=$(grep -o '/nix/store/[a-z0-9]*-niri-wlogout-style-narrow.css' "$hp/niri-power-menu")
python3 tests/test_desktop_polish.py \
  --power-menu "$hp/niri-power-menu" \
  --power "$hp/niri-power" \
  --lock-wait "$hp/niri-lock-wait" \
  --layout "$layout" --style "$wide" --narrow-style "$narrow"
```

## 9. main 实机验收清单

在用户主动应用新 generation 并重新登录后执行；先确认当前会话可以回滚：

```bash
# 会话与 unit
systemctl --user --failed
systemctl --user status waybar.service swayidle.service niri-lock-screen.service
pgrep -a -u "$USER" -f 'waybar|dms|mako|swaync|nm-applet|hyprlock|swayidle'

# 配置生成
jq . ~/.config/waybar/niri.jsonc >/dev/null
test -s ~/.config/hypr/hyprlock.conf && echo hyprlock.conf-ok
test -w ~/.config/niri/monitor.kdl && echo monitor.kdl-writable
readlink -f ~/.config/niri/config.kdl

# 编辑器/终端
hx --version
hx --health
readlink -f ~/.config/kitty/kitty.conf

# niri 快捷键和输出（只读）
niri msg -j outputs | jq
niri msg -j workspaces | jq
```

逐项确认：

1. Waybar 连续半透明底栏、CPU/RAM 常驻、网速在工作区右侧；1280/1536/1920
   逻辑宽度下不互相挤压。
2. 托盘默认只显示 `⋯`，悬停展开，应用图标可点击；菜单不会立即消失，也没有
   永久空胶囊。
3. `Alt+Shift+L` 打开居中五卡片菜单，图标/中文标签正常，Esc 关闭；退出、重启、
   关机确认框默认“取消”，选择取消不会执行动作。
4. `Alt+L` 和菜单“锁屏”都只启动一个 Hyprlock；错误密码提示、PAM 解锁正常。
5. 菜单“挂起”在锁屏就绪后执行；正常 logind 挂起/合盖唤醒后需要解锁。检查
   `loginctl show-session "$XDG_SESSION_ID" -p LockedHint --value` 在锁屏期间为
   `yes`。
6. nwg-displays 能打开；禁用有 modes 的输出后仍出现在 GUI 中并可重新启用；
   `monitor.kdl` 是普通可写文件，不覆盖手工布局。
7. 新开 kitty 窗口没有标题栏/标签栏，背景半透明而文字清晰；Sway 会话仍使用原
   Waybar/Mako 样式和 swaylock。
8. 重启/重新登录后没有 DMS 与 Waybar 双面板、双通知服务、双 swayidle 或残留
   锁屏进程。

构建失败、缓存不可用或没有图形会话时，记录具体命令和错误，不要把“未执行”写成
“已通过”。系统切换、重启、锁屏和挂起测试都由用户主动执行。
