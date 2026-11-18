# Rakazo

`bot.20050917.xyz` 的自托管部署记录。运行目录是服务器的
`/srv/containers/rakazo`，不属于 Git；本目录只记录必要信息。

## 版本与镜像

- 上游 release：`v0.12.0`，Compose 与安装脚本按该 tag 固定。
- 应用/computer 镜像：`ghcr.nju.edu.cn/elie222/rakazo/{app,computer}:v0.12.0`。
- Postgres/busybox：`docker.m.daocloud.io/library/{postgres:16,busybox:1}`。
- 镜像站是第三方 GHCR/Docker Hub 镜像；升级时保持 app 与 computer 同 tag。

## 入口

```text
bot.20050917.xyz
  -> hw:183.87.144.211 frps（TLS 直通，自定义域 bot.20050917.xyz）
  -> nixos frpc-artex
  -> Caddy :443（/etc/caddy/sites-enabled/bot.caddy）
  -> 127.0.0.1:5173 Rakazo web
```

- Cloudflare 只新增精确 A 记录 `bot -> 183.87.144.211`，TTL 120，DNS only；
  不修改 `*.20050917.xyz` 通配、apex 或 `nixos` 记录。
- Caddy 路由由 `sudo ingressctl publish bot 5173` 管理；撤销用
  `sudo ingressctl remove bot`。
- `hw` 只有 IPv4；`bot` 没有 AAAA。

## 运行

```bash
cd /srv/containers/rakazo

sudo docker compose --env-file .env -f docker-compose.images.yml -f docker-compose.override.yml ps
sudo docker compose --env-file .env -f docker-compose.images.yml -f docker-compose.override.yml up -d --wait
sudo docker compose --env-file .env -f docker-compose.images.yml -f docker-compose.override.yml logs --tail=100
```

- `docker-compose.override.yml` 清空 api/worker 的宿主代理变量；手动执行 Compose
  时要带上它，`install-images.sh` 会自动检测。

- `.env` 为 `0600 root:root`，包含数据库/认证/加密密钥；不要提交或输出。
- 必须备份 `.env` 中的 `ENCRYPTION_KEY`；丢失后已加密内容不可恢复。
- 数据在 Docker named volumes：`rakazo_pgdata`、`rakazo_appdata`、
  `rakazo_webassets`。停止用 `down`，不要用 `down -v`。
- 首次账号：运行 `sudo bash /srv/containers/rakazo/bootstrap-owner.sh`，交互输入
  邮箱和至少 16 位密码。`SIGNUPS_ENABLED=false`，不开放公开注册。
- bot computer 的 egress 由 NixOS 服务 `rakazo-computer-egress.service` 执行
  `/srv/containers/rakazo/restrict-computer-egress.sh --apply`，只匹配
  `rakazo-c*` 网桥。

### bot computer 资源

- `.env`：`RAKAZO_COMPUTER_MEMORY=2g`、`RAKAZO_COMPUTER_CPUS=2`、
  `SANDBOX_MAX_COMPUTERS_PER_USER=1`。
- `docker-compose.override.yml`：supervisor 设置
  `SANDBOX_MAX_COMPUTERS_PER_SPACE=1`、`SANDBOX_TEAM_SCREEN_LIMIT=1`。
- 修改后只重建受影响服务：

```bash
sudo docker compose --env-file .env -f docker-compose.images.yml \
  -f docker-compose.override.yml up -d --wait api worker supervisor
```

`2g` 是 cgroup 上限，不是预留内存。主机 5.7 GiB，启动 computer 后用
`free -h` 和 `docker stats` 观察；内存压力大时先降到 `1536m`，不要同时开多个
computer 或桌面。已经运行的 computer 保持创建时的上限，需在 UI 停止该 computer
或停止 bot，下一次打开时才会按新值创建。

### computer use 模型

Docker provider 已启用，不需要 E2B。屏幕操作要求模型能接收图片：在
**Settings → Models** 选择支持图片的模型并设为 **Computer-use model**，或把
主模型换成视觉模型。纯文本模型仍可使用 shell、文件和网页文本工具，但不能
截图和点击桌面。

## 升级与回滚

升级前备份 `.env` 和 volumes。修改 `RAKAZO_IMAGE_TAG` /
`RAKAZO_COMPUTER_IMAGE_TAG` 后执行 `pull` 和 `up -d --wait`；迁移失败时先保留
旧镜像和 volumes，不要 `down -v`。

回滚公网入口：

```bash
sudo ingressctl remove bot
# 恢复 /etc/frp/frpc-artex.toml.bak-* 并 restart frpc-artex
# 在 Cloudflare 删除精确 bot A 记录，恢复通配覆盖
```

## 已知限制

- nixos 无入站 IPv6，公网只走 hw 的 IPv4 frps。
- 内存 5.7 GiB；bot computer 上限 `2g`/`2` CPU，每个用户和 Space 各 1 个
  computer、每个 computer 1 个活动桌面；启动后需观察内存和 swap。
- api/worker 不继承宿主 shell 的 7897 代理；如需容器出站代理，必须改成容器内
  可达的地址，不能直接使用 `127.0.0.1`。
- 未启用 `updater` profile，升级手动执行。
- bot computer 的实际启动和屏幕代理尚未在实机验证。
