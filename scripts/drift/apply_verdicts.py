#!/usr/bin/env python3
"""Turn the judge step's verdicts into GitHub issues, deterministically.

This is step 3 of the semantic doc-drift agent (issue #4). The model never opens
issues; it only writes verdicts to a file. This script owns every side effect and
every safety rail, so a bad model day can produce wrong verdicts but never rogue
public issues:

  - a completeness gate (every work-list key has exactly one verdict, and no
    verdict is for an unknown key) turns a truncated/malformed agent run into a
    red run rather than a silent partial pass;
  - dedup by the stable title `drift-candidate: <key>` means an unresolved
    candidate is not re-opened every week;
  - a hard cap on NEW issues per run bounds the blast radius of a prompt
    regression;
  - `clear` and `not_doc_checkable` verdicts never open anything.

The planning core (`plan_actions`) is pure and unit-tested; only `run` touches
`gh`. See docs/specs/compat-drift-agent.md sections 4.3, 5.2, 6, 7.

Usage:
    python3 scripts/drift/apply_verdicts.py \
        --work-list work-list.json --verdicts verdicts.json [--dry-run] [--cap 5]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

VALID_STATUS = {"fired", "clear", "uncertain", "not_doc_checkable"}
OPEN_STATUS = {"fired", "uncertain"}  # these can open an issue
LABEL_TRIAGE = "needs-triage"
LABEL_FILTER = "drift-candidate"
TITLE_PREFIX = "drift-candidate: "
DEFAULT_CAP = 5


class ApplyError(Exception):
    """Raised for any fail-loud condition (bad input, completeness violation)."""


@dataclass
class Plan:
    to_open: list[dict] = field(default_factory=list)       # will be created (<= cap)
    still_open: list[str] = field(default_factory=list)     # dedup: already open
    suppressed: list[str] = field(default_factory=list)     # over the cap
    clear: list[str] = field(default_factory=list)
    not_doc_checkable: list[tuple[str, str]] = field(default_factory=list)  # (key, reason)
    now_resolvable: list[tuple[str, int, str]] = field(default_factory=list)  # (key, issue#, status)


def _index_by_key(items: list[dict], what: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for item in items:
        key = item.get("key")
        if not key or not isinstance(key, str):
            raise ApplyError(f"{what}: an entry is missing a string 'key': {item!r}")
        if key in out:
            raise ApplyError(f"{what}: duplicate key {key!r}")
        out[key] = item
    return out


def _open_key_to_number(open_issues: list[dict]) -> dict[str, int]:
    """Map a stable key -> open issue number, from titles `drift-candidate: <key>`."""
    out: dict[str, int] = {}
    for issue in open_issues:
        title = issue.get("title", "")
        if title.startswith(TITLE_PREFIX):
            key = title[len(TITLE_PREFIX):].strip()
            if key:
                out[key] = issue.get("number")
    return out


def plan_actions(
    work_list: list[dict],
    verdicts: list[dict],
    open_issues: list[dict],
    cap: int = DEFAULT_CAP,
) -> Plan:
    """Pure planning: decide what to open/skip/suppress without any side effect.

    Enforces the completeness gate first (fail-loud), then partitions verdicts and
    applies dedup + cap in work-list order for deterministic cap behaviour.
    """
    wl_by_key = _index_by_key(work_list, "work-list")
    v_by_key = _index_by_key(verdicts, "verdicts")

    # Completeness gate.
    missing = [k for k in wl_by_key if k not in v_by_key]
    extra = [k for k in v_by_key if k not in wl_by_key]
    if missing:
        raise ApplyError(
            "completeness gate: work-list keys with no verdict (the agent run was "
            f"likely truncated): {', '.join(sorted(missing))}"
        )
    if extra:
        raise ApplyError(
            "completeness gate: verdict keys not present in the work-list: "
            f"{', '.join(sorted(extra))}"
        )

    for key, verdict in v_by_key.items():
        status = verdict.get("status")
        if status not in VALID_STATUS:
            raise ApplyError(
                f"verdict {key!r} has invalid status {status!r}; expected one of "
                f"{sorted(VALID_STATUS)}"
            )

    open_keys = _open_key_to_number(open_issues)
    plan = Plan()

    # Walk in work-list order so the cap is deterministic.
    for key in wl_by_key:
        verdict = v_by_key[key]
        status = verdict["status"]

        if status == "clear":
            plan.clear.append(key)
        elif status == "not_doc_checkable":
            plan.not_doc_checkable.append((key, verdict.get("reason", "")))

        # An open issue whose key now judges clear / not_doc_checkable can be closed.
        if status in ("clear", "not_doc_checkable") and key in open_keys:
            plan.now_resolvable.append((key, open_keys[key], status))

        if status not in OPEN_STATUS:
            continue

        title = TITLE_PREFIX + key
        if key in open_keys:
            plan.still_open.append(key)
            continue

        candidate = {
            "key": key,
            "title": title,
            "work_item": wl_by_key[key],
            "verdict": verdict,
        }
        if len(plan.to_open) < cap:
            plan.to_open.append(candidate)
        else:
            plan.suppressed.append(key)

    return plan


def build_body(work_item: dict, verdict: dict) -> str:
    """Deterministic issue body: structural context from code, prose from the model.

    The banner, metadata, and dedup footer are code-owned so every issue is
    consistently framed as a candidate; the model contributes only the analysis
    prose, which is clearly attributed and explicitly not to be trusted as fact.
    """
    label = work_item.get("label", verdict["key"])
    trigger = work_item.get("trigger_text", "")
    last_verified = work_item.get("last_verified", "") or "unknown"
    learn_url = verdict.get("learn_url", "")
    status = verdict.get("status", "")
    # `or ""` (not just a get default) because the model's JSON is untrusted: a
    # present `"evidence": null` returns None from get(), and None.strip() would
    # crash the apply step mid-run. Coerce null/missing alike to an empty string.
    evidence = (verdict.get("evidence") or "").strip()
    drafted = (verdict.get("drafted_body") or "").strip()

    lines = [
        "> **Candidate, not a confirmed change.** Flagged by the COMPATIBILITY.md "
        "drift agent (issue #4). A human MUST verify against Microsoft Learn "
        "before editing COMPATIBILITY.md. Do not treat the agent's wording as fact.",
        "",
        f"- **Row:** {label}",
        f"- **Key:** `{verdict['key']}`",
        f"- **Recorded last-verified:** {last_verified}",
        f"- **Re-check trigger:** {trigger}",
        f"- **Agent status:** `{status}` (fired = docs look changed; uncertain = "
        "could not resolve either way)",
    ]
    if learn_url:
        lines.append(f"- **Learn page consulted:** {learn_url}")
    lines += ["", "## What the agent found", evidence or "_(none recorded)_"]
    if drafted:
        lines += ["", "## Agent's drafted analysis", drafted]
    lines += [
        "",
        "---",
        f"Dedup handle: this issue's title `{TITLE_PREFIX}{verdict['key']}` is how "
        "the weekly agent knows the candidate is still open; it stays silent while "
        "this is open. Close it once the row is re-verified and its Last-verified "
        "date updated.",
    ]
    return "\n".join(lines)


def render_summary(plan: Plan, cap: int) -> str:
    """Markdown run summary for $GITHUB_STEP_SUMMARY (also printed on --dry-run)."""
    out = ["# COMPATIBILITY.md drift agent - run summary", ""]

    out.append(f"## Opened ({len(plan.to_open)})")
    if plan.to_open:
        for c in plan.to_open:
            out.append(f"- `{c['key']}` ({c['verdict'].get('status')})")
    else:
        out.append("- none")
    out.append("")

    out.append(f"## Still open, left silent ({len(plan.still_open)})")
    out += [f"- `{k}`" for k in plan.still_open] or ["- none"]
    out.append("")

    if plan.suppressed:
        out.append(
            f"## Suppressed by the {cap}-issue cap ({len(plan.suppressed)}) - "
            "inspect these; a spike may mean a prompt regression"
        )
        out += [f"- `{k}`" for k in plan.suppressed]
        out.append("")

    if plan.now_resolvable:
        out.append(f"## You may close ({len(plan.now_resolvable)})")
        out += [
            f"- `{k}` now `{status}` -> #{num}"
            for (k, num, status) in plan.now_resolvable
        ]
        out.append("")

    out.append(f"## Clear ({len(plan.clear)})")
    out += [f"- `{k}`" for k in plan.clear] or ["- none"]
    out.append("")

    out.append(f"## Not doc-checkable ({len(plan.not_doc_checkable)})")
    out += [
        f"- `{k}` - {reason or 'no reason given'}"
        for (k, reason) in plan.not_doc_checkable
    ] or ["- none"]
    out.append("")

    return "\n".join(out)


def _gh_create_issue(title: str, body: str, labels: list[str]) -> str:
    cmd = ["gh", "issue", "create", "--title", title, "--body", body]
    for label in labels:
        cmd += ["--label", label]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise ApplyError(
            f"gh issue create failed for {title!r}: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def _fetch_open_issues() -> list[dict]:
    cmd = [
        "gh", "issue", "list", "--label", LABEL_FILTER, "--state", "open",
        "--json", "number,title", "--limit", "200",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise ApplyError(f"gh issue list failed: {result.stderr.strip()}")
    return json.loads(result.stdout or "[]")


def _load_json(path: str, what: str) -> list[dict]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise ApplyError(f"cannot read {what} {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ApplyError(f"{what} {path} is not valid JSON: {exc}") from exc
    if not isinstance(data, list):
        raise ApplyError(f"{what} {path} must be a JSON array")
    return data


def run(args: argparse.Namespace) -> int:
    work_list = _load_json(args.work_list, "work-list")
    verdicts = _load_json(args.verdicts, "verdicts")

    if args.open_issues:
        open_issues = _load_json(args.open_issues, "open-issues")
    elif args.dry_run:
        open_issues = []
    else:
        open_issues = _fetch_open_issues()

    plan = plan_actions(work_list, verdicts, open_issues, cap=args.cap)

    opened_urls: list[str] = []
    if not args.dry_run:
        for candidate in plan.to_open:
            body = build_body(candidate["work_item"], candidate["verdict"])
            url = _gh_create_issue(
                candidate["title"], body, [LABEL_TRIAGE, LABEL_FILTER]
            )
            opened_urls.append(url)
    else:
        for candidate in plan.to_open:
            print(f"[dry-run] would open: {candidate['title']}")
            print(f"          labels: {LABEL_TRIAGE}, {LABEL_FILTER}")

    summary = render_summary(plan, args.cap)
    if opened_urls:
        summary += "\n## Opened issue URLs\n" + "\n".join(f"- {u}" for u in opened_urls)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as fh:
            fh.write(summary + "\n")
    else:
        print(summary)

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-list", default="work-list.json")
    parser.add_argument("--verdicts", default="verdicts.json")
    parser.add_argument(
        "--open-issues",
        default="",
        help="JSON file of currently-open drift-candidate issues "
        "([{number,title}]). If omitted, fetched via gh (or [] on --dry-run).",
    )
    parser.add_argument("--cap", type=int, default=DEFAULT_CAP)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    try:
        return run(args)
    except ApplyError as exc:
        print(f"apply_verdicts: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
