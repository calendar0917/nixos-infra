import datetime
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE = os.path.join(ROOT, "deploy", "axonhub", "profile.py")
spec = importlib.util.spec_from_file_location("axonhub_profile", PROFILE)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class AxonhubProfileTest(unittest.TestCase):
    def test_profile_has_exactly_16_logical_fields(self):
        self.assertEqual(len(profile.PROFILE_FIELDS), 16)
        self.assertEqual(len(set(profile.PROFILE_FIELDS)), 16)

    def test_ds_kind_prefers_observed_non_ds_model(self):
        self.assertEqual(
            profile.ds_kind(["deepseek-jb"], "hy4-flash-free"), "non_ds"
        )
        self.assertEqual(
            profile.ds_kind(["deepseek-v4.1-flash"], None), "ds"
        )
        self.assertEqual(profile.ds_kind(["some-opaque-model"], None), "unknown")

    def test_temporary_requires_keyword_and_recent_creation(self):
        now = datetime.datetime(2026, 11, 28, tzinfo=datetime.timezone.utc)
        self.assertTrue(profile.is_temporary(
            "weekend-temp", "2026-11-27T00:00:00Z", "", "", now
        )[0])
        self.assertFalse(profile.is_temporary(
            "hub-1125", "2026-11-01T00:00:00Z", "", "", now
        )[0])
        self.assertTrue(profile.is_temporary(
            "mystery", "2026-11-01T00:00:00Z", "备注：临时", "", now
        )[0])

    def test_key_fingerprint_never_contains_plaintext(self):
        key = "sk-TEST-NOT-A-REAL-KEY-0123456789abcdef"
        fp = profile.key_fingerprint(key)
        self.assertEqual(fp, hashlib.sha256(key.encode()).hexdigest()[:8])
        self.assertNotIn(key, fp)
        self.assertEqual(len(fp), 8)

    def test_shared_key_groups(self):
        channels = [
            {"identity": {"id": "46"}, "key_group": {"key_fp": "abc12345"}},
            {"identity": {"id": "51"}, "key_group": {"key_fp": "abc12345"}},
            {"identity": {"id": "48"}, "key_group": {"key_fp": "def67890"}},
        ]
        self.assertEqual(
            profile.shared_key_groups(channels),
            {"abc12345": ["46", "51"], "def67890": ["48"]},
        )

    def test_window_rate_and_low_sample_logic(self):
        self.assertEqual(profile.window_rate(100, 5), 95.0)
        self.assertEqual(profile.window_rate(0, 0), None)
        self.assertEqual(profile.window_rate(3, 1), 66.7)

    def test_median_or_none(self):
        self.assertEqual(profile.median_or_none([10, 2, 4]), 4)
        self.assertEqual(profile.median_or_none([None]), None)

    def test_hint_conflict_flags_non_ds_claimed_ds(self):
        conflicts = profile.hint_conflict(
            {"description": "opencode 的 DS 通道"}, "non_ds", False, 99.9
        )
        self.assertIn("hint 说 DS，实测为 non_ds", conflicts)

    def test_hint_conflict_flags_stability_when_rate_low(self):
        conflicts = profile.hint_conflict(
            {"description": "稳定的 DS 中转"}, "ds", False, 12.5
        )
        self.assertIn("hint 说稳定，实测 24h 成功率 <80%", conflicts)

    def test_current_tier_map(self):
        arr = {
            "deepseek-jb": [
                {"priority": 0, "disabled": False, "channelModel": {"channelId": 51}},
                {"priority": 3, "disabled": True, "channelModel": {"channelId": 46}},
            ]
        }
        out = profile.current_tier_map(arr)
        self.assertEqual(out["deepseek-jb"][0], {"priority": 0, "disabled": False})
        self.assertEqual(out["deepseek-jb"][1], {"priority": 3, "disabled": True})
        self.assertIn("deepseek-safe", out)

    def test_load_user_hints_parses_name_description_url_and_key_ref(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as f:
            f.write(
                "# test\n"
                "- temp-1127：临时破限 DS，五小时额度，"
                "url=https://linuxdo.si/v1，key_ref=AXONHUB_KEY_TEMP1127\n"
            )
            path = f.name
        try:
            hints = profile.load_user_hints(path)
            self.assertEqual(hints["temp-1127"]["url"], "https://linuxdo.si/v1")
            self.assertEqual(hints["temp-1127"]["key_ref"], "AXONHUB_KEY_TEMP1127")
            self.assertIn("五小时", hints["temp-1127"]["description"])
        finally:
            os.unlink(path)

    def test_profile_schema_contains_no_plaintext_key_field(self):
        # 构建层在把 credentials 写入画像前就 pop 掉；这里直接断言字段集合不含它。
        self.assertNotIn("credentials", profile.PROFILE_FIELDS)
        self.assertIn("key_group", profile.PROFILE_FIELDS)

    def test_reset_state_uses_utc_and_marks_past_window(self):
        self.assertEqual(
            profile.reset_state("2026-11-28T01:55:00Z", "2026-11-28T09:15:00+00:00"),
            "past",
        )
        self.assertEqual(
            profile.reset_state("2026-11-28T10:55:00Z", "2026-11-28T09:15:00+00:00"),
            "future",
        )
        self.assertEqual(profile.reset_state(None, "2026-11-28T09:15:00+00:00"), "unknown")

    def test_reset_time_extracted_from_error(self):
        self.assertEqual(
            profile.reset_time_from_error(
                "You've reached your weekly usage limit; reset 2026-11-28T01:55Z"
            ),
            "2026-11-28T01:55Z",
        )
        self.assertEqual(
            profile.reset_time_from_error(
                "Your limit resets at 2026-11-28T01:55:10.695Z. Please wait"
            ),
            "2026-11-28T01:55:10.695Z",
        )

    def test_upstream_unavailable_overrides_high_success_rate(self):
        h = profile.upstream_health(
            "disabled", "504 Gateway Timeout", total_24h=39685, requests_with_5xx=271
        )
        self.assertEqual(h["upstream_health"], "unavailable")
        self.assertTrue(h["error_pressure_severe"])

    def test_quota_limited_is_not_misclassified_as_upstream_failure(self):
        h = profile.upstream_health(
            "enabled", "weekly usage limit; reset 2026-11-28T01:55Z", 16, 0
        )
        self.assertEqual(h["upstream_health"], "quota_limited")

    def test_intent_cmd_url_is_commandcode_not_hub(self):
        path = os.path.join(ROOT, "deploy", "axonhub", "intent.md")
        hints = profile.load_user_hints(path)
        self.assertEqual(
            hints["cmd"]["url"], "https://api.commandcode.ai/provider/v1"
        )


if __name__ == "__main__":
    unittest.main()
