#!/bin/bash
# selftest-part: 1 guard sessmap account
# selftest-part: 2 phases overrun
# selftest-part: 3 git
# selftest-part: 4 issues
# selftest-part: 5 banner
# fleet-collect-tick-selftest.sh — the dash collector (tmux-dash-collect.sh), one
# case per theme, all in the one environment of selftest-collect-fixture.sh (T601).
# Args name the cases to run (default: all); each runs in a sandbox of its own.
#
#   guard    overlap guard + heartbeat (#551): skip a live tick, supersede a wedged
#            one, ignore a dead/recycled pid, `--issues` kicks past the guard
#   sessmap  sessmap write-guard (#203): discovery writes, stale flat mirrors are
#            pruned, an empty discovery never clobbers a good map, an empty global
#            map over good legacy rows is removed (un-shadow)
#   account  ph_banner heals @cc_account from the live process's token, never a
#            banner (T546); fleet-context.sh reads it; fleet-account-truth.py
#   phases   every phase budgeted, the tick budgeted, truncation rotates (#653, #725)
#   overrun  hubsess runs in the tick's fixed head: a tick that hits its budget
#            still stamps hubsess.want (the hub loop's life), hub off ⇒ nothing
#   git      no `git status`, a budget, round-robin, slow-log, cache sweep (#552, #647)
#   issues   a timed-out repo never monopolises the issues phase (#651, #1942)
#   banner   window-scaled budget, working-first rotation, heartbeat counts (#1588)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
. "$BIN/selftest-collect-fixture.sh"

case_guard() {
  cfx_sandbox guard; cfx_copy
  printf '#!/bin/bash\nsleep 300\n' > "$WORK/fakepath/tmux-dash-collect-holder"
  holder() { bash "$WORK/fakepath/tmux-dash-collect-holder" >/dev/null 2>&1 </dev/null & HOLDER=$!
             disown "$HOLDER"; CFX_PIDS="$CFX_PIDS $HOLDER"; sleep 0.2; }
  issues() { grep -c '^issue ' "$L/gh.log"; }

  cfx_run || cfx_fail "1: a full tick must exit 0"
  st_eq "1: phase=done after a clean tick" 'done' "$(cfx_hb phase)"
  [ -n "$(cfx_hb end)" ] && [ -n "$(cfx_hb dur)" ] || cfx_fail "1: end= and dur= written"
  ph=$(cfx_hb phases)
  st_hasnt "1: the retired quota watch is no phase" "$ph" quotawatch=
  st_has "1: phases= names issues" "$ph" issues=
  st_has "1: phases= names snapshot" "$ph" snapshot=
  [ ! -e "$G/collect.pid" ] || cfx_fail "1: collect.pid removed after a clean exit"
  grep -q sessA "$G/sessmap" || cfx_fail "1: sessmap written"

  holder; printf '%s\t%s\n' "$HOLDER" "$(date +%s)" > "$G/collect.pid"; printf 'SENTINEL\n' > "$G/sessmap"
  cfx_run || cfx_fail "2: a skipped tick must exit 0"
  grep -q 'skip — tick' "$L/err" || cfx_fail "2: a live holder under the deadline ⇒ skip line"
  st_eq "2: a skipped tick writes nothing" SENTINEL "$(cat "$G/sessmap")"
  st_eq "2: skip leaves the holder's pidfile" "$HOLDER" "$(cut -f1 "$G/collect.pid")"
  kill -0 "$HOLDER" 2>/dev/null || cfx_fail "2: skip must not kill the holder"

  printf '%s\t%s\n' "$HOLDER" "$(( $(date +%s) - 1000 ))" > "$G/collect.pid"
  cfx_run || cfx_fail "3: a superseding tick must exit 0"
  grep -q 'exceeded the 600s deadline' "$L/err" || cfx_fail "3: past the deadline ⇒ kill line"
  sleep 0.3; kill -0 "$HOLDER" 2>/dev/null && cfx_fail "3: the wedged holder must be TERMed"
  grep -q sessA "$G/sessmap" || cfx_fail "3: the superseding tick runs"
  [ ! -e "$G/collect.pid" ] || cfx_fail "3: pidfile removed after the superseding tick"

  printf '999999\t%s\n' "$(date +%s)" > "$G/collect.pid"; printf 'SENTINEL\n' > "$G/sessmap"
  cfx_run || cfx_fail "4: dead-holder tick must exit 0"
  grep -q sessA "$G/sessmap" || cfx_fail "4: a dead holder is taken over"
  sleep 300 >/dev/null 2>&1 & SLEEPER=$!; disown "$SLEEPER"; CFX_PIDS="$CFX_PIDS $SLEEPER"
  printf '%s\t%s\n' "$SLEEPER" "$(date +%s)" > "$G/collect.pid"; printf 'SENTINEL\n' > "$G/sessmap"
  cfx_run || cfx_fail "4b: recycled-pid tick must exit 0"
  grep -q skip "$L/err" && cfx_fail "4b: a live pid that is NOT a collector is no holder"
  grep -q sessA "$G/sessmap" || cfx_fail "4b: recycled pid ⇒ the tick runs"
  kill -0 "$SLEEPER" 2>/dev/null || cfx_fail "4b: an unrelated live process is never killed"

  holder; printf '%s\t%s\n' "$HOLDER" "$(date +%s)" > "$G/collect.pid"
  cfx_run --issues acme/widgets || cfx_fail "5: --issues kick must exit 0"
  st_eq "5: the kick fetches while a tick holds the pidfile" 1 "$(issues)"
  st_eq "5: the kick leaves the pidfile" "$HOLDER" "$(cut -f1 "$G/collect.pid")"
  st_ok "guard: heartbeat phases, skip, supersede, dead/recycled holder, --issues bypass (#551)"
}

