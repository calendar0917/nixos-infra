import importlib.util
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECIDE = os.path.join(ROOT, "deploy", "axonhub", "decide.py")
spec = importlib.util.spec_from_file_location("axonhub_decide_free", DECIDE)
decide = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decide)


def free_channel(catalog, tiers=None, shared=None):
    return {
        "identity": {"id": "51", "name": "opencode-free"},
        "ds_kind": "non_ds",
        "models": {
            "supported": list(catalog),
            "catalog": catalog,
            "stats24": {
                model: {"total": 3, "failed": 0, "requests_with_429": 0}
                for model in catalog
            },
        },
        "current_tier": tiers or [],
        "key_group": {"shared_key_with": shared or []},
        "error_pressure": {
            "attribution": "no_error",
            "attribution_unknown": False,
            "requests_with_429": 0,
            "requests_with_5xx": 0,
        },
    }


class AxonhubFreeCardsTest(unittest.TestCase):
    def test_distinct_and_undisclosed_families_get_separate_cards(self):
        channel = free_channel({
            "hy4-flash-free": {
                "canonical_id": "tencent/hy4-flash",
                "family": "hy-flash-free",
                "name": "Hy4 flash Free",
                "description": "Tencent Hy4",
            },
            "hungerg-free": {
                "canonical_id": None,
                "family": None,
                "name": "HungerG Free",
                "description": "Stealth reasoning model, free for a limited time",
            },
        })
        proposals = decide.build_free_card_proposals({"channels": [channel]})
        self.assertEqual(
            [p["card"] for p in proposals],
            ["free-hy4-flash", "free-hungerg-stealth"],
        )
        self.assertEqual(proposals[0]["verifiedFamily"], "tencent/hy4")
        self.assertEqual(proposals[1]["verifiedFamily"], "undisclosed")
        self.assertTrue(all(p["autoApply"] is False for p in proposals))

    def test_same_verified_family_uses_one_card_with_model_names(self):
        channel = free_channel({
            "hy4-flash-free": {"family": "hy-flash"},
            "hy4-pro-free": {"family": "hy-flash"},
        })
        proposals = decide.build_free_card_proposals({"channels": [channel]})
        self.assertEqual(len(proposals), 1)
        self.assertEqual(proposals[0]["card"], "free-hy-flash")
        self.assertEqual(
            proposals[0]["upstreamModels"], ["hy4-flash-free", "hy4-pro-free"]
        )

    def test_non_ds_on_ds_card_is_migrated_not_demoted(self):
        channel = free_channel(
            {"hy4-flash-free": {"canonical_id": "tencent/hy4-flash"}},
            tiers=[{"model": "deepseek-jb", "priority": 0, "disabled": False}],
        )
        profile = {"channels": [channel]}
        doc = {
            "summary": "把 free 降到 p3",
            "changes": [{
                "action": "move_priority", "channel": 51, "model": "deepseek-jb",
                "from": 0, "to": 3, "intent": "x", "evidence": "ds_kind=non_ds",
            }],
        }
        out = decide.fact_check_decision(doc, profile)
        item = out["changes"][0]
        self.assertEqual(item["action"], "migrate_to_free_card")
        self.assertIsNone(item["to"])
        self.assertEqual(item["targetCard"], "free-hy4-flash")
        decide.validate_decision(out)

    def test_rules_are_proposal_only_and_never_emit_write_actions(self):
        channel = free_channel(
            {
                "hy4-flash-free": {"canonical_id": "tencent/hy4-flash"},
                "hungerg-free": {"description": "Stealth reasoning model"},
            },
            tiers=[
                {"model": "deepseek-jb", "priority": 0, "disabled": False},
                {"model": "deepseek-safe", "priority": 3, "disabled": False},
                {"model": "gpt-5.6-luna", "priority": 4, "disabled": False},
                {"model": "gpt-5.6-sol", "priority": 5, "disabled": False},
            ],
            shared=["46"],
        )
        out = decide.rules_decision({"channels": [channel]})
        self.assertFalse(out["autoApply"])
        self.assertEqual(len(out["modelCardProposals"]), 2)
        self.assertTrue(all(
            item["action"] == "migrate_to_free_card" for item in out["changes"]
        ))
        self.assertTrue(all(
            proposal["execution"] == "proposal_only"
            for proposal in out["modelCardProposals"]
        ))
        self.assertEqual(out["modelCardProposals"][0]["quotaIsolation"],
                         "shared_credential_requires_separate_key")
        decide.validate_decision(out)

    def test_attribution_unknown_cancels_error_based_weight_change(self):
        profile = {"channels": [{
            "identity": {"id": "38", "name": "hub-1125"},
            "error_pressure": {
                "attribution": "attribution_unknown",
                "attribution_unknown": True,
            },
        }]}
        doc = {"summary": "38 access_blocked", "changes": [{
            "action": "move_priority", "channel": 38, "intent": "x",
            "evidence": "last_error=403 moxuna", "to": 9,
        }]}
        out = decide.fact_check_decision(doc, profile)
        self.assertEqual(out["changes"][0]["action"], "keep")
        self.assertIsNone(out["changes"][0]["to"])
        self.assertIn("attribution_unknown", out["changes"][0]["evidence"])
        self.assertIn("不参与自动调权", out["summary"])

    def test_validation_rejects_actual_model_write_action(self):
        doc = {"changes": [{
            "action": "createModel", "intent": "x", "evidence": "x",
        }]}
        with self.assertRaises(ValueError):
            decide.validate_decision(doc)


if __name__ == "__main__":
    unittest.main()
