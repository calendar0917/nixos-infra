# Hermes Agent 本地部署

本目录只部署在 `main` 主机：一个官方 `nousresearch/hermes-agent` 容器，同时运行
Hermes Gateway、Webapp、Dashboard 和 QQ 官方 Bot 通道。使用 Docker bridge
网络，宿主机端口发布在 `0.0.0.0`（loopback、局域网和 Tailscale 都可访问），
不发布 Gateway API 8642，不使用 host networking、Funnel 或公网端口转发。

```text
本机 / 局域网 / Tailscale 设备
   │  http://127.0.0.1:9120  http://<TAILSCALE_IPV4>:9120  Webapp
   │  http://127.0.0.1:9119  http://<TAILSCALE_IPV4>:9119  Dashboard
   ▼
nvme 主机 docker-proxy（绑定 0.0.0.0:9119、0.0.0.0:9120）
   ▼
hermes-agent 容器
   ├─ gateway run（Gateway + Webapp :9120）
   ├─ dashboard（:9119）
   └─ QQ 官方 Bot（仅在凭据和 OpenID 齐备时启用）
```

## 文件与秘密边界

| 路径 | 说明 | 是否进 Git |
| --- | --- | --- |
| `compose.yaml` | 固定容器模型 | 是 |
| `.env.example` | 模板，不含真实秘密 | 是 |
| `.env` | 当前 Tailscale IP、pin 后的镜像 digest、UID/GID | 否，`0600` |
| `data/.env` | Hermes API key、Web 密码、Session Secret、QQ Secret | 否，`0600` |
| `data/config.yaml` | Hermes 配置（Webapp、QQ、模型等） | 否，`0600` |
| `data/` | SQLite、sessions、skills、日志等运行时状态 | 否 |

`data/` 属于运行账户 `calendar`，目录权限 `0700`。Compose 使用镜像官方的
`HERMES_UID`/`HERMES_GID` 重映射到宿主机 UID/GID，这样容器写入的文件仍由
`calendar` 拥有；没有使用 Compose `user:`，也没有 `read_only`、`cap_drop: ALL`
或 Docker Socket 挂载。

## 初始化

```bash
cd deploy/hermes
./scripts/init.sh
```

脚本会：

1. 检查当前用户、Git 仓库位置、Docker/Compose、Tailscale；
2. 用 `tailscale ip -4` 取得 IPv4，并确认它确实在本机 Tailscale 接口上；
3. 生成 `.env`，写入 `TAILSCALE_IPV4`、`HERMES_IMAGE`、`HERMES_UID/GID`；
4. 创建 `data/`、`data/.gitignore`；
5. 拉取 `nousresearch/hermes-agent:stable`，把实际 digest 固定进 `.env`；
6. 用镜像官方 `setup --non-interactive` 初始化配置和运行时目录；
7. 生成随机的 Web 登录密码和独立的 Session Secret（不打印）；
8. 合并 `webapp` 和 `platforms.qqbot`，保留已有模型和平台设置；
9. 检查 QQ App ID、Secret、OpenID；不齐备时把 QQ 保持为禁用；
10. 输出不含秘密内容的状态。

再次运行 `init.sh` 是幂等的：已有的模型配置、API key、QQ Secret、Web
密码/Secret 和会话数据不会被覆盖；只有缺失的字段才会补上。如果 `hermes-agent`
正在运行，`init.sh` 会先停止它，避免初始化容器与线上实例同时使用同一份
SQLite/QQ 会话；初始化完成后需要再执行 `scripts/start.sh`。

> 初始化只使用官方镜像的 entrypoint 和 s6 监督机制。不要改成
> `docker run --entrypoint` 或 `--user`，也不要挂载 `/home/calendar`、
> `/nix/store`、`/var/run` 或 SSH 私钥目录。

## 启动、停止、日志

