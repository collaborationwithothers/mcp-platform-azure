"""Unit tests for check_compat_sync.py (stdlib unittest, no third-party deps)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_compat_sync as cs  # noqa: E402


FIXTURE = """\
# COMPATIBILITY

## Feature status

| Component | Status | Notes | Last verified |
| --- | --- | --- | --- |
| Some feature | GA | not a pin | 2026-07-08 |

## Pinned versions

| What | Pin | Where | Rationale | Last verified | Doc link |
| --- | --- | --- | --- | --- | --- |
| azurerm provider | ~> 4.80 | infra/terraform/modules/mcp-function-host/versions.tf | pin | 2026-07-11 | https://x |
| ModelContextProtocol | 1.4.1 | src/McpTestClient/McpTestClient.csproj | pin | 2026-07-12 | https://y |
| Worker | 2.52.0 | src/McpTools/McpTools.csproj | pin | 2026-07-12 | https://z |

## History

Not a pinned-versions row.

| What | Pin | Where | x | y | z |
| --- | --- | --- | --- | --- | --- |
| Should not | be | parsed-from-history.tf | a | b | c |
"""


class ParsePinnedRows(unittest.TestCase):
    def test_extracts_only_pinned_section(self):
        rows = cs.parse_pinned_rows(FIXTURE)
        wheres = {r.where for r in rows}
        self.assertIn("src/McpTools/McpTools.csproj", wheres)
        self.assertIn("infra/terraform/modules/mcp-function-host/versions.tf", wheres)
        # Rows from Feature status and History must not leak in.
        self.assertNotIn("parsed-from-history.tf", wheres)
        self.assertEqual(len(rows), 3)

    def test_what_and_where_columns(self):
        rows = cs.parse_pinned_rows(FIXTURE)
        by_where = {r.where: r.what for r in rows}
        self.assertEqual(by_where["src/McpTools/McpTools.csproj"], "Worker")


class IsManifest(unittest.TestCase):
    def test_true_cases(self):
        for p in (
            "src/McpTools/McpTools.csproj",
            "infra/terraform/modules/foo/versions.tf",
            ".github/workflows/ci.yml",
            "src/McpTools/packages.lock.json",
        ):
            self.assertTrue(cs.is_manifest(p), p)

    def test_false_cases(self):
        for p in ("COMPATIBILITY.md", "README.md", "docs/foo.md", ""):
            self.assertFalse(cs.is_manifest(p), p)


class TouchesCompat(unittest.TestCase):
    def test_detects_root_file(self):
        self.assertTrue(cs.touches_compat(["COMPATIBILITY.md", "src/x.csproj"]))

    def test_absent(self):
        self.assertFalse(cs.touches_compat(["src/x.csproj", "README.md"]))


class RowsForFile(unittest.TestCase):
    def setUp(self):
        self.rows = cs.parse_pinned_rows(FIXTURE)

    def test_matches_by_where(self):
        matched = cs.rows_for_file("src/McpTools/McpTools.csproj", self.rows)
        self.assertEqual([r.what for r in matched], ["Worker"])

    def test_no_match(self):
        self.assertEqual(cs.rows_for_file(".github/workflows/ci.yml", self.rows), [])


class Evaluate(unittest.TestCase):
    def setUp(self):
        self.rows = cs.parse_pinned_rows(FIXTURE)

    def test_not_a_dependencies_pr_passes(self):
        code, msg = cs.evaluate(set(), ["src/McpTools/McpTools.csproj"], self.rows)
        self.assertEqual(code, 0)
        self.assertIn("not a `dependencies` PR", msg)

    def test_other_labels_only_passes(self):
        code, _ = cs.evaluate({"bug", "infra"}, ["src/McpTools/McpTools.csproj"], self.rows)
        self.assertEqual(code, 0)

    def test_dependencies_with_compat_passes(self):
        code, msg = cs.evaluate(
            {"dependencies"},
            ["src/McpTools/McpTools.csproj", "COMPATIBILITY.md"],
            self.rows,
        )
        self.assertEqual(code, 0)
        self.assertIn("also updates COMPATIBILITY.md", msg)

    def test_dependencies_without_compat_fails_and_names_row(self):
        code, msg = cs.evaluate(
            {"dependencies"}, ["src/McpTools/McpTools.csproj"], self.rows
        )
        self.assertEqual(code, 1)
        self.assertIn("FAIL", msg)
        self.assertIn("Worker", msg)
        self.assertIn("src/McpTools/McpTools.csproj", msg)

    def test_dependencies_workflow_bump_without_row_still_fails_with_history_hint(self):
        code, msg = cs.evaluate(
            {"dependencies"}, [".github/workflows/ci.yml"], self.rows
        )
        self.assertEqual(code, 1)
        self.assertIn("no matching pin row", msg)
        self.assertIn("History", msg)

    def test_dependencies_no_manifest_fails(self):
        code, msg = cs.evaluate({"dependencies"}, ["README.md"], self.rows)
        self.assertEqual(code, 1)
        self.assertIn("No manifest file", msg)


if __name__ == "__main__":
    unittest.main()
