# 桌面组件与故障入口

本文说明桌面组件如何协作、哪些文件有特殊约定，以及出问题时先看哪里。仓库中的
配置能否构建不等于当前图形会话已经应用；GUI 行为未实际执行时写“待实机验证”。

## 1. 作用域

| 范围 | main | nixos |
| --- | --- | --- |
| niri 会话 | `config/niri/config.kdl` | `config/niri/config-dms.kdl` |
| 面板/通知/壁纸生命周期 | `home/calendar/desktop/shell.nix` + Waybar | DMS 自己的 unit |
| 电源菜单、锁屏等待、swayidle | `home/calendar/desktop/power.nix`、`lib.nix`、`lock.nix` | 不启用 |
| Sway 备用会话 | `config/sway/config-main` + `sway-*.service` | `config/sway/config` 原文件 |
| 显示器布局 | `home/calendar/desktop/displays.nix`（wdisplays + kanshi） | 不启用 |

不要把 DMS、`config-dms.kdl`、Sway 或可选 Plasma 模块当成 main 专属内容删除。
共享 Home Manager 文件必须在两台主机求值，但 main 的面板、Hyprlock、蓝牙和电源
菜单不会因此出现在小主机。

## 2. Waybar 与单实例

main 的 Waybar、SwayNC、nm-applet、swaybg 和剪贴板 watcher 由绑定
`niri.service` 的 systemd user units 启动；没有第二个 Waybar service、XDG
autostart 或 `spawn-at-startup waybar`。每个 unit 都带 no-DMS 过渡守卫。

```bash
systemctl --user status waybar.service swaync.service nm-applet.service \
  swaybg.service niri-cliphist.service
systemctl --user status swayidle.service niri-lock-screen.service
journalctl --user -u waybar.service -b --no-pager
```

- 不要让 DMS 和 Waybar 在同一个 niri 会话中同时运行。
- 托盘中的 nm-applet、Blueman、Fcitx5 代理功能必须保留；不要靠杀进程减少图标。
- Sway 读取自己的 `config/sway/config-main`、Waybar 配置和 Mako，不加载 niri 样式。

### Waybar 布局（main，niri）

| 区域 | 模块顺序 |
| --- | --- |
| 左 | `custom/launcher`、`niri/workspaces`（含工作区应用任务栏）、`cpu`、`memory`、`network#traffic` |
| 中 | `custom/clock` |
| 右 | `network#status`、`battery`、`custom/lid-mode`、`custom/notification`、`custom/system-control`、`group/tray` |

CPU、RAM 和实时上下行网速直接常驻，没有点击展开的监控抽屉；数值、tooltip 和
点击打开 btop 的行为与共享模块一致。网速仍是 Waybar 原生 `network` 模块，不运行
每秒轮询的 Shell 脚本。右栏的 `network#status` 与左侧 `network#traffic` 是两个
独立原生实例。音量、蓝牙、亮度、电源档位不再常驻右栏，统一进入系统控制中心；
底层 PipeWire、BlueZ、背光和 power-profiles-daemon 服务不变。

托盘继续由 `group/tray` 的鼠标悬停抽屉展开，nm-applet、Blueman 等原有托盘程序
保留，不通过杀进程精简。

### 系统控制中心（main，niri）

`Mod+S` 或点击右栏齿轮调用 `niri-system-control launch`，在单个 Kitty 浮动窗口中
打开 fzf 主菜单。程序名和命令接口固定：

| 菜单项 | 实际工具 |
| --- | --- |
| 网络连接 | `nmtui`（`pkgs.networkmanager`） |
| 蓝牙设备 | `bluetui` |
| 音频与音量 | `wiremix` |
| 屏幕亮度 | 本仓库的 fzf 亮度界面 + `brightnessctl` |
| 电源性能模式 | `powerprofilesctl`（只列实际支持的模式） |
| 合盖行为 | `lid-keep-awake.service` |
| 系统监控 | `btop` |
| 退出 | 关闭菜单；Esc 同样退出 |

