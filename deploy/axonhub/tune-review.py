#!/usr/bin/env python3
"""axonhub 渠道调权：每 20 分钟模型复盘，产出 override.json。

流程（由 systemd 用户 timer 每 20 分钟触发一次，不占用 DS Bot 主对话）：
  1. 读 ~/.local/state/axonhub-tune/state.json 最近 12 轮 + override.json 现状 + 最近日志
  2. 拼 prompt，用 ~/DS Bot/tools/pi-task.py 起一个短会话
  3. 只接受三类指令（pin / pause_probe / archive_candidate），模型最多 3 条，
     每条的 expires_at（epoch 秒）由本脚本按 minutes 重算，不信任模型给的
  4. 校验通过才原子写 override.json；模型失败/输出不合法就不动旧文件
  5. source=manual 的条目是用户手工决定，原样保留，模型不得覆盖
  6. 同一个 pin(id,weight) 连续 3 轮一致 → 自动升格为 manual（续期 1440 分钟），
     并在 state.json 的 promoteLog 里记一条；之后不再每 20 分钟重算

硬约束（写进 prompt，也在这里用代码兜底）：
  - 不得删除渠道、不得停用渠道、不得改 credentials、不得改 model 卡
  - 只写上述三类指令；每轮最多 3 条；拿不准就不写
  - 保护名单（目前只有 45/temp-1127）不接受模型给出的
    archive_candidate / pause_probe
"""
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.environ.get(
    "AXONHUB_TUNE_STATE_DIR", os.path.expanduser("~/.local/state/axonhub-tune")
)
STATE_PATH = os.path.join(STATE_DIR, "state.json")
OVERRIDE_PATH = os.path.join(STATE_DIR, "override.json")
REVIEW_STATE_PATH = os.path.join(STATE_DIR, "review-state.json")
LOCK_PATH = os.path.join(STATE_DIR, "state.lock")
TUNE_LOG = os.path.join(STATE_DIR, "tune.log")
REVIEW_LOG = os.path.join(STATE_DIR, "review.log")
PROMPT_PATH = os.path.join(STATE_DIR, "review-prompt.txt")

PI_TASK = os.environ.get(
    "AXONHUB_PI_TASK", os.path.expanduser("~/DS Bot/tools/pi-task.py")
)
PI_WEB_PASSWORD_FILE = os.path.expanduser("~/.config/pi-web/password")
REVIEW_TIMEOUT = int(os.environ.get("AXONHUB_REVIEW_TIMEOUT", "600"))
# 模型偶发返回空回复（stopReason=error、0 token）：隔一会儿整轮重跑一次
REVIEW_RETRY_WAIT = int(os.environ.get("AXONHUB_REVIEW_RETRY_WAIT", "60"))

OVERRIDE_MAX = 3
MINUTES_DEFAULT = 60
MINUTES_MAX = 20160  # 最多两周
HISTORY_KEEP = 12
LOG_TAIL = 60
REVIEW_RUNS_KEEP = 12  # review-state.json 保留最近多少轮模型判断
PROMOTE_ROUNDS = 3     # 连续多少轮相同 pin 自动升格 manual
PROMOTE_MINUTES = 1440  # 升格后的有效期（一天后复查）

# 受保护渠道：模型不得标成 archive_candidate，也不得暂停探活。
# 45 = temp-1127，deepseek-jb 的 p2 备用主力，用户明确等它额度恢复后放第二顺位。
PROTECTED = {
    "45": "temp-1127：deepseek-jb 的 p2 备用主力，等额度恢复后放第二顺位，"
    "现在只是 credits 用尽，不是渠道坏了",
}


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log_line(msg):
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(REVIEW_LOG) and os.path.getsize(REVIEW_LOG) > 400_000:
            with open(REVIEW_LOG, encoding="utf-8", errors="replace") as f:
                tail = f.readlines()[-1000:]
            with open(REVIEW_LOG, "w", encoding="utf-8") as f:
                f.writelines(tail)
        with open(REVIEW_LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now_iso(), msg))
    except OSError:
        pass


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


