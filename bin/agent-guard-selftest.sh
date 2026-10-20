#!/bin/bash
# agent-guard-selftest.sh — the allow/deny matrix for hooks/agent-guard.py
# (issue #811): inside a fleet, code-writing work goes to a Fleet WORKER; a
# subagent may only do read-only fan-out.
#
# What is pinned:
#   1. ALLOW  — the read-only types (Explore / Plan / claude-code-guide).
#   2. BLOCK  — general-purpose, claude, fork, an unknown type, and NO type (the
#              tool's default is general-purpose); `isolation: worktree` even for
#              an allowed type (a fork worktree is edit-blocked by the base guard).
#              The refusal must TELL the model what to do instead — it names
#              the `task` tool + `await` (issue #4897), and Explore for the read-only case.
#   3. ESCAPE — FLEET_ALLOW_SUBAGENT=1 allows everything.
#   4. FAIL-OPEN — bad JSON / a non-Agent tool never block.
#   5. FLEET-SCOPED — outside a fleet (no FLEET_MAIN, no $TMUX) it is a no-op;
#              under $TMUX it asks fleet-lib whether the current session has a
#              fleet conf (an ad-hoc session on the default socket is NOT a
#              fleet, #159), via a stub lib so no live tmux is consulted.
#
# Hermetic: no network, no tmux, no live fleet. The fleet seam is the FLEET_MAIN
# env override (as in bash-guard-selftest.sh); the lib path is FLEET_LIB.
# python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which case diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
GUARD="$BIN/../hooks/agent-guard.py"
[ -f "$GUARD" ] || { printf 'selftest: %s not found\n' "$GUARD" >&2; exit 2; }

PY="$(command -v python3 2>/dev/null)"
[ -n "$PY" ] || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
# assert_exit <expected-code> <label> <json>   [env passed via caller]
assert_exit() {
  local want="$1" label="$2" json="$3" got
  printf '%s' "$json" | "$PY" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    st_miss "$label — expected exit $want, got $got"
  fi
}
# agent_json '<tool_input json>'  → a PreToolUse payload for the Agent tool
agent_json() { printf '{"tool_name":"Agent","tool_input":%s}' "$1"; }

# --- 1 + 2: the matrix, inside a fleet (FLEET_MAIN seam) ----------------------
( FAIL=0; unset FLEET_ALLOW_SUBAGENT; export FLEET_MAIN="$TMP/base"; unset TMUX
  # ALLOW: read-only fan-out
  for t in Explore Plan claude-code-guide; do
    assert_exit 0 "$t allowed" "$(agent_json "{\"subagent_type\":\"$t\",\"prompt\":\"find X\",\"description\":\"sweep\"}")"
  done
  assert_exit 0 "Explore with remote isolation allowed" "$(agent_json '{"subagent_type":"Explore","isolation":"remote","prompt":"p","description":"d"}')"
  # BLOCK: anything that could write
  assert_exit 2 "general-purpose blocked"  "$(agent_json '{"subagent_type":"general-purpose","prompt":"implement X","description":"impl"}')"
  assert_exit 2 "claude blocked"           "$(agent_json '{"subagent_type":"claude","prompt":"implement X","description":"impl"}')"
  assert_exit 2 "fork blocked"             "$(agent_json '{"subagent_type":"fork","prompt":"implement X","description":"impl"}')"
  assert_exit 2 "no subagent_type blocked" "$(agent_json '{"prompt":"implement X","description":"impl"}')"
  assert_exit 2 "unknown type blocked"     "$(agent_json '{"subagent_type":"brand-new-agent","prompt":"p","description":"d"}')"
  assert_exit 2 "fork + worktree blocked"  "$(agent_json '{"subagent_type":"fork","isolation":"worktree","prompt":"p","description":"d"}')"
  assert_exit 2 "Explore + worktree blocked (fork worktree is edit-blocked)" "$(agent_json '{"subagent_type":"Explore","isolation":"worktree","prompt":"p","description":"d"}')"
  # the refusal must TELL the model what to do instead
  msg=$(printf '%s' "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')" | "$PY" "$GUARD" 2>&1 >/dev/null)
  # issue #4897: hand it to a TASK — the `task` tool (spawn: true) and `await` on its T<n>.
  case "$msg" in *'Fleet TASK'*'task (title'*'spawn: true'*) ;; *) st_miss "refusal must point at the task tool with spawn (got: $msg)" ;; esac
  case "$msg" in *'await (task: T<n>)'*) ;; *) st_miss "refusal must point at await on the T<n> — the synchronous hand-off (got: $msg)" ;; esac
  case "$msg" in *dash-issue-session.sh*|*issue-file*) st_miss "refusal must not send the work to a GitHub issue any more" ;; esac
  case "$msg" in *Explore*) ;; *) st_miss "refusal must name Explore for read-only fan-out" ;; esac
  case "$msg" in *FLEET_ALLOW_SUBAGENT=1*) ;; *) st_miss "refusal must name the FLEET_ALLOW_SUBAGENT escape hatch" ;; esac
  # --- 4: fail-open
  assert_exit 0 "bad json → allow"        'nope'
  assert_exit 0 "non-Agent tool → allow"  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}'
  assert_exit 0 "tool_input not an object → allow" '{"tool_name":"Agent","tool_input":"general-purpose"}'
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))

