# nixos-infra

`calendar` 的 NixOS 配置，使用单一 `flake.nix` / `flake.lock`、NixOS 原生模块和
集成的 Home Manager。仓库管理两台机器；日常桌面以 niri 为主，Sway 是备用会话。

## 两台主机

| 主机 | 角色 | 桌面 |
| --- | --- | --- |
| `main` | LENOVO 21LG 笔记本，Arch/NixOS 双系统 | niri + Waybar；Hyprlock、蓝牙、wdisplays + kanshi |
| `nixos` | KOLOE 小主机，SSH/轻量容器节点 | niri + DMS；保留 Sway 备用会话 |

共享 Nix 文件必须能在两台主机求值，但只改 main 的桌面行为不会自动切换小主机。
`system.stateVersion` 和 `home.stateVersion` 保持首次安装时的值，不随 nixpkgs
升级而改变。

## 目录

```text
flake.nix / flake.lock              # 唯一入口和锁定版本
hosts/main/                         # 笔记本 host、Waybar 覆盖、蓝牙/PAM
hosts/nixos/                        # 小主机 host、DDNS、Caddy/ACME 入口
modules/                            # NixOS 基础、网络、备份、桌面模块
home/calendar/                      # Home Manager：shell、终端、编辑器、桌面
config/                             # niri、Sway、Waybar、SwayNC、壁纸
deploy/                             # 各服务的 Compose 配置；运行数据不放这里
tests/                              # 无 GUI 的 Python 回归检查
scripts/check-desktop               # 桌面回归入口
scripts/check-server-network        # 小主机校园网/Mihomo 静态回归
scripts/check-server-docker         # 小主机 Docker/Compose 静态回归
scripts/check-server-ingress        # 小主机 DDNS/Caddy/ACME 静态与事务回归
docs/                               # 桌面、应用、恢复、开发说明
```

## 日常命令

```bash
# 只求值/构建，不切换当前系统
nix flake check --no-build
nix build --no-link .#nixosConfigurations.main.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel

# 用户确认后应用；仓库不会自动执行 switch/boot
sudo nixos-rebuild switch --flake .#main
sudo nixos-rebuild switch --flake .#nixos

# 回滚
sudo nixos-rebuild switch --rollback
sudo nixos-rebuild boot --rollback
nix-env -p /nix/var/nix/profiles/system --list-generations
```

`.#main` 是 flake 的主机属性，不是 Git 分支。main 每周自动 GC 只回收无引用的
store 内容，不删除 profile generation；小主机仍暂停自动 GC。旧 generation 只在
人工核对后选择性删除，不要为了腾空间删除最后一个可用回滚点。详见
[`docs/RECOVERY.md`](docs/RECOVERY.md) 3.2。

## 维护入口

桌面回归统一从这里执行：

```bash
scripts/check-desktop
```

它会构建 main 的 Home Manager activationPackage，提取实际生成的 niri 电源菜单/
锁屏/显示模式 helper 和 wlogout 资源，再运行桌面、显示菜单与会话/主机回归。后者
直接读取生成出来的 systemd user unit 和会话文件，并用桩命令检查 Sway 退出 watcher
的分支，不会真的启停会话。脚本不会 switch、锁屏、挂起或重启；`--help` 不触发构建。
只改文档时不需要运行它。

小主机校园网/Mihomo 的无网络单元回归：

```bash
scripts/check-server-network
```

它只构建一个固定 Python 测试环境并运行 `tests/test_server_network.py`，不启动
`campus-login`/`mihomo`，不读取真实凭据，也不改当前 generation。

小主机 Docker/Compose 的静态回归：

```bash
scripts/check-server-docker
```

它会解析 `deploy/nixos-smoke/compose.yaml`，在 Compose CLI 可用时执行
`config -q`，求值 NixOS 配置并运行 `tests/test_server_docker.py`；不会连接
Docker daemon、启动容器或修改持久化数据。

小主机公网入口的静态与事务回归：

```bash
scripts/check-server-ingress
```

它用固定 Python 环境和 Caddy 运行 `tests/test_server_ingress.py`，覆盖 IPv6
选择、模拟 Cloudflare API、`ingressctl` 发布/回滚、Caddyfile 解析和 NixOS
配置检查；不会访问真实 Cloudflare、申请证书、启动 Caddy 或修改 generation。

