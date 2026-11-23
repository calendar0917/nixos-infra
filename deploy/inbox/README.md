# Inbox hub（邮件聚合 + 推送通知）

在笔记本 `#main` 上常驻的两个小服务，都只监听 loopback，由现有的
`cloudflared-pi.service` 隧道对外，不开放任何入站端口：

| 服务 | 本地地址 | 公网入口（隧道 ingress） | 镜像体积（压缩） |
| --- | --- | --- | --- |
| Gofer 邮件聚合 | `http://127.0.0.1:24080` | `https://mail.20050917.xyz` | 41.7 MiB（amd64，4 层） |
| ntfy 推送 | `http://127.0.0.1:2586` | `https://notify.20050917.xyz` | ~30MB |

## 为什么是这两个

- **Gofer**：Go 写的单容器（内嵌 SQLite，**不需要数据库容器**），把几个邮箱挂进
  同一个界面；htmx 前端、自带多套主题和主题生成器、原生简体中文，安卓上可以
  「安装成应用」。邮件、联系人、日历都在一个界面里。
- **ntfy**：备份失败、磁盘告警、站点 5xx 用一行 `curl` 推到手机锁屏。安卓有官方
  App（Play 版走 FCM，F-Droid 版走常连 WebSocket）。

选型经过了三次迭代，都记在这里，免得以后重走一遍：

| | Cypht + MariaDB | SnappyMail | **现在：Gofer** |
| --- | --- | --- | --- |
| 容器 | 3 | 2 | **2** |
| 磁盘（镜像，压缩） | 305 + 104 + 30 MB | 93 + 30 MB | **41.7 + 30 MiB** |
| 内存（实测） | 400–600MB | 57 + 14.5 MiB | 见下方实测 |
| 界面 | 旧 | 旧 | **现代，多主题** |
| 中文 | 有 | 有 | **原生** |
| RSS / GitHub 通知 | 有 | 没有（明确放弃） | 没有 |

换掉 Cypht 是因为不要 RSS/GitHub 收件，白搭一个 MariaDB；换掉 SnappyMail 是因为
界面太老，而 Gofer 在「轻」和「现代」两点上同时达标，且镜像比 SnappyMail 小一半
以上。

## 文件

- `compose.yaml`：Gofer + ntfy，两个容器，loopback 端口，私网互联。
- `.env.example`：版本化模板，没有真实口令。
- `.env`：本地运行文件，`0600`，已被 Git 忽略。这套栈的 `.env` 不含密钥（邮箱
  口令和加密密钥在 Gofer 数据卷里，ntfy 凭据在它自己的 auth 库里），但仍然不要
  提交。
- 数据在 Docker named volume（`inbox_gofer_data`、`inbox_ntfy_cache`、
  `inbox_ntfy_lib`），落在 NixOS 根分区的 `/var/lib/docker`，不要在 Arch 的
  `@home` 或 U 盘上。

## 起服务

```bash
cd ~/nixos-infra/deploy/inbox
sudo docker compose --env-file .env config --quiet
sudo docker compose --env-file .env pull
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env ps
```

从旧版（SnappyMail）换过来时，先 `down`（**不加 `-v`**）再 `pull`/`up -d`。
旧卷 `inbox_snappymail_data` 不会自动删除，里面只有管理员口令、没有任何邮箱
账号配置，确认不用了再手工 `docker volume rm inbox_snappymail_data`。

如果这台机器没有 Compose CLI 插件，用 `sudo docker-compose --env-file .env ...`，
不要为了改命令名另装一套 Compose。

起完自查（都在宿主机上，不需要隧道）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:24080/   # 期望 200/302
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2586/v1/health  # 期望 200
sudo docker stats --no-stream                                       # 看真实内存占用
```

## 端口为什么是 24080

Gofer 容器内监听 **8090**，官方 compose 也发布 `127.0.0.1:8090`。这台机器上
`127.0.0.1:8090` 已经属于 `api.20050917.xyz`（ axonhub 那套），所以宿主机侧映射
到 `24080`，容器内侧仍走 8090。隧道 ingress 那条 `mail → http://127.0.0.1:24080`
因此**不需要改**。

## 隧道 ingress（已配好，2026-11-23）

`config_src=cloudflare`，ingress 在云端，不在本仓库。两条规则已经用
`CLOUDFLARE_API_TOKEN` 通过 API 写进去（tunnel
`ecb1dbdf-d1fd-4ef8-9c03-cae65a62c690`，配置 `version 6`），DNS 也建了
两条指向 `ecb1dbdf-…cfargotunnel.com` 的 CNAME（proxied）：

| Subdomain | Domain | Service |
| --- | --- | --- |
| `mail` | `20050917.xyz` | `http://127.0.0.1:24080` |
| `notify` | `20050917.xyz` | `http://127.0.0.1:2586` |

