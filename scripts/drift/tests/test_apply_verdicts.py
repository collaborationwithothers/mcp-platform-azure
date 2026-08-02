"""Unit tests for apply_verdicts.py planning core (stdlib unittest)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import apply_verdicts as av  # noqa: E402


def wl(*keys):
    """Minimal work-list items in a fixed order."""
    return [
        {
            "key": k,
            "label": f"Label {k}",
            "trigger_text": f"trigger for {k}",
            "last_verified": "2026-01-01",
            "doc_links": [],
            "recorded_claim": "claim",
        }
        for k in keys
    ]


def verdict(key, status, **extra):
    v = {"key": key, "status": status}
    v.update(extra)
    return v


class CompletenessGateTests(unittest.TestCase):
    def test_missing_verdict_fails(self):
        with self.assertRaises(av.ApplyError):
            av.plan_actions(wl("a", "b"), [verdict("a", "clear")], [])

    def test_extra_verdict_fails(self):
        with self.assertRaises(av.ApplyError):
            av.plan_actions(wl("a"), [verdict("a", "clear"), verdict("z", "fired")], [])

    def test_invalid_status_fails(self):
        with self.assertRaises(av.ApplyError):
            av.plan_actions(wl("a"), [verdict("a", "maybe")], [])

    def test_duplicate_verdict_key_fails(self):
        with self.assertRaises(av.ApplyError):
            av.plan_actions(wl("a"), [verdict("a", "fired"), verdict("a", "clear")], [])


class PartitionTests(unittest.TestCase):
    def test_fired_and_uncertain_open_clear_and_ndc_do_not(self):
        work = wl("f", "u", "c", "n")
        verdicts = [
            verdict("f", "fired"),
            verdict("u", "uncertain"),
            verdict("c", "clear"),
            verdict("n", "not_doc_checkable", reason="ADR reference"),
        ]
        plan = av.plan_actions(work, verdicts, [])
        self.assertEqual({c["key"] for c in plan.to_open}, {"f", "u"})
        self.assertEqual(plan.clear, ["c"])
        self.assertEqual(plan.not_doc_checkable, [("n", "ADR reference")])

    def test_dedup_still_open_not_reopened(self):
        work = wl("f")
        plan = av.plan_actions(
            work,
            [verdict("f", "fired")],
            [{"number": 42, "title": "drift-candidate: f"}],
        )
        self.assertEqual(plan.to_open, [])
        self.assertEqual(plan.still_open, ["f"])

    def test_now_resolvable_when_open_key_now_clear(self):
        work = wl("c")
        plan = av.plan_actions(
            work,
            [verdict("c", "clear")],
            [{"number": 7, "title": "drift-candidate: c"}],
        )
        self.assertEqual(plan.now_resolvable, [("c", 7, "clear")])


class CapTests(unittest.TestCase):
    def test_cap_is_deterministic_in_worklist_order(self):
        keys = ["k1", "k2", "k3", "k4", "k5", "k6"]
        work = wl(*keys)
        verdicts = [verdict(k, "fired") for k in keys]
        plan = av.plan_actions(work, verdicts, [], cap=5)
        self.assertEqual([c["key"] for c in plan.to_open], ["k1", "k2", "k3", "k4", "k5"])
        self.assertEqual(plan.suppressed, ["k6"])


class RenderAndBodyTests(unittest.TestCase):
    def test_summary_has_all_sections(self):
        work = wl("f", "c", "n")
        verdicts = [
            verdict("f", "fired"),
            verdict("c", "clear"),
            verdict("n", "not_doc_checkable", reason="internal event"),
        ]
        plan = av.plan_actions(work, verdicts, [])
        summary = av.render_summary(plan, cap=5)
        for heading in ["Opened", "Still open", "Clear", "Not doc-checkable"]:
            self.assertIn(heading, summary)
        self.assertIn("internal event", summary)

    def test_body_is_candidate_framed_and_carries_context(self):
        item = wl("f")[0]
        v = verdict("f", "fired", evidence="doc now says Y", learn_url="https://learn/x",
                    drafted_body="analysis prose")
        body = av.build_body(item, v)
        self.assertIn("Candidate, not a confirmed change", body)
        self.assertIn("`f`", body)
        self.assertIn("trigger for f", body)
        self.assertIn("doc now says Y", body)
        self.assertIn("analysis prose", body)
        self.assertIn("https://learn/x", body)


if __name__ == "__main__":
    unittest.main()
