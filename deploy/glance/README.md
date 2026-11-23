# Glance 服务总览（`home.20050917.xyz`）

> **2026-11-23 起已被 Homepage 取代**（`deploy/homepage/`）：隧道 `home` 那条 ingress 已指向
> `127.0.0.1:3000`，`glance.service` 还在跑但没人访问，留着当回滚。要看页面改 `deploy/homepage/`。

四台机器上跑的东西集中在一页看，顺带做八个监控点。Glance 是 Go 静态文件，常驻约 30–50MB。

选 Glance 而不是 Homepage，真实原因是省事：单个二进制、无数据库、`systemctl --user` 直起，
不用向用户要一条 sudo 命令。**这不是「没有 sudo 所以做不到」**——Homepage 是 Next.js 应用，
`main` 上 docker 是 active 且开机自启，照 `deploy/axonhub` 的惯例写个 compose 就能跑，
代价是需要用户执行一次 `sudo docker compose up -d`（单容器，常驻约 150–250MB，端口 3000）。
界面观感、服务网格、书签的成熟度上 Homepage 确实更好；要换就照这个路子重做，
隧道里 `home` 那条 ingress 从 `127.0.0.1:8770` 改成 `127.0.0.1:3000` 即可。

- 二进制：`~/opt/glance/glance`（v0.8.8，来源 `glanceapp/glance` 的 `glance-linux-amd64.tar.gz`）
- 配置：本目录 `glance.yml`（进仓库）+ `auth.yml`（**不进仓库**，600）
- 运行：`systemctl --user` 单元 `~/.config/systemd/user/glance.service`
- 监听：`127.0.0.1:8770`
- 入口：Cloudflare 隧道 `laptop-main` 里 `home.20050917.xyz → http://127.0.0.1:8770`
- 四台详情：本目录 `fleet-json.py`（`fleet-json.service`，`127.0.0.1:8771`）把
  `scripts/fleet-status --json` 的结果转成 HTTP，给「机器」页的 `custom-api` widget 用

## 页面上有什么

- **概览**：时钟、`main` 的本机资源、八个监控点、三组书签（对外域名 / main 本机 / 其他机器）。
- **机器**：四台的实时状态（uptime / 负载 / 磁盘 / 失败单元，来自 `fleet-status`）、
  四台入口、不纳管的两台 pve、团队项目仓库。

监控点（`monitor` widget，1 分钟缓存）：`pi`、`vault`、`api`、`teamup` 四个对外域名，
加本机 `30141` / `8090` / `8787` / `8222` 四个服务。`pi` 那条用了 `alt-status-codes: [307]`。

## 配置里踩过的坑

- `bookmarks` 的分组和链接字段都叫 **`title`**，不是 `name`。写成 `name` 时 Glance 不报错，
  但渲染出来是空链接——只有 `<a href>` 没有文字，分组标题也不显示。已按 v0.8.8 文档改正。
- 字段名以当时版本的文档为准，不要凭记忆写：
  `curl -sS https://raw.githubusercontent.com/glanceapp/glance/main/docs/configuration.md`，
  或对照 `~/opt/glance/glance -config … config:validate`（它只校验语法，不校验键名是否生效）。

## 四台详情怎么来的（`fleet-json` + `custom-api`）

Glance 自带的 `server-stats` 只读**本机**的 `/proc`，所以 nixos / az / hw 的 uptime、负载、
磁盘它拿不到——页面上原本只有 `main`。补法是绕一圈：

1. `scripts/fleet-status --json` 走 ssh 探四台，输出一个数组（新增的 `--json` 模式，
   不带参数时仍是原来那张表格，CLI 用法不变）。
2. `deploy/glance/fleet-json.py` 起在 `127.0.0.1:8771`，后台每 120 秒预热一次，请求只读缓存、
   立即返回（实测 1ms）。不能每个请求同步跑 ssh：四台最坏各 8 秒，Glance 会等到超时。
3. 「机器」页的 `custom-api` widget `GET /fleet.json`，用 Go 模板渲染成四行状态。
   连着两次探测失败也只会显示上一次的结果，不会白屏（缓存最多容忍 15 分钟）。

```bash
# 装/更新这个单元（和 glance.service 一样是用户级）
cp deploy/glance/fleet-json.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now fleet-json.service
curl -sS http://127.0.0.1:8771/fleet.json | python3 -m json.tool
```

## 为什么只监控这些

nixos 上的 artex `8787`、bot `8799` 只绑 `127.0.0.1`，从 `main` 走 tailscale 连不上
（实测 `http://100.107.6.15:8787` 返回 000），所以它们只出现在书签里，不做探活。
要让它们也能探活，得在 nixos 上把监听地址改到 `tailscale0` 或加 Caddy 反代——没做。

## 改动与运维

```bash
# 改完 glance.yml 先校验，再重启
~/opt/glance/glance -config ~/nixos-infra/deploy/glance/glance.yml config:validate
systemctl --user restart glance.service
systemctl --user status glance.service --no-pager
journalctl --user -u glance -n 30 --no-pager
```

页面 HTML 是壳，内容走 `GET /api/pages/<slug>/content/`（要带登录 cookie）。
所以从命令行验证不要只看首页 200，要看这个接口：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"username":"calendar","password":"<口令>"}' \
  -c /tmp/gc.txt https://home.20050917.xyz/api/authenticate
curl -s -b /tmp/gc.txt https://home.20050917.xyz/api/pages/home/content/ | grep -c '>OK<'
```

## 鉴权（一个坑）

Glance 0.8.8 的 `password` 字段实测**只吃明文**：`password:hash` 生成的 bcrypt 哈希
（无论加不加引号、走不走 `${ENV}` 展开）登录一律 401，改明文立刻 200。
所以 `auth.yml` 里是明文口令，权限 600、`.gitignore` 排除、不进 git。
代价是这台机器上能读 `~/.config` 的人能读到它——和 `main` 上其它本地凭据一个量级。

换口令：改 `auth.yml` 里的 `password`，重启服务。换会话密钥：`glance secret:make` 写回 `secret-key`，
会让所有已登录会话失效。

从零重建 `auth.yml`：

```bash
cp auth.yml.example auth.yml && chmod 600 auth.yml
~/opt/glance/glance secret:make    # 填 secret-key
# password 直接填明文
```

## 回滚

```bash
systemctl --user disable --now glance.service
```

再删隧道里 `home.20050917.xyz` 那条 ingress（改 `version` 时把这条去掉）和对应 CNAME，
最后删 `~/.config/systemd/user/glance.service`、`~/opt/glance/`。已生成的会话 cookie 会随
`secret-key` 消失而失效。

## 已知局限

- 两个单元（`glance`、`fleet-json`）都随 `calendar` 的用户会话启动；机器重启后要等桌面会话
  起来才在。没开 linger（要 `sudo loginctl enable-linger calendar`）。
- 监控只探 HTTP 状态码、不探内容；`az` 的 VLESS（非 HTTP）和 `hw` 的 sshd 探不了。
- 「机器」页的详情依赖本机能 ssh 到四台（`BatchMode`、密钥无口令）；ssh 一断就退化成旧数据。
- 监控请求从 `main` 发出，`127.0.0.1` 与本机服务同机，出口域名走 CF 绕一圈回来。