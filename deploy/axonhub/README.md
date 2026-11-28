# AxonHub local deployment

This directory contains the fixed AxonHub Compose model requested for the main
workstation. Do not replace the images with `latest`.

## Files and secrets

- `compose.yaml`: PostgreSQL 16 + AxonHub, private `backend` network, separate
  `egress` network, PostgreSQL without a host port, AxonHub published through
  `${AXONHUB_BIND_IP:-127.0.0.1}:${AXONHUB_PORT:-8090}`.
- The local runtime `.env` sets `AXONHUB_BIND_IP=0.0.0.0`, so AxonHub listens on
  all IPv4 interfaces. `.env.example` keeps the safe default `127.0.0.1`.
- `.env.example`: versioned template. It contains no real password.
- `.env`: local runtime file, mode `0600`, ignored by Git. It contains the
  PostgreSQL password. Never commit, upload, or paste it into a chat.
- PostgreSQL data lives in the Docker named volume `axonhub_postgres_data` on
  the NixOS root filesystem, not on Arch's `@home` and not on the 128 GB USB.

## Start and check

```bash
cd deploy/axonhub
sudo docker compose --env-file .env config --quiet
sudo docker compose --env-file .env pull
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:8090/health
```

If this Docker installation does not discover the Compose CLI plugin, use
`sudo docker-compose --env-file .env ...` instead. Do not install a second
Compose implementation just to change the command name.

## Access

The local `.env` sets `AXONHUB_BIND_IP=0.0.0.0`; the running service is reachable
at:

- `http://<主机局域网IP>:8090`
- `http://<主机Tailscale-IP>:8090`
- `https://api.20050917.xyz`（公网，经 Cloudflare Tunnel `laptop-main`，
  规则在云端；见 [docs/UNIFIED_ACCESS.md](../../docs/UNIFIED_ACCESS.md)）

公网入口不改变鉴权：`/v1/*` 仍要 AxonHub API key（无 key 返回 401），管理界面走
`/login`。风险点在于 `/login` 现在对全网可见，是暴力破解的靶子；`.env` 的
`AXONHUB_BIND_IP=0.0.0.0` 同时意味着局域网和 tailnet 都能直连，这两层一起考虑。

Use the existing web login and API key authentication. PostgreSQL remains on the
internal `backend` network with no host port. Binding to `0.0.0.0` listens on
every IPv4 interface; not having a public IPv4 address is not the same as
network isolation. Do not add router port forwarding or UPnP for this service.

## Registry pulls and proxy

Image pulls are performed by the `dockerd` daemon, not by the `docker` CLI.
Exporting `HTTPS_PROXY` in an interactive shell does not make the daemon use
that proxy. This host sets the daemon's own environment in
`hosts/main/docker.nix`:

```nix
systemd.services.docker.environment = {
  HTTP_PROXY = "http://127.0.0.1:7897";
  HTTPS_PROXY = "http://127.0.0.1:7897";
  NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,.local";
};
```

After a rebuild/switch, verify the running unit and pull again:

```bash
systemctl show docker -p Environment | tr ':' '\n' | grep -E 'HTTP_PROXY|HTTPS_PROXY|NO_PROXY'
cd deploy/axonhub
sudo docker compose --env-file .env pull
```

Do not disable TLS verification and do not point the daemon at a proxy that
is not already working. If a registry mirror lacks the image, Docker should
fall back to Docker Hub; the daemon proxy makes that fallback usable.

Expected checks:

```bash
ss -lntp | grep ':8090'          # must show 0.0.0.0:8090, not only 127.0.0.1:8090
ss -lntp | grep ':5432'          # must show nothing on the host
sudo docker compose --env-file .env ps
```

PostgreSQL and AxonHub should both become healthy. A healthy PostgreSQL is a
prerequisite for AxonHub because of `depends_on.condition: service_healthy`.

## Logs

```bash
sudo docker compose --env-file .env logs --tail=100 postgres
sudo docker compose --env-file .env logs --tail=100 axonhub
```

The logging driver is `json-file` with rotation (`10m`, 3 files) per service.
Do not replace it with an unbounded driver.

## Backup

Create the ignored backup directory once:

```bash
cd deploy/axonhub
mkdir -p backups
```

Take a consistent PostgreSQL dump (custom format):

