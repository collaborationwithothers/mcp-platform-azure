#!/usr/bin/env python3
"""Bounded-wait consumer for the live gate's per-tool deny audit-event check
(issue 18). Connects to the ephemeral audit Event Hub the log-to-eventhub
policy element writes to, and waits up to --timeout-seconds for a message
matching --tool-name with a non-empty caller field. Always exits 0 and prints
one JSON object to stdout; the caller (discovery-assertions.ps1) reads the
"found" field rather than relying on a process exit code, matching how this
repo's PowerShell gate scripts already treat `az` subprocess stdout as the
source of truth.

Auth: AzureCliCredential (passwordless), reusing the az login the workflow
already performed for Terraform apply -- no connection string or key, per
this repo's hard rule against secrets in the repo.

--since anchors starting_position: the caller passes the wall-clock time
just before it issued the tools/call that should trigger the deny, so this
only reads messages enqueued after that point (never a stale message from an
earlier check or an earlier live-test run against the same ephemeral Event
Hub instance name).
"""

import argparse
import json
import sys
import threading
from datetime import datetime, timezone

from azure.eventhub import EventHubConsumerClient
from azure.identity import AzureCliCredential


def parse_since(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace-fqdn", required=True)
    parser.add_argument("--eventhub-name", required=True)
    parser.add_argument("--tool-name", required=True)
    parser.add_argument("--since", required=True, help="ISO 8601 UTC timestamp; only events enqueued after this are considered.")
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--consumer-group", default="$Default")
    args = parser.parse_args()

    since = parse_since(args.since)
    result = {"found": False, "tool": args.tool_name, "since": args.since}
    found_event = threading.Event()

    client = EventHubConsumerClient(
        fully_qualified_namespace=args.namespace_fqdn,
        eventhub_name=args.eventhub_name,
        consumer_group=args.consumer_group,
        credential=AzureCliCredential(),
    )

    def on_event(partition_context, event):
        if event is None:
            return
        try:
            body = event.body_as_json(encoding="UTF-8")
        except (ValueError, UnicodeDecodeError):
            return
        if body.get("tool") == args.tool_name and body.get("caller"):
            result["found"] = True
            result["caller"] = body["caller"]
            result["enqueued_time"] = event.enqueued_time.isoformat() if event.enqueued_time else None
            found_event.set()

    def on_error(partition_context, error):
        result["error"] = f"{type(error).__name__}: {error}"
        found_event.set()

    def watchdog():
        found_event.wait(timeout=args.timeout_seconds)
        client.close()

    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    watchdog_thread.start()

    try:
        with client:
            client.receive(
                on_event=on_event,
                on_error=on_error,
                starting_position=since,
                starting_position_inclusive=False,
            )
    except Exception as exc:  # noqa: BLE001 - reported in JSON, never a crash for the PowerShell caller
        result.setdefault("error", f"{type(exc).__name__}: {exc}")

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
