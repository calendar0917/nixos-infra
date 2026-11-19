# 应用兼容与默认打开方式

main 额外安装 Obsidian、腾讯会议、QQ、微信、ONLYOFFICE、OBS Studio、Super
Productivity 和 Mark Shot；DS Bot 作为手工下载的 AppImage 提供桌面入口。小主机
不安装这些应用。应用模块是 `home/calendar/apps.nix`，只在
`networking.hostName == "main"` 时生效；Mark Shot 及其入口在
`home/calendar/desktop/screenshot.nix`。包、桌面项和交互效果仍以实机图形会话为准。

## 1. 兼容约定

- QQ、Obsidian、腾讯会议继续使用各自包内的 Wayland/输入法 wrapper；不要全局设置
  `QT_QPA_PLATFORM=xcb`、`GDK_BACKEND` 或 `QT_SCALE_FACTOR`。
- ONLYOFFICE 当前包固定使用 XWayland（`QT_QPA_PLATFORM=xcb`），保留打包方式。
  它额外带入 Liberation、Carlito 和 Noto CJK Serif 字体，用于改善 DOCX/PPTX
  的中文/西文回退；这不等于与 Microsoft Office 完全一致。
- OBS 使用 Home Manager 的 wrapped 包，`plugins = []`。不要把
  `pkgs.obs-studio` 再加进 `home.packages`，否则会出现第二套未包装入口。
- OBS 走现有 PipeWire/WirePlumber 和桌面 Portal；没有新增 PulseAudio 服务，也
  没有启用虚拟摄像头、背景移除或直播扩展。
- `modules/base.nix` 在两台主机上都安装 `appimage-run`，用于临时试跑尚未打包的
  AppImage。仓库里已固定的应用（如 Mark Shot）仍用
  `pkgs.appimageTools.wrapType2` 生成声明式入口，不要改成每次手跑
  `appimage-run`。
- 手工下载、随时会被换掉的 AppImage 走 `appimage-run` 的直接入口，不要为了它
  虚构一个版本号和 SHA256 去用 `wrapType2`。见下一节。

这些应用的输入法、HiDPI、文件打开和音视频能力都需要用户账号与图形设备，未在
agent 会话中实际点击验证。

## 1.1 手工维护的 AppImage（DS Bot）

`appimage-run` 是在终端里跑 AppImage 的前台程序：它占着那个终端直到应用退出，
关掉终端应用也会跟着结束。桌面启动器不需要终端，所以 DS Bot 同时有两种入口，
都由 `home/calendar/apps.nix` 生成：

| 入口 | 用途 |
| --- | --- |
| `ds-bot`（PATH 中的命令） | 在终端里启动后立刻拿回提示符 |
| `ds-bot.desktop`（fuzzel 里搜 “DS Bot”） | 图形启动，不产生终端窗口 |

两者都指向同一个包装器，行为差别只在谁来 fork：

- 包装器用 `setsid -f` 把 `appimage-run` 放到新会话里。它 2 ms 内返回，应用
  继续在后台运行，并且不再挂在调用者的控制终端上，关掉终端不会连带结束应用。
- desktop 条目用 `Terminal=false`，启动器直接执行程序，本来就没有终端可占。条目
  里的 `StartupWMClass=dsbot` 是 Electron 报告的实际 `app_id`，Waybar 和 niri
  据此把窗口和条目归到一起。
- 图标放在 `config/icons/dsbot.png`，安装到
  `~/.local/share/icons/hicolor/256x256/apps/dsbot.png`，条目按主题名
  `Icon=dsbot` 引用；不要把 Nix store 绝对路径写进 `Icon`。

镜像路径默认是 `~/appimage/DS-Bot.AppImage`，可以用 `DS_BOT_APPIMAGE` 覆盖。更新
版本时直接替换该文件即可，仓库里没有版本号或哈希需要同步。文件不存在时包装器
会报错退出，而不是静默启动一个空白窗口。

AppImage 由 `appimage-run` 解包到 `~/.cache/appimage-run/<hash>/` 后再执行；换掉
AppImage 会生成新的缓存目录，旧目录不会自动清理。

## 2. 默认打开方式

main 的 `xdg.mimeApps.defaultApplications` 增加：

| 类型 | desktop ID |
| --- | --- |
| PDF | `firefox.desktop` |
| PNG/JPEG/WebP/GIF/SVG | `firefox.desktop` |
| `video/mp4`、`video/webm` | `firefox.desktop` |
| DOC/DOCX/XLS/XLSX/PPT/PPTX | `onlyoffice-desktopeditors.desktop` |
| ODT/ODS/ODP | `onlyoffice-desktopeditors.desktop` |
| `x-scheme-handler/obsidian` | `md.obsidian.Obsidian.desktop` |
| `x-scheme-handler/superproductivity` | `superproductivity.desktop` |