```bash
cd deploy/axonhub
stamp=$(date +%Y-%m-%d-%H%M%S)
sudo docker compose --env-file .env exec -T postgres \
  pg_dump -U axonhub -d axonhub -Fc > "backups/axonhub-$stamp.dump"
pg_restore --list "backups/axonhub-$stamp.dump" >/dev/null
sha256sum "backups/axonhub-$stamp.dump"
```

The dump is written by the invoking user; the password stays in `.env` and is
not passed on the command line. Keep at least one copy off this machine and
store the PostgreSQL password separately in a password manager. A database
dump without its password is not a complete recovery set.

## Restore test in an isolated temporary environment

Never test a restore by overwriting the live volume. Use a separate Docker
project, a separate volume, and no host port. The following is a design to run
only after the live deployment is healthy:

```bash
cd deploy/axonhub
# 1. Start a throwaway PostgreSQL with its own volume and a random password.
restore_pw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
sudo docker run --rm -d --name axonhub-restore-test \
  -e POSTGRES_DB=axonhub \
  -e POSTGRES_USER=axonhub \
  -e POSTGRES_PASSWORD="$restore_pw" \
  -v axonhub_restore_test:/var/lib/postgresql/data \
  postgres:16-alpine
unset restore_pw

# 2. Wait for readiness, copy the dump in, and restore it.
sudo docker exec axonhub-restore-test \
  pg_isready -U axonhub -d axonhub
sudo docker cp "backups/axonhub-<stamp>.dump" \
  axonhub-restore-test:/tmp/axonhub.dump
sudo docker exec axonhub-restore-test \
  pg_restore -U axonhub -d axonhub --clean --if-exists /tmp/axonhub.dump

# 3. Inspect a few tables/counts, then remove only the test container/volume.
sudo docker exec axonhub-restore-test \
  psql -U axonhub -d axonhub -c '\dt'
sudo docker rm -f axonhub-restore-test
sudo docker volume rm axonhub_restore_test
```

Do not run `docker compose down -v`, `docker volume prune`, or any command that
deletes `axonhub_postgres_data`. The restored test must use a different volume
name from the live one.

## Network and security notes

- `backend` is `internal: true`; PostgreSQL is reachable only by AxonHub.
- `egress` gives AxonHub outbound access for upstream APIs.
- The local `.env` publishes AxonHub on `0.0.0.0:8090`, which is every IPv4
  interface. A missing public IPv4 address is not network isolation; keep the
  web login and API keys enabled and do not add port forwarding or UPnP.
- AxonHub drops all Linux capabilities, uses a non-root UID, a read-only root
  filesystem, and only a small `/tmp` tmpfs.
- Do not add `privileged`, the Docker socket, Arch's home, or the backup USB to
  this Compose file.
- Registry mirrors are third-party services. They are only pull accelerators;
  they are not a trust boundary. Do not disable TLS verification to work around
  a mirror failure.

## 渠道调权层（tune.py）

每 5 分钟一个 systemd 用户 timer 跑 `tune.py`，只动 `deepseek-jb` /
`deepseek-safe` 两张模型卡关联的渠道；opencode 的免费模型由 `decide.py` 单独给出
`free-*` 卡迁移建议，当前不写线上：

- `~/.local/state/axonhub-tune/state.json`：每轮状态摘要（权重、成功率、最近
  1 小时 429 数、探活结果、本轮改了什么及原因），滚动保留最近 12 轮；另有
  `promoteLog` 记录「模型 pin 连续 3 轮一致 → 自动升格 manual」的事件。
- `~/.local/state/axonhub-tune/override.json`：人工/模型决定，`tune.py` 只读。
- `~/.local/state/axonhub-tune/review-state.json`：复盘脚本自己的 20 分钟轮次
  记录（只存每轮模型给出的 pin，用于判断「连续 3 轮一致」）。
- 日志：`~/.local/state/axonhub-tune/tune.log`、`review.log`。
- 凭据：管理员密码只从 `$DSH_SECRET_AXONHUB_ADMIN_PASSWORD` 或
  `~/.config/axonhub-tune/password`（0600）读取；token 缓存
  `~/.cache/axonhub-tune/token`（0600）。任何日志都不回显凭据片段。

override 指令只有三类，每条必须带 `expires_at`（epoch 秒）：`pin`（固定权重）、
`pause_probe`（暂停探活）、`archive_candidate`（标记待归档，不删除渠道）。
过期条目自动失效并记日志；文件不存在当空。

