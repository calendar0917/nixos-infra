# 主力机 NixOS 工作环境状态

> 机器：LENOVO 21LG，hostname `main`，Arch 与 NixOS 共用 ESP。
> 本文只记录实际检查/验证过的结果；标为“待执行”的项目没有写成已完成。
> 最近更新：2026-10-28（已 switch 到 Generation 6；Docker/AxonHub 已运行，尚未重启内核）。

## 1. 系统、启动与磁盘

| 项目 | 当前结果 |
| --- | --- |
| 运行系统 | NixOS `26.11.20261020.dirty`，内核 `6.18.57` |
| 当前 generation | Generation 6，`/run/current-system` 指向 `vj45wp…` |
| 本次启动的系统 | `/run/booted-system` 仍指向 `5pzgam…`；尚未重启，内核仍为启动时版本 |
| 最新构建 | Generation 6 已激活；Generation 1–5 保留用于回滚 |
| 失败服务 | `systemctl --failed`：0 loaded units |
| `/` | `/dev/nvme0n1p2[/@nixos]`，rw |
| `/home` | 同一 Btrfs 的 `[/@nixos-home]`，rw |
| `/nix` | 同一 Btrfs 的 `[/@nixos-nix]`，rw |
| `/boot` | `/dev/nvme0n1p1`，vfat，共享 ESP，约 872 MiB 可用 |
| `/mnt/arch-home` | `/dev/nvme0n1p2[/@home]`，`ro`，只读访问 Arch 家目录 |
| Arch 默认启动项 | `loader.conf` 为 `default arch-linux-lts.efi` |
| Arch UKI | `/boot/EFI/Linux/arch-linux-lts.efi`，SHA256 `a7834276…bee23a93c` |
| EFI BootOrder | `Boot2001, Boot0005, Boot0000, Boot2002, Boot2003`；`Boot0005` 为 Linux Boot Manager，无 BootNext |
| systemd-boot | 262，`canTouchEfiVariables = false`，`configurationLimit = 3` |

### Boot hook

`hosts/main/boot.nix` 的 `extraInstallCommands` 只编辑 `loader.conf` 的
`default`/`preferred` 行，并强制 Arch UKI 为默认项。之前裸调用 `grep` 的失败
已修复为 `${pkgs.gnugrep}/bin/grep`；当前构建中实际展开为
`/nix/store/…-gnugrep-3.12/bin/grep`。每次 switch 前仍应确认：

```bash
cat /boot/loader/loader.conf
sha256sum /boot/EFI/Linux/arch-linux-lts.efi
bootctl status --no-pager | sed -n '/Default Boot Loader Entry/,$p'
```

不要在 NixOS 中运行 `bootctl install`、`efibootmgr -o` 或手工改默认启动项。
共享 ESP 的写入只应通过已审查的 `nixos-rebuild switch` 完成。

## 2. 已配置并验证的环境

| 项目 | 状态 / 位置 |
| --- | --- |
| Node.js | `v22.23.3`，`npm`/`npx` `10.9.9` |
| pnpm | `10.34.5`，已生效 |
| uv | `0.13.1`，已生效 |
| Pi Web Agent | `@agegr/pi-web 0.12.2` 正在运行，`127.0.0.1:30141`；项目工作目录 `/home/calendar/nixos-infra` |
| Pi 用户数据 | `~/.pi/agent/`：sessions、auth.json、models、settings、pi-web state；未发现自定义 skills 目录 |
| Fish / Git / SSH Agent | Fish `4.9.3`、Git `2.56.0`、`ssh-agent` 可用 |
| 终端/编辑器 | Neovim `0.12.6`、tmux `3.8`、Yazi、Kitty、direnv、starship、zoxide |
| Docker | `docker 29.9.1`、Compose `5.6.0`，服务 active；daemon 代理走 `127.0.0.1:7897` |
| AxonHub | `v1.0.0-beta10`，`/health` 返回 healthy；仅监听 `127.0.0.1:8090` |
| Tailscale | `tailscaled` active，`tailscale0` 存在；本轮未改登录/路由/DNS 设置 |
| Clash Verge Rev | 2.5.2，服务模式 active；GeoSite 数据已修复并通过配置测试 |

