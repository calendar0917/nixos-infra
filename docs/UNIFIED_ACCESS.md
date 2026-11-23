# 统一访问入口

状态：**P1 已上线**。`https://pi.20050917.xyz` 经 Cloudflare Tunnel 指向笔记本
（`#main`）的 pi-web，手机不开 Tailscale 即可访问。**P2 已上线**：同一条隧道再挂一个
`https://vault.20050917.xyz`，跑 Vaultwarden 密码库。**P3 已上线**：
`https://api.20050917.xyz` 指向同一台笔记本的 AxonHub（LLM 网关，`/v1/*` 仍需
AxonHub API key）。其余主机维持现状。

## 1. 要解决的问题

1. 手机上访问家里服务（pi-web 等）必须开 Tailscale；Android 只有一个 VPN 槽，
   Tailscale 与 Clash 互斥，来回切换成本高。
2. 四台机器、多条互不相干的暴露路径（az 的 8088、hw 的 frps、nixos 的
   Caddy/DDNS、笔记本的 frpc-artex），没有统一清单和入口。

## 2. 主机

哪四台、地址、怎么进、跑什么、归谁管：见 [`INVENTORY.md`](INVENTORY.md) §1，这里不重复。

## 3. 已实施的架构

入口放笔记本而非小主机：小主机不能保证 24h，笔记本本身就是家里服务的主要载体，
cloudflared 直接打 loopback，链路最短。

```
手机（普通网络，无需 VPN）
  └─ https://pi.20050917.xyz   → Cloudflare 边缘 → cloudflared（main 上的 cloudflared-pi.service）
  └─ https://vault.20050917.xyz →            ├─ http://127.0.0.1:30141 (pi-web)
  └─ https://api.20050917.xyz   →            ├─ http://127.0.0.1:8222  (vaultwarden)
  └─ https://home.20050917.xyz  →            ├─ http://127.0.0.1:8090  (axonhub)
                                             └─ http://127.0.0.1:8770  (glance 服务总览)
```

- 只建**出站**隧道，不开放任何公网端口，不新增防火墙规则。
- 隧道 id `ecb1dbdf-d1fd-4ef8-9c03-cae65a62c690`（名称 `laptop-main`），
  `config_src=cloudflare`：**ingress 规则存在云端**，改映射去 dashboard 或 API，
  不在本仓库。当前 ingress 有哪几条、每个域名指向哪个后端、现场通不通：
  见 [`INVENTORY.md`](INVENTORY.md) §2（唯一台账，这里只写做法）。

## 4. 实现细节（仓库内）

| 文件 | 作用 |
| --- | --- |
| [hosts/main/tunnel.nix](../hosts/main/tunnel.nix) | `cloudflared-pi.service`：DynamicUser、`Restart=always`、`LoadCredential` 注入 token |
| [modules/secrets.nix](../modules/secrets.nix) | sops-nix 的 `age.keyFile` 与 `defaultSopsFile` |
| [modules/vaultwarden.nix](../modules/vaultwarden.nix) | Vaultwarden：loopback 监听、CF 真实 IP、注册关闭、登录限流 |
| [.sops.yaml](../.sops.yaml) | age 收件人（笔记本公钥） |
| [secrets/secrets.yaml](../secrets/secrets.yaml) | 密文；`cloudflared-tunnel-token`、`vaultwarden-admin-token` |
| [deploy/pi-web/start.sh](../deploy/pi-web/start.sh) | `PI_WEB_ALLOWED_HOSTS` 放行隧道域名 |

### 4.1 凭据

- 隧道 token 以密文存 `secrets/secrets.yaml`，activation 时由 sops-nix 落到
  `/run/secrets/cloudflared-tunnel-token`（`0400`，属主为 DynamicUser），服务只
  通过 `%d/tunnel-token` 读它。token 不进 Git、不进 Nix store、不进命令行。
- `vaultwarden-admin-token` 同法落到 `/run/secrets/vaultwarden-admin-token`
  （`0400`，属主 `vaultwarden`），整行内容是 `ADMIN_TOKEN=<48 位 hex>`，直接当
  `EnvironmentFile` 用。管理面板在 `https://vault.20050917.xyz/admin`。
- **本仓库是 public**：密文与 age 公钥全网可见，安全性全部押在 age 私钥上。
- age 私钥在 `~/.config/sops/age/keys.txt`，另有一份给 activation 用：
  `/var/lib/sops-nix/keys.txt`（`0600 root`）。**这两份都必须异地备份**，
  丢了 `secrets/secrets.yaml` 里所有密文都解不开。现在 vault 里另存了一份安全
  笔记，但那不能算唯一副本——它和 vault 主密码是同一个失败域。
- 编辑密文：`cd ~/nixos-infra && sops secrets/secrets.yaml`（普通用户即可，
  不需要 sudo）。改完 `sudo nixos-rebuild switch --flake .#main`；
  `restartUnits` 会让 cloudflared 自己重启。

### 4.2 pi-web 主机白名单（坑）

pi-web 中间件用 `PI_WEB_HOSTNAME` + `PI_WEB_ALLOWED_HOSTS` 做 Host 白名单
（`localhost` 和 IP 恒放行），API 还校验 `Origin` / `sec-fetch-site`。

