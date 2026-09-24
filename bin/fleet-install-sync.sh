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
# (bin/fleet-stable.sh, C1 #1118) — never master, and only when nothing is busy.
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
#   deferred   any window on any of this login's live fleets is
#              working / looping / waking (the same busy trio
#              fleet-epic-backstop.sh uses) → wait; `deferred_since` keeps the
#              first deferral's time so the doctor (C7 #1123) can say
#              "waiting 26h". Also deferred while the disk gate is closed.
#   updated    `git merge --ff-only <stable>` → the NEW version's
#              bin/fleet-install-apply.sh --from <old> --to <stable> (C2 #1119:
#              the one implementation of "sync once" — daemons reloaded, hooks
#              merged, commands/skills installed) → the NEW version's
#              bin/fleet-doctor.sh.
#   rolled-back the doctor printed a FAIL line the pre-update doctor did NOT
#              (a FAIL this login already had — a stale quota cache, a missing
#              tool — is not the new version's fault and must not roll every
#              version back forever; WARN lines never count) →
#              `git reset --hard <old>` (safe: the tree was clean, see refused
#              above) → the OLD version's apply --from <stable> --to <old> →
#              `skip: <stable>` recorded, so this version is not retried until
#              stable moves.
#
# State (for the doctor, C7): $FLEET_CONF_DIR/global/install-sync.state, one
# `key: value` per line, rewritten atomically every tick —
#   last_check: <epoch>  last_check_iso: <UTC>  result: <token above>
#   head: <sha>  stable: <sha>|none  from: <sha>  to: <sha>  reason: <text>
#   deferred_since: <epoch>|-  skip: <sha>|-  apply: <apply's last line>|-
# Log: $ROOT/logs/install-sync.log, ONE line per tick:
#   <UTC> <result> <from>..<to> <reason>
# The apply and doctor transcripts go to stderr (the launchd/systemd log).
#
# Ships as launchd/com.claude-fleet.install-sync.plist.tmpl (StartInterval 1800,
# ProcessType Standard — it rewrites bin/ under every other daemon, issue #588)
# and systemd/claude-fleet-install-sync.{service,timer}. It is installed by the
# same apply step it drives (an added template is installed + loaded), in the
# shape this login's daemons already have (gui LaunchAgent, or system
# LaunchDaemon + UserName — apply decides). Switch it off per login with
# FLEET_INSTALL_SYNC=0.
#
# A tick that moves the install rewrites THIS script on disk: the whole body is
# a function and the last line is `main "$@"; exit`, so bash has parsed
# everything it will ever run before the tree changes under it.
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

ROOT="${FLEET_INSTALL_ROOT:-$(cd "$BIN/.." && pwd)}"
REMOTE=origin TAG=stable TIMEOUT="${FLEET_INSTALL_SYNC_TIMEOUT:-30}"
DRY=0 STATUS=0
BUSY_STATES='working|looping|waking'
LOCK_TTL=3600   # an apply + two doctor runs take well under a minute; older = a dead tick

usage() { sed -n '2,76p' "$0" | sed 's/^# \{0,1\}//'; }
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

CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
STATE_DIR="$CONF_DIR/global"
STATE="$STATE_DIR/install-sync.state"
LOCK="$STATE_DIR/install-sync.lock"
LOGF="$ROOT/logs/install-sync.log"

