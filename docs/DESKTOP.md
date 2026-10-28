# 桌面组件与故障入口

本文说明桌面组件如何协作、哪些文件有特殊约定，以及出问题时先看哪里。仓库中的
配置能否构建不等于当前图形会话已经应用；GUI 行为未实际执行时写“待实机验证”。

## 1. 作用域

| 范围 | main | nixos |
| --- | --- | --- |
| niri 会话 | `config/niri/config.kdl` | `config/niri/config-dms.kdl` |
| 面板/通知/壁纸生命周期 | `home/calendar/desktop/shell.nix` + Waybar | DMS 自己的 unit |
| 电源菜单、锁屏等待、swayidle | `home/calendar/desktop/power.nix`、`lib.nix`、`lock.nix` | 不启用 |
| Sway 备用会话 | `config/sway/` + Mako/Waybar | 同样保留 |
| nwg-displays 补丁 | `hosts/main/nwg-displays.nix` + `patches/` | 使用原包 |

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
- Sway 仍读取自己的 `config/sway/config`、Waybar 配置和 Mako，不加载 niri 样式。

### 滚轮、亮度与电源

- `niri/workspaces` 启用原生 `enable-bar-scroll`；栏的普通区域上滚/下滚切换工作区，
  niri 在首尾停止、不循环。音量与亮度模块自身也会截获滚轮，因此它们的
  `on-scroll-*` 被显式映射到同一 niri 动作，避免一次滚动同时改音量/亮度并切工作区。
  音量仍用媒体键或点击打开 `pavucontrol`。
- 亮度标签使用原生 `backlight`，点击展开 group 内的原生 `backlight/slider`，最小
  5%；滑条保留拖动和点击交互。固定 Waybar 构建已开启 `-Dlogin-proxy=true`，否则
  滑条只能读不能写。内屏设备由实机只读探测为 `amdgpu_bl1`；按键仍由
  `brightnessctl` 按实际最大值计算 5% 下限。
- 仅 main 启用 `services.power-profiles-daemon`，Waybar 使用原生模块；左键循环
  实际可用档位，tooltip 显示名称与驱动。首次是 `balanced`，之后由 PPD 保存手动
  选择，登录/插拔电源不强制覆盖。
- 电池模块每 10 秒读取原生 `{power}`，只在放电格式显示电池侧功率；充电、插电、
  满电使用文字状态，不把充电功率标成整机耗电。`power_now` 不可用的硬件不应照搬
  该字段。

同亮度、同负载比较档位时，分别用同一命令/构建在放电状态运行，记录
`powerprofilesctl get`、Waybar 电池功率和 `time` 结果并重复一次。读数是电池侧
功率，不是墙插整机功率。全栏滚动、滑条拖动、托盘滚动传播、档位切换和放电功率
仍需应用 generation 后实机验收。

## 3. `monitor.kdl` 与 nwg-displays

`config/niri/config.kdl` 只读，并 `include "monitor.kdl"`。Home Manager 只在
`~/.config/niri/monitor.kdl` **缺失**时创建一个普通可写空文件；已有布局不被覆盖。
nwg-displays 需要写这个文件，所以不能把它改成 store 软链，也不能为了 GUI 写回而
把整个 `config.kdl` 变成可写。

- `Mod+P` 打开补丁后的 nwg-displays；`Mod+Alt+P` 强制打开内屏 `eDP-1`。
- 补丁处理 niri 禁用输出：有 modes 的输出仍可重新启用，没有 modes 的异常输出
  跳过并记录，不拖垮正常输出。
- 实机先只读核对：

  ```bash
  niri msg -j outputs | jq
  ```

- 修改补丁或包时，运行针对性包构建；nwg 回归已挂在包的 `checkPhase`，不需要每次
  桌面样式检查都重跑：

  ```bash
  nix build --no-link .#nixosConfigurations.main.pkgs.nwg-displays
  ```

若故障不是 `current_mode`/`logical` 为 null，保留补丁并记录真实 stderr，不要把
假设写成诊断结论。

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

main 使用完整 `Catppuccin-Mocha` 主题文件，背景半透明、文字保持不透明；
nixos 保持原终端外观。niri 额外有一条只匹配 `app-id="^kitty$"` 的
`window-rule`，关闭焦点底板的实色背景；焦点边框和主题继续保留。

如果新窗口仍像不透明，先确认运行的是包含该规则的配置，并检查顶部条是否其实是
niri 的 tabbed-column 指示器。不要用全局窗口 opacity 或焦点切换脚本替代。
最终视觉效果待实机验证。

### Helix

`hx` 是两台主机的默认编辑器。配置是
`~/.config/helix/config.toml`，属于 TOML；**不要用 jq 读取**。需要解析时使用
Python `tomllib` 或 TOML 工具。主题只清空 `ui.background`，让 kitty 背景透出，
状态栏、选区和诊断仍用 Catppuccin。

语言服务器由 Home Manager 的 `extraPackages` 提供；`hx --health` 可检查入口，
但启动 `hx` 不等于 LSP 已完成补全/诊断。旧 Neovim 运行时目录不由本仓库管理，
也不因默认编辑器改为 Helix 而删除。

### 蓝牙

main 启用 BlueZ（开机上电）和 Blueman；Waybar 使用原生 `bluetooth` 模块，不在
后台每秒执行 `bluetoothctl`。左键打开 `blueman-manager`，设备详情放 tooltip。
无适配器时显示 no-controller 状态，不应导致 Waybar 崩溃。不要新增第二个 applet。

## 6. 检查与故障入口

- 只改文档：检查本地链接和 `git diff --check`，不构建系统。
- 桌面/Home Manager 改动：从 [`README.md`](../README.md) 的维护入口运行
  `scripts/check-desktop`；该脚本只做构建和无 GUI 回归，不激活 generation。
- niri 配置改动：临时复制 `config.kdl`，创建临时空 `monitor.kdl`，再执行
  `niri validate -c <临时配置>`；不要覆盖用户布局。
- 会话故障：先看 `systemctl --user --failed`、waybar/swayidle/锁屏 unit 的
  journal，以及 `niri msg -j outputs` / `niri msg -j workspaces`。
- 看不清桌面时用 TTY 或 Sway 备用会话恢复，具体步骤见
  [`RECOVERY.md`](RECOVERY.md)。

真实验收只保留简短方法：应用新 generation 并重新登录后，检查 Waybar 单元、
`Alt+L` 与菜单“锁屏”、挂起前 `LockedHint=yes`、kitty 焦点透明度，以及
nwg-displays 能否写回 `monitor.kdl`。这些操作由用户主动执行；未实际执行的项目
写“待实机验证”。