没有设置 `video/*` 通配符，也没有接管 HTTP(S) 或目录的默认处理。目录仍由
Nautilus 打开，HTTP(S) 仍由 Firefox 打开。`Mod+E` 现在只是在 main 打开
`kitty -e yazi`，不改变这张 MIME 表，也没有把 `inode/directory` 从
`org.gnome.Nautilus.desktop` 拿走；`xdg-open` 和 XDG 文件选择器都没有被包装。
因此浏览器、ONLYOFFICE、Obsidian 等 GUI 程序打开文件夹时仍调用 Nautilus。
Yazi 的日常快捷键见 [`DESKTOP.md`](DESKTOP.md)。

可用只读查询核对：

```bash
xdg-mime query default application/pdf
xdg-mime query default image/png
xdg-mime query default video/mp4
xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document
xdg-mime query default x-scheme-handler/obsidian
xdg-mime query default x-scheme-handler/superproductivity
```

## 3. Super Productivity（仅 main）

Super Productivity 由固定 nixpkgs commit 中的 `pkgs.super-productivity`（19.3.1）
提供，只加进 main 的 `home.packages`；小主机 `nixos` 不安装。没有 overlay、
AppImage、Flatpak、自定义 wrapper 或系统服务。`xdg-utils` 同时加入 main，保证 Niri
快捷键里的 `xdg-open` 在用户 PATH 上。

启动方式：

```bash
super-productivity                                  # 直接启动
xdg-open 'superproductivity://add-task'             # 新建任务输入框
xdg-open 'superproductivity://toggle-visibility'    # 显示/隐藏主窗口
```

URL Scheme `x-scheme-handler/superproductivity` 的默认 handler 是
`superproductivity.desktop`，因此 Niri 的 `Mod+A`（新建任务）只需调用
`xdg-open`，不另外写 shell 脚本。`Mod+S` 现在打开系统控制中心，不再绑定
Super Productivity 的显示/隐藏；应用和 URL Scheme 都保留。快捷键见
[`DESKTOP.md`](DESKTOP.md)。

应用偏好、任务和账户数据留在可写的 `~/.config/superProductivity/`，由用户在 GUI
内管理；不要把它做成只读的 Nix Store 链接，也不要在仓库里声明任务数据。本次没有
配置开机自启、后台常驻、手机同步、WebDAV、SuperSync 或 CalDAV。

应用的首次启动、URL Scheme 跳转和窗口显示/隐藏都依赖真实图形会话，未在 agent
会话中执行，均为待实机验证。

## 4. OBS 录屏

第一次启动后：

1. 在“来源”中添加“屏幕采集（PipeWire）”，选择屏幕或窗口。
2. 添加“音频输入采集”选择麦克风；添加“音频输出采集”选择桌面音频。
3. 输出分辨率优先使用屏幕原分辨率，帧率 30fps；有 AMD 硬件编码时选择
   `H.264/AVC (AMD)` 或 OBS 显示的 VAAPI 选项。
4. 录制格式选 MKV。异常退出时 MKV 更容易恢复；录完后用 OBS 的
   “文件 -> 重新封装录像”转换为 H.264/AAC 的 MP4，再用 Firefox 回放。
5. 默认目录为 `~/Videos/Recordings`。激活脚本只在目录缺失时创建，不移动或覆盖
   已有录像。

OBS 的 profile/scene 和用户数据保持可写；没有把整个配置目录链接到只读 store。
完整测试需要真实屏幕、麦克风和系统声音，由用户主动执行一分钟录屏、MKV remux
和 Firefox 回放。

## 5. Mark Shot 截图（仅 main）

Mark Shot 使用 GitHub Release v0.2.0 的 Linux x86_64 AppImage，经
`pkgs.appimageTools.wrapType2` 包装，SHA256 固定为
`b85f67274916b4a1636c3a3e1a9797a6393eff3b6f84c0ba17b31ed9c3469981`。没有使用
`curl | sh`、Cargo 安装、Flatpak 或移动分支 Flake，也没有为了它升级 nixpkgs。

统一入口由 `desktop-shot` 提供：`capture` 区域截图/标注，`scroll` 滚动长截图，
`pin` 贴剪贴板；对应 niri/Sway 快捷键为 `Ctrl+Q`、`Ctrl+Shift+Q`、`Ctrl+Alt+Q`。
截图保存到 `~/Pictures/Screenshots`，并用 Mark Shot 的 `--output`/`-t cs` 完成
保存和复制。`Print` 仍是原生截图备用。没有启动托盘、内置全局快捷键服务、
上传或第三方 OCR；Mark Shot 的配置、历史和截图目录保持用户可写。

标注、滚动长截图、贴图、与 Yazi `c i`/`c t` 的配合，以及 `Print`/Nautilus 的边界，
见 [`DESKTOP.md`](DESKTOP.md)。截图、标注、滚动拼接和贴图都需要真实图形会话，
未在 agent 会话中实际点击验证。
