# Inbox hub（邮件/RSS 聚合 + 推送通知）

笔记本 `#main` 上的两个常驻小服务，都只监听 loopback，由现有的
`cloudflared-pi.service` 隧道对外，不开放任何入站端口：

| 服务 | 本地地址 | 公网入口（隧道 ingress，需在 Cloudflare 面板加） |
| --- | --- | --- |
| Cypht 邮件聚合 | `http://127.0.0.1:24080` | `https://mail.20050917.xyz` |
| ntfy 推送 | `http://127.0.0.1:2586` | `https://notify.20050917.xyz` |

## 为什么是这两个

- **Cypht**：把 QQ 邮箱、学校邮箱等 IMAP 账号合成一个收件箱，顺带 RSS/Atom
  和 GitHub 通知，电脑和手机打开同一个网页（加到主屏就是 PWA），不存在多端
  同步问题。官方镜像自带 nginx + PHP，不需要在宿主机装 PHP。
- **ntfy**：备份失败、磁盘告警、站点 5xx 用一行 `curl` 推到手机锁屏。安卓有
  官方 App（Play 版走 FCM，F-Droid 版走常连 WebSocket）。Gotify 没有 iOS
  客户端，这里统一用 ntfy。

## 文件

- `compose.yaml`：MariaDB + Cypht + ntfy，三个容器，loopback 端口，私网互联。
- `.env.example`：版本化模板，没有真实口令。
- `.env`：本地运行文件，`0600`，已被 Git 忽略。**不要提交、不要贴进对话。**
- 数据在 Docker named volume（`inbox_cypht_db`、`inbox_cypht_users`、
  `inbox_ntfy_cache`、`inbox_ntfy_lib`），落在 NixOS 根分区的
  `/var/lib/docker`，不要在 Arch 的 `@home` 或 U 盘上。

## 起服务

```bash
cd ~/nixos-infra/deploy/inbox
sudo docker compose --env-file .env config --quiet
sudo docker compose --env-file .env pull
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env ps
```

如果这台机器没有 Compose CLI 插件，用 `sudo docker-compose --env-file .env ...`，
不要为了改命令名另装一套 Compose。

起完自查（都在宿主机上，不需要隧道）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:24080/   # 期望 200/302
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2586/   # 期望 200
```

## 隧道 ingress（Cloudflare 面板）

`config_src=cloudflare`，ingress 在云端，不在本仓库。在
Network → Tunnels → `laptop-main` → Public Hostnames 加两条：

| Subdomain | Domain | Service |
| --- | --- | --- |
| `mail` | `20050917.xyz` | `http://127.0.0.1:24080` |
| `notify` | `20050917.xyz` | `http://127.0.0.1:2586` |

DNS 会自动生成 CNAME。加完从任意网络验证：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://notify.20050917.xyz/v1/health
curl -sS -o /dev/null -w '%{http_code}\n' https://mail.20050917.xyz/
```

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

## Cypht 的邮箱账号

登录 `https://mail.20050917.xyz`（账号口令见 `.env` 的 `CYPHT_AUTH_*`），在
Settings → Accounts 里逐个加 IMAP/SMTP：

- QQ 邮箱：需要先在 QQ 邮箱网页版开启 IMAP，并使用**授权码**而不是登录密码；
  服务器 `imap.qq.com:993`（SSL）/ `smtp.qq.com:465`（SSL）。
- 学校邮箱：是否开放 IMAP 要先确认；不开放就走不通，替代做法是邮箱侧设置
  转发到 QQ 邮箱。

## 回滚与备份

- 停服务：`sudo docker compose --env-file .env down`（**不要**加 `-v`，会删数据）。
- 数据备份（Cypht 配置和账号列表最重要）：

```bash
sudo docker run --rm -v inbox_cypht_users:/src:ro -v /var/backup:/dst \
  alpine tar czf /dst/inbox-cypht-users-$(date +%F).tar.gz -C /src .
```

- 账号口令忘了只能改 `.env` 后重建容器：`sudo docker compose --env-file .env up -d --force-recreate cypht`。

## 局限（写清楚，别当成没有）

- 同一条隧道上已经有 vault/api/pi-web；这台笔记本关机或断网时，Cypht 和推送一起不可用。推送是"锦上添花"，不能当唯一告警通道。
- Cypht 的小屏体验一般，手机上更多是"能用"；它也不是 IM 聚合器，微信/QQ 消息永远不在这条链路上。
- ntfy 的自建实例 + FCM 组合依赖公共 ntfy.sh 转发；纯自建 WebSocket 更隐私但更耗电。