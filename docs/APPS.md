# 主力机应用与默认打开方式

本文记录 `main` 上新增的桌面应用、`nixos` 小主机的边界，以及不依赖 GUI 的
配置/构建验证。未在真实图形会话中执行的交互项目会明确标为“待实机验证”。

## 1. 作用域

| 内容 | main | nixos（小主机） |
| --- | --- | --- |
| Obsidian、腾讯会议、QQ、微信、ONLYOFFICE | 安装 | 不安装 |
| OBS Studio（含 PipeWire 屏幕捕获） | 安装 | 不安装 |
| Helix 默认编辑器 | 是 | 是，共享同一 Home Manager 模块 |
| Firefox 打开 PDF/图片/MP4/WebM | 默认 | 保持原设置 |
| Nautilus 打开目录、Firefox 打开 HTTP(S) | 是 | 是 |

应用模块是 `home/calendar/apps.nix`，只在
`networking.hostName == "main"` 时生效。小主机继续使用 DMS、Sway 和原有终端
外观，不会因为共享 Home Manager 而多出 Office、会议、聊天或 OBS。

## 2. 包来源与用途

全部来自当前锁定的 nixpkgs：

| 应用 | 包 | 用途 |
| --- | --- | --- |
| Obsidian | `pkgs.obsidian` | Markdown 知识库/vault |
| 腾讯会议 | `pkgs.wemeet` | 音视频会议 |
| QQ | `pkgs.qq` | 聊天 |
| 微信 | `pkgs.wechat` | 官方 Linux 客户端 |
| ONLYOFFICE | `pkgs.onlyoffice-desktopeditors` | DOCX/XLSX/PPTX、ODF |
| OBS Studio | Home Manager `programs.obs-studio` | 偶尔录屏，不配置直播 |

OBS 使用 Home Manager 模块安装 wrapped 包，`plugins = []`。不要额外把
`pkgs.obs-studio` 加进 `home.packages`，否则会出现第二套未包装入口。OBS 通过
现有 PipeWire/WirePlumber 和桌面 Portal 工作；没有新开 PulseAudio 服务，也没有
启用虚拟摄像头、背景移除或直播扩展。

QQ、Obsidian、腾讯会议继续使用各自包内的 Wayland/输入法 wrapper。没有全局设置
`QT_QPA_PLATFORM=xcb`、`GDK_BACKEND` 或 `QT_SCALE_FACTOR`。ONLYOFFICE 当前包
固定使用 XWayland（包内设置 `QT_QPA_PLATFORM=xcb`），保留其打包方式。

## 3. ONLYOFFICE 字体

`onlyoffice-desktopeditors.override` 只增加：

- `liberation_ttf`
- `carlito`
- `noto-fonts-cjk-serif`

包本身已包含 Noto CJK Sans。没有下载或打包来源不明的微软字体。这样能改善常见
DOCX/PPTX 的中文和西文字体回退，但不承诺与 Microsoft Office 完全一致。中文
输入、缩放和具体文档排版仍需实机检查。

## 4. 默认打开方式

`xdg.mimeApps.defaultApplications` 在 main 上增加：

| 类型 | desktop ID |
| --- | --- |
| PDF | `firefox.desktop` |
| PNG/JPEG/WebP/GIF/SVG | `firefox.desktop` |
| `video/mp4`、`video/webm` | `firefox.desktop` |
| DOC/DOCX/XLS/XLSX/PPT/PPTX | `onlyoffice-desktopeditors.desktop` |
| ODT/ODS/ODP | `onlyoffice-desktopeditors.desktop` |
| `x-scheme-handler/obsidian` | `md.obsidian.Obsidian.desktop` |

没有设置 `video/*` 通配符，也没有把 HTTP(S) 或目录从 Firefox/Nautilus 手里拿走。
构建后核对过实际 desktop 文件：

```text
obsidian .../share/applications/md.obsidian.Obsidian.desktop
onlyoffice .../share/applications/onlyoffice-desktopeditors.desktop
```

可用无打开文档的检查确认分派：

```bash
xdg-mime query default application/pdf
xdg-mime query default image/png
xdg-mime query default video/mp4
xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document
xdg-mime query default x-scheme-handler/obsidian
```

## 5. OBS 录屏建议

第一次启动后：

1. 在“来源”中添加“屏幕采集（PipeWire）”，选择屏幕或窗口。
2. 添加“音频输入采集”选择麦克风；添加“音频输出采集”选择桌面音频。
3. 输出分辨率优先使用屏幕原分辨率，帧率 30fps；有 AMD 硬件编码时选择
   `H.264/AVC (AMD)` 或 OBS 显示的 VAAPI 选项。
4. 录制格式选 MKV。MKV 在异常退出时更容易恢复；录完后用 OBS 的
   “文件 -> 重新封装录像”转换为 H.264/AAC 的 MP4，再用 Firefox 回放。
5. 默认目录为 `~/Videos/Recordings`。该目录只由激活脚本在缺失时创建，不移动或
   覆盖已有录像。

OBS 的 profile/scene 和 `obs-studio` 用户数据保持可写；没有把整个配置目录链接到
只读 store，也没有依赖未经验证的 INI 字段强写现有配置。

如果用户主动授权且图形环境可用，可录制约一分钟带麦克风和系统声音的测试，再用
Firefox 打开 remux 后的 MP4。该测试会接触真实屏幕和音频，本轮未自动执行，标为
“待实机验证”。

## 6. 编辑器入口

默认编辑器是 Helix：

```bash
hx --version
hx --health
```

Fish 的 `n`、Git 的 `core.editor`、`EDITOR`/`VISUAL` 都指向 `hx`。语言服务器和
格式化入口的已验证状态见 `docs/DESKTOP.md` 的编辑器一节。Neovim 的旧运行时目录
（`~/.local/share/nvim`、`~/.local/state/nvim`、用户自己的 `~/.config/nvim`）没有
被删除。

## 7. 待实机验证

- QQ/微信/Obsidian/腾讯会议/ONLYOFFICE 的中文输入、HiDPI 缩放、打开和收发文件。
- 腾讯会议音视频和双向屏幕共享。
- OBS 一分钟带声音录屏、MKV remux 和 Firefox 回放。
- ONLYOFFICE 常用 DOCX/PPTX 的字体排版和中文输入。

这些项目需要用户账号、图形会话或真实音视频设备，不能在当前 agent 会话中代替
用户执行。
