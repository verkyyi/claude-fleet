#!/bin/bash
# fleet-quotawatch.sh — the ccquota-driven PRE-EMPTIVE account rotation, as its
# OWN ~60s tick (issue #551). Reads every pool account's exact 5h/7d utilization
# off the ccquota hub and, per account, warns its sessions at
# FLEET_ACCOUNT_WARN_PCT and benches + moves them at FLEET_ACCOUNT_CEILING —
# BEFORE the subscription wall (issue #513's policy, unchanged).
#
# Why its own tick (#551): this policy used to be the LAST block of the dash
# collector's tick, after the per-repo gh fetches, the git/ctx/usage scans and
# the pane scrapes. On a 21-window fleet a tick ran 2–3 minutes, and a tick that
# stalled (an un-timeboxed `gh` on a bad network) or died before its end simply
# never reached the quota block — the cache went 2.5h stale, the 70%/85% branches
# never ran, and every session on the account rode the 5-hour window to 100%.
# The watch is now (a) this script on its own launchd/systemd 60s unit
# (com.claude-fleet.quotawatch) and (b) ALSO the first thing every collector tick
# runs — so an install whose daemon set predates #551 keeps the watch at the
# collector's cadence, and a healthy install gets a real 60s cadence that no gh
# latency can push around. Both callers are safe together: the once-per-reset-
# window markers dedup the actions, `fleet-account.sh quota` refetches at most
# every FLEET_ACCOUNT_QUOTA_TTL s, and the lock below serializes overlapping ticks.
#
# What it writes (all under $TMPDIR/.claude-dash/global/):
#   account.quota(.ts)      — via `fleet-account.sh quota` (the TTL-gated fetch)
#   quota.warn.<label>      — reset epoch the 70% warning was sent for
#   quota.ceiling.<label>   — reset epoch the 85% bench+move was done for
#   quota.phase             — reset epoch the 5h phase stagger was planned for
#                             (issue #598; only with FLEET_ACCOUNT_PHASE_AUTO=1)
#   quotawatch.heartbeat    — key=value: pid/caller/start/phase/end/dur/rows/
#                             fetched, plus the per-phase breakdown t_modelcap/
#                             t_fetch/t_policy (issue #582)
#   quotawatch.lock/        — mkdir lock (pid + ts inside) — overlap guard,
#                             released only by the tick that still holds it (#582)
#   quotawatch.sweep.start  — fairness cursor: the fleet whose cap probe was cut
#                             short last tick, swept first on the next one (#582)
#
# Staleness alarm (#551): `account.quota.ts` is the watch's liveness — every tick
# restamps it even when the hub is unreachable (empty rows still refresh the
# stamp). Once it is older than FLEET_ACCOUNT_QUOTA_STALE (default 600s = 10×
# the TTL) while the pool + hub are configured, the watch is BLIND: the status
# bar shows `⚠ quota stale 47m` (bin/tmux-status.sh via usage-lib.sh),
# fleet-doctor FAILs, and the next tick that does run notifies once that it was
# blind for that long. `--status` prints the same verdict for scripts.
#
# SECOND job — the PER-MODEL cap sweep (issue #569). A model cap ("You've reached
# your Fable limit …", #524) is detected by the dash collector's banner phase, and
# that phase sits behind the whole tick: on a monorepo fleet the git scan alone ran
# 551 s, so nine walled workers idled for the better part of an hour on
# 2026-09-12 while the recovery trickled through one cold `--resume` at a time. The
# detection belongs on a fast tick, and the recovery does not need a restart at all
# — so every tick now also runs `fleet-model-switch.sh --capped` per fleet, which
# types `/model <fallback>` at each walled session's own prompt (~5 s, process and
# background agents and context all kept) and only falls back to
# `fleet-migrate.sh --model` when it cannot verify the flip. Reaction time goes
# from a tick of unbounded length to ≤60 s. The collector's #524 branch stays as
# the backstop for installs whose daemon set predates this; `@model_migrating`
# (180 s) and the pane's own status line keep the two callers from double-typing.
#
# BUDGETS (issue #582). The cap sweep is the unbounded half of this tick: ~8 tmux
# round-trips per window per fleet, and on a loaded server one `display-message`
# can block for minutes — so on 2026-09-13 a tick sat in a single probe for 26
# MINUTES against a 120 s deadline. It could not be superseded (bash defers a
# trapped signal until the foreground command returns) and, when it finally died,
# its unconditional lock release deleted its successor's lock — so ticks piled up
# three-deep on the same tmux server, each making the others slower. The unit
# looked healthy the whole time (`launchctl list` → exit 0) while the launchd log
# filled with `skip — still running` and the quota stamp aged past STALE: the
# pre-emptive rotation this script exists for was BLIND. Now: each fleet's probe
# runs under FLEET_QUOTAWATCH_PROBE_BUDGET (20 s, tree-killed on expiry), the
# phase as a whole under FLEET_QUOTAWATCH_SWEEP_BUDGET (40 s), whatever is left
# over is swept first next tick, and the ccquota fetch — the cheap half, ~1 s,
# and the one whose stamp is the liveness signal — can no longer be starved by it.
#
# Fail-open, per job: the model sweep needs only an accounts pool (the cap ledger
# is per-account), the ccquota policy needs a hub URL too. Neither configured →
# exit 0 and nothing here runs.
#
# Usage:
#   fleet-quotawatch.sh [--caller <name>] [--dry-run]
#   fleet-quotawatch.sh --status        # off | never | fresh | stale  <TAB> age-s
#
# Env: FLEET_QUOTAWATCH_DEADLINE (120) FLEET_QUOTAWATCH_PROBE_BUDGET (20)
#      FLEET_QUOTAWATCH_SWEEP_BUDGET (40) FLEET_ACCOUNT_QUOTA_STALE (600)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"         # fleet_quota_stale_age / fleet_quota_watch_configured