**重要**：`tune.py` 每 5 分钟按滚动成功率重算权重，会覆盖手工在后台改的
`orderingWeight`。任何人工意图（固定权重、暂停探活、待归档）都必须写成
override 条目，否则下一轮就被抹掉。`source: "manual"` 的条目由复盘原样保留，
模型不得覆盖，也不占「每轮最多 3 条」的额度。

当前的人工 pin（`source: manual`）：

| 渠道 | 权重 | 到期 | 说明 |
| --- | --- | --- | --- |
| 48 / 49 / 47 | 100 | 两周 | 破限线主力等权轮转 |
| 45（temp-1127） | 100 | 一天后复查 | deepseek-jb 的 p2 备用主力，等额度恢复放第二顺位 |

**保护名单**：45 属于保护渠道，不允许被模型标成 `archive_candidate` 或
`pause_probe`（prompt 里写明，代码里也双重兜底）。它现在只是 credits 用尽，
不是渠道坏了。

**探活恢复**：范围内 `status=disabled` 或带 `autoDisabledAt` 的渠道每轮最多探
2 条，连续 2 轮成功才置 `enabled`。注意全局 `autoDisableChannel`（如 429×5）会把
渠道的 **API key 一并永久禁用**（`disabledAPIKeys.expiresAt` 为空），此时
`testChannel` 只报 missing api key，单靠置 enabled 救不回来。`tune.py` 会在 key
被禁满 30 分钟（`AXONHUB_KEY_RECOVER_COOLDOWN`，默认 1800 秒，可临时设为 0 做
验证）后调 `enableAllChannelAPIKeys` 重开一次 key、把渠道按回 disabled，再靠两票
探活放回；仍失败就等下一轮 30 分钟冷却，不会形成 429 循环。已恢复的渠道会清掉
旧探活票，避免残留票让下次一票就放行。

**scope 护栏（2026-11-28 事故后加）**：模型关联里某条
`associations[].disabled=true` 时，那个渠道会**静默掉出** `tune.py` 的调权范围——
pin 空转、不探活、不参与路由，日志里只剩一行 `override-ignored=…渠道不在两张卡范围内`。
15:42 就是这样丢了 45/48/49 三个渠道，靠人肉才发现。现在每轮都会：
把被禁用的关联、scope 相对上一轮的缩水（`SCOPE_DROP_ALERT`，默认少 2 个就报）、
空转的 pin 写进 `tune.log` 的 `ALERT=` 行，同时记进 state.json 的 `alerts`，
`tune-review.py` 会把它们带进复盘 prompt 并告知模型「这是运维事故，别据此降权」。
另外 `tune.py` 每轮只读 `~/.local/state/axonhub/decisions/profile-latest.json`，把
live scope 与画像快照对账：渠道掉出/新增、`non_ds` 渠道出现在 DS 卡 p0/p1 等
「意图/画像不一致」都会持续告警。**已移除 `SCOPE_MIN_EXPECTED=8` 固定数量阈值**，
不再要求 scope 永远是 8 个。

**手动改完关联后怎么立即生效**：不用等 tune.py，跑一次
`systemctl --user start axonhub-tune.service` 即可（定时器每 5 分钟也会自己发现）。
如果改出问题，异常会作为 `ALERT=` 行记进 `~/.local/state/axonhub-tune/tune.log`。

**复盘空回复重试**：上游偶发返回 `stopReason=error`、0 token 的空回复（15:16 那次
就是），旧逻辑第一次就判失败。现在解析不出 JSON 会隔 `AXONHUB_REVIEW_RETRY_WAIT`
（默认 60 秒）整轮重跑一次，仍失败才记 `fail`，旧 override.json 不动。