同一条隧道上原有 `pi`（30141）、`vault`（8222）、`api`（8090）三条，未改动。
复核公网：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://notify.20050917.xyz/v1/health
curl -sS -o /dev/null -w '%{http_code}\n' https://mail.20050917.xyz/
```

**注意本机代理**：这台机器上 `HTTPS_PROXY=127.0.0.1:7897` 会让
`notify.20050917.xyz` 的 TLS 握手失败（直连正常，`mail` 不受影响）。用
`curl --noproxy '*'` 验证，或给代理加 DIRECT 规则。

## Gofer 首次配置（setup token）

Gofer 没有管理员面板口令，第一次打开网页时用**一次性 setup token** 建档，
token 只打印在容器日志里：

```bash
sudo docker compose --env-file .env logs gofer | grep -i 'setup token'
```

打开 `https://mail.20050917.xyz/`，粘上那串 token，设一个登录口令（强口令，
这是唯一入口），完成后在 **Settings → Security** 里开 TOTP 两步验证。token 丢
了或过期可以换一个：

```bash
sudo docker compose --env-file .env exec gofer gofer auth setup-token rotate
```

然后在 **Settings → Accounts** 里加邮箱。要准备的东西（缺一个都加不进去）：

1. **QQ 邮箱**：走 IMAP/SMTP，主机 `imap.qq.com:993`（SSL）、
   `smtp.qq.com:465`（SSL）。口令要填**授权码**，不是 QQ 登录密码，在 QQ 邮箱
   「设置 → 账户 → POP3/IMAP/SMTP」里开 IMAP 并生成授权码。
2. **学校邮箱**：域名和 IMAP 是否开放要先问信息化中心；不开放就邮箱侧设转发到
   QQ 邮箱，聚合照样能收到。
3. Gmail / Outlook 要用自己的 OAuth 应用凭据（作者尚未提供公共应用），暂时不用。

加完账号后，安卓手机用 Chrome 打开同一个网址 → 菜单「安装应用」，桌面多一个
图标；iOS 用 Safari「添加到主屏幕」。

## ntfy 的账号与令牌

`NTFY_AUTH_DEFAULT_ACCESS=deny-all` 意味着匿名不能读写任何主题。建用户和令牌
（每条都要 `sudo docker exec -it inbox-ntfy-1 ...`，容器名以 `docker compose ps`
为准）：

```bash
# 1) 建一个接收账号
sudo docker exec -it inbox-ntfy-1 ntfy user add --role=admin teamup-alerts
# 2) 建一个发送令牌（脚本用）
sudo docker exec -it inbox-ntfy-1 ntfy token add --label=scripts teamup-alerts
```

发送端只用令牌，不保存账号口令：

```bash
curl -H "Authorization: Bearer <token>" \
     -d "teamup 备份失败" https://notify.20050917.xyz/teamup-alerts
```

手机 App 里填服务器 `https://notify.20050917.xyz`，用第 1 步的账号登录，再
订阅 `teamup-alerts` 主题。想让 App 走 FCM（不常连、省电），把 compose 里的
`NTFY_UPSTREAM_BASE_URL: https://ntfy.sh` 取消注释；代价是消息元数据经公共
ntfy.sh 中转。

## 回滚与备份

- 停服务：`sudo docker compose --env-file .env down`（**不要**加 `-v`，会删数据）。
- 数据备份（邮箱账号配置、加密密钥、setup token 状态都在里面，**属于敏感数据**，
  备份前先 `down`，Gofer 运行中复制可能拿到半写状态）：

```bash
sudo docker run --rm -v inbox_gofer_data:/src:ro -v /var/backup:/dst \
  alpine tar czf /dst/inbox-gofer-$(date +%F).tar.gz -C /src .
```

- 换镜像版本：改 `.env` 里的 `GOFER_IMAGE` 后 `up -d --force-recreate gofer`；
  升级前先备份卷、读 release notes（还没到 1.0，版本间有破坏性改动，回退需要对应
  版本的备份）。建议先用 `GOFER_PREVENT_STORAGE_CONVERSION: "true"` 挡住自动
  存储迁移。

## 局限（写清楚，别当成没有）

- **Gofer 还没到 1.0**：v0.25.0（2026-11-16），单人维护，2026-05 才建仓，26 个
  未关 issue。能用，但不要当成不会变的东西；升级前备份，版本别跟 `latest`。
- 同一条隧道上已经有 vault/api/pi-web；这台笔记本关机或断网时，Gofer 和推送
  一起不可用。推送是"锦上添花"，不能当唯一告警通道。
- 它保存你的邮箱凭据（加密后存在数据卷里），所以这份备份等同于邮箱凭据，别乱放。
- 它也不是 IM 聚合器，微信/QQ 消息永远不在这条链路上；也没有 RSS。
- 没有 RSS / GitHub 通知——这是换掉 Cypht 时主动砍掉的功能，需要时另装阅读器。
- ntfy 的自建实例 + FCM 组合依赖公共 ntfy.sh 转发；纯自建 WebSocket 更隐私但更耗电。

## 镜像记录

| 镜像 | tag | 平台 | 压缩体积 |
| --- | --- | --- | --- |
| Gofer | `ghcr.io/cristianadrielbraun/gofer:0.25.0` | amd64（manifest `sha256:d5bb38a5…`） | 43,711,160 B（41.7 MiB，4 层） |
| ntfy | `binwiederhier/ntfy:v2.37.2` | amd64 | ~30MB |