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
#   quotawatch.heartbeat    — key=value: pid/caller/start/phase/end/dur/rows/fetched
#   quotawatch.lock/        — mkdir lock (pid + ts inside) — overlap guard
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
# Fail-open, per job: the model sweep needs only an accounts pool (the cap ledger
# is per-account), the ccquota policy needs a hub URL too. Neither configured →
# exit 0 and nothing here runs.
#
# Usage:
#   fleet-quotawatch.sh [--caller <name>] [--dry-run]
#   fleet-quotawatch.sh --status        # off | never | fresh | stale  <TAB> age-s
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
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) printf 'fleet-quotawatch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

QTS="$G/account.quota.ts"
HB="$G/quotawatch.heartbeat"
LOCK="$G/quotawatch.lock"
STALE="${FLEET_ACCOUNT_QUOTA_STALE:-600}"
DEADLINE="${FLEET_QUOTAWATCH_DEADLINE:-120}"   # a tick past this is stuck → superseded

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
    kill -TERM "$opid" 2>/dev/null
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0        # lost the takeover race → the other tick has it
fi
printf '%s' "$$" > "$LOCK/pid"; now > "$LOCK/ts"
trap 'rm -rf "$LOCK"' EXIT
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
# `run-shell -b` so the ~5 s-per-window typing can never eat into DEADLINE.
# run-shell sets $TMUX for the job, so the switch's bare tmux calls stay on THIS
# fleet's server.
if [ "$MODEL_SWEEP" = 1 ] && [ -x "$BIN/fleet-model-switch.sh" ]; then
  hb "modelcap"
  for ms in $SOCKETS; do
    mplan=$("$BIN/fleet-model-switch.sh" --capped --dry-run --session "$ms" 2>/dev/null | grep -c '^  would:')
    case "$mplan" in ''|*[!0-9]*) mplan=0 ;; esac
    [ "$mplan" -gt 0 ] || continue
    if [ "$DRY" = 1 ]; then
      printf 'would: switch %s walled window(s) on %s in place (/model <fallback>)\n' "$mplan" "$ms"
      continue
    fi
    printf 'fleet-quotawatch: %s walled window(s) on %s — switching in place\n' "$mplan" "$ms" >&2
    tmux -L "$ms" run-shell -b "bash '$BIN/fleet-model-switch.sh' --capped --session '$ms' --toast" 2>/dev/null
  done
fi

[ "$QUOTA_POLICY" = 1 ] || { END=$(now); hb "done" "end=$END"$'\n'"dur=$(( END - START ))"$'\n'"modelsweep=1"$'\n'; exit 0; }

# --- blind-spell alarm: how old was the stamp BEFORE this tick? A stamp older
# than STALE (and not "never": a fresh install has no stamp) means no tick ran
# for that long — say so once, now that one is running, so the gap is visible in
# the notifier's history and not only on the status bar while it lasted.
pre_ts=$(cat "$QTS" 2>/dev/null); case "$pre_ts" in ''|*[!0-9]*) pre_ts=0;; esac
blind=0
if [ "$pre_ts" -gt 0 ] && [ $(( START - pre_ts )) -ge "$STALE" ]; then blind=$(( START - pre_ts )); fi

hb "fetch"
qrows=$("$BIN/fleet-account.sh" quota 2>/dev/null)
post_ts=$(cat "$QTS" 2>/dev/null); case "$post_ts" in ''|*[!0-9]*) post_ts=0;; esac
fetched=0; [ "$post_ts" -gt "$pre_ts" ] && fetched=1
nrows=$(printf '%s' "$qrows" | grep -c .)
hb "policy" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'

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
      tmux -L "$qs" run-shell -b "bash '$BIN/fleet-account.sh' migrate --account '$ql' --session '$qs' --toast" 2>/dev/null
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
    qmsg="[fleet quota watch] Subscription account $ql — the one this session runs on — is at ${qutil}% of its $qwhich window${qeta}; it resets at $qresett. At ${qceil}% the fleet will send /exit to this session and resume it in a new window under another account (claude --resume, same transcript). Commit or stash any work in progress and leave a one-line note of where you are, so the resumed session picks up cleanly. No reply is needed."
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

END=$(now)
hb "done" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'"end=$END"$'\n'"dur=$(( END - START ))"$'\n'
exit 0
