#!/bin/sh
# fleet-pending-tool.sh <transcript.jsonl>      — WHICH tool is this session blocked on?
# fleet-pending-tool.sh [-L <sock>] <tmux-tgt>  — …asked of a WINDOW/PANE (issue #658)
#
# Prints the NAME of the newest `tool_use` in the transcript that has no
# `tool_result` yet, and exits 0. Nothing pending ⇒ no output, exit 1.
#
# WHY IT IS ITS OWN FILE (issue #656). "tool_use without tool_result" is the fleet's
# ONE hard judgement about what a red window is waiting on, and four callers need
# it: bin/fleet-answer.sh (the pending gate — is there an AskUserQuestion to answer?),
# bin/fleet-permission.sh (the same gate, inverted — an AskUserQuestion is NOT ours),
# bin/set-claude-state.sh, which stamps @claude_needs (#656), and since #658 the
# spinner's stale-`needs` reconcile, which asks it about a WINDOW.
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
# ── TARGET FORM (issue #658) ─────────────────────────────────────────────────
# The argument may also be a tmux target (`%83`, `@12`, `sess:idx`) instead of a
# transcript path — "does the session in THIS window have a tool_use pending?" is
# the question a reconcile actually has, and #658 was filed on the back of a
# `fleet-pending-tool.sh %83` that printed nothing and was read as "that pane is
# idle". It was not: a pane id is not a file, so the path form simply exited 1. The
# only way that command could not mislead is for it to MEAN something, so it does:
# pane → Claude pid → the session registry's sessionId → ~/.claude/projects/*/<sid>.jsonl,
# the same exact, cwd-independent chain bin/fleet-answer.sh resolves with.
# `-L <socket>` targets one fleet's tmux server for a headless caller (the spinner);
# inside a pane, bare tmux is already the right server.
#
# Exit codes — the target form needs to distinguish "nothing is pending" from "I
# could not find out", because a reconcile ACTS on the first and must never act on
# the second:
#   0  a tool_use is pending      — its name on stdout
#   1  nothing is pending         — a transcript WAS read and holds no open tool_use
#                                   (path form: also an absent/unreadable path, the
#                                   historic fail-safe every hook caller relies on)
#   2  usage
#   3  no live Claude under that pane — nothing CAN be pending (target form only)
#   4  unknown — a non-Claude agent, a live Claude whose transcript could not be
#      resolved or read, no python3, no tmux, unavailable shared reader (target form only). Treat 4 as
#      "leave it alone".
#
# `sh`-wired on purpose: its first caller is a `sh` hook on the Notification path.
# Fail-safe by construction — on the PATH form any failure (no python3, unreadable
# transcript, malformed JSON) is silence + exit 1, which leaves every caller on the
# behaviour it had before it asked.
# Compatibility entry: the importable module owns both resolution and parsing.
set -u
case "${1:-}" in
  -L|--socket) [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 2; _target=$3 ;;
  -*|'') exit 2 ;;
  *) _target=$1 ;;
esac
_unknown=4
case "$_target" in */*) _unknown=1 ;; esac
[ ! -f "$_target" ] || _unknown=1
command -v python3 >/dev/null 2>&1 || exit "$_unknown"
# Shell parameter expansion avoids a dirname subprocess on every hook.
_bin=${0%/*}
[ "$_bin" != "$0" ] || _bin=.
[ -f "$_bin/fleet_pending_tool.py" ] || exit "$_unknown"
exec python3 "$_bin/fleet_pending_tool.py" "$@"
