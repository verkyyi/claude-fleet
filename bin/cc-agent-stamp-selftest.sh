#!/bin/bash
# cc-agent-stamp-selftest.sh — every road that opens or relaunches a session's
# window stamps its agent, Claude too (T493: the ⌘P list's Agent column, the
# reports' `agent`). A lint over the spawners and launchers:
#   A  dash-raw-session.sh / dash-issue-session.sh / fleet-migrate.sh stamp
#      @cc_agent unconditionally — never behind a `[ -n "$AGENT" ]` or a
#      codex-only test
#   B  fleet-claude.sh stamps `claude`, fleet-codex.sh `codex`, from the pane
#   C  fleet-transfer.sh and fleet-restore.sh keep stamping it
#   D  fleet-report-parent.sh reads @cc_agent and files it on the ledger row and
#      the person's reminder
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
fail() { printf 'cc-agent-stamp selftest FAIL: %s\n' "$1" >&2; exit 1; }
pass() { echo "ok   $*"; }

for f in dash-raw-session.sh dash-issue-session.sh fleet-migrate.sh; do
  line=$(grep -n '@cc_agent "' "$BIN/$f" | grep -i 'set-window-option\|set-option' | head -1)
  [ -n "$line" ] || fail "A: $f stamps no @cc_agent"
  case "$line" in *'[ -n "$AGENT" ]'*|*'!= codex'*|*'= codex ]'*) fail "A: $f stamps @cc_agent only sometimes: $line" ;; esac
  case "$line" in *'claude}'*) ;; *) fail "A: $f has no Claude default in its stamp: $line" ;; esac
done
pass "A  the spawners and migrate always stamp @cc_agent, Claude by default"
grep -q 'set-option -w -t "$TMUX_PANE" @cc_agent claude' "$BIN/fleet-claude.sh" || fail "B: fleet-claude.sh does not stamp claude"
grep -q '@cc_agent codex' "$BIN/fleet-codex.sh" || fail "B: fleet-codex.sh does not stamp codex"
pass "B  each launcher stamps its own agent"
grep -q '@cc_agent "$TO"' "$BIN/fleet-transfer.sh" || fail "C: fleet-transfer.sh no longer stamps the target agent"
grep -q '@cc_agent "${wagent:-claude}"' "$BIN/fleet-restore.sh" || fail "C: fleet-restore.sh no longer stamps the agent"
pass "C  transfer and restore stamp it"
grep -q '#{@cc_agent}|#{window_name}' "$BIN/fleet-report-parent.sh" || fail "D: fleet-report-parent.sh does not read @cc_agent"
grep -q 'd\["agent"\]' "$BIN/fleet-report-parent.sh" || fail "D: the ledger row carries no agent"
grep -q 'OR_AGENT="$wagent"' "$BIN/fleet-report-parent.sh" || fail "D: the reminder row carries no agent"
pass "D  a report names its agent"