```bash
cd deploy/hermes

# 启动/应用最新 .env；先检查 Tailscale，再执行 compose up -d
./scripts/start.sh

# 停止（保留 data/）
sudo docker compose --env-file .env stop

# 停止并删除容器（data/ 和 .env 仍保留）
sudo docker compose --env-file .env down

# 日志
sudo docker compose --env-file .env logs -f --tail=100
sudo docker compose --env-file .env logs --tail=200 hermes

# 健康与安全边界检查
./scripts/check.sh
```

`start.sh` 会：

- 拒绝 Tailscale 离线或没有 IPv4 的状态（`webapp.public_url` 和 Dashboard
  可信来源依赖它）；端口绑定固定为 `0.0.0.0`，不再随 IP 变化；
- 比较当前 IP 与 `.env`，变化时更新 `.env` 和
  `data/config.yaml` 的 `webapp.public_url`；
- 执行 `docker compose config --quiet`；
- 解析 Compose 模型，确认 9120/9119 的 `host_ip` 是 `0.0.0.0`，
  且没有 8642 或其他宿主端口；
- 运行 `sudo docker compose up -d`，再检查容器的实际端口绑定。

Docker 命令沿用仓库现有工作流：`sudo docker compose`。不要把 `calendar`
加入 `docker` 组。

## 访问地址（本机 / 局域网 / Tailscale）

端口发布在 `0.0.0.0`，本机、同一局域网和 tailnet 设备都能连。推荐地址：

```text
本机:     http://127.0.0.1:9119  http://127.0.0.1:9120
Tailscale: http://<TAILSCALE_IPV4>:9119  http://<TAILSCALE_IPV4>:9120
局域网:   http://<主机局域网IPv4>:9119  http://<主机局域网IPv4>:9120
```

`webapp.public_url` 只能写一个地址，它是 Webapp 的“同源”基准：Webapp 的
cookie 写入（发消息、改设置）只接受这个地址。当前值取自
`TAILSCALE_IPV4`，所以 **Webapp 请用 Tailscale 地址打开**；从
`http://127.0.0.1:9120` 打开可以登录和浏览，但写操作会返回 403
（"Cookie-authenticated writes must come from the Webapp's own origin"）。
Dashboard (`9119`) 不受这个限制，localhost 和局域网地址都能正常操作。

如果只在笔记本本地用 Webapp，可以把 `data/config.yaml` 的
`webapp.public_url` 改成 `http://127.0.0.1:9120` 并重启；代价是反过来
Tailscale 地址上的写操作会被拒绝。

本机可以用：

```bash
ip=$(grep '^TAILSCALE_IPV4=' deploy/hermes/.env | cut -d= -f2)
curl --noproxy '*' -I "http://127.0.0.1:9119/"
curl --noproxy '*' -I "http://$ip:9119/"
```

未认证时页面应跳转到登录页，`/api/config` 应返回 401。`/api/status` 是公开的只读
状态接口，不用于判断受保护内容。仓库没有修改 NixOS 防火墙、Tailscale ACL 或
Docker daemon；端口绑定是 `0.0.0.0`，所以同网段设备也能连到登录页，能否进入
只取决于密码。没有第二台设备时，“从另一台设备访问”只能标记为“待人工验证”。

## 容器访问宿主机服务

容器和宿主机是两个 netns，容器里的 `localhost` 是容器自己。Compose 里加了

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

所以从容器内用 `host.docker.internal` 就能指到宿主机地址。它是一个 `host-gateway`
别名，指向 Docker daemon 的默认网桥 `docker0`（当前 `172.17.0.1`），而不是容器所在
compose 网络的网关 `172.21.0.1`；两者都是宿主机地址，只要有服务监听 `0.0.0.0`
就都能连上。核对方式：

```bash
# 容器视角的网关
sudo docker inspect hermes-agent --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
sudo docker network inspect hermes_default --format '{{(index .IPAM.Config 0).Gateway}}'
# 宿主机侧的网桥地址
ip -4 -o addr show | grep br-

# 容器内测试
sudo docker exec -u hermes hermes-agent \
  curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:8090/
```

