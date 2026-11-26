# 小主机 Docker / Compose

本文对应 `nixosConfigurations.nixos` 的第二阶段服务器化基础。目标是让 KOLOE
小主机具备可复现的 Docker Engine、Compose v2、loopback 测试服务和持久化目录
约定。第三阶段已增加宿主机 Caddy、Cloudflare IPv6 DDNS 和 ACME 通配符证书，
见 [`SERVER_INGRESS.md`](SERVER_INGRESS.md)；Docker 本身仍不发布公网端口。

相关文件：

- `hosts/nixos/docker.nix`：Docker Engine、日志、代理和 `/srv/containers` 根目录。
- `deploy/nixos-smoke/compose.yaml`：只监听 loopback 的 Nginx 冒烟服务。
- `deploy/nixos-smoke/README.md`：该示例的操作说明。

## 1. 设计边界

- Docker daemon 随系统启动，已创建容器通过 restart policy 恢复。
- Docker API 只保留默认 Unix socket；不监听 TCP，不开放 Tailscale 或公网。
- `calendar` 不加入 `docker` 组；日常命令使用 `sudo docker ...`。
- 小主机的 Docker 配置独立于 main。main 的 `hosts/main/docker.nix` 行为不变。
- 不关闭 NixOS nftables/firewall，不切换 Docker firewall backend，不修改全局
  forwarding 或把所有 bridge 加入 `trustedInterfaces`。容器访问宿主服务是
  单端口、按网段的例外，见 [`DOCKER_HOST_ACCESS.md`](DOCKER_HOST_ACCESS.md)。
- 不启用 Swarm、experimental、容器 IPv6、镜像加速站或自动 prune。
- 不建立 Compose 编排框架、Portainer、Watchtower 或自动拉取/重建 unit。

## 2. Docker daemon

`hosts/nixos/docker.nix` 启用：

```nix
virtualisation.docker = {
  enable = true;
  enableOnBoot = true;
  extraPackages = [ pkgs.nftables ];
  logDriver = "json-file";
  daemon.settings.log-opts = {
    "max-size" = "10m";
    "max-file" = "3";
  };
};
```

说明：

- `nftables` 只是加入 Docker unit 的 `PATH`，让 Docker 29 能调用 nft CLI；没有
  替换 NixOS 防火墙实现。
- 默认日志驱动改为有界 `json-file`；Compose 服务自身也设置相同上限。
- NixOS 模块默认只暴露 `/run/docker.sock`，并通过 systemd socket activation
  启动 dockerd。不要设置 `virtualisation.docker.listenOptions` 为 `tcp://...`。
- `docker-compose` 同时安装为系统包；NixOS 的 Docker CLI 也能发现 Compose
  plugin，使用 `docker compose`（失败时可用 `docker-compose`）。
- `enableOnBoot = true` 保证重启后 daemon 启动；是否自动恢复容器由容器的
  restart policy 决定。

### 代理

Docker daemon 的 systemd 环境设置：

```text
HTTP_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,.local
```

- 该代理只用于 dockerd 的镜像拉取等网络访问，不会自动注入容器。
- Docker unit 没有 `Requires`/`After=mihomo.service`。Mihomo 未运行时 Docker
  仍应启动；已有本地镜像仍可运行，新拉取可能因连接 7897 失败。
- `campus-login.service` 和 Mihomo 都不依赖 Docker；不要添加反向依赖。
- 不修改 Nix daemon 或 Nix 客户端的代理环境。
- 容器里的 `127.0.0.1` 是容器自身，不是宿主机 Mihomo。业务需要代理时单独配置，
  本阶段不实现通用注入。

## 3. 用户和 socket 权限

不把 `calendar` 加入 `docker` 组。`docker.sock` 等同宿主机 root 级控制权，当前
只允许：

```bash
sudo docker ps
sudo docker compose ps
sudo docker compose up -d
sudo docker compose logs -f
```

socket 仍为本地 Unix socket（`/run/docker.sock`），不配置 TCP API，也不修改现有
sudo 密码策略。

## 4. 目录约定

```text
nixos-infra/deploy/<service>/        # Compose 配置，属于 Git
/srv/containers/<service>/data/      # 运行时数据，属于服务器
/srv/containers/<service>/config/    # 运行时配置，属于服务器
```

- `hosts/nixos/docker.nix` 只用 tmpfiles 创建 `/srv/containers`，不递归创建或
  chown 每个应用目录。
- 每个服务的 UID/GID、目录权限和备份方式在部署该服务时单独确定。
- 不把实际数据、真实 `.env` 或秘密提交 Git，不把长期数据放进 Nix store、临时
  目录或 `/home/calendar`。