case_sessmap() {
  cfx_sandbox sessmap; cfx_copy tmux-dash-collect.sh fleet-lib.sh fleet-client-core.sh
  run() { FAKE_DOWN="${1:-}" cfx_run || cfx_fail "collector exited non-zero"; }
  mkdir -p "$C"
  printf 'STALE alpha (other repo)\n' > "$C/issues"; : > "$C/issues.ts"
  printf 'STALE prmap\n' > "$C/prmap"; : > "$C/prmap.ts"; printf 'STALE labels\n' > "$C/labels"
  run ''
  grep -q sessA "$G/sessmap" || cfx_fail "1: sessmap lists sessA after discovery"
  grep -q acme/widgets "$G/sessmap" || cfx_fail "1: the row carries the resolved repo"
  for f in issues issues.ts prmap labels; do
    [ -e "$C/$f" ] && cfx_fail "2: stale flat \$C/$f must be pruned"
  done
  good=$(cat "$G/sessmap")
  run sessA   # down ⇒ discovery empty
  st_eq "3: an empty discovery keeps the good sessmap verbatim" "$good" "$(cat "$G/sessmap" 2>/dev/null)"
  : > "$G/sessmap"; printf 'sessL\tacme-legacy\tacme/legacy\n' > "$C/sessmap"
  run sessA
  [ -e "$G/sessmap" ] && cfx_fail "4: an empty global sessmap over good legacy rows is removed"
  grep -q sessL "$C/sessmap" || cfx_fail "4: the legacy flat sessmap is left intact"
  st_ok "sessmap: discovery+write, prune stale flat mirrors, write-guard, un-shadow (#203)"
}

case_account() {
  cfx_sandbox account
  cfx_copy fleet-lib.sh fleet-client-core.sh usage-lib.sh fleet-account-truth.sh fleet-account-truth.py \
    fleet-context.sh fleet_pending_tool.py fleet_native_proc.py fleet_agent_argv.py \
    fleet-codex-rpc.py fleet-codex-session.py
  rm -f "$WORK/accounts/a"; printf 'token-A\n' > "$WORK/accounts/acctA"; printf 'token-B\n' > "$WORK/accounts/acctB"
  cfx_extract "$WORK/phase.sh" atomic_write ph_banner banner_scan_one
  cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$TMLOG"
if [ "${1:-}" = -L ]; then [ "$2" = fixture ] || exit 1; shift 2; fi
case "$1" in
  list-windows)
    if [[ "$*" = *pane_pid* ]]; then
      pre=''; [[ "$*" = *'#{window_id}:#{session_id}:#{session_name} '* ]] && pre=1   # fleet_lw (#1489)
      printf '@1 %%1 101 acctB\n@2 %%2 102\n@3 %%3 103 acctB\n@4 %%4 104 acctB\n@5 %%5 105\n@6 %%6 106 acctB\n@7 %%7 107 acctA\n@8 %%8 108 acctB\n@9 %%9 109 acctB\n' \
        | if [ -n "$pre" ]; then awk '{ print $1 ":$0:fixture", $0 }'; else cat; fi
    else
      printf 'fixture:1\037@1\037acctB\nfixture:2\037@2\037\nfixture:3\037@3\037acctB\nfixture:4\037@4\037acctB\nfixture:5\037@5\037\n'
    fi ;;
  display-message)
    case "$*" in
      *session_name*) echo fixture ;;
      *pane_pid*) printf '@1 %%1 101\n' ;;
      *@ctx_pct*) echo 10 ;;
      *'-t @8 #{@migrated_banner}'*) echo 'Usage limit reached · continuing automatically at 1:50am · esc to cancel' ;;
      *'-t @9 #{@migrated_banner}'*) echo "hit your weekly limit · resets Sep 25 at 7am" ;;
    esac ;;
  capture-pane) case "$*" in *'%6'*|*'%7'*) exit 0 ;; esac; printf 'Usage limit reached · continuing automatically at 1:50am · esc to cancel\n' ;;
  set-window-option) : ;;
  *) exit 1 ;;
esac
FAKE
  cat > "$WORK/fakepath/ps" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$PSLOG"
[ "$*" = '-axo pid=,ppid=,stat=,lstart=,comm=' ] || exit 1
for pane in 101 102 103 104 105 106 107 108 109; do   # state + a 24-char C-locale birth
  agent=claude; [ "$pane" != 103 ] || agent=codex
  printf '%s 1 Ss Thu Oct 15 10:00:00 2026 zsh\n' "$pane"
  printf '%s %s S Thu Oct 15 10:00:00 2026 %s\n' "$((pane + 100))" "$pane" "$agent"
done
FAKE
  cat > "$WORK/fakepath/token-probe" <<'FAKE'
