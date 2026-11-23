# Homepage 总览页（`home.20050917.xyz`）

替换原来的 Glance（`deploy/glance/`，留着当回滚）。Homepage 是 Next.js 应用，一个容器，
服务网格、书签、状态点都比 Glance 成熟；代价是比 Glance 重（常驻约 150–250MB）。

- 镜像：`ghcr.io/gethomepage/homepage:v2.8.0`（2026-11-11）
- 配置：`config/settings.yaml`、`services.yaml`、`bookmarks.yaml`、`widgets.yaml`
- 监听：`0.0.0.0:3000`（host 网络；外部由 nixos 防火墙挡住，公网只走隧道）
- 入口：Cloudflare 隧道 `laptop-main` 里 `home.20050917.xyz → http://127.0.0.1:3000`

## 为什么用 host 网络

页面要读的东西全部在本机 loopback 上：`fleet-json` 的 `127.0.0.1:8771`、pi-web 的 `:30141`、
axonhub 的 `:8090`、artex 的 `:8787`、vaultwarden 的 `:8222`。桥接网络里 `127.0.0.1`
是容器自己，这些一个都访问不到；host 网络下 `127.0.0.1` 就是本机，不用给任何服务改绑定。

代价是 Homepage 自己的 3000 绑在 `0.0.0.0`。`hosts/main/default.nix` 的
`allowedTCPPorts` 只有 `30141 7897`，3000 不在里面，所以校园网进不来；隧道按
`127.0.0.1:3000` 连，不受影响。

## 装（需要 sudo：容器由 root 起）

```bash
cd ~/nixos-infra/deploy/homepage
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs --tail=30 homepage
curl -sS -o /dev/null -w 'homepage %{http_code}\n' http://127.0.0.1:3000/
```

`HOMEPAGE_ALLOWED_HOSTS` 必须包含访问用的域名，否则 Homepage 直接 400（防 DNS rebinding）。
现在写的是 `home.20050917.xyz,127.0.0.1:3000`。

## 机器卡片的数据

四台机器的 uptime / 负载 / 磁盘不是 Homepage 自己采的——它的 `resources` 只读本机。
走的是 `scripts/fleet-status --json` → `deploy/glance/fleet-json.py`（`127.0.0.1:8771`，
用户级单元 `fleet-json.service`）→ 每台一个 `customapi` widget 读 `/host/<name>.json`。

```bash
systemctl --user status fleet-json.service --no-pager
curl -sS http://127.0.0.1:8771/host/nixos.json
```

fleet-json 每 120 秒后台预热一次，请求只读缓存，所以页面刷新不会被 ssh 拖慢；
某台连不上时字段显示 `—`，不会报错。

## 改配置

改完直接刷页面即可，Homepage 每次请求都重新读 `config/` 下的文件，不用重启容器。
只有改 `compose.yaml`（镜像、环境变量、网络）才要 `sudo docker compose up -d`。

### 书签的 YAML 嵌套（踩过）

`bookmarks.yaml` 里一个书签的属性必须写在**同一个列表元素的映射里**：

```yaml
- 组名:
    - 书签名:
        - abbr: X
          href: https://example.com
```

写成每个属性各占一个 `- `（三个独立列表元素）不会报错，解析时只取第 0 个元素，
`href` 直接丢失；首页 SSR 在 `new URL(bookmark.href)` 处抛 `TypeError: Invalid URL`，
整页 500。排查时看 `/api/bookmarks` 的返回最快——缺 `href` 一眼能看出来。
`services.yaml` 不一样，属性是普通映射（不要 `- `）。

## 回滚到 Glance

```bash
cd ~/nixos-infra/deploy/homepage && sudo docker compose down
systemctl --user start glance.service           # 配置还在，见 deploy/glance/README.md
```

再把隧道里 `home` 那条 ingress 从 `127.0.0.1:3000` 改回 `127.0.0.1:8770`。

## 已知局限

- 没有挂 `/var/run/docker.sock`，所以看不到容器列表和 docker 状态；要的话在 compose 里
  加一行 `- /var/run/docker.sock:/var/run/docker.sock:ro`，但那等于把宿主机 root 权限交给这个容器。
- `siteMonitor` 只探 HTTP 状态码；`az` 的 VLESS 和 `hw` 的 sshd 探不了。
- **没有鉴权**：Glance 有账号，Homepage 默认谁都能看。要加密码得在 compose 里补
  `HOMEPAGE_AUTH_ENABLED=true`、`HOMEPAGE_AUTH_PASSWORD`、`HOMEPAGE_AUTH_SECRET`（≥32 位）、
  `HOMEPAGE_EXTERNAL_URL=https://home.20050917.xyz`，改完 `up -d` 生效；
- 容器重启策略是 `unless-stopped`，开机自启；`calendar` 的 linger 已开
  （`loginctl show-user calendar | grep Linger` → `Linger=yes`），`fleet-json` 也跟着起。