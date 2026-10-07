#!/bin/bash
# fleet-install-sync.sh [--dry-run] [--status] [--root <dir>] [--remote <name>]
#                       [--timeout <s>] — the INSTALL-SYNC daemon
# (com.claude-fleet.install-sync, every 30 min; issue #1120, EPIC #1117 C3).
#
# Every login on a machine has its own live install (~/.claude/fleet) and its own
# daemons, and until now each one was brought forward by hand — someone had to
# remember to run /fleet-sync-install as THAT login. On 2026-09-24, before the
# hand sync, 4 of the Mac mini's 5 logins sat 60–265 commits behind, every daemon
# green. This tick closes that gap the only safe way: each login follows the ONE
# mark the operator vouches for — `refs/tags/stable` on the public repo
# (bin/fleet-stable.sh, C1 #1118) — never master.
#
# VERSIONS (issue #1894, EPIC #1906 C1). The install is never rewritten in
# place: ~/.claude/fleet is a LINK to ~/.claude/fleet.versions/<sha>/, every
# version a git worktree of its own, and a move is ONE rename(2) of that link
# (bin/fleet-versions-lib.sh — the client's switch shares it). A script already
# running keeps the files it opened (and every sibling it reaches by its
# physical path); the next call through ~/.claude/fleet reads the new version.
# So a busy session no longer holds the machine back: this tick used to wait
# for every window to go idle, and on 2026-10-06 the busiest machine sat 9h+ on
# the old version while stable moved on. A running EPIC batch IS a reason to
# wait (issue #2062, EPIC #2074 C1 — the 10-06 call to switch under a batch was
# taken back after EPIC #1935's last member ran on a new floor and its skill
# text changed mid-batch): one mark per batch in global/epic-running.d/, and
# while ANY is fresh the tick is `deferred` BEFORE the switch (the EPIC gate
# below), never `switched`. What every version shares
# — logs/, epic-pages/, the fleet.conf backups, anything else untracked at the
# top level — lives once in fleet.versions/.shared/ and is linked into each
# version. fleet.versions/.prev names the version before the last switch; a
# retired version is kept FLEET_INSTALL_VERSIONS_KEEP_SECS (7 days) for the
# sessions still running from it, then removed. The checkout that was the
# install before the first switch holds the repository (its .git/) and is never
# removed. MIGRATION: a plain-directory install is adopted at its first move —
# moved to fleet.versions/<its HEAD>/ and the link put in its place.
#
# One tick, in order (each gate is a line in the state file + one log line):
#
#   off        FLEET_INSTALL_SYNC=0 (this login's fleet.conf / fleet.settings)
#              → nothing is fetched or moved. Default 1 (on).
#   fetch      `git fetch --no-tags origin +refs/tags/stable:refs/tags/stable`
#              over https, no credentials, bounded by --timeout (git's own
#              low-speed abort — macOS has no timeout(1)). A fetch that fails is
#              `fetch-failed`: NOT seen, NOT a refusal, NOT an alarm (R4 #1125
#              alarms on refused / rolled-back / long deferrals only). No tag on
#              the remote is `none`. The + is deliberate: a clone auto-follows the
#              tag once and a later plain fetch would refuse to move it
#              ("would clobber existing tag"), leaving a stale local `stable`.
#   current    HEAD == stable → nothing to do.
#   skipped    stable == the version the doctor rejected last time (`skip:` in
#              the state) → not retried until stable moves again. No flapping.
#   refused    stable is not a DESCENDANT of HEAD (a backward move, or this
#              install carries commits trunk does not — a hand sync pushed
#              HEAD past stable, #1117 risk table) → never moves backward or
#              sideways; the next stable move past HEAD aligns it.
#   refused    TRACKED local changes → never touched; the doctor names them.
#              Untracked litter (fleet.conf.bak*) is fine.
#   deferred   the disk gate is closed (fleet-diskguard.sh --gate) — a new
#              version is a new checkout. `deferred_since` keeps the first
#              deferral's time so the doctor (C7 #1123) can say "waiting 26h".
#              Busy windows no longer defer (#1894); a fresh EPIC mark — any
#              batch on this login, fleet_epic_running_fresh — does (#953,
#              #2062), before the switch: the loop's pane and its workers are
#              idle between ticks, so no busy gate can see a batch.
#   switched   the new version checked out beside the old one
#              (`git worktree add` → fleet.versions/<stable>/), checked (every
#              bin/*.sh parses with `bash -n`, every bin/ + hooks/ *.py
#              compiles), the link switched, then the NEW version's
#              bin/fleet-install-apply.sh --from <old> --to <stable> (C2 #1119:
#              the one implementation of "sync once" — daemons reloaded, hooks
#              merged, commands/skills installed) → the NEW version's
#              bin/fleet-doctor.sh.
#   rolled-back the check failed (nothing switched), or the doctor printed a
#              FAIL line the pre-update doctor did NOT (a FAIL this login
#              already had — a stale quota cache, a missing tool — is not the
#              new version's fault and must not roll every version back forever;
#              WARN lines never count) → the link back to the old version (.prev
#              names the rejected one) → the OLD version's apply --from <stable>
#              --to <old> → `skip: <stable>` recorded, so this version is not
#              retried until stable moves.
#
# NODE → the node agent follows too (issue #1723, EPIC #1718 C5). A tick that
# ends `current` or `switched` (the install IS stable) then asks THIS version's
# bin/fleet-node-upgrade.sh for the plan at stable (`--dry-run`): every login on
# the machine whose ccquota agent is not prod-<stable short> — on disk, or as the
# hub sees it running — is behind. A tokenledger/ change is the usual reason,
# but the version string is the test, so a stable move with no agent change
# still brings every agent to the version the hub's /v1/nodes reports. Behind →
#   fleet-node-upgrade.sh <stable> --dist --rollback --logins <login…>
# — the hub's /v1/node/dist binary first (SHA-256 + version checked), a local
# build only when the hub has none; one login at a time, each confirmed on the
# hub; a login that never comes back goes back to its .prev bytes. Which logins:
# this login's own LaunchAgent; a LaunchDaemon login needs `sudo -n`, so a login
# that has it (the admin login) upgrades every behind login on the machine, its
# own first, and one that has not leaves its own to that tick (`delegated`).
# Only at an idle moment: the agent half keeps the busy gate the install switch
# dropped (#1894), and the EPIC gate both halves have (#2062). A failure is `node_upgrade_failed`
# — ONE FLEET_NOTIFY_CMD per (login · stable), a `node-node_upgrade_failed` log
# line, and no retry of that stable for FLEET_NODE_FOLLOW_RETRY_SECS (6h,
# `backoff`) — so a broken machine never loops and the other logins never wait
# on it. FLEET_NODE_FOLLOW=0 switches this half off; a version without
# fleet-node-upgrade.sh, or a machine with no agent service, records nothing to do.
#
# TEAM → the hub's team layer follows too (issue #1726, EPIC #1718 C8). Every
# tick that gets as far as finish (any result, never --dry-run) runs THIS
# install's bin/fleet-agent-team.py sync: the team version on the hub moved →
# the layer is composed again (fleet default < team < local, the login's own
# writes always win) and one `team` log line is written; unchanged → nothing. No
# hub configured is nothing at all. The state's `team:` line is its last word.
#
# STUCK → ONE notification (R4 #1125). The doctor's install row (C7 #1123) WARNs
# on a stuck login, but nobody runs the doctor on the days nobody is looking, so
# the tick that turns stuck says so itself — over FLEET_NOTIFY_CMD, the same
# channel quotawatch / diskguard / the collector use (nothing when it is unset).
# Stuck is what the doctor calls STUCK: `refused`, `rolled-back` (and the
# `skipped` ticks that follow it — the same episode), `failed`, or `deferred`
# (the disk gate) longer than FLEET_INSTALL_FOLLOW_STUCK_SECS (24h).
# Dedup key = login + why + stable (`notified:` in the state): the same stuck
# tick again is silent; a tick that is NOT stuck (`current`, `switched`, `off`, a
# short `deferred`) clears the key, so a login that followed and then stuck
# again — even for the same reason — is announced again. `fetch-failed` / `none`
# say nothing about the login and leave the key as it was. A send that fails is
# not recorded, so the next tick retries; the message names the login, the
# reason and how to silence it (FLEET_INSTALL_SYNC=0). Never under --dry-run
# (it prints `notify: would send` instead).
#
# State (for the doctor, C7): $FLEET_CONF_DIR/global/install-sync.state, one
# `key: value` per line, rewritten atomically every tick —
#   last_check: <epoch>  last_check_iso: <UTC>  result: <token above>
#   head: <sha>  stable: <sha>|none  from: <sha>  to: <sha>  reason: <text>
#   deferred_since: <epoch>|-  skip: <sha>|-  apply: <apply's last line>|-
#   notified: <login> <why> <stable>|-  notified_at: <epoch>|-
#   node: <current|upgraded|node_upgrade_failed|backoff|deferred|delegated|
#         none|off|check-failed>|-  node_reason: <text>|-
#   node_failed_at: <epoch>|-  node_fail_stable: <sha>|-  node_notified: <key>|-
#   team: <fleet-agent-team.py's last line>|-
# Log: $ROOT/logs/install-sync.log, ONE line per tick —
#   <UTC> <result> <from>..<to> <reason>
# — plus ONE `node-<node result>` line in the same shape when the agent step
# did something (upgraded / failed / backoff / delegated / deferred / check-failed)
# — plus ONE `notified` line per notification that went out (the send log):
#   <UTC> notified <from>..<to> <login> <why> <stable> via <FLEET_NOTIFY_CMD>
# The apply and doctor transcripts go to stderr (the launchd/systemd log).
#
# Log results: current · switched · rolled-back · refused · deferred · skipped ·
# off · none · fetch-failed · failed (`updated` was a pre-#1894 move in place).
#
# Ships as launchd/com.claude-fleet.install-sync.plist.tmpl (StartInterval 1800,
# ProcessType Standard — it rewrites bin/ under every other daemon, issue #588)
# and systemd/claude-fleet-install-sync.{service,timer}. It is installed by the
# same apply step it drives (an added template is installed + loaded), in the
# shape this login's daemons already have (gui LaunchAgent, or system
# LaunchDaemon + UserName — apply decides). Switch it off per login with
# FLEET_INSTALL_SYNC=0.
#
# A tick that moves the install switches THIS script's link: the whole body is
# a function and the last line is `main "$@"; exit`, so bash has parsed
# everything it will ever run before the link moves under it.
#
# Exit: always 0 from a tick (a daemon's exit code is nobody's signal — the
# state file is); 2 on a usage error; --status exits 0 (state printed) / 1 (none).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# scheduling heartbeat (issue #639) — guarded source, stamped before any exit
# shellcheck source=/dev/null
[ -f "$BIN/fleet-daemon-lib.sh" ] && { . "$BIN/fleet-daemon-lib.sh"
  fleet_daemon_stamp_tick install-sync "$BIN/.."; }
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-versions-lib.sh"