#!/bin/sh
case "$1" in 201|206|207) echo token-A ;; 202|203|208|209) echo token-B ;; 204) echo unregistered-token ;; 205) exit 1 ;; esac
FAKE
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$ACLOG"\n' > "$WORK/bin/fleet-account.sh"
  chmod +x "$WORK/fakepath/"* "$WORK/bin/fleet-account.sh"
  export PATH="$WORK/fakepath:$PATH" FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_CONF_DIR="$WORK/conf"
  export FLEET_TOKEN_PROBE="$WORK/fakepath/token-probe" TMPDIR="$WORK"
  export TMLOG="$WORK/tmux.log" PSLOG="$WORK/ps.log" ACLOG="$WORK/account.log"
  : > "$TMLOG"; : > "$PSLOG"; : > "$ACLOG"
  ( BIN="$WORK/bin"; . "$BIN/fleet-lib.sh"; . "$BIN/usage-lib.sh"; . "$WORK/phase.sh"
    export SOCKETS=fixture US=$'\037' G="$WORK/cache"; ph_banner ) > "$WORK/out" 2> "$WORK/err"
  [ ! -s "$ACLOG" ] || st_fail "a subscription banner reached fleet-account.sh (T546)" "$(cat "$ACLOG")"
  tl=$(cat "$TMLOG")
  st_has 'a stale stamp is healed on its own socket/pane' "$tl" '-L fixture set-window-option -t %1 @cc_account acctA'
  st_has 'an empty stamp is healed' "$tl" '-L fixture set-window-option -t %2 @cc_account acctB'
  st_has 'a quiet pane stamp is healed' "$tl" '-L fixture set-window-option -t %6 @cc_account acctA'
  st_hasnt 'a correct stamp writes nothing' "$tl" 'set-window-option -t %7'
  st_eq 'one canonical process walk' '-axo pid=,ppid=,stat=,lstart=,comm=' "$(cat "$PSLOG")"
  ! grep -Eq 'token-A|token-B|unregistered-token' "$WORK/out" "$WORK/err" "$TMLOG" "$ACLOG" || st_fail 'a token leaked to output'
  : > "$TMLOG"; : > "$PSLOG"
  TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh" --json \
    | python3 -c 'import json,sys; assert json.load(sys.stdin)["account"]=="acctA"' || st_fail 'context JSON lacks the verified account'
  out=$(TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh")
  case "$out" in *'account   acctA'*'process token'*) ;; *) st_fail 'context text lacks account provenance' "$out" ;; esac
  grep -q set-window-option "$TMLOG" && st_fail 'a context query mutated a stamp'
  st_eq 'context quiet verdict' OK "$(TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh" -q)"
  st_eq 'JSON/text read one batch each; quiet none' 2 "$(wc -l < "$PSLOG" | tr -d ' ')"
  st_eq 'context process query format' '-axo pid=,ppid=,stat=,lstart=,comm=' "$(sort -u "$PSLOG")"
  # Both production token readers; no host credentials are inspected.
  python3 - "$BIN/fleet-account-truth.py" "$WORK/accounts" <<'PY' || st_fail 'production token reader contracts failed'
import importlib.util, os, pathlib, subprocess, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('account_truth', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = dict(os.environ); env.pop('FLEET_TOKEN_PROBE', None)
text = '@1 %1 101\n@2 %2 102\n@3 %3 103\n---PROCESSES---\n101 201\n102 202\n103 203\n'
raw = (b'201 claude CLAUDE_CODE_OAUTH_TOKEN=token-A PATH=/bin\n'
       b'202 node /app/claude-code/cli.js CLAUDE_CODE_OAUTH_TOKEN=token-B\n'
       b'203 claude CLAUDE_CODE_OAUTH_TOKEN=not-registered\n'
       b'999 claude CLAUDE_CODE_OAUTH_TOKEN=token-A\n')
with patch.dict(os.environ, env, clear=True), patch.object(m.sys, 'platform', 'darwin'):
    with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, raw)) as run:
        assert m.resolve(text, sys.argv[2]) == [('@1', '%1', 'acctA', '1'), ('@2', '%2', 'acctB', '1')]
        assert run.call_count == 1, 'macOS environment probe must be batched'
        assert run.call_args.args[0][-1] == '201,202,203'
    with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 5)):
        assert m.resolve(text, sys.argv[2]) == [], 'timeout must not authorize attribution'
    with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, raw)):
        assert m.resolve(text, sys.argv[2]) == [], 'failed probe must not authorize attribution'
    def environ(path):
        if path == pathlib.Path('/proc/201/environ'):
            return b'PATH=/bin\0CLAUDE_CODE_OAUTH_TOKEN=token-A\0'
        raise PermissionError('unreadable')
    with patch.object(m.sys, 'platform', 'linux'), patch.object(m.Path, 'read_bytes', environ):
        assert m.resolve(text, sys.argv[2]) == [('@1', '%1', 'acctA', '1')]
# Ambiguous or excluded pool files never invent a verified label.
root = pathlib.Path(sys.argv[2])
(root / 'duplicate').write_text('token-A\n')
(root / '.hidden').write_text('not-registered\n')
(root / 'metadata.conf').write_text('not-registered\n')
with patch.object(m, 'process_tokens', return_value={201:b'token-A',203:b'not-registered'}):
    assert m.resolve(text, root) == []
# A hub-managed label (hub:<label>, #1415) answers for the marker AND its token (#1463).
(root / 'duplicate').unlink()
(root / 'hubbed').write_text('hub:hubbed\n')
(root / 'hubbed.hub').mkdir()
(root / 'hubbed.hub' / '.credentials.json').write_text('{"claudeAiOauth":{"accessToken":"token-H","refreshToken":null}}')
with patch.object(m, 'process_tokens', return_value={201:b'hub:hubbed',202:b'token-H'}):
    assert m.resolve(text, root) == [('@1', '%1', 'hubbed', '1'), ('@2', '%2', 'hubbed', '1')], m.resolve(text, root)
PY
  st_ok "account: heals stamps from the live process, never the screen; context; token readers"
}