- Docker 镜像、容器元数据和 named volume 仍在默认 `/var/lib/docker`；未来使用
  named volume 时不能遗漏其备份。
- 不新增 Btrfs 子卷，不修改磁盘、分区、挂载点或 `hardware-configuration.nix`。

冒烟服务本身无持久数据。

## 5. Compose 示例

`deploy/nixos-smoke/compose.yaml`：

- project name 固定为 `nixos-smoke`。
- 镜像为固定的 `nginx:1.27.4-alpine`。
- 端口为 `127.0.0.1:18080:80`，不监听 `0.0.0.0` 或 IPv6。
- `restart: unless-stopped`。
- 只读根文件系统，tmpfs 覆盖 Nginx 必需的写入位置。
- `no-new-privileges:true`，没有 privileged/host network/docker.sock/主机目录。
- `mem_limit`、`pids_limit`、`cpus` 设置有界资源。
- JSON 日志轮转为 `10m × 3`。

手动操作：

```bash
cd deploy/nixos-smoke

# 只解析和校验，不启动容器
sudo docker compose config -q

# 首次启动或 Compose 明确改动后
sudo docker compose up -d

sudo docker compose ps
curl --noproxy '*' http://127.0.0.1:18080/
sudo docker compose logs --tail=50
```

Compose 文件变化不会自动应用；必须由用户再次运行 `up -d`。仅把新项目文件放进
仓库不会自动部署。`restart: unless-stopped` 只负责已创建容器在 Docker/系统重启
后的恢复，不会重新拉取镜像或重建配置。

停止示例（保留镜像和所有数据）：

```bash
sudo docker compose down
```

不要使用 `down -v`、`docker volume prune` 或
`docker system prune -a --volumes`，除非用户针对具体数据明确授权。

## 6. 首次部署前置检查

本阶段的 Docker 代码可以和上一阶段的校园网/Mihomo 一起首次部署，但不要把上一
阶段当作已经验收。切换前在目标机检查：

```bash
systemctl status campus-login
systemctl status mihomo
sudo proxyctl status
tailscale status
systemctl status sshd
```

并确认：

- 能从第二台设备通过 SSH 登录。
- Tailscale 可用。
- 有一个可回退的旧 NixOS generation 和本地 TTY 路径。
- 校园网凭据已按 `SERVER_NETWORK.md` 安装；真实 Profile 不应提交到仓库。
- 切换前停止旧的 Clash Verge，避免与 Mihomo 争用 7897。
- 当前网络变更只在用户明确授权、且具备回退路径时执行。

上一阶段尚未部署时，不能把“静态构建通过”写成“校园网/Mihomo 已验收”。

## 7. 部署与启动

在目标机准备好本仓库后（路径按实际 clone 位置替换）：

```bash
# 先只构建/求值；是否切换由用户决定
nix flake check --no-build
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel

# 用户明确授权后
sudo nixos-rebuild switch --flake .#nixos
```

切换后：

```bash
systemctl is-enabled docker
systemctl status docker
sudo docker info
sudo docker compose -f deploy/nixos-smoke/compose.yaml config -q
```

如果 `docker compose` 不被识别，使用同一包的 standalone 入口
`sudo docker-compose -f ...`；不要为 CLI 发现机制修改 Docker socket 或权限。

首次启动冒烟服务：

```bash
cd deploy/nixos-smoke
sudo docker compose up -d
sudo docker compose ps
curl --noproxy '*' http://127.0.0.1:18080/
```

## 8. 重启恢复验证

已部署容器通过 `restart: unless-stopped` 恢复。可以先验证 Docker daemon 重启：

```bash
sudo systemctl restart docker
sudo docker compose ps
sudo docker compose logs --tail=20
```

完整系统重启属于改变可达性的操作，只有在用户明确授权且具备 SSH/TTY 回退时
才执行。重启后应重新检查：

```bash
systemctl is-enabled docker
systemctl status docker
sudo docker ps
sudo docker compose ps
curl --noproxy '*' http://127.0.0.1:18080/
```

注意区分：

- Docker daemon 开机启动：NixOS 配置负责。
- 已创建容器恢复：Compose 的 restart policy 负责。
- Git 里的 Compose 变更：不会自动应用。
- 新项目文件：不会因为存在于仓库而自动部署。

## 9. 网络与安全验证

静态边界：

- `127.0.0.1:18080` 只绑定 loopback。
- 不增加 `networking.firewall.allowedTCPPorts` 的 18080。
- 第三阶段由宿主机 Caddy 使用 80/443；这不是 Docker `ports`，也不允许业务
  容器自行绑定公网端口。入口细节见 [`SERVER_INGRESS.md`](SERVER_INGRESS.md)。
- Docker API 不监听 TCP；不开放数据库端口。
- 不改变 SSH、Tailscale 或 campus-login 的防火墙策略。

