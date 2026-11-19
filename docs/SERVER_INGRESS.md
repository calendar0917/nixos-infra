# 小主机公网入口：Cloudflare IPv6 DDNS、ACME 与 Caddy

本文对应 `nixosConfigurations.nixos`（KOLOE 小主机）的第三阶段。目标是：

- `nixos.20050917.xyz` 自动跟随小主机的公网 IPv6。
- 使用 Cloudflare DNS-01 自动申请和续期 `*.20050917.xyz`。
- 宿主机 Caddy 作为唯一的 HTTPS 入口。
- 普通 Docker 服务通过 Compose + `ingressctl` 上线或下线，不重新执行
  `nixos-rebuild switch`。

本文同时区分“仓库静态验证”和“实机/公网验收”。没有真实 Token、Zone ID、
证书签发记录和校外网络测试时，不能把静态构建通过写成公网入口已经可用。

相关文件：

| 文件 | 作用 |
| --- | --- |
| `hosts/nixos/ddns.nix` | DDNS systemd service/timer、运行时目录 |
| `hosts/nixos/scripts/cf-ddns.py` | IPv6 选择与 Cloudflare AAAA 更新 |
| `hosts/nixos/ingress.nix` | Caddy、ACME 通配符证书、80/443 防火墙、`ingressctl` 包装 |
| `hosts/nixos/frp.nix` | 公网 IPv4 的 `frpc-artex` 隧道客户端 |
| `hosts/nixos/scripts/ingressctl.py` | 动态站点片段、证书检查、Caddy 校验和 reload |
| `tests/test_server_ingress.py` | DDNS/Caddy/NixOS 静态和事务回归 |
| `scripts/check-server-ingress` | 上述测试的唯一入口 |

## 1. 运行时边界

```text
/etc/cloudflare/
├── token                 # 真实 Cloudflare API Token（0600 root:root）
├── zone-id               # Cloudflare Zone ID（0600 root:root）
└── ddns.env              # 可选：CF_DDNS_PROXY=...
/etc/caddy/
├── caddy_config          # NixOS 生成，指向 Nix store
└── sites-enabled/        # 运行时动态路由，不是 Nix store 链接
    ├── app.caddy
    └── git.caddy
/var/lib/acme/20050917.xyz/
├── fullchain.pem         # ACME 自动管理，不提交 Git
├── key.pem
└── acme-success          # 成功签发标记；ingressctl 发布前检查
```

- `/etc/cloudflare` 由 NixOS tmpfiles 创建为 `0700 root:root`；两个凭据文件由
  管理员在目标机本地安装，不进入 Git、Nix store、flake 求值或 systemd
  `ExecStart`。
- `/etc/caddy/sites-enabled` 由 tmpfiles 创建，属于运行时状态。Caddy 主配置只
  通过 `import /etc/caddy/sites-enabled/*.caddy` 引入它。
- `/var/lib/acme` 由 NixOS `security.acme` 管理。证书私钥、证书内容和 ACME
  账户材料都不得复制到仓库。
- 宿主机 Caddy 直接监听 80/443；不是 Docker 容器，不通过 Docker `ports` 暴露
  入口。

## 2. Cloudflare Token 与 Zone ID

### 2.1 创建受限 Token

在 Cloudflare Dashboard 创建 **API Token**，不要使用 Global API Key：

```text
Zone → Zone → Read
Zone → DNS → Edit

Resources:
Include → Specific zone → 20050917.xyz
```

该 Token 同时供 DDNS 和 ACME DNS-01 使用。它的权限只覆盖
`20050917.xyz`，不能修改其他 Zone，也不应开放账号级权限。

### 2.2 在目标机安装

不要在命令行参数、聊天、Git 或 shell history 中写入真实 Token。使用
`sudoedit` 交互输入：

```bash
sudo install -d -m 0700 -o root -g root /etc/cloudflare
sudo install -m 0600 -o root -g root /dev/null /etc/cloudflare/token
sudo install -m 0600 -o root -g root /dev/null /etc/cloudflare/zone-id

sudoedit /etc/cloudflare/token
sudoedit /etc/cloudflare/zone-id
```

