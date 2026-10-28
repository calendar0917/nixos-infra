# 主力机 NixOS 工作环境状态

> 机器：LENOVO 21LG，hostname `main`，Arch 与 NixOS 共用 ESP。
> 本文只记录实际检查/验证过的结果；标为“待执行/阻塞”的项目没有写成已完成。
> 最近更新：2026-10-28。当前仍运行 Generation 6；本轮新增的声明式配置已经
> `nixos-rebuild build` 成功，但**没有**由迁移代理执行 switch/boot/reboot。

## 1. 系统、启动与只读基线

| 项目 | 当前结果 |
| --- | --- |
| 运行系统 | NixOS `26.11.20261020.dirty`，内核 `6.18.57` |
| 当前 generation | Generation 6，`/run/current-system` 指向 `vj45wp…` |
| 本次启动的系统 | `/run/booted-system` 仍指向 `5pzgam…`；安装后尚未重启 |
| 本轮新构建 | 已成功 build，路径见 `./result`；**尚未激活** |
| 失败服务 | `systemctl --failed`：0 loaded units |
| sudo | `%wheel` 已配置 NOPASSWD（`security.sudo.wheelNeedsPassword = false`）；需 switch 后生效，当前运行系统仍要密码 |
| `/` | `/dev/nvme0n1p2[/@nixos]`，rw |
| `/home` | 同一 Btrfs 的 `[/@nixos-home]`，rw |
| `/nix` | 同一 Btrfs 的 `[/@nixos-nix]`，rw（store 自身只读） |
| `/boot` | `/dev/nvme0n1p1`，vfat，共享 ESP，约 872 MiB 可用 |
| `/mnt/arch-home` | `/dev/nvme0n1p2[/@home]`，`ro`，只读访问 Arch 家目录 |
| Arch 默认启动项 | `loader.conf` 为 `default arch-linux-lts.efi` |
| Arch UKI | `/boot/EFI/Linux/arch-linux-lts.efi` |
| EFI BootOrder | `Boot2001, Boot0005, Boot0000, Boot2002, Boot2003`；无 BootNext |
| systemd-boot | 262，`canTouchEfiVariables = false`，`configurationLimit = 3` |

只读基线已确认：Arch 家目录无法写入（`touch` 测试失败），NixOS 根/家目录
可写，ESP 上 Arch UKI 存在。迁移期间没有执行 `bootctl install`、没有修改
`loader.conf`/UKI/子卷/快照，也没有挂载或写入 128 GB U 盘。

### Boot hook

`hosts/main/boot.nix` 的 `extraInstallCommands` 只编辑 `loader.conf` 的
`default`/`preferred` 行，并强制 Arch UKI 为默认项。之前裸调用 `grep` 的失败
已修复为 `${pkgs.gnugrep}/bin/grep`。每次 switch 前仍应确认：

```bash
cat /boot/loader/loader.conf
sha256sum /boot/EFI/Linux/arch-linux-lts.efi
bootctl status --no-pager | sed -n '/Default Boot Loader Entry/,$p'
```

不要在 NixOS 中运行 `bootctl install`、`efibootmgr -o` 或手工改默认启动项。
共享 ESP 的写入只应通过已审查的 `nixos-rebuild switch` 完成。

## 2. 已完成的仓库与数据迁移

### 2.1 `research`（原 `res`）

- Arch 真实路径：`/mnt/arch-home/calendar/code/research`，不是 `res/`。
- remote：`git@github.com:calendar0917/research.git`，分支 `main`，HEAD
  `c52861d33fd9ae474d82b55754482ec0e4b23817`，源仓库 clean。
- 源仓库 50 个本地分支；约 116 GiB，其中 `data/` 3.0 GiB、`.git/` 499 MiB；
  `.venv`、`data/`、`dist/` 和缓存均被忽略。
- 复制到 `/home/calendar/code/research`，排除 `.venv`、`__pycache__`、
  `.pytest_cache`、`.ruff_cache`、`.mypy_cache`、`.direnv`、`node_modules`：
  46,709 个文件，约 110 GiB，rc=0。
