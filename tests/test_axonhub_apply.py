import copy
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY = os.path.join(ROOT, "deploy", "axonhub")
import sys
sys.path.insert(0, DEPLOY)
spec = importlib.util.spec_from_file_location("axonhub_apply", os.path.join(DEPLOY, "apply.py"))
apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply)


def assoc(cid, model, priority=1, disabled=False):
    return {"type": "channel_model", "priority": priority, "disabled": disabled,
            "channelModel": {"channelId": cid, "modelId": model}}


def channel(cid, kind="ds", status="enabled", key="k1", shared=None):
    return {
        "id": "gid://axonhub/Channel/" + str(cid), "name": "c" + str(cid),
        "status": status, "orderingWeight": 100, "baseURL": "https://x/v1",
        "supportedModels": ["deepseek-v4.1-flash"] if kind == "ds" else ["hy4-flash-free"],
        "defaultTestModel": "deepseek-v4.1-flash" if kind == "ds" else "hy4-flash-free",
        "allModelEntries": [], "disabledAPIKeys": [], "ds_kind": kind,
        "key_group": {"key_fp": key, "key_count": 1, "shared_key_with": shared or []},
    }


def model(name, associations):
    return {"id": "gid://axonhub/Model/" + name, "modelID": name, "name": name,
            "status": "enabled", "settings": {"associations": associations,
            "loadBalancerStrategy": "failover", "traceStickyMode": "default"}}


def live_state():
    models = {
        "deepseek-jb": model("deepseek-jb", [assoc(51, "hy4-flash-free", 0), assoc(46, "deepseek-v4.1-flash", 3)]),
        "deepseek-safe": model("deepseek-safe", [assoc(25, "deepseek-v4.1-flash", 1), assoc(51, "hy4-flash-free", 3)]),
        "gpt-5.6-luna": model("gpt-5.6-luna", [assoc(48, "deepseek-v4.1-flash-1017", 1), assoc(49, "deepseek-4.1-flash-1017", 1), assoc(46, "deepseek-v4.1-flash", 3)]),
        "gpt-5.6-sol": model("gpt-5.6-sol", [assoc(48, "deepseek-v4.1-flash-1017", 1), assoc(46, "deepseek-v4.1-flash", 3)]),
    }
    channels = {
        "25": channel(25, key="k25"), "46": channel(46, key="kop", shared=["51"]),
        "48": channel(48, key="kw", shared=["49"]), "49": channel(49, key="kw", shared=["48"]),
        "51": channel(51, kind="non_ds", key="kop", shared=["46"]),
    }
    return {"models": models, "channels": channels}


def decision(changes, proposals=None):
    return {"round": "test", "autoApply": False, "changes": changes,
            "modelCardProposals": proposals or []}