只有监听在 `0.0.0.0` 或该网桥地址上的服务才可达。只绑 `127.0.0.1` 的宿主机
服务（例如部分代理）容器永远连不到，需要改监听地址、在宿主机做 `socat` 转发，
或者接受这部分功能不可用；不要为此改成 host networking。

本机的 AxonHub 监听 `0.0.0.0:8090`，因此在 `hermes setup model` 里可以直接填
OpenAI-compatible 的 Base URL：`http://host.docker.internal:8090/v1`（或
`http://100.67.68.157:8090/v1`）。注意 `172.21.0.1` 这类 bridge 地址只在
宿主机和容器网络内有效，浏览器访问请用局域网或 Tailscale 地址。

## Web 登录认证

`data/.env` 中保存：

```dotenv
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<init.sh 随机生成>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<init.sh 独立随机生成，至少 32 字节>
```

- 密码由 `secrets.token_urlsafe()` 生成，不是固定示例值；密码长度本身没有下限，
  自己改短也可以；
- Session Secret 独立生成，用于签名登录会话。Hermes 拒绝短于 16 字节的
  Secret，且被拒绝时 basic-auth 不会注册，Dashboard 会 fail-closed 拒绝绑定；
  因此 `init.sh` 把小于 32 字符的值视为需要重置（会打印一行提示，不打印值）。
  需要看重置后的新值就重新读取 `data/.env`，不要在聊天或日志里传播；
- `data/.env` 权限为 `0600`；
- 不使用 `HERMES_DASHBOARD_INSECURE`；
- Webapp 的 `webapp.public_url` 和 Dashboard 的非 loopback 绑定都会启用
  Hermes 原生认证；Webapp 与 Dashboard 共用同一组密码认证。

查看密码必须由本机用户主动读取，且不要把结果贴到聊天、PR 或日志：

```bash
sudo -u calendar sed -n 's/^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=//p' data/.env
```

验证方法：

```bash
# 未认证的受保护 API 必须是 401
ip=$(grep '^TAILSCALE_IPV4=' .env | cut -d= -f2)
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' "http://$ip:9120/api/config"
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' "http://$ip:9119/api/config"

# 然后在浏览器中打开登录页，使用 admin + data/.env 中的密码
```

`scripts/check.sh` 会自动完成上面两步、正确密码登录、错误密码拒绝和带会话
访问页面/API 的检查；它不会输出密码。

保留 `HERMES_DASHBOARD_BASIC_AUTH_SECRET` 不变，容器重启后已有会话继续有效。
如果更换 Secret，所有旧会话都会失效，这是有意的会话轮换。

## QQ 官方机器人

只使用腾讯官方 QQ Bot API；不使用 NapCat、OneBot 或非官方协议。

### 申请与获取 OpenID

