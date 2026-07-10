#!/bin/bash
# fleet-land-lease.sh — the reusable per-repo "land lease": the single-writer
# lock that serializes LANDING (squash-merge + base fast-forward) on ONE repo, so
# two landers can never advance the same base branch under each other.
#
# It GENERALIZES the inline lease that ships in bin/land-train.sh (issue #62): the
# steward's batch land-train and the worker-owned self-land (bin/fleet-land-self.sh,
# issue #138) share the EXACT same mkdir-atomic acquire + steal-if-stale semantics,
# so the two land paths interlock on the same lock instead of each rolling its own.
#
# Why a lease at all (issue #138 §5 — hold-through-green): a lander holds the lease
# across the whole "update-branch → wait for green → merge" window. Holding through
# the green-wait means master can't advance under it, so green ⇒ still-up-to-date ⇒
# the merge lands first try — no wasted CI, no starvation. The correctness partner
# to steal-if-stale is land_lease_mine: because a lease CAN be stolen (a crashed
# holder must not deadlock the queue), the holder re-validates ownership right
# before it merges.
#
# SOURCED, not executed — like fleet-lib.sh this file must NOT `set -u` /
# `set -o pipefail` (those would leak into every caller and change behaviour far
# from here). It is written to be safe under a `set -u` caller: every optional
# expansion is defaulted and every helper returns cleanly.
#
# Lock model: the lock IS the directory (mkdir is the atomic test-and-set). Inside
# it, `holder` is a 4-line file — pid, host, expiry-epoch, label — written right
# after the mkdir wins. A contender steals the lock when it is STALE:
#   * now ≥ expiry               (the TTL elapsed — a normal holder renews via ttl)
#   * OR holder is on THIS host AND its pid is no longer alive  (crashed holder)
#   * OR the holder file never appeared and the lockdir itself is older than the
#     TTL  (a holder that died between mkdir and the holder write)
# A same-host dead-pid steal reclaims a crash instantly; a cross-host holder can
# only be reclaimed by the TTL (you can't probe a pid on another machine).
#
# API (all take the lease PATH explicitly so the caller owns dir + name):
#   land_lease_acquire <lease-path> [ttl-secs] [label]   rc 0 acquired / 1 busy
#   land_lease_mine    <lease-path>                       rc 0 if still ours
#   land_lease_release <lease-path>                       drop it iff it's ours
#   land_lease_holder  <lease-path>                       print holder label (info)

# hostname short-form, portable + cheap. One helper so acquire/mine agree.
land_lease_host() { hostname -s 2>/dev/null || hostname 2>/dev/null || echo host; }

# 0 if <pid> is a LIVE process, 1 only if it is genuinely gone. Only meaningful
# for a holder on THIS host (a pid on another machine is unknowable → never
# probed). `kill -0` returns non-zero for BOTH "no such process" (ESRCH → dead)
# AND "operation not permitted" (EPERM → alive but owned by another user), so we
# must disambiguate: only ESRCH means dead. Erring toward "alive" is the safe bias
# — we'd rather wait out the TTL than steal a lease from a running lander.
land_lease_alive() {
  local pid="${1:-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 0
  case "$(kill -0 "$pid" 2>&1)" in
    *[Nn]o\ such\ process*) return 1 ;;   # ESRCH → dead
    *) return 0 ;;                         # EPERM / anything else → treat as alive
  esac
}

# now-epoch, with a safe fallback so `set -u` callers never see an empty arithmetic.
land_lease_now() { date +%s 2>/dev/null || echo 0; }