- 校验：HEAD、`git ls-files -s` 哈希、50 个分支、clean status、`git fsck`
  和关键文件哈希与源一致；源仓库未被写入；陈旧 worktree 已 prune。
- 在 NixOS 重建 `.venv`：`uv sync --frozen`，Python 3.12.15，约 5.8 GiB
  （torch 2.5.1、torch-geometric 2.6.1、xgboost 等）。没有复用 Arch 的
  `.venv`/缓存。
- 验证：`uv run research context` 正常；`research doctor` 12/12；
  `research verify` 11 ok / 0 fail；按仓库文档 deselect 后的快速 pytest
  **1945 passed**，rc=0。

### 2.2 其他代码仓库

以下目录已从 Arch 只读家目录复制到 `/home/calendar/code`，保留 Git 状态，
不复制 `node_modules` 和可重建的备份：

| 目录 | 结果 |
| --- | --- |
| `server` | 约 8.1 MiB / 1,183 文件 |
| `temp` | 约 944 KiB |
| `shiyan` | 约 3.2 MiB |
| `learning/bianyi` | 约 72 KiB |
| `UESTC-Teamup` | 约 52 MiB |
| `YulinSecRecruit2026` | 约 88 MiB；HEAD `99429ae`，clean；排除 36 GiB `deploy/backups` |

另建 `ln -s /home/calendar/nixos-infra /home/calendar/code/nixos-infra`，用于
保留 Arch 旧 Pi session 中 `cwd` 为 `/home/calendar/code/nixos-infra` 的记录；
真实仓库仍是 `/home/calendar/nixos-infra`。

### 2.3 `life`

`life/` 的 notes、blog、dotfiles、scripts、secrets、`Passwords.kdbx` 已复制到
`/home/calendar/life`，约 47 MiB。`secrets` 收紧为目录 700、文件 600；
`notes` 中 4 个修改文件是原 vault 的备份状态，没有覆盖或回滚。Arch 家目录
始终只读，未向 `@home` 写入。

## 3. Pi / Pi Web

### 3.1 Session 与数据

- Arch 有 405 个 JSONL session（约 467 MiB，9 个项目目录）；NixOS 原有 2 个，
  没有同名冲突。
- 迁移前备份：`/home/calendar/.local/state/nixos-migration/20261028-before-pi`
  （mode 700），包含 `pi`、`gh`、`ssh`、`gitconfig`、`gnupg`。
- 使用 `rsync --ignore-existing` 导入；首次出现的 `sessions/sessions/` 嵌套
  已原子移回，未覆盖任何文件。405 个源文件哈希全部一致；当前共 **407** 个
  JSONL，NixOS 原有 2 个 session 完整保留。
- 迁移了 `agent/npm`（24 文件）、`agent/git`（56）、`agent/skills`（清理
  `__pycache__` 后 49 文件）以及全局 `.agents` 的 `grill-me`、`teach` skills
  和 `.skill-lock.json`。
- `settings.json` 合并后：`defaultProvider=new-provider`、
  `defaultModel=deepseek-v4.1-flash`、`defaultThinkingLevel=max`；Arch 的三个
  包配置全部保留，`pi list` 可见。
- `pi-web-session-state.json` 的 `projectOrder` 已合并（含
  `/home/calendar/nixos-infra`），revision 3。

### 3.2 Pi Web

- 当前运行：`127.0.0.1:30141`，`@agegr/pi-web 0.12.2`，pi `1.2.0`；实际
  HTTP 200，Pi Web 列出 407 个 session，各项目计数正确。
- 数据目录：`/home/calendar/.pi`；`agent/auth.json`、`models.json`、
  `settings.json` 均为 0600。`auth.json` 是空数组，凭据实际在
  `models.json` 的 `providers.*.apiKey`；不要把该文件复制进 Git/Nix store。
- 模型端到端测试（真实 provider）：`pi -p --no-session --no-tools
  --model new-provider/deepseek-v4.1-flash 'Reply with exactly OK'` 返回
  `OK`，rc=0。