检查权限和存在性，不输出文件内容：

```bash
sudo stat -c '%a %U:%G %n' /etc/cloudflare /etc/cloudflare/token /etc/cloudflare/zone-id
```

Zone ID 在 Cloudflare 域名概览页的 **Zone ID** 处获取，是 32 位十六进制
字符串。不要用 Zone 名称或邮箱代替。

DDNS 的 service 通过 systemd `LoadCredential` 读取：

```text
token:/etc/cloudflare/token
zone-id:/etc/cloudflare/zone-id
```

ACME 的 `security.acme` 通过 `credentialFiles` 把同一 Token 作为
`CLOUDFLARE_DNS_API_TOKEN_FILE` 加载给 lego。两个消费者都不需要把 Token
写入 Nix store。

## 3. Cloudflare DNS 设计

### 3.1 必须存在的 AAAA

```text
Type: AAAA
Name: nixos
Content: 当前小主机公网 IPv6
Proxy: DNS only
TTL: 120
```

DDNS 自动维护这条精确记录。首次真实写入前，先在 Dashboard 或 API 只读查询确认：

```bash
dig AAAA nixos.20050917.xyz
```

不要通过 Cloudflare 橙云代理连接 SSH。`nixos.20050917.xyz` 是保留名称，
`ingressctl` 不会覆盖它。

### 3.2 建议的通配符 CNAME

管理员在 Cloudflare Dashboard 只创建一次：

```text
Type: CNAME
Name: *
Target: nixos.20050917.xyz
Proxy: DNS only
```

这样 `app.20050917.xyz`、`git.20050917.xyz` 等自动指向小主机，不需要为每个
业务域名调用 Cloudflare API。精确记录优先于通配符。

约束：

- 不修改域名根记录 `20050917.xyz`。
- 不修改 MX、TXT、NS 等其他记录。
- 不启用橙云代理。
- 如果 `nixos` 已有同名 CNAME、重复 AAAA、被代理的 AAAA 或其他冲突，DDNS
  明确失败并保留原记录，不自动删除或覆盖。
- 不通过 Cloudflare 普通 HTTP 代理转发 SSH。

## 4. IPv6 DDNS

### 4.1 地址来源

`cf-ddns.py` 不调用外部 “what is my IP” 服务。流程是：

1. `ip -j -6 route show default` 获取当前 IPv6 默认路由。
2. 排除 `lo`、Docker、veth、Tailscale、TUN、WireGuard、虚拟机等虚拟接口。
3. 在剩余物理接口中按 NetworkManager 路由 `metric` 选择最低优先级出口。
4. 两个物理接口 metric 相同视为歧义，拒绝更新。
5. `ip -j -6 addr show dev <interface>` 只查看该出口的地址。
6. 排除 link-local、ULA、multicast、loopback、tentative、deprecated 和
   temporary 隐私地址。
7. 只保留有效的稳定全球单播 IPv6；候选不唯一时拒绝更新。
8. 没有物理默认路由或没有合法地址时，不修改 Cloudflare。

不会为了 DDNS 关闭 IPv6 privacy extension、防火墙、Tailscale，亦不会修改
NetworkManager 地址分配或系统路由策略。

### 4.2 Cloudflare 更新规则

- 读取本地 Zone ID。
- 查询精确匹配的 `nixos.20050917.xyz` 记录。
- 不存在则创建 AAAA，TTL 120，`proxied=false`。
- 已存在且 IPv6 未变化：不发送写入请求。
- IPv6 变化：只 PATCH 该记录。
- 存在多条 AAAA、同名 CNAME、被代理记录或异常内容：报错并要求人工检查。
- API 超时、HTTP 429、5xx：本轮失败，下一次 timer 再试；不会无限重试或
  在本地循环写请求。
- 日志不打印 Token。Token 只存在于 systemd credential 和本进程内存中。

### 4.3 代理选择

