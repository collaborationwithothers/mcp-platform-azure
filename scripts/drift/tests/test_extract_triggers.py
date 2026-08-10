"""Unit tests for extract_triggers.py (stdlib unittest, no third-party deps)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import extract_triggers as et  # noqa: E402


FIXTURE = """\
# COMPATIBILITY

## Pinned versions

| What | Pin | Where | Rationale | Last verified | Doc link |
| --- | --- | --- | --- | --- | --- |
| Widget A | 1.0 | file.tf | Some rationale. Re-check trigger: a newer Widget API ships. | 2026-01-02 | https://learn.microsoft.com/widget |
| Widget B | 2.0 | file.tf | No trigger in this row at all. | 2026-03-04 | https://learn.microsoft.com/widgetb |
| Thing C | 3.0 | file.tf | Cross-ref only. Re-check trigger: ADR-006. | 2026-05-06 | https://learn.microsoft.com/thing |

Some prose paragraph that is not a table.

## Feature status

| Component | Status | Notes | Last verified |
| --- | --- | --- | --- |
| Feature D | GA | Watch this one. Re-check trigger: Microsoft documents X. | 2026-07-08 |
"""


class SlugifyTests(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(et.slugify("Microsoft.ApiCenter/services"), "microsoft-apicenter-services")

    def test_collapses_and_trims(self):
        self.assertEqual(et.slugify("  A -- B  "), "a-b")

    def test_deterministic(self):
        label = "Some.Weird/Label + thing"
        self.assertEqual(et.slugify(label), et.slugify(label))


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.items = et.extract_triggers(FIXTURE)
        self.by_key = {i["key"]: i for i in self.items}

    def test_only_trigger_rows_extracted(self):
        # Widget B has no trigger and must not appear.
        self.assertEqual(len(self.items), 3)
        self.assertNotIn("widget-b", self.by_key)

    def test_keys(self):
        self.assertEqual(set(self.by_key), {"widget-a", "thing-c", "feature-d"})

    def test_trigger_text_captured_from_marker_to_cell_end(self):
        self.assertEqual(self.by_key["widget-a"]["trigger_text"], "a newer Widget API ships.")

    def test_adr_reference_trigger_is_still_extracted(self):
        # extract does not classify; the judge step marks this not_doc_checkable.
        self.assertEqual(self.by_key["thing-c"]["trigger_text"], "ADR-006.")

    def test_last_verified_read_from_correct_column_per_table(self):
        # Pinned table: Last verified is column index 4.
        self.assertEqual(self.by_key["widget-a"]["last_verified"], "2026-01-02")
        self.assertEqual(self.by_key["thing-c"]["last_verified"], "2026-05-06")
        # Feature table: Last verified is column index 3 (different width).
        self.assertEqual(self.by_key["feature-d"]["last_verified"], "2026-07-08")

    def test_doc_links(self):
        self.assertEqual(self.by_key["widget-a"]["doc_links"], ["https://learn.microsoft.com/widget"])

    def test_doc_links_split_markdown_breaks_and_trim_punctuation(self):
        markdown = (
            "| What | Notes | Last verified |\n"
            "| --- | --- | --- |\n"
            "| Widget E | Re-check trigger: docs change. "
            "https://learn.microsoft.com/first<br>"
            "**https://learn.microsoft.com/second**. | 2026-07-09 |\n"
        )

        items = et.extract_triggers(markdown)

        self.assertEqual(
            items[0]["doc_links"],
            [
                "https://learn.microsoft.com/first",
                "https://learn.microsoft.com/second",
            ],
        )

    def test_recorded_claim_is_the_trigger_cell(self):
        self.assertIn("Some rationale", self.by_key["widget-a"]["recorded_claim"])
        self.assertIn("Re-check trigger", self.by_key["widget-a"]["recorded_claim"])

    def test_file_order_preserved(self):
        self.assertEqual([i["key"] for i in self.items], ["widget-a", "thing-c", "feature-d"])

    def test_deterministic_output(self):
        again = et.extract_triggers(FIXTURE)
        self.assertEqual(self.items, again)


class CollisionTests(unittest.TestCase):
    def test_two_rows_same_key_is_hard_error(self):
        # Two trigger rows whose first cell slugifies identically must not be
        # silently merged; dedup depends on keys being unique.
        dup = (
            "| What | Pin | Last verified |\n"
            "| --- | --- | --- |\n"
            "| Dup Row | 1 | 2026-01-01 | Re-check trigger: a. |\n"
            "| Dup Row | 2 | 2026-02-02 | Re-check trigger: b. |\n"
        )
        with self.assertRaises(ValueError):
            et.extract_triggers(dup)

    def test_trigger_row_with_empty_first_cell_is_hard_error(self):
        md = (
            "| What | Pin |\n"
            "| --- | --- |\n"
            "|  | 1 | Re-check trigger: something. |\n"
        )
        with self.assertRaises(ValueError):
            et.extract_triggers(md)


if __name__ == "__main__":
    unittest.main()
