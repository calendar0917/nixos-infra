# 网络设计

## 职责边界

| 组件 | 负责 | 不负责 |
| --- | --- | --- |
| NetworkManager | Wi-Fi/以太网、连接配置、DHCP | 不做 DNS 转发 |
| systemd-resolved | 本机唯一 DNS stub（`127.0.0.53:53`） | 不代理流量 |
| Tailscale | tailnet 连接、MagicDNS 可选 | 不接管默认路由 |
| Mihomo | HTTP/SOCKS 代理、规则、TUN | 不监听宿主 `:53`（必须由配置保证） |
| NixOS firewall | 入站策略 | 不为排障整体关闭 |

`modules/network.nix` 设置：

```nix
networking.networkmanager.dns = "systemd-resolved";
services.resolved.enable = true;
networking.firewall.enable = true;
networking.firewall.trustedInterfaces = [ "tailscale0" ];
```

只有 `tailscale0` 被信任，没有全局关闭防火墙。Tailscale 的 UDP 端口由
`openFirewall = true` 精确放行。

## Tailscale

默认值：

```nix
my.network.tailscale.enable = true;
my.network.tailscale.acceptDns = false;
my.network.tailscale.acceptRoutes = false;
```

- `--accept-routes=false`：避免 Tailscale 接受 subnet router 后改写默认路由，和
  Mihomo TUN 的路由表打架。
- `--accept-dns=false`：避免第二个 DNS 管理者；需要 MagicDNS 时再单独改为 `true`，
  并检查 `resolvectl status` 和 Mihomo 的 DNS 配置。
- `tailscaled` **没有**设置 `HTTP_PROXY`/`HTTPS_PROXY`。旧配置给 `tailscaled`
  注入 `127.0.0.1:7890` 会在 Mihomo 未启动时让 Tailscale 起不来，也会让
  Tailscale 自身流量误入代理；本仓库不继承这个做法。
- 首次登录用：
  ```bash
  sudo tailscale up --accept-dns=false --accept-routes=false
  ```
  或设置 `my.network.tailscale.authKeyFile` 指向运行时密钥文件；不要把 auth key
  写入 Nix store。

## Mihomo

`my.network.mihomo.enable = false` 是默认值：没有订阅、没有 age key 时系统仍可
正常构建、登录、直连排障。启用时：

- `services.mihomo.tunMode = true` 只给服务 `CAP_NET_ADMIN`，TUN 仍需在加密配置
  中打开（`tun.enable: true`）。
- `services.mihomo.configFile` 指向 `/run/secrets/mihomo-config`，该文件由
  sops-nix 在运行时解密，权限 `0400 root:root`；不会进 `/nix/store`。
- `webui = metacubexd` 只安装本地控制台静态文件，不改变 DNS 或路由。
- 不设置全局 `HTTP_PROXY` 环境变量；需要代理的命令手动加环境变量。

Mihomo 配置的 DNS 建议：

```yaml
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
```

关键点是 `listen` 不要写成 `0.0.0.0:53` 或 `127.0.0.1:53`；宿主 `:53` 属于
systemd-resolved。TUN 内的 `dns-hijack: any:53` 只处理进入 TUN 的查询，不会和
resolved 抢宿主端口。若使用 fake-ip，确认 Tailscale 的域名/网段规则走直连，避免
Tailscale 连接被代理。

## 故障时的顺序

1. 先停 Mihomo，保留防火墙和 resolved：
   ```bash
   sudo systemctl stop mihomo
   resolvectl status
   ip route
   curl -I https://cache.nixos.org
   ```
2. 若怀疑 Tailscale 路由/DNS：
   ```bash
   sudo systemctl stop tailscaled
   tailscale status
   ```
3. 只在当前命令上使用代理，不修改 `tailscaled`：
   ```bash
   https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 \
     nix flake check
   ```
4. 不要执行 `networking.firewall.enable = false`；本仓库不会以关闭防火墙作为恢复
   手段。