默认直连 Cloudflare API。若当前网络必须经 Mihomo，使用运行时文件，不需要
`nixos-rebuild`：

```bash
sudoedit /etc/cloudflare/ddns.env
```

内容只能是：

```text
CF_DDNS_PROXY=http://127.0.0.1:7897
```

脚本会拒绝其他代理地址。删除该行或清空值即恢复直连。修改后下一次 timer
自动生效；需要立即验证时：

```bash
sudo systemctl start cloudflare-ddns.service
```

该模式只使用 loopback HTTP 代理，不启用 TUN，不修改系统路由。

### 4.4 systemd 服务与定时器

```text
cloudflare-ddns.service   oneshot
cloudflare-ddns.timer     开机约 2 分钟后首次检查，此后每 5 分钟
```

Timer 有 45 秒随机延迟和 30 秒精度，避免固定瞬间请求；失败由下一轮重试。
服务使用 `DynamicUser`、`LoadCredential`、严格文件系统保护和空 capability
集合，不依赖图形登录，也不阻塞系统启动。

常用命令：

```bash
sudo systemctl start cloudflare-ddns.service
systemctl status cloudflare-ddns.timer
journalctl -u cloudflare-ddns.service -n 50
systemctl list-timers --all
```

核对真实 AAAA 与默认路由：

```bash
ip -6 address
ip -6 route
ip -6 route show default
ip -6 route get 2606:4700:4700::1111
dig AAAA nixos.20050917.xyz
```

日志中的 `selected interface=... address=...` 应与 `ip -6 addr` 和 Cloudflare
记录一致。`proxy=direct` 或 `127.0.0.1:7897` 只表示 API 出口，不代表公网
入站已经可达。

## 5. ACME 通配符证书

`ingress.nix` 使用 NixOS 原生 `security.acme` 和 lego 的 Cloudflare DNS
provider，不使用 Caddy Cloudflare 插件，也不通过 xcaddy 自行编译。

```nix
security.acme.certs."20050917.xyz" = {
  domain = "*.20050917.xyz";
  dnsProvider = "cloudflare";
  group = "caddy";
  dnsAuthoritativePropagationCheck = true;
  dnsRecursivePropagationCheck = true;
  credentialFiles."CLOUDFLARE_DNS_API_TOKEN_FILE" = "/etc/cloudflare/token";
  reloadServices = [ "caddy.service" ];
};
```

- 只申请 `*.20050917.xyz`，暂不包含 apex `20050917.xyz`。
- 使用 DNS-01，不需要公网 HTTP-01 验证。
- 不关闭 DNS 传播检查。nixpkgs 已把原来的单个 `dnsPropagationCheck` 拆成
  authoritative 和 recursive 两项，这里两项都保持 `true`，与拆分前的行为一致。
- 证书和私钥由 systemd 自动申请/续期，路径为
  `/var/lib/acme/20050917.xyz/`。
- 私钥不进入 Nix store；文件属组为 `caddy`，Caddy 通过组成员关系读取。
- 续期成功后自动 reload Caddy；失败不会删除上一张可用证书。
- `acme-success` 标记只有成功签发后才存在。`ingressctl publish` 在标记缺失时
  拒绝发布，避免把 ACME 自签占位证书当成公网证书。

当前没有编造 ACME 联系邮箱，因此使用模块允许的无邮箱配置。建议日后在
`security.acme.defaults.email` 或该 cert 上配置真实邮箱；这是 NixOS 配置变更，
需要一次 switch。邮箱只用于 CA 通知，不是 DNS 凭据。

检查证书：

```bash
sudo ls -l /var/lib/acme/20050917.xyz/
sudo stat -c '%a %U:%G %n' /var/lib/acme/20050917.xyz /var/lib/acme/20050917.xyz/*
systemctl status 'acme-*.service' 'acme-*.timer'
journalctl -u 'acme-order-renew-20050917.xyz.service' -n 100
sudo -u caddy test -r /var/lib/acme/20050917.xyz/fullchain.pem
sudo -u caddy test -r /var/lib/acme/20050917.xyz/key.pem
```

