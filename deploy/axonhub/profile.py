#!/usr/bin/env python3
"""axonhub 渠道画像（只读，不写线上配置）。

输出 16 个逻辑字段组，模型只看这个 JSON。任何 API key 只在内存里参与一次
sha256 计算，输出永远只有前 8 位指纹；credentials 原对象从结果中彻底删除。

用法：
  python3 profile.py --output ~/.local/state/axonhub/decisions/profile-latest.json
  python3 profile.py --ids 25,26,38,45,46,47,48,49,51 --window-hours 24

真实窗口统计按 RequestExecution.channelID 归属后聚合 requests，不用
channelSuccessRates（它忽略 timeWindow），也避免 failover 错误串渠道。
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_IDS = "25,26,38,45,46,47,48,49,51"
CARD_MODELS = ("deepseek-jb", "deepseek-safe", "gpt-5.6-luna", "gpt-5.6-sol")
LOW_SAMPLE = 20

# 16 个逻辑字段组（字段名固定，模型和测试都依赖它）。
PROFILE_FIELDS = (
    "identity", "status", "lifecycle", "ordering", "models", "ds_kind",
    "observed_response_model", "temporary", "key_group", "stats24",
    "error_pressure", "latency", "last_error", "quota", "current_tier",
    "user_hint",
)


# --------------------------------------------------------------- pure helpers
def parse_ts(value):
    """RFC3339 -> datetime；失败返回 None。"""
    try:
        s = str(value or "").replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(s)
    except (TypeError, ValueError):
        return None


def key_fingerprint(key):
    """返回 key 的短指纹；绝不返回明文。"""
    if not key:
        return None
    return hashlib.sha256(str(key).encode("utf-8")).hexdigest()[:8]


def ds_kind(model_ids, observed_response_model=None):
    """从上游 actualModel / 实测响应模型推导 DS 性质；hint 不参与判定。"""
    names = {str(x) for x in (model_ids or []) if x}
    if observed_response_model:
        names.add(str(observed_response_model))
    if any(re.search(r"hy4|hungerg|hunyuan|free", n, re.I) for n in names):
        return "non_ds"
    if any(re.search(r"deepseek|r1", n, re.I) for n in names):
        return "ds"
    return "unknown"


def is_temporary(name, created_at, remark, user_hint, now=None):
    """临时性由名字/用户描述/备注交叉判断，不只看名字。"""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    created = parse_ts(created_at)
    recent = bool(created and (now - created).days <= 14)
    text = " ".join(str(x or "") for x in (name, remark, user_hint))
    keyword = bool(re.search(r"temp|weekend|临时|周限额|五小时|限量|free", text, re.I))
    reasons = []
    if re.search(r"temp|weekend|临时|五小时|限量|free", str(name or ""), re.I):
        reasons.append("name")
    if re.search(r"临时|周限额|五小时|限量|free", str(user_hint or ""), re.I):
        reasons.append("hint")
    if re.search(r"临时|temp|weekend", str(remark or ""), re.I):
        reasons.append("remark")
    if recent and keyword:
        reasons.append("created_within_14d")
    return bool(reasons), ",".join(dict.fromkeys(reasons)) or None


def window_rate(total, failed):
    """真实窗口成功率；样本不足时额外标 low_sample。"""
    total = int(total or 0)
    failed = int(failed or 0)
    if total <= 0:
        return None
    return round(100.0 * (total - failed) / total, 1)


def median_or_none(values):
    vals = [float(x) for x in (values or []) if x is not None]
    return round(statistics.median(vals)) if vals else None


def reset_time_from_error(error):
    """从 last_error 里提取明确的 RFC3339 重置时间；没有就返回 None。"""
    m = re.search(r"(20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))", str(error or ""))
    return m.group(1) if m else None


def reset_state(reset_at, now_utc):
    """重置状态只由脚本按 UTC 计算，模型不允许自己猜时区。"""
    reset = parse_ts(reset_at)
    now = parse_ts(now_utc)
    if not reset or not now:
        return "unknown"
    return "past" if reset <= now else "future"


def local_time_iso(value):
    """把带时区的 RFC3339 时间转成本机时区；原值不变，避免把 Z 当本地时间。"""
    parsed = parse_ts(value)
    return parsed.astimezone().isoformat(timespec="seconds") if parsed else None


def upstream_health(status, last_error, total_24h, requests_with_5xx,
                   reset_state_value=None, attribution_unknown=False,
                   requests_with_4xx=0, requests_with_429=0):
    """上游健康度优先于 successRate；重试会把上游失败算成请求成功，必须单列。"""
    err = str(last_error or "")
    n = int(total_24h or 0)
    x5 = int(requests_with_5xx or 0)
    x4 = int(requests_with_4xx or 0)
    x429 = int(requests_with_429 or 0)
    ratio = (x5 / n) if n else 0.0
    ratio4 = (x4 / n) if n else 0.0
    ratio429 = (x429 / n) if n else 0.0
    five_xx_error = bool(re.search(r"\b(500|502|503|504)\b|gateway timeout", err, re.I))
    if attribution_unknown and err:
        health, severe, reason = "unknown", False, "错误归属无法证明，不参与自动健康判断"
    elif str(status) == "disabled" and (five_xx_error or x5 >= 5):
        health, severe, reason = "unavailable", True, "disabled + 24h 有 5xx/504 压力"
    elif re.search(r"weekly usage limit|quota|usage limit", err, re.I):
        if reset_state_value == "past":
            health, severe, reason = (
                "quota_reset_past", False,
                "last_error 为额度/周限额，但 quota.reset_state=past",
            )
        else:
            health, severe, reason = "quota_limited", False, "last_error 为额度/周限额"
    elif re.search(r"no access|forbidden|unauthorized", err, re.I):
        health, severe, reason = "access_blocked", False, "last_error 为权限/403"
    elif x429 >= 20 and ratio429 >= 0.05:
        health, severe, reason = "rate_limited", True, "24h 429 占比 ≥5%%（%d/%d）" % (x429, n)
    elif x4 >= 20 and ratio4 >= 0.10:
        health, severe, reason = "degraded", True, "24h 非429 4xx 占比 ≥10%%（%d/%d）" % (x4, n)
    elif x5 >= 5 and ratio >= 0.01:
        health, severe, reason = "degraded", True, "24h 5xx 占比 ≥1%%（%d/%d）" % (x5, n)
    elif x5 >= 10:
        health, severe, reason = "degraded", False, "24h 有 %d 次 5xx" % x5
    elif x5 > 0:
        health, severe, reason = "healthy_with_noise", False, "24h 有 %d 次 5xx" % x5
    else:
        health, severe, reason = "healthy", False, "24h 无 5xx/明显 4xx 压力"
    return {
        "upstream_health": health,
        "error_pressure_severe": severe,
        "reason": reason,
        "five_xx_ratio_pct": round(ratio * 100, 2),
        "four_xx_ratio_pct": round(ratio4 * 100, 2),
        "rate_429_ratio_pct": round(ratio429 * 100, 2),
    }


def shared_key_groups(channels):
    """输入已带 key_fp 的画像列表，返回 fp -> [channel_id]。"""
    groups = {}
    for ch in channels:
        fp = (ch.get("key_group") or {}).get("key_fp")
        if fp:
            groups.setdefault(fp, []).append(ch["identity"]["id"])
    return groups


def hint_conflict(user_hint, ds_kind_value, temporary, rate_24h):
    """用户给的性质只是 hint；与实测冲突时明确标出来。"""
    conflicts = []
    hint = (user_hint or {}).get("description", "")
    if re.search(r"\bDS\b|deepseek", hint, re.I) and ds_kind_value == "non_ds":
        conflicts.append("hint 说 DS，实测为 non_ds")
    if re.search(r"稳定", hint, re.I) and rate_24h is not None and rate_24h < 80:
        conflicts.append("hint 说稳定，实测 24h 成功率 <80%")
    return conflicts


def current_tier_map(associations_by_model):
    """把四张卡的 associations 压成 model -> [{priority, disabled}]。"""
    return {
        model: [
            {"priority": a.get("priority"), "disabled": bool(a.get("disabled"))}
            for a in (associations_by_model.get(model) or [])
        ]
        for model in CARD_MODELS
    }


def load_user_hints(intent_path):
    """从 intent.md 的渠道输入行提取 name -> {description,url,key_ref}。"""
    out = {}
    try:
        with open(intent_path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        body = line[2:]
        if "，" not in body or "url=" not in body or "key_ref=" not in body:
            continue
        name, rest = body.split("：", 1)
        m = re.search(r"url=([^，\s]+)", rest)
        k = re.search(r"key_ref=([A-Z0-9_]+)", rest)
        desc = rest.split("，url=", 1)[0].strip()
        if m and k:
            out[name.strip()] = {
                "description": desc,
                "url": m.group(1),
                "key_ref": k.group(1),
            }
    return out


# ---------------------------------------------------------------- graphql io
class GraphQLClient:
    def __init__(self, base=None, token_path=None, password_env=None):
        self.base = base or os.environ.get("AXONHUB_BASE", "http://127.0.0.1:8090")
        self.token_path = token_path or os.environ.get(
            "AXONHUB_TUNE_TOKEN", os.path.expanduser("~/.cache/axonhub-tune/token")
        )
        self.password_env = password_env or "DSH_SECRET_AXONHUB_ADMIN_PASSWORD"
        self.token = self._read_token()

    def _read_token(self):
        try:
            tok = open(self.token_path, encoding="utf-8").read().strip()
            if tok:
                return tok
        except OSError:
            pass
        return None

    def _post(self, path, payload, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(
            self.base + path, data=json.dumps(payload).encode(), headers=headers
        )
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.loads(r.read().decode() or "{}")

    def _login(self):
        email = os.environ.get("AXONHUB_EMAIL", "1131821081@qq.com")
        pw = os.environ.get(self.password_env, "").strip()
        if not pw:
            path = os.environ.get(
                "AXONHUB_PASSWORD_FILE",
                os.path.expanduser("~/.config/axonhub-tune/password"),
            )
            try:
                pw = open(path, encoding="utf-8").read().strip()
            except OSError:
                raise RuntimeError("缺管理员密码（环境变量或 0600 文件）")
        d = self._post(
            "/admin/auth/signin",
            {"email": email, "password": pw},
        )
        tok = d.get("token") or (d.get("data") or {}).get("token")
        if not tok:
            raise RuntimeError("signin 未返回 token")
        self.token = tok
        os.makedirs(os.path.dirname(self.token_path), mode=0o700, exist_ok=True)
        fd = os.open(self.token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(tok)

    def gql(self, query):
        if not self.token:
            self._login()
        try:
            d = self._post("/admin/graphql", {"query": query}, self.token)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                self._login()
                d = self._post("/admin/graphql", {"query": query}, self.token)
            else:
                raise
        if d.get("errors"):
            raise RuntimeError(str(d["errors"][0].get("message", "graphql error"))[:200])
        return d.get("data") or {}


def short_id(gid):
    return str(gid).rsplit("/", 1)[-1]


def sanitize_catalog_model(model):
    """只保留分类/配额需要的公开元数据；绝不保留请求头或凭据。"""
    return {
        "id": model.get("id"),
        "name": model.get("name"),
        "canonical_id": model.get("canonical_id"),
        "family": model.get("family"),
        "description": model.get("description"),
        "open_weights": model.get("open_weights"),
        "limit": model.get("limit"),
        "cost": model.get("cost"),
        "go": model.get("go"),
    }


def fetch_opencode_catalog(base_url, api_key, wanted_models, timeout=20):
    """读取 opencode /v1/models 的公开目录；失败只返回错误类型，不回显响应体。"""
    wanted = {str(x) for x in (wanted_models or []) if x}
    if not wanted:
        return {}, None
    req = urllib.request.Request(
        base_url.rstrip("/") + "/v1/models",
        headers={
            "Authorization": "Bearer " + api_key,
            "Accept": "application/json",
            # opencode 的 Cloudflare 规则会拒绝没有 User-Agent 的请求。
            "User-Agent": "axonhub/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            doc = json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        return {}, "HTTP %d" % exc.code
    except (OSError, ValueError) as exc:
        return {}, type(exc).__name__
    rows = doc.get("data") or doc.get("models") or []
    return {
        str(row.get("id")): sanitize_catalog_model(row)
        for row in rows
        if isinstance(row, dict) and str(row.get("id")) in wanted
    }, None


def build_profile(client, channel_ids, window_hours, intent_path):
    ids = sorted(set(str(x) for x in channel_ids), key=lambda x: int(x) if x.isdigit() else 10**9)
    hints = load_user_hints(intent_path)
    gids = ["gid://axonhub/Channel/" + x for x in ids]
    now_utc_dt = datetime.datetime.now(datetime.timezone.utc)
    now_local_dt = datetime.datetime.now().astimezone()
    now_utc = now_utc_dt.isoformat()
    now_local = now_local_dt.isoformat(timespec="seconds")
    since = (now_utc_dt - datetime.timedelta(hours=window_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")

    channel_q = (
        "{queryChannels(input:{first:200,where:{idIn:%s}}){edges{node{"
        "id name type baseURL status createdAt updatedAt supportedModels manualModels "
        "autoSyncSupportedModels defaultTestModel orderingWeight tags remark errorMessage "
        "autoDisabledAt credentials{apiKeys} disabledAPIKeys{disabledAt expiresAt errorCode reason} "
        "providerQuotaStatus{providerType status quotaData nextResetAt ready nextCheckAt} "
        "allModelEntries{requestModel actualModel source} "
        "channelProbes{avgTokensPerSecond avgTimeToFirstTokenMs successRequestCount totalRequestCount timestamp}"
        "}}}}"
    ) % json.dumps(gids)
    data = client.gql(channel_q)
    raw_channels = {short_id(e["node"]["id"]): e["node"] for e in data["queryChannels"]["edges"]}

    model_q = (
        "{models(first:50){edges{node{modelID settings{associations{priority disabled "
        "channelModel{channelId}}}}}}}"
    )
    assoc = {}
    for e in client.gql(model_q)["models"]["edges"]:
        n = e["node"]
        if n.get("modelID") in CARD_MODELS:
            assoc[n["modelID"]] = n.get("settings", {}).get("associations") or []

    # 统计只认「实际执行过该渠道」的 request。Request.channelID 是首选渠道，
    # failover 到别的渠道时仍保留原值；直接按它过滤会把别家的错误串到本渠道。
    aliases = []
    for cid in ids:
        gid = "gid://axonhub/Channel/" + cid
        base = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s"}' % (
            since, gid, since
        )
        failed_where = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",statusIn:[failed,canceled]}' % (
            since, gid, since
        )
        e429_where = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",responseStatusCodeIn:[429]}' % (
            since, gid, since
        )
        e5_where = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",responseStatusCodeIn:[500,502,503,504]}' % (
            since, gid, since
        )
        final_failed_where = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s"},statusIn:[failed,canceled]' % (
            since, gid, since
        )
        x4_where = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",responseStatusCodeIn:[400,401,403,404,422]}' % (
            since, gid, since
        )
        aliases.append('a%s:requests(first:1,where:{%s}){totalCount}' % (cid, base))
        aliases.append('f%s:requests(first:1,where:{%s}){totalCount}' % (cid, failed_where))
        aliases.append('ff%s:requests(first:1,where:{%s}){totalCount}' % (cid, final_failed_where))
        aliases.append('e%s:requests(first:1,where:{%s}){totalCount}' % (cid, e429_where))
        aliases.append('g%s:requests(first:1,where:{%s}){totalCount}' % (cid, e5_where))
        aliases.append('x%s:requests(first:1,where:{%s}){totalCount}' % (cid, x4_where))
        aliases.append(
            'r%s:requests(first:12,orderBy:{field:CREATED_AT,direction:DESC},where:{%s})'
            '{edges{node{modelID createdAt executions(first:12){edges{node{'
            'channelID requestURL createdAt status responseStatusCode metricsLatencyMs errorMessage'
            '}}}}}}' % (cid, base)
        )
        raw = raw_channels.get(cid) or {}
        if raw.get("type") == "opencode_go":
            for idx, model in enumerate(raw.get("supportedModels") or []):
                p = "p%s_%d" % (cid, idx)
                # 客户端请求的是 deepseek-* 卡名时，Request.modelID 不是上游模型；
                # 必须按 RequestExecution.modelID 拆 free 模型统计。
                mexec = 'hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",modelID:%s}' % (
                    gid, since, json.dumps(model)
                )
                mbase = 'createdAtGTE:"%s",%s' % (since, mexec)
                mfailed = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",modelID:%s,statusIn:[failed,canceled]}' % (
                    since, gid, since, json.dumps(model)
                )
                me429 = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",modelID:%s,responseStatusCodeIn:[429]}' % (
                    since, gid, since, json.dumps(model)
                )
                me5 = 'createdAtGTE:"%s",hasExecutionsWith:{channelID:"%s",createdAtGTE:"%s",modelID:%s,responseStatusCodeIn:[500,502,503,504]}' % (
                    since, gid, since, json.dumps(model)
                )
                aliases.append('%s_n:requests(first:1,where:{%s}){totalCount}' % (p, mbase))
                aliases.append('%s_f:requests(first:1,where:{%s}){totalCount}' % (p, mfailed))
                aliases.append('%s_e:requests(first:1,where:{%s}){totalCount}' % (p, me429))
                aliases.append('%s_g:requests(first:1,where:{%s}){totalCount}' % (p, me5))
    stats = client.gql("{" + " ".join(aliases) + "}")

    catalog_wanted = {}
    for raw in raw_channels.values():
        if raw.get("type") != "opencode_go":
            continue
        raw_keys = ((raw.get("credentials") or {}).get("apiKeys") or [])
        raw_fps = [key_fingerprint(k) for k in raw_keys if k]
        if raw_fps:
            catalog_wanted.setdefault((raw.get("baseURL"), raw_fps[0]), set()).update(
                raw.get("supportedModels") or []
            )
    catalog_cache = {}
    channels = []
    for cid in ids:
        raw = raw_channels.get(cid)
        if not raw:
            continue
        keys = ((raw.get("credentials") or {}).get("apiKeys") or [])
        fps = [key_fingerprint(k) for k in keys if k]
        catalog, catalog_error = {}, None
        if raw.get("type") == "opencode_go" and keys and fps:
            cache_key = (raw.get("baseURL"), fps[0])
            if cache_key not in catalog_cache:
                catalog_cache[cache_key] = fetch_opencode_catalog(
                    raw.get("baseURL"), keys[0], sorted(catalog_wanted.get(cache_key, set()))
                )
            catalog, catalog_error = catalog_cache[cache_key]
            catalog = {
                model: catalog[model]
                for model in (raw.get("supportedModels") or [])
                if model in catalog
            }
        # 原 credentials 对象绝不进入输出。
        raw.pop("credentials", None)
        entries = raw.get("allModelEntries") or []
        actual_models = [e.get("actualModel") for e in entries if e.get("actualModel")]
        model_ids = actual_models or raw.get("supportedModels") or []
        observed = actual_models[0] if actual_models else raw.get("defaultTestModel")
        hint = hints.get(raw.get("name"))
        temp, temp_reason = is_temporary(
            raw.get("name"), raw.get("createdAt"), raw.get("remark"),
            (hint or {}).get("description"),
        )
        n = int((stats.get("a" + cid) or {}).get("totalCount") or 0)
        failed = int((stats.get("f" + cid) or {}).get("totalCount") or 0)
        final_failed = int((stats.get("ff" + cid) or {}).get("totalCount") or 0)
        req429 = int((stats.get("e" + cid) or {}).get("totalCount") or 0)
        req4xx = int((stats.get("x" + cid) or {}).get("totalCount") or 0)
        rate = window_rate(n, failed)
        final_rate = window_rate(n, final_failed)
        recent = (stats.get("r" + cid) or {}).get("edges") or []
        latencies = []
        own_executions = []
        cross_channel_ignored = 0
        for e in recent:
            for ee in (e["node"].get("executions") or {}).get("edges") or []:
                x = ee["node"]
                execution_channel = short_id(x["channelID"]) if x.get("channelID") else None
                if execution_channel != cid:
                    cross_channel_ignored += 1
                    continue
                own_executions.append(x)
                if x.get("metricsLatencyMs") is not None:
                    latencies.append(x["metricsLatencyMs"])
        error_executions = [x for x in own_executions if x.get("errorMessage")]
        last_execution = max(
            error_executions,
            key=lambda x: parse_ts(x.get("createdAt")) or datetime.datetime.min.replace(
                tzinfo=datetime.timezone.utc
            ),
            default=None,
        )
        last_error = last_execution.get("errorMessage")[:130] if last_execution else None
        last_error_url = last_execution.get("requestURL") if last_execution else None
        last_error_channel = (
            short_id(last_execution.get("channelID"))
            if last_execution and last_execution.get("channelID") else None
        )
        attribution_unknown = bool(
            last_error and (last_error_channel != cid or not last_error_url)
        )
        attribution = (
            "attribution_unknown" if attribution_unknown
            else ("execution_channel_verified" if last_error else "no_error")
        )
        probes = raw.get("channelProbes") or []
        ttfts = [p.get("avgTimeToFirstTokenMs") for p in probes if p.get("avgTimeToFirstTokenMs")]
        disabled_keys = raw.get("disabledAPIKeys") or []
        quota = raw.get("providerQuotaStatus") or {}
        quota_data = quota.get("quotaData") or {}
        reset_at = quota.get("nextResetAt") or reset_time_from_error(last_error)
        reset_src = "providerQuotaStatus" if quota.get("nextResetAt") else (
            "last_error" if reset_at else None
        )
        reset_kind = reset_state(reset_at, now_utc)
        req5xx = int((stats.get("g" + cid) or {}).get("totalCount") or 0)
        health = upstream_health(
            raw.get("status"), last_error, n, req5xx,
            reset_state_value=reset_kind, attribution_unknown=attribution_unknown,
            requests_with_4xx=req4xx, requests_with_429=req429,
        )
        per_model_stats = {}
        if raw.get("type") == "opencode_go":
            for idx, model in enumerate(raw.get("supportedModels") or []):
                p = "p%s_%d" % (cid, idx)
                mn = int((stats.get(p + "_n") or {}).get("totalCount") or 0)
                mf = int((stats.get(p + "_f") or {}).get("totalCount") or 0)
                per_model_stats[model] = {
                    "windowHours": window_hours,
                    "total": mn,
                    "failed": mf,
                    "successRate": window_rate(mn, mf),
                    "low_sample": mn < LOW_SAMPLE,
                    "requests_with_429": int((stats.get(p + "_e") or {}).get("totalCount") or 0),
                    "requests_with_5xx": int((stats.get(p + "_g") or {}).get("totalCount") or 0),
                }
        ch = {
            "identity": {
                "id": cid, "name": raw.get("name"), "type": raw.get("type"),
                "baseURL": raw.get("baseURL"),
            },
            "status": {
                "value": raw.get("status"),
                "autoDisabledAt": raw.get("autoDisabledAt"),
                "errorMessage": raw.get("errorMessage"),
                "disabled_key_count": len(disabled_keys),
                "key_auto_disabled": any(not k.get("expiresAt") for k in disabled_keys),
            },
            "lifecycle": {"createdAt": raw.get("createdAt"), "updatedAt": raw.get("updatedAt")},
            "ordering": {
                "weight": raw.get("orderingWeight"), "tags": raw.get("tags") or [],
                "remark": raw.get("remark") or "",
            },
            "models": {
                "supported": raw.get("supportedModels") or [],
                "manual": raw.get("manualModels") or [],
                "defaultTestModel": raw.get("defaultTestModel"),
                "allEntries": entries,
                "catalog": catalog,
                "catalogError": catalog_error,
                "stats24": per_model_stats,
            },
            "ds_kind": ds_kind(model_ids, observed),
            "observed_response_model": observed,
            "temporary": {"value": temp, "reason": temp_reason},
            "key_group": {
                "key_fp": fps[0] if fps else None,
                "key_count": len(fps),
                "shared_key_with": [],
            },
            "stats24": {
                "windowHours": window_hours, "total": n, "failed": failed,
                "successRate": rate, "finalFailed": final_failed,
                "finalSuccessRate": final_rate, "low_sample": n < LOW_SAMPLE,
                "countBasis": "unique_requests_with_execution_on_channel",
                "successRateBasis": "requests_without_any_failed_execution_on_channel",
                "finalSuccessRateBasis": "request_final_status_completed",
            },
            "error_pressure": {
                "requests_with_429": req429,
                "requests_with_4xx_excluding_429": req4xx,
                "requests_with_5xx": req5xx,
                "upstream_health": health["upstream_health"],
                "error_pressure_severe": health["error_pressure_severe"],
                "health_reason": health["reason"],
                "five_xx_ratio_pct": health["five_xx_ratio_pct"],
                "four_xx_ratio_pct": health["four_xx_ratio_pct"],
                "rate_429_ratio_pct": health["rate_429_ratio_pct"],
                "attribution": attribution,
                "attribution_unknown": attribution_unknown,
                "attribution_basis": "RequestExecution.channelID + requestURL",
                "last_error_channel": last_error_channel,
                "last_error_url": last_error_url,
                "last_error_host": urllib.parse.urlparse(last_error_url).netloc if last_error_url else None,
                "cross_channel_attempts_ignored_recent": cross_channel_ignored,
            },
            "latency": {
                "p50_ms": median_or_none(latencies),
                "ttft_p50_ms": median_or_none(ttfts),
            },
            "last_error": last_error,
            "quota": {
                "providerType": quota.get("providerType"), "status": quota.get("status"),
                "ready": quota.get("ready"), "nextResetAt": reset_at,
                "nextResetAtLocal": local_time_iso(reset_at),
                "reset_source": reset_src, "reset_state": reset_kind,
                "nextCheckAt": quota.get("nextCheckAt"),
                "planType": quota_data.get("plan_type"),
                "windows": quota_data.get("windows") or {},
                "limits": quota_data.get("_limits") or [],
            },
            "current_tier": [],
            "user_hint": hint or {},
        }
        for model, arr in assoc.items():
            for a in arr:
                cm = a.get("channelModel") or {}
                if cm.get("channelId") == int(cid):
                    ch["current_tier"].append({
                        "model": model, "priority": a.get("priority"),
                        "disabled": bool(a.get("disabled")),
                    })
        channels.append(ch)

    groups = shared_key_groups(channels)
    for ch in channels:
        fp = ch["key_group"]["key_fp"]
        if fp:
            ch["key_group"]["shared_key_with"] = [
                x for x in groups.get(fp, []) if x != ch["identity"]["id"]
            ]
        ch["user_hint"]["conflicts"] = hint_conflict(
            ch["user_hint"], ch["ds_kind"], ch["temporary"], ch["stats24"]["successRate"]
        )

    return {
        "generatedAt": now_utc,
        "now_utc": now_utc,
        "now_local": now_local,
        "windowHours": window_hours,
        "profileFields": list(PROFILE_FIELDS),
        "channelCount": len(channels),
        "channels": channels,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="只读生成 axonhub 渠道画像")
    ap.add_argument("--ids", default=DEFAULT_IDS, help="逗号分隔的渠道 id")
    ap.add_argument("--window-hours", type=int, default=24)
    ap.add_argument("--intent", default=os.path.join(HERE, "intent.md"))
    ap.add_argument("--output", required=True)
    args = ap.parse_args(argv)
    ids = [x for x in args.ids.split(",") if x]
    doc = build_profile(GraphQLClient(), ids, args.window_hours, args.intent)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), mode=0o700, exist_ok=True)
    tmp = args.output + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, args.output)
    print(json.dumps({
        "output": args.output, "channelCount": doc["channelCount"],
        "generatedAt": doc["generatedAt"],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
