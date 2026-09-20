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
#      a window pinned at @claude_state=working by the Stop hook the cap never fired
#      (switched — the #569 blocker), a GENUINELY live turn left untouched, a cap the
#      ledger knows but the scrollback has lost (switched, silently), an
#      already-flipped window left untouched, a fallback that is itself capped on the
#      account, and --dry-run.
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
# The #706 rewrite dropped the `printf | sed | tail` (three forks, once per window,
# inside a probe whose whole bug was its fork count) for parameter expansion plus
# one bash ERE. These pin the grammar it must NOT have loosened on the way — each
# is a shape the old sed refused, and a looser reader would hand back a bogus
# model name, which is a `/model` typed at a window that never needed one.
eq "pane_model_of: no column gap"    ""          "$(pane_model_of '  ◆ Opus 5 [█░] 9%')"
eq "pane_model_of: name must start alnum" ""    "$(pane_model_of '  ◆ -weird  [█░] 9%')"
eq "pane_model_of: no name after the diamond" "" "$(pane_model_of '  ◆   [█░] 9%')"
eq "pane_model_of: diamond at the very end" ""  "$(pane_model_of 'some output ◆ ')"
eq "pane_model_of: gap on a LATER line does not rescue an earlier diamond" "" "$(pane_model_of '  ◆ Opus 5
next  line  here')"

# _lc — the fork-free lowercase that replaced `printf | tr` on the same hot path.
command -v _lc >/dev/null 2>&1 || fail "_lc not defined after sourcing"
_lc "Fable";   eq "_lc: a model name"        "fable"     "$_LC"
_lc "Opus 5";  eq "_lc: digits and spaces"   "opus 5"    "$_LC"
_lc "";        eq "_lc: empty in, empty out" ""          "$_LC"
_lc "a*b?c";   eq "_lc: glob chars stay literal" "a*b?c" "$_LC"
_lc "5.1";     eq "_lc: nothing to fold"     "5.1"       "$_LC"

# #674: the ledger hot path needs neither external commands nor a subshell, and
# both hits and misses persist in the parent shell. Changing the file between
# calls makes an ineffective `$(ledger_until ...)` cache observable without a
# wall-clock assertion that flakes when the machine is busy.
mkdir -p "${CAPLEDGER%/*}"
printf 'acctA\tfable\t2300\tcap\n' > "$CAPLEDGER"
PATH=/nonexistent ledger_until acctA Fable 1000
eq "ledger: builtin-only first read" 2300 "$LEDGER_UNTIL"
PATH=/nonexistent ledger_until acctA opus 1000
eq "ledger: uncapped result" 0 "$LEDGER_UNTIL"
printf 'acctA\tfable\t2400\tnew cap\nacctA\topus\t2500\tnew cap\n' > "$CAPLEDGER"
PATH=/nonexistent ledger_until acctA fable 1000
eq "ledger: hit is memoized across calls and query case" 2300 "$LEDGER_UNTIL"
PATH=/nonexistent ledger_until acctA opus 1000
eq "ledger: miss is memoized too" 0 "$LEDGER_UNTIL"
PATH=/nonexistent ledger_until acctB fable 1000
eq "ledger: account is part of the cache key" 0 "$LEDGER_UNTIL"
_LEDGER_MEMO="|"
PATH=/nonexistent ledger_until acctA fable 1000
eq "ledger: a new probe sees the updated cap" 2400 "$LEDGER_UNTIL"
PATH=/nonexistent ledger_until '' fable 1000
eq "ledger: empty account resets the output" 0 "$LEDGER_UNTIL"
PATH=/nonexistent ledger_until acctA '' 1000
eq "ledger: empty model resets the output" 0 "$LEDGER_UNTIL"
rm -f "$CAPLEDGER"
_LEDGER_MEMO="|"

ok; model_matches opus  "Opus 5"    || fail "model_matches: opus ↔ Opus 5"
ok; model_matches fable "Fable 5.1" || fail "model_matches: fable ↔ Fable 5.1"
ok; model_matches FABLE "fable 5.1" || fail "model_matches: case-insensitive both ways"
ok; model_matches fable "Opus 5"    && fail "model_matches: fable must NOT match Opus 5"
ok; model_matches opus  ""          && fail "model_matches: empty pane model never matches"
ok; model_matches ""    "Opus 5"    && fail "model_matches: empty alias never matches"

