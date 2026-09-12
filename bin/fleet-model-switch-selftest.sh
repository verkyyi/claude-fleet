#!/bin/bash
# fleet-model-switch-selftest.sh — hermetic tests for bin/fleet-model-switch.sh
# (issue #569: clear a per-model usage cap IN PLACE with `/model <fallback>`
# instead of the close + `--resume` dance #524 inherited from account rotation).
#
# Two layers:
#   1. PURE helpers, sourced: pane_model_of (read the model off Claude Code's
#      status line), model_matches (the alias grammar `opus` ↔ "Opus 5" that the
#      pane and fleet-account.sh's ledger must agree on) and switch_selected (the
#      candidate matrix: mid-turn refused, already-flipped refused, target ==
#      capped refused).
#   2. END-TO-END on a DEDICATED tmux server on its own -L label (never the live
#      server, issue #159) — it must be -L, not a -S shim, because the script
#      targets servers as `tmux -L <session>` and a trailing -L would override a
#      shim's -S — with a fake `claude` (a symlink to perl, so `comm` is `claude`
#      like the real binary, which is what fleet_pane_claude_pid matches) that:
#      • paints the per-model wall banner and a `◆ Fable 5.1  […]` status line;
#      • on a line containing `/model <x>` paints Claude Code's "Switch model?"
#        confirmation and waits;
#      • on the next bare Enter repaints the status line as `◆ Opus 5  […]`;
#      • records every line it was handed, so "nothing was typed" is provable.
#      A real unix-socket listener stands in for the session's peer inbox, so the
#      nudge is asserted to arrive over fleet_peer_send — the SendMessage channel,
#      NOT send-keys (#437/#513) — wrapped in the canonical cross-session envelope.
#      Cases: the happy flip (+ ledger row, @cc_model restamped, nudge delivered),
#      a mid-turn window left untouched, an already-flipped window left untouched,
#      a fallback that is itself capped on the account, and --dry-run.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/fleet-model-switch.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

