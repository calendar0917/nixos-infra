#!/usr/bin/env python3
"""axonhub 渠道权重调优 + 故障渠道探活恢复。

由 systemd 用户定时器每 5 分钟跑一轮（不依赖 LLM）。
只动 deepseek-jb / deepseek-safe 两张模型卡实际关联到的渠道，其它渠道一律不碰。

模型层：
  ~/.local/state/axonhub-tune/state.json    每轮写状态摘要，保留最近 12 轮；
                                            另有 promoteLog（tune-review.py 写的
                                            「模型 pin 连续 3 轮一致→升格 manual」记录）
  ~/.local/state/axonhub-tune/override.json 每轮开头先读，按其中指令覆盖自动计算
    允许的指令只有三类（都由人工/每 20 分钟复盘写入，本脚本只读）：
      pin(id, weight)                    固定某渠道权重，直到 expires_at
      pause_probe(id)                    暂停对该渠道探活
      archive_candidate(id, reason)      标记为待归档候选（本脚本不删除渠道）
    每条都必须带 expires_at（epoch 秒）；过期条目忽略并记日志；文件不存在当空。

凭据来源（按优先级）：
  1. 已缓存 token          $AXONHUB_TUNE_TOKEN（默认 ~/.cache/axonhub-tune/token，0600）
  2. 环境变量              $DSH_SECRET_AXONHUB_ADMIN_PASSWORD
  3. 密码文件（0600）      $AXONHUB_PASSWORD_FILE（默认 ~/.config/axonhub-tune/password）

探测恢复：对范围内 status=disabled / autoDisabledAt 的渠道每轮最多探 2 条，连续
2 轮成功才置 enabled。若渠道的 API key 被全局 autoDisableChannel（如 429×5）连
key 一起永久禁用（disabledAPIKeys 里 expiresAt 为空），先等
KEY_RECOVER_COOLDOWN（30 分钟）再 enableAllChannelAPIKeys 重开一次并立刻探活，
否则 testChannel 只会报 missing api key，渠道永远回不来。
注意：本脚本每 5 分钟按滚动成功率重算权重，会覆盖手工在后台改的
orderingWeight。任何人工意图（固定某渠道权重、暂停探活、待归档）都必须写成
override.json 条目，否则下一轮就被抹掉。override 只读，本脚本从不写它。

密码与 token 永不写入日志、永不输出。
"""
import datetime
import fcntl
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("AXONHUB_BASE", "http://127.0.0.1:8090")
EMAIL = os.environ.get("AXONHUB_EMAIL", "1131821081@qq.com")
HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.environ.get(
    "AXONHUB_TUNE_STATE_DIR", os.path.expanduser("~/.local/state/axonhub-tune")
)
STATE_PATH = os.path.join(STATE_DIR, "state.json")
OVERRIDE_PATH = os.path.join(STATE_DIR, "override.json")
LOCK_PATH = os.path.join(STATE_DIR, "state.lock")
LOG_PATH = os.path.join(STATE_DIR, "tune.log")
TOKEN_PATH = os.environ.get(
    "AXONHUB_TUNE_TOKEN", os.path.expanduser("~/.cache/axonhub-tune/token")
)
PASSWORD_FILE = os.environ.get(
    "AXONHUB_PASSWORD_FILE", os.path.expanduser("~/.config/axonhub-tune/password")
)
CARDS = ("deepseek-jb", "deepseek-safe")

# 受保护渠道：不接受模型给出的 pause_probe / archive_candidate（manual 的除外）。
# 45 = temp-1127，deepseek-jb 的 p2 备用主力，等额度恢复后放第二顺位。
PROTECTED_IDS = {"45"}