C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"; mkdir -p "$G"
now() { date +%s; }
atomic_write() { local dest="$1" tmp="$1.$$"; cat > "$tmp" && mv "$tmp" "$dest"; }

CALLER=daemon; DRY=0; STATUS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --caller)  CALLER="${2:-daemon}"; shift ;;
    --dry-run) DRY=1 ;;
    --status)  STATUS=1 ;;
    -h|--help) sed -n '2,80p' "$0"; exit 0 ;;
    *) printf 'fleet-quotawatch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

QTS="$G/account.quota.ts"
HB="$G/quotawatch.heartbeat"
LOCK="$G/quotawatch.lock"
STALE="${FLEET_ACCOUNT_QUOTA_STALE:-600}"
DEADLINE="${FLEET_QUOTAWATCH_DEADLINE:-120}"   # a tick past this is stuck → superseded
# Budgets for the model-cap sweep (issue #582) — the tick's unbounded half. The
# sweep makes ~8 tmux round-trips per window per fleet (23 windows on the monorepo
# fleet ⇒ ~180 client invocations), and on a loaded server a SINGLE
# `tmux display-message` can block for minutes: one was observed stuck for 57 s,
# inside a probe that had been running for 24. Unbudgeted, one wedged fleet
# starves the ccquota fetch below — the fetch that writes the stamp `--status`
# reads — so the watch goes stale and the pre-emptive rotation goes BLIND while
# the launchd unit still reports exit 0. Both budgets are per-TICK and
# best-effort: whatever is skipped is swept by the next tick, 60 s later.
PROBE_BUDGET="${FLEET_QUOTAWATCH_PROBE_BUDGET:-20}"   # one fleet's cap probe
SWEEP_BUDGET="${FLEET_QUOTAWATCH_SWEEP_BUDGET:-40}"   # the whole modelcap phase
SWEEP_START="$G/quotawatch.sweep.start"               # fairness rotation cursor

# --status: off (pool/hub not configured) | never (configured, no stamp yet) |
# fresh | stale, then TAB + the stamp's age in seconds (0 for off/never).
if [ "$STATUS" = 1 ]; then
  if ! fleet_quota_watch_configured; then printf 'off\t0\n'; exit 0; fi
  ts=$(cat "$QTS" 2>/dev/null); case "$ts" in ''|*[!0-9]*) ts=0;; esac
  if [ "$ts" -eq 0 ]; then printf 'never\t0\n'; exit 0; fi
  age=$(( $(now) - ts ))
  if [ -n "$(fleet_quota_stale_age)" ]; then printf 'stale\t%s\n' "$age"; else printf 'fresh\t%s\n' "$age"; fi
  exit 0
fi

