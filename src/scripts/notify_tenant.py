#!/usr/bin/env python3
"""
notify_tenant.py — Post a Slack notification for a tenant lifecycle event.

Usage:
    python notify_tenant.py --tenant-id <id> --event <event> [--namespace <ns>]

Events:
    onboard-complete    Tenant namespace provisioned and ArgoCD synced
    offboard-complete   Tenant namespace and resources removed
    onboard-failed      Tenant onboarding failed
    offboard-failed     Tenant offboarding failed
"""

import argparse
import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError

EVENTS = {
    "onboard-complete": {
        "color": "good",
        "icon": ":white_check_mark:",
        "title": "Tenant onboarded",
        "text": "Tenant *{tenant_id}* has been onboarded. Namespace `{namespace}` is ready.",
    },
    "offboard-complete": {
        "color": "good",
        "icon": ":recycle:",
        "title": "Tenant offboarded",
        "text": "Tenant *{tenant_id}* has been offboarded. Namespace `{namespace}` removed.",
    },
    "onboard-failed": {
        "color": "danger",
        "icon": ":x:",
        "title": "Tenant onboarding failed",
        "text": "Onboarding failed for tenant *{tenant_id}*. Check the workflow run for details.",
    },
    "offboard-failed": {
        "color": "danger",
        "icon": ":x:",
        "title": "Tenant offboarding failed",
        "text": "Offboarding failed for tenant *{tenant_id}*. Manual cleanup may be required.",
    },
}


def post_slack(webhook_url: str, color: str, title: str, text: str) -> None:
    payload = {
        "attachments": [
            {
                "color": color,
                "title": title,
                "text": text,
                "mrkdwn_in": ["text"],
            }
        ]
    }
    data = json.dumps(payload).encode("utf-8")
    req = Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                print(f"WARNING: Slack returned HTTP {resp.status}", file=sys.stderr)
    except URLError as e:
        print(f"ERROR: Failed to post to Slack: {e}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="Post tenant lifecycle event to Slack")
    parser.add_argument("--tenant-id", required=True)
    parser.add_argument(
        "--event",
        required=True,
        choices=list(EVENTS.keys()),
        help="Lifecycle event type",
    )
    parser.add_argument("--namespace", help="Kubernetes namespace (defaults to tenant-id)")
    args = parser.parse_args()

    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook_url:
        print("ERROR: SLACK_WEBHOOK_URL environment variable is not set", file=sys.stderr)
        sys.exit(1)

    namespace = args.namespace or args.tenant_id
    event = EVENTS[args.event]

    title = f"{event['icon']} {event['title']}"
    text = event["text"].format(tenant_id=args.tenant_id, namespace=namespace)

    print(f"Posting '{args.event}' notification for tenant '{args.tenant_id}'")
    post_slack(webhook_url, event["color"], title, text)
    print("Done.")


if __name__ == "__main__":
    main()
