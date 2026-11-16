# 小主机无人值守网络与 Mihomo

本文针对 `nixosConfigurations.nixos`（KOLOE 小主机）。目标是：不依赖图形登录
完成锐捷校园网认证，运行无 GUI 的 Mihomo，通过 `proxyctl` 管理本地 YAML 和
HTTPS 订阅，同时保留 Tailscale、SSH、Nix 下载和回滚能力。

当前仓库中的声明式配置和 Python 实现不能代替实机验收。本文把所有需要现场执行
或需要用户提供凭据的步骤单独标出。

## 1. 组件与边界

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| 校园网认证 | `hosts/nixos/campus.nix`、`hosts/nixos/scripts/campus-login.py` | systemd 系统服务，开机即运行，不依赖桌面 |
| Mihomo | `hosts/nixos/proxy.nix` | 使用 nixpkgs `services.mihomo`，无 GUI、无 TUN |
| 管理 CLI | `hosts/nixos/scripts/proxyctl.py` | 系统命令 `proxyctl` |
| 运行时数据 | `/etc/mihomo` | root-only，运行时创建，不进入 Git/Nix store |
| 凭据 | `/etc/campus-network` | root-only，运行时安装，不使用 SOPS |

保留 niri、Sway、SDDM、Tailscale、NetworkManager、systemd-resolved、nftables
和现有 SSH 配置。本次不启用 Docker、IPv6 DDNS、反向代理、HTTPS 或公网 SSH，
也不把 7897/9090 开放到局域网或公网。

### 1.1 固定监听约束

`proxyctl` 生成运行配置时会强制覆盖以下值，不信任机场 YAML 自带的监听参数：

```yaml
mixed-port: 7897
allow-lan: false
bind-address: 127.0.0.1
external-controller: 127.0.0.1:9090
tun:
  enable: false
```

同时移除 `port`、`socks-port`、`redir-port`、`tproxy-port`、`listeners`、
`external-controller-unix`、`external-controller-pipe`、`external-ui`、控制器
TLS 证书和 `dns.listen`。非空的额外 `listeners` 会被明确拒绝，而不是静默删除。
代理节点、策略组、规则和 provider 内容会保留；依赖 `/home` 或绝对路径的
provider 会被拒绝。

## 2. 凭据：校园网账号密码

真实账号密码只由管理员在目标机器本地安装，不写入仓库、Nix store、systemd
`ExecStart` 参数或 journald。不要使用 `sudo proxyctl add` 之类的命令承载凭据。

创建 root-only 文件和目录（`sudoedit` 交互输入，不进入 shell history）：

```bash
sudo install -d -m 0700 -o root -g root /etc/campus-network
sudo install -m 0600 -o root -g root /dev/null /etc/campus-network/username
sudo install -m 0600 -o root -g root /dev/null /etc/campus-network/password
sudoedit /etc/campus-network/username
sudoedit /etc/campus-network/password
```

也可以在当前终端隐藏密码输入：

```bash
sudo bash -c '
  umask 077
  IFS= read -r -s -p "Campus password: " p; echo
  printf "%s\n" "$p" > /etc/campus-network/password
'
```

检查权限，不要输出文件内容：

```bash
sudo stat -c '%a %U:%G %n' /etc/campus-network /etc/campus-network/*
```

服务使用 systemd `LoadCredential` 读取这两个文件。缺少文件时，服务日志会指出
缺少的路径；脚本手工运行时仍保留下面的方式：

```bash
WIFI_USERNAME=... WIFI_PASSWORD=... python3 campus-login.py -c
WIFI_USERNAME=... WIFI_PASSWORD=... python3 campus-login.py -u ... -d
```

不要在日常 shell 中把真实密码写进历史。`-c` 只做连通性检查，不需要凭据。

## 3. 校园网服务

服务名：

```text
campus-login.service
```

行为：

- `WantedBy=multi-user.target`，不依赖 SDDM、niri、Sway 或用户登录。
- 在 `NetworkManager.service` 之后启动，但不要求校园网认证已经成功。
- 常驻 Python daemon 自己完成保活循环；没有额外的 systemd timer。
- 网络未就绪、HTTP 超时或认证失败时，脚本继续重试；进程异常退出后 systemd
  在 15 秒后重启，并关闭 start-limit，便于安装凭据后自动恢复。
- 请求不继承系统代理（`trust_env=False`），避免通过 Mihomo 访问 Portal。
- 使用当前系统路由出口，兼容有线和 Wi-Fi。

查看状态和日志：