command -v cap_settled >/dev/null 2>&1 || fail "cap_settled not defined after sourcing"

# cap_settled — the gate that tells a LIVE turn apart from a turn the cap already
# ended. Regression cover for the #569 blocker: a per-model cap aborts the turn
# without a Stop hook, so @claude_state stays `working` and the mid-turn guard
# deferred the sweep's own candidates on every tick, forever.
#                                              vis  state_ts  now   stale
ok; cap_settled 1 1000 2000 120 || fail "cap_settled: cap on screen + 1000s stale is settled"
ok; cap_settled 1 1900 2000 120 && fail "cap_settled: a 100s-old stamp is still inside the guard"
ok; cap_settled 1 2000 2000 120 && fail "cap_settled: a stamp from right now is never settled"
ok; cap_settled 0 1000 2000 120 && fail "cap_settled: no cap on the VISIBLE screen → never settled"
ok; cap_settled 1 ''   2000 120 && fail "cap_settled: a missing stamp is refused, not assumed stale"
ok; cap_settled 1 abc  2000 120 && fail "cap_settled: a garbage stamp is refused"
ok; cap_settled 1 1000 2000 0   && fail "cap_settled: stale-secs 0 disables the lift (the #101 idiom)"
ok; cap_settled 1 1000 2000 ''  || fail "cap_settled: empty stale-secs falls back to the 120s default"
ok; cap_settled 1 1000 1000 120 && fail "cap_settled: a stamp in the future is never settled"

sel() { ok; switch_selected "$2" "$3" "$4" "$5" "${6:-0}" || fail "$1 — expected a candidate"; }
nsel(){ ok; switch_selected "$2" "$3" "$4" "$5" "${6:-0}" && fail "$1 — expected NOT a candidate"; }
#     desc                              state     pane-model    capped  target   settled
sel  "walled + idle"                    -         "Fable 5.1"   fable   opus
sel  "walled + done"                    "done"    "Fable 5.1"   fable   opus
sel  "walled + needs"                   needs     "Fable 5.1"   fable   opus
nsel "a LIVE turn is never typed into"  working   "Fable 5.1"   fable   opus     0
sel  "working pinned by the missed Stop hook IS taken" \
                                        working   "Fable 5.1"   fable   opus     1
nsel "already flipped off the cap"      "done"    "Opus 5"      fable   opus
nsel "already flipped, even when settled" \
                                        working   "Opus 5"      fable   opus     1
nsel "target IS the capped model"       "done"    "Fable 5.1"   fable   fable
nsel "target IS the capped model, even when settled" \
                                        working   "Fable 5.1"   fable   fable    1
nsel "target is a version of the cap"   "done"    "Fable 5.1"   fable   "fable 5"
nsel "no target (fallback switched off)" "done"   "Fable 5.1"   fable   ""
nsel "no target, even when settled"     working   "Fable 5.1"   fable   ""       1
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
spawn_worker stuck     Fable "Fable 5.1"; W_STUCK="$WID"
spawn_worker recovered Fable "Opus 5";    W_DONE="$WID"
: "$W_DONE"
NOWS=$(date +%s)
# `busy` is a GENUINELY live turn: @claude_state working with a stamp from just
# now, which is what a session mid-tool-call looks like. It must never be typed
# into — an Escape there cancels real work.
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state working 2>/dev/null
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state_ts "$NOWS" 2>/dev/null
# `stuck` is what a REAL per-model cap leaves behind, and the case this selftest
# used to get wrong: the cap aborted the turn without a Stop hook, so the window is
# pinned at `working` with the stamp frozen at the moment of the abort. The old
# fixture set `working` with no stamp at all and asserted the window was skipped —
# i.e. it asserted the production bug as correct, which is exactly why #570 shipped
# green while nine walled workers idled. It must be SWITCHED.
tmux -L "$LBL" set-window-option -t "$W_STUCK" @claude_state working 2>/dev/null
tmux -L "$LBL" set-window-option -t "$W_STUCK" @claude_state_ts "$((NOWS - 600))" 2>/dev/null
sleep 1

