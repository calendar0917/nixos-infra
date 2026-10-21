# 验证记录

验证环境不是 NixOS：当前执行机为 Arch Linux x86_64，为执行用户要求的 flake 验证，
临时安装了 Nix 2.35.3 并初始化了本机 `/nix/store`。没有在这台机器上执行
`nixos-rebuild switch`、分区、格式化、EFI 写入、真实网络修改或真实备份。

## 实际执行的命令与结果

| 命令 | 结果 |
| --- | --- |
| `nix flake show` | 通过；输出 `nixosConfigurations.nixos` |
| `nix flake check` | 通过；`all checks passed!` |
| `nix eval .#nixosConfigurations.nixos.config.system.build.toplevel.drvPath` | 通过；得到 `/nix/store/3b1smswz2g1wh5z04zw1rm97wwgqbiy9-nixos-system-nixos-26.11.19800101.dirty.drv` |
| `nix build .#nixosConfigurations.nixos.config.system.build.toplevel` | 通过；生成 `/nix/store/mzgf415s5aykj0l7jghqapq4fckcgj8h-nixos-system-nixos-26.11.19800101.dirty` |
| `niri validate -c config/niri/config.kdl` | 通过；`config is valid` |
| `WLR_BACKENDS=headless WLR_RENDERER=pixman sway --validate -c config/sway/config` | 通过；退出码 0 |
| `jq empty config/sway/waybar/config.jsonc` | 通过 |
| 三种桌面开关组合的 eval（niri-only / sway-only / plasma-only） | 均通过；仅 eval，未构建可选组合 |
| 三桌面全部开启的 eval（niri + sway + plasma） | 通过；仅 eval |

`nix build` 的日志里只有 man-db 的 whatis 解析警告和 xwayland/xorg-server 的
路径碰撞警告（被忽略），没有构建错误。Home Manager 的 Neovim `init.lua` 冲突已
通过 `sideloadInitLua = true` 解决。

## 未验证的内容

以下内容没有真实运行，因此不能声称通过：

- `nixos-rebuild switch` / `nixos-install`；
- SDDM 登录、niri 实际启动、DMS 实际启动、Sway/Waybar/Mako/Fuzzel 实际显示；
- Fcitx5 输入法实际输入；
- Tailscale 登录、Mihomo TUN/代理、DNS/路由行为；
- sops 解密激活、Restic USB 挂载/备份/恢复；
- Windows 启动项和真实 EFI 布局；
- `hardware-configuration.nix` 与目标机的匹配性。

## 重要发现

当前 Arch 环境的磁盘布局与旧仓库继承的
`hosts/nixos/hardware-configuration.nix` 不一致：旧文件引用的根、`/home`、swap
等 UUID 在当前 `lsblk` 中不存在。仓库中保留了该文件以维持旧主机的构建上下文，但
README 和 `docs/INSTALL.md` 已把它标为“安装前必须重新生成/核对”。在真实目标机上
不要直接 switch。

## Nix daemon 代理

由于访问 GitHub/TUNA 需要代理，验证期间临时给本机 `nix-daemon` 加了
`HTTP_PROXY/HTTPS_PROXY/ALL_PROXY=127.0.0.1:7897` 的 systemd drop-in。这不是仓库
内容，也不属于目标 NixOS 配置；如果不需要，验证结束后可删除该 drop-in 并重启
`nix-daemon`。