# --- 3: the operator's escape hatch --------------------------------------------
( FAIL=0; export FLEET_ALLOW_SUBAGENT=1 FLEET_MAIN="$TMP/base"; unset TMUX
  assert_exit 0 "FLEET_ALLOW_SUBAGENT=1 → general-purpose allowed" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  assert_exit 0 "FLEET_ALLOW_SUBAGENT=1 → fork + worktree allowed"   "$(agent_json '{"subagent_type":"fork","isolation":"worktree","prompt":"p","description":"d"}')"
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))
( FAIL=0; export FLEET_ALLOW_SUBAGENT=0 FLEET_MAIN="$TMP/base"; unset TMUX
  assert_exit 2 "FLEET_ALLOW_SUBAGENT=0 is not an override" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))

# --- 5: fleet-scoped -------------------------------------------------------------
# Not in a fleet (no FLEET_MAIN, no $TMUX) → nothing to protect → allow
( FAIL=0; unset FLEET_ALLOW_SUBAGENT FLEET_MAIN TMUX
  assert_exit 0 "no fleet → general-purpose allowed" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))
# Under $TMUX with no FLEET_MAIN, the guard asks fleet-lib. A stub lib stands in
# for the real one so no live tmux server is ever consulted: fleet_current_session
# and fleet_conf_file are the two functions the guard calls.
mkdir -p "$TMP/conf/fleets/fleet-x"; : > "$TMP/conf/fleets/fleet-x/conf"
cat > "$TMP/stub-lib.sh" <<STUB
fleet_current_session() { printf '%s' "\${STUB_SESSION:-}"; }
fleet_conf_file() { printf '%s' "$TMP/conf/fleets/\$1/conf"; }
STUB
( FAIL=0; unset FLEET_ALLOW_SUBAGENT FLEET_MAIN; export TMUX=/tmp/tmux-0/fleet-x,1,0 FLEET_LIB="$TMP/stub-lib.sh"
  STUB_SESSION=fleet-x assert_exit 2 "tmux session WITH a fleet conf → blocked" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  STUB_SESSION=fleet-x assert_exit 0 "tmux session WITH a fleet conf → Explore still allowed" "$(agent_json '{"subagent_type":"Explore","prompt":"p","description":"d"}')"
  STUB_SESSION=adhoc   assert_exit 0 "ad-hoc tmux session (no fleet conf) → allowed" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  STUB_SESSION=''      assert_exit 0 "tmux, no resolvable session → allowed" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))
( FAIL=0; unset FLEET_ALLOW_SUBAGENT FLEET_MAIN; export TMUX=/tmp/tmux-0/x,1,0 FLEET_LIB="$TMP/no-such-lib.sh"
  assert_exit 0 "tmux but no fleet-lib installed → allowed (fail open)" "$(agent_json '{"subagent_type":"general-purpose","prompt":"p","description":"d"}')"
  exit $FAIL ); rc=$?; FAIL=$((FAIL + rc))

# The hook must be WIRED: settings-hooks.json carries an Agent group that runs it.
HOOKS="$BIN/../hooks/settings-hooks.json"
"$PY" - "$HOOKS" <<'PY' || { st_miss "hooks/settings-hooks.json has no PreToolUse group matcher=Agent running agent-guard.py"; }
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
ok = any(g.get("matcher") == "Agent" and any("agent-guard.py" in h.get("command", "") for h in g.get("hooks", [])) for g in d)
sys.exit(0 if ok else 1)
PY

st_done