1. 在 [QQ 开放平台](https://q.qq.com/) 创建机器人应用，取得 **App ID** 和
   **Client Secret**；
2. 在官方后台配置沙箱/正式环境、消息事件和私聊能力；
3. 从官方后台的事件调试或沙箱消息事件中取得用户的 `openid`。OpenID 是应用
   维度的标识，**不是 QQ 号码**，不要猜；
4. 不要为了拿 OpenID 临时打开“所有人可用”或群聊。

### 配置

用本地编辑器写入 `data/.env`，不要通过聊天或命令历史传递 Secret：

```dotenv
QQ_APP_ID=<官方 App ID>
QQ_CLIENT_SECRET=<官方 Client Secret>
QQ_ALLOWED_USERS=<用户 openid>
QQBOT_HOME_CHANNEL=<同一个用户 openid>
QQ_ALLOW_ALL_USERS=false
GATEWAY_ALLOW_ALL_USERS=false
```

```bash
chmod 600 data/.env
./scripts/init.sh      # 幂等；补全并合并 platforms.qqbot
./scripts/start.sh
./scripts/check.sh
```

初始化后 `data/config.yaml` 中的 QQ 配置应为：

```yaml
platforms:
  qqbot:
    enabled: true
    extra:
      dm_policy: "allowlist"
      allow_from:
        - "<用户 openid>"
      group_policy: "disabled"
      group_allow_from: []
```

`init.sh` 只有在 App ID、Client Secret 和至少一个 OpenID 都非空时才把
`platforms.qqbot.enabled` 设为 `true`。缺任意一项时保持 `false`，Webapp 继续
正常部署；这比启动一个默认开放私聊的机器人安全。

QQ 与 Webapp 共享同一个 Hermes 实例和 `data/` 状态，但不额外实现跨通道对话
自动同步。授权用户私聊应正常；其他用户和所有群聊应被拒绝。真实 QQ 私聊和
群聊拒绝必须用真实账号验证，不能仅凭配置声称通过。

## Tailscale IP 变化

IP 变化时不需要改 NixOS：

```bash
cd deploy/hermes
./scripts/start.sh
```

端口绑定固定为 `0.0.0.0`，IP 变化只影响 URL。`start.sh` 会发现 `.env` 与
`tailscale ip -4` 不一致，更新：

- `.env` 的 `TAILSCALE_IPV4`；
- `data/config.yaml` 的 `webapp.public_url`；
- Dashboard 的 `HERMES_DASHBOARD_PUBLIC_URL`（Compose 环境变量随 `.env` 更新）。

如果 Tailscale 尚未就绪，脚本会失败并提示，避免写入一个过期或空的
`public_url`。

## 休眠与开机顺序限制

- 笔记本休眠后 Hermes 容器、QQ WebSocket 和 Tailscale 连接都可能暂停；唤醒后
  先确认 Tailscale 在线，再运行 `./scripts/start.sh` 和 `./scripts/check.sh`。
- `0.0.0.0` 绑定不再依赖 `tailscale0` 出现，所以开机顺序本身不会让端口绑定
  失败；但 `webapp.public_url` 和 Dashboard 的公开地址仍是 Tailscale 地址，
  Tailscale 尚未就绪时先跑 `./scripts/start.sh` 会直接报错。开机后等
  `tailscale status` 正常再启动即可。
- 第一版没有新增全局 systemd 服务，也没有修改 Tailscale 系统设置。恢复命令：

```bash
sudo systemctl status docker tailscaled --no-pager
tailscale status
cd deploy/hermes && ./scripts/start.sh
```

如果容器反复重启，先看日志再重启 Docker；不要删除 `data/`：

```bash
sudo docker compose --env-file .env logs --tail=200
sudo systemctl restart docker
cd deploy/hermes && ./scripts/start.sh
```

## 备份

备份包含 SQLite 会话、skills、配置和秘密，必须加密保存。先停止写入，再打包
`data/`：

```bash
cd deploy/hermes
sudo docker compose --env-file .env stop

stamp=$(date +%Y-%m-%d-%H%M%S)
umask 077
tar -C . -czf "/tmp/hermes-data-$stamp.tar.gz" data

# 使用 age 口令加密（推荐；若本机没有 age，使用下面的 gpg）
age -p -o "$HOME/hermes-backup-$stamp.tar.gz.age" "/tmp/hermes-data-$stamp.tar.gz"
shred -u "/tmp/hermes-data-$stamp.tar.gz"
sha256sum "$HOME/hermes-backup-$stamp.tar.gz.age"

# 或 gpg 对称加密
# gpg --symmetric --cipher-algo AES256 -o "$HOME/hermes-backup-$stamp.tar.gz.gpg" "/tmp/hermes-data-$stamp.tar.gz"
```

同时用密码管理器单独保存解密口令。`data/.env`、`.env` 和模型/QQ 凭据都属于
备份内容；未加密的 tar 不得留在磁盘、U 盘或云盘。恢复前先验证归档可解密、
可解包，并在一台隔离机器上测试。

## 迁移到独立服务器

迁移必须保证同一时间只有一个实例使用同一组 QQ 凭据和会话数据库：

1. 在旧机执行 `./scripts/start.sh` 前先 `stop`，确认容器已停止；
2. 按上面的方式加密备份完整 `data/`，同时保留 `deploy/hermes/.env`
   （或至少保留镜像 digest 和 UID/GID 约定）；
3. 在新服务器安装 Docker/Compose、Tailscale 和 Git，克隆仓库；
4. 在新机恢复 `data/`，确认属主是运行账户、`data/` 为 `0700`、
   `data/.env` 为 `0600`；
5. 在新机运行 `./scripts/init.sh` 更新 `TAILSCALE_IPV4`，再运行
   `./scripts/start.sh`；
6. 在新机通过 `./scripts/check.sh` 和真实 QQ 私聊验证后，才让旧机下线。

不要在旧机和新机同时运行 `gateway run`，否则 QQ 会话、SQLite 和消息去重会
互相冲突。

## 镜像升级与回滚

`.env` 中的 `HERMES_IMAGE` 必须固定到 digest。不要长期使用 `stable` 或
`latest` 浮动标签。

升级：

```bash
cd deploy/hermes
# 先备份（见上）
sudo docker pull nousresearch/hermes-agent:stable
sudo docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  nousresearch/hermes-agent:stable | grep '^nousresearch/hermes-agent@sha256:'

# 把新的 digest 写入 .env 的 HERMES_IMAGE，保留旧 digest 作为回滚记录
# 然后：
./scripts/start.sh
./scripts/check.sh
```

升级后至少验证 Webapp、Dashboard、QQ 私聊和模型回复。Hermes 可能对
`data/config.yaml` 或数据库做向前迁移；升级前没有备份时不要直接回滚镜像。

回滚：

```bash
cd deploy/hermes
# 备份当前 data/，因为旧镜像可能不认识新配置/数据库
# 将 HERMES_IMAGE 改回旧 digest
./scripts/start.sh
./scripts/check.sh
```

如果旧镜像无法读取新数据库，只能恢复升级前的加密备份和对应镜像 digest。

## 安全边界

- 宿主机端口发布在 `0.0.0.0`：`9120` Webapp、`9119` Dashboard，loopback、
  局域网和 Tailscale 都能访问；两个端口都强制登录，局域网设备不需要
  Tailscale 就能看到登录页，所以密码强度就是这一层的边界；
- 不发布 `8642` Gateway API；
- 不使用 Docker host networking、`privileged`、Docker Socket 或宿主机
  `/home/calendar`；
- 不挂载 `/nix/store`、`/var/run`、SSH 私钥目录或其他服务的数据目录；
- 不修改 NixOS 防火墙、Tailscale ACL 或 Docker daemon 全局配置；
- QQ 默认 `dm_policy: allowlist`、`group_policy: disabled`，
  `QQ_ALLOW_ALL_USERS=false`、`GATEWAY_ALLOW_ALL_USERS=false`；
- 不自动安装渗透测试工具，不赋予 Hermes 宿主机管理能力；
- 不读取仓库已有的 secrets 文件内容，不把模型/QQ/Web 密钥写入 Nix Store。

## 已知待人工验证项目

- 第二台 Tailscale 设备、以及同网段非 Tailscale 设备的访问和 ACL 边界；
- 笔记本重启后 Docker 与 Tailscale 的启动顺序；
- 真实 QQ 账号的授权私聊、非授权用户拒绝和群聊拒绝；
- 休眠/唤醒后 QQ WebSocket 的恢复；
- 配置模型后的真实回复。当前环境没有提供模型 API Key 时，模型设置保留为
  手动入口：

```bash
cd deploy/hermes
sudo docker compose --env-file .env run --rm hermes setup model
```

如果需要 OpenAI-compatible 服务，使用 `hermes setup model` 选择 `custom`，
填写已有的 API base URL、模型名和 Key；密钥只写入 `data/.env` 或
`data/config.yaml` 的本地运行文件，不进入 Compose、Git 或文档。