# Fail-open gates — one per job (#569). The MODEL sweep needs only an accounts
# pool: a per-model cap is recorded per account and recovered in place, neither of
# which touches ccquota. The ccquota POLICY additionally needs a hub URL — that is
# fleet_quota_watch_configured, identical to the collector's pre-#551 gate, and it
# alone still governs `--status`, the liveness stamp and the blind-spell alarm.
ACCT_DIR="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
MODEL_SWEEP=0; [ -d "$ACCT_DIR" ] && MODEL_SWEEP=1
QUOTA_POLICY=0; fleet_quota_watch_configured && QUOTA_POLICY=1
[ "$MODEL_SWEEP" = 1 ] || [ "$QUOTA_POLICY" = 1 ] || exit 0

# --- overlap guard: one tick at a time; a stuck one is superseded past DEADLINE.
# mkdir is the atomic primitive (no flock on macOS). The holder's pid + start
# epoch sit inside; a dead holder (crash without cleanup) or one past the
# deadline is taken over — and killed, so a wedged `ccquota` can't pin the lock.
if ! mkdir "$LOCK" 2>/dev/null; then
  opid=$(cat "$LOCK/pid" 2>/dev/null); ots=$(cat "$LOCK/ts" 2>/dev/null)
  case "$opid" in ''|*[!0-9]*) opid='';; esac
  case "$ots" in ''|*[!0-9]*) ots=0;; esac
  if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null \
     && ps -o command= -p "$opid" 2>/dev/null | grep -q 'fleet-quotawatch'; then
    age=$(( $(now) - ots ))
    if [ "$age" -lt "$DEADLINE" ]; then
      printf 'fleet-quotawatch: skip — tick %s still running (%ss)\n' "$opid" "$age" >&2
      exit 0
    fi
    printf 'fleet-quotawatch: tick %s past the %ss deadline (%ss) — superseding it\n' "$opid" "$DEADLINE" "$age" >&2
    # Kill the TREE, not just the script (issue #582). bash DEFERS a trapped
    # signal until the current foreground command returns, so a tick sitting in
    # `x=$(tmux …)` ignores its supersede for as long as that tmux takes — one
    # survived 26 MINUTES against this 120 s deadline — and meanwhile its tmux
    # clients keep loading the very server that wedged it. TERM the tree, brief
    # grace, SIGKILL the survivors.
    fleet_kill_tree "$opid" 2
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0        # lost the takeover race → the other tick has it
fi
printf '%s' "$$" > "$LOCK/pid"; now > "$LOCK/ts"
# Release ONLY a lock we still hold (issue #582). The release used to be an
# unconditional `rm -rf "$LOCK"`, so a superseded-but-still-alive tick deleted its
# SUCCESSOR's lock the moment it finally died — admitting a third tick alongside
# the second. That is the pileup in the launchd log: three concurrent cap probes
# against one tmux server, each making the others slower, which wedges the next.
release_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }
trap 'release_lock' EXIT
trap 'exit 143' INT TERM                       # so the EXIT trap (lock release) runs on a supersede

START=$(now)
hb() {  # $1 = phase, $2 = extra key=value lines (optional)
  printf 'pid=%s\ncaller=%s\nstart=%s\nphase=%s\nphase_ts=%s\n%s' "$$" "$CALLER" "$START" "$1" "$(now)" "${2:-}" | atomic_write "$HB"
}

SOCKETS=$(fleet_sockets)

