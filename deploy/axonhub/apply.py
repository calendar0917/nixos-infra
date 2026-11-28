#!/usr/bin/env python3
"""axonhub 决策执行层（默认 dry-run，绝不静默写线上）。

用法：
  python3 apply.py --decision ~/.local/state/axonhub/decisions/decision-latest.json \
      --dry-run --output ~/.local/state/axonhub/decisions/apply-latest.json
  python3 apply.py --decision ... --plan-free-cards --output .../free-card-plan.json
  python3 apply.py --decision ... --rollback-drill --snapshot .../snapshots/<ts>.json

默认 auto_apply=false：只抓取只读快照、输出 would_apply / blocked，不调用任何 mutation。
--auto-apply 才允许执行；free 卡创建是独立阶段，必须另有用户批准文件。
"""
import argparse
import copy
import datetime
import hashlib
import json
import os
import re
import sys

from decide import DS_CARD_MODELS, atomic_json, now_iso
from profile import GraphQLClient, ds_kind, key_fingerprint, short_id

DEFAULT_DECISION = os.path.expanduser("~/.local/state/axonhub/decisions/decision-latest.json")
DEFAULT_SNAPSHOT_DIR = os.path.expanduser("~/.local/state/axonhub/snapshots")
DEFAULT_FREE_STATE = os.path.expanduser("~/.local/state/axonhub/free-cards.json")
DEFAULT_ALERT_LOG = os.path.expanduser("~/.local/state/axonhub-tune/tune.log")
ACTION_WHITELIST = {
    "keep", "mark_review", "keep_out_of_p1", "keep_disabled",
    "move_priority", "migrate_to_free_card",
}
MUTATING_ACTIONS = {"move_priority", "migrate_to_free_card", "keep_disabled"}
MAX_NON_KEEP_CHANGES = 3
PRIORITY_MIN = 0
PRIORITY_MAX = 99


# ------------------------------------------------------------------ utilities
def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        return default


def write_alert(message, path=None):
    path = path or os.environ.get("AXONHUB_APPLY_ALERT_LOG", DEFAULT_ALERT_LOG)
    row = "%s ALERT=apply %s\n" % (now_iso(), str(message).replace("\n", " ")[:500])
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(row)
    except OSError:
        pass
    return row


def dedupe_changes(changes):
    out, seen = [], set()
    for item in changes or []:
        key = (str(item.get("channel")), str(item.get("model")), item.get("action"))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _channel_ds_kind(ch):
    entries = ch.get("allModelEntries") or []
    actual = [x.get("actualModel") for x in entries if x.get("actualModel")]
    return ds_kind(actual or ch.get("supportedModels") or [], ch.get("defaultTestModel"))


def _assoc_key(a):
    cm = a.get("channelModel") or {}
    return (cm.get("channelId"), cm.get("modelId"))


def _find_assoc(associations, channel_id, model_id=None):
    for a in associations or []:
        cm = a.get("channelModel") or {}
        if cm.get("channelId") == int(channel_id) and (
            model_id is None or cm.get("modelId") == model_id
        ):
            return a
    return None


def _model_node(node):
    return {
        "id": node.get("id"), "modelID": node.get("modelID"),
        "name": node.get("name"), "status": node.get("status"),
        "settings": copy.deepcopy(node.get("settings") or {}),
    }


def _channel_node(node):
    # 快照绝不包含 credentials/apiKeys；只保留 sha256 前 8 位指纹。
    keys = ((node.get("credentials") or {}).get("apiKeys") or [])
    fps = [key_fingerprint(k) for k in keys if k]
    return {
        "id": node.get("id"), "name": node.get("name"), "status": node.get("status"),
        "orderingWeight": node.get("orderingWeight"), "baseURL": node.get("baseURL"),
        "supportedModels": node.get("supportedModels") or [],
        "defaultTestModel": node.get("defaultTestModel"),
        "allModelEntries": node.get("allModelEntries") or [],
        "disabledAPIKeys": [
            {"expiresAt": x.get("expiresAt"), "errorCode": x.get("errorCode")}
            for x in node.get("disabledAPIKeys") or []
        ],
        "ds_kind": _channel_ds_kind(node),
        "key_group": {"key_fp": fps[0] if fps else None, "key_count": len(fps),
                      "shared_key_with": []},
    }