**意图驱动决策 dry-run**：`intent.md` 只写目标/约束和用户提供的「性质 + url +
key 引用名」；`profile.py` 从实时 GraphQL/requests 数据推导 16 个字段组（key 只存
sha256 前 8 位指纹）。请求统计按 `RequestExecution.channelID + requestURL` 归属，
避免把 failover 到别渠道的错误串到原渠道；无法证明归属时标
`error_pressure.attribution=attribution_unknown`，不参与自动决策。画像同时给出
`stats24.successRate`（该渠道无失败 execution 的清洁率）和 `stats24.finalSuccessRate`
（请求最终 completed 比例）；两者差距大表示 failover 掩盖了上游拒绝，模型必须同时看。
4xx/429 压力会进入 `error_pressure.upstream_health`（如 `degraded` / `rate_limited`）。
opencode 渠道还会只读拉取 `/v1/models` 目录，用 `canonical_id/family/description`
证明模型家族。`decide.py --mode model` 是严格模型模式：失败会写 `source=model-failed`
并返回非零，**禁止 rules-offline 兜底冒充模型结果**。默认 `auto_apply=false`，不调用任何
写接口；free/非 DS 模型只建议迁移到独立 `free-*` 卡，不生成实际 mutation。
46/51（以及 48/49）共用 key 时，`tune.py` 每轮写 `ALERT=共用key配额/429风险 ...`，
画像继续监控 quota/429；用户暂不换独立 key 时不创建第二把 key。
决策频率配置项是
`AXONHUB_DECIDE_INTERVAL_MINUTES`，**默认 10 分钟**；要降到 30 分钟只需把该环境变量
设成 `30`（例如 timer 的 `Environment=AXONHUB_DECIDE_INTERVAL_MINUTES=30`）。画像和
决策输出在 `~/.local/state/axonhub/decisions/`。

**定时模型决策**：`axonhub-decide.service` 是 oneshot，先跑 `profile.py`，再跑
`decide.py --mode model`；严格模型模式失败会写 `source=model-failed` 并非零退出，
不会用 rules-offline 冒充。`run-decide.sh` 用 `flock -n` 防重叠，service 不调用
`apply.py`、不写任何 axonhub 接口。service `TimeoutStartSec=900`（模型长尾实测
42–208 秒，留足余量，避免 timer 下一轮撞上未结束的上一轮）。`axonhub-decide.timer` 默认
`OnBootSec=2min` + `OnUnitActiveSec=10min`，`AccuracySec=30s`，日志进 journal。
频率由 `AXONHUB_DECIDE_INTERVAL_MINUTES` 控制，默认 10；改成 30 分钟只需：

```sh
cd /home/calendar/nixos-infra/deploy/axonhub
AXONHUB_DECIDE_INTERVAL_MINUTES=30 ./install-axonhub-decide.sh
```

安装脚本会把同一个数同步写进 service 的 Environment 和 timer 的
`OnUnitActiveSec`，然后 `daemon-reload` 并 `enable --now`。手动跑一轮用
`systemctl --user start axonhub-decide.service`；看下一次触发用
`systemctl --user list-timers axonhub-decide.timer`。

**执行层 dry-run**：`apply.py` 默认只读快照并输出 `would_apply` / `blocked`，不会调用
createModel/updateModel/bulkUpdateChannel/createChannel。硬护栏包括：action 白名单、
channel/model/priority 校验、DS 卡只收 `ds_kind=ds`、单轮最多 3 个非 keep 变更、
每张卡至少保留一条 enabled DS、共用 key 同组保护、禁改 key/删渠道。快照写入
`~/.local/state/axonhub/snapshots/<ts>.json`（不含 key 明文）；mutation 失败会自动用
快照回滚并写 `ALERT=apply ...`。free 卡创建是独立 proposal 阶段，输出 createModel
计划并标记 `requiresExplicitApproval`；只有 free 卡存在且 `free-cards.json` 中状态为
`probe_ok` 时才允许迁移，顺序是「创建 → 逐模型探活 → 挂到 free 卡 → 从 DS/luna/sol
摘除」。`--rollback-drill` 用模拟 client 演练失败回滚，不联网。

模型复盘由 `tune-review.py` + `axonhub-tune-review.timer` 每 20 分钟跑一次，
用 `~/DS Bot/tools/pi-task.py` 起短会话；模型最多 3 条指令，校验通过才原子
改写 override.json，失败或输出不合法时不动旧文件。同一条 `pin(id,weight)`
连续 3 轮一致时自动升格为 `manual`（续期 1440 分钟），并在 state.json 的
`promoteLog` 记一条，之后不必每 20 分钟重算。两个脚本通过
`state.lock`（flock）互斥写 state.json，`tune.py` 保存时会合并盘上的
`promoteLog`，不会覆盖复盘脚本刚写的升格记录。单元文件在本目录有副本，
安装位置是 `~/.config/systemd/user/`。