- Arch 的 `hub` provider key 对 AxonHub 返回 401，未冒然迁移；见第 6 节。
- 新增 `home/calendar/pi.nix`：固定 `@agegr/pi-web@0.12.2` 的
  `pi-web-pinned` 包装器，并设置 `PI_SKIP_VERSION_CHECK=1`、
  `PI_TELEMETRY=0`、`PI_WEB_SKIP_VERSION_CHECK=1`。固定版启动命令：

  ```bash
  pi-web-pinned --no-open
  # 默认 127.0.0.1:30141；也可显式 --port 30141
  ```

  没有让 Home Manager 自动启动 Pi Web，避免与当前交互进程争抢 30141；用户
  需要时可手动启动，或自行添加 user service。

## 4. Clash Verge、geosite 与 7897

### 4.1 根因

- Nixpkgs 的 `clash-verge-rev-2.5.2` 把 `v2ray-geoip` 和
  `v2ray-domain-list-community` 的 geosite/geoip 链接进包。
- 订阅 profile `profiles/RQhVHMttbXtZ.yaml` 使用
  `dns.fallback-filter.geosite: [gfw]`，而 v2ray 的
  `geosite.dat` 不含 `gfw`；`list gfw not found` 导致配置校验失败。
- 实测 MetaCubeX meta-rules-dat 的 geosite 能加载 `gfw`（4424 条），校验 rc=0。
- 上游 `init_resources` 会在资源更新时把包内 geosite 复制到应用数据目录，
  因此手工替换会被包更新覆盖；必须做成每次 boot/switch 在 `/home` 挂载后
  重建的声明式副本。

### 4.2 声明式修复

`hosts/main/clash.nix` 固定：

- 仓库：`MetaCubeX/meta-rules-dat`
- 分支/提交：`release` / `f57214884b79e6e6770d753950b81242dd7f2541`
- URL：`https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/<commit>/geosite.dat`
- SHA256：`ba8968847bfb82a4f9b0c33da77b6d95f4f8fe1d7d3bb241a7ebac6c23b71631`
- SRI：`sha256-uolohHv7gqT5sMM9p3ttlfT4/h19O7JBp+usbCO3FjE=`

`systemd.services.clash-verge-geosite` 在 boot 时、以及 switch 使该 unit 新增/变更时运行：

1. 通过 `RequiresMountsFor=/home/calendar` 等到 `/home` 真正挂载；
2. 在 `display-manager.service` 之前启动（oneshot，`RemainAfterExit`）；
3. 创建应用数据目录
   `/home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev`；
4. 把 store 中的 geosite 安装到同目录临时文件；
5. 用 `mv` 原子替换 `geosite.dat`，所有者 `calendar:calendar`，mode 0644。

这里特意不用 `system.activationScripts`：stage-2 activation 可能早于独立的
`/home` 挂载，那样会把文件写到根文件系统的挂载点上。

结果是**真实可写普通文件**，不是 store symlink；即使目标原来是 symlink 也会
被替换，重复执行幂等。特别注意：`tmpfiles.d` 的 `C+` 对已存在的普通文件
不会覆盖，所以本项目没有使用 `C+` 作为修复。已用隔离目录和 symlink 场景
验证安装脚本的输出哈希与 SRI 一致；需要手动重跑时执行 `sudo systemctl restart clash-verge-geosite`。

### 4.3 7897 的单监听者方案

当前实际状态：

- `127.0.0.1:7897` 仅由手工启动的 mihomo（pid 45675，
  `/home/calendar/Downloads/mihomo/kit`）监听；`HTTP_PROXY` 仍为
  `http://127.0.0.1:7897`，Docker daemon 也使用该值。
- `clash-verge.service` 为 active，GUI 进程存在；`verge-mihomo` 也启动，
  但其日志报 `127.0.0.1:7897: bind: address already in use`，所以**没有**
  第二个 7897 监听者。
- `verge.yaml` 当前 `enable_tun_mode: false`、`enable_system_proxy: false`、
  `enable_auto_launch: false`、`verge_mixed_port: 7897`。TUN/系统代理没有
  实际启用。

不再提供 `mihomo-standalone` 服务。`hosts/main/clash.nix` 只保留 geosite
安装器；`127.0.0.1:7897` 的唯一预期所有者是 Clash Verge 的核心。

当前过渡状态：