通配符只覆盖一层子域名，例如 `app.20050917.xyz`，不覆盖
`a.b.20050917.xyz`。`ingressctl` 因此只接受一个标签。

## 6. Caddy 宿主机入口

`services.caddy.enable = true`，由 NixOS 启动，不使用 Docker。主配置由 NixOS
生成在 `/etc/caddy/caddy_config`，关键片段：

```caddyfile
{
    admin 127.0.0.1:2019
}

import /etc/caddy/sites-enabled/*.caddy

http://127.0.0.1:2080 {
    bind 127.0.0.1
    respond /health 200
    respond 404
}
```

- 业务站点不写入 `services.caddy.virtualHosts`，否则每次新增服务都要 switch。
- `sites-enabled` 是运行时可写目录，不是 Nix store 的只读链接。
- 健康检查只监听 `127.0.0.1:2080`，不开放防火墙，目录为空时 Caddy 仍可启动。
- Admin API 明确限制在 `127.0.0.1:2019`，不暴露公网。
- 不使用 `on_demand_tls`，不启用匿名管理面板。
- 每个动态站点统一使用：

```caddyfile
app.20050917.xyz {
    tls /var/lib/acme/20050917.xyz/fullchain.pem /var/lib/acme/20050917.xyz/key.pem
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
```

这里的 `127.0.0.1` 是宿主机 loopback，不是容器内部。

### 6.1 防火墙与端口

`networking.firewall.allowedTCPPorts = [ 80 443 ]`。

`allowedTCPPorts` 会同时放行 IPv4 和 IPv6，**不是 IPv6-only**。本项目没有
依赖“校园网没有公网 IPv4”的假设，也没有通过 `trustedInterfaces` 整体信任
校园网物理接口。

本阶段：

- 不开放 UDP 443 / HTTP3。
- 不通过 Docker `ports` 暴露 80/443。
- 不开放 7897、9090、2375、2376、5432、3306、6379、27017 等端口。
- 保持 nftables 开启。

首次真正开启 80/443 前，必须确认用户具备 SSH 公钥、Tailscale、本地 TTY 和
旧 NixOS generation 回退路径。

## 7. `ingressctl`

命令由 `hosts/nixos/ingress.nix` 打包为系统命令 `ingressctl`。

```bash
ingressctl list
ingressctl status
sudo ingressctl check
sudo ingressctl publish app 8080
sudo ingressctl publish app 8081 --force
sudo ingressctl remove app
```

`publish` 生成 `/etc/caddy/sites-enabled/<name>.caddy`：

```caddyfile
# Managed by ingressctl; manual changes will be overwritten.

app.20050917.xyz {
    tls /var/lib/acme/20050917.xyz/fullchain.pem /var/lib/acme/20050917.xyz/key.pem
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
```

### 7.1 接受范围

- `name` 只能是一个小写 DNS 标签：字母、数字、连字符，1–63 字符。
- 域名固定为 `<name>.20050917.xyz`，不接受完整任意域名。
- `nixos` 是保留名称，不能被发布工具覆盖。
- 端口必须在 `1024–65535`，并且拒绝 Caddy admin、Docker API、Mihomo、
  数据库等基础服务端口。
- 上游固定为 `127.0.0.1:<port>`，不接受 URL、Docker socket、Unix socket、
  `0.0.0.0` 或公网地址。
- 不执行用户传入的 Caddy 指令、模板、路径或 shell 命令。
- 同名路由默认拒绝覆盖；确需改端口使用 `--force`。
- 不自动添加 Basic Auth。敏感应用是否适合公开，必须在部署时单独决定。

### 7.2 发布事务

`publish` 的顺序：

1. 获取 `/etc/caddy/sites-enabled/.ingressctl.lock` 排他锁。
2. 检查运行目录、父目录和目标文件权限，拒绝符号链接劫持。
3. 检查 ACME 证书、`acme-success` 标记和 Caddy 组读取权限。
4. 在目标目录创建临时文件并 `fsync`，原子替换站点片段。
5. 执行 `caddy validate --config /etc/caddy/caddy_config --adapter caddyfile`，
   其中包含 import 的所有站点。