case_phases() {
  # Case 4 runs every phase AHEAD of the wedge unbudgeted (0 = inline, no 1s poll
  # floor), so `git` meets the tick with all of it and `ctx` is the first phase
  # with no room — a fact of the mechanism, not the machine's speed (#725).
  cfx_sandbox phases; cfx_copy
  printf '%s\n%s\n' "$WORK/wt1" "$WORK/wt2" > "$WORK/panepaths"
  order() { cfx_hb phases | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' '; }
  pcur() { cat "$G/collect.phase.cursor" 2>/dev/null; }
  survivors() { sleep 2; pgrep -f "$CFX_HANG" 2>/dev/null | wc -l | tr -d ' '; }

  cfx_run || cfx_fail "1: a full tick must exit 0"
  st_eq "1: phase=done" 'done' "$(cfx_hb phase)"
  st_eq "1: the historical phase order" \
    'sockets guide sessmap issues git ctx usage scrape banner escalate agentcfg snapshot ' "$(order)"
  st_eq "1: over= empty on a clean tick" '' "$(cfx_hb over)"
  st_eq "1: skipped= empty on a clean tick" '' "$(cfx_hb skipped)"
  st_eq "1: a completed tick parks no cursor" '' "$(pcur)"
  grep -q acme/widgets "$G/collect.repoqueue" || cfx_fail "2: sessmap publishes the repo queue to disk"
  grep -q '^issue ' "$L/gh.log" || cfx_fail "2: issues fetches off the queue file"

  FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=3 FLEET_COLLECT_TICK_BUDGET=120 cfx_run \
    || cfx_fail "3: a wedged phase must not fail the tick"
  st_eq "3: phase=done with a wedged phase" 'done' "$(cfx_hb phase)"
  st_has "3: over= names the phase" " $(cfx_hb over) " ' git '
  st_eq "3: nothing deferred" '' "$(cfx_hb skipped)"
  grep -q 'phase git hit the 3s budget (FLEET_COLLECT_GIT_BUDGET)' "$L/err" || cfx_fail "3: stderr names phase, budget, knob"
  st_has "3: every later phase still runs" "$(order)" ' snapshot '
  st_eq "3: the wedged child is gone once the tick returns (#682)" 0 "$(survivors)"

  rm -f "$G/collect.phase.cursor"
  FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=20 FLEET_COLLECT_TICK_BUDGET=10 FLEET_COLLECT_SOCKETS_BUDGET=0 \
    FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail "4: a truncated tick must exit 0"
  st_eq "4: phase=done" 'done' "$(cfx_hb phase)"
  st_has "4: the wedge is in over=" " $(cfx_hb over) " ' git '
  clamp=$(sed -n 's/^fleet-collect: phase git hit the \([0-9]*\)s budget (FLEET_COLLECT_GIT_BUDGET).*/\1/p' "$L/err" | head -1)
  [ -n "$clamp" ] && [ "$clamp" -le 10 ] || cfx_fail "4: git's budget is CLAMPED to the tick's room (≤10s), got [${clamp}]"
  st_eq "4: skipped= is every phase after the wedge" 'ctx usage scrape banner escalate agentcfg snapshot' "$(cfx_hb skipped)"
  st_eq "4: the cursor parks on the first deferred phase" ctx "$(pcur)"
  grep -q 'tick hit its 10s budget (FLEET_COLLECT_TICK_BUDGET)' "$L/err" || cfx_fail "4: stderr says the tick budget was hit"

  FLEET_COLLECT_TICK_BUDGET=120 cfx_run || cfx_fail "5: the resuming tick must exit 0"
  st_eq "5: the tick resumes at the cursor and wraps" \
    'sockets ctx usage scrape banner escalate agentcfg snapshot guide sessmap issues git ' "$(order)"
  st_eq "5: a full round clears the cursor" '' "$(pcur)"
  st_ok "phases: per-phase · whole-tick clamp · rotation · heartbeat · repo queue (#653)"
}

case_overrun() {
  # The hub's refresh loop lives LOOP_SECS past its newest --ensure; the ensure
  # sat at the END of the rotating body, so every tick that hit its budget skipped
  # it (31 overruns on a node at load 27-43) and the loop died under ⌘P. It runs in
  # the tick's fixed head now: a truncated tick still stamps hubsess.want.
  cfx_sandbox overrun; cfx_copy
  printf '%s\n%s\n' "$WORK/wt1" "$WORK/wt2" > "$WORK/panepaths"
  # fleet-hub-sessions.sh --ensure's one write the collector depends on: the stamp
  cat > "$WORK/bin/fleet-hub-sessions.sh" <<'FAKE'
#!/bin/bash
printf '%s by=%s\n' "$*" "${FLEET_HUBSESS_BY:-}" >> "$FAKE_L/hubsess.calls"
[ "${1:-}" = --ensure ] && date +%s > "$TMPDIR/.claude-dash/global/hubsess.want"
exit 0
FAKE
  chmod +x "$WORK/bin/fleet-hub-sessions.sh"
  order() { cfx_hb phases | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' '; }
  # the fixture's login has no live socket: keep the loop regardless (#4261's skip)
  export FLEET_HUBSESS_IDLE_SKIP=0

  CCQUOTA_FLEET=1 cfx_run || cfx_fail "1: a full tick must exit 0"
  st_eq "1: hubsess runs in the head, right after sockets" \
    'sockets hubsess guide sessmap issues git ctx usage scrape banner escalate agentcfg snapshot ' "$(order)"
  [ -s "$G/hubsess.want" ] || cfx_fail "1: the head's --ensure stamped no hubsess.want"
  st_eq "1: one --ensure, named the collector's" '--ensure by=collector' "$(cat "$L/hubsess.calls")"

  rm -f "$G/hubsess.want" "$L/hubsess.calls" "$G/collect.phase.cursor"
  CCQUOTA_FLEET=1 FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=20 FLEET_COLLECT_TICK_BUDGET=10 FLEET_COLLECT_SOCKETS_BUDGET=0 \
    FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail "2: a truncated tick must exit 0"
  grep -q 'tick hit its 10s budget (FLEET_COLLECT_TICK_BUDGET)' "$L/err" || cfx_fail "2: the tick did not hit its budget"
  st_has "2: the body was cut short" " $(cfx_hb skipped) " ' snapshot '
  st_hasnt "2: hubsess is never deferred" " $(cfx_hb skipped) " ' hubsess '
  [ -s "$G/hubsess.want" ] || cfx_fail "2: a tick that hit its budget stamped no hubsess.want — the loop dies 70 s after the last one"
  st_has "2: the heartbeat still reports it" " $(order)" ' hubsess '

  rm -f "$G/hubsess.want" "$L/hubsess.calls" "$G/collect.phase.cursor"
  cfx_run || cfx_fail "3: a hub-off tick must exit 0"
  [ ! -e "$L/hubsess.calls" ] && [ ! -e "$G/hubsess.want" ] || cfx_fail "3: the hub off, yet --ensure ran"
  st_hasnt "3: the hub off — no hubsess on the heartbeat" " $(order)" ' hubsess '
  st_ok "overrun: hubsess in the head — a tick at its budget still stamps hubsess.want; hub off ⇒ nothing"
}