# --------------------------------------------------------------- read-only IO
def fetch_live_state(client):
    model_q = (
        "{models(first:100){edges{node{id modelID name status settings{"
        "disableDeveloperSettingsInheritance loadBalancerStrategy traceStickyMode "
        "associations{type priority disabled channelModel{channelId modelId}}"
        "}}}}}"
    )
    channel_q = (
        "{queryChannels(input:{first:200}){edges{node{id name status orderingWeight "
        "baseURL supportedModels defaultTestModel allModelEntries{requestModel actualModel source} "
        "credentials{apiKeys} disabledAPIKeys{expiresAt errorCode}}}}}"
    )
    models = {}
    for e in client.gql(model_q)["models"]["edges"]:
        n = e["node"]
        models[n["modelID"]] = _model_node(n)
    channels = {}
    for e in client.gql(channel_q)["queryChannels"]["edges"]:
        n = e["node"]
        channels[short_id(n["id"])] = _channel_node(n)
    groups = {}
    for cid, ch in channels.items():
        fp = (ch.get("key_group") or {}).get("key_fp")
        if fp:
            groups.setdefault(fp, []).append(cid)
    for ch in channels.values():
        fp = (ch.get("key_group") or {}).get("key_fp")
        if fp:
            ch["key_group"]["shared_key_with"] = [
                x for x in groups[fp] if x != short_id(ch["id"])
            ]
    return {"models": models, "channels": channels, "generatedAt": now_iso()}


def involved_channel_ids(decision):
    return sorted(
        {str(x.get("channel")) for x in decision.get("changes", []) if x.get("channel") is not None},
        key=lambda x: int(x) if x.isdigit() else 10**9,
    )


def create_snapshot(live, decision, decision_path, snapshot_dir=DEFAULT_SNAPSHOT_DIR):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = os.path.join(snapshot_dir, ts + ".json")
    involved = set(involved_channel_ids(decision))
    model_ids = set(DS_CARD_MODELS)
    for item in decision.get("changes") or []:
        if item.get("action") == "migrate_to_free_card":
            model_ids.update(_target_cards(item))
    doc = {
        "schema": 1,
        "createdAt": now_iso(),
        "decisionFile": os.path.abspath(decision_path),
        "models": [copy.deepcopy(live["models"][m]) for m in DS_CARD_MODELS if m in live["models"]],
        "targetFreeModels": [copy.deepcopy(live["models"][m]) for m in sorted(model_ids - set(DS_CARD_MODELS)) if m in live["models"]],
        "channels": [copy.deepcopy(live["channels"][c]) for c in sorted(involved) if c in live["channels"]],
    }
    atomic_json(path, doc)
    return doc, path


# -------------------------------------------------------------- free card plan
def plan_free_card_creation(decision, live_models):
    plans = []
    for p in decision.get("modelCardProposals") or []:
        card = str(p.get("card") or "")
        if not card.startswith("free-"):
            continue
        source = str(p.get("sourceChannel"))
        upstream = list(p.get("upstreamModels") or [])
        associations = [
            {"type": "channel_model", "priority": 1, "disabled": False,
             "channelModel": {"channelId": int(source), "modelId": model}}
            for model in upstream
        ]
        create_input = {
            "developer": "opencode",
            "modelID": card,
            "type": "chat",
            "name": card,
            "icon": "free",
            "group": "free",
            "modelCard": {},
            "settings": {"associations": associations, "loadBalancerStrategy": "failover"},
            "remark": "free 模型独立卡；创建后必须逐模型探活成功才能迁移 51",
        }
        plans.append({
            "card": card,
            "sourceChannel": int(source),
            "upstreamModels": upstream,
            "exists": card in live_models,
            "createModelInput": create_input,
            "probeAfterCreate": [
                {"channelID": "gid://axonhub/Channel/" + source, "modelID": m}
                for m in upstream
            ],
            "execution": "proposal_only",
            "requiresExplicitApproval": True,
            "autoApply": False,
        })
    return plans


