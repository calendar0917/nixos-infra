import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECIDE = os.path.join(ROOT, "deploy", "axonhub", "decide.py")
spec = importlib.util.spec_from_file_location("axonhub_decide", DECIDE)
decide = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decide)


class AxonhubDecideFactsTest(unittest.TestCase):
    def test_prompt_requires_reset_state_and_upstream_health(self):
        prompt = decide.build_prompt("intent", {"now_utc": "x", "channels": []})
        self.assertIn("quota.reset_state", prompt)
        self.assertIn("error_pressure.upstream_health", prompt)
        self.assertIn("禁止自己换算时区", prompt)
        self.assertIn("finalSuccessRate", prompt)
        self.assertIn("暂不换 key", prompt)

    def test_47_unavailable_is_forced_keep_disabled(self):
        profile = {"channels": [{
            "identity": {"id": "47"},
            "error_pressure": {"upstream_health": "unavailable", "error_pressure_severe": True},
        }]}
        doc = {"summary": "47 成功率高但观察", "changes": [{
            "action": "keep", "channel": 47, "intent": "x", "evidence": "successRate=99.6",
        }]}
        out = decide.fact_check_decision(doc, profile)
        self.assertEqual(out["changes"][0]["action"], "keep_disabled")
        self.assertIn("upstream_health=unavailable", out["changes"][0]["evidence"])
        self.assertIn("上游不可用", out["changes"][0]["note"])

    def test_26_past_reset_window_corrects_model_conclusion(self):
        profile = {"channels": [{
            "identity": {"id": "26"},
            "quota": {"reset_state": "past", "nextResetAt": "2026-11-28T01:55Z"},
        }]}
        doc = {"summary": "26 周额度未过，保持不进 p1", "changes": [{
            "action": "keep_out_of_p1", "channel": 26,
            "intent": "x", "evidence": "low_sample=true",
        }]}
        out = decide.fact_check_decision(doc, profile)
        self.assertIn("quota.reset_state=past", out["changes"][0]["evidence"])
        self.assertIn("窗口已过", out["changes"][0]["note"])
        self.assertIn("窗口已过", out["summary"])

    def test_duplicate_reset_state_is_collapsed(self):
        profile = {"channels": [{
            "identity": {"id": "26"}, "quota": {"reset_state": "past"},
        }]}
        doc = {"summary": "", "changes": [{
            "action": "keep_out_of_p1", "channel": 26, "intent": "x",
            "evidence": "quota.reset_state=past; quota.reset_state=past，low_sample=true",
        }]}
        out = decide.fact_check_decision(doc, profile)
        self.assertEqual(out["changes"][0]["evidence"].count("quota.reset_state=past"), 1)

    def test_non_ds_migration_covers_all_four_ds_cards(self):
        tiers = [
            {"model": "deepseek-jb", "priority": 0, "disabled": False},
            {"model": "deepseek-safe", "priority": 3, "disabled": False},
            {"model": "gpt-5.6-luna", "priority": 4, "disabled": False},
            {"model": "gpt-5.6-sol", "priority": 5, "disabled": False},
        ]
        profile = {"channels": [{
            "identity": {"id": "51", "name": "opencode-free"}, "ds_kind": "non_ds",
            "models": {"supported": ["hy4-flash-free", "hungerg-free"]},
            "current_tier": tiers,
        }]}
        doc = {"summary": "", "changes": []}
        out = decide.fact_check_decision(doc, profile)
        migrations = [x for x in out["changes"] if x["action"] == "migrate_to_free_card"]
        self.assertEqual({x["model"] for x in migrations}, set(decide.DS_CARD_MODELS))
        self.assertEqual(len(out["modelCardProposals"]), 2)

    def test_render_page_deduplicates_channel_model_action(self):
        doc = {
            "source": "model", "round": "r", "generatedAt": "t",
            "summary": "s", "changes": [
                {"channel": 48, "model": "gpt-5.6-luna", "action": "move_priority",
                 "from": 1, "to": 4, "evidence": "first"},
                {"channel": 48, "model": "gpt-5.6-luna", "action": "move_priority",
                 "from": 1, "to": 4, "evidence": "duplicate"},
            ], "no_change": [],
        }
        page = decide.render_page(doc)
        self.assertEqual(page.count("| 48 |"), 1)
        self.assertIn("first", page)
        self.assertNotIn("duplicate", page)

    def test_strict_model_mode_never_falls_back_to_rules(self):
        with tempfile.TemporaryDirectory() as td:
            profile_path = os.path.join(td, "profile.json")
            intent_path = os.path.join(td, "intent.md")
            json_out = os.path.join(td, "decision.json")
            page_out = os.path.join(td, "decision.md")
            with open(profile_path, "w", encoding="utf-8") as f:
                json.dump({"channels": []}, f)
            with open(intent_path, "w", encoding="utf-8") as f:
                f.write("intent")
            with mock.patch.object(decide, "run_model", return_value=(None, "empty response")):
                rc = decide.main([
                    "--profile", profile_path, "--intent", intent_path,
                    "--mode", "model", "--state-dir", td,
                    "--json-out", json_out, "--page-out", page_out,
                ])
            self.assertEqual(rc, 2)
            with open(json_out, encoding="utf-8") as f:
                doc = json.load(f)
            self.assertEqual(doc["source"], "model-failed")
            self.assertEqual(doc["changes"], [])
            self.assertIn("empty response", doc["modelError"])


if __name__ == "__main__":
    unittest.main()
