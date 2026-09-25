#!/bin/bash
# orphan-listener-reap-selftest.sh — the orphaned-LISTENER rails of issue #1154:
# fleet_orphan_listeners / fleet_reap_orphan_listeners (the diskguard tick),
# fleet_reap_worktree_listeners (teardown), and the doctor's `listen` line.
#
# The gap this guards: a 2026-09-24 audit found agent-started `python3 -m
# http.server` orphans (PPID=1) bound to `*:<port>` — one serving the WHOLE
# scratchpad root /private/tmp/claude-<uid> to the LAN, one in a session
# scratchpad, one in a worktree long since built — and none of the worktree-keyed
# reapers could see them: a cwd that belongs to no session, or to a worktree that
# is already gone, matches nothing they look for.
#
# Asserts:
#   • MANGLE      fleet_mangle_path turns EVERY non-alphanumeric into `-` (Claude
#                 Code's rule) — `tr '/' '-'` kept the dots, so a `*.noindex`
#                 worktree's session scratchpad was invisible to #469's matcher.
#   • ROOT        a listener whose cwd IS the scratchpad root is a candidate, and
#                 the LAN bind shows in `fleet-diskguard.sh --listeners`.
#   • DELETED     a listener whose worktree (`…-issue-N`) was removed after it
#                 started is still a candidate — lsof keeps reporting the old path.
#   • AGE GATE    nothing younger than minage is taken.
#   • SCOPE       a listener in a plain dir (not fleet-anchored), and an exempt
#                 one (doc-preview's server.py), are never candidates.
#   • REAP        the sweep kills both candidates and their PORTS ARE RELEASED;
#                 the unanchored and exempt ones survive.
#   • TEARDOWN    fleet_reap_worktree_listeners kills a listener in the worktree's
#                 session scratchpad and leaves a NON-listening orphan beside it
#                 (that one is the age-gated kept-worktree sweep's call, not this).
#   • PANE        a listener running under a live tmux pane is never a candidate.
#   • DOCTOR      `fleet-doctor.sh` WARNs `listen` naming the LAN orphan, and no
#                 longer names it once it is reaped (PASS when the box is clean).
#
# Hermetic: the scratchpad root is a temp dir (FLEET_CLAUDE_TMP_ROOT), probes are
# double-forked python sockets (real orphans, PPID=1) that SERVE NOTHING — a bare
# listen(), so even the one bound to 0.0.0.0 exposes no file for its few seconds.
# tmux is driven on a PRIVATE -S socket only (issue #159). No lsof → SKIP.
# Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }
command -v lsof >/dev/null 2>&1 || { printf 'selftest: no lsof — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: no python3 — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-listen.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"

PROBES=""
PANE_SOCK=""
cleanup() {
  [ -n "$PROBES" ] && kill $PROBES 2>/dev/null
  # ISOLATED socket only (issue #159's rail): this is never a fleet's server.
  [ -n "$PANE_SOCK" ] && tmux -S "$PANE_SOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB"
export FLEET_CLAUDE_TMP_ROOT="$WORK/claude-root"
mkdir -p "$FLEET_CLAUDE_TMP_ROOT"

# A listening socket and nothing else: bind, listen, write the port, sleep.
# Extra argv words ride along so a probe can carry an exempt fingerprint.
LISTEN_PY='import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 0)); s.listen(1)
open(sys.argv[2], "w").write(str(s.getsockname()[1])); time.sleep(90)'

# probe <cwd> <bind-addr> [extra argv…] → sets PROBE_PID + PROBE_PORT. DOUBLE fork,
# so the probe is a true orphan (a plain background child would inherit this
# script's pane ancestry and read as owned — see orphan-proc-reap-selftest.sh).
PROBE_PID=""; PROBE_PORT=""
probe() {
  local dir="$1" addr="$2"; shift 2
  mkdir -p "$dir" || fail "cannot create $dir"
  local pf="$WORK/.probe.pid" portf="$WORK/.probe.port"; rm -f "$pf" "$portf"
  ( ( cd "$dir" && exec python3 -c "$LISTEN_PY" "$addr" "$portf" "$@" ) >/dev/null 2>&1 &
    printf '%s' "$!" > "$pf" ) &
  wait $! 2>/dev/null
  PROBE_PID="$(cat "$pf" 2>/dev/null)"
  [ -n "$PROBE_PID" ] || fail "probe pid was not captured for $dir"
  PROBES="$PROBES $PROBE_PID"
  local i=0; while [ "$i" -lt 50 ] && [ ! -s "$portf" ]; do i=$((i+1)); sleep 0.1; done
  PROBE_PORT="$(cat "$portf" 2>/dev/null)"
  [ -n "$PROBE_PORT" ] || fail "probe in $dir never listened"
}
listening() { lsof -nP -w -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | grep -q "^n.*:$2\$"; }
has_pid()   { printf '%s\n' "$2" | awk -v p="$1" '{ for (i=1;i<=NF;i++) if ($i==p) f=1 } END{ exit !f }'; }

# --- MANGLE ------------------------------------------------------------------
got="$(fleet_mangle_path '/Users/u/projects/.fleet-worktrees.noindex/app_x-issue-7')"
[ "$got" = "-Users-u-projects--fleet-worktrees-noindex-app-x-issue-7" ] \
  && ok "fleet_mangle_path turns every non-alphanumeric into '-' (dots too)" \
  || fail "fleet_mangle_path mangled wrong" "$got"

# --- the fixtures --------------------------------------------------------------
probe "$FLEET_CLAUDE_TMP_ROOT" 0.0.0.0;           p_root="$PROBE_PID"; port_root="$PROBE_PORT"
probe "$WORK/app-issue-77/dist" 127.0.0.1;        p_del="$PROBE_PID";  port_del="$PROBE_PORT"
rm -rf "$WORK/app-issue-77"                       # the worktree is gone; the server is not
probe "$WORK/plain/site" 127.0.0.1;               p_plain="$PROBE_PID"
probe "$FLEET_CLAUDE_TMP_ROOT/x" 127.0.0.1 /skills/doc-preview/server.py; p_exempt="$PROBE_PID"

# --- ROOT / DELETED / SCOPE ----------------------------------------------------
cand="$(fleet_reap_orphan_listeners dry 0)"
has_pid "$p_root" "$cand" && ok "a listener whose cwd IS the scratchpad root is a candidate" \
  || fail "scratchpad-root listener $p_root not a candidate" "$cand"
has_pid "$p_del" "$cand" && ok "a listener in a REMOVED worktree is still a candidate" \
  || fail "deleted-worktree listener $p_del not a candidate" "$cand"
has_pid "$p_plain" "$cand" && fail "an unanchored listener $p_plain was made a candidate" "$cand"
has_pid "$p_exempt" "$cand" && fail "doc-preview's server ($p_exempt) was made a candidate" "$cand"
ok "unanchored and exempt listeners are never candidates"
case "$cand" in *"$p_root lan "*) ok "a 0.0.0.0 bind is classified lan" ;;
  *) fail "the 0.0.0.0 probe was not classified lan" "$cand" ;; esac

