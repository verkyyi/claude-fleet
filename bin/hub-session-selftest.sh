#!/bin/bash
# hub-session-selftest.sh — the hub's launch contract: DASH-ONLY, never a Claude.
#
# Since issue #1533 that hub is the FLEET_DASH_WINDOW=1 way back only: by default
# hub-session.sh builds NO 'plan' window at all — it builds `home`, a plain shell
# the task list draws beside. Legs 1-5 below pin the FLEET_DASH_WINDOW=1 hub
# exactly as it was; leg 6 pins the default (print seam + a real isolated tmux).
#
# The 'plan' hub used to split a persistent `claude` in below the dash (the "hub
# pane", issue #439, successor to the steward seat). That pane restored itself
# unasked — the ⌂ home tap, F9 and prefix+g all fall back to hub-session.sh when
# they find no pane to focus, and fleet-up/fleet-restore rebuilt it on every fresh
# fleet and every crash recovery — so an operator who closed it got it back on the
# next tap. The hub is now the dash and NOTHING else.
#
# This test drives the REAL bin/hub-session.sh through its HUB_PRINT_CMD debug
# seam (which builds the launch command and exits BEFORE any tmux spawn — so no
# live tmux/dash/socket is needed) against a throwaway FLEET_CONF_DIR, and asserts:
#
#   • the launch is the DASHBOARD, and the word `claude` appears nowhere in it.
#   • the retired knobs are INERT: HUB_RESUME_ID (crash-resume of the hub
#     transcript) and FLEET_HUB_CMD (the per-fleet override) are both ignored, so
#     neither a stale restore.map nor a leftover conf key can reintroduce a hub
#     Claude. These are the regression guards — they are the exact paths that
#     used to bring the pane back.
#   • FLEET_HUB is NOT exported by the launch (nothing is auto-marked as the hub
#     any more). The @hub marker itself still EXISTS for a pane an operator marks
#     by hand — that contract lives in tmux-guard-selftest.sh / dash-marker-selftest.sh
#     and is deliberately unchanged here.
#   • no per-fleet settings/mcp files are rendered.
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
      FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 FLEET_DASH_WINDOW=1 \
      "$@" bash "$SCRIPT"
}

# no_claude <label> <cmd> — the headline guarantee: no route back to a Claude
# session. The install path itself legitimately contains the string "claude"
# (~/.claude/fleet/bin, or a claude-fleet checkout), so strip $BIN before
# matching — otherwise every run trivially "fails" on its own directory name.
# What survives the strip is real command text: `claude`, `claude --resume`,
# `fleet-claude.sh`, …
no_claude() {
  case "${2//"$BIN"/}" in *claude*) fail "$1: the hub must NEVER launch a claude session: $2" ;; esac
}

# --- 1. the hub launches the DASH, and no Claude at all ----------------------
out=$(run) || fail "default run exited non-zero"
# Fully deterministic, so pin it exactly — this is the whole hub command line.
[ "$out" = "bash '$BIN/tmux-dashboard.sh'" ] \
  || fail "default: the hub must launch the dash ALONE, got: $out"
no_claude default "$out"
# Retired rails must not reappear by any route.
case "$out" in *"--settings"*)     fail "default: --settings must not appear: $out" ;; esac
case "$out" in *"--mcp-config"*)   fail "default: --mcp-config must not appear: $out" ;; esac
case "$out" in *"--model"*)        fail "default: --model must not appear: $out" ;; esac
case "$out" in *"/fleet-steward"*) fail "default: the retired /fleet-steward seed must not appear: $out" ;; esac
# FLEET_MODEL is the workers' knob and must not reach the hub either.
out=$(run FLEET_MODEL=haiku) || fail "FLEET_MODEL run exited non-zero"
case "$out" in *"--model"*) fail "FLEET_MODEL must not be injected into the hub launch" ;; esac

# --- 2. no hub marker is exported (nothing is auto-marked @hub) --------------
out=$(run) || fail "marker run exited non-zero"
case "$out" in *"FLEET_HUB=1"*)
  fail "the dash-only hub must not export FLEET_HUB=1 — nothing is auto-marked as hub: $out" ;; esac
case "$out" in *"FLEET_SEAT"*) fail "the retired FLEET_SEAT env must not be exported (#439)" ;; esac

# --- 3. nothing is rendered on disk ------------------------------------------
run >/dev/null || fail "render-check run exited non-zero"
[ -e "$CONF/fleets/$SESS/steward-settings.json" ] && fail "no per-fleet settings file may be rendered"
[ -e "$CONF/fleets/$SESS/hub-settings.json" ]     && fail "no per-fleet settings file may be rendered"
[ -e "$CONF/fleets/$SESS/steward-mcp.json" ]      && fail "no per-fleet mcp config may be rendered"