ROOT="${FLEET_INSTALL_ROOT:-$(cd "$BIN/.." && pwd)}"
REMOTE=origin TAG=stable TIMEOUT="${FLEET_INSTALL_SYNC_TIMEOUT:-30}"
DRY=0 STATUS=0
BUSY_STATES='working|looping|waking'
# A Loop parked between rounds (issue #1690) is busy only when its next round is
# this close: an apply + doctor finish well inside it.
LOOP_MARGIN="${FLEET_INSTALL_LOOP_MARGIN_SECS:-600}"
case "$LOOP_MARGIN" in ''|*[!0-9]*) LOOP_MARGIN=600 ;; esac
LOCK_TTL=3600   # an apply + two doctor runs take well under a minute; older = a dead tick
# A deferral this long is STUCK (the doctor's own threshold, C7) — and the alarm's.
STUCK_SECS="${FLEET_INSTALL_FOLLOW_STUCK_SECS:-86400}"
case "$STUCK_SECS" in ''|*[!0-9]*) STUCK_SECS=86400 ;; esac
NOTIFY_BUDGET=30   # a notifier that hangs must not hold the tick lock
# A failed agent upgrade is not retried on the same stable for this long (#1723).
NODE_RETRY="${FLEET_NODE_FOLLOW_RETRY_SECS:-21600}"
case "$NODE_RETRY" in ''|*[!0-9]*) NODE_RETRY=21600 ;; esac
LOGIN=$(id -un 2>/dev/null || printf '%s' "${USER:-?}")
HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '?')

usage() { sed -n '2,154p' "$0" | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --status)     STATUS=1 ;;
    --root)       shift; ROOT="${1:-}" ;;
    --remote)     shift; REMOTE="${1:-origin}" ;;
    --timeout)    shift; TIMEOUT="${1:-30}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            printf 'fleet-install-sync: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=30 ;; esac