```bash
systemctl status campus-login.service
journalctl -b -u campus-login.service --no-pager
journalctl -f -u campus-login.service
```

日志状态含义：

| 日志 | 含义 |
| --- | --- |
| `already-online` | 已连通，无需认证 |
| `online (verified)` | 认证后通过 204/HTTPS 验证 |
| `submitted-unverified` | Portal 接受提交，但连通性尚未恢复 |
| `auth-failed` | Portal 明确拒绝 |
| `portal-unknown` | Portal 返回页面但不具备可识别的跳转/参数 |
| `network-error` | 超时、DNS 或链路错误；只记录异常类型 |
| `Credential configuration error` | 凭据文件缺失、为空或不可读 |

### 3.1 Portal 是 HTTP 的现实限制

原始认证流程使用 `http://110.184.24.61` 的锐捷 Web Portal / CAS SSO。当前没有
经过验证的 HTTPS Portal 端点，因此不能虚构一个 HTTPS 地址或强制改成 HTTPS。
脚本会在 HTTP 结果不确定时额外做一次独立的 HTTPS 连通性验证，但认证请求本身
仍走 Portal 提供的 HTTP 入口。

脚本不会记录密码、AES 加密后的密码、完整认证 URL、`sessionId`、CAS token 或
`customPageId`；Portal 查询参数只在本进程内使用。`journalctl` 中不应出现这些
值。

## 4. Mihomo 运行时目录

全部在运行时创建，目录/文件为 root-only：

```text
/etc/mihomo/
├── profiles/          # 本地 YAML 和下载后的订阅原始内容
├── sources/           # <name>.url，HTTPS 订阅地址
├── active.yaml        # 当前规范化运行配置
├── active-name        # 当前 Profile 名称
├── last-good.yaml     # 上一次验证成功的运行配置（回滚副本）
└── api-secret         # 随机 API secret
```

`active.yaml`、`api-secret`、订阅 URL 和 profile 不应进入 Git。不要用
`environment.etc.*.text` 生成这些文件。

Mihomo 的缓存、provider 数据和规则由 NixOS `services.mihomo` 的
`StateDirectory` 持久化到 `/var/lib/private/mihomo`，不需要 `proxyctl` 管理。

## 5. 首次部署顺序

以下步骤需要用户在目标机器上执行。仓库不会自动 switch、重启或真实断网。

### 5.1 预检

从另一台可 SSH 的机器或本地 TTY 确认：

```bash
ssh calendar@<nixos-address> hostname
tailscale status
systemctl status NetworkManager
resolvectl status
ip route
```

同时确认当前 generation 和回滚路径：

```bash
nix-env -p /nix/var/nix/profiles/system --list-generations | tail
readlink /run/current-system
```

### 5.2 构建但不切换

```bash
cd ~/nixos-infra
nix flake check --no-build
nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel
```

仓库层面的无网络回归可以在任意开发机执行：

```bash
scripts/check-server-network
```

它只构建测试用 Python 环境并运行单元测试，不启动服务、不读取真实凭据。

如果服务器网络无法访问 GitHub，只给当前的 `nix` 客户端临时设置代理即可：

```bash
export https_proxy=http://127.0.0.1:7897
export http_proxy=http://127.0.0.1:7897
```

在 switch 前，旧系统可能还没有 Mihomo，因此这个 7897 可能是当前的 Clash Verge。
不要把代理环境写进 `/etc/nixos` 或长期 shell 配置；`modules/base.nix` 已经为
Nix daemon/客户端配置固定的 loopback 代理。

### 5.3 安装凭据

先完成第 2 节的凭据安装。此时只安装文件，不启动新服务：

```bash
sudo stat -c '%a %U:%G %n' /etc/campus-network /etc/campus-network/*
```

### 5.4 关闭旧 Clash Verge（迁移时）

当前小主机旧配置使用 Clash Verge Rev。切换前关闭 GUI 和旧服务，避免与 Mihomo
争用 7897：

```bash
pkill -u calendar -x clash-verge || true
sudo systemctl stop clash-verge.service
ss -ltnp 'sport = :7897'
```

如果 7897 仍有监听，不要继续启动 Mihomo；先查明进程。保留 SSH/Tailscale 的
可达性，不要为了释放端口关闭防火墙。

### 5.5 切换：先验证校园网，再导入 Profile

在用户确认维护窗口和回滚路径后执行：

```bash
sudo nixos-rebuild switch --flake .#nixos
```

这次 switch 会安装 `proxyctl`、启用 `campus-login.service`，并把 Clash Verge
从配置中移除。因为还没有 `active.yaml`，`mihomo.service` 会启动失败并等待
配置；这不影响 NetworkManager、SSH 或 Tailscale。