case_git() {
  # The slow worktree costs 3 calls × 3s = 9s against a 5s threshold: wide on both
  # sides of the `SECONDS` ±1s quantization (#693).
  cfx_sandbox git; cfx_copy
  WT1="$WORK/wt1"; WT2="$WORK/wt2"; WT3="$WORK/wt3"
  printf '%s\n%s\n%s\n' "$WT3" "$WT1" "$WT2" > "$WORK/panepaths"   # unsorted on purpose
  export GH_TTL=999999 FLEET_COLLECT_GIT_BUDGET=30 FLEET_COLLECT_GIT_SLOW=10
  gk() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }   # == cache_key()
  cache() { cat "$G/git_$(gk "$1")" 2>/dev/null; }
  cursor() { cat "$G/collect.git.cursor" 2>/dev/null; }
  git_order() { cut -f1 "$L/git.log" | awk 'NF && $0!=prev{print; prev=$0}' | tr '\n' ' '; }
  br() { printf 'b-%s+2-1\t' "${1##*/}"; }

  ( cfx_lane lane5
    FAKE_GIT_SLOW=/wt2 FAKE_GIT_SLOW_SECS=3 FLEET_COLLECT_GIT_SLOW=5 cfx_run || cfx_fail "5: the tick must exit 0"
    grep -q "git took .*s on $WT2" "$L/err" || cfx_fail "5: a slow worktree is named on stderr"
    grep -q "git took .*s on $WT3" "$L/err" && cfx_fail "5: a fast worktree is not logged as slow"
    st_ok "git 5: slow-log" ) > "$WORK/lane5.log" 2>&1 & L5=$!
  ( cfx_lane lane34
    printf '%s' "$WT3" > "$G/collect.git.cursor"   # ⇒ this tick starts at wt1
    FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=2 cfx_run || cfx_fail "3: the tick exits 0 with a wedged worktree"
    grep -q 'hit the 2s budget' "$L/err" || cfx_fail "3: stderr names the blown budget"
    st_eq "3: a blown git budget does not abort the tick" 'done' "$(cfx_hb phase)"
    st_eq "3: the cursor names the wedged worktree" "$WT1" "$(cursor)"
    st_eq "3: worktrees behind the wedge are not reached" '' "$(cache "$WT2")"
    FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=2 cfx_run || cfx_fail "4: the follow-up tick exits 0"
    st_eq "4: wt2 refreshes the tick after the wedge" "$(br "$WT2")" "$(cache "$WT2")"
    st_eq "4: wt3 refreshes the tick after the wedge" "$(br "$WT3")" "$(cache "$WT3")"
    st_eq "4: the wedged worktree stays uncached" '' "$(cache "$WT1")"
    st_ok "git 3-4: budget, round-robin under a permanent wedge" ) > "$WORK/lane34.log" 2>&1 & L34=$!

  cfx_run || cfx_fail "1: a full tick must exit 0"
  grep -q status "$L/git.log" && cfx_fail "1: the git phase never runs \`git status\`"
  for wt in "$WT1" "$WT2" "$WT3"; do st_eq "1: $wt cached as branch+ahead-behind<TAB>" "$(br "$wt")" "$(cache "$wt")"; done
  st_has "1: phases= names git" "$(cfx_hb phases)" git=
  st_eq "1: phase=done" 'done' "$(cfx_hb phase)"
  st_eq "1: the cursor parks on the last worktree" "$WT3" "$(cursor)"
  printf '%s' "$WT1" > "$G/collect.git.cursor"
  cfx_run || cfx_fail "2: a full tick must exit 0"
  st_eq "2: the scan resumes after the cursor and wraps" "$WT2 $WT3 $WT1 " "$(git_order)"

  WT4="$WORK/other space_under_score"; DEAD="$WORK/other/space_under_score"
  mkdir -p "$WORK/conf/fleets/sessB" "$DEAD"; : > "$WORK/conf/fleets/sessB/conf"
  fx_repo "$WORK/conf" sessB acme/other
  printf '%s\n' "$WT4" > "$WORK/otherpaths"
  seed_dead() { printf 'stale-git' > "$G/git_$(gk "$DEAD")"; printf 'stale-ctx' > "$G/ctx_$(gk "$DEAD")"; }
  dead_kept() { [ -f "$G/git_$(gk "$DEAD")" ] && [ -f "$G/ctx_$(gk "$DEAD")" ]; }
  dead_gone() { [ ! -e "$G/git_$(gk "$DEAD")" ] && [ ! -e "$G/ctx_$(gk "$DEAD")" ]; }
  for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do printf 'live-ctx' > "$G/ctx_$(gk "$wt")"; done
  printf 'native-ctx' > "$G/ctx_codex_sessB_1_2_session"; printf 'unrelated' > "$G/git_unrelated"
  printf 'outside' > "$WORK/outside"; ln -s "$WORK/outside" "$G/ctx_$(gk "$WORK/symlink")"
  mkdir "$G/git_$(gk "$WORK/directory")"; printf 'pending' > "$G/git_$(gk "$WT4").123"
  seed_dead
  cfx_run || cfx_fail '6: sweep tick must succeed'
  dead_gone || cfx_fail '6: inactive worktree caches survived a complete inventory'
  for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do
    st_eq '6: a live context cache stays' live-ctx "$(cat "$G/ctx_$(gk "$wt")")"
    [ -s "$G/git_$(gk "$wt")" ] || cfx_fail '6: a live git cache was lost'
  done
  st_eq '6: native session cache kept' native-ctx "$(cat "$G/ctx_codex_sessB_1_2_session")"
  st_eq '6: an unrelated key kept' unrelated "$(cat "$G/git_unrelated")"
  [ -L "$G/ctx_$(gk "$WORK/symlink")" ] && [ "$(cat "$WORK/outside")" = outside ] || cfx_fail '6: followed or removed a symlink'
  [ -d "$G/git_$(gk "$WORK/directory")" ] || cfx_fail '6: removed a directory'
  st_eq '6: a live atomic-write temporary kept' pending "$(cat "$G/git_$(gk "$WT4").123")"
  # An earlier socket failing then a later one succeeding must not authorize a sweep.
  seed_dead
  for mode in failed empty all_empty malformed; do
    case "$mode" in
      failed) FAKE_TMUX_FAIL_SESS=sessA cfx_run ;;
      empty) FAKE_TMUX_EMPTY_SESS=sessA cfx_run ;;
      all_empty) FAKE_TMUX_EMPTY_SESS=all cfx_run ;;
      malformed) printf 'not-an-absolute-path\n' >> "$WORK/panepaths"; cfx_run
                 printf '%s\n%s\n%s\n' "$WT3" "$WT1" "$WT2" > "$WORK/panepaths" ;;
    esac
    dead_kept || cfx_fail "7: $mode inventory pruned caches"
    st_eq "7: $mode inventory keeps the missing fleet's cache" live-ctx "$(cat "$G/ctx_$(gk "$WT1")")"
  done
  # The sweep uses the full inventory even when the very first git call wedges.
  for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do printf 'prior-branch\t' > "$G/git_$(gk "$wt")"; done
  printf '%s' "$WT4" > "$G/collect.git.cursor"   # sorted WT4 precedes wt1
  FAKE_GIT_HANG=/wt1 FLEET_COLLECT_GIT_BUDGET=5 cfx_run || cfx_fail '8: a truncated git phase still finishes the tick'
  st_eq '8: the first git worktree wedges' "$WT1" "$(cursor)"
  dead_gone || cfx_fail '8: the sweep happens before budgeted git work'
  for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do
    st_eq '8: an unvisited live git cache kept' $'prior-branch\t' "$(cache "$wt")"
    st_eq '8: an unvisited live context cache kept' live-ctx "$(cat "$G/ctx_$(gk "$wt")")"
  done
  wait "$L34"; r34=$?; cat "$WORK/lane34.log"
  wait "$L5"; r5=$?; cat "$WORK/lane5.log"
  [ "$r34" = 0 ] && [ "$r5" = 0 ] || st_fail 'a lane failed (its lines above)'
  st_ok "git: no status · budget · round-robin · slow-log · cache sweep (#552/#647)"
}