- 手工 mihomo 仍占用 7897，Clash 核心暂时无法绑定；本会话继续使用手工
  mihomo，避免中断 agent。
- 重启后手工 mihomo 不会自动启动；需要启动 Clash Verge，让它的核心绑定
  7897。`autoStart=true` 会安装 XDG autostart 项，但当前 `verge.yaml` 的
  `enable_auto_launch: false` 仍可能要求手动打开 GUI，启动后确认核心已运行。
- 没有 systemd fallback；如果 Clash 没有启动，7897 会暂时没有监听者。
  这不是迁移期间允许的长期状态，必须由用户启动 Clash 后验证。

隔离测试（未触碰 7897）：把配置复制到临时目录，mixed-port 改为 `17899`，
controller 改为 `19097`，DNS 改为 `15353`；`mihomo -t` rc=0，
`gstatic` 204、GitHub 200、`cache.nixos.org` 200，DNS 查询
`github.com → 20.205.243.166`。真实 profile 仍在 17897 上通过验证。订阅中的
`fallback-filter.geosite` 已被上游标记为 deprecated，但当前仍可用；改成
`nameserver-policy` 会改变 DNS 行为，未在本轮应用。

### 4.4 接管/回滚边界

- **只允许 Clash Verge 一个核心绑定 7897；不再提供 mihomo fallback。**
- 当前手工 mihomo 不是 systemd 服务；在本会话中不要由代理杀掉它。重启后
  手工进程消失，Clash Verge 是唯一的预期核心。
- 切换到 Clash 的步骤（由用户执行）：

  ```bash
  # 先停止当前手工 mihomo（关闭其终端/进程；不要动 agent 本身）
  ss -lntp 'sport = :7897'          # 必须为空
  # 打开/启动 Clash Verge，确认它的核心绑定 7897
  ```

  验证 `gstatic`/GitHub/`cache.nixos.org` 后再保留该状态。若 Clash 启动
  失败，先看 GUI/核心日志；不要为了绕过问题再启动第二个 7897 listener。
  只有用户明确接受临时降级时，才手工启动旧 kit，并在恢复后回到 Clash。
- 任何时候都不要改 `HTTP_PROXY=http://127.0.0.1:7897`，也不要在 7897 上
  启动第二个 listener。

## 5. 身份、密钥与桌面配置

### 5.1 SSH / Git / GitHub

- `~/.ssh` 的 `config`、`id_rsa`（0600）、`id_rsa.pub`（0644）、
  `known_hosts` 已迁移；`ssh -T git@github.com` 认证为 `calendar0917`，
  `git ls-remote` 私有 `research` 仓库成功。
- `~/.config/gh` 的 hosts/config 为 0600；`gh auth status` 已登录
  `calendar0917`，scopes 包含 `repo`、`read:org`、`gist`、
  `admin:public_key`；`gh api user` 返回 `calendar0917`。
- `~/.gitconfig` 已迁移（user calendar / 1131821081@qq.com）。
- `home/calendar/shell.nix` 新增 Git credential helper，委托给
  `gh auth git-credential`；GitHub/Gist 均配置，token 只存在用户自己的
  `~/.config/gh`，不进入 Nix store。
- SSH 的 `PasswordAuthentication yes` 加固**没有**执行；见第 10 节。

### 5.2 GPG / age / SOPS

- GPG 的 `common.conf`、`trustdb.gpg`、`public-keys.d/pubring.db` 已从 Arch
  复制；`gpg --list-secret-keys` 为空，Arch 的 `private-keys-v1.d` 本来也是
  空的，因此**没有可迁移的私钥**。
- `/var/lib/sops-nix` 是 root-only，当前用户不可读；没有找到可用的用户
  age 私钥。`.sops.yaml` 仍只有一个 recipient
  `age1ce6lurdq9acgvd0rzzfmemfgpkty2rtk9muh90lk8cd5x8jnw3cqj9yxyg`，
  `secrets/secrets.yaml` 仍加密给该 key。
- 因此不能声称 SOPS 已可解密；需要用户从离线介质恢复 age 私钥，或在
  `sops-nix` 服务中配置 root 可读的 key，再做 `sops -d` 验证。

