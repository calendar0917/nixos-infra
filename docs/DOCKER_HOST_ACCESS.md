# 容器访问宿主服务（Docker → main）

main 上的 Docker 容器要调用宿主进程（例如 magpie 网关 `*:3425`、axonhub）时，
默认**连不通**。这不是地址填错，是 NixOS 防火墙的 input 链丢包。

## 1. 症状

```bash
# 宿主上测，通
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.1:3425/api/hello   # 401
# 容器里测，超时
docker compose exec axonhub wget -T 3 -O- http://172.18.0.1:3425/api/hello    # timeout
```

宿主能连是**假象**：访问本机自己的桥地址走 `lo`，`lo` 在 trusted interfaces
里被整条 accept。magpie 日志里那些 `from 172.18.0.1` 的记录也是宿主自己的探测，
源地址就是桥地址本身，不代表容器来过。

## 2. 真因

- 容器 → 宿主是 **INPUT** 路径（不是 FORWARD）。`DOCKER-USER` 链只管容器进出
  外网，管不到这条。
- 当前规则集（`table inet nixos-fw`）里 input 链 `policy drop`，trusted
  interfaces 只有 `tailscale0` / `Meta` / `lo`，`input-allow` 里只有
  `tcp dport { 7897, 30141 }` 和 udp 41641。
- 容器从 `br-*` 进来、新连接、端口没在白名单 → 直接被丢。

## 3. 修法：按网段开端口，别信网桥名

`hosts/main/default.nix`：

```nix
networking.firewall.extraInputRules = ''
  ip saddr 172.16.0.0/12 tcp dport 3425 accept comment "magpie gateway for docker"
'';
```

要点：

- `172.16.0.0/12` 覆盖 Docker 默认地址池 `172.17`–`172.31`，compose 重建后
  网段不变也不用改。
- **不要**把 `br-*` 加进 `trustedInterfaces`：网桥名随 compose 项目重建变化，
  而且信任整条桥等于对同网段所有容器全开。
- **不要**加进 `allowedTCPPorts`：那是所有接口（LAN/公网）一起开。3425 目前
  也不对 LAN 开放，是有意的。
- 只改 magpie 一个端口时，规则里写死 `tcp dport 3425`。

验证：

```bash
sudo nft list chain inet nixos-fw input-allow | grep 3425
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.1:3425/api/hello
```

临时 `sudo nft insert rule inet nixos-fw input iifname "br-xxx" tcp dport 3425 accept`
只活在运行时，`nftables.service` 重载或下一次 switch 就没了，别当永久修复。

## 4. magpie + AxonHub 具体值

- magpie 监听 `*:3425`，请求必须带 `Authorization: Bearer <magpie key>`。
- AxonHub 容器地址：`172.18.0.2`（backend，postgres 在 `172.18.0.3`）和
  `172.19.0.2`（egress）。宿主侧网关分别是 `172.18.0.1` / `172.19.0.1`，
  两个都通，provider base URL 用 `http://172.18.0.1:3425/v1`。
- `model` 字段要填 `/v1/models` 里的 `provider/model` 全名。当前 key 只暴露
  `miastral/deepseek-v4-1-flash-1017`，填裸名或别的模型会报
  `magpie knows no model`。

相关：`hosts/main/docker.nix`（main 的 Docker）、`deploy/axonhub/compose.yaml`
（axonhub 的两个网络）。
