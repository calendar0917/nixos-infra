# 设备与服务清册

> **唯一现状台账。** 这里只写"现在是什么"，不写"怎么配"。怎么装、怎么回滚在
> 各 `SERVER_*.md` 里；改一次现状只改这里，别在别的文档里再抄一遍。
>
> 最后核对：2026-11-23（`scripts/fleet-status` + 逐个域名实测 + `home.` 上线）。

## 1. 纳管主机（四台）

| 别名 | 机器 | 地址 | 怎么进 | 常开 | 配置源 | 主要服务 |
| --- | --- | --- | --- | --- | --- | --- |
| `main` | LENOVO 21LG 笔记本（`#main`） | tailscale `100.98.145.40` | 本机 | 基本常开 | nixos-infra flake | pi-web `30141`、axonhub `8090`、vaultwarden `127.0.0.1:8222`、artex `127.0.0.1:8787/8788`、cloudflared（隧道 `laptop-main`）、DS Bot `127.0.0.1:35721` |
| `nixos` | KOLOE 小主机（`#nixos`） | tailscale `100.107.6.15` | `ssh nixos` | **不保证 24h** | nixos-infra flake | Caddy、artex `127.0.0.1:8787/8788`、openmausbot `127.0.0.1:8799/8800`、mihomo `7897/7898`、x11vnc `127.0.0.1:5900` |
| `az` | Azure 印度（hostname `india`，Ubuntu 22.04） | tailscale `100.125.26.18` | `ssh az` | 常开 | **手工**，不在 flake | cloudflared（隧道 `az`）、VLESS+WS `127.0.0.1:8080` |
| `hw` | 华为云（hostname `hcss-ecs-1e04`，Debian 12） | tailscale `100.85.48.79` | `ssh hw` | 常开 | **手工**，不在 flake | sshd；`frps.service` 已停用（见 §2） |

- 四台 ssh 别名全部写 tailscale `100.x`，不再需要代理或跳板；`az` 原来那条 `ProxyCommand` 已删。
- 两台云主机的公网地址仅作备案：`az` = `52.231.71.121`（国内直连被墙）、`hw` = `183.87.144.211`。
- `main` 的 pi-web 与 axonhub 绑在 `0.0.0.0`（同网段可达），其余服务都只绑 loopback。

## 2. 对外入口

| 域名 | 走到哪 | 后端 | 状态（2026-11-23 实测） | 鉴权 |
| --- | --- | --- | --- | --- |
| `pi.20050917.xyz` | 隧道 `laptop-main` | `127.0.0.1:30141` | 307 → 登录页 | pi-web 密码 |
| `vault.20050917.xyz` | 隧道 `laptop-main` | `127.0.0.1:8222` | 200 | Vaultwarden 账密 |
| `api.20050917.xyz` | 隧道 `laptop-main` | `127.0.0.1:8090` | 200 | AxonHub API key |
| `home.20050917.xyz` | 隧道 `laptop-main` | `127.0.0.1:8770`（Glance） | 303 → 登录页 | Glance 账号（见 `deploy/glance/`） |
| `az.20050917.xyz` | 隧道 `az`（`4fa56e9c-…`） | `127.0.0.1:8080` VLESS+WS | 404（按路径走，正常） | VLESS uuid |
| `teamup.20050917.xyz` | A 记录 → `20.89.19.232` | 直连 nginx | 200 | 应用自身 |
| `bot.20050917.xyz` | A 记录 → `183.87.144.211`，本应 frps → nixos Caddy `8799` | — | **暂不使用**（原链路断，见下） | — |
| `artex.20050917.xyz` | 同上 → `8787` | — | **暂不使用**（同一个原因） | — |

- 通配 `*.20050917.xyz` → `52.231.71.121`（az）：没单独建过记录的域名都会落到 az。
- 隧道 `laptop-main` 的 ingress 在云端（`config_src=cloudflare`），**以 API/面板为准**，不在本仓库；这里只记结果。
- `bot.` / `artex.` 的链路是 DNS → hw `frps` → nixos Caddy，**中间那一跳没了**：`frps.service` 于 2026-11-23 13:55:23 被一次 root 登录（`110.184.179.202`）手动 `stop`，hw 上 80/443 现无进程监听。nixos 侧是好的：Caddy `active`，`127.0.0.1:8787`、`127.0.0.1:8799` 本地均返回 200。要恢复只需 hw 上 `systemctl start frps`，但 hw 的 frps 同时承载 `*.yulinsec.cn` 那批站，启停不由我们定，故标为暂不使用。

## 3. 不纳管（别人的机器，只登记）

| 别名 | 是什么 | 怎么进 |
| --- | --- | --- |
| `pve-old` | Proxmox 宿主机 `pve-old.yulinsec.cn`（IPv6），125G 内存 | `ssh pve-old` |
| `pve-new` | Proxmox 宿主机 `192.168.31.45` | `ssh pve-new`（经 pve-old 跳；内存只剩 15G，`T10-Tester` 占 98G） |
| `26-web` `26-pwn` `26-host` `edge` | `10.44.0.x` 靶场/竞赛环境 | 经 `pve-old` 跳 |
| `teamup` `teamup-2` | TeamUp 项目服务器 | `ssh teamup` / `ssh teamup-2`（后者经 pve-old 跳） |

这些不归 flake 管，改它只能手工 ssh，别指望 `nixos-rebuild`。

## 4. 状态怎么查

| 想知道 | 命令 |
| --- | --- |
| 四台一行看全 | `scripts/fleet-status` |
| 浏览器里看服务 | <https://home.20050917.xyz>（Glance，见 `deploy/glance/`） |
| 谁在线 | `tailscale status` |
| 外部入口实况 | 逐个 `curl`（见 §2 状态列的口径） |
| 隧道映射 | Cloudflare API（`CLOUDFLARE_API_TOKEN`）或面板 |