class AxonhubApplyTest(unittest.TestCase):
    def test_normal_decision_passes_guardrails(self):
        live = live_state()
        d = decision([{"action": "move_priority", "channel": 48, "model": "gpt-5.6-luna",
                       "from": 1, "to": 4, "intent": "x", "evidence": "y"}])
        # 同 key 的 49 也在 luna，必须一起移动；补上后通过。
        d["changes"].append({"action": "move_priority", "channel": 49, "model": "gpt-5.6-luna",
                             "from": 1, "to": 4, "intent": "x", "evidence": "y"})
        plan = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertTrue(plan["canExecute"], plan)
        self.assertEqual(plan["blocked"], [])
        self.assertEqual(plan["guardrails"], [])

    def test_51_migration_blocked_when_free_card_missing(self):
        live = live_state()
        d = decision(
            [{"action": "migrate_to_free_card", "channel": 51, "model": "deepseek-jb",
              "from": 0, "to": None, "targetCard": "free-hy4-flash",
              "intent": "x", "evidence": "y"}],
            [{"card": "free-hy4-flash", "sourceChannel": 51,
              "upstreamModels": ["hy4-flash-free"]}],
        )
        plan = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertFalse(plan["canExecute"])
        self.assertTrue(any("free 卡尚未创建" in x["reason"] for x in plan["blocked"]))

    def test_51_migration_requires_probe_ok_after_card_creation(self):
        live = live_state()
        live["models"]["free-hy4-flash"] = model("free-hy4-flash", [])
        d = decision(
            [{"action": "migrate_to_free_card", "channel": 51, "model": "deepseek-jb",
              "from": 0, "to": None, "targetCard": "free-hy4-flash",
              "intent": "x", "evidence": "y"}],
            [{"card": "free-hy4-flash", "sourceChannel": 51,
              "upstreamModels": ["hy4-flash-free"]}],
        )
        blocked = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertTrue(any("尚未探活通过" in x["reason"] for x in blocked["blocked"]))
        ready = apply.build_apply_plan(
            d, live, {"free-hy4-flash": {"status": "probe_ok"}}, auto_apply=True
        )
        self.assertTrue(ready["canExecute"], ready)

    def test_more_than_three_non_keep_changes_blocked(self):
        live = live_state()
        live["models"]["gpt-5.6-luna"]["settings"]["associations"].append(
            assoc(25, "deepseek-v4.1-flash", 1)
        )
        changes = []
        for cid, frm in ((48, 1), (49, 1), (46, 3), (25, 1)):
            changes.append({"action": "move_priority", "channel": cid,
                            "model": "gpt-5.6-luna", "from": frm, "to": 4,
                            "intent": "x", "evidence": "y"})
        plan = apply.build_apply_plan(decision(changes), live, auto_apply=True)
        self.assertFalse(plan["canExecute"])
        self.assertTrue(any("上限 3" in x for x in plan["guardrails"]))

    def test_cannot_leave_card_without_enabled_ds_channel(self):
        live = live_state()
        live["models"]["deepseek-jb"]["settings"]["associations"] = [
            assoc(46, "deepseek-v4.1-flash", 3)
        ]
        d = decision([{"action": "keep_disabled", "channel": 46, "model": None,
                       "from": 3, "to": None, "intent": "x", "evidence": "y"}])
        plan = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertFalse(plan["canExecute"])
        self.assertTrue(any("没有任何 enabled 的 DS 渠道" in x for x in plan["guardrails"]))

    def test_mutation_failure_rolls_back_and_writes_alert(self):
        live = live_state()
        snapshot = {"models": [live["models"]["deepseek-jb"], live["models"]["deepseek-safe"]],
                    "channels": [live["channels"]["46"]]}
        operations = [
            {"kind": "update_model", "model": "deepseek-jb",
             "settings": live["models"]["deepseek-jb"]["settings"]},
            {"kind": "update_model", "model": "deepseek-safe",
             "settings": live["models"]["deepseek-safe"]["settings"]},
        ]
        with tempfile.TemporaryDirectory() as td:
            alert_path = os.path.join(td, "alerts.log")
            client = apply.SimulatedClient(fail_on=2)
            result = apply.execute_operations(
                client, operations, snapshot, auto_apply=True,
                alert_fn=lambda msg: apply.write_alert(msg, alert_path),
            )
            self.assertFalse(result["executed"])
            self.assertTrue(result["rollbackAttempted"])
            self.assertGreater(len(client.calls), 2)
            with open(alert_path, encoding="utf-8") as f:
                self.assertIn("ALERT=apply", f.read())

    def test_auto_apply_false_never_calls_mutation(self):
        class NoWriteClient:
            def __init__(self):
                self.calls = []
            def gql(self, query):
                self.calls.append(query)
                raise AssertionError("auto_apply=false 不应调用 client")
        client = NoWriteClient()
        result = apply.execute_operations(
            client, [{"kind": "update_model", "model": "deepseek-jb", "settings": {}}],
            {"models": [], "channels": []}, auto_apply=False,
        )
        self.assertFalse(result["executed"])
        self.assertEqual(client.calls, [])

    def test_shared_key_group_requires_both_channels(self):
        live = live_state()
        d = decision([{"action": "move_priority", "channel": 48, "model": "gpt-5.6-luna",
                       "from": 1, "to": 4, "intent": "x", "evidence": "y"}])
        plan = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertTrue(any("共用 key 同组保护" in x for x in plan["guardrails"]))

    def test_priority_out_of_range_blocked(self):
        live = live_state()
        d = decision([{"action": "move_priority", "channel": 48, "model": "gpt-5.6-luna",
                       "from": 1, "to": 100, "intent": "x", "evidence": "y"}])
        plan = apply.build_apply_plan(d, live, auto_apply=True)
        self.assertTrue(any("priority 非法" in x["reason"] for x in plan["blocked"]))

    def test_snapshot_contains_no_plaintext_credentials(self):
        live = live_state()
        d = decision([{"action": "move_priority", "channel": 48, "model": "gpt-5.6-luna",
                       "from": 1, "to": 4, "intent": "x", "evidence": "y"}])
        with tempfile.TemporaryDirectory() as td:
            snap, path = apply.create_snapshot(live, d, "decision.json", td)
            with open(path, encoding="utf-8") as f:
                raw = f.read()
            self.assertNotIn('"credentials"', raw)
            self.assertNotIn('"apiKeys"', raw)
            self.assertIn("key_group", raw)


if __name__ == "__main__":
    unittest.main()
