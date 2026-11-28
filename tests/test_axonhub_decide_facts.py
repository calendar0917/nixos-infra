import importlib.util
import os
import unittest

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


if __name__ == "__main__":
    unittest.main()