# lockdir mtime (epoch), portable across BSD (stat -f %m) and GNU (stat -c %Y).
land_lease_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Try to take the lease. rc 0 = acquired (fresh OR stolen-stale); rc 1 = busy.
# On success writes the 4-line holder file recording THIS process. Idempotent-ish:
# re-acquiring a lease we already hold succeeds (refreshes the expiry).
land_lease_acquire() {
  local lease="${1:-}" ttl="${2:-3600}" label="${3:-}"
  [ -n "$lease" ] || return 1
  local dir; dir=$(dirname "$lease"); mkdir -p "$dir" 2>/dev/null
  local me_pid="$$" me_host now exp
  me_host=$(land_lease_host); now=$(land_lease_now); exp=$((now + ttl))
  [ -z "$label" ] && label="${FLEET_SESSION:-$USER}:$me_pid@$me_host"

  if mkdir "$lease" 2>/dev/null; then
    printf '%s\n%s\n%s\n%s\n' "$me_pid" "$me_host" "$exp" "$label" > "$lease/holder"
    return 0
  fi

  # Contended. Already ours? (re-entrant refresh — a resumed holder re-acquiring.)
  if land_lease_mine "$lease"; then
    printf '%s\n%s\n%s\n%s\n' "$me_pid" "$me_host" "$exp" "$label" > "$lease/holder"
    return 0
  fi

  # Read the holder and decide staleness.
  local h_pid h_host h_exp
  h_pid=$(sed -n 1p "$lease/holder" 2>/dev/null); h_pid="${h_pid//[^0-9]/}"
  h_host=$(sed -n 2p "$lease/holder" 2>/dev/null)
  h_exp=$(sed -n 3p "$lease/holder" 2>/dev/null); h_exp="${h_exp//[^0-9]/}"

  # Staleness. LIVENESS BEATS TTL for a same-host holder: a lander (land-train or a
  # self-land worker) legitimately HOLDS this lock through its whole green-wait,
  # which can outlast the TTL — and no lander renews its expiry. If we stole on TTL
  # alone we could yank the lock out from under a *still-running* holder and let two
  # landers advance the base branch at once (the exact race the shared lease exists
  # to prevent). So on THIS host the holder's pid is authoritative — alive ⇒ never
  # steal, dead ⇒ steal now. The TTL only governs a holder we CANNOT probe: a
  # cross-host holder (no way to check its pid), or a lock whose holder file never
  # appeared (a holder that died between mkdir and the write).
  local stale=0
  if [ "$h_host" = "$me_host" ] && [ -n "$h_pid" ]; then
    land_lease_alive "$h_pid" || stale=1     # same host → pid liveness decides
  elif [ -n "$h_exp" ]; then
    [ "$now" -ge "$h_exp" ] && stale=1        # cross-host → only the TTL can reclaim
  else
    # No parseable holder (a holder that died before it wrote the file). Fall back
    # to the lockdir's own age so we still reclaim it — but only after the TTL, so
    # a lock in the mkdir→write window (sub-second) is never stolen out from under.
    local age=$(( now - $(land_lease_mtime "$lease") ))
    [ "$age" -ge "$ttl" ] && stale=1
  fi

  if [ "$stale" -eq 1 ]; then
    rm -rf "$lease" 2>/dev/null
    if mkdir "$lease" 2>/dev/null; then
      printf '%s\n%s\n%s\n%s\n' "$me_pid" "$me_host" "$exp" "$label" > "$lease/holder"
      return 0
    fi
  fi
  return 1
}

# 0 if the lease still records THIS pid on THIS host — the re-validate-on-resume
# check a holder runs right before it merges (a stolen lease ⇒ NOT ours ⇒ abort).
land_lease_mine() {
  local lease="${1:-}"; [ -n "$lease" ] || return 1
  [ -f "$lease/holder" ] || return 1
  local h_pid h_host
  h_pid=$(sed -n 1p "$lease/holder" 2>/dev/null); h_pid="${h_pid//[^0-9]/}"
  h_host=$(sed -n 2p "$lease/holder" 2>/dev/null)
  [ "$h_pid" = "$$" ] && [ "$h_host" = "$(land_lease_host)" ]
}

# Release ONLY if it's still ours — never yank a lease another lander legitimately
# stole after we went stale (that would let two landers run at once). Idempotent.
land_lease_release() {
  local lease="${1:-}"; [ -n "$lease" ] || return 0
  land_lease_mine "$lease" && rm -rf "$lease" 2>/dev/null
  return 0
}

# Print the holder's label (4th line), for logs/diagnostics. Empty if unheld.
land_lease_holder() {
  local lease="${1:-}"; [ -n "$lease" ] || return 0
  sed -n 4p "$lease/holder" 2>/dev/null
}

# The SHARED merge-state taxonomy for both landers (bin/land-train.sh's batch and
# bin/fleet-land-self.sh's single-PR self-land) — one source so the two paths can
# never disagree on whether a PR is landable. Folds (state,mergeable,mss,draft,
# checks) → one verdict the land loops switch on:
#   GONE     not open (already merged/closed)                        → skip
#   DRAFT    draft                                                   → eject
#   CONFLICT CONFLICTING / DIRTY                                     → eject (rebase)
#   FAILING  a REQUIRED check is red                                 → eject
#   BLOCKED  mergeable-blocked, checks green (review required/other) → eject
#   BEHIND   out of date w/ base                                     → update-branch
#   PENDING  checks still running / unknown                          → wait
#   READY    green + up to date                                      → merge
# Callers that also care about MERGED (an already-landed PR) test for it BEFORE
# calling this (MERGED is not OPEN, so it would fold to GONE here).
land_classify() {
  local st="$1" mg="$2" ms="$3" dr="$4" ck="$5"
  [ "$st" != OPEN ]       && { echo GONE;     return; }
  [ "$dr" = DRAFT ]       && { echo DRAFT;    return; }
  [ "$mg" = CONFLICTING ] && { echo CONFLICT; return; }
  case "$ms" in
    DIRTY)           echo CONFLICT ;;
    BEHIND)          echo BEHIND ;;
    CLEAN|HAS_HOOKS) echo READY ;;
    UNSTABLE)        echo READY ;;  # mergeable: at worst a NON-required check is red
    BLOCKED)         case "$ck" in fail) echo FAILING ;; pending|none) echo PENDING ;; *) echo BLOCKED ;; esac ;;
    *)               case "$ck" in fail) echo FAILING ;; *) echo PENDING ;; esac ;;  # UNKNOWN → give CI a beat
  esac
}