MIN_SAMPLE = 20          # 样本不足不下结论
PROBE_MAX = 2            # 每轮最多探活 2 条
VOTES_NEEDED = 2         # 连续 2 轮成功才恢复
RECOVER_COOLDOWN = 1800  # 恢复后 30 分钟内不再探
KEY_RECOVER_COOLDOWN = int(
    os.environ.get("AXONHUB_KEY_RECOVER_COOLDOWN", "1800")
)  # key 被自动禁用满这么久才重开一次，避免 429 循环
SCOPE_DROP_ALERT = 2     # scope 比上一轮少这么多渠道就告警
# 画像快照由 profile.py 生成；tune.py 只读它做漂移对账，不再硬编码渠道数量。
PROFILE_PATH = os.environ.get(
    "AXONHUB_PROFILE_PATH",
    os.path.expanduser("~/.local/state/axonhub/decisions/profile-latest.json"),
)
INTENT_PATH = os.environ.get(
    "AXONHUB_INTENT_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "intent.md")
)
DEADLINE = 60            # 单轮最坏耗时（秒）
HTTP_TIMEOUT = 10

LOG_LINES_MAX = 2000     # 日志超过就截断，避免无限增长
HISTORY_KEEP = 12        # state.json 保留最近多少轮
OVERRIDE_MAX = 3         # 每轮最多接受多少条 override 指令
STATS_WINDOW_429 = 3600  # 429 统计窗口（秒）


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def parse_ts(s):
    """RFC3339 -> epoch 秒；解析不了返回 0。"""
    try:
        s = str(s or "")
        return datetime.datetime.strptime(
            s[:19], "%Y-%m-%dT%H:%M:%S"
        ).replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return 0.0


# ---------------------------------------------------------------- credentials
def load_token():
    try:
        with open(TOKEN_PATH) as f:
            tok = f.read().strip()
        if tok:
            return tok
    except OSError:
        pass
    return None


def save_token(tok):
    d = os.path.dirname(TOKEN_PATH)
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(tok)
    except OSError:
        pass  # 缓存失败不影响本轮


def read_password():
    pw = os.environ.get("DSH_SECRET_AXONHUB_ADMIN_PASSWORD", "").strip()
    if pw:
        return pw
    try:
        with open(PASSWORD_FILE) as f:
            return f.read().strip()
    except OSError:
        return None


# ------------------------------------------------------------------- transport
class ApiError(Exception):
    pass


class AuthError(ApiError):
    pass


