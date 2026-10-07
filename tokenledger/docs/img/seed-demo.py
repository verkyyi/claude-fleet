#!/usr/bin/env python3
"""Synthesise usage batches and push them through the hub's real /v1/ingest.

Every identifier here is invented. See seed-demo.sh for why that is not
negotiable: the dashboard carries emails, client names and machine names, and
none of it may reach a public image.

Costs are deliberately NOT sent. The hub prices events against its own table
("Price on the hub, not the agent"), so leaving cost_usd unset exercises the
real pricing path instead of asserting numbers this script made up.
"""

import json
import os
import random
import urllib.request
from datetime import datetime, timedelta, timezone

HUB = os.environ["HUB"]
# 30, to fill the dashboard's default 30-day span. At 14 the timeline showed a
# blank left half, which reads as "the tool lost my data" rather than "the demo
# is short".
DAYS = 30
random.seed(20260914)  # same picture every run

now = datetime.now(timezone.utc)
created = now - timedelta(days=400)


def iso(t):
    return t.replace(microsecond=0).isoformat().replace("+00:00", "Z")


# Two subscriptions, three machines. The account a machine reports under is a
# property of who is logged in there, not of the machine.
ACCOUNTS = {
    "ada": {
        "source": "claude",
        "account_uuid": "acc-demo-ada",
        "email": "ada@example.com",
        "org_name": "Example Co",
        "subscription_type": "max",
        "rate_limit_tier": "default_claude_max_20x",
        "display_name": "Ada · Max 20x",
        "account_created_at": iso(created),
    },
    "ben": {
        "source": "claude",
        "account_uuid": "acc-demo-ben",
        "email": "ben@example.com",
        "org_name": "Example Co",
        "subscription_type": "max",
        "rate_limit_tier": "default_claude_max_5x",
        "display_name": "Ben · Max 5x",
        "account_created_at": iso(created),
    },
}

ENDPOINTS = {
    "mac-mini": {
        "token": os.environ["MAC_TOKEN"],
        "machine_id": "demo-machine-mac-mini",
        "hostname": "mac-mini",
        "os": "darwin",
        "arch": "arm64",
        "os_user": "ada",
        "who": "ada",
    },
    "web-01": {
        "token": os.environ["WEB_TOKEN"],
        "machine_id": "demo-machine-web-01",
        "hostname": "web-01",
        "os": "linux",
        "arch": "amd64",
        "os_user": "deploy",
        "who": "ben",
    },
    "laptop-ada": {
        "token": os.environ["LAP_TOKEN"],
        "machine_id": "demo-machine-laptop",
        "hostname": "laptop-ada",
        "os": "darwin",
        "arch": "arm64",
        "os_user": "ada",
        "who": "ada",
    },
}

# Invented repos. acme-app matches claude-fleet's demo data on purpose.
PROJECTS = [
    ("~/projects/acme-app", ["main", "feat/checkout-v2", "fix/flaky-e2e"]),
    ("~/projects/acme-api", ["main", "feat/rate-limits"]),
    ("~/projects/docs-site", ["main"]),
]

# Weighted so the mix looks like real work: a lot of Sonnet, real but smaller
# Opus, a tail of Haiku. Every id is in the hub's pricing table.
MODELS = (
    ["claude-sonnet-5"] * 11
    + ["claude-opus-5"] * 6
    + ["claude-haiku-4-5-20251001"] * 3
    + ["claude-fable-5"] * 2
)


def turn(ep, key, ts, n):
    """One assistant turn, with a cache-heavy shape typical of agentic work."""
    model = random.choice(MODELS)
    big = model in ("claude-opus-5", "claude-fable-5")
    return {
        "source": "claude",
        "account_uuid": ACCOUNTS[ep["who"]]["account_uuid"],
        "session_id": f"demo-sess-{key}",
        "message_uuid": f"demo-msg-{key}-{n}",
        "ts": iso(ts),
        "model": model,
        "input_tokens": random.randint(900, 4200),
        "output_tokens": random.randint(320, 2600 if big else 1400),
        "cache_create_5m_tokens": random.choice([0, 0, random.randint(1200, 26000)]),
        "cache_read_tokens": random.randint(18000, 340000),
        "thinking_tokens": random.randint(0, 900) if big else 0,
        "cwd": ep["cwd"],
        "git_branch": ep["branch"],
        "os_user": ep["os_user"],
        "entrypoint": "cli",
        "is_sidechain": random.random() < 0.22,  # subagent turns
    }


def push(ep_name, ep, events):
    acct = ACCOUNTS[ep["who"]]
    batch = {
        "agent_version": "demo",
        "identity": {
            **acct,
            "machine_id": ep["machine_id"],
            "hostname": ep["hostname"],
            "os": ep["os"],
            "arch": ep["arch"],
            "cc_version": "2.0.0",
        },
        "events": events,
    }
    req = urllib.request.Request(
        f"{HUB}/v1/ingest",
        data=json.dumps(batch).encode(),
        headers={
            "Authorization": f"Bearer {ep['token']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.loads(r.read())
    print(f"   {ep_name}: {len(events)} events -> {body.get('accepted', body)}")


total = 0
for name, base in ENDPOINTS.items():
    events = []
    for day in range(DAYS):
        # Weekends are quieter; mac-mini runs the always-on fleet so it never
        # really stops.
        d = now - timedelta(days=DAYS - 1 - day)
        weekend = d.weekday() >= 5
        sessions = random.randint(1, 2) if weekend else random.randint(2, 5)
        if name == "mac-mini":
            sessions += 2
        for s in range(sessions):
            cwd, branches = random.choice(PROJECTS)
            ep = {**base, "cwd": cwd, "branch": random.choice(branches)}
            start = d.replace(hour=random.randint(9, 21), minute=random.randint(0, 59))
            key = f"{name}-{day}-{s}"
            for n in range(random.randint(6, 40)):
                events.append(turn(ep, key, start + timedelta(minutes=2 * n), n))
    push(name, base, events)
    total += len(events)

print(f"   total {total} events across {len(ENDPOINTS)} endpoints, {DAYS} days")

