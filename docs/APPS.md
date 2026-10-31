# 应用兼容与默认打开方式

main 额外安装 Obsidian、腾讯会议、QQ、微信、ONLYOFFICE、OBS Studio 和 Super
Productivity；小主机不安装这些应用。应用模块是 `home/calendar/apps.nix`，只在
`networking.hostName == "main"` 时生效。包、桌面项和交互效果仍以实机图形会话为准。

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

这些应用的输入法、HiDPI、文件打开和音视频能力都需要用户账号与图形设备，未在
agent 会话中实际点击验证。

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
Nautilus 打开，HTTP(S) 仍由 Firefox 打开。可用只读查询核对：

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
`superproductivity.desktop`，因此 Niri 的 `Mod+A`（新建任务）与 `Mod+S`
（显示/隐藏）只需调用 `xdg-open`，不另外写 shell 脚本。两个快捷键见
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