- 主菜单按固定顺序显示以上八项；方向键选择、Enter 确认、Esc 关闭。
- 进入 `nmtui`、`bluetui`、`wiremix` 或 `btop` 后，程序正常退出会回到同一个
  Kitty 窗口的主菜单；异常退出会显示非零状态，按 Enter 后回到菜单，不会直接关窗。
- `network#status` 左键直接执行 `niri-system-control launch network`，在同一浮动
  窗口里打开 `nmtui`。
- 控制中心由 `home/calendar/desktop/system-control.nix` +
  `system-control.sh` 生成，工具依赖在 `runtimeInputs` 中固定，不读取交互式 Fish
  的 PATH、alias 或函数。它只在 main 的 Waybar 条件安装，不进入小主机 DMS。
- 诊断命令（除亮度/模式设置外均为只读）：

```bash
niri-system-control launch          # 与 Mod+S 相同的 GUI 入口
niri-system-control menu            # 当前终端直接打开
niri-system-control brightness-status
niri-system-control brightness-step -5
niri-system-control brightness-set 50
niri-system-control power
niri-system-control lid
powerprofilesctl list
systemctl --user status lid-keep-awake.service
```

`Mod+A` 仍是 `xdg-open 'superproductivity://add-task'`。原来的 `Mod+S` 显示/隐藏
Super Productivity 正式弃用，只移除该快捷键；应用、URL Scheme 和用户数据保留。
小主机 `config/niri/config-dms.kdl` 的 `Mod+S` 仍是 DMS 设置，`Mod+Alt+S` 仍是
main 的 Orca 切换，均未改动。应用和 handler 的说明见 [`APPS.md`](APPS.md)。

亮度和电源、合盖的细节见下文“滚轮、亮度与电源”和“main 的合盖模式与常驻资源”。

### Sway 会话生命周期

只有 main 用 systemd 管理 Sway 的子进程；小主机仍用 `config/sway/config` 里的裸
`exec waybar` / `exec mako` / `exec swaybg`，行为不变。

main 的 `home/calendar/desktop/sway.nix` 定义四个 unit：

| unit | 作用 |
| --- | --- |
| `sway-waybar.service` | Waybar，显式传 `~/.config/waybar/config.jsonc` 和 `style.css` |
| `sway-mako.service` | Mako 通知守护 |
| `sway-bg.service` | `config/wallpapers/background.jpg` 壁纸 |
| `sway-exit-watch.service` | Sway 退出后停止会话 target 并清理 `SWAYSOCK` |

四个 unit 都是 `WantedBy=` / `PartOf=` / `BindsTo=` / `After=sway-session.target`，并
带 `ConditionEnvironment=SWAYSOCK`。因此它们只会随 Sway 会话启动，在 niri 里执行
Home Manager activation 不会误启；也不存在 `waybar.service`、`swaybg.service`、
`swaync.service` 被覆盖的风险，niri 的同名 unit 保持独立。

`sway-exit-watch.service` 的处理顺序：

1. 等 Sway IPC 可连接。
2. `swaymsg -t subscribe '["shutdown"]'` 订阅退出。
3. IPC 结束后再确认 Sway 不可连接；仍可连接就失败并由 `Restart=on-failure` 重试，
   不会提前拆会话。
4. 从 systemd 用户环境 unset `SWAYSOCK`。
5. `niri.service` 未运行时，用 `--no-block` 异步停止 `sway-session.target` 和
   `graphical-session.target`。
6. `niri.service` 正在运行时，只停止残留的 `sway-session.target`，**绝不动** niri
   正在使用的 `graphical-session.target`。

用 `--no-block` 是因为该 unit 自己 `BindsTo=sway-session.target`，同步 stop 会卡住
任务队列。不要用 `pkill sway` / `pkill waybar` / `pkill fcitx5` 代替生命周期管理。

main 的 niri user unit 额外设置 `UnsetEnvironment=SWAYSOCK`，所以即使系统环境里还
残留旧的 Sway socket，niri 和它启动的进程也不会继承。

```bash
systemctl --user status sway-waybar.service sway-mako.service sway-bg.service \
  sway-exit-watch.service
systemctl --user list-dependencies sway-session.target
journalctl --user -b -u sway-exit-watch.service --no-pager
```

