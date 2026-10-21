# 旧 niri 快捷键核对表

对照来源：

- **旧 dotfiles**：`/home/calendar/dotfiles/config/arch/niri/{config.kdl,dms/binds.kdl}`
- **旧 repo**：`/tmp/oldrepo/niri/{config.kdl,dms/binds.kdl}`（旧仓库历史版本）

符号：

- ✅ 按键组合和操作语义等价；
- ◐ 操作意图相同，但后端实现不同（DMS → `wpctl`/`playerctl`/`brightnessctl` 等）；
- ⚠ 两份旧配置互相冲突，新实现选择了其中一份；
- ❌ 旧组合未保留（原因见备注）。

## 系统、启动器和 DMS

| 旧键位 | 旧语义 | 新实现 | 等价 |
| --- | --- | --- | --- |
| `Mod+O` | `toggle-overview` | `Mod+O` → `toggle-overview` | ✅ |
| `Mod+Tab` | dotfiles：`toggle-overview`；repo 注释里有 `focus-workspace-previous` | `Mod+Tab` → `toggle-overview` | ✅（采用 dotfiles） |
| `Mod+Shift+Slash` | 显示快捷键帮助 | 同左 | ✅ |
| `Mod+T` | `kitty` | 同左 | ✅ |
| `Mod+E` | repo：`dolphin`；dotfiles：`nautilus` | `dolphin` | ⚠（采用 repo 的 dolphin） |
| `Mod+D` | DMS spotlight | DMS `spotlight toggle` | ✅ |
| `Alt+Space` | DMS spotlight bar | DMS `spotlight-bar toggle` | ✅ |
| `Mod+Alt+V` | dotfiles：DMS clipboard；repo：`clipse-gui` | DMS `clipboard toggle` | ◐（统一到 DMS） |
| `Mod+Shift+V` | dotfiles：`switch-focus-between-floating-and-tiling`；repo：DMS clipboard | `switch-focus-between-floating-and-tiling` | ⚠（采用 dotfiles；剪贴板见 `Mod+Alt+V`） |
| `Mod+M` | DMS processlist | DMS `processlist focusOrToggle` | ✅ |
| `Alt+Shift+L` | DMS power menu | 同左 | ✅ |
| `Mod+S` | DMS settings（repo 用 `toggle`，dotfiles 用 `focusOrToggle`） | `focusOrToggle` | ✅（语义等价） |
| `Mod+Y` | DMS wallpaper | 同左 | ✅ |
| `Mod+Alt+N` | DMS notifications | 同左 | ✅ |
| `Mod+Shift+W` | DMS window rules | 同左 | ✅ |
| `Ctrl+Shift+R` | DMS workspace rename | 同左 | ✅ |
| `Alt+L` | DMS lock | 同左 | ✅ |
| `Mod+Shift+E` | `quit` | 同左 | ✅ |
| `Ctrl+Alt+Delete` | dotfiles：DMS processlist；repo：`quit` | DMS `processlist focusOrToggle` | ⚠（采用 dotfiles 的排障语义） |
| `Mod+Shift+Escape` | repo 注释：重启 noctalia | `systemctl --user restart dms.service` | ◐（DMS 取代 noctalia） |
| `Mod+P` | 关闭内置屏 `eDP-1` | `niri msg output eDP-1 off` | ✅（输出名需实机核对） |
| `Mod+Alt+P` | 打开内置屏 `eDP-1` | `niri msg output eDP-1 on` | ✅（输出名需实机核对） |
| `Mod+Alt+W` | repo：`waypaper` | DMS `dash toggle wallpaper` | ◐（统一到 DMS） |
| `Mod+Alt+S` | 切换 orca 屏幕阅读器 | `pkill orca || exec orca` | ✅ |
| `Super+Alt+L` | repo：`swaylock` 锁屏 | 未保留该组合；`Alt+L` 仍锁屏 | ❌（`Mod+Alt+L` 已用于 monitor-right） |
| `Mod+Shift+P` | dotfiles：关闭显示器；repo：重启 waybar | `power-off-monitors` | ⚠（采用 dotfiles；niri 不使用 Waybar） |

## 窗口、列、工作区和显示器