先只验证校园网和桌面无关的服务：

```bash
systemctl status campus-login.service
journalctl -b -u campus-login.service --no-pager
```

等待日志出现 `State: online (verified)` 或 `State: already-online`。确认校园网
恢复后，再初始化 Mihomo 状态并导入 Profile：

```bash
sudo proxyctl init
sudo proxyctl add local /path/to/local.yaml
sudo proxyctl add airport /path/to/airport.yaml

# 或者只保存订阅地址，再下载：
sudo proxyctl set-url airport
# 交互输入 HTTPS URL；输入不回显，不进入 shell history
sudo proxyctl refresh airport
sudo proxyctl refresh airport --via-proxy   # 直连失败时，经当前 7897 下载
```

`refresh` 只更新 `profiles/<name>.yaml`，不会自动切换当前运行配置，也不会新增
订阅更新 timer。若订阅只能经代理下载，先用一个本地 Profile 完成下面的 `use`，
再执行 `refresh --via-proxy`；不要在没有可用 7897 监听者时假设代理刷新会成功。

最后激活一个已验证 Profile：

```bash
sudo proxyctl use local
proxyctl status
proxyctl test
```

`use` 会先做 YAML 规范化、`mihomo -t` 校验和本机服务检查，成功后才更新
`active-name`。它不会执行 `nixos-rebuild`。

## 6. 切换配置事务

`sudo proxyctl use <name>` 的顺序：

1. 获取 `/etc/mihomo/.proxyctl.lock` 排他锁。
2. 检查 profile 存在且为普通文件。
3. 解析并强制安全参数。
4. 保留原 profile 文件不变。
5. 在临时目录运行 `mihomo -t`。
6. 失败立即退出，不改变 active 或运行中的服务。
7. 把上一份 active 保存到 `last-good.yaml`。
8. 原子写入新的 `active.yaml`。
9. `systemctl restart mihomo.service`。
10. 检查 systemd、7897 监听、9090 API 和本机代理端口。
11. 失败时恢复上一份 active 并重启；没有上一份时移除失败的 active 并停止服务。
12. 只有成功才更新 `active-name`。

回滚判断只使用本机服务状态、监听端口和 API，不依赖 GitHub 等外部站点。

### 6.1 初始化尚未完成时

```bash
sudo proxyctl init
sudo proxyctl list
```

如果没有 profile，`list`/`use` 会明确提示先 `add`、`set-url`、`refresh`。如果
服务尚未启动或 `/etc/mihomo` 不存在，先部署本模块后再执行 `proxyctl use`。

## 7. 查看状态、测试和日志

```bash
proxyctl status          # 普通用户可看服务/监听；API secret 仍需 root
proxyctl test            # 经 127.0.0.1:7897 访问 HTTPS 测试端点
proxyctl logs            # journalctl -u mihomo.service
journalctl -b -u mihomo.service --no-pager
ss -ltnp 'sport = :7897 or sport = :9090'
```

`proxyctl status` 在普通用户下不会读取 root-only 的 active-name/secret；需要完整
信息时使用 `sudo proxyctl status`。

## 8. 策略组与节点

只通过本机 API 操作，API 固定为 `http://127.0.0.1:9090`，secret 从
`/etc/mihomo/api-secret` 读取，不放进 shell 环境变量或命令行参数：

```bash
sudo proxyctl groups
sudo proxyctl nodes <group>
sudo proxyctl select <group> <node>
```

节点/组名可以包含中文、空格和 `/`，CLI 使用 JSON 和 URL 编码处理。运行配置中
启用了 `profile.store-selected`，使 Mihomo 持久化用户选择。

## 9. 网络排查

### 9.1 判断是否被校园网认证拦截

不要只看普通 HTTP 200：

```bash
curl -I --max-time 5 http://connect.rom.miui.com/generate_204
curl -I --max-time 8 https://www.baidu.com/
journalctl -b -u campus-login.service --no-pager
```

Portal 可能用 200/3xx 返回登录页。脚本的判定是：专用 204 端点成功，或独立
HTTPS 校验成功，才算在线；只有 200 而 HTTPS 失败时记为 `captive`，不会误报。

网络链路检查：

```bash
ip route
resolvectl status
nmcli device status
nmcli connection show --active
```

### 9.2 GitHub/Nix 下载失败

先区分 flake 客户端和 daemon：

```bash
nix show-config | grep -E 'substituters|http|https'
systemctl show nix-daemon.service -p Environment --value
systemctl status nix-daemon
```

