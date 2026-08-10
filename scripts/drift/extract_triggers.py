#!/usr/bin/env python3
"""Extract the ``Re-check trigger:`` rows from COMPATIBILITY.md into a work-list.

This is step 1 of the semantic doc-drift agent (issue #4). It is deterministic
and dependency-free (Python 3 stdlib only, matching scripts/check-mcp-parity):
the same COMPATIBILITY.md yields byte-identical output every run, so the agent's
judgement step and dedup are stable.

It does NOT judge anything and does NOT talk to any network. It only finds the
rows a human already flagged for re-verification (the ``Re-check trigger:`` notes
authored into COMPATIBILITY.md) and emits, per row, the identifying key, the
trigger condition, the claim context, any doc links, and the recorded
last-verified date. The classification of whether a trigger is even checkable
against Microsoft Learn is left to the judge step (see scripts/drift/prompt.md);
this step includes every trigger row so nothing is silently dropped.

Output contract: see docs/specs/compat-drift-agent.md section 5.1.

Usage:
    python3 scripts/drift/extract_triggers.py [COMPATIBILITY.md] [--out work-list.json]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TRIGGER_MARKER = "Re-check trigger:"
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
# Markdown delimiters end a URL token even when no whitespace separates them.
# This keeps two links joined with ``<br>`` as two work-list entries instead of
# passing one merged value to the weekly judge.
URL_RE = re.compile(r"https?://[^\s|)\]<>*`\"']+")
TRAILING_URL_PUNCTUATION = ".,;:"
# A markdown table separator row, e.g. |---|:--:|-----| (only dashes, colons,
# pipes and spaces between the outer pipes).
SEPARATOR_RE = re.compile(r"^\|[\s:|-]+\|\s*$")


def split_row(line: str) -> list[str]:
    """Split a markdown table row into its trimmed cell values.

    ``| a | b | c |`` -> ``['a', 'b', 'c']``. Leading/trailing empty fragments
    produced by the outer pipes are dropped.
    """
    parts = [cell.strip() for cell in line.strip().split("|")]
    # Drop the empty fragments before the first pipe and after the last pipe.
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def slugify(label: str) -> str:
    """Deterministic slug used as the row's stable key and issue-title handle.

    Lowercase; every run of non-alphanumeric characters becomes a single ``-``;
    leading/trailing dashes trimmed. Stability across runs is what makes dedup
    work, so this must never change behaviour for an unchanged label.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
    return slug


def is_table_row(line: str) -> bool:
    return line.strip().startswith("|")


def extract_triggers(markdown_text: str) -> list[dict]:
    """Return the work-list for every ``Re-check trigger:`` row, in file order.

    Tracks the current table header so ``last_verified`` is read from the row's
    real "Last verified" column rather than guessed from prose dates (the Notes
    cells contain many dates). A header is a table row immediately followed by a
    separator row.
    """
    lines = markdown_text.splitlines()
    header_cells: list[str] = []
    last_verified_idx: int | None = None

    items: list[dict] = []
    seen_keys: dict[str, str] = {}
    collisions: list[str] = []

    for i, line in enumerate(lines):
        if not is_table_row(line):
            # Left the table; forget the header so a later prose "| " never
            # reuses a stale column map.
            header_cells = []
            last_verified_idx = None
            continue

        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if SEPARATOR_RE.match(nxt):
            # This is a header row: record its column map.
            header_cells = split_row(line)
            last_verified_idx = None
            for idx, name in enumerate(header_cells):
                if name.strip().lower() == "last verified":
                    last_verified_idx = idx
                    break
            continue

        if SEPARATOR_RE.match(line):
            continue

        if TRIGGER_MARKER.lower() not in line.lower():
            continue

        cells = split_row(line)
        if not cells or not cells[0]:
            # A trigger row we cannot key is a hard error, not a silent skip.
            collisions.append(
                f"row on line {i + 1} contains a Re-check trigger but has no "
                f"identifying first cell"
            )
            continue

        label = cells[0]
        key = slugify(label)
        if not key:
            collisions.append(
                f"row on line {i + 1} label {label!r} slugified to an empty key"
            )
            continue
        if key in seen_keys:
            collisions.append(
                f"key {key!r} produced by two rows: {seen_keys[key]!r} and "
                f"{label!r}"
            )
            continue
        seen_keys[key] = label

        # The cell that carries the trigger marker is the claim context.
        claim_cell = ""
        trigger_text = ""
        for cell in cells:
            pos = cell.lower().find(TRIGGER_MARKER.lower())
            if pos != -1:
                claim_cell = cell
                trigger_text = cell[pos + len(TRIGGER_MARKER):].strip()
                break

        doc_links: list[str] = []
        for candidate in URL_RE.findall(line):
            url = candidate.rstrip(TRAILING_URL_PUNCTUATION)
            if url not in doc_links:
                doc_links.append(url)

        last_verified = ""
        if last_verified_idx is not None and last_verified_idx < len(cells):
            m = DATE_RE.search(cells[last_verified_idx])
            if m:
                last_verified = m.group(1)

        items.append(
            {
                "key": key,
                "label": label,
                "trigger_text": trigger_text,
                "recorded_claim": claim_cell,
                "doc_links": doc_links,
                "last_verified": last_verified,
            }
        )

    if collisions:
        raise ValueError(
            "extract_triggers: cannot produce a stable work-list:\n  - "
            + "\n  - ".join(collisions)
        )

    return items


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        default="COMPATIBILITY.md",
        help="Path to COMPATIBILITY.md (default: %(default)s).",
    )
    parser.add_argument(
        "--out",
        default="-",
        help="Write the work-list JSON here (default: stdout).",
    )
    args = parser.parse_args(argv)

    try:
        text = Path(args.path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"extract_triggers: cannot read {args.path}: {exc}", file=sys.stderr)
        return 1

    try:
        items = extract_triggers(text)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    payload = json.dumps(items, indent=2, ensure_ascii=False) + "\n"
    if args.out == "-":
        sys.stdout.write(payload)
    else:
        Path(args.out).write_text(payload, encoding="utf-8")
        print(
            f"extract_triggers: wrote {len(items)} trigger rows to {args.out}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
