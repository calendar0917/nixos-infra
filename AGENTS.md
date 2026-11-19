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

- `hosts/main`、`hosts/nixos`：主机硬件、导入项和主机级开关。小主机的
  `ddns.nix`、`ingress.nix` 与 `scripts/` 管理 Cloudflare DDNS、ACME 和 Caddy。
- `modules/`：NixOS 基础、网络、备份、桌面会话和 shell 选择。
- `home/calendar/`：Home Manager 用户配置；桌面子目录含 Waybar、电源、锁屏、
  剪贴板和共享 helper。
- `config/`：niri、Sway、Waybar、SwayNC 和壁纸等只读配置。
- `deploy/`：各服务的 Compose 配置；运行数据不提交，放在服务器的
  `/srv/containers/<service>/`。
- `tests/`：无 GUI 的 Python 回归检查。
- Arch 安装期的 `START.sh`、`install-preflight.sh`、`docs/install/` 和
  `docs/history/` 已移除；需要旧现场步骤时从 Git 历史取
  （`git log --all --diff-filter=D -- docs/install`），不要重建这些入口。

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
- 改小主机 Docker/Compose：运行 `scripts/check-server-docker`，构建 nixos
  toplevel；没有改共享模块时至少对 main 做求值检查。
- 改小主机 DDNS/Caddy/ACME/动态路由：运行 `scripts/check-server-ingress`，构建
  nixos toplevel；没有改共享模块时至少对 main 做求值检查。真实 Cloudflare、
  证书签发、Caddy reload 和公网连通性必须单独报告，不能混入静态测试结论。
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
- 默认编辑器是 `nvim`（`home/calendar/nvim.nix` 的 `defaultEditor`）；main 的
  `~/.config/nvim` 由 `programs.lazyvim` 生成，是只读 store 链接。改编辑器配置
  改 `home/calendar/lazyvim.nix`，不要在运行期手改 `~/.config/nvim`。
- 锁屏就绪指 logind 的 `LockedHint=yes`，不是“锁屏进程已启动”；systemd 262
  的会话所有者属性是 `User`，不是 `UID`。
- `config/niri/config.kdl` 的 kitty 窗口规则只为透明窗口关闭焦点底板；不要
  扩大成全局窗口 opacity 或焦点切换脚本。
- main 的每周自动 GC 只回收无引用 store 内容，`nix.gc.options` 明确覆盖为空，
  不删除 profile generation；nixos 仍暂停自动 GC。修改该覆盖前确认不会继承
  `--delete-older-than`。
- 小主机 Docker 只从 `hosts/nixos/docker.nix` 配置；main 的 Docker 行为保持独立。
  `calendar` 不加入 `docker` 组，Docker API 只保留本地 Unix socket，不开放 TCP。
- Compose 示例只监听 loopback；运行数据用 `/srv/containers/<service>/`，不放进
  Nix store、`/home/calendar` 或 Git。不要执行 `docker system prune`、
  `docker volume prune` 或 `docker compose down -v`，除非用户明确授权具体数据。
- Docker daemon 的代理只用于镜像拉取；不要添加 Docker 对 Mihomo 的硬依赖，也
  不要把宿主机 7897 注入业务容器。
- 新增普通 Docker 服务默认只修改 `deploy/`、`/srv/containers/<service>/` 和
  `/etc/caddy/sites-enabled/`，使用 `sudo ingressctl publish <name> <port>`；不要
  为了新增业务服务修改 `hosts/nixos/*.nix` 或执行 `nixos-rebuild switch`。只有
  Docker Engine、宿主机防火墙、Caddy/ACME 基础策略等 NixOS 级变更才 switch。
- Caddy 业务站点只放在 `/etc/caddy/sites-enabled/*.caddy`，由 `ingressctl` 事务
  发布。不要在 `services.caddy.virtualHosts` 里逐个声明业务站点，不要手写任意
  Caddyfile、指向非 loopback 上游或绕过 `caddy validate` + `systemctl reload`。
- `/etc/cloudflare/token` 和 `/etc/cloudflare/zone-id` 只在实机安装，不进入 Git、
  Nix store、日志或命令行；DDNS/ACME 使用 systemd credential。不要修改无关 DNS
  记录、启用橙云代理或把真实 Token 写进测试。
- `allowedTCPPorts = [ 80 443 ]` 同时作用于 IPv4/IPv6，不是 IPv6-only；本阶段不
  开放 UDP 443，不通过 Docker `ports` 暴露 80/443。不要用 `trustedInterfaces`
  全局信任校园网物理接口。

## 工作流

- 默认从最新 Git `main` 直接工作，保留用户未提交内容；不要回退到旧 SHA 覆盖
  新状态。只有用户明确要求时才建立功能分支或 PR。
- 提交按行为分组；直接在 `main` 提交并 push，遵守分支保护，不强推。
- 每阶段简短报告完成项、验证结果和下一步；长构建说明等待目标。
- 按影响范围选择检查；只有新错误、真实行为变化或依赖变化才扩大验证。
- 完成后提供最终 main SHA、实际通过项、未执行项和待实机项目，然后停止。