### Docker / AxonHub

- Docker 数据仍在默认的 `/var/lib/docker`，没有放到 Arch Home 或 U 盘。
- `hosts/main/docker.nix` 给 dockerd 增加了 `pkgs.nftables` 和
  `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:7897`；拉镜像是 dockerd 发起的，
  shell 里的 `export HTTPS_PROXY` 不会影响它。
- 2026-10-28 已实际拉取 `postgres:16-alpine` 和
  `looplj/axonhub:v1.0.0-beta10`，AxonHub 健康检查通过。
- PostgreSQL 没有宿主机 5432 监听；AxonHub 进程与数据库之间已有 idle 连接。

### Clash Verge / Mihomo

- 独立 Mihomo 仍监听 `127.0.0.1:7897`，本次验证 GitHub 返回 200。
- Clash Verge 数据目录：
  `/home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev/`。
- 原 `geosite.dat` 来自 v2fly `domain-list-community-20261009101206`，不含
  `gfw` 分类；订阅 profile `RQhVHMttbXtZ.yaml` 的
  `dns.fallback-filter.geosite: [gfw]` 因此失败。
- 已将该文件替换为 MetaCubeX `meta-rules-dat` 的官方 `geosite.dat`
  （SHA256 `ba8968847bfb82a4f9b0c33da77b6d95f4f8fe1d7d3bb241a7ebac6c23b71631`）。
- `verge-mihomo -t` 对实际数据目录测试成功；临时 17897 端口实测 GitHub 200。
- 已废弃字段仍会打印 warning。`nameserver-policy."geosite:gfw"` 的替代配置
  已在隔离文件测试成功，但尚未应用，因为需要开启 Clash Verge DNS 覆写并
  改变订阅 DNS 行为。
- **Clash Verge GUI 尚未接管 7897**。在验证完成前，不要停止独立 Mihomo；
  也不允许两者同时绑定 7897。

## 3. 还没有迁移 / 待执行

| 项目 | 说明 |
| --- | --- |
| 系统重启 | 尚未重启；内核仍为 switch 前 boot 版本。等 Clash Verge 接管完成后再安排，避免手动 Mihomo 7897 丢失 |
| Clash Verge 正式接管 | 需要先决定临时端口/停独立 Mihomo，再切回 7897 |
| 系统 Python | 故意不全局安装；使用 `uv` 或项目 devShell，避免污染系统环境 |
| Arch 个人配置 | 只读挂载 `/mnt/arch-home`；没有复制 `.config`、`.local`、浏览器 profile、SSH/GPG |
| Pi skills/extensions | 当前只有 sessions/auth/models/settings；未迁移 Arch 的 `.pi` 自定义内容 |
| 128 GB U 盘写入 | 本轮只读盘点并已卸载；未写入、未格式化、未清理 |

## 4. 重要数据位置

- NixOS 家目录：`/home/calendar`（约 1.5 GiB，其中 `.npm` 约 1.1 GiB、
  `.cache` 约 227 MiB）。
- NixOS 配置：`/home/calendar/nixos-infra`。
- AxonHub 运行配置：`deploy/axonhub/.env`，权限 `0600`，被 Git 忽略；
  数据库密码只在这里和密码管理器中保存。
- AxonHub 数据库：Docker named volume `axonhub_postgres_data`（已创建），位于
  NixOS `/var/lib/docker`，不在 Arch Home、不在 U 盘。
- Arch 家目录：`/mnt/arch-home/calendar`，只读；`life/` 内有个人资料和
  `secrets/`，不要把其中任何内容复制进 Git 或 Nix store。
- 128 GB U 盘：`/dev/sda1`，exfat，UUID `B810-3F4A`，116.1 GiB，已用约
  4.7 GiB。`latest/life` 是最新 life 副本（约 1.5 GiB，`secrets/` 按设计排除）；
  `backup/` 有 2026-08-11、2026-08-28 的 `life-*.tar.zst` 和 secrets 7z；
  `restic/` 是独立仓库（约 1.3 GiB）。当前已卸载，未写入。