### Sway 快捷键（main）

main 的 Sway 操作习惯与 niri 对齐；主要差异只在内核命令，不复制 niri 专用 IPC。

| 按键 | 动作 |
| --- | --- |
| `Mod+T` | kitty |
| `Mod+E` | Nautilus |
| `Mod+D`、`Alt+Space` | Fuzzel |
| `Mod+M` | `kitty -e btop` |
| `Mod+P` | wdisplays |
| `Mod+V` | 切换浮动（原 `Mod+V` 的 `split v` 改到 `Mod+Ctrl+V`） |
| `Mod+Ctrl+V` | `split v` |
| `Alt+L` | swaylock |
| `Mod+Shift+E` | 退出确认（swaynag） |
| `Mod+Shift+C` / `Mod+Shift+R` | reload / restart |

音量、亮度、截图、焦点移动、工作区数字键和 resize mode 保持原样。原文件
`config/sway/config` 不变，只给小主机使用；新增文件是 `config/sway/config-main`。

### 滚轮、亮度与电源

- `niri/workspaces` 启用原生 `enable-bar-scroll`；栏的普通区域上滚/下滚切换工作区，
  niri 在首尾停止、不循环。右栏已没有音量/亮度滑条，不会再出现一次滚动同时改
  设备状态并切工作区的问题。
- 亮度不再常驻 Waybar。`Mod+S` → 屏幕亮度进入 fzf 界面：预览持续显示
  `当前亮度：NN%`；`←`/`h` 每次降低 5%，`→`/`l` 提高 5%，`H`/`L` 降低/提高 1%，
  按键即时生效；`5%`、`25%`、`50%`、`75%`、`100%` 预设按 Enter 立即应用，
  Esc 返回主菜单。
- 亮度设备固定为 `amdgpu_bl1`。脚本先读取 `brightnessctl -d amdgpu_bl1 get` 和
  `max` 计算百分比，再以绝对百分比写入；所有路径统一 clamp 到 **5%–100%**，
  `brightness-set 0` 也会落到 5%。设备不存在、最大值为 0 或读取失败时直接报错，
  绝不回退到其他背光设备。
- `XF86MonBrightnessUp`/`XF86MonBrightnessDown` 仍由 niri 直接调用
  `brightnessctl`，按实际最大值计算 5% 下限；亮度 TUI 是补充入口，不替代硬件键。
- 仅 main 启用 `services.power-profiles-daemon`。控制中心的“电源性能模式”读取
  `powerprofilesctl get` 和 `list`，只显示并允许实际支持的档位，当前档位有标记；
  选择当前档位是空操作。首次仍是 `balanced`，之后由 PPD 保存手动选择，登录/
  插拔电源不强制覆盖，也没有自动切换钩子。
- 电池模块每 10 秒读取原生 `{power}`，只在放电格式显示电池侧功率；充电、插电、
  满电使用文字状态，不把充电功率标成整机耗电。`power_now` 不可用的硬件不应照搬
  该字段。

同亮度、同负载比较档位时，分别用同一命令/构建在放电状态运行，记录
`powerprofilesctl get`、Waybar 电池功率和 `time` 结果并重复一次。读数是电池侧
功率，不是墙插整机功率。亮度按键、预设、下限和档位切换仍需应用 generation 后
实机验收。

### main 的合盖模式与常驻资源

main 的 niri Waybar 左侧直接常驻 CPU、RAM 和实时上下行网速，不再有点击展开的
`⌁` 资源抽屉。数值、tooltip 和点击打开 btop 的能力保持不变。右栏保留
电池百分比/放电功率、网络状态、合盖状态、通知、系统控制和托盘；音量、蓝牙、
亮度、电源档位移入系统控制中心。这个变化只影响 main 的 niri 配置。

电池附近的 `☾` / `☕` 是合盖行为快捷切换；控制中心的“合盖行为”提供相同目标状态：