case_issues() {
  cfx_sandbox issues; cfx_copy tmux-dash-collect.sh fleet-lib.sh fleet-client-core.sh usage-lib.sh
  printf '#!/bin/sh\nexit 1\n' > "$WORK/fakepath/git"
  rm -rf "$WORK/conf/fleets"
  export FLEET_REPOS='acme/a acme/b acme/c' FLEET_COLLECT_ISSUES_BUDGET=5 \
    FLEET_COLLECT_SOCKETS_BUDGET=0 FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_GIT_BUDGET=0 \
    FLEET_COLLECT_CTX_BUDGET=0 FLEET_COLLECT_USAGE_BUDGET=0 FLEET_COLLECT_SCRAPE_BUDGET=0 \
    FLEET_COLLECT_BANNER_BUDGET=0 FLEET_COLLECT_ESCALATE_BUDGET=0 FLEET_COLLECT_SNAPSHOT_BUDGET=0
  lane() {
    CFX_HANG="$CFX_HANG.$1"; cfx_lane "lane$1"; F="$C/fleets"
    for n in a b c; do mkdir -p "$F/acme-$n"; printf 'old %s\n' "$n" > "$F/acme-$n/issues"
                       printf 'old parents\n' > "$F/acme-$n/parents"; done
  }
  cursor() { cat "$G/collect.issues.cursor" 2>/dev/null || :; }
  order() { sed -n 's/^issue //p' "$L/gh.log" | tr '\n' ' '; }
  fresh() { printf 'Milestone\t#1\t·\tFresh %s' "$1"; }
  ( lane 1
    FAKE_GH_HANG=a:issue cfx_run || cfx_fail 'a timed-out phase lets the collector finish'
    st_eq 'first attempt' 'a ' "$(order)"
    st_eq 'a timeout keeps the last good cache' 'old a' "$(cat "$F/acme-a/issues")"
    st_eq 'the timed-out repo is claimed before its fetch' acme/a "$(cursor)"
    grep -q 'phase issues hit' "$L/err" || cfx_fail 'missing budget diagnostic'
    grep -q 'next tick resumes after acme/a' "$L/err" || cfx_fail 'missing repo diagnostic'
    pgrep -f "$CFX_HANG" >/dev/null && cfx_fail 'the timed-out gh survived the phase'
    FAKE_GH_HANG=a:issue cfx_run || cfx_fail 'second tick failed'
    st_eq 'later repos run before the recurring wedge' 'b c a ' "$(order)"
    st_eq 'repo b refreshed' "$(fresh b)" "$(cat "$F/acme-b/issues")"
    st_eq 'repo c refreshed' "$(fresh c)" "$(cat "$F/acme-c/issues")"
    st_eq 'the wedged repo keeps its cache' 'old a' "$(cat "$F/acme-a/issues")"
    FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail 'healthy tick failed'
    st_eq 'a healthy tick wraps and visits every repo once' 'b c a ' "$(order)"
    st_eq 'a completed round clears the cursor' '' "$(cursor)"
    GH_TTL=999999 FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail 'TTL tick failed'
    st_eq 'fresh caches make no GitHub calls' '' "$(cat "$L/gh.log")"
    printf 'acme/a' > "$G/collect.issues.cursor"
    GH_TTL=999999 cfx_run --issues acme/b || cfx_fail 'targeted refresh failed'
    st_eq 'a targeted refresh bypasses the TTL' 'b ' "$(order)"
    st_eq 'a targeted refresh leaves the sweep cursor' acme/a "$(cursor)"
  ) > "$WORK/lane1.log" 2>&1 & P1=$!
  ( lane 2
    FAKE_GH_HANG=a:api cfx_run || cfx_fail 'GraphQL timeout tick failed'
    st_eq 'a GraphQL timeout saves the repo cursor' acme/a "$(cursor)"
    st_eq 'a GraphQL timeout keeps old parents' 'old parents' "$(cat "$F/acme-a/parents")"
    FAKE_GH_HANG=a:api cfx_run || cfx_fail 'GraphQL retry tick failed'
    st_eq 'a GraphQL wedge cannot starve other repos' 'b c a ' "$(order)"
    # Cursor identity, not an index: removing/reordering repos skips no neighbour.
    printf 'acme/b' > "$G/collect.issues.cursor"
    FLEET_REPOS='acme/c acme/a' FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail 'removed cursor tick failed'
    st_eq 'a removed cursor falls back to the queue start' 'c a ' "$(order)"
    printf 'acme/a' > "$G/collect.issues.cursor"
    FLEET_REPOS='acme/c acme/a acme/b' FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail 'reordered queue tick failed'
    st_eq 'resume after identity in a reordered queue' 'b c a ' "$(order)"
    : > "$G/collect.repoqueue"   # legal on a fresh install (bash 3.2, set -u)
    FLEET_REPOS='' FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run || cfx_fail 'empty queue tick failed'
    st_eq 'an empty queue makes no calls' '' "$(cat "$L/gh.log")"
    # A parent in ANOTHER repo never nests (#1942) — the collector's own --jq, real jq.
    if command -v jq >/dev/null 2>&1; then
      FAKE_GQL_JSON='{"data":{"repository":{"issues":{"nodes":[
        {"number":5,"parent":{"number":4,"repository":{"nameWithOwner":"Acme/A"}}},
        {"number":6,"parent":{"number":4,"repository":{"nameWithOwner":"acme/other"}}},
        {"number":7,"parent":null}]}}}}' FLEET_REPOS='acme/a' FLEET_COLLECT_ISSUES_BUDGET=0 cfx_run \
        || cfx_fail 'cross-repo parents tick failed'
      st_eq 'only a same-repo parent nests' $'5\t4' "$(cat "$F/acme-a/parents")"
    else echo 'issues: jq absent — cross-repo parent check SKIPPED'; fi
  ) > "$WORK/lane2.log" 2>&1 & P2=$!
  wait "$P1"; r1=$?; cat "$WORK/lane1.log"; wait "$P2"; r2=$?; cat "$WORK/lane2.log"
  [ "$r1" = 0 ] && [ "$r2" = 0 ] || st_fail 'a lane failed (its lines above)'
  st_ok "issues: timeout fairness, caches, TTL, targeted refresh, queue changes, cross-repo parents"
}

