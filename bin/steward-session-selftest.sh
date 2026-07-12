#!/bin/bash
# steward-session-selftest.sh — the Steward Lite profile (issue #284).
#
# bin/steward-session.sh renders a per-fleet settings file from
# conf/steward-settings.template.json and launches the hub `claude` with
# `--settings <it> --strict-mcp-config --mcp-config <empty> [--model <m>]`, giving
# every fleet's steward a minimum fixed context + hard no-code rails at the one
# choke point all hubs share. This test drives the REAL script through its
# STEWARD_PRINT_CMD debug seam (which builds the launch command and exits BEFORE
# any tmux spawn — so no live claude/hub/socket is needed) against a throwaway
# FLEET_CONF_DIR, and asserts the flag/rendering matrix:
#
#   • LITE on (default): renders settings; deny covers base + issue-<N> worktree
#     siblings + NotebookEdit; launch carries --settings/--strict-mcp-config/--mcp-config.
#   • FLEET_STEWARD_MCP=1: keeps --settings but DROPS the MCP diet (--strict-mcp-config).
#   • FLEET_STEWARD_MODEL / FLEET_MODEL: --model resolves steward ▸ fleet ▸ (none).
#   • LITE=0: bare spawn — no --settings/--strict-mcp-config/--model, no file rendered.
#   • resume (STEWARD_RESUME_ID): the rails are re-applied on the resume invocation.
#   • FLEET_STEWARD_CMD override: never injected into — the override owns its command.
#
# Hermetic: its own temp FLEET_CONF_DIR, no tmux, no network. python3 gates only
# the JSON-validity assertion (SKIP that one if absent — the rest still run).
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/steward-session.sh"
TPL="$BIN/../conf/steward-settings.template.json"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }
[ -f "$TPL" ]    || { printf 'selftest: %s not found\n' "$TPL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stsess-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM HUP

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SESS=tf
CONF="$WORK/conf"
MAIN="$WORK/projects/widget"
mkdir -p "$CONF/fleets/$SESS" "$MAIN"
cat > "$CONF/fleets/$SESS/conf" <<EOF
FLEET_REPO="acme/widget"
FLEET_MAIN="$MAIN"
FLEET_BASE_BRANCH="main"
EOF

SETTINGS="$CONF/fleets/$SESS/steward-settings.json"
MCPCFG="$CONF/fleets/$SESS/steward-mcp.json"

# Run the script through the print seam with a CLEAN env (drop any FLEET_*/STEWARD_*
# the caller's shell might export — the steward seat leaks these). Extra assignments
# are passed as args, e.g.  run FLEET_STEWARD_MCP=1
run() {
  env -u FLEET_STEWARD_LITE -u FLEET_STEWARD_MCP -u FLEET_STEWARD_MODEL \
      -u FLEET_MODEL -u FLEET_STEWARD_CMD -u STEWARD_RESUME_ID -u STEWARD_CWD \
      FLEET_CONF_DIR="$CONF" STEWARD_SESSION="$SESS" STEWARD_PRINT_CMD=1 \
      "$@" bash "$SCRIPT"
}

# --- 1. LITE on (default): renders settings + full lite flags ----------------
rm -f "$SETTINGS" "$MCPCFG"
out=$(run) || fail "default run exited non-zero"
[ -f "$SETTINGS" ] || fail "default: steward-settings.json not rendered"
[ -f "$MCPCFG" ]   || fail "default: steward-mcp.json not rendered"
case "$out" in *"--settings '$SETTINGS'"*)              : ;; *) fail "default: --settings <rendered> missing from launch: $out" ;; esac
case "$out" in *"--strict-mcp-config"*)                 : ;; *) fail "default: --strict-mcp-config missing" ;; esac
case "$out" in *"--mcp-config '$MCPCFG'"*)              : ;; *) fail "default: --mcp-config <empty> missing" ;; esac

