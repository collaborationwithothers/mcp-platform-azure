#!/usr/bin/env python3
"""Fail a `dependencies`-labelled PR that bumps a pin without bringing its
COMPATIBILITY.md row along (issue #64).

Dependabot edits only the manifest (.csproj / versions.tf / a module `version`
arg) and leaves the matching COMPATIBILITY.md "Pinned versions" row stale -- the
exact manifest-vs-doc drift that table exists to prevent (AGENTS.md GOVERNANCE >
Truth and verification rules). This guard is the required `compat-sync` status
check that keeps them in lockstep: any PR carrying the `dependencies` label must
also touch COMPATIBILITY.md, or it fails, and the failure message names the pin
row(s) that need a fresh doc link + Last-verified date.

SCOPE. This is the REGISTRY-drift gate (a newer version of a pinned package).
SEMANTIC doc drift under a fixed pin is issue #4's compat-drift agent. See
COMPATIBILITY.md "Registry drift vs documentation drift".

The pass/fail rule is deliberately blanket on the label (not on which files
changed): if a bump is labelled `dependencies`, COMPATIBILITY.md must move with
it. The row mapping below is only for the failure message; it is best-effort and
never changes the verdict.

Dependency-free: Python 3 stdlib only, matching scripts/check-mcp-parity and the
scripts/drift harness. Exit 0 = in sync, 1 = sync violation (fail the PR),
2 = usage/parse error.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

DEPENDENCIES_LABEL = "dependencies"
COMPAT_BASENAME = "COMPATIBILITY.md"
PINNED_HEADING = "## Pinned versions"

# A markdown table separator row, e.g. |---|:--:|-----|.
_SEPARATOR_CHARS = set(" :-|")


@dataclass(frozen=True)
class PinRow:
    """One row of the COMPATIBILITY.md "Pinned versions" table."""

    what: str
    where: str


def _split_row(line: str) -> list[str]:
    """Split a markdown table row into trimmed cell values, dropping the empty
    fragments produced by the outer pipes."""
    parts = [cell.strip() for cell in line.strip().split("|")]
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def _is_separator(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("|") and set(stripped) <= _SEPARATOR_CHARS


def parse_pinned_rows(text: str) -> list[PinRow]:
    """Parse the "Pinned versions" table into rows carrying What (col 0) and
    Where (col 2). Reads from the `## Pinned versions` heading to the next
    `## ` heading. The header row and separator row are skipped; only rows with
    at least three columns are kept."""
    rows: list[PinRow] = []
    in_section = False
    header_seen = False
    for line in text.splitlines():
        if line.startswith("## "):
            if in_section:
                break
            in_section = line.strip() == PINNED_HEADING
            header_seen = False
            continue
        if not in_section:
            continue
        if not line.lstrip().startswith("|"):
            continue
        if _is_separator(line):
            continue
        cells = _split_row(line)
        if not header_seen:
            # First pipe row in the section is the column header.
            header_seen = True
            continue
        if len(cells) >= 3:
            rows.append(PinRow(what=cells[0], where=cells[2]))
    return rows


def is_manifest(path: str) -> bool:
    """Files Dependabot edits and that a pin row can point at."""
    p = path.strip()
    if not p:
        return False
    name = Path(p).name
    if name.endswith(".csproj") or name.endswith(".tf"):
        return True
    if name == "packages.lock.json":
        return True
    if p.startswith(".github/workflows/"):
        return True
    return False


def touches_compat(changed_files: list[str]) -> bool:
    return any(Path(f.strip()).name == COMPAT_BASENAME for f in changed_files if f.strip())


def rows_for_file(path: str, rows: list[PinRow]) -> list[PinRow]:
    """Pin rows whose Where column references this changed file (substring
    match on the repo-relative path)."""
    path = path.strip()
    return [r for r in rows if path and path in r.where]


def build_failure_message(changed_files: list[str], rows: list[PinRow]) -> str:
    manifests = [f.strip() for f in changed_files if is_manifest(f)]
    lines: list[str] = []
    lines.append("compat-sync: FAIL")
    lines.append("")
    lines.append(
        "This PR carries the `dependencies` label but does not update "
        "COMPATIBILITY.md."
    )
    lines.append(
        "A pin bump must land with its COMPATIBILITY.md 'Pinned versions' row "
        "in the SAME PR:"
    )
    lines.append("a fresh doc link and a new 'Last verified' date. See AGENTS.md")
    lines.append("GOVERNANCE > Truth and verification rules.")
    lines.append("")

    if not manifests:
        lines.append(
            "No manifest file (.csproj / .tf / workflow) was detected in the "
            "diff, but the"
        )
        lines.append(
            "`dependencies` label is set. Update COMPATIBILITY.md (or remove the "
            "label if it"
        )
        lines.append("was applied in error).")
        return "\n".join(lines)

    matched_any = False
    lines.append("Pin rows to update (matched by the 'Where' column):")
    for f in manifests:
        matches = rows_for_file(f, rows)
        if matches:
            matched_any = True
            for r in matches:
                lines.append(f"  - {r.what}  [{r.where}]")
        else:
            lines.append(
                f"  - {f}: no matching pin row. Add one, or (for action bumps "
                f"with no pin row)"
            )
            lines.append(
                "    record the bump under COMPATIBILITY.md 'History' with a "
                "verification date."
            )
    if not matched_any:
        lines.append("")
        lines.append(
            "None of the changed manifests matched a 'Pinned versions' row; "
            "if this is a"
        )
        lines.append(
            "genuinely new dependency, add its row now so the table stays "
            "complete."
        )
    return "\n".join(lines)


def evaluate(labels: set[str], changed_files: list[str], rows: list[PinRow]) -> tuple[int, str]:
    """Pure decision core. Returns (exit_code, message).

    0 -> in sync (not a dependencies PR, or COMPATIBILITY.md moved with it)
    1 -> sync violation
    """
    if DEPENDENCIES_LABEL not in labels:
        return 0, "compat-sync: OK (not a `dependencies` PR; nothing to enforce)."
    if touches_compat(changed_files):
        return 0, "compat-sync: OK (`dependencies` PR also updates COMPATIBILITY.md)."
    return 1, build_failure_message(changed_files, rows)


def _read_lines(path: str) -> list[str]:
    if path == "-":
        return sys.stdin.read().splitlines()
    return Path(path).read_text(encoding="utf-8").splitlines()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compat", default="COMPATIBILITY.md", help="Path to COMPATIBILITY.md")
    parser.add_argument(
        "--labels",
        default="",
        help="Comma-separated PR label names (e.g. from github.event.pull_request.labels).",
    )
    parser.add_argument(
        "--changed-files",
        required=True,
        help="File with newline-separated changed paths, or '-' for stdin.",
    )
    args = parser.parse_args(argv)

    labels = {l.strip() for l in args.labels.split(",") if l.strip()}

    try:
        changed_files = _read_lines(args.changed_files)
    except OSError as exc:
        print(f"compat-sync: cannot read changed-files: {exc}", file=sys.stderr)
        return 2

    # Only parse COMPATIBILITY.md when we actually need it (a failing case);
    # a missing file is a real error, not a silent pass.
    rows: list[PinRow] = []
    if DEPENDENCIES_LABEL in labels and not touches_compat(changed_files):
        try:
            rows = parse_pinned_rows(Path(args.compat).read_text(encoding="utf-8"))
        except OSError as exc:
            print(f"compat-sync: cannot read {args.compat}: {exc}", file=sys.stderr)
            return 2

    code, message = evaluate(labels, changed_files, rows)
    stream = sys.stdout if code == 0 else sys.stderr
    print(message, file=stream)
    return code


if __name__ == "__main__":
    sys.exit(main())