实际部署后不能只看 `ss` 或 NixOS 防火墙配置，还要检查 Docker 规则：

```bash
sudo docker ps
sudo docker network ls
sudo docker network inspect bridge
sudo nft list ruleset
sudo ss -lntup
```

从另一台设备分别测试宿主机的校园网 IPv4 和 IPv6 地址，确认 18080 不能从远程
访问（预期连接拒绝/超时，而不是返回 Nginx 页面）。同时确认：

- 校园网认证仍正常。
- Tailscale 节点仍在线，SSH 未被 Docker 规则影响。
- `getent hosts`/DNS 未被 Docker 覆盖。
- Docker bridge/NAT 没有改变校园网默认路由。

若出现端口意外暴露或网络异常，先停止冒烟服务：

```bash
cd deploy/nixos-smoke
sudo docker compose down
```

不要用关闭 NixOS firewall、打开所有 bridge 的 trusted 接口或关闭 reverse-path
filter 来“修复”问题。需要回退 generation 时见第 12 节。

## 10. 日志与资源

- daemon 默认容器日志：`json-file`，`max-size=10m`，`max-file=3`。
- Compose 示例显式设置相同轮转。
- 查看日志：`sudo docker compose logs --tail=100`。
- 不启用自动 prune；不要为了“清理空间”删除现有 image、container 或 volume。
- 示例限制 128 MiB 内存、64 个 PID、0.50 CPU；后续服务按业务单独评估。

## 11. 备份与数据恢复

当前 `modules/backup.nix` 的 Restic 仍是手动关闭状态，本阶段不启用备份，也不
修改备份策略。未来启用时必须把以下内容纳入计划：

- `/srv/containers` 下的所有 bind mount 数据。
- `/var/lib/docker/volumes` 中的 named volume（不能只备份 Compose 文件）。
- 数据库使用一致性快照或数据库原生 dump；不要假设复制在线 PostgreSQL 数据目录
  就是可靠备份。
- 定期做恢复演练。
- NixOS generation 回滚只回滚系统和镜像引用，不回滚容器数据。

## 12. 故障与回滚

### 镜像拉取失败

```bash
systemctl status mihomo
sudo proxyctl status
curl --noproxy '*' -I http://127.0.0.1:7897
journalctl -u docker -n 100 --no-pager
```

Mihomo 没启动时 Docker 仍能运行已有镜像；先修复代理，不要给 Docker 增加对
Mihomo 的硬依赖，也不要把 7897 暴露到外部。

### Docker 启动失败

```bash
systemctl status docker
journalctl -u docker -n 100 --no-pager
sudo nixos-rebuild switch --rollback
```

### 停止服务并回滚系统

先停止/删除测试容器和项目网络（不删除 volume）：

```bash
cd deploy/nixos-smoke
sudo docker compose down
```

再回退 NixOS generation：

```bash
sudo nixos-rebuild switch --rollback
# 或仅准备下次启动回退
sudo nixos-rebuild boot --rollback
```

不要执行 `docker system prune`、`docker volume prune` 或 `down -v`。不要删除
`/srv/containers` 或 `/var/lib/docker` 来“恢复”。如果 Docker 删除后仍有网络异常，
保留现场并检查 `nft list ruleset`、`docker network inspect bridge`、SSH/Tailscale，
而不是关闭防火墙。

## 13. 验收清单

已通过静态/构建验证的项目以最终提交报告为准。以下必须在实机执行后才算通过：

- [ ] 首次 switch 成功，Docker 和 Compose 可用。
- [ ] `docker info` 显示 daemon 正常运行，代理环境正确。
- [ ] `docker compose up -d` 后只监听 `127.0.0.1:18080`。
- [ ] 从第二台设备无法访问 IPv4/IPv6 的 18080。
- [ ] `nft list ruleset`、`docker network inspect bridge` 无意外全局放行。
- [ ] 校园网认证、DNS、Tailscale、SSH 未受影响。
- [ ] Docker daemon 重启后容器恢复。
- [ ] 完整重启后容器恢复（需用户授权）。
- [ ] 失败时能 `docker compose down` 并回退 generation，数据未丢失。

## 14. 下一阶段

第三阶段的公网入口已经按以下链路实现，详见
[`SERVER_INGRESS.md`](SERVER_INGRESS.md)：

```text
Internet IPv6
    |
NixOS firewall (TCP 80/443)
    |
宿主机 Caddy
    |
127.0.0.1:<app-port>
    |
Docker service
```

不要把当前 18080 测试端口直接开放到公网，也不要用反向代理容器替代宿主机
Caddy。公网 SSH 仍是独立的安全变更，不能因为已有 HTTPS 入口就默认开放密码
登录。