# --- the PER-MODEL cap sweep (issue #569) -------------------------------------
# Runs FIRST and on every tick: it is capture-pane only until it finds something,
# it needs no network, and a walled worker is the most urgent thing this daemon
# can fix. The dry run is the cheap probe (no keystrokes, no sleeps); only a fleet
# with at least one candidate gets the real pass, and that one is backgrounded via
# fleet_bg so the ~5 s-per-window typing can never eat into DEADLINE. run-shell
# sets $TMUX for the job, so the switch's bare tmux calls stay on THIS fleet's
# server. fleet_bg, not a hand-rolled `run-shell -b` (issue #575): the switch
# prints a per-window report on stdout, and run-shell paints a backgrounded job's
# stdout over the operator's window as an Esc-to-dismiss view — fleet_bg silences
# it centrally; --toast still reports on the status line.
T_MODEL=0; T_FETCH=0; T_POLICY=0; MTIMES=""; DEFERRED=""
if [ "$MODEL_SWEEP" = 1 ] && [ -x "$BIN/fleet-model-switch.sh" ]; then
  hb "modelcap"
  m0=$(now)
  # Fairness rotation (issue #582): start from the fleet the LAST tick ran out of
  # budget on, so a chronically slow fleet cannot permanently starve the ones
  # behind it in fleet_sockets' fixed order. The cursor is cleared every tick and
  # re-armed only by a defer or a timeout below.
  msweep="$SOCKETS"; mfirst=$(cat "$SWEEP_START" 2>/dev/null)
  if [ -n "$mfirst" ] && printf '%s\n' "$SOCKETS" | grep -qxF "$mfirst"; then
    msweep=$(printf '%s\n' "$SOCKETS" | grep -xF "$mfirst"; printf '%s\n' "$SOCKETS" | grep -vxF "$mfirst")
  fi
  : > "$SWEEP_START"
  for ms in $msweep; do
    # Phase budget: stop probing once the sweep has spent SWEEP_BUDGET, so the
    # ccquota fetch below always gets its turn within the 60 s period.
    if [ $(( $(now) - m0 )) -ge "$SWEEP_BUDGET" ]; then
      DEFERRED="$DEFERRED $ms"; [ -s "$SWEEP_START" ] || printf '%s' "$ms" > "$SWEEP_START"
      continue
    fi
    p0=$(now)
    mout=$(fleet_timebox "$PROBE_BUDGET" "$BIN/fleet-model-switch.sh" --capped --dry-run --session "$ms" 2>/dev/null); mrc=$?
    if [ "$mrc" = 124 ]; then
      # Report it honestly rather than letting it eat the tick (issue #582): the
      # probe and every tmux client under it are dead, and this fleet goes first
      # on the next tick.
      MTIMES="$MTIMES $ms=timeout"
      [ -s "$SWEEP_START" ] || printf '%s' "$ms" > "$SWEEP_START"
      printf 'fleet-quotawatch: modelcap probe on %s hit its %ss budget — killed, not swept this tick\n' "$ms" "$PROBE_BUDGET" >&2
      continue
    fi
    MTIMES="$MTIMES $ms=$(( $(now) - p0 ))s"
    mplan=$(printf '%s\n' "$mout" | grep -c '^  would:')
    case "$mplan" in ''|*[!0-9]*) mplan=0 ;; esac
    [ "$mplan" -gt 0 ] || continue
    if [ "$DRY" = 1 ]; then
      printf 'would: switch %s walled window(s) on %s in place (/model <fallback>)\n' "$mplan" "$ms"
      continue
    fi
    printf 'fleet-quotawatch: %s walled window(s) on %s — switching in place\n' "$mplan" "$ms" >&2
    fleet_bg -L "$ms" "bash '$BIN/fleet-model-switch.sh' --capped --session '$ms' --toast"
  done
  T_MODEL=$(( $(now) - m0 ))
  [ -n "$DEFERRED" ] && printf 'fleet-quotawatch: modelcap phase spent its %ss budget (%ss) — deferred to the next tick:%s\n' "$SWEEP_BUDGET" "$T_MODEL" "$DEFERRED" >&2
fi

if [ "$QUOTA_POLICY" != 1 ]; then
  END=$(now)
  hb "done" "end=$END"$'\n'"dur=$(( END - START ))"$'\n'"modelsweep=1"$'\n'"t_modelcap=$T_MODEL"$'\n'
  printf 'fleet-quotawatch: tick done in %ss — modelcap %ss [%s ], no ccquota policy (no hub)\n' \
    "$(( END - START ))" "$T_MODEL" "${MTIMES:- none}" >&2
  exit 0
fi

# --- blind-spell alarm: how old was the stamp BEFORE this tick? A stamp older
# than STALE (and not "never": a fresh install has no stamp) means no tick ran
# for that long — say so once, now that one is running, so the gap is visible in
# the notifier's history and not only on the status bar while it lasted.
pre_ts=$(cat "$QTS" 2>/dev/null); case "$pre_ts" in ''|*[!0-9]*) pre_ts=0;; esac
blind=0
if [ "$pre_ts" -gt 0 ] && [ $(( START - pre_ts )) -ge "$STALE" ]; then blind=$(( START - pre_ts )); fi

