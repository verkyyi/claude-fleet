#!/bin/sh
# fleet-pending-tool.sh <transcript.jsonl> — WHICH tool is this session blocked on?
#
# Prints the NAME of the newest `tool_use` in the transcript that has no
# `tool_result` yet, and exits 0. Nothing pending (or no readable transcript) ⇒ no
# output, exit 1.
#
# WHY IT IS ITS OWN FILE (issue #656). "tool_use without tool_result" is the fleet's
# ONE hard judgement about what a red window is waiting on, and three callers need
# it: bin/fleet-answer.sh (the pending gate — is there an AskUserQuestion to answer?),
# bin/fleet-permission.sh (the same gate, inverted — an AskUserQuestion is NOT ours)
# and, since #656, bin/set-claude-state.sh, which stamps @claude_needs.
#
# The state hook used to decide from the Notification's WORDING instead, and on
# 2026-09-14 that put `perm` on a window holding a plain AskUserQuestion: measured on
# Claude Code 2.1.272, an open AskUserQuestion fires
#
#     {"hook_event_name":"Notification","message":"Claude needs your permission",
#      "notification_type":"permission_prompt", …}
#
# — the very same payload a real permission prompt sends. Wording cannot tell them
# apart, so nothing built on wording ever could. The dash then showed `⊘` ("go press
# it yourself") for a question the operator could have answered from the dash with
# ⌃k, which is exactly the value #640 was meant to add. The transcript is the only
# source that knows, and the two tools that act on the answer already trusted it —
# this file is that judgement, extracted so the stamp cannot drift from the tools.
#
# `sh`-wired on purpose: its first caller is a `sh` hook on the Notification path.
# Fail-safe by construction — any failure (no python3, unreadable transcript,
# malformed JSON) is silence + exit 1, which leaves every caller on the behaviour it
# had before it asked.
set -u
T="${1:-}"
[ -n "$T" ] || { printf 'usage: fleet-pending-tool.sh <transcript.jsonl>\n' >&2; exit 2; }
[ -f "$T" ] || exit 1
command -v python3 >/dev/null 2>&1 || exit 1

FPT_T="$T" python3 - <<'PY' 2>/dev/null
import json, os, sys

# Identical rule to bin/fleet-answer.sh and bin/fleet-permission.sh: walk the whole
# transcript, remember every tool_use in order and every id that got a result, and
# take the newest id still without one.
uses, done, order = {}, set(), []
try:
    with open(os.environ["FPT_T"], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"tool_use"' not in line and "tool_result" not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            content = m.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    uses[c.get("id")] = c.get("name") or "?"
                    order.append(c.get("id"))
                elif c.get("type") == "tool_result":
                    done.add(c.get("tool_use_id"))
except OSError:
    sys.exit(1)

tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
if tuid is None:
    sys.exit(1)
print(uses[tuid])
PY