def plan_hash(plans):
    raw = json.dumps(plans, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest()


def load_free_card_state(path=DEFAULT_FREE_STATE):
    return load_json(path, {}) or {}


# ------------------------------------------------------------------ validation
def _base_validation(item, live):
    errors = []
    action = item.get("action")
    if action not in ACTION_WHITELIST:
        errors.append("action 不在白名单: %s" % action)
    cid = str(item.get("channel"))
    if cid not in live["channels"]:
        errors.append("channel 不存在: %s" % cid)
    model = item.get("model")
    if model is not None and action in ("move_priority", "migrate_to_free_card") and model not in live["models"]:
        errors.append("model 不存在: %s" % model)
    for field in ("from", "to"):
        value = item.get(field)
        if value is not None:
            if not isinstance(value, int) or not PRIORITY_MIN <= value <= PRIORITY_MAX:
                errors.append("%s priority 非法: %r" % (field, value))
    if any(k in item for k in ("credentials", "apiKey", "delete", "removeChannel")):
        errors.append("决策包含禁止的 key/删除字段")
    return errors


def _target_cards(item):
    return [x.strip() for x in str(item.get("targetCard") or "").split("/") if x.strip()]


def validate_item(item, live, free_state):
    errors = _base_validation(item, live)
    if errors:
        return errors
    action = item.get("action")
    cid = str(item.get("channel"))
    ch = live["channels"][cid]
    model = item.get("model")

    if action == "move_priority":
        if model not in DS_CARD_MODELS:
            errors.append("move_priority 只能作用于四张 DS/luna/sol 卡")
        if item.get("to") is None:
            errors.append("move_priority 缺 to priority")
        if ch.get("ds_kind") != "ds":
            errors.append("DS 卡只能关联 ds_kind=ds 渠道")
        assoc = _find_assoc((live["models"].get(model) or {}).get("settings", {}).get("associations"), cid)
        if not assoc:
            errors.append("source association 不存在: %s/%s" % (model, cid))
        elif item.get("from") is not None and assoc.get("priority") != item.get("from"):
            errors.append("from priority 与线上不一致")

    if action == "migrate_to_free_card":
        cards = _target_cards(item)
        if not cards:
            errors.append("migrate_to_free_card 缺 targetCard")
        if ch.get("ds_kind") != "non_ds":
            errors.append("free 迁移要求 source channel ds_kind=non_ds")
        for card in cards:
            if not card.startswith("free-"):
                errors.append("targetCard 不是 free-*: %s" % card)
                continue
            if card not in live["models"]:
                errors.append("blocked: free 卡尚未创建: %s" % card)
                continue
            target_assocs = (live["models"][card].get("settings") or {}).get("associations") or []
            for a in target_assocs:
                target_ch = live["channels"].get(str((a.get("channelModel") or {}).get("channelId"))) or {}
                if target_ch.get("ds_kind") == "ds":
                    errors.append("targetCard 与 ds_kind 不一致: %s 含 DS 渠道" % card)
                    break
            state = (free_state.get(card) or {})
            if state.get("status") != "probe_ok":
                errors.append("blocked: free 卡尚未探活通过: %s" % card)
        if model not in DS_CARD_MODELS:
            errors.append("migrate_to_free_card 的 source model 必须是四张 DS/luna/sol 卡")
        assoc = _find_assoc((live["models"].get(model) or {}).get("settings", {}).get("associations"), cid)
        if not assoc:
            errors.append("source association 不存在: %s/%s" % (model, cid))

    if action == "keep_disabled" and item.get("to") is not None:
        errors.append("keep_disabled 不能携带 to priority")
    return errors


def _is_mutating(item, live):
    action = item.get("action")
    if action == "keep_disabled":
        return live["channels"].get(str(item.get("channel")), {}).get("status") != "disabled"
    return action in MUTATING_ACTIONS


def shared_key_guard(items, live):
    """同一模型里，共用 key 的 move_priority 必须同组一起决策。"""
    violations = []
    by_model = {}
    for item in items:
        if item.get("action") == "move_priority":
            by_model.setdefault(item.get("model"), []).append(item)
    for model, arr in by_model.items():
        moved = {str(x.get("channel")) for x in arr}
        associations = (live["models"].get(model) or {}).get("settings", {}).get("associations") or []
        associated = {str((a.get("channelModel") or {}).get("channelId")) for a in associations}
        for cid in moved:
            ch = live["channels"].get(cid) or {}
            for other in (ch.get("key_group") or {}).get("shared_key_with") or []:
                other = str(other)
                if other in associated and other not in moved:
                    violations.append(
                        "共用 key 同组保护: %s 与 %s 在 %s 上必须一起决策" % (cid, other, model)
                    )
    return violations


def apply_changes_to_live(live, accepted_items):
    """在内存里模拟最终状态，用于「至少留一条 enabled DS」护栏。"""
    sim = copy.deepcopy(live)
    for item in accepted_items:
        action = item.get("action")
        cid = str(item.get("channel"))
        model = item.get("model")
        if action == "keep_disabled" and cid in sim["channels"]:
            sim["channels"][cid]["status"] = "disabled"
        elif action == "move_priority" and model in sim["models"]:
            assocs = sim["models"][model]["settings"]["associations"]
            for a in assocs:
                if (a.get("channelModel") or {}).get("channelId") == int(cid):
                    a["priority"] = item.get("to")
        elif action == "migrate_to_free_card" and model in sim["models"]:
            sim["models"][model]["settings"]["associations"] = [
                a for a in sim["models"][model]["settings"]["associations"]
                if (a.get("channelModel") or {}).get("channelId") != int(cid)
            ]
    return sim


def min_ds_guard(live, accepted_items):
    sim = apply_changes_to_live(live, accepted_items)
    violations = []
    for model in DS_CARD_MODELS:
        ok = False
        for a in (sim["models"].get(model) or {}).get("settings", {}).get("associations") or []:
            if a.get("disabled"):
                continue
            cm = a.get("channelModel") or {}
            ch = sim["channels"].get(str(cm.get("channelId"))) or {}
            if ch.get("status") == "enabled" and ch.get("ds_kind") == "ds":
                ok = True
                break
        if not ok:
            violations.append("%s 将没有任何 enabled 的 DS 渠道" % model)
    return violations


# --------------------------------------------------------------------- plan
def build_apply_plan(decision, live, free_state=None, auto_apply=False):
    free_state = free_state or {}
    changes = dedupe_changes(decision.get("changes"))
    proposals = {str(p.get("card")): p for p in decision.get("modelCardProposals") or []}
    validated, blocked = [], []
    for idx, item in enumerate(changes):
        errors = validate_item(item, live, free_state)
        if item.get("action") == "migrate_to_free_card":
            for card in _target_cards(item):
                p = proposals.get(card) or {}
                if not p.get("upstreamModels"):
                    errors.append("blocked: 缺 free 卡 createModel/association 计划: %s" % card)
        row = {"index": idx, "action": item.get("action"), "channel": item.get("channel"),
               "model": item.get("model"), "targetCard": item.get("targetCard")}
        if errors:
            row["reason"] = "; ".join(errors)
            blocked.append(row)
        else:
            validated.append(item)

    mutating = [x for x in validated if _is_mutating(x, live)]
    guardrails = []
    if len(mutating) > MAX_NON_KEEP_CHANGES:
        guardrails.append(
            "单轮非 keep 变更 %d > 上限 %d" % (len(mutating), MAX_NON_KEEP_CHANGES)
        )
    guardrails.extend(shared_key_guard(mutating, live))
    guardrails.extend(min_ds_guard(live, validated))

    can_execute = not blocked and not guardrails
    would_apply = []
    for item in validated:
        action = item.get("action")
        if not _is_mutating(item, live):
            would_apply.append({"action": action, "channel": item.get("channel"),
                                "model": item.get("model"), "status": "noop/review"})
            continue
        status = "would_apply" if can_execute and auto_apply else "blocked"
        reason = None
        if blocked:
            reason = "decision 含 blocked 项，整轮不半执行"
        elif guardrails:
            reason = "硬护栏未通过"
        elif not auto_apply:
            reason = "auto_apply=false"
        would_apply.append({
            "action": action, "channel": item.get("channel"), "model": item.get("model"),
            "from": item.get("from"), "to": item.get("to"),
            "targetCard": item.get("targetCard"), "status": status, "reason": reason,
        })
    return {
        "schema": 1,
        "generatedAt": now_iso(),
        "decisionRound": decision.get("round"),
        "autoApply": bool(auto_apply),
        "canExecute": can_execute,
        "guardrails": guardrails,
        "blocked": blocked,
        "wouldApply": would_apply,
        "freeCardPlans": plan_free_card_creation(decision, live["models"]),
        "note": "auto_apply=false 时只输出计划；不会调用 createModel/updateModel/bulkUpdateChannel/createChannel。",
    }


# -------------------------------------------------------------- operations
def build_operations(decision, live, accepted_items):
    """把已通过校验的决策合并成尽量少的 updateModel / status 操作。"""
    final_models = copy.deepcopy(live["models"])
    channel_status = {}
    proposals = {p["card"]: p for p in decision.get("modelCardProposals") or []}
    add_first, remove_last = [], []

    for item in accepted_items:
        action = item.get("action")
        cid = str(item.get("channel"))
        model = item.get("model")
        if action == "keep_disabled":
            channel_status[cid] = "disabled"
        elif action == "move_priority":
            for a in final_models[model]["settings"]["associations"]:
                if (a.get("channelModel") or {}).get("channelId") == int(cid):
                    a["priority"] = item.get("to")
        elif action == "migrate_to_free_card":
            for card in _target_cards(item):
                if card not in final_models:
                    continue
                p = proposals.get(card) or {}
                for upstream in p.get("upstreamModels") or []:
                    if not _find_assoc(final_models[card]["settings"]["associations"], cid, upstream):
                        final_models[card]["settings"]["associations"].append({
                            "type": "channel_model", "priority": 1, "disabled": False,
                            "channelModel": {"channelId": int(cid), "modelId": upstream},
                        })
                        add_first.append(card)
            final_models[model]["settings"]["associations"] = [
                a for a in final_models[model]["settings"]["associations"]
                if (a.get("channelModel") or {}).get("channelId") != int(cid)
            ]
            remove_last.append(model)

    operations = []
    for cid, status in channel_status.items():
        if live["channels"].get(cid, {}).get("status") != status:
            operations.append({
                "kind": "update_channel_status", "channel": cid, "status": status,
                "phase": 1,
            })
    for card in dict.fromkeys(add_first):
        operations.append({
            "kind": "update_model", "model": card,
            "settings": copy.deepcopy(final_models[card]["settings"]), "phase": 2,
        })
    for model in DS_CARD_MODELS:
        if model in final_models and final_models[model]["settings"] != live["models"][model]["settings"]:
            operations.append({
                "kind": "update_model", "model": model,
                "settings": copy.deepcopy(final_models[model]["settings"]),
                "phase": 3 if model in remove_last else 2,
            })
    operations.sort(key=lambda x: x["phase"])
    return operations


def _gql_update_model(client, model, settings):
    query = (
        'mutation($id:ID!,$input:UpdateModelInput!){updateModel(id:$id,input:$input){id}}'
    )
    return client.gql(query, {
        "id": "gid://axonhub/Model/" + model,
        "input": {"settings": {
            "associations": settings.get("associations") or [],
            "loadBalancerStrategy": settings.get("loadBalancerStrategy") or "failover",
        }},
    })


def execute_operations(client, operations, snapshot, auto_apply=False, alert_fn=write_alert):
    if not auto_apply:
        return {"executed": False, "reason": "auto_apply=false", "operations": len(operations)}
    executed = []
    try:
        for op in operations:
            if op["kind"] == "update_channel_status":
                client.gql(
                    'mutation{updateChannelStatus(id:%s,status:%s){id}}'
                    % (json.dumps("gid://axonhub/Channel/" + op["channel"]),
                       json.dumps(op["status"]))
                )
            elif op["kind"] == "update_model":
                _gql_update_model(client, op["model"], op["settings"])
            else:
                raise RuntimeError("未知 operation: %s" % op["kind"])
            executed.append(op["kind"])
        client.gql('mutation{clearCache(input:{targets:[CHANNEL_CACHE]}){success}}')
        return {"executed": True, "operations": executed}
    except Exception as exc:
        alert_fn("mutation 失败，自动回滚: %s" % exc)
        rollback_error = None
        try:
            rollback_snapshot(client, snapshot)
        except Exception as rexc:
            rollback_error = str(rexc)
            alert_fn("回滚失败: %s" % rexc)
        return {
            "executed": False, "failedAfter": len(executed),
            "error": str(exc), "rollbackAttempted": True,
            "rollbackError": rollback_error,
        }


def rollback_snapshot(client, snapshot):
    for model in (snapshot.get("models") or []) + (snapshot.get("targetFreeModels") or []):
        settings = model.get("settings") or {}
        _gql_update_model(client, model["modelID"], settings)
    channels = snapshot.get("channels") or []
    for ch in channels:
        client.gql(
            'mutation{updateChannelStatus(id:%s,status:%s){id}}'
            % (json.dumps(ch["id"]), json.dumps(ch.get("status") or "disabled"))
        )
    if channels:
        items = ",".join(
            '{id:%s,orderingWeight:%d}' % (json.dumps(ch["id"]), int(ch.get("orderingWeight") or 0))
            for ch in channels
        )
        client.gql(
            "mutation{bulkUpdateChannelOrdering(input:{channels:[%s]}){updated}}" % items
        )
    client.gql('mutation{clearCache(input:{targets:[CHANNEL_CACHE]}){success}}')


class SimulatedClient:
    """回滚演练专用：只记录 mutation，第二次调用模拟失败，绝不联网。"""
    def __init__(self, fail_on=2):
        self.calls = []
        self.fail_on = fail_on

    def gql(self, query, variables=None):
        self.calls.append(query)
        if len(self.calls) == self.fail_on:
            raise RuntimeError("simulated mutation failure")
        return {}


def rollback_drill(snapshot, alert_path):
    client = SimulatedClient(fail_on=2)
    operations = [
        {"kind": "update_model", "model": DS_CARD_MODELS[0],
         "settings": snapshot["models"][0]["settings"]},
        {"kind": "update_model", "model": DS_CARD_MODELS[1],
         "settings": snapshot["models"][1]["settings"]},
    ]
    result = execute_operations(
        client, operations, snapshot, auto_apply=True,
        alert_fn=lambda msg: write_alert(msg, alert_path),
    )
    result["simulatedCalls"] = len(client.calls)
    result["rollbackQueriesPresent"] = any("updateModel" in q for q in client.calls[2:])
    result["clearCachePresent"] = any("clearCache" in q for q in client.calls)
    result["networkUsed"] = False
    return result


# ---------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description="axonhub 决策执行层 dry-run")
    ap.add_argument("--decision", default=DEFAULT_DECISION)
    ap.add_argument("--output", default=os.path.expanduser("~/.local/state/axonhub/decisions/apply-latest.json"))
    ap.add_argument("--snapshot-dir", default=DEFAULT_SNAPSHOT_DIR)
    ap.add_argument("--snapshot", help="rollback-drill 使用指定快照；指定后不联网")
    ap.add_argument("--free-state", default=DEFAULT_FREE_STATE)
    ap.add_argument("--auto-apply", action="store_true", help="显式允许写线上；默认关闭")
    ap.add_argument("--dry-run", action="store_true", help="显式 dry-run（默认就是 dry-run）")
    ap.add_argument("--plan-free-cards", action="store_true", help="只输出 createModel 计划")
    ap.add_argument("--rollback-drill", action="store_true", help="用模拟 client 演练失败回滚")
    args = ap.parse_args(argv)

    decision = load_json(args.decision)
    if not isinstance(decision, dict):
        raise SystemExit("decision 文件不存在或不是 JSON")
    if decision.get("autoApply") is True and not args.auto_apply:
        raise SystemExit("decision autoApply=true，但本进程未显式 --auto-apply")

    if args.rollback_drill and args.snapshot:
        snapshot = load_json(args.snapshot)
        if not isinstance(snapshot, dict):
            raise SystemExit("snapshot 文件不存在或不是 JSON")
        snapshot_path = os.path.abspath(args.snapshot)
        live = None
    else:
        client = GraphQLClient()
        live = fetch_live_state(client)
        snapshot, snapshot_path = create_snapshot(live, decision, args.decision, args.snapshot_dir)

    if args.rollback_drill:
        result = rollback_drill(snapshot, os.path.join(args.snapshot_dir, "rollback-drill.log"))
        result["snapshot"] = snapshot_path
        atomic_json(args.output, result)
        print(json.dumps(result, ensure_ascii=False))
        return 0

    free_state = load_free_card_state(args.free_state)
    plan = build_apply_plan(decision, live, free_state, auto_apply=args.auto_apply)
    plan["snapshot"] = snapshot_path
    if args.plan_free_cards:
        plan["freeCardPlanHash"] = plan_hash(plan["freeCardPlans"])
        plan["freeCardPlans"] = [
            dict(p, status="needs_user_approval") for p in plan["freeCardPlans"]
        ]
    atomic_json(args.output, plan)

    if args.auto_apply and plan["canExecute"]:
        accepted = [
            x for x in dedupe_changes(decision.get("changes"))
            if not validate_item(x, live, free_state)
        ]
        operations = build_operations(decision, live, accepted)
        result = execute_operations(client, operations, snapshot, auto_apply=True)
        plan["execution"] = result
        atomic_json(args.output, plan)
    elif args.auto_apply:
        write_alert("apply 被护栏拦截: %s" % "; ".join(plan["guardrails"] + [x["reason"] for x in plan["blocked"]]))
    print(json.dumps({
        "output": args.output, "snapshot": snapshot_path,
        "autoApply": args.auto_apply, "canExecute": plan["canExecute"],
        "blocked": len(plan["blocked"]), "guardrails": plan["guardrails"],
        "wouldApply": len(plan["wouldApply"]),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