### 5.3 KeePassXC

- `~/.config/keepassxc/keepassxc.ini` 0600；数据库
  `/home/calendar/life/Passwords.kdbx` 0600。
- 已创建 Firefox native messaging manifest：
  `~/.mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json`，
  指向 `/etc/profiles/per-user/calendar/bin/keepassxc-proxy`（NixOS 路径，
  不是 Arch 的 `/usr/bin/keepassxc-proxy`）。
- 尚未用密码打开数据库，也没有把数据库加入 KeePassXC 最近列表；需要用户
  首次打开并确认浏览器集成。不要把数据库密码写入配置或聊天。

### 5.4 Firefox

- Arch 的真实 profile 在
  `/mnt/arch-home/calendar/.config/mozilla/firefox/y5a2y2xo.default-release`
  （不是 `~/.mozilla`；`~/.mozilla` 只有 native messaging host）。
- 已复制到
  `/home/calendar/.config/mozilla/firefox/y5a2y2xo.default-release`，约
  277 MiB；排除 cache、lock、crash/minidump。`prefs.js`、`places.sqlite`、
  `key4.db`、`logins.json`、`cookies.sqlite` 哈希与源一致；目录 700、
  所有文件 600（登录/cookie 数据不向组/其他用户开放）。
- NixOS 原有 profile `ie824o64.default` 保留且仍是默认。`profiles.ini`
  已备份为 `profiles.ini.bak-20261028`，新增 `arch-migrated` Profile1。
  迁移时 Firefox 正在运行，因此不会强行切换默认；重启 Firefox 后可用
  Profile Manager 或 `firefox --profile .../y5a2y2xo.default-release` 打开。
- 没有复制 Arch 的整个 `.mozilla`/缓存，也没有覆盖 NixOS 原有 profile。

### 5.5 fish / Neovim / 其他

- fish 继续由 Home Manager 管理；本轮补回 Arch 的 `pon`/`poff` 代理函数、
  `bt`/`cc`/`cdot`/`ch` 别名，以及 Pi 的无遥测/跳过版本检查环境变量。
  Arch 的 fish 配置保留在 `/home/calendar/life/dotfiles/config/common/fish`。
- Neovim 继续使用仓库内的 Nix 管理 LazyVim 配置（插件和 lock 在
  `~/.local/{share,state}/nvim`，不进 store）。Arch 的 LazyVim starter
  已原样保留到 `/home/calendar/life/nvim-arch`（含 Git 状态和未跟踪的
  `lazy-lock.json`/`lazyvim.json`），没有覆盖 NixOS 配置。
- Tailscale：`tailscaled` active，但 `tailscale status` 为 `Logged out` /
  `NeedsLogin`，没有 Tailscale IP；需要用户交互登录。

## 6. Docker、AxonHub 与数据库

- Docker 服务 active；`postgres:16-alpine` 和
  `looplj/axonhub:v1.0.0-beta10` 已运行，AxonHub `/health` 返回
  `status=healthy`、`version=v1.0.0-beta10`（本轮再次实测 HTTP 200）。
- AxonHub 只监听 `127.0.0.1:8090`；宿主机没有 `:5432` 监听；PostgreSQL
  只在 Compose 的 internal `backend` 网络内可达。
- `deploy/axonhub/.env` 为 0600 且被 Git 忽略，只含镜像、端口和随机
  `DB_PASSWORD`；`docker compose --env-file .env config --quiet` rc=0。
  `.env` 内容没有出现在本仓库、Nix store 或本文中。
- **阻塞（switch 前）**：当前用户不在 `docker` 组，`sudo -n true` 仍失败
  （运行系统还是旧 sudoers），所以迁移代理目前无法执行 `docker ps`、
  `pg_dump` 或隔离恢复测试。没有执行任何 `docker volume prune`/
  `compose down -v`，也没有删除 `axonhub_postgres_data`。
- 已声明 `security.sudo.wheelNeedsPassword = false`；switch 后 `sudo -n true`
  应成功，届时按 `deploy/axonhub/README.md` 执行 `pg_dump -Fc` 和独立
  volume 恢复测试。用户仍不在 `docker` 组，但可用 `sudo docker ...`。
