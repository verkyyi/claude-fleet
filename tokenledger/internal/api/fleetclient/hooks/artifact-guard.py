#!/usr/bin/env python3
"""
artifact-guard.py — PreToolUse hook: a fleet session never PUBLISHES an Artifact.

WHY (issue #526): an Artifact page is scoped to the claude.ai ACCOUNT that
published it. The fleet rotates subscription tokens under sessions
(#513/#515/#524), so the operator cannot tell which account a given session
used — and from the wrong login the page simply is not there. The fleet ships
the `doc-preview` skill instead: one fixed Tailscale tailnet URL, any device, no
login, every session's shares in one list. This guard turns a publish into a
pointer at that, and leaves reading / listing / commenting on artifacts that
OTHERS shared alone (those are viewing, not hosting).

Wired from hooks/settings-hooks.json with matcher "Artifact"; installed
machine-wide into ~/.claude/settings.json by /fleet-sync-install, so it covers
the hub, scratch sessions and workers on every fleet. Claude Code re-reads hooks
per turn — live sessions pick it up without a restart.

Contract (same as the sibling guards):
  - stdin: JSON {tool_name, tool_input:{action?, file_path?, url?, ...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK; stderr is shown to the model (it says what to do instead)
  - any error / non-Artifact tool -> exit 0 (fail OPEN — a guard bug must never
    brick a session)
  - FLEET_ALLOW_ARTIFACT=1 in the environment -> allow (the operator's escape
    hatch for a session that genuinely needs Artifact-only features: comment
    threads, a shared db, the claude.ai gallery)

A publish is: action absent (the tool's default), or action == "publish". Every
other action (read, list, comments, reply, resolve, status, watch, unwatch,
read_db, write_db, upload_asset, ...) is allowed as given.
"""
import json
import os
import sys

MSG = (
    "⛔ BLOCKED by ~/.claude/fleet/hooks/artifact-guard.py: fleet sessions do not\n"
    "publish Artifacts.\n"
    "  An Artifact page belongs to the claude.ai ACCOUNT that published it. The fleet\n"
    "  rotates subscription accounts under sessions, so the operator cannot know which\n"
    "  login would show this page — from any other account it does not exist.\n"
    "  Host it on the fleet's tailnet instead (any device, no login, all sessions in\n"
    "  one list):\n"
    "    ~/.claude/skills/doc-preview/share.sh <file.md|file.html>\n"
    "  then relay the READY URL it prints. Markdown is rendered GitHub-style; an\n"
    "  .html file is served as-is. Reading / listing / commenting on artifacts others\n"
    "  shared is still allowed. Operator override: FLEET_ALLOW_ARTIFACT=1.\n"
)


def allow():
    sys.exit(0)


def block():
    sys.stderr.write(MSG)
    sys.exit(2)


def main():
    if os.environ.get("FLEET_ALLOW_ARTIFACT", "").strip() == "1":
        allow()
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open
    if not isinstance(data, dict) or data.get("tool_name") != "Artifact":
        allow()
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()
    action = str(ti.get("action") or "publish").strip().lower()
    if action == "publish":
        block()
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
