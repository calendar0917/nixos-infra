#!/usr/bin/env python3
"""axonhub 意图驱动决策 dry-run。

读取 intent.md + profile.py 生成的画像，输出：
  - 结构化 JSON（可审计，未来 apply.py 消费）
  - 一页可读建议（给人看）

默认 mode=auto：先用现有 pi-task 起模型决策；模型失败时回退到离线规则并标记
source=rules-fallback。mode=offline 只跑规则，用于测试/上游不可用时的 dry-run。
本脚本不调用任何 axonhub 写接口，不实现 apply。

决策频率配置：AXONHUB_DECIDE_INTERVAL_MINUTES，默认 10，改成 30 即降频。
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STATE_DIR = os.path.expanduser("~/.local/state/axonhub/decisions")
DECIDE_INTERVAL_MINUTES = int(os.environ.get("AXONHUB_DECIDE_INTERVAL_MINUTES", "10"))
PI_TASK = os.path.expanduser("~/DS Bot/tools/pi-task.py")
PI_WEB_PASSWORD_FILE = os.path.expanduser("~/.config/axonhub-tune/pi-web-password")
MODEL_TIMEOUT = int(os.environ.get("AXONHUB_DECIDE_MODEL_TIMEOUT", "600"))
DS_CARD_MODELS = ("deepseek-jb", "deepseek-safe", "gpt-5.6-luna", "gpt-5.6-sol")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def atomic_json(path, doc):
    os.makedirs(os.path.dirname(os.path.abspath(path)), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def pi_env():
    env = dict(os.environ)
    if not env.get("DSH_SECRET_PI_WEB_PASSWORD"):
        try:
            with open(PI_WEB_PASSWORD_FILE, encoding="utf-8") as f:
                pw = f.read().strip()
            if pw:
                env["DSH_SECRET_PI_WEB_PASSWORD"] = pw
        except OSError:
            pass
    return env


def extract_json(lines):
    for line in reversed(lines or []):
        s = line.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
            if isinstance(obj, dict):
                return obj
        except ValueError:
            pass
        for m in reversed(list(re.finditer(r"\{", s))):
            try:
                obj, _ = json.JSONDecoder().raw_decode(s[m.start():])
                if isinstance(obj, dict):
                    return obj
            except ValueError:
                continue
    return None


def build_prompt(intent, profile):
    payload = {
        "intent": intent,
        "profile": profile,
        "decisionFrequencyMinutes": DECIDE_INTERVAL_MINUTES,
    }
    return """你是 axonhub 渠道池的决策助手。只输出一个严格 JSON 对象，不要解释、不要代码块、不要调用工具。
用户目标见 intent，所有实测数据见 profile。你必须按 intent 的「稳定 > 成本」硬顺序判断，
不要临场改变优先级；每条建议必须写清依据哪条意图和哪个画像字段。
只允许这些 action：move_priority, migrate_to_free_card, keep_disabled, mark_review, keep_out_of_p1, keep。
本轮不执行任何变更，只给建议；auto_apply=false。不得输出或调用 createModel/updateModel/bulkUpdateChannel。
输出格式：
{
  "round": "<字符串>",
  "summary": "<不超过100字>",
  "changes": [
    {"action":"...", "channel":<id或渠道名>, "model":"<模型名或null>",
     "from":<priority或null>, "to":<priority或null>, "weight":<权重或null>,
     "targetCard":"<free 卡名或null>", "intent":"<依据>", "evidence":"<画像证据>",
     "risk":"low|medium|high", "confidence":"high|medium|low", "note":"<可选>"}
  ],
  "modelCardProposals": [
    {"card":"free-...", "purpose":"<用途>", "sourceChannel":<id>,
     "upstreamModels":["..."], "verifiedFamily":"<family 或 undisclosed>",
     "identityEvidence":"<models.catalog 证据>", "priority":1,
     "execution":"proposal_only", "autoApply":false}
  ],
  "no_change": ["<保持不动的对象>"]
}
模型分类硬规则：
1. deepseek-jb/deepseek-safe/gpt-5.6-luna/gpt-5.6-sol 只允许 ds_kind=ds；free/非 DS/stealth
   不得挂任何优先级。发现这种关联必须用 migrate_to_free_card，不是降级到后备。