- Arch 的 AxonHub/`hub` provider key 对 `/v1/models` 返回 401；仓库中没有
  可用的 AxonHub API key，因此没有把它写入 Pi。AxonHub 健康不等于模型 API
  已授权；需要在 AxonHub 中创建/确认 key 后再接 Pi。
- 128 GB U 盘 `/dev/sda1`（exfat，116.1 GiB，UUID `B810-3F4A`）当前未挂载、
  未写入。`lsblk` 的 `RO=0` 只表示设备未硬件只读；本迁移的策略是**只读
  使用，不挂载 rw**。备份/恢复演练未执行。

## 7. 本轮 Nix 声明式变更

| 文件 | 变更 |
| --- | --- |
| `hosts/main/clash.nix`（新增） | 固定 MetaCubeX geosite；`clash-verge-geosite` oneshot 在 `/home` 挂载后原子安装可写副本；不提供 mihomo fallback，7897 由 Clash Verge 唯一接管 |
| `hosts/main/default.nix` | 导入 `./clash.nix`；`security.sudo.wheelNeedsPassword = false` |
| `home/calendar/pi.nix`（新增） | `pi-web-pinned` 固定 0.12.2；Pi/Pi Web 无遥测/跳过版本检查 |
| `home/calendar/default.nix` | 导入 `./pi.nix` |
| `home/calendar/shell.nix` | Git credential helper 委托给 `gh`；fish `pon`/`poff` 和少量别名 |

约束：

- 没有更新 `flake.lock`，nixpkgs 仍使用原有 immutable channel tarball。
- 没有把 subscription、节点密码、API key、SSH key、GPG 私钥、Firefox
  `logins.json`/`key4.db` 或任何 token 写入 Nix store。
- `hosts/nixos` mini 配置未被修改；本轮只改 `main` 及其 Home Manager。

验证结果：

```text
nix flake check --no-update-lock-file        # rc=0
nixos-rebuild build --flake .#main --no-update-lock-file  # rc=0
git diff --check                             # rc=0
```

生成物检查：geosite store 文件 SHA256 与上述值一致；
`systemd-analyze verify` 对 `clash-verge-geosite.service` rc=0；
`result/etc/sudoers` 中 `%wheel` 为 `NOPASSWD:SETENV: ALL`；安装脚本在
隔离目录中能把 symlink 原子替换为普通文件；`pi-web-pinned` 包装器可执行。
`result` 中不再生成 `mihomo-standalone.service`。

## 8. 未完成 / 阻塞项

| 项目 | 状态与下一步 |
| --- | --- |
| 最终 switch/reboot | 代理明确未执行；由用户确认后运行 `sudo nixos-rebuild switch` 并重启 |
| 7897 交给 Clash Verge | 不再有 mihomo fallback；当前手工 mihomo 继续服务，重启后手工进程消失，需启动 Clash Verge 并确认其核心绑定 7897 |
| Docker 备份/恢复测试 | switch 前阻塞；switch 后 sudo 免密生效，按 README 用 `sudo docker` 执行 |
| sudo 免密生效 | 已写入 `hosts/main/default.nix`，需 switch 后生效；当前会话仍要密码 |
| AxonHub API key | Arch key 401；需在 AxonHub 创建/确认 key，再更新 Pi provider |
| Tailscale | 已安装但 logged out；需用户交互登录 |
| SOPS/age | `/var/lib/sops-nix` root-only，无用户 age 私钥；未解密验证 |
| GPG 私钥 | Arch 本来就没有私钥；只有公钥 |
| KeePassXC 数据库 | 文件已迁移；尚未用密码打开/加入最近列表 |
| Firefox profile 选择 | 已复制并登记 Profile1，但当前 Firefox 仍在运行；重启后手动选择/切换 |
| Neovim Arch 配置 | 已保留到 `life/nvim-arch`，未替换 Nix 管理配置；如需启用 Arch 版本，用 `NVIM_APPNAME`/独立 profile |
| USB 备份 | 未执行；U 盘未挂载、未写入 |
| SSH 密码登录加固 | 未执行；当前仍是 `PasswordAuthentication yes`，需要单独评审和测试 |

