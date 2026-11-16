# nixos-smoke

小主机的 Docker/Compose 冒烟服务。它只用于验证 Docker Engine、bridge 网络、
DNS、端口绑定、日志和重启恢复，不是业务服务。

## 边界

- 只发布到 `127.0.0.1:18080`，不监听 `0.0.0.0` 或 IPv6。
- 使用 `nginx:1.27.4-alpine` 固定版本，不使用 `latest`。
- 根文件系统只读，`/var/cache/nginx`、`/var/run` 和 `/tmp` 使用 tmpfs。
- `no-new-privileges` 开启；没有 `privileged`、host network、Docker socket
  挂载或主机目录挂载。
- 日志使用 `json-file`，`10m × 3` 轮转。
- 没有秘密、真实账号或持久化数据。数据目录约定见
  [`docs/SERVER_DOCKER.md`](../../docs/SERVER_DOCKER.md)。

Compose project name 已固定为 `nixos-smoke`，不要用 `-p` 覆盖。

## 手动操作

```bash
cd deploy/nixos-smoke

# 只校验，不启动容器
sudo docker compose config -q

# 启动/更新
sudo docker compose up -d

sudo docker compose ps
curl --noproxy '*' http://127.0.0.1:18080/
sudo docker compose logs --tail=50
```

修改 `compose.yaml` 后不会自动生效，需要用户明确再次运行 `sudo docker compose up -d`。
容器使用 `restart: unless-stopped`，Docker daemon 或系统重启后已创建的容器会恢复；
仅把文件放在 Git 里不会自动创建项目。

停止并删除容器和项目网络（保留镜像）：

```bash
sudo docker compose down
```

不要把 `down` 改成 `down -v`，也不要运行 prune，除非用户针对具体数据明确授权。
本示例没有命名 volume 或宿主机数据目录；未来服务的数据应放在
`/srv/containers/<service-name>/data` 和 `config`，并按服务单独确定 UID/GID。
