# AGENTS.md

本文件记录进入仓库的长期工作约定。具体任务的操作授权仍以用户当次说明为准。

## 仓库与主机

- 仓库只有一个 `flake.nix`，暴露 `nixosConfigurations.main` 和
  `nixosConfigurations.nixos`。
- `main` 是 LENOVO 笔记本：niri + Waybar、Hyprlock、蓝牙、wdisplays + kanshi 和
  main-only 应用。`nixos` 是 KOLOE 小主机：niri + DMS，保留 Sway 备用会话。
- Git 分支 `main` 与 flake 主机 `#main` 是两件事；应用命令的 `.#main` 指主机
  属性，不是分支名。
- 共享文件必须能在两台主机求值；只改 main 桌面作用域不等于要切换或重建小主机。

## 目录地图

- `hosts/main`、`hosts/nixos`：主机硬件、导入项和主机级开关。
- `modules/`：NixOS 基础、网络、备份、桌面会话和 shell 选择。
- `home/calendar/`：Home Manager 用户配置；桌面子目录含 Waybar、电源、锁屏、
  剪贴板和共享 helper。
- `config/`：niri、Sway、Waybar、SwayNC 和壁纸等只读配置。
- `tests/`：无 GUI 的 Python 回归检查。
- `docs/history/`、`docs/install/`、`START.sh`、`START_HERE.txt` 和
  `install-preflight.sh` 是历史或安装恢复材料；只在相关任务中读取，不作为
  当前运行状态。

## 默认边界

- 除非用户在当前任务中明确授权，不要执行 switch/boot/reboot/suspend、真实
  锁屏，不要写 ESP/磁盘/挂载点，也不要修改网络、账号、secrets 或备份策略。
- 默认不要更新 flake inputs，不要顺手改另一台主机。需要时先确认具体范围。
- 以上是维护默认值，不是对未来明确任务的永久禁令；用户已授权时按授权执行，
  不重复索要许可。
- 不为维护任务增加软件、主题、CI、测试框架或模块框架。GUI 未执行的项目写
  “待实机验证”，不要写成已通过。
- 不读取 secrets 内容；需要密钥时只检查权限和存在性。

## 验证范围

- 只改文档：检查本地链接和 `git diff --check`，不构建系统。
- 只改 main 桌面或 Home Manager：检查相关生成脚本和样式，运行
  `scripts/check-desktop`；不默认重建两台 toplevel。
- 改 `modules/`、`hosts/`、系统服务或两机共享行为：分别求值/构建受影响主机。
- 改 niri 配置：直接 `niri validate -c config/niri/config.kdl`。配置已不 include
  `monitor.kdl`，不需要临时文件，也不读写用户的旧布局记录。
- 改 Sway 配置：main 用 `sway -C -c config/sway/config-main`，小主机用
  `sway -C -c config/sway/config`。`sway -C` 不报重复按键，重复绑定由
  `tests/test_session_and_hosts.py` 检查。
- 改显示器布局：只动 `home/calendar/desktop/displays.nix` 和 Kanshi 的初始 Profile；
  不要给 Kanshi 生成只读配置，也不要手改 niri 的输出块。
- 桌面回归标准入口只有 README 维护段中的 `scripts/check-desktop`；其他文档
  引用入口，不复制整段命令。

## 已知约定

- Waybar 在 main 上只允许一个实例，由 niri 绑定的 user unit 启动；不要另加
  systemd unit、XDG autostart 或 `spawn-at-startup waybar`。
- `config/niri/config.kdl` 只读，且**不再** `include "monitor.kdl"`。旧的
  `~/.config/niri/monitor.kdl` 只是布局记录（含非法 niri KDL `on`），不要加回
  include，也不要删除该文件。
- `~/.config/kanshi/config` 是 wdisplays 写入的可写文件。`services.kanshi.settings`
  必须保持 `[]`，Home Manager 只在文件缺失时复制初始 Profile，绝不覆盖已有布局。
- main 的 Sway 辅助进程只用 `sway-waybar.service`、`sway-mako.service`、
  `sway-bg.service`、`sway-exit-watch.service`；不要复用 niri 的 `waybar.service`、
  `swaybg.service`、`swaync.service`，也不要在 `config/sway/config-main` 里加裸
  `exec waybar`/`exec mako`/`exec swaybg`。
- `sway-exit-watch` 只在 niri 未运行时停止 `graphical-session.target`；不要改成
  无条件停止，也不要用 `pkill` 代替 unit 生命周期。
- main 和 nixos 的 Sway 配置、Fuzzel 配置、Waybar 样式按 hostName 分流；改其中
  一份不要顺手改另一份。
- wlogout 读取的是换行分隔的 JSON 对象流，不是 JSON 数组。
- flake 只把 Git 跟踪的文件纳入构建；新增文件必须 `git add` 后才参与求值。
- Helix 的 `config.toml` 是 TOML；需要解析时使用 Python `tomllib` 或 TOML
  工具，不要用 `jq`。
- 锁屏就绪指 logind 的 `LockedHint=yes`，不是“锁屏进程已启动”；systemd 262
  的会话所有者属性是 `User`，不是 `UID`。
- `config/niri/config.kdl` 的 kitty 窗口规则只为透明窗口关闭焦点底板；不要
  扩大成全局窗口 opacity 或焦点切换脚本。
- main 的每周自动 GC 只回收无引用 store 内容，`nix.gc.options` 明确覆盖为空，
  不删除 profile generation；nixos 仍暂停自动 GC。修改该覆盖前确认不会继承
  `--delete-older-than`。

## 工作流

- 从最新 Git `main` 建立短生命周期分支，保留用户未提交内容；不要回退到旧
  SHA 覆盖新状态。
- 提交按行为分组，同一任务用一个 PR；遵守分支保护，不强推。
- 每阶段简短报告完成项、验证结果和下一步；长构建说明等待目标。
- 按影响范围选择检查；只有新错误、真实行为变化或依赖变化才扩大验证。
- 合并后提供最终 main SHA、实际通过项、未执行项和待实机项目，然后停止。