# --- 4. REGRESSION: HUB_RESUME_ID is inert -----------------------------------
# fleet-restore.sh no longer passes this, but an OLD restore.map still carries a
# HUB row; a fleet restored from one must NOT come back with the hub Claude the
# operator closed on purpose.
out=$(run HUB_RESUME_ID=abc123) || fail "resume run exited non-zero"
case "$out" in *"--resume"*) fail "HUB_RESUME_ID must be IGNORED — no --resume in a dash-only hub: $out" ;; esac
no_claude HUB_RESUME_ID "$out"
case "$out" in *"abc123"*)   fail "HUB_RESUME_ID must not reach the launch command at all: $out" ;; esac

# --- 5. REGRESSION: FLEET_HUB_CMD is inert -----------------------------------
# The old per-fleet override could name ANY command. A leftover key in a live
# fleet's conf must not be a back door to a hub Claude.
out=$(run FLEET_HUB_CMD='claude "my own orders"; exec $SHELL') || fail "override run exited non-zero"
case "$out" in *"my own orders"*) fail "FLEET_HUB_CMD must be IGNORED, not honored: $out" ;; esac
no_claude FLEET_HUB_CMD "$out"
case "$out" in *"tmux-dashboard.sh"*) : ;;
  *) fail "override: the hub must still launch the dash: $out" ;; esac
# Both retired knobs together — still just the dash.
out=$(run HUB_RESUME_ID=xyz789 FLEET_HUB_CMD='claude "my own orders"; exec $SHELL')
no_claude resume+override "$out"

# --- 6. DEFAULT (issue #1533): no 'plan' window, a `home` shell instead --------
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = home ] || fail "default: hub-session must build the 'home' window, not the dash: $d"
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=cwd bash "$SCRIPT")
[ "$d" = "$MAIN" ] || fail "default: home must open in the fleet's checkout, got: $d"
# fleet.settings carries the knob too (the login's settings, #979).
printf 'FLEET_DASH_WINDOW=1\n' > "$CONF/fleet.settings"
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = "bash '$BIN/tmux-dashboard.sh'" ] || fail "fleet.settings FLEET_DASH_WINDOW=1 must bring the hub back: $d"
rm -f "$CONF/fleet.settings"

# A real build, on an isolated server (never the live one): fleet-up's throwaway
# first window, then hub-session.sh — `home` at index 1, no `plan`, and a second
# run (the ⌂ fallback) builds nothing more.
REAL_TMUX=$(command -v tmux 2>/dev/null)
if [ -z "$REAL_TMUX" ]; then
  printf 'selftest: tmux missing — live leg 6 SKIPPED\n' >&2
else
  mkdir -p "$WORK/shim"
  cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
case "\$1" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$WORK/sock" "\$@"
EOF
  chmod +x "$WORK/shim/tmux"
  trap '"$REAL_TMUX" -S "$WORK/sock" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
  T() { "$REAL_TMUX" -S "$WORK/sock" "$@"; }
  T -f /dev/null new-session -d -s "$SESS" -n work 'sleep 600' || fail "could not start the isolated tmux server"
  T set-option -g default-shell /bin/sh
  T set-option -g base-index 1
  live() { env -u FLEET_DASH_WINDOW -u TMUX PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" bash "$SCRIPT"; }
  live || fail "default: hub-session.sh exited non-zero"
  names=$(T list-windows -t "$SESS" -F '#{window_index}:#{window_name}' | tr '\n' ' ')
  case " $names" in *":plan "*) fail "default: a 'plan' window was built: $names" ;; esac
  case " $names" in *" 1:home "*) : ;; *) fail "default: 'home' must sit at index 1: $names" ;; esac
  [ "$(T display-message -p -t "$SESS:" '#{window_name}')" = home ] || fail "default: home must be selected"
  [ -z "$(T list-panes -s -t "$SESS" -F '#{@dash}' | tr -d '\n')" ] || fail "default: no dash pane may exist"
  live || fail "default: a second hub-session.sh exited non-zero"
  [ "$(T list-windows -t "$SESS" -F '#{window_name}' | grep -c '^home$')" = 1 ] \
    || fail "default: a second run must not build a second home: $(T list-windows -t "$SESS" -F '#{window_name}' | tr '\n' ' ')"
fi

printf 'PASS: default builds `home` (no plan window); FLEET_DASH_WINDOW=1 launches the dash ALONE — HUB_RESUME_ID and FLEET_HUB_CMD are inert, no claude by any route\n'
exit 0