CHECKS=0
fail() { printf 'fleet-model-switch selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '  got: %s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
eq()   { ok; [ "$2" = "$3" ] || fail "$1 — expected [$2]" "[$3]"; }
has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-model-switch-selftest.XXXXXX")" || exit 2
export TMPDIR="$WORK"                                     # FLEET_C (the cap ledger)
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"; mkdir -p "$FLEET_ACCOUNTS_DIR"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_MAIN="$WORK/main"; mkdir -p "$FLEET_MAIN/.git"
# fleet-account.sh keeps the cap ledger under FLEET_C/global, and FLEET_C is
# $TMPDIR/.claude-dash — re-homed above, so this is the scratch copy.
CAPLEDGER="$WORK/.claude-dash/global/account.model-limited"
unset TMUX TMUX_PANE FLEET_ACCOUNTS FLEET_MODEL_FALLBACK
printf 'tokA-secret\n' > "$FLEET_ACCOUNTS_DIR/acctA"; chmod 600 "$FLEET_ACCOUNTS_DIR"/*

# ============================================================================
# 1. pure helpers
# ============================================================================
# shellcheck source=/dev/null
. "$SCRIPT"
command -v switch_selected >/dev/null 2>&1 || fail "switch_selected not defined after sourcing"

eq "pane_model_of: the meter form"   "Opus 5"    "$(pane_model_of '  ◆ Opus 5  [████░░░░░░] 38% 381k/1.0M  wt-9  ↯xhigh  $23.62')"
eq "pane_model_of: a dotted version" "Fable 5.1" "$(pane_model_of '  ◆ Fable 5.1  [███░░░░░░░] 29% 293k/1.0M  ai-voice-agent')"
eq "pane_model_of: last line wins"   "Opus 5"    "$(pane_model_of '  ◆ Fable 5.1  [█░] 9% x
  ◆ Opus 5  [█░] 9% x')"
eq "pane_model_of: no status line"   ""          "$(pane_model_of 'just some output')"

ok; model_matches opus  "Opus 5"    || fail "model_matches: opus ↔ Opus 5"
ok; model_matches fable "Fable 5.1" || fail "model_matches: fable ↔ Fable 5.1"
ok; model_matches FABLE "fable 5.1" || fail "model_matches: case-insensitive both ways"
ok; model_matches fable "Opus 5"    && fail "model_matches: fable must NOT match Opus 5"
ok; model_matches opus  ""          && fail "model_matches: empty pane model never matches"
ok; model_matches ""    "Opus 5"    && fail "model_matches: empty alias never matches"

sel() { ok; switch_selected "$2" "$3" "$4" "$5" || fail "$1 — expected a candidate"; }
nsel(){ ok; switch_selected "$2" "$3" "$4" "$5" && fail "$1 — expected NOT a candidate"; }
#     desc                              state     pane-model    capped  target
sel  "walled + idle"                    -         "Fable 5.1"   fable   opus
sel  "walled + done"                    "done"    "Fable 5.1"   fable   opus
sel  "walled + needs"                   needs     "Fable 5.1"   fable   opus
nsel "mid-turn is never typed into"     working   "Fable 5.1"   fable   opus
nsel "already flipped off the cap"      "done"    "Opus 5"      fable   opus
nsel "target IS the capped model"       "done"    "Fable 5.1"   fable   fable
nsel "target is a version of the cap"   "done"    "Fable 5.1"   fable   "fable 5"
nsel "no target (fallback switched off)" "done"   "Fable 5.1"   fable   ""
nsel "no status line to verify against" "done"    ""            fable   opus

printf 'fleet-model-switch selftest: %s pure checks passed\n' "$CHECKS"

# ============================================================================
# 2. end-to-end on a dedicated tmux server
# ============================================================================
command -v tmux >/dev/null 2>&1 || { printf 'fleet-model-switch selftest: tmux absent — pure layer only\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'fleet-model-switch selftest: perl absent — pure layer only\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-model-switch selftest: python3 absent — pure layer only\n'; exit 0; }

LBL="fms-selftest-$$"
BINSH="$WORK/fakebin"; mkdir -p "$BINSH"
cleanup() {
  tmux -L "$LBL" kill-server 2>/dev/null
  [ -n "${INBOX_PID:-}" ] && kill "$INBOX_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- the fake `claude` ---------------------------------------------------------
cat > "$WORK/fake-claude.pl" <<'PERL'
$| = 1;
my $log = $ENV{FAKE_LOG};
my $model = $ENV{FAKE_MODEL} || "Fable 5.1";
my $wall  = $ENV{FAKE_WALL};
sub paint { printf("  \x{25c6} %s  [\x{2588}\x{2588}\x{2591}\x{2591}] 30%% 300k/1.0M  wt  \x{21af}xhigh  \$1.00\n", $model); }
binmode(STDOUT, ":utf8");
print "fake claude up\n";
print "  \x{23bf}  You've reached your $wall limit. Run /usage-credits to continue or switch models with /model.\n" if $wall;
paint();
my $pending = "";
while (my $l = <STDIN>) {
  chomp $l;
  my $fh;
  if (open($fh, '>>', $log)) { print $fh "$l\n"; close $fh; }
  if ($l =~ m{/model\s+([A-Za-z0-9.\-]+)}) {
    $pending = $1;
    print "   Switch model?\n   \x{25b8} 1. Yes, switch to \u$pending\n";
    next;
  }
  if ($pending ne "") {
    # Enter on the confirmation → the real CLI repaints the status line.
    $model = ($pending =~ /^opus/i) ? "Opus 5" : ($pending =~ /^sonnet/i ? "Sonnet 5" : "\u$pending");
    $pending = "";
    paint();
    next;
  }
}
PERL
ln -sf "$(command -v perl)" "$BINSH/claude"

# --- the fake peer inbox: a real unix socket, so fleet_peer_send is exercised --
INBOX_DIR="$WORK/socks"; mkdir -p "$INBOX_DIR"
INBOX_LOG="$WORK/inbox.ndjson"
: > "$INBOX_LOG"
INBOX_SOCK="$INBOX_DIR/inbox.sock"
python3 - "$INBOX_SOCK" "$INBOX_LOG" <<'PY' &
import os, socket, sys
path, log = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except OSError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); s.listen(8)
while True:
    c, _ = s.accept()
    buf = b""
    while True:
        b = c.recv(65536)
        if not b: break
        buf += b
    c.close()
    with open(log, "ab") as fh: fh.write(buf)
PY
INBOX_PID=$!
# off the job table, or bash prints "Terminated: 15" over the summary when the
# EXIT trap reaps it
disown "$INBOX_PID" 2>/dev/null || :
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$INBOX_SOCK" ] && break; sleep 0.3; done
[ -S "$INBOX_SOCK" ] || fail "the fake peer inbox socket never appeared"

# --- a window running the fake claude, registered like the real CLI ------------
# spawn_worker <window-name> <wall-model|''> <start-model> — sets $WID.
# NOT a command substitution on purpose: `fail` must be able to exit the whole
# selftest, and inside `$( )` its exit would only kill the subshell.
WID=""
spawn_worker() {
  local name="$1" wall="$2" start="$3" pid=""
  : > "$WORK/typed.$name"
  tmux -L "$LBL" new-window -d -n "$name" -c "$WORK" \
    "FAKE_LOG='$WORK/typed.$name' FAKE_WALL='$wall' FAKE_MODEL='$start' PATH='$BINSH:$PATH' exec claude '$WORK/fake-claude.pl'" 2>/dev/null
  WID=$(tmux -L "$LBL" list-windows -F '#{window_id} #{window_name}' | awk -v n="$name" '$2==n{print $1; exit}')
  [ -n "$WID" ] || fail "could not create window $name"
  tmux -L "$LBL" set-window-option -t "$WID" @cc_account acctA 2>/dev/null
  tmux -L "$LBL" set-window-option -t "$WID" @cc_model fable 2>/dev/null
  # the Claude Code registry + peer key the script's helpers read. The fake is
  # exec'd BY the pane's shell, so it IS the pane pid — fleet_pane_claude_pid is
  # the one that knows that (a bare `pgrep -P` finds nothing).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid=$(fleet_pane_claude_pid "$WID" "$LBL" 2>/dev/null) && [ -n "$pid" ] && break
    sleep 0.3
  done
  [ -n "$pid" ] || fail "no fake claude under $name"
  printf '{"sessionId":"sid-%s","messagingSocketPath":"%s"}\n' "$name" "$INBOX_SOCK" > "$FLEET_CC_SESSIONS_DIR/$pid.json"
  printf '{"peerToken":"tok-%s"}\n' "$name" > "$FLEET_CC_SESSIONS_DIR/$pid.deadbeef.key"
}

tmux -L "$LBL" new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
spawn_worker walled    Fable "Fable 5.1"; W_OK="$WID"
spawn_worker busy      Fable "Fable 5.1"; W_BUSY="$WID"
spawn_worker recovered Fable "Opus 5";    W_DONE="$WID"
: "$W_DONE"
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state working 2>/dev/null
sleep 1

RUN() { FLEET_MODEL_SWITCH_VERIFY=12 "$SCRIPT" --session "$LBL" --no-fallback "$@" 2>&1; }

# --- --dry-run touches nothing ------------------------------------------------
out=$(RUN --capped --model opus --dry-run)
ok; has 'would:' "$out" || fail "--dry-run should print a plan" "$out"
eq "--dry-run types nothing" "" "$(cat "$WORK/typed.walled")"
eq "--dry-run writes no ledger row" "" "$(cat "$CAPLEDGER" 2>/dev/null)"

# --- the real pass ------------------------------------------------------------
out=$(RUN --capped --model opus)
ok; has '1 switched' "$out" || fail "expected exactly the walled window to switch" "$out"
ok; has "$W_OK" "$out" || fail "the walled window should be named in the report" "$out"

typed=$(cat "$WORK/typed.walled")
ok; has '/model opus' "$typed" || fail "the walled pane should have been handed /model opus" "$typed"
eq "the busy pane was never typed into"      "" "$(cat "$WORK/typed.busy")"
eq "the recovered pane was never typed into" "" "$(cat "$WORK/typed.recovered")"

ok; has 'mid-turn' "$out" || fail "the working window should be reported as mid-turn" "$out"
ok; has 'already off fable' "$out" || fail "the flipped window should be reported as already off the cap" "$out"

eq "@cc_model restamped to the new model" "opus" "$(tmux -L "$LBL" display-message -p -t "$W_OK" '#{@cc_model}')"
ok; has 'Opus 5' "$(tmux -L "$LBL" capture-pane -p -t "$W_OK")" || fail "the pane's status line should now read Opus 5"

led=$(cat "$CAPLEDGER" 2>/dev/null)
ok; has $'acctA\tfable' "$led" || fail "the (account, model) cap should be recorded for the spawn path" "$led"

# --- the nudge went over the peer inbox, not the keyboard ---------------------
inbox=$(cat "$INBOX_LOG")
ok; has 'cross-session-message' "$inbox" || fail "the nudge must ride the canonical peer envelope" "$inbox"
ok; has 'fleet-model-switch' "$inbox" || fail "the nudge must name its sender" "$inbox"
ok; has 'IN PLACE' "$inbox" || fail "the default nudge should say the switch was in place" "$inbox"
ok; has 'opus' "$inbox" || fail "__MODEL__ should be substituted in the nudge" "$inbox"
ok; has 'tok-walled' "$inbox" || fail "the auth frame should carry the session's peer token" "$inbox"
ok; has '/model' "$(cat "$WORK/typed.walled")" || fail "sanity: keystrokes are recorded"
ok; grep -q 'cross-session-message' "$WORK/typed.walled" && fail "the NUDGE must never be typed into the pane"

# --- a fallback that is itself capped on the account is refused ---------------
spawn_worker walled2 Fable "Fable 5.1"
"$BIN/fleet-account.sh" model-limited acctA opus "reached your Opus limit" >/dev/null 2>&1
out=$(RUN --capped --model opus)
ok; has 'ALSO capped' "$out" || fail "a capped fallback must be refused, not flipped onto" "$out"
eq "nothing typed when the fallback is capped too" "" "$(cat "$WORK/typed.walled2")"
"$BIN/fleet-account.sh" model-clear acctA opus >/dev/null 2>&1
out=$(RUN --capped --model opus)
ok; has '1 switched' "$out" || fail "once the fallback clears, the window switches" "$out"
ok; has '/model opus' "$(cat "$WORK/typed.walled2")" || fail "walled2 should have been switched"

# --- panels and the hub are never touched ------------------------------------
eq "the dash panel was never typed into" "" "$(cat "$WORK/typed.dash" 2>/dev/null)"

printf 'fleet-model-switch selftest: OK (%s checks)\n' "$CHECKS"
exit 0
