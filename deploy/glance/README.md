# Glance 服务总览（`home.20050917.xyz`）

四台机器上跑的东西集中在一页看，顺带做八个监控点。选它不选 Homepage 的原因：
这台机器（`main`）上执行账户**没有 sudo、不在 docker 组**，而用户级 systemd 是活的，
所以只能跑「单个二进制 + 无数据库」的东西。Glance 是 Go 静态文件，常驻约 30–50MB。

- 二进制：`~/opt/glance/glance`（v0.8.8，来源 `glanceapp/glance` 的 `glance-linux-amd64.tar.gz`）
- 配置：本目录 `glance.yml`（进仓库）+ `auth.yml`（**不进仓库**，600）
- 运行：`systemctl --user` 单元 `~/.config/systemd/user/glance.service`
- 监听：`127.0.0.1:8770`
- 入口：Cloudflare 隧道 `laptop-main` 里 `home.20050917.xyz → http://127.0.0.1:8770`

## 页面上有什么

- **概览**：时钟、`main` 的本机资源、八个监控点、四组书签（对外入口 / main / 其他机器）。
- **机器**：四台纳管机器、团队项目仓库。

监控点（`monitor` widget，1 分钟缓存）：`pi`、`vault`、`api`、`teamup` 四个对外域名，
加本机 `30141` / `8090` / `8787` / `8222` 四个服务。`pi` 那条用了 `alt-status-codes: [307]`。

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

- 服务随 `calendar` 的用户会话启动；机器重启后要等桌面会话起来它才在。没开 linger（要 sudo）。
- 只探 HTTP 状态码，不探内容；`az` 的 VLESS（非 HTTP）和 `hw` 的 sshd 探不了。
- 监控请求从 `main` 发出，`127.0.0.1` 与本机服务同机，出口域名走 CF 绕一圈回来。