- `☾`：默认模式；未主动拦截 logind 合盖事件。
- `☕`：正在运行 `lid-keep-awake.service`，请求 logind 忽略合盖事件。
- 点击图标调用 `niri-lid-mode toggle` 启停 user service；不会每次 rebuild。
- 控制中心显示当前状态，并只在目标状态不同时执行
  `systemctl --user start/stop lid-keep-awake.service`；重复选择同一状态是空操作，
  不使用盲目的 toggle。
- 该服务未启用开机自启，并且绑定 `niri.service` 生命周期，退出 niri 后清理。
- 只拦截 `handle-lid-switch`，并不禁止主动 `systemctl suspend`。
  原有 `swayidle before-sleep` / `niri-lock-wait` 保持不变。
- **保持运行模式不会自动触发 before-sleep 锁屏**。临时合盖离开电脑时先按
  `Alt+L`，并避免在背包等散热不良的环境里长时间使用。控制中心会显示同一提示。
- Docked 和外接屏幕时 logind 自身可能忽略合盖，测试需要分开进行。
- 若获取 low-level inhibitor 被 polkit 拒绝，服务会启动失败；应先核实
  logind/polkit 权限，不要无条件放宽权限。

检查（不会主动挂起）：

```bash
systemctl --user status lid-keep-awake.service
systemd-inhibit --list
niri-lid-mode status
niri-system-control lid
```

应用新 generation 后，点击合盖图标或用控制中心切换，并用以上命令检查 inhibitor
是否真的存在，再在可安全恢复的环境中进行合盖测试；GUI/固件实际效果待实机验证。

## 3. 显示器布局：wdisplays + kanshi

显示器配置分成三层，互不替代：

| 层 | 工具 | 文件/状态 | 作用域 |
| --- | --- | --- | --- |
| 持久 Profile | wdisplays 写入、kanshi 读取 | `~/.config/kanshi/config`（可写） | niri 和 Sway 共用 |
| 自动应用 | `kanshi.service` | 绑定 `graphical-session.target` | main 的 niri 与 Sway |
| 临时覆盖 | `niri-display-menu` | 仅 `niri msg output` 的运行时状态 | 当前 niri 会话 |

`services.kanshi.settings = []` 是刻意设置：Home Manager 只管理 `kanshi.service`，
不生成只读的 Kanshi 配置。`home/calendar/desktop/displays.nix` 的 activation 只在
`~/.config/kanshi/config` **不存在**时复制一份初始文件（`profile portable` 加
`output eDP-1 enable`）；已有文件不会被覆盖、清空或换成 `/nix/store` 软链。

- 初始 Profile 只保证笔记本内屏可用，不为陌生外屏猜分辨率、缩放比例或固定位置。
- 连接已知外屏时 kanshi 使用该外屏已有的 Profile。
- 连接陌生外屏时保留内屏，用户用 wdisplays 调好布局后点 **Save to kanshi Config**
  保存，kanshi 重新加载后生效。
- 拔掉外屏后 kanshi 回落到仅内屏的 Profile。
- 任何情况下都不要在没有已确认活动外屏时关闭 `eDP-1`。

快捷键：

- `Mod+P`：打开 `wdisplays`（图形化手动布局）。
- `Mod+Ctrl+P`：打开显示模式菜单。固定四项：仅笔记本屏幕、扩展显示、仅外接显示器、
  高级显示设置（wdisplays）。
- `Mod+Alt+P`：紧急恢复入口，通过 IPC 重新启用 `eDP-1`。

显示模式菜单由 `home/calendar/desktop/display-menu.sh` 提供，只在调用时执行，没有
常驻进程、systemd unit/timer、udev 规则或自动轮询。它使用 Fuzzel `--dmenu --index`，
只通过 `niri msg output ...` 临时切换输出：仅内屏先确认 `eDP-1` 活动再关闭活动外屏；
仅外屏先确认至少一个外屏活动再关闭内屏；扩展只启用可用输出，不关闭任何屏幕，也不
计算位置或实现镜像。

菜单的切换是运行时覆盖，kanshi 之后仍可能按 Profile 重新应用布局。需要长期生效时用
wdisplays 保存 Profile，不要依赖菜单的临时状态。

