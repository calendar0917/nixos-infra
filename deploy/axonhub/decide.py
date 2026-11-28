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

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STATE_DIR = os.path.expanduser("~/.local/state/axonhub/decisions")
DECIDE_INTERVAL_MINUTES = int(os.environ.get("AXONHUB_DECIDE_INTERVAL_MINUTES", "10"))
PI_TASK = os.path.expanduser("~/DS Bot/tools/pi-task.py")
PI_WEB_PASSWORD_FILE = os.path.expanduser("~/.config/axonhub-tune/pi-web-password")
MODEL_TIMEOUT = int(os.environ.get("AXONHUB_DECIDE_MODEL_TIMEOUT", "600"))


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
只允许这些 action：move_priority, keep_disabled, mark_review, keep_out_of_p1, keep。
本轮不执行任何变更，只给建议。输出格式：
{
  "round": "<字符串>",
  "summary": "<不超过100字>",
  "changes": [
    {"action":"...", "channel":<id或渠道名>, "model":"<模型名或null>",
     "from":<priority或null>, "to":<priority或null>, "weight":<权重或null>,
     "intent":"<依据>", "evidence":"<画像证据>", "risk":"low|medium|high",
     "confidence":"high|medium|low", "note":"<可选>"}
  ],
  "no_change": ["<保持不动的对象>"]
}
注意：非 DS/free 渠道不能当 deepseek 卡首选；临时渠道标记复评；探活失败/持续5xx保持禁用；
样本不足或配额受限的渠道不要升主位；不确定就不改并说明缺什么证据。

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


def rules_decision(profile):
    channels = {str(c["identity"]["id"]): c for c in profile.get("channels", [])}
    changes = []
    no_change = []

    def add(action, cid, intent, evidence, model=None, frm=None, to=None,
            weight=None, risk="low", confidence="high", note=None):
        ch = channels[cid]
        item = {
            "action": action, "channel": int(cid), "channelName": ch["identity"]["name"],
            "model": model, "from": frm, "to": to, "weight": weight,
            "intent": intent, "evidence": evidence, "risk": risk,
            "confidence": confidence,
        }
        if note:
            item["note"] = note
        changes.append(item)

    c51 = channels.get("51")
    if c51 and c51.get("ds_kind") == "non_ds":
        tiers = [x for x in c51.get("current_tier", []) if x.get("model") == "deepseek-jb"]
        frm = min([x["priority"] for x in tiers if x.get("priority") is not None], default=None)
        add(
            "move_priority", "51", "free/非 DS 渠道不能当 deepseek 卡首选",
            "observed_response_model=%s; ds_kind=non_ds; current_tier=jb p%s"
            % (c51.get("observed_response_model"), frm),
            model="deepseek-jb", frm=frm, to=3,
        )

    c47 = channels.get("47")
    if c47 and (c47["status"]["value"] == "disabled" or c47["error_pressure"]["requests_with_5xx"] > 0):
        add(
            "keep_disabled", "47", "持续 5xx/504 的渠道交探活等待恢复，不要删",
            "upstream_health=%s; severe=%s; 24h 5xx请求=%s; status=%s; last_error=%s"
            % (c47["error_pressure"].get("upstream_health"),
               c47["error_pressure"].get("error_pressure_severe"),
               c47["error_pressure"]["requests_with_5xx"],
               c47["status"]["value"], c47.get("last_error")),
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
        add(
            "keep_out_of_p1", "26", "额度窗口已过可重新探活，但样本不足先不升主位",
            "quota.reset_state=%s; rate_24h=%s%%, n=%s, low_sample=%s, 429请求=%s, last_error=%s"
            % (reset_kind, s["successRate"], s["total"], s["low_sample"],
               c26["error_pressure"]["requests_with_429"], c26.get("last_error")),
            risk="low", confidence="medium" if s["low_sample"] else "high",
            note="窗口已过，可以重新探活；24h 样本不足，先补样本再评估是否进主位",
        )

    for cid in ("25", "38", "46"):
        c = channels.get(cid)
        if c:
            add(
                "keep", cid, "稳定渠道不折腾",
                "rate_24h=%s%%, n=%s, 429请求=%s, 5xx请求=%s, key共享=%s"
                % (c["stats24"]["successRate"], c["stats24"]["total"],
                   c["error_pressure"]["requests_with_429"],
                   c["error_pressure"]["requests_with_5xx"],
                   c["key_group"]["shared_key_with"]),
                confidence="high",
            )

    no_change = ["gpt-5.6-luna", "gpt-5.6-sol", "deepseek-safe", "orderingWeight 全部保持"]
    return {
        "round": "rules-dryrun-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
        "summary": "jb 把非 DS 的 free 从 p0 挪到后备；47 上游不可用保持禁用；26 额度窗口已过可重新探活但样本不足，暂不进主位；临时渠道标记复评。其余不动。",
        "changes": changes,
        "no_change": no_change,
    }


def validate_decision(doc):
    if not isinstance(doc, dict) or not isinstance(doc.get("changes"), list):
        raise ValueError("决策顶层不是 {changes:[...]}")
    allowed = {"move_priority", "keep_disabled", "mark_review", "keep_out_of_p1", "keep"}
    for item in doc["changes"]:
        if not isinstance(item, dict) or item.get("action") not in allowed:
            raise ValueError("非法 action")
        if not item.get("intent") or not item.get("evidence"):
            raise ValueError("每条建议必须带 intent + evidence")
    return doc


def fact_check_decision(doc, profile):
    """对模型输出做事实兜底：时间窗和上游健康度不允许模型猜反。"""
    channels = {str(c["identity"]["id"]): c for c in profile.get("channels", [])}
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
        item["evidence"] = evidence
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
                "", evidence,
            ).lstrip(" ；;，,")
            item["evidence"] = "quota.reset_state=%s; %s" % (state, evidence)
            if state == "past":
                item["note"] = "额度窗口已过，可以重新探活；24h 样本不足，先补样本再评估是否进主位"
    summary = str(doc.get("summary") or "")
    if "26" in channels and (channels["26"].get("quota") or {}).get("reset_state") == "past":
        summary = summary.replace("周额度未过", "周额度窗口已过").replace(
            "额度未过", "额度窗口已过"
        )
    doc["summary"] = summary
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
        if target is not None:
            advice = "%s → p%s" % (action, target)
        else:
            advice = action
        evidence = str(item.get("evidence", "")).replace("|", "/")
        lines.append("| %s | %s | %s | %s |" % (ch, current, advice, evidence))
    if doc.get("no_change"):
        lines += ["", "**保持不动**：" + "、".join(doc["no_change"])]
    lines += [
        "",
        "> 本页只是建议；auto_apply 关闭，没有调用 updateModel / bulkUpdateChannel / createChannel。",
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
    if args.mode in ("auto", "model"):
        decision, model_error = run_model(prompt, args.state_dir)
        if decision:
            source = "model"
    if decision is None:
        decision = rules_decision(profile)
        source = "rules-fallback" if args.mode == "auto" else "rules-offline"

    decision = validate_decision(decision)
    decision = fact_check_decision(decision, profile)
    decision["source"] = source
    decision["generatedAt"] = now_iso()
    decision["decisionIntervalMinutes"] = DECIDE_INTERVAL_MINUTES
    decision["autoApply"] = False
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
        "modelError": model_error,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