`modules/base.nix` 给 Nix 客户端和 daemon 设置：

```text
http://127.0.0.1:7897
```

loopback 直连。若代理未运行，远程 fetch/build 会失败；先确认：

```bash
systemctl status mihomo.service
proxyctl status
proxyctl test
curl -I --max-time 10 -x http://127.0.0.1:7897 https://cache.nixos.org/nix-cache-info
```

如果只是当前 SSH 会话访问 GitHub 失败，可以临时给当前命令设置
`https_proxy=http://127.0.0.1:7897`；不要修改 daemon 长期环境或 flake inputs。

### 9.3 Clash Verge 与 Mihomo 不能同时占用 7897

迁移窗口内只允许一个监听者：

```bash
ss -ltnp 'sport = :7897'
pgrep -af 'clash-verge|mihomo'
```

停止旧 GUI 和旧 service 后再启动 Mihomo。不要在 nixos 上重新启用
`my.network.clashVerge.enable`。

## 10. 故障恢复

### 10.1 Mihomo 配置导致不可用

先停止 Mihomo，保留 NetworkManager/resolved/Tailscale：

```bash
sudo systemctl stop mihomo.service
proxyctl status
ip route
resolvectl query example.com
```

优先用 CLI 切回另一个已验证 Profile：

```bash
sudo proxyctl use <other-name>
```

CLI 不可用时，手工恢复 `last-good.yaml`（这是上一次成功切换前的副本）：

```bash
sudo systemctl stop mihomo.service
sudo install -m 0600 /etc/mihomo/last-good.yaml /etc/mihomo/active.yaml
sudo systemctl start mihomo.service
```

手工恢复后 `active-name` 可能仍是失败的那个名字；确认无误后再手动修正，或
用 `proxyctl use` 重新建立一致状态。不要删除 `last-good.yaml`。

### 10.2 校园网认证失败

```bash
sudo systemctl status campus-login
sudo journalctl -b -u campus-login --no-pager
sudo stat -c '%a %U:%G %n' /etc/campus-network/*
```

检查路由和 Portal 可达性；如果是凭据文件问题，修正后 `restart` 服务即可。不要
把密码写入命令行或日志。

### 10.3 Tailscale 和 SSH 检查

```bash
tailscale status
tailscale ping <peer>
ip route get 100.64.0.1
resolvectl query <machine>.tailnet.ts.net
sudo ss -ltnp 'sport = :7897 or sport = :9090'
```

`tailscale0` 仍然在防火墙 trusted interfaces 中；Mihomo 不启用 TUN，也不改写
`systemd-resolved`。监听检查应只看到 `127.0.0.1:7897` 和
`127.0.0.1:9090`，不能看到 `0.0.0.0` 或公网 IPv6。

### 10.4 整机回滚

如果新 generation 导致无法联网但仍有 TTY/Tailscale：

```bash
sudo nixos-rebuild switch --rollback
```

或从引导菜单选择旧 generation。回滚到旧 generation 会恢复 Clash Verge 配置，
因此要同时停止/确认 Mihomo，避免两个进程争用 7897。只有在人工核对后，才删除
旧 generation；不要为了腾空间删除最后一个可用回滚点。

## 11. 重启后的验收

需要实机确认，不能仅凭构建结果宣称通过：

- [ ] 不登录桌面，`campus-login.service` 自动在线。
- [ ] 有线/Wi-Fi 切换后，下一次检查自动重新认证。
- [ ] `mihomo.service` 在无 GUI 时运行，加载上次 `active.yaml`。
- [ ] 两个 Profile 可切换，失败切换回滚到旧配置。
- [ ] `proxyctl groups/nodes/select` 支持中文和特殊字符。
- [ ] `nix build`/`nix flake` 能经 Mihomo 下载。
- [ ] Tailscale 在线，SSH 从第二台机器可用。
- [ ] `ss -ltnp` 只有 loopback 监听，7897/9090 未暴露。
- [ ] `resolvectl query` 和 `/etc/resolv.conf` 仍由 systemd-resolved 管理。
- [ ] 重启后服务恢复正常，旧 generation 可回滚。

## 12. 下一阶段：Docker 与 IPv6 DDNS

本任务不在小主机启用 Docker。未来启用 Docker 时，daemon 的代理环境应使用：

```text
HTTP_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
```

业务容器是否走代理需要单独决定，不要默认把容器网络或 daemon socket 暴露到
公网。IPv6 DDNS、反向代理、HTTPS 和公网 SSH 是独立任务，不在本次范围内。
