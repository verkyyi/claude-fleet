#!/bin/bash
# fleet-ledger-watch.sh [--dry-run] [session...] — the LEDGER-WATCH daemon
# (com.claude-fleet.ledger-watch, ~60s; issue #320).
#
# Records EVERY closed worker session into the history ledger — not just the
# landed ones. The land path (bin/fleet-cleanup.sh → fleet-history.sh record)
# only indexes a session when its merged PR is reaped, so a worker window you
# close BY HAND (or that crashes, or an abandoned/blocked one that never lands)
# leaves its Claude transcript UNINDEXED: invisible to /fleet-history, not
# resumable. This daemon closes that gap.
#
# It can't inspect a window AFTER it's gone, so it SNAPSHOT-DIFFS: each tick it
# snapshots every live issue-bound worker window in each fleet to a durable
# per-fleet snapshot, then diffs against the PREVIOUS snapshot. A worker whose
# window VANISHED and that is NOT already in the ledger → one `closed-unlanded`
# ledger row (issue/title/worktree/transcript-dir/session-id/summary), so its
# transcript is browsable + resumable. Its worktree usually still exists on disk
# (worktree-autoclean keeps unmerged), so resume just reuses it.
#
# Design (mirrors the other single-writer, disk-gated fleet daemons — the cleanup
# daemon it sits beside):
#   for each LIVE fleet session (or the ones named on argv):
#     load its conf; skip if FLEET_LEDGER_WATCH=0
#     acquire a per-REPO LEASE (mkdir, steal-if-stale)      → single-writer (it
#                                                             WRITES the ledger)
#     honor the diskguard GATE (fleet-diskguard.sh --gate)  → never append on a full disk
#     snapshot the live worker windows (issue/win/worktree/title/summary), keyed
#       by ISSUE (one worker window ≡ one issue) — @raw scratch + panels excluded
#     diff vs the durable prior snapshot: for every issue that VANISHED, drive
#       bin/fleet-history.sh record-closed (idempotent — dedups on session-id, so
#       a landed session or a prior tick is never double-recorded)
#     overwrite the snapshot with the fresh one
#
# KEY = ISSUE, not session-id: /fleet-handoff cycles a worker through a fresh
# session-id in the SAME window (a `/clear`), so keying on session-id would emit a
# spurious row on every handoff. Keying on the issue records only when the whole
# window goes away, capturing its FINAL session (the newest transcript in the
# worktree). Trade-off: a kill-then-respawn of the SAME issue inside one tick is
# missed (rare); the common hand-close / crash / abandon is caught.
#
# WHY NO gh / LLM: detection is pure tmux snapshot + a local transcript lookup;
# the append is a shell `record-closed` (no gh). So — like the collector — it is
# ON BY DEFAULT for every fleet (opt out per fleet with FLEET_LEDGER_WATCH=0).
#
# NOT a reaper: it RECORDS ONLY (transcript indexing). It never removes a worktree
# or closes an issue — a recorded unlanded session leaves its worktree in place for
# resume; worktree-autoclean/cleanup stay the sole reapers.
#
# SCOPE: only fleets that are currently LIVE (own a hub window) are diffed. A
# whole-fleet tmux-server crash is handled by fleet-restore.sh (--if-down resumes
# the windows), not here — so this daemon targets a single window vanishing while
# its fleet stays up (the hand-close / abandon / per-window crash case).
#   Restore interaction: a fleet brought back by fleet-up is hub-only until
#   fleet-restore reopens its work windows. A tick that lands in that brief gap
#   sees those workers "vanished" and records them closed-unlanded — CORRECT if
#   they were abandoned, but if restore then resumes one (same session-id) and it
#   later lands, the landed path appends a second (landed) row for that session.
#   The consequence is cosmetic (two /fleet-history rows for one session; resume
#   picks the newest = the landed one). Left as-is deliberately: the alternatives
#   (dedup the append-only landed path, or suppress recording for a worker-less
#   fleet) each break a legitimate case that matters more.
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_LEDGER_WATCH          0 to disable for this fleet          (default 1/on)
#   FLEET_LEDGER_WATCH_LEASE_TTL lease lifetime, seconds             (default 300)
#   FLEET_DISPATCH_LEASE_DIR    lease dir (shared)    (default ~/.claude/leases)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           printf 'fleet-ledger-watch: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