2. free 模型按 models.catalog 的 canonical_id/family/description 分组：同一 verified family 一张卡，
   不同 family 或身份未公开的模型分别建卡；没有证据就写 undisclosed，禁止猜 GPT/DS/混元。
3. 新卡名一律 free-*，用途和上游模型一眼可辨；proposal 不是写操作，不包含 mutation 名或凭据。
4. 共用 key 只证明账号/上游限额共享，不证明 AxonHub disabledAPIKeys 跨渠道同步；建议要区分
   「拆卡避免误路由」与「换独立 key 才能真正隔离配额」。本轮用户决定暂不换 key，不要建议创建第二把 key；
   46/51 共用 key 的 ALERT、quota 与 429 监控继续保留。
5. 本轮输出必须覆盖：两张 free 卡建议；51 从 deepseek-jb/deepseek-safe/gpt-5.6-luna/gpt-5.6-sol
   四张卡全部摘除；47 保持 disabled；25/26/38/45/46/48/49 的处置。稳定的可以写 keep，但不要漏。
6. stats24.successRate 是「该渠道没有失败 execution 的清洁率」，stats24.finalSuccessRate 是请求最终
   completed 比例。两者差距大说明 failover 掩盖了上游拒绝；必须同时引用并明确指出，不能把
   finalSuccessRate 高当作上游健康。error_pressure.upstream_health=degraded/rate_limited 时要提示
   上游正在拒绝/限流，即使最终成功率高。
注意：临时渠道标记复评；探活失败/持续5xx保持禁用；样本不足或配额受限的渠道不要升主位；
不确定就不改并说明缺什么证据。

时间与健康度的硬规则（必须遵守，不许自行推断）：
1. 当前时间只看 profile.now_utc / profile.now_local；额度重置只看渠道 quota.reset_state
   （past/future/unknown）和 quota.nextResetAt。禁止自己换算时区或猜测窗口是否过期。
   reset_state=past 表示窗口已过，可以重新探活；future 表示还要等待；unknown 表示缺证据。
2. 质量判断必须先看 error_pressure.upstream_health 和 error_pressure_severe，再看 successRate。
   upstream_health=unavailable 时必须输出 keep_disabled，并在 summary/evidence 明确写「上游不可用」，
   即使 successRate 很高（失败重试会把上游 5xx 算成请求成功）。
3. quota_limited 且 reset_state=past 时，不要再说「额度未过」；应建议重新探活/补样本。
   如果同时 low_sample=true 或成功率低，则保持不进主位，理由写成「窗口已过但样本不足，先补样本」。
4. 每条 evidence 必须引用对应字段，例如 quota.reset_state、error_pressure.upstream_health、
   stats24.low_sample；没有这些字段就不要下时间/健康结论。
5. error_pressure.attribution=attribution_unknown 时，last_error 不得参与自动决策；只能输出
   「归属待证/不改」，不能据此判 access_blocked、降权或禁用。统计口径只看
   stats24.countBasis=unique_requests_with_execution_on_channel。