now() { date +%s; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
short() { printf '%.7s' "${1:-}"; }
say() { printf 'fleet-install-sync: %s\n' "$*" >&2; }

# git with the network bounded: git's own stall abort, the only portable timeout.
g() { git -C "$ROOT" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$TIMEOUT" "$@"; }

# state_get <key> — one value from the previous state file ('' when absent).
state_get() { [ -f "$STATE" ] && sed -n "s/^$1: //p" "$STATE" | head -1; }

# The whole record, rewritten atomically. Globals: HEAD_SHA STABLE_SHA FROM TO
# DEFERRED_SINCE SKIP APPLY_LINE.
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
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

log_line() { # $1 result $2 reason
  [ -d "$ROOT/logs" ] || mkdir -p "$ROOT/logs" 2>/dev/null || return 0
  printf '%s %s %s..%s %s\n' "$(utc)" "$1" "$(short "${FROM:-${HEAD_SHA:-?}}")" \
    "$(short "${TO:-${HEAD_SHA:-?}}")" "$2" >> "$LOGF" 2>/dev/null
}

# finish <result> <reason> — record + log + leave. Under --dry-run, print only.
finish() {
  if [ "$DRY" = 1 ]; then printf '%s: %s\n' "$1" "$2"; exit 0; fi
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
busy_fleets() {
  local sess n
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    n=$(tmux -L "$sess" list-windows -a -F '#{@claude_state}' 2>/dev/null \
        | grep -cE "^($BUSY_STATES)$")
    [ "${n:-0}" -gt 0 ] && printf '%s:%s\n' "$sess" "$n"
  done <<EOF
$(fleet_sockets 2>/dev/null)
EOF
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
  HEAD_SHA='' STABLE_SHA='' FROM='' TO='' DEFERRED_SINCE='' SKIP='' APPLY_LINE=''

  if [ "$STATUS" = 1 ]; then
    if [ -f "$STATE" ]; then cat "$STATE"; exit 0; fi
    printf 'no state yet (%s) — no tick has run on this login\n' "$STATE"; exit 1
  fi

  # Carry the two durable fields forward; every other line is this tick's.
  DEFERRED_SINCE=$(state_get deferred_since); [ "$DEFERRED_SINCE" = - ] && DEFERRED_SINCE=''
  SKIP=$(state_get skip); [ "$SKIP" = - ] && SKIP=''
  HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || :)

  # --- off ---------------------------------------------------------------------
  if [ "${FLEET_INSTALL_SYNC:-1}" = 0 ]; then
    DEFERRED_SINCE=''
    finish off 'FLEET_INSTALL_SYNC=0 — this login does not follow stable (set it to 1, or delete the line, to switch back on)'
  fi

  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || finish refused "$ROOT is not a git checkout — a file-copy install cannot follow stable (fleet-sync-logins.sh --to-git converts it)"
  [ -n "$HEAD_SHA" ] || finish refused "$ROOT has no HEAD commit"

  # --- one tick at a time (an apply + doctor may outlive a short interval) -----
  if [ "$DRY" = 0 ]; then
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
    if ! mkdir "$LOCK" 2>/dev/null; then
      local lts
      lts=$(cat "$LOCK/ts" 2>/dev/null); case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
      if [ $(( $(now) - lts )) -lt "$LOCK_TTL" ]; then
        say "another tick holds $LOCK (since $lts) — skip"; exit 0
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
    local rel
    if git -C "$ROOT" merge-base --is-ancestor "$STABLE_SHA" "$HEAD_SHA" 2>/dev/null; then
      rel="behind this install ($(git -C "$ROOT" rev-list --count "$STABLE_SHA..$HEAD_SHA" 2>/dev/null) commit(s)) — a hand sync pushed HEAD past it"
    else
      rel="not on this install's history (diverged)"
    fi
    finish refused "stable $(short "$STABLE_SHA") is not a descendant of HEAD $(short "$HEAD_SHA") — $rel; only ever fast-forwards, never moves back; the next stable move past HEAD aligns it"
  fi
  local dirty ndirty more=''
  dirty=$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null | awk 'NF {print $NF}')
  if [ -n "$dirty" ]; then
    ndirty=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
    [ "$ndirty" -gt 3 ] && more=" +$((ndirty - 3)) more"
    dirty=$(printf '%s\n' "$dirty" | head -3 | tr '\n' ' ')
    DEFERRED_SINCE=''
    finish refused "tracked local changes in $ROOT (${dirty% }$more) — not touching an edited install; commit or discard them, then the next tick follows"
  fi

  # --- quiet? ----------------------------------------------------------------------------
  local busy
  busy=$(busy_fleets | tr '\n' ' ')
  if [ -n "$busy" ]; then
    [ -n "$DEFERRED_SINCE" ] || DEFERRED_SINCE=$(now)
    finish deferred "busy window(s) on ${busy% } — waiting for every session to go idle (since $DEFERRED_SINCE)"
  fi
  if [ "$DRY" = 0 ] && [ -x "$ROOT/bin/fleet-diskguard.sh" ] \
     && ! "$ROOT/bin/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
    [ -n "$DEFERRED_SINCE" ] || DEFERRED_SINCE=$(now)
    finish deferred "disk gate closed (fleet-diskguard.sh --gate) — not rewriting the install below the floor"
  fi
  DEFERRED_SINCE=''

  if [ "$DRY" = 1 ]; then
    printf 'would ff %s %s..%s, then fleet-install-apply.sh --from %s --to %s, then fleet-doctor.sh (dry-run)\n' \
      "$ROOT" "$(short "$HEAD_SHA")" "$(short "$STABLE_SHA")" "$(short "$HEAD_SHA")" "$(short "$STABLE_SHA")"
    exit 0
  fi

  # --- move ---------------------------------------------------------------------------------
  # Baseline first: FAIL lines this login already has are not the new version's.
  local pre post new merr
  say "updating $(short "$HEAD_SHA") -> $(short "$STABLE_SHA")"
  pre=$(doctor_fail_tags)
  if ! merr=$(git -C "$ROOT" merge --ff-only -q "$STABLE_SHA" 2>&1 </dev/null); then
    finish refused "git merge --ff-only $(short "$STABLE_SHA") failed: $(printf '%s\n' "$merr" | tail -1)"
  fi
  run_apply "$HEAD_SHA" "$STABLE_SHA" || :
  post=$(doctor_fail_tags)
  new=$(comm -13 <(printf '%s\n' "$pre" | sed '/^$/d') <(printf '%s\n' "$post" | sed '/^$/d') | tr '\n' ',')
  new=${new%,}
  if [ -z "$new" ]; then
    finish updated "apply: ${APPLY_LINE}$([ -n "$post" ] && printf '; doctor FAIL already present before: %s' "$(printf '%s\n' "$pre" | tr '\n' ',' | sed 's/,$//')")"
  fi

  # --- roll back ----------------------------------------------------------------------------
  say "doctor FAIL after update: $new — rolling back to $(short "$HEAD_SHA")"
  local fwd="$APPLY_LINE"
  if ! git -C "$ROOT" reset --hard -q "$HEAD_SHA" >/dev/null 2>&1 </dev/null; then
    SKIP="$STABLE_SHA"
    finish failed "doctor FAIL ($new) at $(short "$STABLE_SHA") and git reset --hard $(short "$HEAD_SHA") FAILED — the install is at $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null); fix by hand"
  fi
  run_apply "$STABLE_SHA" "$HEAD_SHA" || :
  SKIP="$STABLE_SHA"
  FROM="$STABLE_SHA"; TO="$HEAD_SHA"
  finish rolled-back "doctor FAIL after update: $new — back at $(short "$HEAD_SHA"); stable $(short "$STABLE_SHA") is not retried until it moves (forward apply: $fwd; rollback apply: $APPLY_LINE)"
}

main "$@"; exit