hb "fetch"
f0=$(now)
qrows=$("$BIN/fleet-account.sh" quota 2>/dev/null)
T_FETCH=$(( $(now) - f0 ))
post_ts=$(cat "$QTS" 2>/dev/null); case "$post_ts" in ''|*[!0-9]*) post_ts=0;; esac
fetched=0; [ "$post_ts" -gt "$pre_ts" ] && fetched=1
nrows=$(printf '%s' "$qrows" | grep -c .)
hb "policy" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'
y0=$(now)

if [ "$blind" -gt 0 ]; then
  bm=$(( blind / 60 ))
  printf 'fleet-quotawatch: the quota cache was %sm stale before this tick — the watch was blind for that long (caller now: %s)\n' "$bm" "$CALLER" >&2
  if [ "$DRY" = 0 ] && [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
    $FLEET_NOTIFY_CMD "# quota watch was blind for ${bm}m
the ccquota cache (\`account.quota.ts\`) had not been refreshed for ${bm}m — no pre-emptive rotation could fire in that window. It is ticking again now (caller: ${CALLER}). Check \`fleet-doctor.sh\` → quotawatch / collect, and that com.claude-fleet.quotawatch is loaded." >/dev/null 2>&1
  fi
fi

# --- the policy (issue #513, verbatim from the collector's former tail block):
#   ≥ FLEET_ACCOUNT_CEILING (85%)  bench until ccquota's reset instant (rotates
#                                  the active pointer past it — new spawns go
#                                  elsewhere at once), then move every session
#                                  still on it (fleet-account.sh migrate
#                                  --account, per fleet, backgrounded); notify once.
#                                  No OTHER account to move to (#567): bench
#                                  only, say so once — the sessions stay put.
#   ≥ FLEET_ACCOUNT_WARN_PCT (70%) tell every session on it, over its own peer
#                                  inbox (fleet_peer_send — the SendMessage
#                                  channel, not send-keys), that a move is coming
#                                  and to commit WIP; toast + FLEET_NOTIFY_CMD once.
# Once per (account, reset-window): a marker file holds the reset epoch the
# episode was handled for (fleet_same_window compares with tolerance — ccquota's
# resets_at jitters by a second between polls), so the next window re-arms it.
# Empty rows (no ccquota / hub unreachable / unknown verdict) → nothing runs.
qceil="${FLEET_ACCOUNT_CEILING:-85}"; qwarn="${FLEET_ACCOUNT_WARN_PCT:-70}"
# quota_move_target <label> — an account the ceiling branch could move <label>'s
# sessions onto: some OTHER pool account that is neither benched nor itself at
# the ceiling in THIS tick's rows. Prints it; empty + exit 1 ⇒ nowhere to move
# (issue #567). Why not just `fleet-account.sh active` after the bench: with every
# other account benched it keeps the CURRENT one — the right answer for "which
# account should a new spawn use" (there is no better), but the migrate fan-out
# then closes N sessions and cold-boots each one (~25 s) straight back onto the
# account that was just benched for being over the ceiling, still walled. Seen
# live on 2026-09-12 05:32: 12 sessions bounced onto the same wall with the reset
# 24 min away. A session that is walled and waiting for its own reset is strictly
# better off than one cold-booted into the same wall — so: bench (spawns must
# know), skip the move, say so. Rows matter too: an account that crosses the
# ceiling in the SAME tick (a later row, not benched yet) is no target either —
# its own row benches it seconds later and would bounce those sessions again.
quota_move_target() {
  local skip="$1" f l u
  for f in "$ACCT_DIR"/*; do
    [ -f "$f" ] || continue
    l=${f##*/}; case "$l" in .*|*~|*.conf) continue;; esac
    [ "$l" != "$skip" ] || continue
    [ "$("$BIN/fleet-account.sh" limited-until "$l" 2>/dev/null || echo 0)" -le "$(now)" ] || continue
    u=$(printf '%s\n' "$qrows" | awk -F'\t' -v l="$l" '$1==l{print (($2+0)>($3+0))?$2+0:$3+0; exit}')
    [ -n "$u" ] && [ "$u" -ge "$qceil" ] && continue
    printf '%s' "$l"; return 0
  done
  return 1
}
# shellcheck disable=SC2034  # qroom: headroom column, read by `list`/pick_active, not here
printf '%s\n' "$qrows" | while IFS=$'\t' read -r ql q5 q7 qroom qr5 qr7 qpph; do
  [ -n "$ql" ] || continue
  qutil=$q5; qwhich="5-hour"; qreset=$qr5
  if [ "${q7:-0}" -gt "$qutil" ]; then qutil=$q7; qwhich="7-day"; qreset=$qr7; fi
  qresett=$(date -r "$qreset" '+%H:%M' 2>/dev/null || date -d "@$qreset" '+%H:%M' 2>/dev/null || echo "?")
  if [ "$qutil" -ge "$qceil" ]; then
    mk="$G/quota.ceiling.$ql"
    fleet_same_window "$mk" "$qreset" && continue                          # this window already handled
    qto=$(quota_move_target "$ql") || qto=""
    if [ "$DRY" = 1 ]; then
      if [ -n "$qto" ]; then printf 'would: bench %s (%s%% of %s, resets %s) + migrate --account %s on: %s\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" "$(printf '%s' "$SOCKETS" | tr '\n' ' ')"
      else printf 'would: bench %s (%s%% of %s, resets %s) — nowhere to move: every other account is benched or at its ceiling; its sessions would stay on %s until %s\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" "$qresett"; fi
      continue
    fi
    printf '%s' "$qreset" | atomic_write "$mk"
    "$BIN/fleet-account.sh" bench "$ql" "$qreset" "ccquota: $qwhich window at ${qutil}%" >/dev/null 2>&1
    qnew=$("$BIN/fleet-account.sh" active 2>/dev/null)
    if [ -z "$qto" ]; then
      # #567: the bench is recorded (a new spawn must know), the move is not made.
      printf 'fleet-quotawatch: %s at %s%% of its %s window — benched until %s; nowhere to move: every account is at its ceiling, its sessions stay on %s until then\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" >&2
      for qs in $SOCKETS; do
        tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) → benched until $qresett; nowhere to move: every account is at its ceiling — sessions stay on $ql until $qresett" 2>/dev/null
      done
      if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
        $FLEET_NOTIFY_CMD "# subscription at its limit — nowhere to move
**$ql** is at ${qutil}% of its $qwhich window (ccquota, exact) — benched until $qresett, but every other account is benched or at its ceiling too, so its sessions were NOT moved: they stay on **$ql** until $qresett (a walled session waiting for its own reset beats one cold-booted back into the same wall)" >/dev/null 2>&1
      fi
      continue
    fi
    for qs in $SOCKETS; do
      fleet_bg -L "$qs" "bash '$BIN/fleet-account.sh' migrate --account '$ql' --session '$qs' --toast"
      tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) → benched until $qresett; moving its sessions to ${qnew:-?}" 2>/dev/null
    done
    if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
      $FLEET_NOTIFY_CMD "# subscription near its limit — rotated early
**$ql** is at ${qutil}% of its $qwhich window (ccquota, exact) — benched until $qresett; new sessions now use **${qnew:-?}** and every session still on it is being moved (close + \`--resume\` in a new window), before it hits the wall" >/dev/null 2>&1
    fi
  elif [ "$qutil" -ge "$qwarn" ]; then
    mk="$G/quota.warn.$ql"
    fleet_same_window "$mk" "$qreset" && continue
    if [ "$DRY" = 1 ]; then printf 'would: warn the sessions on %s (%s%% of %s, resets %s)\n' "$ql" "$qutil" "$qwhich" "$qresett"; continue; fi
    printf '%s' "$qreset" | atomic_write "$mk"
    qeta=""; [ "${qpph:-0}" -gt 0 ] && qeta=" (~$(( (100 - qutil) * 60 / qpph )) min to 100% at the current rate)"
    # The trailing language rule (issue #620) is what keeps this English notice
    # from reading as a language switch to a session that has been speaking
    # Chinese for forty turns — the notice itself needs no translation.
    qmsg="[fleet quota watch] Subscription account $ql — the one this session runs on — is at ${qutil}% of its $qwhich window${qeta}; it resets at $qresett. At ${qceil}% the fleet will send /exit to this session and resume it in a new window under another account (claude --resume, same transcript). Commit or stash any work in progress and leave a one-line note of where you are, so the resumed session picks up cleanly. No reply is needed.${FLEET_LANG_RULE_NOTICE:+ $FLEET_LANG_RULE_NOTICE}"
    qn=0
    for qs in $SOCKETS; do
      # space-separated: a window id has no spaces and a label is a file name
      # (tmux ≤3.4 would print a control-byte separator as literal `\037`)
      while read -r qw qa; do
        [ "$qa" = "$ql" ] || continue
        qp=$(fleet_pane_claude_pid "$qw" "$qs" 2>/dev/null) || continue
        [ -n "$qp" ] && fleet_peer_send "$qp" "$qmsg" fleet-quotawatch && qn=$((qn+1))
      done < <(tmux -L "$qs" list-windows -a -F '#{window_id} #{@cc_account}' 2>/dev/null)
      tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) — sessions warned; moves at ${qceil}%" 2>/dev/null
    done
    [ -n "${FLEET_NOTIFY_CMD:-}" ] && $FLEET_NOTIFY_CMD "# subscription approaching its limit
**$ql** is at ${qutil}% of its $qwhich window${qeta} (ccquota, exact) — $qn running session(s) warned to commit WIP; at ${qceil}% the fleet benches it and moves them" >/dev/null 2>&1
  else
    [ "$DRY" = 1 ] && printf 'ok: %s at %s%% of its %s window (warn %s%%, ceiling %s%%)\n' "$ql" "$qutil" "$qwhich" "$qwarn" "$qceil"
  fi
done

# --- THIRD job (OPT-IN): re-plan the 5h-window PHASE stagger (issue #598) ------
# N subscriptions first used at around the same time keep their 5h windows in the
# same phase — they burn down together and reset together, so the pool's total
# headroom is a sawtooth whose trough is a full outage. `phase --plan --apply`
# staggers the accounts that have NO live window by 5h/N, which is a decision
# about WHEN each account may open its next window (see fleet-account.sh
# phase_plan). Once per window is the right cadence — the plan is a queue of
# start slots, not a rotation — so it is keyed on the earliest 5h reset in these
# rows, the same fleet_same_window dedup the ceiling/warn branches use.
#
# DEFAULT OFF. This tick is what keeps the fleet alive, and a phase hold makes an
# account temporarily un-spawnable: it is fail-open in pick_active (a hold can
# never be the reason a spawn has no account), but arming it is still the
# operator's call, after they have watched `fleet-account.sh phase --plan` agree
# with the pool they can see. FLEET_ACCOUNT_PHASE_AUTO=1 arms it;
# FLEET_ACCOUNT_PHASE=0 disables the holds themselves, wherever they came from.
if [ "${FLEET_ACCOUNT_PHASE_AUTO:-0}" = 1 ] && [ "${nrows:-0}" -gt 1 ]; then
  qpmin=$(printf '%s\n' "$qrows" | awk -F'\t' 'BEGIN{m=0} ($5+0)>0 && (m==0 || ($5+0)<m){m=$5+0} END{print m+0}')
  qpmk="$G/quota.phase"
  if [ "$qpmin" -gt 0 ] && ! fleet_same_window "$qpmk" "$qpmin"; then
    if [ "$DRY" = 1 ]; then
      printf 'would: re-plan the 5h phase stagger —\n'
      "$BIN/fleet-account.sh" phase --plan 2>&1 | sed 's/^/  /'
    else
      printf '%s' "$qpmin" | atomic_write "$qpmk"
      if qpout=$("$BIN/fleet-account.sh" phase --plan --apply 2>&1); then
        printf 'fleet-quotawatch: re-planned the 5h phase stagger (issue #598)\n%s\n' "$qpout" >&2
      else
        printf 'fleet-quotawatch: phase re-plan declined — %s\n' "$qpout" >&2
      fi
    fi
  fi
fi

T_POLICY=$(( $(now) - y0 ))
END=$(now)
hb "done" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'"end=$END"$'\n'"dur=$(( END - START ))"$'\n'"t_modelcap=$T_MODEL"$'\n'"t_fetch=$T_FETCH"$'\n'"t_policy=$T_POLICY"$'\n'
# One line per tick, so the launchd log can answer "which HALF was slow?" without
# instrumenting anything after the fact (issue #582). Before this, the heartbeat
# held only the phase currently running and overwrote it, so a tick that took
# 143 s left no record of where the 143 s went.
printf 'fleet-quotawatch: tick done in %ss — modelcap %ss [%s ], fetch %ss, policy %ss, %s row(s)\n' \
  "$(( END - START ))" "$T_MODEL" "${MTIMES:- none}" "$T_FETCH" "$T_POLICY" "$nrows" >&2
exit 0