# ------------------------------------------------------------------ 状态文件
def atomic_write_json(path, doc):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def lock_state():
    """和 tune.py 共用同一把锁，避免两进程同时改 state.json 互相覆盖。"""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def unlock_state(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def write_review_state(rs):
    atomic_write_json(REVIEW_STATE_PATH, rs)


def save_run(rs, items, base_round):
    """记一轮模型判断；items=[] 表示这轮没拿到有效输出（会打断连续计数）。"""
    runs = rs.get("runs")
    if not isinstance(runs, list):
        runs = []
    runs.append({"ts": now_iso(), "baseRound": base_round, "items": items})
    rs["runs"] = runs[-REVIEW_RUNS_KEEP:]
    rs["lastRun"] = now_iso()
    write_review_state(rs)


def trailing_count(runs, kind, cid, weight):
    """从最近一轮往前数，连续多少轮都给出同一个 (kind,id,weight)。"""
    n = 0
    for r in reversed(runs):
        items = r.get("items") if isinstance(r, dict) else None
        if not isinstance(items, list):
            break
        hit = any(
            isinstance(i, dict)
            and i.get("kind") == kind
            and str(i.get("id")) == cid
            and i.get("weight") == weight
            for i in items
        )
        if not hit:
            break
        n += 1
    return n


def append_promote_log(entries):
    """把升格记录追加进 state.json 的 promoteLog（tune.py 保存时会合并，不会丢）。"""
    if not entries:
        return
    fd = lock_state()
    try:
        state = read_json(STATE_PATH, None)
        if not isinstance(state, dict):
            return
        log = state.get("promoteLog")
        if not isinstance(log, list):
            log = []
        log.extend(entries)
        state["promoteLog"] = log[-200:]
        atomic_write_json(STATE_PATH, state)
    finally:
        unlock_state(fd)


def compact_history(state):
    """只保留复盘需要的字段，别把 state.json 整个塞进 prompt。"""
    out = []
    for h in (state.get("history") or [])[-HISTORY_KEEP:]:
        chans = {}
        for cid, c in (h.get("channels") or {}).items():
            chans[cid] = {
                "name": c.get("name"),
                "w": c.get("weight"),
                "rate": c.get("successRate"),
                "n": c.get("total"),
                "r429": c.get("r429_1h"),
                "d429": c.get("r429Delta"),
                "drate": c.get("rateDelta"),
                "probe": c.get("probe"),
                "status": c.get("status"),
            }
        out.append(
            {
                "round": h.get("round"),
                "ts": h.get("ts"),
                "channels": chans,
                "changes": h.get("changes"),
                "recovered": h.get("recovered"),
                "alerts": h.get("alerts"),
                "scopeCount": len(h.get("scope") or []) or None,
            }
        )
    return out


def build_prompt(state, override, tune_log, review_log):
    round_no = int(state.get("rounds") or 0)
    nxt = round_no + 1
    payload = {
        "currentRound": round_no,
        "nextRound": nxt,
        "history": compact_history(state),
        "overrideNow": override,
        "recentTuneLog": tune_log.strip().splitlines()[-40:],
        "recentReviewLog": review_log.strip().splitlines()[-10:],
    }
    return """你是 axonhub 渠道池的调权复盘助手。每 20 分钟复盘一次，只输出 JSON，不要解释、不要调用工具、不要写文件。

# 数据
下面是最近 12 轮状态摘要、当前 override.json、最近日志（JSON）：
__DATA__

# 你能做的事（只能写这三类指令）
1. pin：固定某渠道权重一段时间
   {"kind":"pin","id":"<渠道id>","weight":<1-1000>,"minutes":<1-20160>,"reason":"<不超过60字>"}
2. pause_probe：暂停对某渠道的探活一段时间（比如刚恢复，怕连续探活又打挂）
   {"kind":"pause_probe","id":"<渠道id>","minutes":<1-20160>,"reason":"<不超过60字>"}
3. archive_candidate：把某渠道标记为「待归档候选」，交给人工决定（不会自动删除）
   {"kind":"archive_candidate","id":"<渠道id>","minutes":<1-20160>,"reason":"<不超过60字>"}

# 渠道保护名单（硬约束，违反的指令会被丢弃）
- **id 45（temp-1127）**：deepseek-jb 的 p2 备用主力。用户明确要等它额度/credits
  恢复后放到第二顺位，现在只是额度用尽，不是渠道坏了。
  禁止对 45 输出 archive_candidate 或 pause_probe；45 的 pin 已由人工固定，
  也不要再写 45 的 pin。

# 硬约束（违反的指令会被丢弃）
- 不得删除渠道、不得停用渠道、不得改 API key/credentials、不得改 model 卡。
- **history 里某轮出现 alerts（例如「关联被禁用」「scope 缩水」「pin 空转」）说明
  渠道关联被人改过、渠道掉出了调权范围。这是运维事故，不是渠道质量问题：不要
  因此对相关渠道输出 pause_probe/archive_candidate，在 reason 里点明「等关联修复」
  即可；能输出空指令就输出空指令。**
- 只能写上面三类指令，别发明新字段。
- 每轮最多 3 条；没有把握就输出 {"instructions":[]}。
- id 必须是上面 history 里出现过的渠道 id（纯数字字符串）。
- 不要输出 expires_at，系统会按 minutes 自动换算。
- overrideNow 里 source=manual 的条目是用户手工决定，原样保留；不要提出与它冲突的指令。
- 判断依据：成功率持续 <80%、429 明显上升、连续探活失败 → 考虑 pin 低权重或 archive_candidate；
  刚恢复/刚变好的渠道不要急着调权；样本量小的（n<20）不要下结论。
- 权重不是越高越好：低权重先吃流量；只在明显需要时才提高某个渠道。
- 已经长期稳定的渠道不要反复写指令；上一轮写过的条目如果仍然成立，可以重新写一遍续期。
- 同一条 pin(id,weight) 连续 3 轮保持一致会被系统自动固化为 manual（续期 1440 分钟），
  之后不必再写；只有判断确实变了才改成别的值。

# 输出（严格一个 JSON 对象，不要代码块）
{"instructions":[...]}
""".replace("__DATA__", json.dumps(payload, ensure_ascii=False, indent=1))


def pi_env():
    env = dict(os.environ)
    if not env.get("DSH_SECRET_PI_WEB_PASSWORD"):
        try:
            with open(PI_WEB_PASSWORD_FILE) as f:
                pw = f.read().strip()
            if pw:
                env["DSH_SECRET_PI_WEB_PASSWORD"] = pw
        except OSError:
            pass
    return env


def run_pi(prompt):
    fd = os.open(PROMPT_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(prompt)
    cmd = [
        "/etc/profiles/per-user/calendar/bin/python3",
        PI_TASK,
        "--cwd",
        STATE_DIR,
        "--prompt-file",
        PROMPT_PATH,
        "--timeout",
        str(REVIEW_TIMEOUT),
        "--json",
    ]
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=REVIEW_TIMEOUT + 120,
            env=pi_env(),
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
        return None, "pi 会话仍在下发/运行（未完成）"
    return out, None


def extract_json(lines):
    """从 pi 的助手输出里挑出最后一个合法 JSON 对象。"""
    for line in reversed(lines or []):
        s = line.strip()
        if not s:
            continue
        try:
            return json.loads(s)
        except ValueError:
            pass
        for m in reversed(list(re.finditer(r"\{", s))):
            try:
                obj, _ = json.JSONDecoder().raw_decode(s[m.start():])
            except ValueError:
                continue
            if isinstance(obj, (dict, list)):
                return obj
    return None


def validate(raw, scope):
    """按硬约束校验模型输出；返回 (instructions, rejected)。minutes 由这里兜底。"""
    if isinstance(raw, list):
        instr = raw
    elif isinstance(raw, dict) and isinstance(raw.get("instructions"), list):
        instr = raw["instructions"]
    else:
        return None, ["顶层不是 {instructions:[...]}"]
    out, rejected = [], []
    for i, ins in enumerate(instr):
        if not isinstance(ins, dict):
            rejected.append("第%d条不是对象" % (i + 1))
            continue
        kind = str(ins.get("kind") or "").strip()
        cid = str(ins.get("id") or "").strip()
        reason = str(ins.get("reason") or "").strip()[:200]
        if kind not in ("pin", "pause_probe", "archive_candidate"):
            rejected.append("第%d条 kind 非法" % (i + 1))
            continue
        if cid not in scope:
            rejected.append("第%d条 id %s 不在两张卡范围" % (i + 1, cid or "?"))
            continue
        try:
            minutes = int(ins.get("minutes", MINUTES_DEFAULT))
        except (TypeError, ValueError):
            minutes = 0
        if not 1 <= minutes <= MINUTES_MAX:
            rejected.append("第%d条 minutes 非法" % (i + 1))
            continue
        item = {"kind": kind, "id": cid, "minutes": minutes, "reason": reason}
        if kind == "pin":
            try:
                w = int(ins.get("weight"))
            except (TypeError, ValueError):
                w = 0
            if not 1 <= w <= 1000:
                rejected.append("第%d条 weight 非法" % (i + 1))
                continue
            item["weight"] = w
        out.append(item)
    if len(out) > OVERRIDE_MAX:
        rejected.append("超过每轮 3 条上限，丢弃第 %d-%d 条" % (OVERRIDE_MAX + 1, len(out)))
        out = out[:OVERRIDE_MAX]
    return out, rejected


def keep_manual(override, scope, now, rejected):
    """保留 source=manual 且未过期的条目；这些是用户手工意图，模型不能覆盖。"""
    kept = []
    for i, ins in enumerate(override.get("instructions") or []):
        if not isinstance(ins, dict) or ins.get("source") != "manual":
            continue
        kind = str(ins.get("kind") or "").strip()
        cid = str(ins.get("id") or "").strip()
        try:
            expires = int(ins.get("expires_at"))
        except (TypeError, ValueError):
            rejected.append("manual 第%d条缺 expires_at" % (i + 1))
            continue
        if kind not in ("pin", "pause_probe", "archive_candidate") or cid not in scope:
            rejected.append("manual 第%d条非法" % (i + 1))
            continue
        if expires <= now:
            rejected.append("manual 第%d条已过期" % (i + 1))
            continue
        kept.append(dict(ins))
    return kept


def write_override(instructions, base_round, session_id):
    doc = {
        "schema": 1,
        "generatedAt": now_iso(),
        "generatedBy": "tune-review.py",
        "baseRound": base_round,
        "sessionId": session_id,
        "instructions": instructions,
    }
    tmp = OVERRIDE_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, OVERRIDE_PATH)


def main():
    state = read_json(STATE_PATH, {})
    base_round = int((state or {}).get("rounds") or 0)
    rs = read_json(REVIEW_STATE_PATH, {"runs": []})
    if not isinstance(rs, dict):
        rs = {"runs": []}
    if not state:
        log_line("skip: 没有 state.json（tune.py 还没跑过）")
        save_run(rs, [], base_round)
        return 0
    override = read_json(OVERRIDE_PATH, {"instructions": []})
    tune_log = read_tail(TUNE_LOG, LOG_TAIL)
    review_log = read_tail(REVIEW_LOG, 20)

    scope = set()
    for h in (state.get("history") or [])[-HISTORY_KEEP:]:
        scope.update((h.get("channels") or {}).keys())
    if not scope:
        log_line("skip: state.json 里没有渠道快照")
        save_run(rs, [], base_round)
        return 0

    prompt = build_prompt(state, override, tune_log, review_log)
    out, err = run_pi(prompt)
    if err:
        log_line("fail: " + err)
        save_run(rs, [], base_round)
        return 0
    raw = extract_json(out.get("lines") or [])
    if raw is None:
        # 2026-11-28 15:16 那次：上游返回 stopReason=error、0 token 的空回复，
        # 第一次就判定失败太早。隔 60 秒整轮重跑一次，仍失败才记 fail。
        log_line(
            "retry: 会话 %s 没解析出 JSON，%ds 后重跑一次"
            % (out.get("sessionId") or "?", REVIEW_RETRY_WAIT)
        )
        time.sleep(REVIEW_RETRY_WAIT)
        out2, err2 = run_pi(prompt)
        if not err2:
            raw = extract_json(out2.get("lines") or [])
    if raw is None:
        log_line("fail: 没从会话 %s 里解析出 JSON" % (out.get("sessionId") or "?"))
        save_run(rs, [], base_round)
        return 0
    instructions, rejected = validate(raw, scope)
    if instructions is None:
        log_line("fail: 输出结构不对（%s），保持旧 override.json" % "; ".join(rejected))
        save_run(rs, [], base_round)
        return 0

    # 保护名单兜底：模型不能把受保护渠道标成待归档，也不能停它的探活
    guarded = []
    for ins in instructions:
        if ins["id"] in PROTECTED and ins["kind"] in ("archive_candidate", "pause_probe"):
            rejected.append("id %s 受保护，拒绝 %s" % (ins["id"], ins["kind"]))
            continue
        guarded.append(ins)
    instructions = guarded

    now = int(datetime.datetime.now().timestamp())
    manual = keep_manual(override, scope, now, rejected)
    manual_ids = {(m.get("kind"), str(m.get("id"))) for m in manual}
    manual_chids = {str(m.get("id")) for m in manual}

    # 记录本轮模型判断；连续 PROMOTE_ROUNDS 轮相同 (id,weight) 的 pin 升格 manual
    cur_items = [
        {"kind": i["kind"], "id": i["id"], "weight": i.get("weight")}
        for i in instructions
    ]
    runs = rs.get("runs") if isinstance(rs.get("runs"), list) else []
    runs = runs + [{"ts": now_iso(), "baseRound": base_round, "items": cur_items}]
    rs["runs"] = runs[-REVIEW_RUNS_KEEP:]
    rs["lastRun"] = now_iso()

    promoted, remaining = [], []
    for ins in instructions:
        if (
            ins["kind"] == "pin"
            and ins["id"] not in manual_chids
            and trailing_count(rs["runs"], "pin", ins["id"], ins["weight"])
            >= PROMOTE_ROUNDS
        ):
            p = dict(ins)
            p["minutes"] = PROMOTE_MINUTES
            p["expires_at"] = now + PROMOTE_MINUTES * 60
            p["source"] = "manual"
            p["promotedAt"] = now_iso()
            p["reason"] = ("[自动升格:连续%d轮] " % PROMOTE_ROUNDS + str(p.get("reason") or ""))[
                :200
            ]
            promoted.append(p)
            continue
        remaining.append(ins)

    manual.extend(promoted)
    manual_ids = {(m.get("kind"), str(m.get("id"))) for m in manual}
    manual_chids = {str(m.get("id")) for m in manual}

    final = list(manual)
    for ins in remaining:
        if (ins["kind"], ins["id"]) in manual_ids or ins["id"] in manual_chids:
            rejected.append("id %s 已被 manual 条目占用，模型指令忽略" % ins["id"])
            continue
        ins = dict(ins)
        ins["expires_at"] = now + int(ins.pop("minutes")) * 60
        ins["source"] = "model"
        final.append(ins)

    write_override(final, base_round, out.get("sessionId") or "")
    write_review_state(rs)

    if promoted:
        plog = [
            {
                "ts": now_iso(),
                "kind": p["kind"],
                "id": p["id"],
                "weight": p.get("weight"),
                "expires_at": p["expires_at"],
                "by": "tune-review.py",
                "source": "model:连续%d轮一致" % PROMOTE_ROUNDS,
            }
            for p in promoted
        ]
        append_promote_log(plog)
        log_line(
            "promote: "
            + ",".join("%s:%s" % (p["id"], p.get("weight")) for p in promoted)
        )

    log_line(
        "ok: round=%d session=%s manual=%d model=%d promoted=%d rejected=%s"
        % (
            base_round,
            out.get("sessionId") or "?",
            len(manual),
            len(final) - len(manual),
            len(promoted),
            (";".join(rejected) if rejected else "-"),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
