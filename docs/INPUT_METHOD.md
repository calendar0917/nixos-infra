# 输入法：可重建与手工补全

fcitx5 + Rime + Pinyin + vinput 语音这套，仓库能声明一部分，另一部分只在用
户目录里。重装或换机器时，前者 `nixos-rebuild switch` 自动回来，后者必须按本
页手工补。范围只到输入法和候选框外观，不涉及 Rime 词库的具体内容。

## 1. 重装能自动回来的

| 内容 | 位置 | 机制 |
|---|---|---|
| fcitx5、chinese-addons、rime、gtk 前端 | `modules/desktop/common.nix` 的 `i18n.inputMethod.fcitx5` | nix store |
| Rime Ice 数据（`rime-data` + `rime-ice`） | 同上 `fcitx5-rime.override` | nix store |
| Rime 的 `default.custom.yaml` 补丁 | `home/calendar/default.nix` 的 `home.file` | Home Manager 只读链接 |
| 输入法组顺序（us、rime、pinyin，默认 rime） | 同上 `xdg.configFile."fcitx5/profile"` | Home Manager 只读链接 |
| vinput addon（全局语音输入） | `flake.nix` 的 main 模块 `addons = [ vinput ]` | nix store |
| `vinput`、`vinput-gui` 命令行与界面 | 同上 `environment.systemPackages` | nix store |
| `vinput-daemon` 用户服务 | 同上 `systemd.user.services.vinput-daemon` | 生成到系统 user unit，`default.target` 拉活 |
| vinput 手柄/遥控器 udev 规则 | 同上 `services.udev.packages` | nix store |
| fcitx5 的启动方式（systemd 用户服务、屏蔽 autostart） | `common.nix` 的 `systemd.user.services.fcitx5` + `default.nix` 的 autostart 占位 | 声明式 |
| 候选框主题（Catppuccin glass、tokyonight、fluent、nord） | `common.nix` 的 `fcitx5ThemeCatppuccinGlass` 派生与 `environment.systemPackages` | nix store |
| 候选框字号与内边距 | 同上派生里的 `sed`（Font 11/10、文字 10/4、背景 8） | 重建即一致 |
| 主题可见性 `pathsToLink = [ "/share/fcitx5" ]` | `common.nix` 末尾 | 少这行 configtool 主题下拉为空 |
| Noto Sans CJK / Emoji 字体 | `common.nix` 的 `fonts.packages` 与 `fontconfig.defaultFonts` | 声明式 |

验收：`ls /run/current-system/sw/share/fcitx5/themes | wc -l` 应为 67；
`systemctl --user is-enabled vinput-daemon` 应为 `enabled`。

## 2. 必须手工补的

### 2.1 ASR 模型（约 630 MB，最费时）

模型是下载物，不在仓库也不在 Nix store，放在
`~/.local/share/vinput/models/sherpa-onnx/`。当前这台机器上有三个：

| 模型 | 大小 | 说明 |
|---|---|---|
| `onnx-xasr-zh-en-punct-int8-off` | 168 M | X-ASR，中英+标点+大小写，支持热词，当前活跃 |
| `sense-voice-zh-en-ja-ko-yue-int8` | 233 M | SenseVoice 2025 构建，已装未启用 |
| `sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` | 229 M | 旧 SenseVoice，回退用 |

重装后补最少的一套：

```bash
vinput model add onnx-xasr-zh-en-punct-int8-off
vinput model use onnx-xasr-zh-en-punct-int8-off
systemctl --user restart vinput-daemon
```

registry 自带国内镜像，GitHub 下不动会自己换；下载中断就重跑，`vinput model
list` 里显示「已安装」再 `use`。要连旧 SenseVoice 一起装就再加
`vinput model add onnx-sv-zh-int8-off`。

回退到旧 SenseVoice：

```bash
vinput model use model.sherpa-onnx.sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
systemctl --user restart vinput-daemon
```

确认加载：`journalctl --user -u vinput-daemon -n 30` 里应出现
`sherpa-onnx offline ASR initialized`，`vinput model list` 里活跃模型带
`[*] 活跃`。

### 2.2 vinput 的 `config.json`

`~/.config/vinput/config.json`（0600）由 daemon 和 `vinput-gui` 自己写，仓库
不生成。`vinput model use` 会把它里面的 `asr.providers[0].model` 改成对应
ID，所以 2.1 做完这一项基本就对了。其余是默认值（VAD 阈值 0.35、静音 1.2 s、
`input_gain=1`），一般不用抄。要保留热词，注意里面 `hotwords_file` 是绝对路
径 `/home/calendar/.config/vinput/hotwords.txt`，换用户名要跟着改。

### 2.3 候选框的 `classicui.conf`

`~/.config/fcitx5/conf/classicui.conf` 是**可写**文件，故意没纳入 Home
Manager，这样用户能在 `fcitx5-configtool` →「外观」里直接换主题。重装后如果
没有这份文件，fcitx5 会退回 `default` 主题，候选框就是你嫌丑的那种。六行要
一致：

```ini
Font="Noto Sans CJK SC 11"
MenuFont="Noto Sans CJK SC 10"
TrayFont="Noto Sans CJK SC Bold 10"
Theme=catppuccin-latte-blue
DarkTheme=catppuccin-mocha-glass
UseDarkTheme=True
```