RUN() { FLEET_MODEL_SWITCH_VERIFY=12 "$SCRIPT" --session "$LBL" --no-fallback "$@" 2>&1; }

# --- --dry-run touches nothing ------------------------------------------------
out=$(RUN --capped --model opus --dry-run)
ok; has 'would:' "$out" || fail "--dry-run should print a plan" "$out"
# The batched window read must not SHIFT its columns (issue #706). Five
# `display-message` per window became one `list-windows -F` with tab-separated
# fields, and tab is IFS whitespace — so a `read -r a b c …` split would COLLAPSE
# runs of empty fields, and every column after the first empty one would shift by
# one. A worker window is full of them: @hub, @claude_state and @claude_state_ts
# are all unset on an idle worker — three empties in a row ahead of @cc_account.
# The account is the visible end of that chain, so a collapsed split shows up here
# as a missing `[acctA]` on the plan line.
ok; has '[acctA]' "$out" || fail "the batched window read must survive three empty option columns ahead of @cc_account" "$out"
eq "--dry-run types nothing" "" "$(cat "$WORK/typed.walled")"
eq "--dry-run writes no ledger row" "" "$(cat "$CAPLEDGER" 2>/dev/null)"

# --- the real pass ------------------------------------------------------------
out=$(RUN --capped --model opus)
ok; has '2 switched' "$out" || fail "expected the walled AND the stop-hook-pinned window to switch" "$out"
ok; has "$W_OK" "$out" || fail "the walled window should be named in the report" "$out"
ok; has "$W_STUCK" "$out" || fail "the stop-hook-pinned window should be named in the report" "$out"

typed=$(cat "$WORK/typed.walled")
ok; has '/model opus' "$typed" || fail "the walled pane should have been handed /model opus" "$typed"
ok; has '/model opus' "$(cat "$WORK/typed.stuck")" || fail "a window pinned at working by the missed Stop hook must still be flipped" "$(cat "$WORK/typed.stuck")"
# A5: the settled walled turn is recorded `done` (its turn ended on the cap, no
# Stop) rather than left a false `working` for the demoters to clear later.
eq "the settled walled window is recorded done, not left working" "done" "$(tmux -L "$LBL" display-message -p -t "$W_STUCK" '#{@claude_state}')"
eq "the genuinely-busy pane was never typed into" "" "$(cat "$WORK/typed.busy")"
eq "the recovered pane was never typed into" "" "$(cat "$WORK/typed.recovered")"

ok; has 'mid-turn' "$out" || fail "the genuinely-working window should be reported as mid-turn" "$out"
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

# --- a cap the LEDGER knows but the scrollback has lost ----------------------
# The banner is ephemeral: it scrolls past $SCROLL, and a session that was merely
# IDLE when the cap landed never printed one at all. The (account, model) ledger
# row is the durable fact, so --capped consults it when no banner is on screen.
# On 2026-09-12 six monorepo windows sat on fable for hours, with the cap recorded
# and 7 days left to run, for exactly this reason.
spawn_worker ledgeronly '' "Fable 5.1"; W_LED="$WID"
# keep `busy` a LIVE turn for this pass too, so the count cannot drift with how
# long the selftest has been running
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state_ts "$(date +%s)" 2>/dev/null
sleep 1
ok; has $'acctA\tfable' "$(cat "$CAPLEDGER" 2>/dev/null)" || fail "precondition: the fable cap row should already be on the ledger"
eq "the ledger-only pane shows no banner" "" "$(tmux -L "$LBL" capture-pane -p -t "$W_LED" | grep -c 'reached your' | tr -d ' ' | sed 's/^0$//')"

out=$(RUN --capped --model opus --dry-run)
ok; has 'via ledger' "$out" || fail "a ledger detection should say so in the plan" "$out"
ok; has "$W_LED" "$out" || fail "the banner-less window on a ledger-capped model should be planned" "$out"

# Repeat a real candidate in dry-run mode: each pair is read ONCE even with many
# windows, and the call sites must not quietly reintroduce the subshell that lost
# the old memo. Count operations, not elapsed seconds (#674).
FLEET_MODEL_SWITCH_VERIFY=12 bash -x "$SCRIPT" --session "$LBL" --no-fallback \
  --model opus --dry-run "$W_LED" "$W_LED" "$W_LED" "$W_LED" \
  > "$WORK/ledger.plan" 2> "$WORK/ledger.xtrace"
