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
#   4  unknown — a live Claude whose transcript could not be resolved or read, no
#      python3, no tmux, no fleet-lib (target form only). Callers must treat 4 as
#      "leave it alone".
#
# `sh`-wired on purpose: its first caller is a `sh` hook on the Notification path.
# Fail-safe by construction — on the PATH form any failure (no python3, unreadable
# transcript, malformed JSON) is silence + exit 1, which leaves every caller on the
# behaviour it had before it asked.
set -u

usage() { printf 'usage: fleet-pending-tool.sh [-L <socket>] <transcript.jsonl|tmux-target>\n' >&2; exit 2; }

SOCK=''
case "${1:-}" in
  -L|--socket) SOCK="${2:-}"; [ -n "$SOCK" ] || usage; shift 2 ;;
  -*) usage ;;
esac
T="${1:-}"
[ -n "$T" ] || usage

MODE=path
if [ ! -f "$T" ]; then
  # A PATH that isn't there stays the path form (exit 1) — never re-read as a tmux
  # target. The hook passes `transcript_path` straight through, and a stale/rotated
  # one must keep costing the subtype, not go looking for a window.
  case "$T" in
    /*|./*|../*|*/*) exit 1 ;;
  esac
  MODE=target
fi

# `unknown` — the exit code for "could not find out", which differs per form: the
# path form owes its hook callers today's fail-safe silence (1); the target form owes
# its reconcile caller a signal it must not act on (4).
unknown() { [ "$MODE" = target ] && exit 4; exit 1; }

if [ "$MODE" = target ]; then
  command -v tmux  >/dev/null 2>&1 || unknown
  command -v bash  >/dev/null 2>&1 || unknown
  BIN0=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || unknown
  [ -n "${BIN0:-}" ] && [ -f "$BIN0/fleet-lib.sh" ] || unknown

  # ONE bash hop for both facts (≈70 ms measured, dominated by the `ps` tree walk).
  # fleet_pane_claude_pid is the fleet's canonical "is Claude alive in this pane"
  # gate (#511 — `pane_current_command` reads the shell runner for a session's whole
  # life on macOS, so it cannot answer this) and it is bash; this script is sh. Same
  # bash-hop idiom bin/set-claude-state.sh uses for fleet-hook-conf.sh.
  _probe=$(bash -c '
    . "$1/fleet-lib.sh" 2>/dev/null || exit 1
    p=$(fleet_pane_claude_pid "$2" "$3" 2>/dev/null)
    printf "pid=%s\n" "$p"
    [ -n "$p" ] && printf "sid=%s\n" "$(fleet_cc_session_id "$p" 2>/dev/null)"
    exit 0   # a pane with no Claude is an ANSWER (pid=, → 3), not a failed hop
  ' _ "$BIN0" "$T" "$SOCK" 2>/dev/null) || unknown

  _pid=$(printf '%s\n' "$_probe" | sed -n 's/^pid=//p' | sed -n 1p)
  [ -n "$_pid" ] || exit 3                       # no Claude here — nothing can be pending
  _sid=$(printf '%s\n' "$_probe" | sed -n 's/^sid=//p' | sed -n 1p)
  [ -n "$_sid" ] || unknown                      # alive but unregistered ⇒ don't guess

  # CLAUDE_PROJECTS_DIR mirrors fleet_transcript_dir's override so a selftest can
  # point the whole lookup at a scratch tree.
  _found=''
  for _f in "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$_sid".jsonl; do
    [ -f "$_f" ] && { _found="$_f"; break; }
  done
  [ -n "$_found" ] || unknown
  T="$_found"
fi

command -v python3 >/dev/null 2>&1 || unknown

FPT_T="$T" python3 - <<'PY' 2>/dev/null
import json, os, sys

# Identical rule to bin/fleet-answer.sh and bin/fleet-permission.sh: walk the whole
# transcript, remember every tool_use in order and every id that got a result, and
# take the newest id still without one.
#
# Exit 4 (not 1) for any failure to READ: "nothing is pending" and "I could not
# look" are the same silence on stdout, and #658's caller clears a red window on the
# first. The shell above folds 4 back to 1 for the path form, whose hook callers
# have always treated an unreadable transcript as "no answer, keep the wording's".
try:
    uses, done, order = {}, set(), []
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
except Exception:
    sys.exit(4)

tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
if tuid is None:
    sys.exit(1)
print(uses[tuid])
PY
rc=$?
# 4 = the read itself failed. The path form owes its hooks silence+1; the target
# form must hand its caller the "don't act" code.
[ "$rc" = 4 ] && unknown
exit "$rc"
