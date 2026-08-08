#!/bin/bash
# hub-session-selftest.sh — the hub pane's launch contract (issue #439).
#
# Since #439 the fleet is operator-driven: the 'plan' hub's bottom pane runs a
# PLAIN `claude` in the base checkout — no charter seed, no settings profile, no
# MCP diet, no model override. This test drives the REAL bin/hub-session.sh
# through its HUB_PRINT_CMD debug seam (which builds the launch command and exits
# BEFORE any tmux spawn — so no live claude/hub/socket is needed) against a
# throwaway FLEET_CONF_DIR, and asserts:
#
#   • default: the launch is a bare `claude` + the pane-keep-alive `exec $SHELL`,
#     with NONE of the retired Steward-Lite flags and no `/fleet-steward` seed.
#   • FLEET_HUB=1 is exported into the pane command (the durable hub marker the
#     shell/cw.zsh destroy-guard trusts first, issue #202).
#   • resume (HUB_RESUME_ID): `claude --resume <id>` with a `||` fallback to the
#     fresh launch, so a stale/pruned id never strands the pane at a bare shell.
#   • FLEET_HUB_CMD override: owns its whole command line — nothing injected.
#   • no per-fleet settings/mcp files are rendered any more.
#
# Hermetic: its own temp FLEET_CONF_DIR, no tmux, no network.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/hub-session.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubsess-selftest.XXXXXX")" || exit 2
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

# Run the script through the print seam with a CLEAN env (drop any FLEET_*/HUB_*
# the caller's shell might export). Extra assignments are passed as args,
# e.g.  run HUB_RESUME_ID=abc123
run() {
  env -u FLEET_MODEL -u FLEET_HUB_CMD -u HUB_RESUME_ID -u HUB_CWD -u HUB_CMD \
      FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 \
      "$@" bash "$SCRIPT"
}

# --- 1. default: a plain `claude`, no injected flags, no seed prompt ----------
out=$(run) || fail "default run exited non-zero"
case "$out" in *"claude"*)   : ;; *) fail "default: expected a bare claude launch: $out" ;; esac
case "$out" in *'exec $SHELL'*) : ;; *) fail "default: pane-keep-alive 'exec \$SHELL' tail missing: $out" ;; esac
# None of the retired Steward-Lite rails may appear.
case "$out" in *"--settings"*)          fail "default: --settings must not appear (Steward Lite retired, #439)" ;; esac
case "$out" in *"--strict-mcp-config"*) fail "default: --strict-mcp-config must not appear (#439)" ;; esac
case "$out" in *"--mcp-config"*)        fail "default: --mcp-config must not appear (#439)" ;; esac
case "$out" in *"--model"*)             fail "default: --model must not appear — the hub inherits your own claude config" ;; esac
case "$out" in *"/fleet-steward"*)      fail "default: the retired /fleet-steward seed must not be launched (#439)" ;; esac
# FLEET_MODEL must NOT leak into the hub launch either (the workers own that knob).
out=$(run FLEET_MODEL=haiku) || fail "FLEET_MODEL run exited non-zero"
case "$out" in *"--model"*) fail "FLEET_MODEL must not be injected into the hub launch (#439)" ;; esac

# --- 2. the durable hub marker is exported into the pane command --------------
out=$(run) || fail "marker run exited non-zero"
case "$out" in "export FLEET_HUB=1; "*) : ;;
  *) fail "hub marker: the command must start with 'export FLEET_HUB=1; ' (#202): $out" ;; esac
case "$out" in *"FLEET_SEAT"*) fail "hub marker: the retired FLEET_SEAT env must not be exported (#439)" ;; esac

# --- 3. nothing is rendered on disk any more ---------------------------------
run >/dev/null || fail "render-check run exited non-zero"
[ -e "$CONF/fleets/$SESS/steward-settings.json" ] && fail "no per-fleet settings file may be rendered (#439)"
[ -e "$CONF/fleets/$SESS/hub-settings.json" ]     && fail "no per-fleet settings file may be rendered (#439)"
[ -e "$CONF/fleets/$SESS/steward-mcp.json" ]      && fail "no per-fleet mcp config may be rendered (#439)"

# --- 4. resume: --resume <id>, with a fallback to the fresh launch ------------
out=$(run HUB_RESUME_ID=abc123) || fail "resume run exited non-zero"
case "$out" in *"claude --resume 'abc123'"*) : ;;
  *) fail "resume: expected \`claude --resume 'abc123'\`: $out" ;; esac
case "$out" in *"--resume 'abc123' || { claude; }"*) : ;;
  *) fail "resume: a stale id must fall back to the fresh launch with ||: $out" ;; esac
# The '-' sentinel means "no id captured" → a plain fresh launch, never --resume.
out=$(run HUB_RESUME_ID=-) || fail "resume-sentinel run exited non-zero"
case "$out" in *"--resume"*) fail "resume: the '-' sentinel must NOT produce a --resume: $out" ;; esac

# --- 5. FLEET_HUB_CMD override owns its whole command line -------------------
out=$(run FLEET_HUB_CMD='claude "my own orders"; exec $SHELL') || fail "override run exited non-zero"
case "$out" in *"my own orders"*) : ;; *) fail "override: FLEET_HUB_CMD not honored: $out" ;; esac
case "$out" in *"--settings"*|*"--model"*) fail "override: nothing may be injected into a FLEET_HUB_CMD override" ;; esac
# Resume still beats the override (that is what fleet-restore announces).
out=$(run HUB_RESUME_ID=xyz789 FLEET_HUB_CMD='claude "my own orders"; exec $SHELL')
case "$out" in "export FLEET_HUB=1; claude --resume 'xyz789' || { claude \"my own orders\"; exec \$SHELL; };"*) : ;;
  *) fail "override+resume: resume must lead, with the override as the fallback: $out" ;; esac

printf 'PASS: hub-session launches a plain claude (no Steward Lite rails), exports FLEET_HUB, resumes with a fallback\n'
exit 0