LEASE_TTL="${FLEET_LEDGER_WATCH_LEASE_TTL:-300}"
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"
# dash summary cache (issue #181/#208): summary_<sess>_<winid> lives under global/.
DASHC="${TMPDIR:-/tmp}/.claude-dash/global"

# All progress goes to stderr — a daemon's stdout is /dev/null; stderr is the log.
now() { date +%s 2>/dev/null || echo 0; }
log() { printf '%s fleet-ledger-watch: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- per-repo lease (single-writer; steal-if-stale) — same shape as the cleanup daemon.
lease_acquire() { # $1 = lease path, $2 = my holder id
  local lease="$1" me="$2" now exp holder
  mkdir -p "$LEASE_DIR" 2>/dev/null
  now=$(now)
  if mkdir "$lease" 2>/dev/null; then
    printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"
    return 0
  fi
  holder=$(sed -n 1p "$lease/holder" 2>/dev/null)
  exp=$(sed -n 2p "$lease/holder" 2>/dev/null); exp="${exp//[^0-9]/}"; exp="${exp:-0}"
  if [ "$now" -ge "$exp" ]; then                       # stale → steal
    rm -rf "$lease" 2>/dev/null
    if mkdir "$lease" 2>/dev/null; then
      printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"
      log "stole stale lease (was ${holder:-?})"
      return 0
    fi
  fi
  return 1
}
# shellcheck disable=SC2329  # invoked indirectly via the `trap '…' EXIT` below
lease_release() { # $1 = lease path, $2 = my holder id
  [ "$(sed -n 1p "$1/holder" 2>/dev/null)" = "$2" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# --- watch ONE fleet. Runs in a subshell so its per-fleet conf never leaks. ------
watch_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  if [ "${FLEET_LEDGER_WATCH:-1}" = 0 ]; then
    log "$sess: ledger-watch off (FLEET_LEDGER_WATCH=0) — skip"
    exit 0
  fi

  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; exit 0; }
  repo=$(fleet_norm_repo "$repo")
  slug=$(fleet_slug "$repo")

  # tmux socket helper: the daemon has no $TMUX → target the fleet's OWN socket.
  ftmux() { tmux -L "$(fleet_socket "$sess")" "$@"; }

  # Raw window list (PIPE-delimited: tmux < 3.5 mangles a TAB in -F output; a
  # printable '|' survives — same reasoning as fleet-restore.sh's snapshot).
  #   window-id | @issue | @raw | @worktree | pane_current_path | window_name
  raw=$(ftmux list-windows -t "$sess" \
        -F '#{window_id}|#{@issue}|#{@raw}|#{@worktree}|#{pane_current_path}|#{window_name}' 2>/dev/null)
  # A LIVE fleet always has ≥1 hub window (dash/plan/backlog). An empty read here
  # means the session is gone or tmux glitched — either way do NOT diff (that would
  # false-record still-live workers as closed) and do NOT overwrite the snapshot.
  if [ -z "$raw" ]; then
    log "$sess: no windows read (session gone / transient) — skip tick (snapshot kept)"
    exit 0
  fi

  # Single-writer per REPO: two sessions serving one repo don't double-append.
  lease="$LEASE_DIR/ledgerwatch-$slug.lock"
  me="ledger-watch:$sess:$$@$(hostname -s 2>/dev/null || echo host)"
  if [ "$DRY" = 0 ]; then
    lease_acquire "$lease" "$me" || { log "$sess: another ledger-watcher holds the lease — skip"; exit 0; }
    trap 'lease_release "$lease" "$me"' EXIT
  fi

  # Build the CURRENT snapshot of worker windows, keyed by issue. A worker window
  # is one with a NUMERIC @issue and @raw != 1 (this also excludes hub panels,
  # which carry no @issue, and @raw scratch sessions per issue #214). Snapshot row
  # (TAB-delimited on disk): issue · window-id · worktree · title · summary. The
  # summary is captured WHILE LIVE (from the dash cache) — the whole point of a
  # snapshot-diff daemon is that the window can't be inspected once it's gone.
  cur=$(fleet_state_dir "$sess")/.ledgerwatch.$$.snap
  cur_issues=$'\n'
  : > "$cur"
  while IFS='|' read -r wid iss rawf wt cwd wname; do
    case "$iss" in ''|*[!0-9]*) continue ;; esac      # numeric @issue only (skips panels)
    [ "$rawf" = 1 ] && continue                        # skip @raw scratch (issue #214)
    # dedup within a tick: one worker window ≡ one issue — first seen wins.
    case "$cur_issues" in *$'\n'"$iss"$'\n'*) continue ;; esac
    local_wt="$wt"; [ -z "$local_wt" ] && local_wt="$cwd"   # @worktree, else the pane cwd
    smry=""
    smk=$(fleet_summary_key "$sess" "$wid")
    [ -f "$DASHC/summary_$smk" ] && read -r smry < "$DASHC/summary_$smk"
    printf '%s\t%s\t%s\t%s\t%s\n' "$iss" "$wid" "$local_wt" "$wname" "$smry" >> "$cur"
    cur_issues="${cur_issues}${iss}"$'\n'
  done <<EOF
