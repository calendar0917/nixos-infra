# nixos-infra

`calendar` 的 NixOS 配置，使用单一 `flake.nix` / `flake.lock`、NixOS 原生模块和
集成的 Home Manager。仓库管理两台机器；日常桌面以 niri 为主，Sway 是备用会话。

## 两台主机

| 主机 | 角色 | 桌面 |
| --- | --- | --- |
| `main` | LENOVO 21LG 笔记本，Arch/NixOS 双系统 | niri + Waybar；Hyprlock、蓝牙、nwg-displays |
| `nixos` | KOLOE 小主机，SSH/轻量容器节点 | niri + DMS；保留 Sway 备用会话 |

共享 Nix 文件必须能在两台主机求值，但只改 main 的桌面行为不会自动切换小主机。
`system.stateVersion` 和 `home.stateVersion` 保持首次安装时的值，不随 nixpkgs
升级而改变。

## 目录

```text
flake.nix / flake.lock              # 唯一入口和锁定版本
hosts/main/                         # 笔记本 host、Waybar 覆盖、nwg 补丁、蓝牙/PAM
hosts/nixos/                        # 小主机 host
modules/                            # NixOS 基础、网络、备份、桌面模块
home/calendar/                      # Home Manager：shell、终端、编辑器、桌面
config/                             # niri、Sway、Waybar、SwayNC、壁纸
patches/                            # nwg-displays 本地补丁
tests/                              # 无 GUI 的 Python 回归检查
scripts/check-desktop               # 桌面回归入口
docs/                               # 桌面、应用、恢复、开发说明
docs/history/                       # 带日期的历史观察，不是当前状态
docs/install/                       # 双系统安装和历史迁移材料
```

`START.sh`、`START_HERE.txt` 和 `install-preflight.sh` 是 Arch 现场安装入口；
只有相关任务才需要读取。

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
锁屏 helper 和 wlogout 资源，再运行 `tests/test_desktop_polish.py`。脚本不会
switch、锁屏、挂起或重启；`--help` 不触发构建。只改文档时不需要运行它。

Agent 的目录范围、默认禁止动作和按影响范围检查的约定见
[`AGENTS.md`](AGENTS.md)。

## nixpkgs 固定与更新

`flake.nix` 固定 NixOS/nixpkgs 的不可变 commit：

```text
31ecbaca1bdefa45dffc409f0250bd8039ea0010   # nixos-unstable, 2026-10-27
```

Home Manager 和 sops-nix 只通过 `follows = "nixpkgs"` 使用同一组包。升级时修改
`flake.nix` 中的 commit，再执行：

```bash
nix flake update nixpkgs
nix flake check --no-build
```

不要手写 `flake.lock` 的 `narHash`，也不要在升级 nixpkgs 时顺带全量更新 inputs。
`hosts/main/waybar.nix` 固定上游 Waybar revision 以保留 `workspace-taskbar`；
不要为了“清理覆盖”删掉它。

`modules/base.nix` 把 Nix daemon 和客户端的 HTTP(S) 下载指向本地 Clash
`http://127.0.0.1:7897`，loopback 直连。Clash 未运行时远程 fetch/build 会失败；
修改该段后需要一次 `nixos-rebuild switch` 才写入 daemon 运行环境。

## 分支、部署与边界

从最新 Git `main` 建立短生命周期分支，完成后通过 PR 合入；遵守分支保护，不强推。
系统切换、重启、真实锁屏和挂起由用户主动执行。

- 默认不更新 flake inputs、不改另一台主机；只有任务明确要求时才扩大范围。
- 不在未确认设备、分区和备份的情况下执行 `mkfs`、`parted`、`sgdisk`、`dd`、
  `wipefs`，不改 ESP、挂载、账号、网络、secrets 或备份策略。
- SOPS 密文在 `secrets/secrets.yaml`；age 私钥和 Restic 密码只在机器本地或离线
  介质，不进入仓库或 Nix store。
- Restic 备份默认关闭，启用前必须填写真实 USB UUID 并完成恢复演练。

## 文档导航

- 桌面组件协作、显示器文件、锁屏/挂起和故障入口：
  [`docs/DESKTOP.md`](docs/DESKTOP.md)
- 应用兼容、默认打开方式和 OBS：
  [`docs/APPS.md`](docs/APPS.md)
- TTY/桌面恢复、网络、SOPS、Restic、SSH：
  [`docs/RECOVERY.md`](docs/RECOVERY.md)
- 开发环境、devShell、tmux 和 Arch/NixOS 共享：
  [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- 双系统安装与恢复：
  [`docs/install/ARCH_DUAL_BOOT.md`](docs/install/ARCH_DUAL_BOOT.md)
- 历史观察（main 2026-10-28 快照、开发环境旧记录）：
  [`docs/history/`](docs/history/)