def _post(path, payload, tok=None):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if tok:
        headers["Authorization"] = "Bearer " + tok
    req = urllib.request.Request(BASE + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        if e.code in (401, 403):
            raise AuthError("http %d" % e.code)
        raise ApiError("http %d %s" % (e.code, body[:200]))
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise ApiError("transport %s" % e.__class__.__name__)


def signin():
    pw = read_password()
    if not pw:
        raise AuthError("no credential")
    r = _post("/admin/auth/signin", {"email": EMAIL, "password": pw})
    tok = (r or {}).get("token")
    if not tok:
        raise AuthError("signin rejected")
    save_token(tok)
    return tok


class Client:
    def __init__(self):
        self.tok = load_token()
        self.relogged = False

    def gql(self, query):
        if not self.tok:
            self._relogin()
        try:
            r = _post("/admin/graphql", {"query": query}, self.tok)
        except AuthError:
            self._relogin()
            r = _post("/admin/graphql", {"query": query}, self.tok)
        err = (r or {}).get("errors")
        if err:
            msg = str(err[0].get("message", ""))[:200]
            if "API key is required" in msg or "unauthorized" in msg.lower():
                self._relogin()
                r = _post("/admin/graphql", {"query": query}, self.tok)
                err = (r or {}).get("errors")
            if err:
                raise ApiError("graphql %s" % str(err[0].get("message", ""))[:160])
        return (r or {}).get("data") or {}

    def _relogin(self):
        if self.relogged:
            raise AuthError("relogin already attempted")
        self.relogged = True
        self.tok = signin()


# ------------------------------------------------------------------- helpers
def load_state():
    try:
        with open(STATE_PATH) as f:
            s = json.load(f)
        if isinstance(s, dict):
            return s
    except (OSError, ValueError):
        pass
    return {
        "cursor": 0,
        "votes": {},
        "errors": {},
        "recoveredAt": {},
        "rounds": 0,
        "history": [],
    }


def lock_state():
    """和 tune-review.py 共用一把锁，避免两个进程同时改 state.json 互相覆盖。"""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def unlock_state(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def save_state(s):
    fd = lock_state()
    try:
        # tune-review.py 可能在本轮读档之后往 state.json 写了 promoteLog；
        # 保存前把盘上的条目并回来，别覆盖掉它的升格记录。
        try:
            with open(STATE_PATH) as f:
                disk = json.load(f)
            if isinstance(disk, dict):
                disk_log = disk.get("promoteLog")
                mem_log = s.get("promoteLog")
                if isinstance(disk_log, list) and disk_log:
                    if not isinstance(mem_log, list):
                        mem_log = []
                    seen = {
                        (e.get("ts"), str(e.get("id")), e.get("kind"))
                        for e in mem_log
                        if isinstance(e, dict)
                    }
                    merged = list(mem_log)
                    for e in disk_log:
                        if not isinstance(e, dict):
                            continue
                        key = (e.get("ts"), str(e.get("id")), e.get("kind"))
                        if key not in seen:
                            merged.append(e)
                            seen.add(key)
                    s["promoteLog"] = merged[-200:]
        except (OSError, ValueError):
            pass
        tmp = STATE_PATH + ".tmp"
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(s, f, ensure_ascii=False, indent=1, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE_PATH)
    finally:
        unlock_state(fd)


def migrate_legacy_state():
    """W8 把 state/log 放在仓库目录里；首次运行时搬到 state 目录，别丢历史。"""
    if os.path.exists(STATE_PATH):
        return
    old_state = os.path.join(HERE, "tune.state.json")
    old_log = os.path.join(HERE, "tune.log")
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(old_state):
            with open(old_state) as f:
                s = json.load(f)
            if isinstance(s, dict):
                s.setdefault("history", [])
                save_state(s)
        if os.path.exists(old_log) and not os.path.exists(LOG_PATH):
            with open(old_log, encoding="utf-8", errors="replace") as f:
                tail = f.readlines()[-LOG_LINES_MAX:]
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                f.writelines(tail)
    except (OSError, ValueError):
        pass


def short(chid):
    return str(chid).rsplit("/", 1)[-1]


def weight_for(rate):
    if rate >= 97:
        return 100
    if rate >= 90:
        return 70
    if rate >= 80:
        return 40
    return 10


def in_scope_channels(c):
    """两张卡实际关联到的渠道 id -> {priority: [..]}

    同时返回被 association.disabled 挡在外面的渠道 id（这些是「关联还在、但被
    禁用」，正是 2026-11-28 15:42 那次事故的形态：渠道静默掉出 scope，pin 空转、
    不探活、不参与路由，日志里只剩一行 override-ignored）。
    """
    q = (
        "{models(first:50){edges{node{modelID settings{associations"
        "{priority disabled channelModel{channelId}}}}}}}"
    )
    d = c.gql(q)
    scope = {}
    blocked = {}
    for e in (d.get("models") or {}).get("edges") or []:
        node = e["node"]
        if node.get("modelID") not in CARDS:
            continue
        for a in (node.get("settings") or {}).get("associations") or []:
            ch = (a.get("channelModel") or {}).get("channelId")
            if ch is None:
                continue
            cid = str(ch)
            if a.get("disabled"):
                blocked.setdefault(cid, []).append(
                    (node.get("modelID"), a.get("priority"))
                )
                continue
            scope.setdefault(cid, []).append(a.get("priority"))
    return scope, blocked


def channels_by_id(c):
    q = (
        "{queryChannels(input:{first:200}){edges{node{id name status orderingWeight"
        " autoDisabledAt errorMessage disabledAPIKeys{disabledAt expiresAt errorCode}}}}}"
    )
    d = c.gql(q)
    out = {}
    for e in (d.get("queryChannels") or {}).get("edges") or []:
        n = e["node"]
        out[short(n["id"])] = n
    return out


def success_rates(c):
    q = (
        '{channelSuccessRates(timeWindow:"24h",limit:100){channelId channelName'
        " channelDisabled successCount failedCount totalCount successRate}}"
    )
    d = c.gql(q)
    return {short(r["channelId"]): r for r in d.get("channelSuccessRates") or []}


def count_429(c, ids):
    """最近 1 小时内每个渠道的 429 响应数（按 RequestExecution 的 responseStatusCode）。"""
    if not ids:
        return {}
    since = (
        datetime.datetime.now(datetime.timezone.utc)
        - datetime.timedelta(seconds=STATS_WINDOW_429)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    parts = []
    for cid in ids:
        parts.append(
            'c%s: requests(first:1,where:{createdAtGTE:"%s",'
            'channelID:"gid://axonhub/Channel/%s",'
            "hasExecutionsWith:{responseStatusCodeIn:[429]}}){totalCount}"
            % (cid, since, cid)
        )
    try:
        d = c.gql("{" + " ".join(parts) + "}")
    except ApiError:
        return {}
    out = {}
    for cid in ids:
        out[cid] = int((d.get("c" + cid) or {}).get("totalCount") or 0)
    return out


def apply_weights(c, changes):
    if not changes:
        return 0
    items = ",".join(
        '{id:"gid://axonhub/Channel/%s",orderingWeight:%d}' % (short(cid), w)
        for cid, w in changes
    )
    c.gql("mutation{bulkUpdateChannelOrdering(input:{channels:[%s]}){updated}}" % items)
    c.gql("mutation{clearCache(input:{targets:[CHANNEL_CACHE]}){success}}")
    return len(changes)


def probe(c, cid, model):
    mi = ' modelID:"%s"' % model.replace('"', "") if model else ""
    q = (
        'mutation{testChannel(input:{channelID:"gid://axonhub/Channel/%s"%s})'
        "{success latency error}}" % (short(cid), mi)
    )
    d = c.gql(q)
    return d.get("testChannel") or {}


# ------------------------------------------------------------------- override
OVERRIDE_KINDS = ("pin", "pause_probe", "archive_candidate")


def load_override(log):
    """读取 override.json（main() 每轮开头调用）。

    文件不存在 / JSON 坏了 / 结构不对都当空，不抛错；只记一行日志。
    返回 {"instructions": [...]} 形状的 dict（instructions 里保留原始条目）。
    """
    try:
        with open(OVERRIDE_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        return {"instructions": []}
    except (OSError, ValueError) as e:
        log.append("override=bad-file(%s)" % e.__class__.__name__)
        return {"instructions": []}
    if isinstance(raw, list):
        raw = {"instructions": raw}
    if not isinstance(raw, dict) or not isinstance(raw.get("instructions", []), list):
        log.append("override=bad-shape")
        return {"instructions": []}
    return raw


def resolve_override(override, now, log, scope):
    """把 override 指令解成三类有效动作；过期/非法/超上限的条目忽略并记日志。

    now 是 epoch 秒；每条指令用 expires_at（epoch 秒）判断是否过期。
    返回 (active, ignored)，active 形如
      {"pin": {cid: weight}, "pause_probe": {cid}, "archive_candidate": {cid: reason}}
    """
    active = {"pin": {}, "pause_probe": {}, "archive_candidate": {}}
    ignored = []
    accepted = 0   # 计入「每轮最多 3 条」的指令数（source=manual 的不占额度）
    total = 0
    for idx, ins in enumerate(override.get("instructions") or []):
        if not isinstance(ins, dict):
            ignored.append({"index": idx, "reason": "不是对象"})
            continue
        kind = str(ins.get("kind") or "").strip()
        cid = short(ins.get("id") if ins.get("id") is not None else "")
        if kind not in OVERRIDE_KINDS:
            ignored.append({"index": idx, "id": cid, "reason": "未知 kind"})
            continue
        if cid not in scope:
            ignored.append(
                {"index": idx, "id": cid, "kind": kind, "reason": "渠道不在两张卡范围内"}
            )
            continue
        if (
            cid in PROTECTED_IDS
            and kind in ("pause_probe", "archive_candidate")
            and ins.get("source") != "manual"
        ):
            ignored.append(
                {
                    "index": idx,
                    "id": cid,
                    "kind": kind,
                    "reason": "受保护渠道不接受 %s" % kind,
                }
            )
            continue
        try:
            expires = int(ins.get("expires_at"))
        except (TypeError, ValueError):
            ignored.append(
                {"index": idx, "id": cid, "kind": kind, "reason": "缺 expires_at"}
            )
            continue
        if expires <= now:
            ignored.append(
                {
                    "index": idx,
                    "id": cid,
                    "kind": kind,
                    "reason": "expired(%ds前)" % int(now - expires),
                }
            )
            continue
        if ins.get("source") != "manual" and accepted >= OVERRIDE_MAX:
            ignored.append(
                {"index": idx, "id": cid, "kind": kind, "reason": "超过每轮 3 条上限"}
            )
            continue
        if kind == "pin":
            try:
                w = int(ins.get("weight"))
            except (TypeError, ValueError):
                ignored.append(
                    {"index": idx, "id": cid, "kind": kind, "reason": "weight 非法"}
                )
                continue
            if not 1 <= w <= 1000:
                ignored.append(
                    {"index": idx, "id": cid, "kind": kind, "reason": "weight 超范围"}
                )
                continue
            active["pin"][cid] = w
        elif kind == "pause_probe":
            active["pause_probe"][cid] = True
        else:  # archive_candidate：只标记，本脚本绝不删除/停用渠道
            active["archive_candidate"][cid] = str(ins.get("reason") or "")[:200]
        total += 1
        if ins.get("source") != "manual":
            accepted += 1
    if ignored:
        log.append(
            "override-ignored="
            + ",".join(
                "%s:%s" % (i.get("id") or i.get("index"), i.get("reason")) for i in ignored
            )
        )
    if total:
        log.append("override-active=%d(manual=%d)" % (total, total - accepted))
    return active, ignored


# ---------------------------------------------------------------------- round
def _free_copy_transition_active():
    """intent.md 显式声明「已复制、旧关联暂留」时，不把 non-DS 旧关联误报为漂移。"""
    try:
        with open(INTENT_PATH, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return False
    return "W38-FREE-COPY-TRANSITION" in text and "当前不执行 migrate/remove" in text


def _profile_drift_alerts(profile, scope, blocked, allow_non_ds_transition=False):
    """拿当前 live scope 与最近一次画像快照对账，不再用固定渠道数量。"""
    if not isinstance(profile, dict):
        return []
    expected = {}
    alerts = []
    for ch in profile.get("channels") or []:
        ident = ch.get("identity") or {}
        cid = str(ident.get("id"))
        if not cid:
            continue
        tiers = [
            (x.get("model"), x.get("priority"))
            for x in ch.get("current_tier") or []
            if x.get("model") in CARDS and not x.get("disabled")
        ]
        if tiers:
            expected[cid] = tiers
        if ch.get("ds_kind") == "non_ds" and not allow_non_ds_transition:
            bad = [
                "%s:p%s" % (m, p) for m, p in tiers
                if m in ("deepseek-jb", "gpt-5.6-luna", "gpt-5.6-sol")
                and p is not None and int(p) <= 1
            ]
            if bad:
                alerts.append("意图/画像不一致 %s(non_ds 在 %s)" % (cid, ",".join(bad)))
    live = set(scope)
    gone = sorted(set(expected) - live, key=lambda x: int(x) if x.isdigit() else 10**9)
    new = sorted(live - set(expected), key=lambda x: int(x) if x.isdigit() else 10**9)
    if gone:
        alerts.append("画像漂移：渠道掉出 %s" % ",".join(gone))
    if new:
        alerts.append("画像漂移：新增渠道 %s" % ",".join(new))
    # 共用 key 的账号配额/429 风险持续可见；用户暂不换独立 key，不能假装拆卡能隔离。
    by_id = {
        str((ch.get("identity") or {}).get("id")): ch
        for ch in profile.get("channels") or []
    }
    seen_pairs = set()
    for cid, ch in by_id.items():
        for other in (ch.get("key_group") or {}).get("shared_key_with") or []:
            other = str(other)
            pair = tuple(sorted((cid, other), key=lambda x: int(x) if x.isdigit() else 10**9))
            if pair in seen_pairs or other not in by_id:
                continue
            seen_pairs.add(pair)
            a, b = by_id[pair[0]], by_id[pair[1]]
            alerts.append(
                "共用key配额/429风险 %s<->%s（429=%s/%s, quota=%s/%s）"
                % (pair[0], pair[1],
                   (a.get("error_pressure") or {}).get("requests_with_429"),
                   (b.get("error_pressure") or {}).get("requests_with_429"),
                   (a.get("quota") or {}).get("status"),
                   (b.get("quota") or {}).get("status"))
            )
    return alerts


def check_scope_health(state, scope, blocked, active):
    """返回告警串（写进 tune.log 的 ALERT= 行）。

    告警来源：被禁用的关联、与上一轮的缩水、空转 pin，以及与 intent/profile.py
    最新画像的漂移/意图冲突。**不再有 SCOPE_MIN_EXPECTED 这种固定数量阈值。**
    """
    alerts = []
    try:
        with open(PROFILE_PATH, encoding="utf-8") as f:
            profile = json.load(f)
    except (OSError, ValueError):
        profile = None
    alerts.extend(
        _profile_drift_alerts(
            profile, scope, blocked,
            allow_non_ds_transition=_free_copy_transition_active(),
        )
    )
    for cid, where in sorted(blocked.items(), key=lambda kv: int(kv[0])):
        tags = ",".join("%s:p%s" % (m, p) for m, p in where)
        alerts.append("关联被禁用 %s(%s)" % (cid, tags))
    prev = ((state.get("history") or [])[-1:] or [{}])[0]
    prev_ids = set((prev.get("channels") or {}).keys())
    if prev_ids:
        gone = sorted(prev_ids - set(scope), key=lambda x: int(x) if x.isdigit() else 10**9)
        if len(gone) >= SCOPE_DROP_ALERT:
            alerts.append(
                "scope 缩水 %d->%d，掉出 %s" % (len(prev_ids), len(scope), ",".join(gone))
            )
    idle_pins = [cid for cid in active["pin"] if cid not in scope]
    if idle_pins:
        alerts.append("pin 空转 %s" % ",".join(sorted(idle_pins)))
    return alerts


def main():
    started = time.time()
    log = []
    migrate_legacy_state()
    state = load_state()
    c = Client()
    touched = 0
    recovered = []

    round_no = int(state.get("rounds") or 0) + 1
    try:
        scope, blocked = in_scope_channels(c)
        chans = channels_by_id(c)
        rates = success_rates(c)
        r429 = count_429(c, sorted(scope))

        override = load_override(log)
        active, ignored = resolve_override(override, time.time(), log, scope)

        # --- 0. 护栏：关联禁用 / scope 变化 / 意图画像漂移，一律显式告警
        alerts = check_scope_health(state, scope, blocked, active)
        for a in alerts:
            log.append("ALERT=" + a)

        # --- 1. 权重
        changes = []
        change_meta = []
        for cid, priorities in sorted(scope.items()):
            info = chans.get(cid)
            if not info or info.get("status") != "enabled":
                continue
            if cid in active["archive_candidate"]:
                continue  # 只标记，不自动改权重，等人工归档
            if cid in active["pin"]:
                want = active["pin"][cid]
                reason = "override:pin"
            else:
                r = rates.get(cid)
                if not r or (r.get("totalCount") or 0) < MIN_SAMPLE:
                    continue
                want = weight_for(r.get("successRate") or 0)
                reason = "auto:rate=%.1f%%" % (r.get("successRate") or 0)
            cur = info.get("orderingWeight") or 0
            if want != cur:
                changes.append((cid, want))
                change_meta.append(
                    {"id": cid, "name": info.get("name"), "from": cur, "to": want,
                     "reason": reason}
                )
        if changes and time.time() - started < DEADLINE:
            touched = apply_weights(c, changes)
            log.append(
                "weights="
                + str(touched)
                + "("
                + ",".join(
                    "%s:%d<-%d" % (m["id"], m["to"], m["from"]) for m in change_meta
                )
                + ")"
            )
        else:
            log.append("weights=0")

        # --- 2. 探活恢复
        cands = []
        for cid, info in chans.items():
            if cid not in scope:
                continue
            if info.get("status") == "disabled" or info.get("autoDisabledAt"):
                cands.append(cid)
        cands.sort(key=lambda x: int(x) if x.isdigit() else 10**9)

        probed = {}
        keys_reopened = []
        votes = state.setdefault("votes", {})
        errors = state.setdefault("errors", {})
        recovered_at = state.setdefault("recoveredAt", {})
        cursor = int(state.get("cursor") or 0)
        now = time.time()
        probe_skipped = set()

        # 已恢复的渠道清掉旧探活票，避免残留票让下次 key 重开后一票就放行。
        for cid, info in chans.items():
            if cid in scope and info.get("status") == "enabled":
                votes[cid] = 0

        if cands:
            for i in range(min(PROBE_MAX, len(cands))):
                if time.time() - started > DEADLINE:
                    break
                cid = cands[(cursor + i) % len(cands)]
                if cid in active["pause_probe"]:
                    probe_skipped.add(cid)
                    probed[cid] = "paused"
                    continue
                last = recovered_at.get(cid)
                if last and now - last < RECOVER_COOLDOWN:
                    continue
                info = chans[cid]
                # key 级自动禁用（expiresAt 为空 = 不会自己恢复）：冷却后重开一次再探。
                # 否则 testChannel 直接报 missing api key，渠道永远救不回来。
                need_key = [
                    k
                    for k in (info.get("disabledAPIKeys") or [])
                    if not k.get("expiresAt")
                ]
                if need_key:
                    newest = max(parse_ts(k.get("disabledAt")) for k in need_key)
                    if now - newest < KEY_RECOVER_COOLDOWN:
                        probed[cid] = "keywait"
                        continue
                    try:
                        c.gql(
                            'mutation{enableAllChannelAPIKeys(channelID:'
                            '"gid://axonhub/Channel/%s")}' % cid
                        )
                        keys_reopened.append(cid)
                        # 重开 key 有可能把渠道一起带回 enabled；先按住，
                        # 等连续 2 票探活成功再放回，避免坏上游直接吃流量。
                        c.gql(
                            'mutation{updateChannelStatus(id:"gid://axonhub/Channel/%s",'
                            "status:disabled){id}}" % cid
                        )
                    except ApiError as e:
                        errors[cid] = ("key: %s" % str(e))[:120]
                        probed[cid] = "keyerr"
                        continue
                model = None
                try:
                    r = probe(c, cid, model)
                except ApiError as e:
                    votes[cid] = 0
                    errors[cid] = str(e)[:120]
                    probed[cid] = "err"
                    continue
                if r.get("success"):
                    votes[cid] = int(votes.get(cid) or 0) + 1
                    probed[cid] = "ok(v%d)" % votes[cid]
                    if votes[cid] >= VOTES_NEEDED and time.time() - started < DEADLINE:
                        c.gql(
                            'mutation{updateChannelStatus(id:"gid://axonhub/Channel/%s",'
                            "status:enabled){id}}" % cid
                        )
                        votes[cid] = 0
                        errors.pop(cid, None)
                        recovered_at[cid] = time.time()
                        recovered.append("%s(%s)" % (cid, info.get("name", "")[:12]))
                else:
                    votes[cid] = 0
                    errors[cid] = str(r.get("error") or r.get("message") or "")[:120]
                    probed[cid] = "fail"
            state["cursor"] = (cursor + PROBE_MAX) % max(1, len(cands))
        log.append(
            "probe="
            + (
                ",".join("%s:%s" % (k, v) for k, v in probed.items())
                if probed
                else "-"
            )
        )
        log.append("recovered=" + (",".join(recovered) if recovered else "-"))
        log.append("keys=" + (",".join(keys_reopened) if keys_reopened else "-"))

        if recovered:
            c.gql("mutation{clearCache(input:{targets:[CHANNEL_CACHE]}){success}}")

        # --- 3. 状态摘要（保留最近 12 轮）
        snap = {}
        prev_hist = (state.get("history") or [])[-1:]
        prev_ch = (prev_hist[0].get("channels") if prev_hist else {}) or {}
        for cid in sorted(scope):
            info = chans.get(cid) or {}
            r = rates.get(cid) or {}
            prio = min([p for p in scope.get(cid) or [1000] if p is not None] or [1000])
            ch = {
                "name": info.get("name"),
                "weight": info.get("orderingWeight"),
                "status": info.get("status"),
                "tier": prio,
                "successRate": round(float(r.get("successRate") or 0), 1)
                if r
                else None,
                "total": r.get("totalCount"),
                "failed": r.get("failedCount"),
                "r429_1h": r429.get(cid),
                "probe": probed.get(cid, "paused" if cid in probe_skipped else "-"),
                "autoDisabled": bool(info.get("autoDisabledAt")),
            }
            prev = prev_ch.get(cid) or {}
            if ch["successRate"] is not None and prev.get("successRate") is not None:
                ch["rateDelta"] = round(ch["successRate"] - prev["successRate"], 1)
            if ch["r429_1h"] is not None and prev.get("r429_1h") is not None:
                ch["r429Delta"] = ch["r429_1h"] - prev["r429_1h"]
            snap[cid] = ch
        history = state.get("history") or []
        history.append(
            {
                "round": round_no,
                "ts": now_iso(),
                "channels": snap,
                "changes": change_meta,
                "recovered": recovered,
                "keysReopened": keys_reopened,
                "alerts": alerts,
                "scope": sorted(scope, key=lambda x: int(x) if x.isdigit() else 10**9),
                "blocked": {k: list(v) for k, v in sorted(blocked.items())},
                "override": {
                    "active": {
                        "pin": active["pin"],
                        "pause_probe": sorted(active["pause_probe"]),
                        "archive_candidate": active["archive_candidate"],
                    },
                    "ignored": ignored,
                },
            }
        )
        state["history"] = history[-HISTORY_KEEP:]

        state["rounds"] = round_no
        state["lastRun"] = now_iso()
        save_state(state)
        write_log(now_iso(), " ".join(log), state)
        return 0
    except AuthError as e:
        write_log(now_iso(), "auth-fail(%s) 需要重新提供密码" % e, state)
        return 0
    except ApiError as e:
        write_log(now_iso(), "api-error(%s)" % str(e)[:120], state)
        return 0
    except Exception as e:  # 兜底：绝不抛出，避免 systemd 刷失败日志
        write_log(now_iso(), "error(%s)" % e.__class__.__name__, state)
        return 0


def write_log(ts, line, state):
    row = "%s %s\n" % (ts, line)
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 400_000:
            with open(LOG_PATH, encoding="utf-8", errors="replace") as f:
                tail = f.readlines()[-LOG_LINES_MAX:]
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                f.writelines(tail)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(row)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