$raw
EOF

  snap=$(fleet_state_dir "$sess")/ledgerwatch.snap

  # DIFF vs the prior snapshot: every issue present LAST tick but gone NOW vanished.
  # Its worker window closed; unless the ledger already carries that session (a
  # landed row, or a prior closed-unlanded row — record-closed dedups), record it.
  recorded=0; vanished=0
  if [ -f "$snap" ]; then
    while IFS=$'\t' read -r p_iss p_wid p_wt p_title p_smry; do
      [ -z "$p_iss" ] && continue
      case "$cur_issues" in *$'\n'"$p_iss"$'\n'*) continue ;; esac   # still live → not vanished
      vanished=$((vanished + 1))
      if [ "$DRY" = 1 ]; then
        log "$sess: would record closed-unlanded issue #$p_iss (win $p_wid, wt ${p_wt##*/})"
        recorded=$((recorded + 1))
        continue
      fi
      # Drive the ledger owner. It resolves transcript-dir + session-id from the
      # worktree, dedups (idempotent), and skips a window with no transcript.
      tok=$(bash "$BIN/fleet-history.sh" record-closed \
              --repo "$repo" --session "$sess" --issue "$p_iss" \
              --worktree "$p_wt" --win "$p_wid" \
              --title "$p_title" --summary "$p_smry" 2>/dev/null)
      case "$tok" in
        closed-unlanded*) log "$sess: $tok"; recorded=$((recorded + 1)) ;;
        *)                log "$sess: issue #$p_iss — ${tok:-record-closed: no output}" ;;
      esac
    done < "$snap"
  fi

  # Overwrite the durable snapshot with the fresh one (atomic). On --dry-run leave
  # the prior snapshot untouched so a real run still sees the same diff.
  if [ "$DRY" = 0 ]; then
    mv "$cur" "$snap" 2>/dev/null || rm -f "$cur"
  else
    rm -f "$cur"
  fi

  if [ "$vanished" -eq 0 ]; then
    log "$sess: no worker window vanished since last tick"
  else
    log "$sess: $vanished vanished → recorded $recorded closed-unlanded row(s)$([ "$DRY" = 1 ] && echo ' (dry-run)')"
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=("${ARGV_SESS[@]}")
else
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(fleet_hub_sessions | sort)
fi

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  log "no fleet sessions found (nothing to watch)"
  exit 0
fi

# Diskguard gate is a MACHINE-WIDE (per-volume) condition, so answer it ONCE per
# tick. Mirrors the other single-writer, disk-gated fleet daemons — don't append
# to a ledger below the floor.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping all fleets this tick"
  exit 0
fi

for s in "${SESSIONS[@]}"; do
  watch_fleet "$s"
done
exit 0