6. 校验失败：恢复旧文件；旧文件不存在则移除新文件。
7. 校验成功才执行 `systemctl reload caddy`。
8. reload 失败：恢复旧文件并再次尝试 reload 旧配置。
9. 任一步失败都输出明确错误，不打印“发布成功”。
10. 只有 Caddy 确实接受新配置才报告成功。

`remove` 只移除对应 `.caddy` 文件，不删除 Docker 容器、Volume、镜像、
持久化数据或 Cloudflare DNS。删除事务同样校验并 reload，失败会恢复旧文件。

> Caddy reload 成功只代表宿主机接受了配置，不代表公网可达。公网测试必须
> 单独记录。

### 7.3 status / check

```bash
ingressctl list      # 列出运行时路由，普通用户可执行
ingressctl status    # 路由和 Caddy 服务状态；证书文件检查需 root
sudo ingressctl status  # 完整证书和证书文件权限检查
sudo ingressctl check
```

`status` 在普通用户下会提示证书文件检查需要 root；`check` 和所有变更命令
要求 root。`check` 只验证，不写文件、不 reload。

## 8. 新 Docker 服务标准流程

新增普通业务服务默认**不修改** `hosts/nixos/*.nix`，也不执行
`nixos-rebuild switch`：

```text
1. 在 deploy/<service>/ 编写 Compose
2. 在 /srv/containers/<service>/ 准备数据目录
3. docker compose up -d
4. 验证 127.0.0.1:<port>
5. ingressctl publish <service> <port>
6. Caddy 校验并 reload
7. 校外验证 HTTPS
```

示例：

```bash
cd deploy/myapp

sudo docker compose config -q
sudo docker compose up -d

curl --noproxy '*' http://127.0.0.1:8080/

sudo ingressctl publish myapp 8080

curl -I https://myapp.20050917.xyz
```

要求：

- 业务容器只绑定 `127.0.0.1:<宿主机端口>`，不直接暴露公网容器端口。
- 持久化数据仍在 `/srv/containers/<service>/`。
- 不使用 host network，不开放 Docker daemon，不共享其他应用的数据库凭据。
- 不在 NixOS Host 模块里为每个业务服务增加端口。
- Compose 的 restart policy 负责已部署容器的开机恢复；新增或修改 Compose
  仍需再次 `docker compose up -d`，不会因文件存在于 Git 自动部署。

只有变更 Docker Engine、宿主机防火墙、Caddy 基础服务、系统软件、证书基础
策略等 NixOS 级配置时，才需要重新 switch。

## 9. 删除、下线与回滚

### 9.1 下线一个域名（保留容器和数据）

```bash
sudo ingressctl remove myapp
```

它只删除 `/etc/caddy/sites-enabled/myapp.caddy` 并 reload Caddy。

### 9.2 停止业务容器（保留镜像、Volume 和数据）

```bash
cd deploy/myapp
sudo docker compose down
```

不要使用 `docker compose down -v`、`docker system prune`、
`docker volume prune`，除非用户针对具体数据明确授权。

### 9.3 路由回滚

`ingressctl` 的每次 publish/remove 都是事务式操作；校验或 reload 失败会自动
恢复旧片段。如果人工需要恢复，编辑运行时片段不属于推荐流程，应使用：

```bash
sudo ingressctl publish myapp 8080 --force
sudo ingressctl check
```

Caddy 配置仍可回滚到 NixOS generation 中的主配置；业务路由文件独立于
generation，不会被系统回滚删除。

### 9.4 系统回滚

```bash
sudo nixos-rebuild switch --rollback
# 或仅准备下次启动回退
sudo nixos-rebuild boot --rollback
```

回滚 NixOS generation 不会删除 `/etc/caddy/sites-enabled`、Docker 数据或
`/var/lib/acme`。回滚后仍需检查新 generation 是否留下 Caddy unit/ACME
服务差异，不要盲目删除旧 generation。