ROOT=${ROOT%/}
# run by its physical path (from inside a version dir): the install is the
# link that fleet.versions/ belongs to
case "$ROOT" in *.versions/*) [ -L "${ROOT%.versions/*}" ] && ROOT=${ROOT%.versions/*} ;; esac
VERS="$ROOT.versions"
# a retired version is kept this long for the sessions still running from it
VKEEP="${FLEET_INSTALL_VERSIONS_KEEP_SECS:-604800}"
case "$VKEEP" in ''|*[!0-9]*) VKEEP=604800 ;; esac

CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
STATE_DIR="$CONF_DIR/global"
STATE="$STATE_DIR/install-sync.state"
LOCK="$STATE_DIR/install-sync.lock"
LOGF="$ROOT/logs/install-sync.log"

now() { date +%s; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"; }
short() { printf '%.7s' "${1:-}"; }
say() { printf 'fleet-install-sync: %s\n' "$*" >&2; }

# git with the network bounded: git's own stall abort, the only portable timeout.
g() { git -C "$ROOT" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$TIMEOUT" "$@"; }

# state_get <key> — one value from the previous state file ('' when absent).
state_get() { [ -f "$STATE" ] && sed -n "s/^$1: //p" "$STATE" | head -1; }

# The whole record, rewritten atomically. Globals: HEAD_SHA STABLE_SHA FROM TO
# DEFERRED_SINCE SKIP APPLY_LINE NOTIFIED NOTIFIED_AT NODE NODE_REASON
# NODE_FAILED_AT NODE_FAIL_STABLE NODE_NOTIFIED.
write_state() { # $1 result $2 reason
  local tmp t
  t=$(now)
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp="$STATE.tmp.$$"
  {
    printf 'last_check: %s\n' "$t"
    printf 'last_check_iso: %s\n' "$(utc)"
    printf 'result: %s\n' "$1"
    printf 'head: %s\n' "${HEAD_SHA:-?}"
    printf 'stable: %s\n' "${STABLE_SHA:-none}"
    printf 'from: %s\n' "${FROM:-${HEAD_SHA:-?}}"
    printf 'to: %s\n' "${TO:-${HEAD_SHA:-?}}"
    printf 'reason: %s\n' "$2"
    printf 'deferred_since: %s\n' "${DEFERRED_SINCE:--}"
    printf 'skip: %s\n' "${SKIP:--}"
    printf 'apply: %s\n' "${APPLY_LINE:--}"
    printf 'notified: %s\n' "${NOTIFIED:--}"
    printf 'notified_at: %s\n' "${NOTIFIED_AT:--}"
    printf 'node: %s\n' "${NODE:--}"
    printf 'node_reason: %s\n' "${NODE_REASON:--}"
    printf 'node_failed_at: %s\n' "${NODE_FAILED_AT:--}"
    printf 'node_fail_stable: %s\n' "${NODE_FAIL_STABLE:--}"
    printf 'node_notified: %s\n' "${NODE_NOTIFIED:--}"
    printf 'team: %s\n' "${TEAM:--}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

log_line() { # $1 result $2 reason
  [ -d "$ROOT/logs" ] || mkdir -p "$ROOT/logs" 2>/dev/null || return 0
  printf '%s %s %s..%s %s\n' "$(utc)" "$1" "$(short "${FROM:-${HEAD_SHA:-?}}")" \
    "$(short "${TO:-${HEAD_SHA:-?}}")" "$2" >> "$LOGF" 2>/dev/null
}

# stuck_key <result> <why> — the dedup key of a STUCK tick (login + why + the
# stable it cannot reach), nothing when the tick is not stuck. `why` is the
# refusal's kind (behind / diverged / dirty / nogit / nohead / ff), so a dirty
# tree whose file list changes is still one episode; a deferral is one episode
# whatever keeps it waiting (busy, then the disk gate — deferred_since is one
# clock), so `deferred` carries no kind; the ticks after a rollback (`skipped`)
# are the rollback's own episode.
stuck_key() {
  local why=''
  case "$1" in
    refused)     why="refused${2:+/$2}" ;;
    rolled-back) why=rolled-back ;;
    skipped)     why=rolled-back ;;
    failed)      why=failed ;;
    deferred)    [ -n "$DEFERRED_SINCE" ] && [ $(( $(now) - DEFERRED_SINCE )) -ge "$STUCK_SECS" ] && why=deferred ;;
  esac
  [ -n "$why" ] || return 0
  printf '%s %s %s\n' "$LOGIN" "$why" "${STABLE_SHA:-?}"
}

# notify_stuck <result> <reason> — ONE FLEET_NOTIFY_CMD per stuck episode
# (issue #1125): sets NOTIFIED / NOTIFIED_AT for write_state and appends the
# `notified` line to the log when a message went out. A non-stuck tick clears
# the key; fetch-failed / none leave it. A failed or budget-killed send is not
# recorded, so the next tick tries again. Never exits, never fails the tick.
notify_stuck() {
  local key hint msg rc cmd
  case "$1" in fetch-failed|none) return 0 ;; esac
  key=$(stuck_key "$1" "${3:-}")
  if [ -z "$key" ]; then NOTIFIED=''; NOTIFIED_AT=''; return 0; fi
  [ "$key" = "$NOTIFIED" ] && return 0                    # this episode was announced
  if [ "$DRY" = 1 ]; then printf 'notify: would send (%s)\n' "$key"; return 0; fi
  NOTIFIED=''; NOTIFIED_AT=''
  if [ -z "${FLEET_NOTIFY_CMD:-}" ]; then
    say "stuck ($key) and no FLEET_NOTIFY_CMD — nobody to tell (fleet-doctor.sh → install shows it)"; return 0
  fi
  case "$1" in
    deferred)
      case "$2" in
        "EPIC batch running"*) hint="Waited $(( ($(now) - DEFERRED_SINCE) / 3600 ))h so far (since $(iso_of "$DEFERRED_SINCE")) — a batch marked running this long is usually a loop that died without its closing tick: \`fleet-epic-heartbeat.sh --status\` names it; a mark expires 45 min after its last tick, or \`--clear <N>\` it by hand." ;;
        *) hint="Waited $(( ($(now) - DEFERRED_SINCE) / 3600 ))h so far (since $(iso_of "$DEFERRED_SINCE")) — a session busy this long is usually a stuck one: check \`fleet-doctor.sh\`, or its dash." ;;
      esac ;;
    skipped)  hint="It rolled back after the doctor failed on this version; nothing is retried until stable moves (\`fleet-stable.sh move\`)." ;;
    *)        hint="The reason above says what to do; \`fleet-install-sync.sh --status\` has the whole record." ;;
  esac
  msg="# install-sync stuck — ${LOGIN}@${HOST}
**${LOGIN}**'s fleet install ($ROOT) is at $(short "${HEAD_SHA:-?}") and not following stable $(short "${STABLE_SHA:-?}") — **$1**: $2
$hint
One notice per (login · reason · stable); it re-arms once this login follows again. Silence it for this login with \`FLEET_INSTALL_SYNC=0\` in ~/.config/claude-fleet/fleet.settings."
  # shellcheck disable=SC2086  # FLEET_NOTIFY_CMD is a command line, split on purpose (quotawatch does the same)
  fleet_timebox "$NOTIFY_BUDGET" $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ]; then
    say "notify ($key) failed: $FLEET_NOTIFY_CMD exit $rc — retried next tick"; return 0
  fi
  NOTIFIED="$key"; NOTIFIED_AT=$(now)
  cmd=${FLEET_NOTIFY_CMD%% *}; cmd=${cmd##*/}
  [ -d "$ROOT/logs" ] || mkdir -p "$ROOT/logs" 2>/dev/null || return 0
  printf '%s notified %s..%s %s via %s\n' "$(utc)" "$(short "${FROM:-${HEAD_SHA:-?}}")" \
    "$(short "${TO:-${HEAD_SHA:-?}}")" "$key" "$cmd" >> "$LOGF" 2>/dev/null
  say "notified ($key) via $cmd"
}