## 5. 重建与回滚

由有 sudo 权限的用户执行，不要自动更新 `flake.lock`：

```bash
cd /home/calendar/nixos-infra
git status --short
nix flake check --no-update-lock-file
sudo -E nixos-rebuild build --flake .#main --no-update-lock-file
# 检查新 result、/boot/loader/loader.conf、Arch UKI 哈希后再执行：
sudo nixos-rebuild switch --flake .#main --no-update-lock-file
```

注意：

- 新增 Nix 文件要先 `git add`，否则 flake 在 dirty Git 树中看不到它。
- 不在本轮升级 `flake.lock` 中的 nixpkgs。
- switch 会写共享 ESP；执行前确认 `loader.conf` 默认项仍为 Arch，执行后再次确认。
- 回滚：`sudo nixos-rebuild switch --rollback` 或重启时在 systemd-boot 菜单
  选择旧 generation。不要在验证前启用自动 GC。
- 不要格式化、重新分区、删除 `@nixos*` 或 Arch 子卷，也不要改默认启动项。

## 6. AxonHub

完整命令和恢复测试见 [`../deploy/axonhub/README.md`](../deploy/axonhub/README.md)。

简要流程（当前已运行；重建或排障时使用）：

```bash
cd /home/calendar/nixos-infra/deploy/axonhub
sudo docker compose --env-file .env config --quiet
sudo docker compose --env-file .env pull
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:8090/health
```

检查项：

- `curl` 返回 `status=healthy`、`version=v1.0.0-beta10`；
- PostgreSQL 容器运行，进程列表中可见 AxonHub 到数据库的 idle 连接；
- `ss -lntp | grep ':8090'` 只显示 `127.0.0.1:8090`；
- 宿主机没有 `:5432` 监听；
- 浏览器访问 `http://127.0.0.1:8090`；
- 容器重启后数据仍在 `axonhub_postgres_data`；
- 上游 API 不通时先查 Docker `egress`、代理和 DNS，不要改主机全局 DNS。
- 需要确认 Compose 的 health 字段时运行
  `sudo docker compose --env-file .env ps`。

## 7. 备份建议（未执行，等待授权）

这块 U 盘目前有 112 GiB 可用，但已有重要 life 备份。若把它作为 NixOS 第二
备份目标，建议：

1. 在 U 盘新建独立目录（例如 `restic-nixos`），绝不与旧 `restic/` 混用；
2. 使用新的随机密码，不复用旧 Restic 密码；密码离线保存两份；
3. restic 原生加密；不加密整块 exfat，避免破坏现有 life 备份；
4. 备份 `/home/calendar`、`/var/lib/sops-nix` 和 AxonHub 的 `pg_dump` 导出，
   排除 `.cache`、`.npm`、`node_modules`、`.venv`、Clash 可重建数据；
5. 恢复测试在 `/tmp` 或独立目录进行，绝不覆盖现有 home；
6. 不把 Docker data-root 或 PostgreSQL volume 放到 U 盘；数据库用 `pg_dump`；
7. 首次写入前再次确认设备 UUID `B810-3F4A`、挂载点和剩余空间，并取得授权。

## 8. Arch 与 NixOS 共存注意事项

- 两者共享 1 GiB ESP；NixOS 只保留 3 个 generation，避免占满 ESP。
- Arch 仍是默认启动项；NixOS 的 boot hook 会在每次安装/重建后把
  `loader.conf` 的 default 改回 `arch-linux-lts.efi`。
- 不要删除 Arch 的 `@`、`@home`、Snapper 快照或 UKI；不要对共享 ESP 做
  未备份的写操作。
- `/mnt/arch-home` 是只读的 Arch `@home`，不是 NixOS 的 `/home`，也不归
  Home Manager 管理。
- 不要把 Arch 的整个 `~/.config`、`~/.local`、Node `node_modules`、Python
  `.venv` 或浏览器 profile 直接覆盖到 NixOS。
- 如果 Arch 重命名 UKI，必须同步更新 `hosts/main/boot.nix` 的
  `arch-linux-lts.efi` 路径并重新验证。