lst="$(bash "$BIN/fleet-diskguard.sh" --listeners 2>&1)"
has_pid "$p_root" "$lst" && ok "diskguard --listeners names the LAN-bound orphan" \
  || fail "--listeners missed the LAN-bound orphan $p_root" "$lst"
has_pid "$p_del" "$lst" && fail "--listeners named a LOOPBACK listener ($p_del)" "$lst"

# --- AGE GATE ------------------------------------------------------------------
cand="$(fleet_reap_orphan_listeners dry 3600)"
[ -z "$cand" ] && ok "nothing younger than minage is a candidate" \
  || fail "the age gate let a seconds-old listener through" "$cand"

# --- DOCTOR (before) -------------------------------------------------------------
listen_line() { printf '%s\n' "$1" | grep -aE '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+listen[[:space:]]' | head -1; }
run_doctor() {
  HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    sh "$BIN/fleet-doctor.sh" 2>/dev/null
}
dout="$(run_doctor)"; dl="$(listen_line "$dout")"
case "$dl" in *WARN*) ok "doctor WARNs listen while a fleet orphan is on the LAN" ;;
  *) fail "doctor did not WARN listen" "$dl" ;; esac
printf '%s\n' "$dout" | grep -q "pid $p_root .*cwd=$FLEET_CLAUDE_TMP_ROOT" \
  && ok "the WARN names the pid and its cwd" \
  || fail "the WARN does not name pid $p_root + cwd" "$(printf '%s\n' "$dout" | grep -A5 ' listen ')"