eq "ledger: every repeated candidate is visited" 4 "$(grep -c 'would:' "$WORK/ledger.plan")"
eq "ledger: repeated fallback pair reads the file once" 1 "$(grep -c '^+ fleet_model_limited_until ' "$WORK/ledger.xtrace")"
FLEET_MODEL_SWITCH_VERIFY=12 bash -x "$SCRIPT" --session "$LBL" --no-fallback \
  --model opus --capped --dry-run > "$WORK/ledger.plan" 2> "$WORK/ledger.xtrace"
eq "ledger: only two distinct pairs read the file" 2 "$(grep -c '^+ fleet_model_limited_until ' "$WORK/ledger.xtrace")"
eq "ledger: calls never run in command substitutions" 0 "$(grep -c '^++*+ ledger_until ' "$WORK/ledger.xtrace")"
eq "ledger: probe never starts the account CLI for reads" 0 "$(grep -c 'fleet-account.sh model-limited-until' "$WORK/ledger.xtrace")"

out=$(RUN --capped --model opus)
ok; has '1 switched' "$out" || fail "expected exactly the ledger-only window to switch" "$out"
ok; has '/model opus' "$(cat "$WORK/typed.ledgeronly")" || fail "the ledger-only pane should have been handed /model opus" "$(cat "$WORK/typed.ledgeronly")"
eq "the genuinely-busy pane is still never typed into" "" "$(cat "$WORK/typed.busy")"
# A ledger detection means the session was sitting at its prompt, not interrupted
# mid-turn — waking it to "continue the task" would spend tokens on a worker that
# may well be finished. The model flips silently instead.
ok; grep -q 'tok-ledgeronly' "$INBOX_LOG" && fail "a ledger-only flip must NOT nudge the session" "$(cat "$INBOX_LOG")"

# --- a fallback that is itself capped on the account is refused ---------------
spawn_worker walled2 Fable "Fable 5.1"
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state_ts "$(date +%s)" 2>/dev/null
"$BIN/fleet-account.sh" model-limited acctA opus "reached your Opus limit" >/dev/null 2>&1
out=$(RUN --capped --model opus)
ok; has 'ALSO capped' "$out" || fail "a capped fallback must be refused, not flipped onto" "$out"
eq "nothing typed when the fallback is capped too" "" "$(cat "$WORK/typed.walled2")"
"$BIN/fleet-account.sh" model-clear acctA opus >/dev/null 2>&1
out=$(RUN --capped --model opus)
ok; has '1 switched' "$out" || fail "once the fallback clears, the window switches" "$out"
ok; has '/model opus' "$(cat "$WORK/typed.walled2")" || fail "walled2 should have been switched"

# --- the batched pane→Claude walk (issue #706) ------------------------------
# fleet_pane_claude_pid now wraps fleet_pane_claude_pids, so there is ONE walk to
# keep correct; the batch form is what made the probe affordable (a `ps` plus two
# forked `awk`s per tree NODE, per window, was 4.3 s of its 12 s). The pair must
# agree window for window — including on a pane with no Claude under it, which
# must print nothing rather than somebody else's pid.
bp=""
for w in "$W_OK" "$W_BUSY" "$W_STUCK" "$W_DONE"; do
  bp="$bp $(tmux -L "$LBL" display-message -p -t "$w" '#{pane_pid}' 2>/dev/null)"
done
# shellcheck disable=SC2086  # deliberate word-split: one pane pid per word
batch=$(fleet_pane_claude_pids $bp 2>/dev/null)
ok; [ "$(printf '%s\n' "$batch" | grep -c .)" = 4 ] || fail "the batch walk must resolve every one of the 4 fake-claude panes" "$batch"
for w in "$W_OK" "$W_BUSY" "$W_STUCK" "$W_DONE"; do
  pp=$(tmux -L "$LBL" display-message -p -t "$w" '#{pane_pid}' 2>/dev/null)
  one=$(fleet_pane_claude_pid "$w" "$LBL" 2>/dev/null)
  many=$(printf '%s\n' "$batch" | awk -v p="$pp" '$1==p{print $2}')
  ok; [ -n "$one" ] && [ "$one" = "$many" ] || fail "batch and single walk disagree for $w (single=$one batch=$many)"
