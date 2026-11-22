# 统一访问入口

状态：**P1 已上线**。`https://pi.20050917.xyz` 经 Cloudflare Tunnel 指向笔记本
（`#main`）的 pi-web，手机不开 Tailscale 即可访问。其余主机维持现状。

## 1. 要解决的问题

1. 手机上访问家里服务（pi-web 等）必须开 Tailscale；Android 只有一个 VPN 槽，
   Tailscale 与 Clash 互斥，来回切换成本高。
2. 四台机器、多条互不相干的暴露路径（az 的 8088、hw 的 frps、nixos 的
   Caddy/DDNS、笔记本的 frpc-artex），没有统一清单和入口。

## 2. 主机

| 别名 | 位置 | 地址 | 常开 | 备注 |
| --- | --- | --- | --- | --- |
| `main` | 笔记本（`#main`） | tailscale `100.98.145.40` | 基本常开 | pi-web、artex、DS Bot、cloudflared |
| `nixos` | KOLOE 小主机（`#nixos`） | tailscale `100.107.6.15` | **不保证 24h** | Caddy + Docker + frpc-artex |
| `az` | Azure | `52.231.71.121` | 常开 | `20050917.xyz` apex，8088 静态页 |
| `hw` | 华为云 | `183.87.144.211` | 常开 | frps，承担 `recruit.yulinsec.cn`，**不动** |

## 3. 已实施的架构

入口放笔记本而非小主机：小主机不能保证 24h，笔记本本身就是家里服务的主要载体，
cloudflared 直接打 loopback，链路最短。

```
手机（普通网络，无需 VPN）
  └─ https://pi.20050917.xyz → Cloudflare 边缘 → cloudflared（main 上的 cloudflared-pi.service）
                                                    └─ http://127.0.0.1:30141 (pi-web)
```

- 只建**出站**隧道，不开放任何公网端口，不新增防火墙规则。
- 隧道 id `ecb1dbdf-d1fd-4ef8-9c03-cae65a62c690`（名称 `laptop-main`），
  `config_src=cloudflare`：**ingress 规则存在云端**，改映射去 dashboard 或 API，
  不在本仓库。当前云端 ingress：

  | hostname | service |
  | --- | --- |
  | `pi.20050917.xyz` | `http://127.0.0.1:30141`（connectTimeout 10000） |
  | 其余 | `http_status:404` |

- DNS：`pi` CNAME → `ecb1dbdf-....cfargotunnel.com`，橙云代理。其余 6 条记录未变。

## 4. 实现细节（仓库内）

| 文件 | 作用 |
| --- | --- |
| [hosts/main/tunnel.nix](../hosts/main/tunnel.nix) | `cloudflared-pi.service`：DynamicUser、`Restart=always`、`LoadCredential` 注入 token |
| [modules/secrets.nix](../modules/secrets.nix) | sops-nix 的 `age.keyFile` 与 `defaultSopsFile` |
| [.sops.yaml](../.sops.yaml) | age 收件人（笔记本公钥） |
| [secrets/secrets.yaml](../secrets/secrets.yaml) | 密文；当前只有 `cloudflared-tunnel-token` |
| [deploy/pi-web/start.sh](../deploy/pi-web/start.sh) | `PI_WEB_ALLOWED_HOSTS` 放行隧道域名 |

### 4.1 凭据

- 隧道 token 以密文存 `secrets/secrets.yaml`，activation 时由 sops-nix 落到
  `/run/secrets/cloudflared-tunnel-token`（`0400`，属主为 DynamicUser），服务只
  通过 `%d/tunnel-token` 读它。token 不进 Git、不进 Nix store、不进命令行。
- age 私钥在 `~/.config/sops/age/keys.txt`，另有一份给 activation 用：
  `/var/lib/sops-nix/keys.txt`（`0600 root`）。**这两份都必须异地备份**，
  丢了 `secrets/secrets.yaml` 里所有密文都解不开。
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

## 5. 鉴权决定：不上 Cloudflare Access

用户嫌一次性验证码到期后要重新收码，故不启用 Access。代价是 pi-web 登录页在
公网可见，只靠它自身的口令 + 上面那层 Host/Origin 白名单。

- DS Bot Web GUI **不接公网**：没有鉴权且含对话数据，只走 tailnet。
- 若将来要加第二层门，可在 CF 侧给 `pi` 加 Access 应用（One-time PIN，
  Session Duration 设 1 个月），主机侧无需改动。

## 6. 自检

`/home/calendar/DS Bot/tools/infra-check.sh`（哨兵每 2 小时跑）检查四项：

1. 公网 `https://pi.20050917.xyz/` 期望 307/200
2. 本地 `http://127.0.0.1:30141/` 期望 307
3. `systemctl is-active cloudflared-pi`（system 级）期望 active
4. `/home` 与 `/` 使用率 >85% 报警（`/` 是 tmpfs 14G，基本恒 0%，主要看 `/home`）

异常时按「公网挂但本地正常 → 隧道问题」「本地也挂 → pi-web 问题」分类。
**固有盲区**：整套自检在笔记本上，整机断电/断网时它也不报；要补需要一台外部
主机（如 az）从公网反查。

## 7. 回滚

1. 停服务：`sudo systemctl disable --now cloudflared-pi`（或从
   `hosts/main/default.nix` 去掉 `./tunnel.nix` 后 switch）。
2. 删 `pi` 的 CNAME。
3. 若也要撤白名单，去掉 `start.sh` 里的 `PI_WEB_ALLOWED_HOSTS` 并重启 pi-web。

全程未改 `hw`、`az` 和小主机的 Caddy/DDNS，回滚不影响任何现有访问路径。

## 8. 已知风险

1. **笔记本单点**：合盖 suspend 会断隧道，手机侧表现为超时。
2. **国内访问 CF 边缘**：延迟高于直连；适合网页 UI，不适合大文件传输。
3. **登录页公网可见**：只有 pi-web 口令一道防线（见 §5）。

## 9. 未做 / 待定

- `art.20050917.xyz`（artex 8787）未接隧道；artex 是否自带登录未确认。
- `wildcard *.20050917.xyz` 维持现状，不动。
- 服务门户页 / `services.yaml` 清单：暂缓（现在服务不多），届时再做。
- 把 frpc-artex 降级为备用通道：未评估。
- 小主机上的服务若需手机访问，再在隧道 ingress 里加一条指向 `100.107.6.15`。