## 10. 验收：必须分开记录的状态

以下状态互不等价：

1. 主机有全球单播 IPv6。
2. 主机可通过 IPv6 出站。
3. Cloudflare AAAA 已更新。
4. 校外网络可主动连接 IPv6 TCP 80/443。
5. Caddy HTTPS 正常。
6. Docker 上游正常响应。

静态/构建通过不能证明 4、5、6。验收命令：

```bash
ip -6 address
ip -6 route
ip -6 route get 2606:4700:4700::1111
dig AAAA nixos.20050917.xyz
dig AAAA app.20050917.xyz

systemctl status cloudflare-ddns.timer
journalctl -u cloudflare-ddns.service -n 50
systemctl status caddy
systemctl list-timers --all
sudo ingressctl status
sudo ingressctl check

sudo ss -lntup
sudo nft list ruleset
```

从真正的校外 IPv6 网络测试（不能只在同一校园网内部）：

```bash
curl -6 -I https://app.20050917.xyz
```

如果校外无法主动连接，依次检查：

- AAAA 是否指向当前接口地址。
- 校园网入站 ACL 是否封锁 TCP 80/443。
- 宿主机 nftables 是否放行。
- Caddy 是否监听 80/443、证书是否有效。
- IPv6 前缀是否变化。
- 访问设备是否支持 IPv6。

若确认校园网封锁入站端口，不要绕过限制，也不要擅自部署 Cloudflare
Tunnel、VPS 中继、NAT 穿透等替代架构。保留 DDNS 和证书代码，明确报告公网
入口受网络条件限制，等待下一阶段决策。

### 10.1 DNS-only 的 IPv6-only 限制

通配符 CNAME 和 AAAA 都是 **DNS only**：Cloudflare 只返回 DNS 答案，不代理
HTTP。只有 IPv4 的客户端无法连接仅发布 AAAA 的主机；不会自动获得 IPv4
兼容入口。若未来需要 IPv4 客户端访问，必须单独设计并明确授权，不能把 DNS
only 误认为 Cloudflare 代理。

## 11. 故障排查

### 11.1 DDNS 不更新

```bash
sudo systemctl start cloudflare-ddns.service
journalctl -u cloudflare-ddns.service -n 100 --no-pager

ip -6 route show default
ip -6 addr show dev <接口>
ip -6 route get 2606:4700:4700::1111
```

重点区分：

- `no physical IPv6 default route`：物理上行没有 IPv6 默认路由。
- `no stable global IPv6 address`：只有临时、ULA、link-local 或 deprecated
  地址。
- `multiple stable global IPv6 addresses` / `ambiguous`：候选不唯一，需要人工
  检查前缀和路由。
- `HTTP 429` / `HTTP 5xx` / `timed out`：Cloudflare 或网络暂时不可用，下一轮
  自动重试。
- `CNAME` / `multiple AAAA` / `proxied`：DNS 记录冲突，必须人工到 Dashboard
  处理，脚本不会删除其他记录。

检查凭据权限，但不要打印内容：

```bash
sudo stat -c '%a %U:%G %n' /etc/cloudflare /etc/cloudflare/token /etc/cloudflare/zone-id
systemctl status cloudflare-ddns.timer
```

### 11.2 证书未签发

```bash
systemctl status 'acme-*.service' 'acme-*.timer'
journalctl -u 'acme-order-renew-20050917.xyz.service' -n 100 --no-pager
sudo ls -l /var/lib/acme/20050917.xyz/
dig TXT _acme-challenge.20050917.xyz
```

常见原因：Token 缺少 `Zone:DNS:Edit`、Zone ID 错误、Cloudflare API 被代理
阻断、DNS 传播检查超时。不要关闭传播检查来“修复”签发失败；先确认 DNS-01
记录确实可见。

证书到期但续期失败时，上一张证书文件通常仍在；先修复 ACME，再检查 Caddy
是否加载了旧文件。不要把证书或私钥复制到仓库来绕过问题。