case_banner() {
  cfx_sandbox banner; cfx_copy
  rm -rf "$WORK/conf/fleets/sessA"; mkdir -p "$WORK/conf/fleets/fixture"
  printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/fixture/conf"
  printf 'tok-a\n' > "$WORK/accounts/acctA"; rm -f "$WORK/accounts/a"
  NWIN=24
  cat > "$WORK/bin/fleet-account-truth.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = --socket ] || exit 2
i=1; while [ "$i" -le "${FAKE_NWIN:-24}" ]; do printf '@%s\t%%%s\tacctA\t0\n' "$i" "$i"; i=$((i+1)); done
STUB
  chmod +x "$WORK/bin/fleet-account-truth.sh"
  export PATH="$WORK/fakepath:$PATH" FAKE_CAPLOG="$WORK/cap.log" FAKE_NWIN=$NWIN
  cfx_extract "$WORK/phase.sh" atomic_write banner_budget ph_banner banner_scan_one ph_banner_over
  # shellcheck disable=SC2034  # read by the sourced phase functions
  in_phase() {
    ( BIN="$WORK/bin"; . "$BIN/fleet-lib.sh"; . "$BIN/usage-lib.sh"; . "$WORK/phase.sh"
      SOCKETS=fixture; US=$'\037'; FLEET_CONF_DIR="$WORK/conf"
      FLEET_ACCOUNTS_DIR="${CFX_ACCTS:-$WORK/accounts}"; FLEET_NOTIFY_CMD=''; "$@" )
  }
  # A. budget = max(floor, windows × per-window); 0 = unbudgeted; no accounts = floor.
  st_eq 'A: 24 windows × 1.5s over the 30s floor' 36 "$(in_phase banner_budget)"
  st_eq 'A: 4 windows keep the floor' 30 "$(FAKE_NWIN=4 in_phase banner_budget)"
  st_eq 'A: a floor above the window term wins' 60 "$(FLEET_COLLECT_BANNER_BUDGET=60 in_phase banner_budget)"
  st_eq 'A: 0 stays unbudgeted' 0 "$(FLEET_COLLECT_BANNER_BUDGET=0 in_phase banner_budget)"
  st_eq 'A: per-window 0 is the old fixed budget' 30 "$(FLEET_COLLECT_BANNER_PER_WINDOW_MS=0 in_phase banner_budget)"
  st_eq 'A: no accounts dir is just the floor' 30 "$(CFX_ACCTS="$WORK/none" in_phase banner_budget)"
  # B. tick 1 wedges on cold %10 and is killed; tick 2 runs working first, then resumes
  # after the claimed %10 — every window within two ticks.
  : > "$FAKE_CAPLOG"; rm -f "$G/banner.cursor"
  FAKE_CAP_HANG=%10 in_phase fleet_timebox 3 ph_banner; st_eq 'B: the wedged tick is killed by its box' 124 "$?"
  t1=$(tr '\n' ' ' < "$FAKE_CAPLOG")
  st_eq 'B: tick 1 working first, then cold up to the wedge' '%1 %2 %3 %4 %5 %6 %7 %8 %9 %10 ' "$t1"
  st_eq 'B: the wedged window is claimed before its scan' 'fixture @10' "$(tr '\t' ' ' < "$G/banner.cursor")"
  over=$(in_phase ph_banner_over 2>&1)
  case "$over" in *'banner covered '*'next tick resumes after fixture @10'*) ;; *) st_fail 'B: ph_banner_over says how far it got' "$over" ;; esac
  : > "$FAKE_CAPLOG"
  in_phase fleet_timebox 30 ph_banner || st_fail 'B: tick 2 must complete'
  t2=$(tr '\n' ' ' < "$FAKE_CAPLOG")
  st_eq 'B: tick 2 working first, resume after %10, wrap' \
    '%1 %2 %3 %11 %12 %13 %14 %15 %16 %17 %18 %19 %20 %21 %22 %23 %24 %4 %5 %6 %7 %8 %9 %10 ' "$t2"
  i=1; while [ "$i" -le "$NWIN" ]; do st_has 'B: every window within two ticks' " $t1 $t2 " " %$i "; i=$((i+1)); done
  st_eq 'B: the wedged capture died with its box' 0 "$(pgrep -f "$CFX_HANG" 2>/dev/null | wc -l | tr -d ' ')"
  # C. a real tick: 24 × 0.2s captures vs a 2s floor; the 500ms window term carries
  # it, and with that term off the same tick IS killed.
  tick() { FLEET_COLLECT_TICK_BUDGET=120 FLEET_COLLECT_BANNER_BUDGET=2 FAKE_CAP_SLEEP=0.2 cfx_run; }
  rm -f "$G/banner.cursor" "$G/collect.phase.cursor" "$G"/collect.banner.prog.*
  FLEET_COLLECT_BANNER_PER_WINDOW_MS=500 tick || cfx_fail 'C: the tick must exit 0'
  st_eq 'C: phase=done' 'done' "$(cfx_hb phase)"
  st_hasnt 'C: banner not killed with a window-scaled budget' " $(cfx_hb over) " ' banner '
  grep -q 'phase banner hit' "$L/err" && cfx_fail 'C: stderr says the banner phase hit its budget'
  st_eq 'C: heartbeat banner_scanned/total' 24/24 "$(cfx_hb banner_scanned)/$(cfx_hb banner_total)"
  ls "$G"/collect.banner.prog.* >/dev/null 2>&1 && cfx_fail 'C: the progress file outlived the tick'
  rm -f "$G/banner.cursor" "$G/collect.phase.cursor"
  FLEET_COLLECT_BANNER_PER_WINDOW_MS=0 tick || cfx_fail 'C: the fixed-budget tick must exit 0'
  st_has 'C: the fixed 2s budget kills banner' " $(cfx_hb over) " ' banner '
  grep -q 'phase banner hit the 2s budget (FLEET_COLLECT_BANNER_BUDGET)' "$L/err" || cfx_fail 'C: stderr names budget + knob'
  grep -q 'fleet-collect: banner covered [0-9]*/24 window(s)' "$L/err" || cfx_fail 'C: stderr says how far the rotation got'
  s=$(cfx_hb banner_scanned)
  [ "$(cfx_hb banner_total)" = 24 ] && [ -n "$s" ] && [ "$s" -lt 24 ] || cfx_fail "C: a killed tick shows the partial count ($s)"
  st_ok "banner: window-scaled budget · working-first rotation · heartbeat (#1588)"
}

CASES="${*:-guard sessmap account phases overrun git issues banner}"
for c in $CASES; do
  ( export ST_LEG="$c"; "case_$c" ) || exit 1
done
printf 'selftest PASS: collector — %s\n' "$CASES"