done
# the dash panel runs `sleep 600`, not a Claude — it must resolve to nothing
dpp=$(tmux -L "$LBL" display-message -p -t dash '#{pane_pid}' 2>/dev/null)
ok; [ -z "$(fleet_pane_claude_pids "$dpp" 2>/dev/null)" ] || fail "a pane with no Claude must resolve to nothing, not to a neighbour"
ok; [ -z "$(fleet_pane_claude_pids 2>/dev/null)" ] || fail "no pids in, nothing out"

# --- the breadcrumb a tree-kill leaves behind (issue #706) -------------------
# fleet-quotawatch runs this probe under fleet_timebox and kills the tree at the
# budget, so nothing the probe prints survives a timeout. The trace file is the
# only thing that can answer "which step ate the 20s" — for 788 of 1136 live ticks
# the answer was simply unavailable.
TRACEF="$WORK/probe.trace"
FLEET_MODEL_SWITCH_TRACE="$TRACEF" RUN --capped --model opus --dry-run >/dev/null
[ -s "$TRACEF" ] || fail "FLEET_MODEL_SWITCH_TRACE must be written"
ok; has 'step=' "$(cat "$TRACEF")"  || fail "the breadcrumb must name the current step" "$(cat "$TRACEF")"
ok; has 'win='  "$(cat "$TRACEF")"  || fail "the breadcrumb must say how far into the sweep it got" "$(cat "$TRACEF")"
ok; has 'steps=' "$(cat "$TRACEF")" || fail "the breadcrumb must carry the per-step timings" "$(cat "$TRACEF")"
eq "a completed probe ends its breadcrumb at done" "step=done" "$(sed -n '1p' "$TRACEF")"
# …and the sweep must have actually visited every window, not stopped at the first.
ok; case "$(sed -n 's/^win=//p' "$TRACEF" | head -1)" in */*) ;; *) fail "win= must read i/N" "$(cat "$TRACEF")";; esac

# Without the variable there is no file and no cost — the trace is opt-in, because
# every step boundary would otherwise be a write on a path that exists to avoid I/O.
rm -f "$TRACEF"
RUN --capped --model opus --dry-run >/dev/null
[ ! -f "$TRACEF" ] || fail "the breadcrumb must be opt-in (no FLEET_MODEL_SWITCH_TRACE, no file)"
ok

# A cap recorded during this sweep must invalidate an earlier cached miss. Put a
# banner-less window before AND after the window that discovers the cap, with an
# empty ledger. Only the earlier one waits for the next sweep; the later one must
# switch silently in this sweep even though its pair was previously uncapped.
"$BIN/fleet-account.sh" model-clear >/dev/null 2>&1
spawn_worker beforecap '' "Fable 5.1"; W_BEFORE="$WID"
spawn_worker newcap Fable "Fable 5.1"; W_NEW="$WID"
spawn_worker aftercap '' "Fable 5.1"; W_AFTER="$WID"
tmux -L "$LBL" set-window-option -t "$W_BUSY" @claude_state_ts "$(date +%s)" 2>/dev/null
sleep 1
out=$(RUN --capped --model opus)
ok; has '2 switched' "$out" || fail "a newly recorded cap must reach the later ledger-only candidate" "$out"
ok; has "$W_NEW" "$out" && has "$W_AFTER" "$out" || fail "both new-cap and later ledger-only windows must switch" "$out"
eq "a window visited before the new cap waits until next sweep" "" "$(cat "$WORK/typed.beforecap")"
ok; has '/model opus' "$(cat "$WORK/typed.aftercap")" || fail "cached miss hid a cap written by this sweep"
ok; grep -q 'tok-aftercap' "$INBOX_LOG" && fail "the newly detected ledger-only window must not be nudged"
out=$(RUN --capped --model opus --dry-run)
ok; has "$W_BEFORE" "$out" || fail "the next sweep must pick up the earlier window" "$out"

# --- panels and the hub are never touched ------------------------------------
eq "the dash panel was never typed into" "" "$(cat "$WORK/typed.dash" 2>/dev/null)"

printf 'fleet-model-switch selftest: OK (%s checks)\n' "$CHECKS"
exit 0
