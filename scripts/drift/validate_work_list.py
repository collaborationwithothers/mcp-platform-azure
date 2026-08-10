#!/usr/bin/env python3
"""Validate the structural health of a drift-agent work-list JSON file.

The weekly drift agent starts from each item's ``doc_links``. A malformed link
there makes the judge's evidence unreliable before it can decide whether the
underlying documentation has drifted. This checker validates only the
extractor's output. It does not fetch a URL or judge a documented claim.

Usage:
    python3 scripts/drift/validate_work_list.py work-list.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

VALID_SCHEMES = {"http", "https"}
FORBIDDEN_URL_CHARACTERS = set("<>*`\"'\\{}")
INVALID_PERCENT_ESCAPE_RE = re.compile(r"%(?![0-9A-Fa-f]{2})")


class WorkListValidationError(ValueError):
    """Raised when the extractor output cannot safely guide the weekly judge."""


def url_error(url: str) -> str | None:
    """Return a structural error for one extracted URL, if it has one."""
    if not url:
        return "is empty"
    if any(character.isspace() for character in url):
        return "contains whitespace"
    if any(character in FORBIDDEN_URL_CHARACTERS for character in url):
        return "contains an unencoded delimiter character"
    if INVALID_PERCENT_ESCAPE_RE.search(url):
        return "contains an invalid percent escape"
    if url.count("://") != 1:
        return "contains more than one URL scheme"

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as exc:
        return f"is not a parseable URL ({exc})"

    if parsed.scheme not in VALID_SCHEMES:
        return "does not use http or https"
    if not parsed.netloc or not parsed.hostname:
        return "does not have a host"
    if port is not None and not 0 < port < 65536:
        return "has a port outside the valid range"

    return None


def item_label(item: dict, index: int) -> str:
    """Return a stable error label without trusting a malformed key value."""
    key = item.get("key")
    if isinstance(key, str) and key:
        return key
    return f"item {index + 1}"


def validate_work_list(work_list: object) -> None:
    """Raise ``WorkListValidationError`` when a work-list has unsafe doc links."""
    if not isinstance(work_list, list):
        raise WorkListValidationError("work-list must be a JSON array")

    errors: list[str] = []
    for item_index, item in enumerate(work_list):
        if not isinstance(item, dict):
            errors.append(f"item {item_index + 1} must be a JSON object")
            continue

        label = item_label(item, item_index)
        doc_links = item.get("doc_links")
        if not isinstance(doc_links, list):
            errors.append(f"{label}: doc_links must be a JSON array")
            continue

        for link_index, url in enumerate(doc_links):
            if not isinstance(url, str):
                errors.append(f"{label}: doc_links[{link_index}] must be a string")
                continue

            error = url_error(url)
            if error:
                errors.append(f"{label}: doc_links[{link_index}] {error}: {url!r}")

    if errors:
        raise WorkListValidationError(
            "validate_work_list: malformed extractor output:\n  - "
            + "\n  - ".join(errors)
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="Path to the extractor work-list JSON file")
    args = parser.parse_args(argv)

    try:
        work_list = json.loads(Path(args.path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"validate_work_list: cannot read {args.path}: {exc}", file=sys.stderr)
        return 1

    try:
        validate_work_list(work_list)
    except WorkListValidationError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print("validate_work_list: work-list doc_links are structurally valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