### 11.3 Caddy 不启动或 reload 失败

```bash
systemctl status caddy
journalctl -u caddy -n 100 --no-pager
sudo ingressctl check
caddy validate --config /etc/caddy/caddy_config --adapter caddyfile
```

检查：

- `/etc/caddy/sites-enabled` 是否存在、是否被误改成符号链接。
- 动态片段是否由 `ingressctl` 生成。
- `/var/lib/acme/20050917.xyz` 的组和权限。
- 80/443 是否被其他进程占用。

不要通过 `services.caddy.virtualHosts` 临时加入业务站点来绕过 `ingressctl`。

### 11.4 校外不可达

按第 10 节顺序排查。不要把“Caddy reload 成功”或“本机 curl 成功”报告为
“公网 HTTPS 已验收”。

## 12. SSH 公网访问安全要求

当前 `hosts/nixos/default.nix` 仍保留 PasswordAuthentication 的 NixOS 默认
值。**在实机允许公网 SSH 前，必须完成：**

1. 从另一台机器验证 SSH 公钥登录成功。
2. 确认禁用密码登录后仍能通过 SSH 管理。
3. 检查 `AuthorizedKeys` 与 `AllowUsers`。
4. 保留 Tailscale 作为备用入口。
5. 保留本地 TTY 和 NixOS generation 回滚能力。
6. 将 SSH 调整为密钥认证、禁止 root 登录、关闭密码和 keyboard-interactive。
7. 再从真正的校外 IPv6 网络测试 TCP 22。

如果无法验证密钥登录，不得为了公网访问强制关闭密码并 switch；也不得在
公网密码认证仍开启时宣告 SSH 安全验收完成。不要修改 SSH 端口，不安装额外
SSH Web 控制面板。

## 13. 备份与恢复

必须备份或至少可重建：

- Cloudflare Token 和 Zone ID：离线保存，权限 `0600`；不要放进 Git。
- `/etc/caddy/sites-enabled/*.caddy`：当前启用的业务路由。
- `/var/lib/acme/20050917.xyz/`：证书与私钥；丢失后可重新签发，但短期频繁
  重签可能触发 CA 速率限制。
- `/var/lib/acme/.lego/`：ACME 账户和续期状态；应纳入 root-only 备份。
- `/srv/containers/<service>/`：每个服务的持久化数据。
- `/var/lib/docker/volumes/`：named volume；不能只备份 Compose 文件。
- 数据库使用一致性快照或原生 dump，不能假设复制在线数据目录即可恢复。

恢复证书后确认属组为 `acme:caddy` 或至少 Caddy 组可读，并运行
`sudo ingressctl check`。恢复 `/etc/caddy/sites-enabled` 后同样执行 check 和
reload，但不要用恢复文件替换 NixOS 生成的 `/etc/caddy/caddy_config`。

## 14. 首次部署顺序

以下步骤需要用户明确授权和实机执行，仓库不会自动 switch、重启或写真实 DNS：

1. 检查校园网、Mihomo、Docker、SSH、Tailscale。
2. 确认第二台设备可以通过 SSH 密钥登录。
3. 确认本地 TTY 和旧 NixOS generation 可用。
4. 安装 `/etc/cloudflare/token` 和 `zone-id`，按第 2 节检查权限。
5. 在 Cloudflare 确认 `nixos` AAAA 可写、通配符 CNAME 存在，且无冲突。
6. 构建新 generation：

```bash
nix flake check --no-build
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel
scripts/check-server-network
scripts/check-server-docker
scripts/check-server-ingress
```

7. 用户确认维护窗口和回退路径后执行：

```bash
sudo nixos-rebuild switch --flake .#nixos
```

8. 观察 DDNS timer 和 ACME 服务；首次签发成功前不要用 `ingressctl publish`
   上线业务站点。
9. 验证 Caddy 健康检查、`sudo ingressctl check` 和本地 HTTPS/上游。
10. 从校外 IPv6 网络做最终公网测试。

