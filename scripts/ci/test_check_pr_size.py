"""Behavior tests for the pull request size command."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/check-pr-size.py"
POLICY = ROOT / ".github/pr-size-policy.json"
JUSTIFICATION = "Approved exception justification: The slice cannot be split safely."


class PrSizeCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write({"base.txt": 1})
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self):
        self.temp_dir.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, text=True, capture_output=True, check=True
        )

    def write(self, files):
        for name, line_count in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("changed\n" * line_count, encoding="utf-8")

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def check(self, *, base=None, labels=(), body=""):
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--base",
                base or self.base,
                "--head",
                "HEAD",
                "--policy",
                str(POLICY),
                "--labels-json",
                json.dumps(labels),
                "--pr-body",
                body,
            ],
            cwd=self.repo,
            text=True,
            capture_output=True,
        )

    def test_under_both_limits_passes(self):
        self.write({"src/a.txt": 4, "src/b.txt": 5})
        self.commit("under limits")

        result = self.check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr-size: PASS", result.stdout)

    def test_exactly_at_both_limits_passes(self):
        self.write({f"src/{index}.txt": 50 for index in range(10)})
        self.commit("at limits")

        result = self.check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("files: 10 / 10", result.stdout)
        self.assertIn("changed lines: 500 / 500", result.stdout)

    def test_file_limit_exceeded_fails(self):
        self.write({f"src/{index}.txt": 1 for index in range(11)})
        self.commit("too many files")

        result = self.check()

        self.assertEqual(result.returncode, 1)
        self.assertIn("pr-size: FAIL", result.stderr)
        self.assertIn("files: 11 / 10", result.stderr)

    def test_line_limit_exceeded_fails(self):
        self.write({"src/large.txt": 501})
        self.commit("too many lines")

        result = self.check()

        self.assertEqual(result.returncode, 1)
        self.assertIn("changed lines: 501 / 500", result.stderr)

    def test_hari_exception_passes_and_reports_exception(self):
        self.write({"src/large.txt": 501})
        self.commit("approved exception")

        result = self.check(labels=("large-pr-approved",), body=JUSTIFICATION)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr-size: PASS (approved exception)", result.stdout)
        self.assertIn("The slice cannot be split safely.", result.stdout)

    def test_exception_without_justification_fails(self):
        self.write({"src/large.txt": 501})
        self.commit("unjustified exception")

        result = self.check(labels=("large-pr-approved",), body="")

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing a written exception justification", result.stderr)

    def test_new_base_exposes_inherited_parent_files(self):
        self.write({f"parent/{index}.txt": 1 for index in range(10)})
        parent = self.commit("parent")
        self.write({"child/owned.txt": 1})
        self.commit("child")

        child_only = self.check(base=parent)
        inherited = self.check(base=self.base)

        self.assertEqual(child_only.returncode, 0, child_only.stderr)
        self.assertEqual(inherited.returncode, 1)
        self.assertIn("files: 11 / 10", inherited.stderr)

    def test_tests_and_documentation_count_as_files_and_lines(self):
        self.write({"docs/guide.md": 3, "scripts/ci/test_example.py": 4})
        self.commit("docs and tests")

        result = self.check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("files: 2 / 10", result.stdout)
        self.assertIn("changed lines: 7 / 500", result.stdout)
        self.assertIn("docs/guide.md", result.stdout)
        self.assertIn("scripts/ci/test_example.py", result.stdout)

    def test_workflow_rechecks_current_pr_metadata(self):
        workflow = (ROOT / ".github/workflows/pr-size.yml").read_text(encoding="utf-8")

        self.assertIn("edited", workflow)
        self.assertIn("github.event.pull_request.base.sha", workflow)
        self.assertIn("github.event.pull_request.head.sha", workflow)
        self.assertIn("github.event.pull_request.labels", workflow)
        self.assertIn("github.event.pull_request.body", workflow)


if __name__ == "__main__":
    unittest.main()