| 旧键位 | 旧语义 | 新实现 | 等价 |
| --- | --- | --- | --- |
| `Mod+Q` | 关闭窗口 | 同左 | ✅ |
| `Mod+Left/Down/Up/Right` | 焦点 左/下/上/右 | 同左 | ✅ |
| `Mod+H/J/K/L` | 焦点 左/下/上/右 | 同左 | ✅ |
| `Mod+Shift+Left/Down/Up/Right` | 移动列/窗口 | 同左 | ✅ |
| `Mod+Shift+H/J/K/L` | 移动列/窗口 | 同左 | ✅ |
| `Mod+Home/End` | 首/末列 | 同左 | ✅ |
| `Mod+Ctrl+Home/End` | 列移到首/末 | 同左 | ✅ |
| `Mod+Alt+Left/Down/Up/Right` | 焦点显示器 | 同左 | ✅ |
| `Mod+Alt+H/J/K/L` | 焦点显示器 | 同左 | ✅ |
| `Mod+Shift+Ctrl+Left/Down/Up/Right` | 列移到显示器 | 同左 | ✅ |
| `Mod+Shift+Ctrl+H/J/K/L` | 列移到显示器 | 同左 | ✅ |
| `Mod+Page_Down/Page_Up` | 焦点工作区 下/上 | 同左 | ✅ |
| `Mod+N` / `Mod+U` | 焦点工作区 下/上 | 同左 | ✅ |
| `Mod+Ctrl+Page_Down/Page_Up` | 列移到工作区 下/上 | 同左 | ✅ |
| `Mod+Ctrl+Down/Up` | 列移到工作区 下/上 | 同左 | ✅ |
| `Mod+Shift+N` / `Mod+Shift+U` | 列移到工作区 下/上 | 同左 | ✅ |
| `Mod+Shift+Page_Down/Page_Up` | 移动工作区 下/上 | 同左 | ✅ |
| `Mod+Ctrl+U` / `Mod+Ctrl+I` | 移动工作区 下/上 | 同左 | ✅ |
| `Mod+WheelScrollDown/Up` | 工作区 下/上 | 同左 | ✅ |
| `Mod+Ctrl+WheelScrollDown/Up` | 列移到工作区 | 同左 | ✅ |
| `Mod+WheelScrollRight/Left` | 列 右/左 | 同左 | ✅ |
| `Mod+Ctrl+WheelScrollRight/Left` | 移动列 右/左 | 同左 | ✅ |
| `Mod+Shift+WheelScrollDown/Up` | 列 右/左 | 同左 | ✅ |
| `Mod+Ctrl+Shift+WheelScrollDown/Up` | 移动列 右/左 | 同左 | ✅ |
| `Mod+1` … `Mod+9` | 焦点到工作区 1–9 | 同左 | ✅ |
| `Mod+Shift+1` … `Mod+Shift+9` | 列移到工作区 1–9 | 同左 | ✅ |
| `Mod+BracketLeft/Right` | consume/expel 窗口 | 同左 | ✅ |
| `Mod+Comma/Period` | 合并/拆分列 | 同左 | ✅ |
| `Mod+R` | 预设列宽 | 同左 | ✅ |
| `Mod+Shift+R` | 预设窗口高度（dotfiles 注释掉，repo 启用） | 同左 | ✅（保留 repo 行为） |
| `Mod+Ctrl+R` | 重置窗口高度 | 同左 | ✅ |
| `Mod+F` | 最大化列 | 同左 | ✅ |
| `Mod+Shift+F` | 全屏窗口 | 同左 | ✅ |
| `Mod+Ctrl+F` | 扩展到可用宽度 | 同左 | ✅ |
| `Mod+C` | 居中列 | 同左 | ✅ |
| `Mod+Ctrl+C` | 居中所有可见列 | 同左 | ✅ |
| `Mod+Minus/Equal` | 列宽 −/+10% | 同左 | ✅ |
| `Mod+Shift+Minus/Equal` | 窗口高度 −/+10% | 同左 | ✅ |
| `Mod+V` | 切换浮动 | 同左 | ✅ |
| `Alt+V` | 浮动/平铺焦点切换 | 同左 | ✅ |
| `Mod+W` | tabbed 列 | 同左 | ✅ |

## 截图、媒体和亮度

| 旧键位 | 旧语义 | 新实现 | 等价 |
| --- | --- | --- | --- |
| `Ctrl+Q` | 截图 | 同左 | ✅ |
| `Print` | dotfiles：截图 | `screenshot` | ✅ |
| `Ctrl+Print` | 全屏截图 | 同左 | ✅ |
| `Alt+Print` | 窗口截图 | 同左 | ✅ |
| `XF86AudioRaiseVolume` / `LowerVolume` | DMS audio ±3 | `wpctl set-volume` ±10% | ◐ |
| `XF86AudioMute` | DMS mute | `wpctl set-mute` | ◐ |
| `XF86AudioMicMute` | DMS mic mute | `wpctl` source mute | ◐ |
| `XF86AudioPlay` / `Pause` | DMS mpris play/pause | `playerctl play-pause` | ◐ |
| `XF86AudioStop` | DMS mpris stop | `playerctl stop` | ◐ |
| `XF86AudioPrev` / `Next` | DMS mpris | `playerctl previous/next` | ◐ |
| `Ctrl+XF86AudioRaiseVolume` / `LowerVolume` | DMS mpris volume | `playerctl volume 0.05±` | ◐ |
| `XF86MonBrightnessUp/Down` | DMS brightness ±5 | `brightnessctl` ±10% | ◐ |
| `XF86AudioPause` | dotfiles 的 mpris 暂停 | 已新增，`playerctl play-pause` | ✅ |
| `Alt+Tab` / `Alt+Shift+Tab` | dotfiles 最近窗口 | `recent-windows` 块 | ✅ |
| `Alt+grave` / `Alt+Shift+grave` | dotfiles 按 app-id 切换 | `recent-windows` 块 | ✅ |

## 有意删除或改变的内容

- 旧 dotfiles 的 `spawn-at-startup fcitx5/clipse/nm-applet/cliphist` 不再复制：
  Fcitx5 改由 systemd user service 启动；剪贴板使用 DMS；NetworkManager 自带
  网络状态，不需要 `nm-applet` 才可联网。
- 旧 dotfiles 的 `environment { XDG_CURRENT_DESKTOP "niri"; }` 由 niri session
  自身设置；不再在 KDL 中重复。
- 旧配置中的 `workspace "work"`、`"web"`、`"note"` 已保留为命名工作区。
- `Mod+Shift+V` 的两种旧含义无法同时成立：本表按更完整的旧 dotfiles 选择
  `switch-focus-between-floating-and-tiling`；DMS 剪贴板保留在 `Mod+Alt+V`。
- `Super+Alt+L` 与 `Mod+Alt+L` 的 monitor-right 冲突，未保留；锁屏仍可用
  `Alt+L`。
- 所有输出切换绑定默认写死 `eDP-1`，来自旧 repo；实际机器若是别的输出名，需要
  按 `niri msg outputs` 修改。