# --- REAP --------------------------------------------------------------------------
out="$(fleet_reap_orphan_listeners kill 0)"
listening "$p_root" "$port_root" && fail "scratchpad-root listener still holds :$port_root" "$out"
listening "$p_del" "$port_del" && fail "deleted-worktree listener still holds :$port_del" "$out"
kill -0 "$p_root" 2>/dev/null && fail "scratchpad-root listener $p_root survived the reap" "$out"
ok "the sweep reaps both candidates and their ports are released"
kill -0 "$p_plain" 2>/dev/null && kill -0 "$p_exempt" 2>/dev/null \
  && ok "the unanchored and exempt listeners survive the sweep" \
  || fail "the sweep killed something outside its scope" "$out"

# --- DOCTOR (after) --------------------------------------------------------------
dout="$(run_doctor)"; dl="$(listen_line "$dout")"
printf '%s\n' "$dout" | grep -q "pid $p_root " && fail "doctor still names the reaped orphan" "$dl"
if [ -z "$(bash "$BIN/fleet-diskguard.sh" --listeners 2>/dev/null)" ]; then
  case "$dl" in *PASS*) ok "doctor's listen line returns to PASS once it is reaped" ;;
    *) fail "doctor did not return to PASS" "$dl" ;; esac
else
  ok "doctor no longer names the reaped orphan (another fleet listener is live on this box)"
fi

# --- TEARDOWN ------------------------------------------------------------------------
WT="$WORK/tree-scratch-5"; mkdir -p "$WT"
PAD="$FLEET_CLAUDE_TMP_ROOT/$(fleet_mangle_path "$WT")/11111111-2222-3333-4444-555555555555/scratchpad"
probe "$PAD" 127.0.0.1; p_pad="$PROBE_PID"; port_pad="$PROBE_PORT"
pf="$WORK/.sleep.pid"
( ( cd "$PAD" && exec sleep 60 ) >/dev/null 2>&1 & printf '%s' "$!" > "$pf" ) &
wait $! 2>/dev/null; p_sleep="$(cat "$pf")"; PROBES="$PROBES $p_sleep"
out="$(fleet_reap_worktree_listeners "$WT" 0)"
listening "$p_pad" "$port_pad" && fail "teardown left the scratchpad listener on :$port_pad" "$out"
has_pid "$p_pad" "$out" && ok "teardown reaps a listener in the worktree's session scratchpad" \
  || fail "teardown did not report the reaped listener" "$out"
kill -0 "$p_sleep" 2>/dev/null && ok "teardown leaves a non-listening orphan to the kept-worktree sweep" \
  || fail "teardown killed a non-listener ($p_sleep)" "$out"

# --- PANE ----------------------------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
  PANE_SOCK="$WORK/pane.sock"
  mkdir -p "$WORK/pane-issue-8"
  tmux -S "$PANE_SOCK" -f /dev/null new-session -d -s t -c "$WORK/pane-issue-8" \
    "exec python3 -c '$LISTEN_PY' 127.0.0.1 $WORK/.pane.port" 2>/dev/null
  i=0; while [ "$i" -lt 50 ] && [ ! -s "$WORK/.pane.port" ]; do i=$((i+1)); sleep 0.1; done
  p_pane="$(tmux -S "$PANE_SOCK" display-message -p -t t '#{pane_pid}' 2>/dev/null)"
  if [ -n "$p_pane" ] && [ -s "$WORK/.pane.port" ]; then
    cand="$(fleet_reap_orphan_listeners dry 0)"
    has_pid "$p_pane" "$cand" && fail "a listener under a live tmux pane ($p_pane) was a candidate" "$cand"
    out="$(fleet_reap_worktree_listeners "$WORK/pane-issue-8" 0)"
    kill -0 "$p_pane" 2>/dev/null && ok "a listener under a live pane is never reaped (sweep or teardown)" \
      || fail "teardown killed a live pane's listener" "$out"
  else
    printf 'skip PANE: private tmux did not come up\n'
  fi
else
  printf 'skip PANE: no tmux\n'
fi

printf 'orphan-listener-reap-selftest: %d checks passed\n' "$pass"