## 9. 重建、验收与回滚

由有 sudo 权限的用户执行；不要自动更新 `flake.lock`：

```bash
cd /home/calendar/nixos-infra
git status --short
nix flake check --no-update-lock-file
nixos-rebuild build --flake .#main --no-update-lock-file

# 检查新 result、boot loader、Arch UKI 哈希后再执行：
sudo nixos-rebuild switch --flake .#main --no-update-lock-file
```

switch 前重点检查：

```bash
readlink -f result
cat result/etc/systemd/system/clash-verge-geosite.service
systemd-analyze verify result/etc/systemd/system/clash-verge-geosite.service
grep -E '^%wheel' result/etc/sudoers
cat /boot/loader/loader.conf
sha256sum /boot/EFI/Linux/arch-linux-lts.efi
```

switch 后重点验收：

```bash
systemctl --failed
systemctl status clash-verge-geosite --no-pager
systemctl status clash-verge --no-pager
sudo -n true                              # switch 后应成功
ss -lntp 'sport = :7897'                 # 先启动 Clash，只允许一个 listener
curl -x http://127.0.0.1:7897 -sS -o /dev/null -w '%{http_code}\n' \
  https://www.gstatic.com/generate_204   # 期望 204
curl -x http://127.0.0.1:7897 -sS -o /dev/null -w '%{http_code}\n' \
  https://github.com                     # 期望 200
stat -c '%F %a %U:%G %n' \
  /home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev/geosite.dat
sha256sum /home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev/geosite.dat
pi-web-pinned --version                    # 期望 0.12.2
git config --get-all credential.https://github.com.helper
git config --get-all credential.https://gist.github.com.helper
```

geosite 期望是普通文件（不是 symlink），mode 0644，哈希为
`ba896884…b71631`。`clash-verge-geosite` 在 `/home` 挂载后、显示管理器之前
完成安装；重启后手工 mihomo 不会自动启动，需要启动 Clash Verge，确认其
核心绑定 7897，并确认没有第二个 listener。

回滚：

```bash
sudo nixos-rebuild switch --rollback
# 或重启时在 systemd-boot 菜单选择旧 generation
```

若只是 7897 出问题：先停止 Clash 核心，确认
`ss -lntp 'sport = :7897'` 为空；再按第 4.4 节恢复单一 listener。没有
`mihomo-standalone` 可停，也不要为了排障启动第二个 7897 进程。不要用
`kill` 杀掉正在承载 agent 的代理进程，也不要在未确认时重载 Docker。

## 10. 安全边界与 Arch 共存

- Arch `@home` 只读挂载，迁移没有写入；不要删除 Arch 的 `@`、`@home`、
  Snapper 快照或 UKI。
- 共享 ESP 只通过已审查的 NixOS switch 写入；不要 `bootctl install`、不要
  手工改默认启动项、不要覆盖 Arch UKI。
- 不格式化/重新分区 `@nixos*` 或 Arch 子卷；不执行 `mkfs`、`parted`、
  `sgdisk`、`dd`、`wipefs`。
- 不执行 Docker volume prune、`compose down -v` 或任何删除
  `axonhub_postgres_data` 的命令；数据库备份用 `pg_dump`。
- 128 GB U 盘只读使用；不要挂载 rw、不要写入、不要格式化。
- secrets 只留在用户 home/密码管理器：`.env` 0600、`models.json` 0600、
  Firefox 登录数据 0600、SSH 私钥 0600；不进入 Git、Nix store 或聊天。
- SSH 密码认证加固尚未应用；在完成密钥登录和应急访问验证前不要贸然改成
  `PasswordAuthentication no`。
- 代理链保持不变：`HTTP_PROXY=http://127.0.0.1:7897`，Docker daemon 也使用
  该值；7897 只允许 Clash Verge 一个 listener，不再提供 mihomo fallback。
- `security.sudo.wheelNeedsPassword = false` 使 `wheel` 用户无需密码即可获得
  root，等价于把该用户的全部进程都视为 root；当前只把 `calendar` 放入
  `wheel`，不要再添加其他交互用户。该选项只写入 `hosts/main`，mini 主机不受影响。