如果缺少真实 Token、Zone ID 或校外验证环境，只完成代码、静态测试、文档和
Git 提交；不要声称证书已真实签发或公网入口已可用。

## 11. 公网 IPv4 备援入口：hw frps + frpc

校园网/运营商不允许 IPv6 入站时，`artex.20050917.xyz` 可以改走已有的公网
IPv4 主机 `hw`。`hw` 上已经有 `frps` 监听 `80/443`，不需要安装 Caddy、
nginx，也不需要把证书复制到 `hw`：

```text
外部客户端
  │ https://artex.20050917.xyz:443
  ▼
hw:443 frps（按 SNI 路由，TLS 直通）
  │
  ▼
nixos frpc-artex
  │
  ▼
127.0.0.1:443 Caddy
  │
  ▼
127.0.0.1:8787 artex
```

### 11.1 运行时文件

```text
/etc/frp/
├── frpc-artex.toml   # 0600 root:root，包含 frps token
└── ca.crt            # 0644 root:root，hw frps 的公网 CA 证书
```

`frpc-artex.toml` 不由 NixOS 生成，也不能进入 Git、Nix store 或 systemd
`ExecStart`：

```toml
serverAddr = "183.87.144.211"
serverPort = 7000
transport.tls.enable = true
transport.tls.trustedCaFile = "/etc/frp/ca.crt"
auth.token = "<frps token>"

[[proxies]]
name = "artex"
type = "https"
customDomains = ["artex.20050917.xyz"]
localIP = "127.0.0.1"
localPort = 443
```

`hosts/nixos/frp.nix` 只定义 `frpc-artex.service` 和 `/etc/frp` 目录。服务
从 nixos 主动连接 `hw:7000`，不开放新的入站端口；`frps` 侧不修改配置。

### 11.2 DNS

走 IPv4 入口时，精确记录改为：

```text
Type: A
Name: artex
Content: 183.87.144.211
Proxy: DNS only
TTL: 120
```

必须删除 `artex` 的精确 AAAA，避免双栈客户端优先尝试不可入站的 IPv6。
不要修改 `nixos` 的 AAAA、通配符记录或其他域名。`hw` 没有 IPv6，因此该
入口只覆盖 IPv4 客户端；需要 IPv6-only 客户端时，应使用 Cloudflare 隧道
或另行增加 IPv6 中继。

### 11.3 启动与验证

先把 `hw` 的 `/etc/frp/token` 和 `/etc/frp/certs/ca.crt` 以 root-only 方式
安装到 nixos；不要输出 token 内容。然后：

```bash
sudo systemctl start frpc-artex.service
sudo systemctl status frpc-artex.service
sudo journalctl -u frpc-artex.service -n 50

# 在 DNS 切换前，用 --resolve 直接验证 hw 入口和端到端证书
curl -4 -I --resolve artex.20050917.xyz:443:183.87.144.211 \
  https://artex.20050917.xyz/login

# DNS 切换后
dig A artex.20050917.xyz
curl -4 -I https://artex.20050917.xyz/login
```

`frpc` 日志出现 `start proxy success`，且 `--resolve` 请求返回 200，才说明
隧道和 TLS 直通正常。只看到 `frpc` 进程存在，不等于公网入口可用。

### 11.4 回滚

```bash
sudo systemctl stop frpc-artex.service
sudo systemctl disable frpc-artex.service
```

`hw` 侧无需回滚；再把 `artex` 的 DNS 恢复为原来的 AAAA 即可。`hw` 的
`frps` 配置和现有代理不受影响。

### 11.5 限制

- `hw` 只有 IPv4，没有全局 IPv6。
- frps token 是共享凭据；`/etc/frp/frpc-artex.toml` 必须是 `0600 root`。
- frps 只按 SNI 转发，TLS 终止仍在 nixos Caddy；不要在 `hw` 上安装
  通配符私钥。
- 校外验收必须从真实 IPv4 网络执行，不能用同一校园网链路代替。
