# Artex 小主机部署

`artex` 是自制渗透测试控制台。这里只部署普通业务容器；不修改 NixOS 模块，
不需要 `nixos-rebuild switch`。公网入口由宿主机 Caddy 提供。

## 文件与数据边界

| 路径 | 说明 | 是否进 Git |
| --- | --- | --- |
| `compose.yaml` | 容器、端口和 volume 定义 | 是 |
| `.env` | 数据库密码和 LLM 凭据 | 否，`0600` |
| `data/` | 任务、transcript、traffic 等运行时数据 | 否 |
| `/srv/containers/artex/data/` | 小主机上的 `data/` | 否 |
| `/srv/containers/artex/.env` | 小主机上的 `.env` | 否，`0600 root:root` |

Compose 的 `ARTEX_DATA_DIR` 默认是仓库内的 `./data`；小主机 `.env` 必须写成：

```text
ARTEX_DATA_DIR=/srv/containers/artex/data
```

不要把 `data/`、真实 `.env` 或证书私钥放进 Nix store、Git 或
`/home/calendar`。本服务只发布到 loopback：

- `127.0.0.1:8787`：Web/API，由 Caddy 反代到 `artex.20050917.xyz`
- `127.0.0.1:8788`：内部代理，不发布公网

Postgres 使用 named volume `artex_pgdata`，`/app/skills` 使用
`artex_artex_skills`。

## 小主机首次部署

先在 `/srv/containers/artex/` 准备目录和 `.env`：

```bash
sudo install -d -m 0755 -o root -g root /srv/containers/artex
# 迁移期间让 calendar 可写；传完后可 chown -R root:root
sudo install -d -m 0755 -o calendar -g users /srv/containers/artex/data
sudo install -m 0600 -o root -g root .env /srv/containers/artex/.env
```

服务器上的 Compose 命令统一从仓库目录执行：

```bash
cd /home/calendar/nixos-infra

sudo docker compose \
  --env-file /srv/containers/artex/.env \
  -f deploy/artex/compose.yaml config -q

sudo docker compose \
  --env-file /srv/containers/artex/.env \
  -f deploy/artex/compose.yaml up -d
```

首次部署使用已经 `docker load` 到本机的同一镜像，不需要 `docker pull`。确认：

```bash
sudo docker compose \
  --env-file /srv/containers/artex/.env \
  -f deploy/artex/compose.yaml ps

curl --noproxy '*' -I http://127.0.0.1:8787/login
```

如果镜像不存在，Compose 才会尝试拉取；不要把 `pull_policy` 改成 `always`。

## 数据库迁移

不要直接复制 `pgdata` 原始目录。迁移时在旧环境执行：

```bash
sudo docker exec -T artex-postgres-1 \
  pg_dump -U artex -d artex -Fc > /tmp/artex.dump
```

把 dump 以 `0600` 放到小主机，启动 Postgres 后恢复：

```bash
sudo docker compose \
  --env-file /srv/containers/artex/.env \
  -f deploy/artex/compose.yaml up -d postgres

sudo docker exec -i artex-postgres-1 \
  pg_restore -U artex -d artex --clean --if-exists --no-owner \
  < /srv/containers/artex/artex.dump
```

恢复后确认 `tasks`、`findings`、`assets` 等表的行数，再启动 `artex`。

## 数据迁移与 task7

本地 `data/tasks/7` 约 47G，默认不迁移；其余 data 约 10G。跳过它不会删除
数据库里的 task 7 记录，但打开该任务时可能缺少证据文件。以后需要补传时单独
rsync 这个目录即可。

迁移用 rsync，保留目录结构：

```bash
sudo rsync -aH --no-owner --no-group \
  --exclude='/tasks/7/' \
  -e 'ssh -F /home/calendar/.ssh/config \
      -i /home/calendar/.ssh/id_rsa \
      -o UserKnownHostsFile=/home/calendar/.ssh/known_hosts' \
  /home/calendar/nixos-infra/deploy/artex/data/ \
  nixos:/srv/containers/artex/data/

ssh nixos 'sudo chown -R root:root /srv/containers/artex/data'
```

`artex_skills` 是独立 volume，不能漏；它只有几百 KB，可先复制到临时目录，再用
一个临时容器写入 `artex_artex_skills`。不要用 `docker volume prune`。

## 域名与证书

DNS 使用精确 AAAA：

```text
artex.20050917.xyz  AAAA  240e:398:f11:c63b:d14c:310d:1d3b:f194  DNS only
```

证书由 `*.20050917.xyz` 通配符证书覆盖，不需要新增 ACME 配置。发布路由：

```bash
sudo ingressctl publish artex 8787
sudo ingressctl status
```

验证：

```bash
curl --noproxy '*' --resolve \
  'artex.20050917.xyz:443:[240e:398:f11:c63b:d14c:310d:1d3b:f194]' \
  -I https://artex.20050917.xyz/login
```

不要把 8788 发布到 Caddy。应用自身有 `/login`；公网开放前确认登录密码不是
默认值，并保持 `.env` 为 `0600`。

## 停止与回滚

```bash
sudo ingressctl remove artex

sudo docker compose \
  --env-file /srv/containers/artex/.env \
  -f deploy/artex/compose.yaml stop
```

`stop` 保留容器、镜像、volume 和 `/srv/containers/artex`。不要使用
`docker compose down -v`、`docker system prune` 或 `docker volume prune`。