__DATA__
""".replace("__DATA__", json.dumps(payload, ensure_ascii=False, indent=1))


def run_model(prompt, state_dir):
    prompt_path = os.path.join(state_dir, "decision-prompt.txt")
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    fd = os.open(prompt_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(prompt)
    cmd = [
        "/etc/profiles/per-user/calendar/bin/python3", PI_TASK,
        "--cwd", state_dir, "--prompt-file", prompt_path,
        "--timeout", str(MODEL_TIMEOUT), "--json",
    ]
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=MODEL_TIMEOUT + 120, env=pi_env(),
        )
    except subprocess.TimeoutExpired:
        return None, "pi-task 超时"
    if p.returncode != 0:
        return None, "pi-task 退出码 %d: %s" % (p.returncode, (p.stderr or "")[-200:])
    try:
        out = json.loads(p.stdout)
    except ValueError:
        return None, "pi-task 输出不是 JSON"
    if not out.get("finished"):
        return None, "pi 会话仍在运行"
    raw = extract_json(out.get("lines") or [])
    if raw is None:
        return None, "pi 会话没有可解析的 JSON"
    return raw, None


def _slug(value):
    return re.sub(r"[^a-z0-9]+", "-", str(value or "").lower()).strip("-") or "model"


def _is_free_model(model, meta):
    if "free" in str(model).lower():
        return True
    text = (((meta or {}).get("cost") or {}).get("text") or {})
    try:
        return float(text.get("input", {}).get("price")) == 0 and float(
            text.get("output", {}).get("price")
        ) == 0
    except (TypeError, ValueError):
        return False


def _verified_family(model, meta):
    """只在有上游目录证据时合并同族；未知身份一律拆开。"""
    canonical = str((meta or {}).get("canonical_id") or "").strip()
    if canonical:
        provider, _, root = canonical.partition("/")
        root = re.split(r"[-_.]", root or canonical)[0]
        return provider + "/" + root, True
    family = str((meta or {}).get("family") or "").strip()
    if family:
        return family, True
    return "undisclosed/" + str(model), False


def _free_card_name(model, meta, family, verified, grouped=False):
    if grouped:
        return "free-" + _slug(family.replace("/", "-"))
    base = re.sub(r"-free$", "", str(model), flags=re.I)
    name = "free-" + _slug(base)
    description = str((meta or {}).get("description") or "")
    if "stealth" in description.lower() and "stealth" not in name:
        name += "-stealth"
    return name


def build_free_card_proposals(profile):
    """按上游目录证据给 non-DS/free 模型生成独立卡建议；不包含任何写操作。"""
    proposals = []
    for ch in profile.get("channels", []):
        if ch.get("ds_kind") != "non_ds":
            continue
        supported = list((ch.get("models") or {}).get("supported") or [])
        catalog = (ch.get("models") or {}).get("catalog") or {}
        model_stats = (ch.get("models") or {}).get("stats24") or {}
        free_models = [
            m for m in supported if _is_free_model(m, catalog.get(m) or {})
        ]
        if not free_models:
            continue
        groups = {}
        for model in free_models:
            meta = catalog.get(model) or {}
            family, verified = _verified_family(model, meta)
            # 未知身份不能仅因同名前缀就合并。
            key = family if verified else "undisclosed/" + model
            groups.setdefault(key, []).append((model, meta, family, verified))
        used_names = set()
        for entries in groups.values():
            grouped = len(entries) > 1
            first_model, first_meta, family, verified = entries[0]
            name = _free_card_name(
                first_model, first_meta, family, verified, grouped=grouped
            )
            if name in used_names:
                name += "-" + _slug(first_model)
            used_names.add(name)
            evidence = []
            for model, meta, _, item_verified in entries:
                evidence.append(
                    "%s: canonical_id=%s; family=%s; description=%s; verified=%s"
                    % (
                        model,
                        meta.get("canonical_id") or "null",
                        meta.get("family") or "null",
                        str(meta.get("description") or "null")[:120],
                        str(item_verified).lower(),
                    )
                )
            shared = list((ch.get("key_group") or {}).get("shared_key_with") or [])
            proposals.append({
                "card": name,
                "purpose": str(first_meta.get("name") or first_model) + " 免费模型",
                "sourceChannel": int(ch["identity"]["id"]),
                "sourceChannelName": ch["identity"].get("name"),
                "upstreamModels": [x[0] for x in entries],
                "verifiedFamily": family if verified else "undisclosed",
                "identityEvidence": "; ".join(evidence),
                "modelStats24": {x[0]: model_stats.get(x[0]) for x in entries},
                "quota": ch.get("quota") or {},
                "priority": 1,
                "sharedKeyWith": shared,
                "quotaIsolation": (
                    "shared_credential_requires_separate_key" if shared
                    else "independent_credential"
                ),
                "execution": "proposal_only",
                "autoApply": False,
                "confidence": "high" if verified else "low",
            })
    return proposals


def rules_decision(profile):
    channels = {str(c["identity"]["id"]): c for c in profile.get("channels", [])}
    changes = []
    no_change = []

    def add(action, cid, intent, evidence, model=None, frm=None, to=None,
            weight=None, risk="low", confidence="high", note=None, target_card=None):
        ch = channels[cid]
        item = {
            "action": action, "channel": int(cid), "channelName": ch["identity"].get("name"),
            "model": model, "from": frm, "to": to, "weight": weight,
            "intent": intent, "evidence": evidence, "risk": risk,
            "confidence": confidence,
        }
        if note:
            item["note"] = note
        if target_card:
            item["targetCard"] = target_card
        changes.append(item)

    proposals = build_free_card_proposals(profile)
    for cid, ch in channels.items():
        if ch.get("ds_kind") != "non_ds":
            continue
        channel_cards = [p for p in proposals if p["sourceChannel"] == int(cid)]
        if not channel_cards:
            continue
        card_names = "/".join(p["card"] for p in channel_cards)
        tiers_by_model = {
            model: [x for x in ch.get("current_tier", []) if x.get("model") == model]
            for model in DS_CARD_MODELS
        }
        found = False
        for model, tiers in tiers_by_model.items():
            if not tiers:
                continue
            found = True
            priorities = sorted({
                x.get("priority") for x in tiers if x.get("priority") is not None
            })
            frm = "/".join(str(x) for x in priorities) if priorities else None
            add(
                "migrate_to_free_card", cid,
                "模型分类：deepseek-* 与 luna/sol 只允许 ds；free 走独立卡",
                "ds_kind=non_ds; supportedModels=%s; current=%s p%s; target=%s"
                % (",".join((ch.get("models") or {}).get("supported") or []),
                   model, frm, card_names),
                model=model, frm=frm, risk="medium", confidence="high",
                note="从该卡摘除；free 模型改挂独立卡；本轮只建议，不写线上",
                target_card=card_names,
            )
        if not found:
            add(
                "migrate_to_free_card", cid,
                "模型分类：free 模型必须使用独立 free 卡",
                "ds_kind=non_ds; supportedModels=%s; current_tier=无 DS 关联"
                % ",".join((ch.get("models") or {}).get("supported") or []),
                risk="medium", confidence="high",
                note="新建 free 卡建议；本轮不调用 createModel/updateModel",
                target_card=card_names,
            )

    c47 = channels.get("47")
    if c47 and (
        (c47.get("status") or {}).get("value") == "disabled"
        or c47["error_pressure"]["requests_with_5xx"] > 0
    ):
        add(
            "keep_disabled", "47", "持续 5xx/504 的渠道交探活等待恢复，不要删",
            "upstream_health=%s; severe=%s; attribution=%s; 24h 5xx请求=%s; status=%s; last_error=%s"
            % (c47["error_pressure"].get("upstream_health"),
               c47["error_pressure"].get("error_pressure_severe"),
               c47["error_pressure"].get("attribution"),
               c47["error_pressure"]["requests_with_5xx"],
               (c47.get("status") or {}).get("value"), c47.get("last_error")),
            confidence="high", note="上游不可用；successRate 受重试影响，不作为健康依据",
        )

    for cid in ("45", "48", "49"):
        c = channels.get(cid)
        if c and c.get("temporary", {}).get("value"):
            extra = "；等额度窗口" if cid == "45" else ""
            add(
                "mark_review", cid, "临时渠道不能长期占坑；45 等额度窗口",
                "temporary=true(reason=%s); last_error=%s"
                % (c["temporary"].get("reason"), c.get("last_error")),
                confidence="medium", note="不降权、不归档；7 天后或额度重置后复评" + extra,
            )

    c26 = channels.get("26")
    if c26:
        s = c26["stats24"]
        reset_kind = (c26.get("quota") or {}).get("reset_state", "unknown")
        if reset_kind == "past":
            intent26 = "额度窗口已过可重新探活，但样本不足先不升主位"
            note26 = "窗口已过，可以重新探活；24h 样本不足，先补样本再评估是否进主位"
        elif reset_kind == "future":
            intent26 = "额度窗口未到，保持不进主位"
            note26 = "窗口未到，等 quota.nextResetAt 后再探活"
        else:
            intent26 = "额度状态缺证据，保持不进主位"
            note26 = "reset_state=unknown，不猜时区或窗口"
        add(
            "keep_out_of_p1", "26", intent26,
            "quota.reset_state=%s; rate_24h=%s%%, n=%s, low_sample=%s, 429请求=%s, last_error=%s"
            % (reset_kind, s["successRate"], s["total"], s["low_sample"],
               c26["error_pressure"]["requests_with_429"], c26.get("last_error")),
            risk="low", confidence="medium" if s["low_sample"] else "high",
            note=note26,
        )

    for cid in ("25", "38", "46"):
        c = channels.get(cid)
        if c:
            unknown = c["error_pressure"].get("attribution_unknown")
            rate = c["stats24"].get("successRate")
            low_rate = rate is not None and rate < 80
            action = "keep"
            intent = "稳定渠道不折腾"
            note = None
            if unknown:
                intent = "错误归属无法证明时不据此调权"
                note = "last_error 不参与自动决策，等待 execution.channelID/requestURL 证明"
            elif low_rate:
                action = "mark_review"
                intent = "24h 成功率低于 80%，先观察，不自动升权"
                note = "本轮只标记复评；不据此直接改线上权重"
            add(
                action, cid, intent,
                "rate_24h=%s%%, n=%s, 429请求=%s, 5xx请求=%s, key共享=%s; attribution=%s"
                % (rate, c["stats24"]["total"],
                   c["error_pressure"]["requests_with_429"],
                   c["error_pressure"]["requests_with_5xx"],
                   c["key_group"]["shared_key_with"],
                   c["error_pressure"].get("attribution")),
                confidence="medium" if unknown or low_rate else "high",
                note=note,
            )

    card_names = "/".join(p["card"] for p in proposals)
    no_change = [
        "deepseek-jb/safe/luna/sol 只保留 ds_kind=ds",
        "orderingWeight 全部保持",
        "共用 key 的渠道：换独立 key 前不宣称配额隔离",
    ]
    summary_parts = []
    if proposals:
        summary_parts.append("free 模型建议 %d 张卡（%s）并从 DS/luna/sol 摘除" % (
            len(proposals), card_names
        ))
    summary_parts.append("47 上游不可用保持禁用")
    if c26:
        state26 = (c26.get("quota") or {}).get("reset_state", "unknown")
        summary_parts.append(
            "26 窗口已过但样本不足，暂不进主位" if state26 == "past"
            else "26 额度状态=%s，暂不进主位" % state26
        )
    if any(c["error_pressure"].get("attribution_unknown") for c in channels.values()):
        summary_parts.append("错误归属待证的渠道不参与自动调权")
    summary_parts.append("临时渠道标记复评")
    return {
        "round": "rules-dryrun-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
        "summary": "；".join(summary_parts) + "。其余不动。",
        "changes": changes,
        "modelCardProposals": proposals,
        "guardrails": [
            "auto_apply=false",
            "free 卡只做建议，不调用 createModel/updateModel/bulkUpdateChannel",
            "共用 key 的账号配额/429 共同承担；拆卡不等于拆配额",
        ],
        "no_change": no_change,
        "autoApply": False,
    }


def validate_decision(doc):
    if not isinstance(doc, dict) or not isinstance(doc.get("changes"), list):
        raise ValueError("决策顶层不是 {changes:[...]}")
    if doc.get("autoApply") not in (None, False):
        raise ValueError("dry-run 不允许 autoApply=true")
    allowed = {
        "move_priority", "migrate_to_free_card", "keep_disabled",
        "mark_review", "keep_out_of_p1", "keep",
    }
    for item in doc["changes"]:
        if not isinstance(item, dict) or item.get("action") not in allowed:
            raise ValueError("非法 action")
        if not item.get("intent") or not item.get("evidence"):
            raise ValueError("每条建议必须带 intent + evidence")
        if item.get("action") == "migrate_to_free_card" and item.get("to") is not None:
            raise ValueError("free 迁移不能降级到 DS 卡后备位")
    proposals = doc.get("modelCardProposals", [])
    if not isinstance(proposals, list):
        raise ValueError("modelCardProposals 必须是列表")
    for proposal in proposals:
        if not isinstance(proposal, dict) or not str(proposal.get("card") or "").startswith("free-"):
            raise ValueError("free 卡名必须以 free- 开头")
        if not proposal.get("upstreamModels"):
            raise ValueError("free 卡建议必须列出上游模型")
        if proposal.get("execution") != "proposal_only" or proposal.get("autoApply") is not False:
            raise ValueError("free 卡建议只能 proposal_only + autoApply=false")
    return doc


def fact_check_decision(doc, profile):
    """对模型输出做事实兜底：分类、时间窗、上游健康度和错误归属都不许猜反。"""
    channels = {str(c["identity"]["id"]): c for c in profile.get("channels", [])}
    generated_proposals = build_free_card_proposals(profile)
    proposals = generated_proposals or doc.get("modelCardProposals") or []
    doc["modelCardProposals"] = proposals
    for item in doc.get("changes", []):
        cid = str(item.get("channel"))
        ch = channels.get(cid)
        if not ch:
            continue
        pressure = ch.get("error_pressure") or {}
        evidence = str(item.get("evidence") or "")
        for state in ("past", "future", "unknown"):
            evidence = evidence.replace(
                "quota.reset_state=%s; quota.reset_state=%s" % (state, state),
                "quota.reset_state=%s" % state,
            )
        if ch.get("ds_kind") == "non_ds" and item.get("model") in DS_CARD_MODELS:
            cards = [
                p["card"] for p in proposals if p["sourceChannel"] == int(cid)
            ]
            item["action"] = "migrate_to_free_card"
            item["to"] = None
            item["weight"] = None
            item["targetCard"] = "/".join(cards) or item.get("targetCard")
            if "ds_kind=non_ds" not in evidence:
                evidence = "ds_kind=non_ds; " + evidence
            item["note"] = "free/非 DS 不得留在 DS 卡任何优先级；改挂独立 free 卡"
        if pressure.get("attribution_unknown") and item.get("action") != "migrate_to_free_card":
            item["action"] = "keep"
            item["to"] = None
            item["weight"] = None
            evidence = "attribution=attribution_unknown; last_error 不参与自动决策; " + evidence
            item["note"] = "错误归属无法证明，撤销据此产生的降权/禁用/升位建议"
        item["evidence"] = evidence
        if item.get("action") == "keep_disabled":
            item["to"] = None
            item["weight"] = None
        if cid == "47" and pressure.get("upstream_health") == "unavailable":
            item["action"] = "keep_disabled"
            evidence = str(item.get("evidence") or "")
            if "upstream_health=unavailable" not in evidence:
                evidence = "upstream_health=unavailable; error_pressure_severe=true; " + evidence
            item["evidence"] = evidence
            item["note"] = "上游不可用；successRate 受失败重试影响，不能当作健康依据"
        if cid == "26":
            state = (ch.get("quota") or {}).get("reset_state", "unknown")
            evidence = re.sub(
                r"quota\.reset_state=(?:past|future|unknown)\s*[;；]?\s*",
                "", str(item.get("evidence") or ""),
            ).lstrip(" ；;，,、")
            item["evidence"] = "quota.reset_state=%s; %s" % (state, evidence)
            if state == "past":
                item["note"] = "额度窗口已过，可以重新探活；24h 样本不足，先补样本再评估是否进主位"
            elif state == "future":
                item["note"] = "额度窗口未到，等 quota.nextResetAt 后再探活"
            else:
                item["note"] = "reset_state=unknown，不猜时区或窗口"
    # 硬约束兜底：即使模型漏写，也必须覆盖 non-DS 渠道在四张 DS/luna/sol 卡上的摘除。
    existing = {(str(x.get("channel")), x.get("model")) for x in doc.get("changes", [])}
    for cid, ch in channels.items():
        if ch.get("ds_kind") != "non_ds":
            continue
        cards = [p["card"] for p in proposals if p["sourceChannel"] == int(cid)]
        for tier in ch.get("current_tier") or []:
            model = tier.get("model")
            if model not in DS_CARD_MODELS or tier.get("disabled"):
                continue
            if (cid, model) in existing:
                continue
            doc["changes"].append({
                "action": "migrate_to_free_card", "channel": int(cid),
                "channelName": ch["identity"].get("name"), "model": model,
                "from": tier.get("priority"), "to": None, "weight": None,
                "targetCard": "/".join(cards),
                "intent": "模型分类：deepseek-* 与 luna/sol 只允许 ds；free 走独立卡",
                "evidence": "ds_kind=non_ds; supported=%s; current_tier=%s:p%s"
                % (",".join((ch.get("models") or {}).get("supported") or []),
                   model, tier.get("priority")),
                "risk": "medium", "confidence": "high",
                "note": "从该卡摘除；free 模型改挂独立卡；本轮只建议，不写线上",
            })
            existing.add((cid, model))
    if not any(str(x.get("channel")) == "47" for x in doc.get("changes", [])):
        ch = channels.get("47")
        if ch and (ch.get("error_pressure") or {}).get("upstream_health") == "unavailable":
            doc["changes"].append({
                "action": "keep_disabled", "channel": 47,
                "channelName": ch["identity"].get("name"), "model": None,
                "from": None, "to": None, "weight": None,
                "intent": "持续 5xx/504 的渠道交探活等待恢复，不要删",
                "evidence": "upstream_health=unavailable; error_pressure_severe=true; last_error=%s"
                % ch.get("last_error"),
                "risk": "low", "confidence": "high",
                "note": "上游不可用；successRate 受失败重试影响，不能当作健康依据",
            })
    summary = str(doc.get("summary") or "")
    if "26" in channels and (channels["26"].get("quota") or {}).get("reset_state") == "past":
        summary = summary.replace("周额度未过", "周额度窗口已过").replace(
            "额度未过", "额度窗口已过"
        )
    if proposals and "free" not in summary.lower():
        summary += " free 模型迁移到独立卡。"
    card_names = {p.get("card") for p in proposals}
    if "free-hungerg-stealth" in card_names:
        summary = re.sub(r"free-hungerg(?!-stealth)", "free-hungerg-stealth", summary)
        doc["no_change"] = [
            re.sub(r"free-hungerg(?!-stealth)", "free-hungerg-stealth", str(x))
            for x in doc.get("no_change", [])
        ]
    if any((c.get("error_pressure") or {}).get("attribution_unknown") for c in channels.values()):
        summary += " 错误归属待证的渠道不参与自动调权。"
    doc["summary"] = summary
    doc["autoApply"] = False
    return doc


def render_page(doc):
    lines = [
        "# axonhub 决策建议（dry-run）",
        "",
        "> source=%s · round=%s · 时间=%s · 决策间隔=%d 分钟"
        % (doc.get("source", "unknown"), doc.get("round"), doc.get("generatedAt"),
           doc.get("decisionIntervalMinutes", DECIDE_INTERVAL_MINUTES)),
        "",
        doc.get("summary", ""),
        "",
        "| 渠道 | 现状 | 建议 | 一句话理由 |",
        "| --- | --- | --- | --- |",
    ]
    for item in doc.get("changes", []):
        ch = item.get("channelName") or item.get("channel")
        current = item.get("from")
        if current is not None:
            current = "p%s" % current
        elif item.get("action") == "keep_disabled":
            current = "disabled"
        else:
            current = item.get("model") or "-"
        action = item["action"]
        target = item.get("to")
        if action == "migrate_to_free_card":
            advice = "migrate_to_free_card → " + str(item.get("targetCard") or "free-*")
        elif target is not None:
            advice = "%s → p%s" % (action, target)
        else:
            advice = action
        evidence = str(item.get("evidence", "")).replace("|", "/")
        lines.append("| %s | %s | %s | %s |" % (ch, current, advice, evidence))
    proposals = doc.get("modelCardProposals") or []
    if proposals:
        lines += [
            "",
            "## 独立 free 卡建议（不执行）",
            "",
            "| 卡名 | 上游模型 | 已验证家族 | key/配额 |",
            "| --- | --- | --- | --- |",
        ]
        for p in proposals:
            lines.append(
                "| %s | %s | %s | %s |"
                % (
                    p.get("card"),
                    ",".join(p.get("upstreamModels") or []),
                    p.get("verifiedFamily"),
                    ("与 %s 共用，需独立 key 才隔离" % ",".join(p.get("sharedKeyWith") or []))
                    if p.get("sharedKeyWith") else "独立",
                )
            )
    if doc.get("guardrails"):
        lines += ["", "**护栏**：" + "；".join(doc["guardrails"])]
    if doc.get("no_change"):
        lines += ["", "**保持不动**：" + "、".join(doc["no_change"])]
    lines += [
        "",
        "> 本页只是建议；auto_apply 关闭，没有调用 createModel / updateModel / bulkUpdateChannel / createChannel。",
    ]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="axonhub 意图驱动决策 dry-run")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--intent", default=os.path.join(HERE, "intent.md"))
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    ap.add_argument("--mode", choices=("auto", "offline", "model"), default="auto")
    ap.add_argument("--json-out", default=os.path.join(DEFAULT_STATE_DIR, "decision-latest.json"))
    ap.add_argument("--page-out", default=os.path.join(DEFAULT_STATE_DIR, "decision-latest.md"))
    args = ap.parse_args(argv)

    profile = load_json(args.profile)
    with open(args.intent, encoding="utf-8") as f:
        intent = f.read()
    prompt = build_prompt(intent, profile)

    source = None
    model_error = None
    decision = None
    model_elapsed = None
    if args.mode in ("auto", "model"):
        model_started = time.time()
        decision, model_error = run_model(prompt, args.state_dir)
        model_elapsed = round(time.time() - model_started, 2)
        if decision:
            source = "model"
    if decision is None and args.mode == "model":
        # 严格模型模式：失败就明确失败，禁止 rules-offline 冒充 source=model。
        failure = {
            "round": "model-failed-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
            "source": "model-failed",
            "generatedAt": now_iso(),
            "autoApply": False,
            "modelError": model_error or "模型未返回决策",
            "elapsedSeconds": model_elapsed,
            "changes": [],
            "modelCardProposals": [],
            "no_change": [],
        }
        atomic_json(args.json_out, failure)
        failure_page = (
            "# axonhub 决策 dry-run（模型失败）\n\n"
            "> source=model-failed · auto_apply=false · 耗时=%s 秒\n\n"
            "%s\n\n没有使用 rules-offline 兜底。\n"
        ) % (model_elapsed, model_error or "模型未返回决策")
        with open(args.page_out, "w", encoding="utf-8") as f:
            f.write(failure_page)
        print(json.dumps({
            "source": "model-failed", "json": args.json_out, "page": args.page_out,
            "autoApply": False, "modelError": model_error,
            "elapsedSeconds": model_elapsed,
        }, ensure_ascii=False))
        return 2
    if decision is None:
        decision = rules_decision(profile)
        source = "rules-fallback" if args.mode == "auto" else "rules-offline"

    decision = fact_check_decision(decision, profile)
    decision = validate_decision(decision)
    decision["source"] = source
    decision["generatedAt"] = now_iso()
    decision["decisionIntervalMinutes"] = DECIDE_INTERVAL_MINUTES
    decision["autoApply"] = False
    decision["elapsedSeconds"] = model_elapsed
    if model_error:
        decision["modelError"] = model_error[:240]
    atomic_json(args.json_out, decision)
    page = render_page(decision)
    tmp = args.page_out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(page)
    os.chmod(tmp, 0o600)
    os.replace(tmp, args.page_out)
    print(json.dumps({
        "source": source, "json": args.json_out, "page": args.page_out,
        "changes": len(decision["changes"]), "autoApply": False,
        "modelError": model_error, "elapsedSeconds": model_elapsed,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