`config/niri/config.kdl` 不再 `include "monitor.kdl"`。旧的
`~/.config/niri/monitor.kdl` 保留在磁盘上，仅作旧布局记录，不参与加载；它的 `on`
关键字不是合法 niri KDL，曾让 niri 报 `unexpected node` 并使整份配置解析失败。不要
再加回 include，也不要删除该文件。

只读核对：

```bash
niri msg -j outputs | jq
cat ~/.config/kanshi/config
systemctl --user status kanshi.service
journalctl --user -b -u kanshi.service --no-pager
```

内屏黑屏时的恢复顺序：

1. `Mod+Alt+P` 通过 IPC 重新启用 `eDP-1`。
2. `Mod+Ctrl+P` 选“仅笔记本屏幕”。
3. 仍黑屏时，在带当前会话 `NIRI_SOCKET` 的 TTY 执行
   `niri msg output eDP-1 on`。
4. 仍无效时切到 Sway 备用会话用 wdisplays 修正布局，或临时移走
   `~/.config/kanshi/config` 后 `systemctl --user restart kanshi.service`。

真实 GUI 布局切换、外屏热插拔和陌生显示器行为待实机验证。nwg-displays 的本地补丁
和 overlay 已移除；它不再是当前操作入口。

## 4. 锁屏、电源菜单与挂起

### 手动锁屏

唯一入口是 `niri-lock`，它启动已有的 `niri-lock-screen.service`。`Alt+L` 和
电源菜单的“锁屏”都走这里；`Mod+Shift+L` 仍是 `move-column-right`，不要静默改键。

```bash
niri-lock
systemctl --user status niri-lock-screen.service
journalctl --user -u niri-lock-screen.service -b --no-pager
```

Hyprlock 由 Home Manager 安装，配置为 `~/.config/hypr/hyprlock.conf`；main 的
`security.pam.services.hyprlock` 提供 PAM 认证。服务没有 `Restart`，重复启动由
systemd 合并。测试会锁住当前屏幕，只能在用户明确授权并确认能输入密码时执行。

### 电源菜单

`Alt+Shift+L` 调用唯一入口 `niri-power-menu`。它读取 focused output 的
`logical` 尺寸，按宽屏或窄屏选择 one-row/one-column 布局，再启动 wlogout。

- 五张卡片：锁屏、挂起、退出、重启、关机。
- 退出、重启、关机使用 Fuzzel 二次确认，默认“取消”；Esc 或选择取消不执行动作。
- wlogout 读取换行分隔的 **JSON 对象流**，不是 JSON 数组；生成布局时保持该格式。
- 布局和 CSS 都使用生成的绝对 store 路径；不要手写 `-m` 外边距或硬编码
  store hash。

### 挂起前锁屏

`niri-lock-wait` 不伪造 `LockedHint`：

1. 从环境读取 `XDG_SESSION_ID`；缺失时直接失败。
2. 用 `loginctl show-session ... -p User --value` 核实会话属于当前 UID。
   systemd 262 的 `User` 属性值是 UID；没有 `UID` 属性，空值也不接受。
3. 启动 `niri-lock-screen.service`。
4. 轮询 logind 的 `LockedHint`，同时要求 unit 保持 active/activating。
5. 只有真正的 `yes` 才成功；超时、unit 失败或其他 UID 都取消挂起。

`swayidle -w` 复用同一入口作为 `before-sleep`。锁屏进程已启动不等于 logind 已
确认锁定；两者不能混为一谈。logind delay inhibitor 有最大时限，本方案不能保证
阻止所有外部强制挂起。

## 5. 终端、编辑器与蓝牙

### kitty

main 使用完整 `Catppuccin-Mocha` 主题文件，字号 13.5，背景半透明、文字保持不透明；
nixos 保持原终端外观（基础 `font_size = 11`，不带 Catppuccin 覆盖）。niri 额外有
一条只匹配 `app-id="^kitty$"` 的 `window-rule`，关闭焦点底板的实色背景；焦点边框和
主题继续保留。

如果新窗口仍像不透明，先确认运行的是包含该规则的配置，并检查顶部条是否其实是
niri 的 tabbed-column 指示器。不要用全局窗口 opacity 或焦点切换脚本替代。
最终视觉效果待实机验证。