新增普通 Docker 服务的标准流程是：在 `deploy/<service>/` 写 Compose、准备
`/srv/containers/<service>/`、`docker compose up -d`、验证 loopback，然后
`sudo ingressctl publish <service> <port>`。**新增业务服务不需要修改
`hosts/nixos/*.nix`，也不需要 `nixos-rebuild switch`。** 只有变更 Docker
Engine、宿主机防火墙、Caddy/ACME 基础配置或系统软件时才重新 switch。详见
[`docs/SERVER_INGRESS.md`](docs/SERVER_INGRESS.md)。

Agent 的目录范围、默认禁止动作和按影响范围检查的约定见
[`AGENTS.md`](AGENTS.md)。

## nixpkgs 固定与更新

`flake.nix` 固定 NixOS/nixpkgs 的不可变 commit：

```text
04906337b6d53e8bb0eaf0470ae9f070a4d4eb55   # nixos-unstable, 2026-11-17
```

Home Manager 和 sops-nix 只通过 `follows = "nixpkgs"` 使用同一组包。升级时修改
`flake.nix` 中的 commit，再执行：

```bash
nix flake update nixpkgs
nix flake check --no-build
```

不要手写 `flake.lock` 的 `narHash`，也不要在升级 nixpkgs 时顺带全量更新 inputs。
`hosts/main/waybar.nix` 不再固定上游 Waybar revision：nixpkgs 的 Waybar 0.16.0
已经包含 `workspace-taskbar` 和 `enable-bar-scroll`，这里只保留关闭 Cava/WWAN 的
feature 裁剪。除非需要 release 里还没有的模块，否则不要重新加回源码 pin。

`modules/base.nix` 把 Nix daemon 和客户端的 HTTP(S) 下载指向本地代理
`http://127.0.0.1:7897`，loopback 直连。main 的监听者是 Clash Verge，nixos 的
监听者是 Mihomo；代理未运行时远程 fetch/build 会失败。修改该段后需要一次
`nixos-rebuild switch` 才写入 daemon 运行环境。

## 分支、部署与边界

默认直接在最新 Git `main` 上完成经过验证的改动；只有用户明确要求时才建立功能
分支或 PR。不要覆盖用户未提交的内容，不要强推。系统切换、重启、真实锁屏和挂起
由用户主动执行。

- 默认不更新 flake inputs、不改另一台主机；只有任务明确要求时才扩大范围。
- 不在未确认设备、分区和备份的情况下执行 `mkfs`、`parted`、`sgdisk`、`dd`、
  `wipefs`，不改 ESP、挂载、账号、网络、secrets 或备份策略。
- SOPS 密文在 `secrets/secrets.yaml`；age 私钥和 Restic 密码只在机器本地或离线
  介质，不进入仓库或 Nix store。
- Restic 备份默认关闭，启用前必须填写真实 USB UUID 并完成恢复演练。

## 文档导航

- 桌面组件协作、Sway/Niri 会话生命周期、显示器布局、锁屏/挂起和故障入口：
  [`docs/DESKTOP.md`](docs/DESKTOP.md)
- 应用兼容、默认打开方式和 OBS：
  [`docs/APPS.md`](docs/APPS.md)
- TTY/桌面恢复、重装顺序、网络、SOPS、Restic、SSH：
  [`docs/RECOVERY.md`](docs/RECOVERY.md)
- 小主机校园网认证、无 GUI Mihomo、`proxyctl`、Profile/订阅和网络回滚：
  [`docs/SERVER_NETWORK.md`](docs/SERVER_NETWORK.md)
- 小主机 Docker/Compose、数据目录、代理、端口和回滚：
  [`docs/SERVER_DOCKER.md`](docs/SERVER_DOCKER.md)
- 小主机 Cloudflare IPv6 DDNS、ACME 通配符证书、Caddy 动态入口和 `ingressctl`：
  [`docs/SERVER_INGRESS.md`](docs/SERVER_INGRESS.md)
- 开发环境、devShell、tmux 和 Arch/NixOS 共享：
  [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
