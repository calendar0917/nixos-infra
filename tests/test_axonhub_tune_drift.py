import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TUNE = os.path.join(ROOT, "deploy", "axonhub", "tune.py")
spec = importlib.util.spec_from_file_location("axonhub_tune", TUNE)
tune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tune)


class AxonhubDriftTest(unittest.TestCase):
    def test_no_fixed_scope_count_constant(self):
        self.assertFalse(hasattr(tune, "SCOPE_MIN_EXPECTED"))

    def test_non_ds_on_jb_p0_is_intent_violation(self):
        profile = {"channels": [{
            "identity": {"id": "51"}, "ds_kind": "non_ds",
            "current_tier": [{"model": "deepseek-jb", "priority": 0, "disabled": False}],
        }]}
        alerts = tune._profile_drift_alerts(profile, {"51": [0]}, {})
        self.assertTrue(any("意图/画像不一致 51" in x for x in alerts))

    def test_channel_disappears_from_scope_is_profile_drift(self):
        profile = {"channels": [
            {"identity": {"id": "48"}, "ds_kind": "ds",
             "current_tier": [{"model": "deepseek-jb", "priority": 1, "disabled": False}]},
            {"identity": {"id": "49"}, "ds_kind": "ds",
             "current_tier": [{"model": "deepseek-jb", "priority": 1, "disabled": False}]},
        ]}
        alerts = tune._profile_drift_alerts(profile, {"48": [1]}, {})
        self.assertTrue(any("画像漂移：渠道掉出 49" in x for x in alerts))

    def test_other_cards_do_not_create_false_drift(self):
        profile = {"channels": [{
            "identity": {"id": "45"}, "ds_kind": "ds",
            "current_tier": [{"model": "gpt-5.6-luna", "priority": 2, "disabled": False}],
        }]}
        self.assertEqual(tune._profile_drift_alerts(profile, {}, {}), [])

    def test_normal_snapshot_has_no_drift_alert(self):
        profile = {"channels": [{
            "identity": {"id": "25"}, "ds_kind": "ds",
            "current_tier": [{"model": "deepseek-safe", "priority": 1, "disabled": False}],
        }]}
        self.assertEqual(tune._profile_drift_alerts(profile, {"25": [1]}, {}), [])

    def test_free_copy_transition_suppresses_only_non_ds_old_association_alert(self):
        profile = {"channels": [{
            "identity": {"id": "51"}, "ds_kind": "non_ds",
            "current_tier": [{"model": "deepseek-jb", "priority": 0, "disabled": False}],
            "key_group": {"shared_key_with": ["46"]},
            "error_pressure": {"requests_with_429": 8}, "quota": {"status": "available"},
        }, {
            "identity": {"id": "46"}, "ds_kind": "ds",
            "current_tier": [{"model": "deepseek-jb", "priority": 3, "disabled": False}],
            "key_group": {"shared_key_with": ["51"]},
            "error_pressure": {"requests_with_429": 159}, "quota": {"status": "available"},
        }]}
        alerts = tune._profile_drift_alerts(
            profile, {"51": [0], "46": [3]}, {}, allow_non_ds_transition=True
        )
        self.assertFalse(any("意图/画像不一致 51" in x for x in alerts))
        self.assertTrue(any("共用key配额/429风险 46<->51" in x for x in alerts))

    def test_shared_key_quota_429_alert_is_persistent(self):
        profile = {"channels": [
            {"identity": {"id": "46"}, "ds_kind": "ds",
             "current_tier": [{"model": "deepseek-jb", "priority": 3, "disabled": False}],
             "key_group": {"shared_key_with": ["51"]},
             "error_pressure": {"requests_with_429": 159}, "quota": {"status": "available"}},
            {"identity": {"id": "51"}, "ds_kind": "non_ds",
             "current_tier": [{"model": "deepseek-jb", "priority": 0, "disabled": False}],
             "key_group": {"shared_key_with": ["46"]},
             "error_pressure": {"requests_with_429": 8}, "quota": {"status": "available"}},
        ]}
        alerts = tune._profile_drift_alerts(profile, {"46": [3], "51": [0]}, {})
        self.assertTrue(any("共用key配额/429风险 46<->51" in x for x in alerts))


if __name__ == "__main__":
    unittest.main()