- 不加白名单：`Host: pi.20050917.xyz` 直接 `403 Untrusted request`。
- 只在 Cloudflare 侧改写 `httpHostHeader` 不行：登录页能开，但
  `POST /api/auth/login` 带真实 Origin 会 `403 Untrusted API request`。**别用这招**。
- 正解就是 `start.sh` 里那行 `export PI_WEB_ALLOWED_HOSTS`。

## 5. 密码管理：Vaultwarden

自建 Vaultwarden（Rust），数据库为 `/var/lib/vaultwarden` 下的 sqlite。

- **只监听 `127.0.0.1:8222`**，公网只经隧道进来，不开放任何端口。
- `IP_HEADER=CF-Connecting-IP`：不设的话所有访客在服务端看来都是 `127.0.0.1`，
  登录限流会被一个人打满、把所有人锁在外面。
- **注册已关闭**（`SIGNUPS_ALLOWED=false`），没有 SMTP、邀请也不可用，账号只有一个。
- 登录限流：每个客户端 IP 60 秒内 10 次，超过返回 `429 Too many login requests`
  （实测第 11 次触发，指数退避）。
- 资源：常驻约 13 MB，峰值约 50 MB（启动），空闲 CPU 近零。
- 每日 23:00 由 `backup-vaultwarden.timer` 把 sqlite 导到 `/var/backup/vaultwarden`。
  **这是同盘备份，不是异地备份。**
- 客户端：Bitwarden 扩展 / App，服务器地址填 `https://vault.20050917.xyz`。
  条目端到端加密，主密码不出设备；服务端被拖库拿不到明文。

## 6. 鉴权决定：不上 Cloudflare Access

用户嫌一次性验证码到期后要重新收码，故不启用 Access。代价是 pi-web 登录页在
公网可见，只靠它自身的口令 + 上面那层 Host/Origin 白名单。

- DS Bot Web GUI **不接公网**：没有鉴权且含对话数据，只走 tailnet。
- 若将来要加第二层门，可在 CF 侧给 `pi` 加 Access 应用（One-time PIN，
  Session Duration 设 1 个月），主机侧无需改动。

## 7. 自检

`/home/calendar/DS Bot/tools/infra-check.sh`（哨兵每 2 小时跑）检查四项：

1. 公网 `https://pi.20050917.xyz/` 期望 307/200
2. 本地 `http://127.0.0.1:30141/` 期望 307
3. `systemctl is-active cloudflared-pi`（system 级）期望 active
4. `/home` 与 `/` 使用率 >85% 报警（`/` 是 tmpfs 14G，基本恒 0%，主要看 `/home`）

异常时按「公网挂但本地正常 → 隧道问题」「本地也挂 → pi-web 问题」分类。
**固有盲区**：整套自检在笔记本上，整机断电/断网时它也不报；要补需要一台外部
主机（如 az）从公网反查。

## 8. 回滚

1. 停服务：`sudo systemctl disable --now cloudflared-pi`（或从
   `hosts/main/default.nix` 去掉 `./tunnel.nix` 后 switch）。
2. 删 `pi` 的 CNAME。
3. 若也要撤白名单，去掉 `start.sh` 里的 `PI_WEB_ALLOWED_HOSTS` 并重启 pi-web。

全程未改 `hw`、`az` 和小主机的 Caddy/DDNS，回滚不影响任何现有访问路径。

## 9. 已知风险

1. **笔记本单点**：合盖 suspend 会断隧道，手机侧表现为超时。
2. **国内访问 CF 边缘**：延迟高于直连；适合网页 UI，不适合大文件传输。
3. **登录页公网可见**：只有 pi-web 口令一道防线（见 §6）。
4. **vault 是新的单点**：全部口令只在这台笔记本的一块盘上。盘挂、机器丢、被
   加密勒索，等于全丢。每日 sqlite 备份还在同一块盘上，不算数。
5. **vault 未开两步验证**：168 条凭据后面只站着一个主密码。
6. **历史口令复用**：迁移时实测，186 条里 155 条落在 11 个口令上，其中两个口令
   守卫 110 个真实站点（含 Google、阿里云、GitHub、淘宝、Steam）。未处理前，
   任一站被拖库即等于其余站点一起失守。

## 10. 未做 / 待定

- **vault 的两步验证**（TOTP，不依赖 SMTP）未开。
- **Firefox 仍用自带密码库**：Bitwarden 扩展未装，`about:logins` 里的旧条目未清。
- **vault 数据的异地副本**：唯一真正紧迫的备份项。
- **哨兵未覆盖 vault**：`infra-check.sh` 只查 pi-web。
- `art.20050917.xyz`（artex 8787）未接隧道；artex 是否自带登录未确认。
- `wildcard *.20050917.xyz` 维持现状，不动。
- 服务门户页 / `services.yaml` 清单：暂缓（现在服务不多），届时再做。
- 把 frpc-artex 降级为备用通道：未评估。
- 小主机上的服务若需手机访问，再在隧道 ingress 里加一条指向 `100.107.6.15`。