# deny rules: base checkout + worktree siblings (double-slash abs anchor) + NotebookEdit.
grep -qF "\"Edit(//${MAIN#/}/**)\""            "$SETTINGS" || fail "deny: Edit(base) rule missing/mis-anchored"
grep -qF "\"Write(//${MAIN#/}/**)\""           "$SETTINGS" || fail "deny: Write(base) rule missing"
grep -qF "\"Edit(//${MAIN#/}-issue-*/**)\""    "$SETTINGS" || fail "deny: Edit(worktree glob) rule missing"
grep -qF "\"Write(//${MAIN#/}-issue-*/**)\""   "$SETTINGS" || fail "deny: Write(worktree glob) rule missing"
grep -qF '"NotebookEdit"'                       "$SETTINGS" || fail "deny: bare NotebookEdit rule missing"
# allow rules carry the substituted install bin dir (no leftover placeholder).
grep -qF "Bash(${BIN}/dash-issue-session.sh:*)" "$SETTINGS" || fail "allow: __BIN__ not substituted for spawn script"
grep -qF "Bash(gh issue list:*)"                "$SETTINGS" || fail "allow: read-only gh command missing"
grep -q  '__DENY_BASE__\|__DENY_WORKTREES__\|__BIN__' "$SETTINGS" && fail "rendered settings still contain a __PLACEHOLDER__"
# empty MCP config = zero servers.
grep -qF '"mcpServers"' "$MCPCFG" || fail "mcp cfg: missing mcpServers key"

# JSON validity (python3-gated — SKIP if absent, per the run-selftests convention).
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('$SETTINGS')); json.load(open('$MCPCFG'))" \
    || fail "rendered settings/mcp are not valid JSON"
else
  printf 'note: python3 absent — skipping JSON-validity assertion\n' >&2
fi

# --- 2. FLEET_STEWARD_MCP=1: --settings stays, MCP diet drops ----------------
out=$(run FLEET_STEWARD_MCP=1) || fail "mcp=1 run exited non-zero"
case "$out" in *"--settings '$SETTINGS'"*) : ;; *) fail "mcp=1: --settings should still apply" ;; esac
case "$out" in *"--strict-mcp-config"*) fail "mcp=1: --strict-mcp-config must be dropped when MCP kept" ;; esac
case "$out" in *"--mcp-config"*)        fail "mcp=1: --mcp-config must be dropped when MCP kept" ;; esac

# --- 3. model resolution: steward ▸ fleet ▸ (none) ---------------------------
out=$(run FLEET_STEWARD_MODEL=sonnet)
case "$out" in *"--model 'sonnet'"*) : ;; *) fail "model: FLEET_STEWARD_MODEL not honored" ;; esac
out=$(run FLEET_STEWARD_MODEL=sonnet FLEET_MODEL=haiku)
case "$out" in *"--model 'sonnet'"*) : ;; *) fail "model: steward model must win over fleet model" ;; esac
out=$(run FLEET_MODEL=haiku)
case "$out" in *"--model 'haiku'"*) : ;; *) fail "model: FLEET_MODEL not inherited when steward model unset" ;; esac
out=$(run)   # neither set → no --model flag (defer to claude's own default)
case "$out" in *"--model"*) fail "model: no --model expected when neither steward nor fleet model set" ;; *) : ;; esac

# --- 4. LITE=0: bare spawn, nothing rendered, no lite flags ------------------
rm -f "$SETTINGS" "$MCPCFG"
out=$(run FLEET_STEWARD_LITE=0) || fail "lite=0 run exited non-zero"
[ -f "$SETTINGS" ] && fail "lite=0: must NOT render a settings file"
case "$out" in *"--settings"*)          fail "lite=0: --settings must not appear" ;; esac
case "$out" in *"--strict-mcp-config"*) fail "lite=0: --strict-mcp-config must not appear" ;; esac
case "$out" in *"claude "*"/fleet-steward"*) : ;; *) fail "lite=0: expected the bare built-in /fleet-steward launch: $out" ;; esac

# --- 5. resume: rails re-applied on the resume invocation --------------------
out=$(run STEWARD_RESUME_ID=abc123 FLEET_STEWARD_LITE=1)
case "$out" in *"claude --settings '$SETTINGS' --strict-mcp-config"*"--resume 'abc123'"*) : ;;
  *) fail "resume: lite flags must precede --resume so a resumed steward keeps the rails: $out" ;; esac

# --- 6. FLEET_STEWARD_CMD override: never injected, nothing rendered ---------
rm -f "$SETTINGS"
out=$(run FLEET_STEWARD_CMD='claude "my own orders"; exec $SHELL')
case "$out" in *"my own orders"*) : ;; *) fail "override: FLEET_STEWARD_CMD not honored" ;; esac
case "$out" in *"--settings"*) fail "override: lite flags must NOT be injected into a FLEET_STEWARD_CMD override" ;; esac
[ -f "$SETTINGS" ] && fail "override: must NOT render a settings file (the override owns its command)"

printf 'PASS: steward-session Steward Lite profile renders + gates correctly\n'
exit 0
