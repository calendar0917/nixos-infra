# Inbox hub（邮件聚合 + 推送通知）

在笔记本 `#main` 上常驻的两个小服务，都只监听 loopback，由现有的
`cloudflared-pi.service` 隧道对外，不开放任何入站端口：

| 服务 | 本地地址 | 公网入口（隧道 ingress，需在 Cloudflare 面板加） | 镜像体积 |
| --- | --- | --- | --- |
| SnappyMail 邮件聚合 | `http://127.0.0.1:24080` | `https://mail.20050917.xyz` | ~93MB（压缩） |
| ntfy 推送 | `http://127.0.0.1:2586` | `https://notify.20050917.xyz` | ~30MB（压缩） |

## 为什么是这两个

- **SnappyMail**：官方镜像自带 nginx + php-fpm，**不需要数据库容器**，一个容器
  就够。把一个登录主邮箱作为入口，再用「Add account」把其他邮箱挂到同一个界面，
  电脑和手机打开同一个网址（浏览器「添加到主屏幕」）。
- **ntfy**：备份失败、磁盘告警、站点 5xx 用一行 `curl` 推到手机锁屏。安卓有官方
  App（Play 版走 FCM，F-Droid 版走常连 WebSocket）。

上一版方案是 Cypht + MariaDB（2 个容器、约 1GB 盘、400–600MB 内存），因为不需要
RSS/GitHub 收件，换成 SnappyMail 后省掉整个数据库：

| | 旧（Cypht + MariaDB） | 现在（SnappyMail） |
| --- | --- | --- |
| 容器 | 3 | 2 |
| 磁盘（镜像） | 305MB + 104MB + 30MB | 93MB + 30MB |
| 内存 | 400–600MB | 预计 150–250MB |
| RSS / GitHub 通知 | 有 | **没有**（明确放弃） |

内存是估的，起服务后用 `docker stats --no-stream` 测真值再回填到本文件。

## 文件

- `compose.yaml`：SnappyMail + ntfy，两个容器，loopback 端口，私网互联。
- `.env.example`：版本化模板，没有真实口令。
- `.env`：本地运行文件，`0600`，已被 Git 忽略。这套栈的 `.env` 不含密钥（邮箱
  口令在 SnappyMail 数据卷里，ntfy 凭据在它自己的 auth 库里），但仍然不要提交。
- 数据在 Docker named volume（`inbox_snappymail_data`、`inbox_ntfy_cache`、
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

如果这台机器没有 Compose CLI 插件，用 `sudo docker-compose --env-file .env ...`，
不要为了改命令名另装一套 Compose。

起完自查（都在宿主机上，不需要隧道）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:24080/   # 期望 200/302
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2586/v1/health  # 期望 200
sudo docker stats --no-stream                                       # 看真实内存占用
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

## SnappyMail 首次配置（管理员面板）

容器起来后，入口脚本会生成管理员口令，存在数据卷里：

```bash
sudo docker compose --env-file .env exec snappymail \
  cat /var/lib/snappymail/_data_/_default_/admin_password.txt
```

打开 `https://mail.20050917.xyz/?admin`，用户名 `admin`，口令是上面那串。
进去按顺序做四件事：

1. **Security** → 改管理员口令；配完以后把 Admin panel 关掉
   （`application.ini` 的 `allow_admin_panel`，面板里有开关）。
2. **Domains** → Add Domain，为每个要挂的邮箱域名建一条配置（IMAP/SMTP
   主机、端口、SSL）。不同域名的账号必须先有 domain 配置，否则加不进来：
   - `qq.com`：IMAP `imap.qq.com:993`（SSL），SMTP `smtp.qq.com:465`（SSL）。
   - 学校邮箱：域名待确认，IMAP 是否开放也要先问信息化中心；不开放就邮箱侧设
     转发到 QQ 邮箱。
3. **Security** → 打开 「Allow additional accounts」，否则登录页不出现加账号入口。
4. 回前台 `https://mail.20050917.xyz/`，用**主邮箱**的地址和口令登录（QQ 这里要
   填授权码，不是登录密码），然后在登录页的「Add account」挂第二个邮箱。

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
- 数据备份（邮箱账号配置、管理员口令都在里面，**属于敏感数据**）：

```bash
sudo docker run --rm -v inbox_snappymail_data:/src:ro -v /var/backup:/dst \
  alpine tar czf /dst/inbox-snappymail-$(date +%F).tar.gz -C /src .
```

- 换镜像版本：改 `.env` 里的 `SNAPPYMAIL_IMAGE` 后 `up -d --force-recreate snappymail`。

## 局限（写清楚，别当成没有）

- 同一条隧道上已经有 vault/api/pi-web；这台笔记本关机或断网时，SnappyMail 和推送
  一起不可用。推送是"锦上添花"，不能当唯一告警通道。
- 手机上小屏体验一般，属于"能用"；它也不是 IM 聚合器，微信/QQ 消息永远不在这条链路上。
- 没有 RSS / GitHub 通知——这是这次换掉 Cypht 主动砍掉的功能，需要时另装阅读器。
- 邮箱口令由 SnappyMail 保存在数据卷里，所以这份备份等同于邮箱凭据，别乱放。
- ntfy 的自建实例 + FCM 组合依赖公共 ntfy.sh 转发；纯自建 WebSocket 更隐私但更耗电。