改完 `fcitx5 -r`。想整体再小一档：`Font` 改 10、`MenuFont` 改 9，同时把
`common.nix` 里 glass 派生的 Font/内边距一起改（两处必须一致，否则主题和
面板行为对不上）。想回默认主题：`Theme=default`、`DarkTheme=default-dark`。

### 2.4 组内轮换键

`~/.config/fcitx5/config` 同属可写文件。`Super+space` 在组内轮换、往回用
`Shift+Super+space`，靠这四段：

```ini
[Hotkey/EnumerateForwardKeys]
0=Super+space

[Hotkey/EnumerateBackwardKeys]
0=Shift+Super+space

[Hotkey/EnumerateGroupForwardKeys]
0=

[Hotkey/EnumerateGroupBackwardKeys]
0=
```

后两段置空是为了避开 niri 和 fcitx5 默认的组切换键。`TriggerKeys=Ctrl+space`
保持默认不动。写完 `fcitx5 -r`。

### 2.5 热词

`~/.config/vinput/hotwords.txt`，一行一个词，改完
`systemctl --user restart vinput-daemon`。规则有个坑：

- **中文必须一个字一个空格**：写 `现在时` 会报
  `Cannot find ID for token 在时`，必须写 `现 在 时`。
- 英文直接写，`NixOS` 没问题。
- 自查：`journalctl --user -u vinput-daemon -n 30 | grep 'Cannot find ID'`
  无输出即编码成功。

只有 X-ASR 支持热词（`vinput model list` 里「热词=是」），SenseVoice 会自动
忽略、不报错。编码成功不等于一定偏置成功，这个模型偏置偏弱，真实效果要靠念
一句确认。

### 2.6 语音触发键和其余面板设置

`~/.config/fcitx5/conf/vinput.conf` 由 addon 在首次加载时生成，默认触发键
`Alt_R`、命令键 `Control_R`。用户从 GUI 改过的值都在这两个文件里，重装后按
需重设。

### 2.7 Rime 用户词库

`~/.local/share/fcitx5/rime/*.userdb` 和 `build/` 是学习数据（现在约 74 M），
重装即从零开始。要保就自己备份整个目录，不要在仓库里固化。

## 3. 从干净机器的顺序

1. 拉仓库，确认输入法相关提交在 `main` 上（`git log --oneline -- flake.nix
   modules/desktop/common.nix` 能看到 vinput/主题那次提交）。
2. `sudo nixos-rebuild switch --flake /home/calendar/nixos-infra#main`。
3. 登录后或 `systemctl --user daemon-reload` 后确认：
   `systemctl --user status vinput-daemon` 为 active、`fcitx5-remote -n` 为
   `rime`、主题目录 67 个。
4. 补模型（2.1），`vinput model use`，重启 daemon。
5. 写回 `classicui.conf` 六行（2.3）。
6. 写回 `~/.config/fcitx5/config` 的四段（2.4）。
7. 需要热词就补 `hotwords.txt`（2.5）再重启 daemon。
8. `fcitx5 -r` 或重新登录；Rime 词库从零开始。
9. 按新硬件重设麦克风默认输入源（见第 5 节）。

## 4. 升级与回退

- 升级 vinput：`nix flake update fcitx5-vinput` 后 `nixos-rebuild switch`，
  再 `systemctl --user restart vinput-daemon` 与 `fcitx5 -r`。升级后模型仍
  在用户目录，不用重下。
- 回退主题：`classicui.conf` 改成 `Theme=default` / `DarkTheme=default-dark`，
  `fcitx5 -r`；或换 `DarkTheme=catppuccin-mocha-blue` 去掉透明。
- 回退语音模型：见 2.1 的回退命令，旧模型别删。

## 5. 永远手工、不可复现的

- **麦克风默认输入源**：PipeWire 的默认源跟硬件走，重装后必然重置。用
  `wpctl status` 看默认 `Source`，在 `pavucontrol` →「输入设备」里选对，或
  `wpctl set-default <id>`。蓝牙耳机接进来时默认源可能变成 HFP 的 loopback
  节点，识别效果会明显变差，先换回内置或 USB 麦再判断模型好坏。
- 硬件静音开关、蓝牙配对、音频路由。
- wowtype 时代的残留（`~/.local/share/wowtype`、`~/.local/state/wowtype`、
  `~/.config/fcitx5/config.bak-before-wowtype`）不参与任何配置，确认没用可以
  删掉；翻译配置备份在 `~/wowtype-backup-2026-11-26.tar.gz`。
- 任何在 GUI 里点出来的设置（fcitx5-configtool、vinput-gui）。

## 6. 排障入口

```bash
fcitx5-remote -n                          # 当前输入法
busctl --user call org.fcitx.Fcitx5 /controller \
  org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default
systemctl --user status vinput-daemon --no-pager
journalctl --user -u vinput-daemon -n 50
ls /run/current-system/sw/share/fcitx5/themes | wc -l
vinput daemon pipe < 某段.wav              # 直接看识别 JSON
```

「按语音键没反应」先确认当前输入法、再确认 daemon 在跑、最后看日志有没有
`ASR initialized`；这三层都正常才轮到麦克风。