### Neovim

`nvim` 是两台主机的默认编辑器：`home/calendar/nvim.nix` 打开
`programs.neovim.defaultEditor`，由 Home Manager 导出 `EDITOR`/`VISUAL=nvim`。
git 的 `core.editor`、fish 别名 `n` 和 Yazi 的编辑 opener 都指向同一个 `nvim`，
没有第二份编辑器配置。

`~/.config/nvim` 在 main 上由 `programs.lazyvim`（`home/calendar/lazyvim.nix`）
生成：`appName = "nvim"`，所以直接运行 `nvim` 就是 LazyVim，不再需要
`NVIM_APPNAME=lazyvim` 或 `lv` 别名。`init.lua` 是 Nix 生成的只读文件，由
lazyvim-nix 的启动代码和 Home Manager 的 provider 设置两段组成；要改配置请改
`home/calendar/lazyvim.nix`，不要在运行期编辑 `~/.config/nvim`。插件、语言服务器
和格式化器全部来自 Nix，Mason 的运行时安装已关闭。

小主机不导入 LazyVim 模块，只有 `programs.neovim` 的基础配置（同样的
`EDITOR`/`VISUAL`），没有 LazyVim 插件集。

启动 `nvim` 不等于 LSP 已完成补全/诊断；`:checkhealth` 可检查入口。旧的
`~/.config/lazyvim`、`~/.local/share/lazyvim` 属于此前 `NVIM_APPNAME=lazyvim`
的遗留目录，不由 Nix 管理，也不影响新的 `~/.config/nvim`。

### 蓝牙

main 启用 BlueZ（开机上电）和 Blueman；右栏不再常驻 Waybar 原生 `bluetooth`
模块，蓝牙设备统一从 `Mod+S` → 蓝牙设备（`bluetui`）进入。托盘中的 Blueman
仍可用，`blueman-manager` 也保留为图形备用入口。不要新增第二个 applet，也不要
为精简面板停用 BlueZ。

## 6. 检查与故障入口

- 只改文档：检查本地链接和 `git diff --check`，不构建系统。
- 桌面/Home Manager 改动：从 [`README.md`](../README.md) 的维护入口运行
  `scripts/check-desktop`；该脚本只做构建和无 GUI 回归，不激活 generation。
- 系统控制中心改动：`scripts/check-desktop` 会定位生成的 `niri-system-control`，
  用 stub 检查菜单、子 TUI 返回、亮度 clamp、电源档位、合盖状态、Waybar 布局和
  `Mod+S`/`Mod+A` 绑定；不会改真实亮度、网络、蓝牙、电源模式或 inhibitor。
  手动只读检查可用 `niri-system-control brightness-status` 和
  `powerprofilesctl list`。
- niri 配置改动：直接 `niri validate -c config/niri/config.kdl`。配置已不再 include
  `monitor.kdl`，不需要临时文件，也不会读写用户的布局记录。
- Sway 配置改动：`sway -C -c config/sway/config-main`（小主机仍是
  `config/sway/config`）。两者都会读取系统生成的 `include /etc/sway/config.d/*`。
- 会话故障：先看 `systemctl --user --failed`、waybar/swayidle/锁屏 unit 和
  `sway-exit-watch` 的 journal，以及 `niri msg -j outputs` / `niri msg -j workspaces`。
- 看不清桌面时用 TTY 或 Sway 备用会话恢复，具体步骤见
  [`RECOVERY.md`](RECOVERY.md)。

真实验收只保留简短方法：应用新 generation 并重新登录后，检查 Waybar 单元、
`Mod+S` 浮动控制中心及其中网络/蓝牙/音频/亮度/电源/合盖入口、`Alt+L` 与菜单
“锁屏”、挂起前 `LockedHint=yes`、kitty 焦点透明度、wdisplays 能否
**Save to kanshi Config** 写回 `~/.config/kanshi/config`，以及 Sway 登录/退出后
`sway-session.target` 是否真的停止。这些操作由用户主动执行；未实际执行的项目写
“待实机验证”。