# node_follow <tick result> — the agent half (issue #1723; the header's NODE
# paragraph). Sets NODE / NODE_REASON (+ the failure fields) for write_state,
# writes its own log line when it did something, never exits, never fails the tick.
node_follow() {
  local nu plan rc cand self_dom sel others out msg cmd key
  if [ "${FLEET_NODE_FOLLOW:-1}" = 0 ]; then
    NODE=off; NODE_REASON='FLEET_NODE_FOLLOW=0 — this login does not upgrade the node agent'; return 0
  fi
  nu="${FLEET_INSTALL_NODE_UPGRADE:-$ROOT/bin/fleet-node-upgrade.sh}"
  [ -f "$nu" ] || { NODE=''; NODE_REASON=''; return 0; }
  # A stable move clears the last one's failure: the new version gets its try.
  [ -n "$NODE_FAIL_STABLE" ] && [ "$NODE_FAIL_STABLE" != "$STABLE_SHA" ] && { NODE_FAIL_STABLE=''; NODE_FAILED_AT=''; }
  plan=$(bash "$nu" "$STABLE_SHA" --dist --dry-run 2>&1 </dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    case "$plan" in
      *"no ccquota agent service"*|*"macOS (launchd) only"*)
        NODE=none; NODE_REASON='no ccquota agent service on this machine'; return 0 ;;
    esac
    NODE=check-failed; NODE_REASON="fleet-node-upgrade.sh --dry-run exit $rc: $(printf '%s\n' "$plan" | tail -1)"
    node_log; return 0
  fi
  # `  <login>  <domain>/<label>  <path>  disk … · hub …  → upgrade`
  cand=$(printf '%s\n' "$plan" | awk '/→ upgrade$/ { split($2, d, "/"); print $1, d[1] }')
  if [ -z "$cand" ]; then
    NODE=current; NODE_REASON="every agent on this machine runs prod-$(short "$STABLE_SHA")"
    NODE_FAILED_AT=''; NODE_FAIL_STABLE=''; NODE_NOTIFIED=''; return 0
  fi
  self_dom=$(printf '%s\n' "$cand" | awk -v me="$LOGIN" '$1 == me {print $2; exit}')
  others=$(printf '%s\n' "$cand" | awk -v me="$LOGIN" '$1 != me {printf "%s ", $1}')
  # shellcheck disable=SC2086  # a command line, split on purpose
  if [ -n "$others" ] || [ "$self_dom" = system ] && ${FLEET_INSTALL_NODE_SUDO_CHECK:-sudo -n true} >/dev/null 2>&1 </dev/null; then
    sel="${self_dom:+$LOGIN }$others"
  elif [ "$self_dom" = gui ]; then
    sel="$LOGIN"
  elif [ "$self_dom" = system ]; then
    NODE=delegated; NODE_REASON="this login's agent is a LaunchDaemon and sudo -n is not available here — an admin login's tick upgrades it to prod-$(short "$STABLE_SHA")"
    node_log; return 0
  else
    NODE=current; NODE_REASON="this login's agent runs prod-$(short "$STABLE_SHA"); behind: ${others% } — an admin login's tick upgrades them"
    return 0
  fi
  sel=${sel% }
  if [ -n "$NODE_FAILED_AT" ] && [ $(( $(now) - NODE_FAILED_AT )) -lt "$NODE_RETRY" ]; then
    NODE=backoff; NODE_REASON="the upgrade to prod-$(short "$STABLE_SHA") failed at $(iso_of "$NODE_FAILED_AT") — next try after $(iso_of $((NODE_FAILED_AT + NODE_RETRY)))"
    node_log; return 0
  fi
  # The install switch no longer waits for idle (#1894); an agent restart still
  # does — and a fresh EPIC mark stops the switch itself above (#2062), so this
  # read only matters on a `current` tick.
  local epic busy
  if epic=$(fleet_epic_running_fresh 2>/dev/null); then
    NODE=deferred; NODE_REASON="EPIC batch running ($epic) — the agent waits for the closing tick"; node_log; return 0
  fi
  busy=$(busy_fleets | tr '\n' ' ')
  if [ -n "$busy" ]; then
    NODE=deferred; NODE_REASON="busy window(s) on ${busy% } — the agent waits for an idle tick"; node_log; return 0
  fi
  if [ "$DRY" = 1 ]; then printf 'node: would upgrade %s to prod-%s (fleet-node-upgrade.sh --dist --rollback)\n' "$sel" "$(short "$STABLE_SHA")"; return 0; fi
  say "node: upgrading $sel to prod-$(short "$STABLE_SHA")"
  # shellcheck disable=SC2086  # $sel is a list of login names
  out=$(bash "$nu" "$STABLE_SHA" --dist --rollback --logins $sel 2>&1 </dev/null); rc=$?
  printf '%s\n' "$out" | sed 's/^/    node: /' >&2
  if [ "$rc" = 0 ]; then
    NODE=upgraded; NODE_REASON=$(printf '%s\n' "$out" | grep '^done: ' | tail -1)
    [ -n "$NODE_REASON" ] || NODE_REASON=$(printf '%s\n' "$out" | tail -1)
    NODE_FAILED_AT=''; NODE_FAIL_STABLE=''; NODE_NOTIFIED=''
    node_log; return 0
  fi
  NODE=node_upgrade_failed
  NODE_REASON=$(printf '%s\n' "$out" | grep 'FAIL' | tail -1 | sed 's/^fleet-node-upgrade: FAIL — //')
  [ -n "$NODE_REASON" ] || NODE_REASON="fleet-node-upgrade.sh exit $rc: $(printf '%s\n' "$out" | tail -1)"
  NODE_FAILED_AT=$(now); NODE_FAIL_STABLE="$STABLE_SHA"
  node_log
  key="$LOGIN node_upgrade_failed $STABLE_SHA"
  [ "$key" = "$NODE_NOTIFIED" ] && return 0
  if [ -z "${FLEET_NOTIFY_CMD:-}" ]; then say "node_upgrade_failed and no FLEET_NOTIFY_CMD — nobody to tell"; return 0; fi
  msg="# node agent upgrade failed — ${LOGIN}@${HOST}
The ccquota agent of **${sel}** did not come up on prod-$(short "$STABLE_SHA"): ${NODE_REASON}
It stays on the old binary; the other logins are untouched. Retried no sooner than $(iso_of $((NODE_FAILED_AT + NODE_RETRY))), or at once when stable moves. \`fleet-node-upgrade.sh --status\` shows every login; switch this off with \`FLEET_NODE_FOLLOW=0\`."
  # shellcheck disable=SC2086
  if fleet_timebox "$NOTIFY_BUDGET" $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1; then
    NODE_NOTIFIED="$key"
    cmd=${FLEET_NOTIFY_CMD%% *}; cmd=${cmd##*/}
    printf '%s notified %s..%s %s via %s\n' "$(utc)" "$(short "${FROM:-${HEAD_SHA:-?}}")" \
      "$(short "${TO:-${HEAD_SHA:-?}}")" "$key" "$cmd" >> "$LOGF" 2>/dev/null
  else
    say "notify ($key) failed — retried next failure"
  fi
  return 0
}
node_log() { [ "$DRY" = 1 ] && { printf 'node: %s — %s\n' "$NODE" "$NODE_REASON"; return 0; }; log_line "node-$NODE" "$NODE_REASON"; }

# team_follow — the team layer (issue #1726): fetch + compose when the hub's
# version moved. TEAM = its last line; one `team-…` log line when it applied or
# failed. No hub (exit 3) → TEAM stays as it was, nothing logged.
team_follow() {
  local tt out rc
  tt="$ROOT/bin/fleet-agent-team.py"
  [ -f "$tt" ] && command -v python3 >/dev/null 2>&1 || return 0
  out=$(python3 "$tt" sync 2>&1); rc=$?
  [ "$rc" = 3 ] && return 0
  TEAM=$(printf '%s\n' "$out" | grep '^team: ' | tail -1 | sed 's/^team: //')
  [ -n "$TEAM" ] || TEAM="exit $rc: $(printf '%s\n' "$out" | tail -1)"
  case "$rc:$out" in
    0:*'item(s)'*) log_line team "$TEAM" ;;
    0:*) ;;
    *) log_line team-failed "$TEAM" ;;
  esac
}

# finish <result> <reason> [why] — notify if newly stuck, record, log, leave.
# Under --dry-run, print only (and what a real tick would notify).
finish() {
  if [ "$DRY" = 1 ]; then
    printf '%s: %s\n' "$1" "$2"; notify_stuck "$1" "$2" "${3:-}"
    case "$1" in current) node_follow "$1" ;; esac
    exit 0
  fi
  notify_stuck "$1" "$2" "${3:-}"
  team_follow
  # The install is stable now: the node agent follows it (issue #1723). Logged
  # AFTER the tick's own line, so a grep of the result stays the first field.
  local nodeq=0
  case "$1" in current|switched) nodeq=1 ;; esac
  if [ "$nodeq" = 1 ]; then
    log_line "$1" "$2"; say "$1 — $2"
    node_follow "$1"
    write_state "$1" "$2"
    exit 0
  fi
  write_state "$1" "$2"
  log_line "$1" "$2"
  say "$1 — $2"
  exit 0
}

# The FAIL tags of one doctor run (`  FAIL  <tag>  …`), sorted unique. Colour is
# off when stdout is not a tty, so the columns are plain. A doctor this version
# does not ship → nothing (never a FAIL).
doctor_fail_tags() {
  [ -f "$ROOT/bin/fleet-doctor.sh" ] || return 0
  local out
  out=$(sh "$ROOT/bin/fleet-doctor.sh" 2>&1 </dev/null)
  printf '%s\n' "$out" | sed 's/^/    doctor: /' >&2
  printf '%s\n' "$out" | awk '$1 == "FAIL" && NF >= 2 { print $2 }' | sort -u
}

# Busy windows across every live fleet of THIS login: "<sess>:<n>" per fleet that
# has any, one line each; nothing when the machine is quiet. No fleet conf, no
# tmux on PATH, no live server — all read as quiet: there is no session to defer to.
# A `looping` window whose ONLY wait is its Loop (@claude_wait = loop) is idle
# between rounds — `looping` is written at Stop, and a round that starts writes
# `working` — so it is busy only while a round may start within LOOP_MARGIN
# (fleet_loop_mark.py due, issue #1690): a cron that fires tomorrow morning no
# longer pins the install for the night. Unknown (a pre-#1690 mark, a loop
# ledger, a children / bg wait, a classifier `looping` with no wait) stays busy.
busy_fleets() {
  local sess n st wt lp mf
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    n=0
    while IFS='|' read -r st wt lp mf; do
      case "|$BUSY_STATES|" in *"|$st|"*) ;; *) continue ;; esac
      if [ "$st" = looping ] && [ "$wt" = loop ] \
         && ! python3 "$BIN/fleet_loop_mark.py" due --value "$lp" --manifest "$mf" \
              --within "$LOOP_MARGIN" >/dev/null 2>&1 </dev/null; then
        continue
      fi
      n=$((n + 1))
    done <<WIN
$(fleet_lw '#{@claude_state}|#{@claude_wait}|#{@loop}|#{@handoff_manifest}' tmux -L "$sess")
WIN
    [ "$n" -gt 0 ] && printf '%s:%s\n' "$sess" "$n"
  done <<EOF
$(fleet_sockets 2>/dev/null)
EOF
  return 0
}

# --- versions (issue #1894) -----------------------------------------------------
# vers_build <sha> — a git worktree of <sha> at $VERS/<sha>/ on its own branch
# fleet-live/<key> (tracking the install's trunk, so `git pull --ff-only` in it
# still works), printed. A stale dir of that name is replaced — unless it is the
# version in use, which gets a fresh name instead.
vers_build() {
  local vsha="$1" vd up
  vd="$VERS/$vsha"
  if [ -e "$vd" ]; then
    if [ "$(fleet_versions_current "$ROOT")" = "$vsha" ]; then vd="$VERS/$vsha-$(now)"; else vers_drop "$vd"; fi
  fi
  [ -e "$vd" ] && return 1
  mkdir -p "$VERS" || return 1
  up=$(git -C "$ROOT" rev-parse -q --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=''
  [ -n "$up" ] || up=$(git -C "$ROOT" symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null) || up=''
  [ -n "$up" ] || up="$REMOTE/master"
  git -C "$ROOT" worktree add -q -B "fleet-live/${vd##*/}" "$vd" "$vsha" >/dev/null 2>&1 </dev/null || { rm -rf "$vd"; return 1; }
  git -C "$vd" branch -q --set-upstream-to="$up" >/dev/null 2>&1 </dev/null || :
  printf '%s\n' "$vd"
}

# vers_check <dir> — every bin/*.sh parses (bash -n) and every bin/ + hooks/ *.py
# compiles. rc 1 + the first broken file on stdout.
vers_check() {
  local f
  for f in "$1"/bin/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null </dev/null || { printf '%s does not parse (bash -n)\n' "${f#"$1"/}"; return 1; }
  done
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import glob, os, sys
root = sys.argv[1]
for d in ("bin", "hooks"):
    for f in sorted(glob.glob(os.path.join(root, d, "*.py"))):
        try:
            with open(f, encoding="utf-8") as fh:
                compile(fh.read(), f, "exec")
        except Exception:
            print("%s does not compile (python3)" % os.path.relpath(f, root))
            sys.exit(1)' "$1" </dev/null
}

# vers_shared <dir> — what every version shares: <dir>'s top-level untracked or
# ignored entries (logs/, epic-pages/, fleet.conf.bak*, …) move to
# $VERS/.shared/ and are linked back; then every .shared entry <dir> lacks is
# linked in. A name .shared already holds is left where it is.
vers_shared() {
  local vd="$1" p
  [ -d "$vd" ] || return 0
  mkdir -p "$VERS/.shared" 2>/dev/null || return 0
  while IFS= read -r p; do
    p=${p%/}
    case "$p" in ''|*/*|.git|__pycache__|.DS_Store|*.switch.*) continue ;; esac
    [ -L "$vd/$p" ] && continue
    { [ -e "$VERS/.shared/$p" ] || [ -L "$VERS/.shared/$p" ]; } && continue
    mv "$vd/$p" "$VERS/.shared/$p" 2>/dev/null || continue
    [ -e "$vd/$p" ] || ln -s "../.shared/$p" "$vd/$p" 2>/dev/null
  done <<SHARED
$(git -C "$vd" status --porcelain --ignored --untracked-files=normal 2>/dev/null </dev/null | awk '$1 == "??" || $1 == "!!" { print substr($0, 4) }')
SHARED
  for p in "$VERS/.shared"/* "$VERS/.shared"/.[!.]*; do
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    p=${p##*/}
    { [ -e "$vd/$p" ] || [ -L "$vd/$p" ]; } || ln -s "../.shared/$p" "$vd/$p" 2>/dev/null
  done
  return 0
}

# vers_retire <key> / vers_unretire <key> — when a version stopped being the one
# in use; vers_prune counts its keep time from here.
vers_retire() { mkdir -p "$VERS/.retired" 2>/dev/null && now > "$VERS/.retired/$1"; }
vers_unretire() { rm -f "$VERS/.retired/$1"; }

# vers_drop <dir> — one version dir and its branch, gone. Never the checkout
# that holds the repository (a .git DIRECTORY), never the one in use.
vers_drop() {
  local vd="$1"
  [ -d "$vd/.git" ] && return 1
  [ "$(fleet_versions_current "$ROOT")" = "${vd##*/}" ] && return 1
  git -C "$ROOT" worktree remove --force "$vd" >/dev/null 2>&1 </dev/null || rm -rf "$vd"
  git -C "$ROOT" worktree prune >/dev/null 2>&1 </dev/null
  git -C "$ROOT" branch -q -D "fleet-live/${vd##*/}" >/dev/null 2>&1 </dev/null
  [ ! -e "$vd" ]
}

# vers_prune — every version but the one in use, .prev's and the repository's,
# once retired longer than VKEEP. A dir with no retire time starts its clock now.
vers_prune() {
  local cur prev='' vd n t
  cur=$(fleet_versions_current "$ROOT")
  { read -r prev < "$VERS/.prev"; } 2>/dev/null
  for vd in "$VERS"/*/; do
    vd=${vd%/}; n=${vd##*/}
    [ -d "$vd" ] || continue
    case "$n" in "$cur"|"$prev") continue ;; esac
    [ -d "$vd/.git" ] && continue
    t=$(cat "$VERS/.retired/$n" 2>/dev/null); case "$t" in ''|*[!0-9]*) vers_retire "$n"; continue ;; esac
    [ $(( $(now) - t )) -ge "$VKEEP" ] || continue
    vers_drop "$vd" && vers_unretire "$n" && say "pruned version $n"
  done
  return 0
}

run_apply() { # $1 from $2 to → APPLY_LINE + rc; transcript to stderr
  local out rc
  out=$(bash "$ROOT/bin/fleet-install-apply.sh" --from "$1" --to "$2" --root "$ROOT" 2>&1 </dev/null); rc=$?
  printf '%s\n' "$out" | sed 's/^/    apply: /' >&2
  APPLY_LINE=$(printf '%s\n' "$out" | grep '^apply: ' | tail -1 | sed 's/^apply: //')
  [ -n "$APPLY_LINE" ] || APPLY_LINE="exit $rc (no apply line)"
  return "$rc"
}

main() {
  HEAD_SHA='' STABLE_SHA='' FROM='' TO='' DEFERRED_SINCE='' SKIP='' APPLY_LINE='' NOTIFIED='' NOTIFIED_AT=''
  NODE='' NODE_REASON='' NODE_FAILED_AT='' NODE_FAIL_STABLE='' NODE_NOTIFIED=''
  TEAM=$(state_get team); [ "$TEAM" = - ] && TEAM=''

  if [ "$STATUS" = 1 ]; then
    if [ -f "$STATE" ]; then cat "$STATE"; exit 0; fi
    printf 'no state yet (%s) — no tick has run on this login\n' "$STATE"; exit 1
  fi

  # Carry the durable fields forward; every other line is this tick's.
  DEFERRED_SINCE=$(state_get deferred_since); [ "$DEFERRED_SINCE" = - ] && DEFERRED_SINCE=''
  SKIP=$(state_get skip); [ "$SKIP" = - ] && SKIP=''
  NOTIFIED=$(state_get notified); [ "$NOTIFIED" = - ] && NOTIFIED=''
  NOTIFIED_AT=$(state_get notified_at); [ "$NOTIFIED_AT" = - ] && NOTIFIED_AT=''
  # The agent half's record rides along on every tick; node_follow rewrites it.
  local k v
  for k in node node_reason node_failed_at node_fail_stable node_notified; do
    v=$(state_get "$k"); [ "$v" = - ] && v=''
    case "$k" in
      node) NODE="$v" ;; node_reason) NODE_REASON="$v" ;; node_failed_at) NODE_FAILED_AT="$v" ;;
      node_fail_stable) NODE_FAIL_STABLE="$v" ;; node_notified) NODE_NOTIFIED="$v" ;;
    esac
  done
  HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || :)

  # --- off ---------------------------------------------------------------------
  if [ "${FLEET_INSTALL_SYNC:-1}" = 0 ]; then
    DEFERRED_SINCE=''
    finish off 'FLEET_INSTALL_SYNC=0 — this login does not follow stable (set it to 1, or delete the line, to switch back on)'
  fi

  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || finish refused "$ROOT is not a git checkout — a file-copy install cannot follow stable (fleet-sync-logins.sh --to-git converts it)" nogit
  [ -n "$HEAD_SHA" ] || finish refused "$ROOT has no HEAD commit" nohead

  # --- one tick at a time (an apply + doctor may outlive a short interval) -----
  if [ "$DRY" = 0 ]; then
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
    # A holder SIGKILLed mid-tick (launchctl kickstart -k, OOM, a reboot) runs no
    # trap, so its lock stays behind (issue #1691): a holder whose pid is gone is
    # taken over at once; LOCK_TTL stays the backstop for a reused pid or a hung
    # holder. No pid yet (a holder between mkdir and the write) = the TTL alone.
    if ! mkdir "$LOCK" 2>/dev/null; then
      local lts lpid lage
      lts=$(cat "$LOCK/ts" 2>/dev/null); case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
      lpid=$(cat "$LOCK/pid" 2>/dev/null); case "$lpid" in *[!0-9]*) lpid='' ;; esac
      lage=$(( $(now) - lts ))
      if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
        say "took over $LOCK: holder pid=$lpid is dead (since $lts, ${lage}s ago)"
      elif [ "$lage" -lt "$LOCK_TTL" ]; then
        say "another tick holds $LOCK (pid=${lpid:-?} ${lpid:+alive }since $lts, ${lage}s ago) — skip"; exit 0
      else
        say "took over $LOCK: older than ${LOCK_TTL}s (pid=${lpid:-?}, since $lts)"
      fi
      rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
    fi
    now > "$LOCK/ts"; printf '%s' "$$" > "$LOCK/pid"
    # shellcheck disable=SC2329  # invoked via the traps below
    drop_lock() { rm -rf "$LOCK"; }
    trap drop_lock EXIT
    trap 'drop_lock; exit 130' INT
    trap 'drop_lock; exit 143' TERM
  fi

  # --- fetch the mark ----------------------------------------------------------
  local ferr
  if ! ferr=$(g fetch --no-tags -q "$REMOTE" "+refs/tags/$TAG:refs/tags/$TAG" 2>&1 </dev/null); then
    case "$ferr" in
      *"couldn't find remote ref"*|*"Couldn't find remote ref"*)
        STABLE_SHA=''
        finish none "no refs/tags/$TAG on $REMOTE yet — nothing to follow; the operator sets it with fleet-stable.sh move" ;;
    esac
    finish fetch-failed "could not read refs/tags/$TAG from $REMOTE (offline? timeout ${TIMEOUT}s) — not seen, not refused: $(printf '%s\n' "$ferr" | tail -1)"
  fi
  STABLE_SHA=$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null) \
    || finish fetch-failed "refs/tags/$TAG fetched but does not resolve to a commit"

  # A remembered rejection is about ONE version; stable moving on clears it.
  [ -n "$SKIP" ] && [ "$SKIP" != "$STABLE_SHA" ] && SKIP=''

  # --- nothing to do -------------------------------------------------------------
  if [ "$HEAD_SHA" = "$STABLE_SHA" ]; then
    DEFERRED_SINCE=''
    finish current "install at stable $(short "$STABLE_SHA")"
  fi
  FROM="$HEAD_SHA"; TO="$STABLE_SHA"
  if [ -n "$SKIP" ]; then
    DEFERRED_SINCE=''
    finish skipped "stable $(short "$STABLE_SHA") failed the doctor after the last update and was rolled back — not retried until stable moves (fleet-stable.sh move)"
  fi

  # --- the two refusals --------------------------------------------------------------
  if ! git -C "$ROOT" merge-base --is-ancestor "$HEAD_SHA" "$STABLE_SHA" 2>/dev/null; then
    DEFERRED_SINCE=''
    local rel why
    if git -C "$ROOT" merge-base --is-ancestor "$STABLE_SHA" "$HEAD_SHA" 2>/dev/null; then
      rel="behind this install ($(git -C "$ROOT" rev-list --count "$STABLE_SHA..$HEAD_SHA" 2>/dev/null) commit(s)) — a hand sync pushed HEAD past it"; why=behind
    else
      rel="not on this install's history (diverged)"; why=diverged
    fi
    finish refused "stable $(short "$STABLE_SHA") is not a descendant of HEAD $(short "$HEAD_SHA") — $rel; only ever fast-forwards, never moves back; the next stable move past HEAD aligns it" "$why"
  fi
  local dirty ndirty more=''
  dirty=$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null | awk 'NF {print $NF}')
  if [ -n "$dirty" ]; then
    ndirty=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
    [ "$ndirty" -gt 3 ] && more=" +$((ndirty - 3)) more"
    dirty=$(printf '%s\n' "$dirty" | head -3 | tr '\n' ' ')
    DEFERRED_SINCE=''
    finish refused "tracked local changes in $ROOT (${dirty% }$more) — not touching an edited install; commit or discard them, then the next tick follows" dirty
  fi

  # --- a running EPIC batch holds the switch (issue #953, back before the switch
  # with #2062) ---------------------------------------------------------------------
  # One mark per batch (global/epic-running.d/, fleet-epic-heartbeat.sh): ANY
  # fresh one defers the whole tick here, before anything is checked out — not
  # only the agent half below. The loop's pane and its workers are idle between
  # ticks, so no busy gate can see a batch; and a version switched under one
  # changes what its later members and its skill text run on (2026-10-07: EPIC
  # #1935's last member ran on a new floor). Every fresh batch is named, so the
  # log line shows who is holding the install.
  local epic
  if epic=$(fleet_epic_running_fresh 2>/dev/null); then
    [ -n "$DEFERRED_SINCE" ] || DEFERRED_SINCE=$(now)
    finish deferred "EPIC batch running on this login ($epic) — not switching the floor under a running batch (issues #953, #2062); each loop clears its own mark at its closing tick (fleet-epic-heartbeat.sh --clear <N>), else it expires"
  fi

  # --- the disk gate (busy windows no longer wait, #1894) ------------------------------
  if [ "$DRY" = 0 ] && [ -x "$ROOT/bin/fleet-diskguard.sh" ] \
     && ! "$ROOT/bin/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
    [ -n "$DEFERRED_SINCE" ] || DEFERRED_SINCE=$(now)
    finish deferred "disk gate closed (fleet-diskguard.sh --gate) — not checking out a new version below the floor"
  fi
  DEFERRED_SINCE=''

  if [ "$DRY" = 1 ]; then
    printf 'would switch %s %s..%s (check out %s/%s, check, switch the link), then fleet-install-apply.sh --from %s --to %s, then fleet-doctor.sh (dry-run)\n' \
      "$ROOT" "$(short "$HEAD_SHA")" "$(short "$STABLE_SHA")" "$VERS" "$STABLE_SHA" "$(short "$HEAD_SHA")" "$(short "$STABLE_SHA")"
    exit 0
  fi

  # --- switch ---------------------------------------------------------------------------------
  # Baseline first: FAIL lines this login already has are not the new version's.
  local pre post new oldkey olddir newdir newkey bad migrated=''
  say "switching $(short "$HEAD_SHA") -> $(short "$STABLE_SHA")"
  pre=$(doctor_fail_tags)
  # A plain-directory install becomes the versions layout first (migration):
  # moved to fleet.versions/<HEAD>/, the link in its place.
  if [ ! -L "$ROOT" ]; then
    oldkey="$HEAD_SHA"; [ -e "$VERS/$oldkey" ] && oldkey="$HEAD_SHA-$(now)"
    fleet_versions_adopt "$ROOT" "$oldkey" \
      || finish refused "could not move $ROOT into $VERS/ (the versions layout, #1894) — nothing changed; check the permissions on $(dirname "$ROOT")" adopt
    migrated="; $ROOT is now a link into $VERS/ (moved to $oldkey)"
    say "migrated: $ROOT -> $VERS/$oldkey"
  fi
  oldkey=$(fleet_versions_current "$ROOT"); olddir="$VERS/$oldkey"
  if ! newdir=$(vers_build "$STABLE_SHA"); then
    finish refused "could not check out stable $(short "$STABLE_SHA") into $VERS/ (git worktree add failed) — still at $(short "$HEAD_SHA")$migrated" build
  fi
  newkey=${newdir##*/}
  if ! bad=$(vers_check "$newdir"); then
    vers_retire "$newkey"
    SKIP="$STABLE_SHA"; FROM="$STABLE_SHA"; TO="$HEAD_SHA"
    finish rolled-back "pre-switch check failed at $(short "$STABLE_SHA"): $bad — nothing switched, still at $(short "$HEAD_SHA"); not retried until stable moves$migrated"
  fi
  vers_shared "$olddir"; vers_shared "$newdir"
  if ! fleet_versions_point "$ROOT" "$newdir"; then
    vers_retire "$newkey"
    finish failed "could not switch the link $ROOT -> $newdir — still at $(short "$HEAD_SHA")$migrated"
  fi
  printf '%s\n' "$oldkey" > "$VERS/.prev"; vers_retire "$oldkey"
  run_apply "$HEAD_SHA" "$STABLE_SHA" || :
  post=$(doctor_fail_tags)
  new=$(comm -13 <(printf '%s\n' "$pre" | sed '/^$/d') <(printf '%s\n' "$post" | sed '/^$/d') | tr '\n' ',')
  new=${new%,}
  if [ -z "$new" ]; then
    vers_prune
    finish switched "$(short "$HEAD_SHA") -> $(short "$STABLE_SHA") in one link switch (.prev $(short "$oldkey")); apply: ${APPLY_LINE}$([ -n "$post" ] && printf '; doctor FAIL already present before: %s' "$(printf '%s\n' "$pre" | tr '\n' ',' | sed 's/,$//')")$migrated"
  fi

  # --- roll back ----------------------------------------------------------------------------
  say "doctor FAIL after the switch: $new — back to $(short "$HEAD_SHA")"
  local fwd="$APPLY_LINE"
  if ! fleet_versions_point "$ROOT" "$olddir"; then
    SKIP="$STABLE_SHA"
    finish failed "doctor FAIL ($new) at $(short "$STABLE_SHA") and the link back to $olddir FAILED — the install is at $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null); fix by hand: ln -sfn $olddir $ROOT"
  fi
  printf '%s\n' "$newkey" > "$VERS/.prev"; vers_retire "$newkey"; vers_unretire "$oldkey"
  run_apply "$STABLE_SHA" "$HEAD_SHA" || :
  SKIP="$STABLE_SHA"
  FROM="$STABLE_SHA"; TO="$HEAD_SHA"
  finish rolled-back "doctor FAIL after the switch: $new — the link is back at $(short "$HEAD_SHA"); stable $(short "$STABLE_SHA") is not retried until it moves (forward apply: $fwd; rollback apply: $APPLY_LINE)"
}

main "$@"; exit
