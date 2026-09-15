#!/bin/bash
# tmux-pr-refresh.sh — dedicated FAST refresher for PR/CI status on the dash +
# status bar. The PR pipeline used to ride the collector's 60s tick
# (tmux-dash-collect.sh), so "CI went green" / "PR merged" took up to a minute to
# surface — exactly when you are watching a PR go green (its worker is waiting on
# that same signal to merge, #441) and the cleanup daemon is waiting to reap it. This script owns that
# pipeline on its own ~15s cadence (FLEET_PR_REFRESH_INTERVAL) instead.
#
# SINGLE WRITER of prmap_<slug> (+ the flat prmap mirror) and each window's
# @prci/@pfg options. tmux-dash-collect.sh no longer touches ANY PR state, so
# there is no double-writer race on these caches — the collector keeps git/usage/
# issues on 60s, PR status refreshes here on 15s.
#
# Writes under $C = $TMPDIR/.claude-dash:
#   prmap_<slug>  — branch<TAB>#num<TAB>state<TAB>ci<TAB>ready<TAB>sha  per repo. The
#                   fold from `gh pr list --json` to that line is FLEET_PRMAP_JQ in
#                   fleet-lib.sh (the taxonomy is documented there; issue #533):
#                   ci ∈ ·|✗|…|✓, ready ∈ draft|conflict|ready|behind|blocked|
#                   unknown|"" — mirrors fleet-pr-verdict.sh so the dash and the
#                   worker's merge gate never disagree about a PR. sha = the merge
#                   commit of a MERGED PR (issue #541), "" otherwise.
#   deploy_<sha>  — `<live|deploying|failed|unknown><TAB><epoch>` per MERGED sha
#                   (fleets/<slug>/), for fleets that set FLEET_DEPLOY_REF or
#                   FLEET_DEPLOY_CHECK (issue #541) — the dash's `live`/`deploy…`/
#                   `deploy✗` and the landed list's `dep` column. `live` is terminal.
#   prmap         — flat mirror of the PRIMARY (FLEET_REPO) slug'd file
#   @prci / @pfg  — per-window tmux options (glyph + color)
# Reads (owned by the collector, read-only here): sessmap (session→slug→repo)
# and git_<key> (window branch). Run from launchd (com.claude-fleet.pr-refresh,
# StartInterval FLEET_PR_REFRESH_INTERVAL) or a systemd user timer.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# --- scheduling heartbeat (issue #639) ---------------------------------------
# Stamped at the TOP, before any early exit, so "launchd never spawned me" stays
# distinguishable from "I ran and had nothing to do" — a conf-gated tick that
# exits immediately still proves it was scheduled. bin/fleet-daemon-watch.sh
# alarms on, and kicks, a unit whose stamp ages past FLEET_DAEMON_STALE_MULT ×
# this unit's StartInterval; without it, a pended unit is silent (issue #639:
# launchd stopped scheduling EVERY interval unit in this user domain and the only
# daemon anyone noticed was the one collector heartbeat #638 had instrumented).
# Only the UNIT's own mode counts: `--repo <r>` is the webhook's instant kick
# (bin/fleet-webhook.sh is KeepAlive, so it keeps firing while interval units
# are pended), and crediting it would hide that this unit was never scheduled.
# The source is GUARDED and the stamp is a side errand: liveness instrumentation
# must never be able to kill the daemon it instruments. A half-synced install
# missing the lib then costs this unit its alarm (it reads `never`, which is
# silent by design) instead of costing the fleet the daemon.
# shellcheck source=/dev/null
if [ "$#" = 0 ] && [ -f "$BIN/fleet-daemon-lib.sh" ]; then
  . "$BIN/fleet-daemon-lib.sh"; fleet_daemon_stamp_tick pr-refresh "$BIN/.."
fi

. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
G="$C/global"                       # machine-wide caches (git_<key>) — issue #181
# Sweep this run's PID-unique temps on exit (across the fleets/<slug>/ subdirs now;
# a failed gh fetch only `mv`s on success, so it would otherwise orphan a 0-byte
# prmap.<pid> forever).
trap 'find "$C" -maxdepth 3 -name "*.'"$$"'" -delete 2>/dev/null || true' EXIT
REPO="${FLEET_REPO:-}"
now() { date +%s; }

# Targeted mode (issue #315): `--repo <owner/repo>` refreshes JUST that one repo's
# PR/CI state NOW, bypassing both the broad session/conf fetch-queue and the TTL —
# this is the webhook handler's instant kick (bin/fleet-webhook.sh). It stays the
# SINGLE writer of prmap/@prci (same code path, narrowed queue + forced fetch); the
# normal no-arg invocation is byte-for-byte unchanged.
TARGET_REPO='' FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) TARGET_REPO="${2:-}"; FORCE=1; shift ;;
    -*)     printf 'tmux-pr-refresh: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)      printf 'tmux-pr-refresh: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# cache_key — byte-identical to bin/tmux-dash-collect.sh. Both scripts write the
# same cache dir, so this MUST stay in lockstep (a reader can't tell which process
# wrote a file). See that file for the full rationale (collision-free reversible
# worktree key). NB: this script no longer writes any cache file atomically —
# prmap_<slug> is written by the fetch loop's own temp+mv, and the flat mirror is
# gone (issue #180) — so the shared atomic_write helper is no longer needed here.
cache_key() {
  local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"
}

# Each fleet runs on its own tmux server/socket now (issue #159): enumerate the
# live fleet sockets once and fan the @prci/@pfg writes out across them. No live
# fleet → nothing to refresh (the dash only exists inside a fleet), same as the
# old `tmux info` gate that this replaces.
SOCKETS=$(fleet_sockets)
# Normal mode needs a live fleet to paint. A targeted --repo kick still refreshes
# the prmap CACHE with no live fleet (fresh the moment one attaches) — the @prci
# mapping loop below simply no-ops over an empty socket set.
[ -n "$TARGET_REPO" ] || [ -n "$SOCKETS" ] || exit 0
# NB: a missing gh only skips the FETCH loop below (guarded there) — the @prci
# mapping still runs off whatever prmap cache already exists, exactly as the
# collector did, so window glyphs don't freeze if gh is transiently unavailable.

# Fetch guard. This daemon fires every FLEET_PR_REFRESH_INTERVAL (~15s) and each
# fire re-fetches, so PR status stays ~15s-fresh. PR_TTL only dedups a manual/
# out-of-band run that overlaps a timer tick (or two timers racing) — it is
# floored a few seconds BELOW the interval so ordinary timer jitter (integer
# second granularity) never makes a normal tick skip its fetch.
INT="${FLEET_PR_REFRESH_INTERVAL:-15}"
case "$INT" in ''|*[!0-9]*) INT=15;; esac
PR_TTL=$(( INT > 4 ? INT - 3 : 1 ))

# --- resolve the repo set (CHEAP) ---
# Mirror of the collector's fetch queue, but sourced from the collector's already
# written sessmap (a single awk-free read) instead of re-running the expensive
# per-session git/tmux repo resolution every 15s — that stays the collector's
# job. Seed with the global FLEET_REPO (so its slug'd cache stays fresh with no
# live session — NOT a primary; issue #180), add every repo a live session
# resolved to, then the configured
# fleets (FLEET_REPOS + per-fleet confs) so a watched-but-unopened repo refreshes.
# Q_SESS carries the FLEET SESSION that owns each queued repo (issue #625). The
# lifecycle emit resolves FLEET_EMIT_URL through the per-fleet conf overlay, and
# this daemon runs OUTSIDE any session (no $TMUX to resolve one from), so the
# session has to be carried from wherever the repo was discovered. Empty is fine —
# the emit then sees only the global fleet.conf.
declare -a Q_REPO Q_SLUG Q_SESS   # unique (repo,slug,session) fetch queue (bash 3.2 ok)
SEEN=' '
queue() {                          # $1=repo [$2=fleet session] → add once
  local r="$1" se="${2:-}" s
  [ -z "$r" ] && return
  s=$(fleet_slug "$r")
  case "$SEEN" in *" $s "*) return;; esac
  SEEN="$SEEN$s "; Q_REPO+=("$r"); Q_SLUG+=("$s"); Q_SESS+=("$se")
}
if [ -n "$TARGET_REPO" ]; then
  # Targeted kick: JUST this repo (forced fetch below); skip the broad enumeration.
  # Its owning session still comes off the collector's sessmap, so a webhook-driven
  # refresh emits against the same fleet conf a polled one would.
  _tr=$(fleet_norm_repo "$TARGET_REPO"); _ts=''
  SESSMAP=$(fleet_sessmap_file)
  [ -f "$SESSMAP" ] && _ts=$(awk -F'\t' -v r="$_tr" '$3==r {print $1; exit}' "$SESSMAP" 2>/dev/null)
  queue "$_tr" "$_ts"
else
  [ -n "$REPO" ] && queue "$(fleet_norm_repo "$REPO")" "${FLEET_SESSION:-}"
  SESSMAP=$(fleet_sessmap_file)
  if [ -f "$SESSMAP" ]; then
    while IFS=$'\t' read -r se _ rp; do
      [ -n "$rp" ] && queue "$(fleet_norm_repo "$rp")" "$se"
    done < "$SESSMAP"
  fi
  for r in ${FLEET_REPOS:-}; do queue "$(fleet_norm_repo "$r")"; done
  while IFS=$'\t' read -r _s cf; do
    [ -f "$cf" ] || continue
    r=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$r" ] && queue "$(fleet_norm_repo "$r")" "$_s"
  done < <(fleet_each_conf)
fi

# --- session.pr: the PR half of the lifecycle facts (issue #625) ---------------
# The prmap this daemon rewrites every ~15s already IS the fleet's picture of every
# PR's state, so a PR transition is a DIFF of the file about to be replaced against
# the one just fetched — no second poller, no second source of truth.
#
# A COLD prmap emits nothing. With no previous file every one of up to 100 PRs
# would read as a transition, which is both a flood and a lie (they did not just
# happen). The first fetch seeds silently and the second one onward reports.
emit_pr_transitions() {
  local oldf="$1" newf="$2" rp="$3" se="$4"
  [ -s "$oldf" ] || return 0
  [ -f "$BIN/fleet-emit.sh" ] || return 0
  awk -F'\t' -v OFS='\t' '
    NR==FNR { old[$2]=$3; next }
    {
      prev = ($2 in old) ? old[$2] : ""
      if (prev == $3) next
      action = ($3 == "MERGED") ? "merged" : (($3 == "CLOSED") ? "closed" : "opened")
      n = $2; sub(/^#/, "", n)
      print n, $1, $3, action
    }
  ' "$oldf" "$newf" 2>/dev/null |
  while IFS=$'\t' read -r num br state action; do
    [ -n "$num" ] || continue
    iss=''
    case "$br" in issue-*) iss="${br#issue-}"; iss="${iss//[^0-9]/}" ;; esac
    bash "$BIN/fleet-emit.sh" session.pr --session "$se" --repo "$rp" \
      --pr "$num" --issue "$iss" --branch "$br" --state "$state" --action "$action" \
      >/dev/null 2>&1 || :
  done
  return 0
}

# --- per-repo PR map (TTL-gated) — the ONLY writer of prmap_<slug> ---
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; se="${Q_SESS[$i]}"; i=$((i+1))
  command -v gh >/dev/null 2>&1 || break
  FD=$(fleet_cache_dir "$sg")          # fleets/<slug>/ (issue #181)
  pts=$(cat "$FD/prmap.ts" 2>/dev/null || echo 0)
  if [ "$FORCE" = 1 ] || [ $(( $(now) - pts )) -ge "$PR_TTL" ]; then
    # The fold from PR JSON → prmap TSV is FLEET_PRMAP_JQ (fleet-lib.sh), the one
    # program the dash, the merge gate's taxonomy and pr-refresh-jq-selftest.sh
    # share (issue #533) — it lived inline here and drifted from fleet-pr-verdict.sh
    # (no isDraft, only FAILURE was red, StatusContext never looked at).
    gh pr list --repo "$rp" --state all --limit 100 \
      --json number,headRefName,state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,mergeCommit \
      --jq "$FLEET_PRMAP_JQ" \
      > "$FD/prmap.$$" 2>/dev/null \
      && { emit_pr_transitions "$FD/prmap" "$FD/prmap.$$" "$rp" "$se"
           mv "$FD/prmap.$$" "$FD/prmap"; }
    now > "$FD/prmap.ts"
  fi
done

# No flat prmap mirror is written (issue #180 — all fleets equal, no primary):
# every reader routes through fleet_cache, which returns prmap_<slug> for a
# resolved fleet and only falls back to the un-slug'd name during cold start.

# --- PR/CI attention signal ---
# Maps each window's branch → its open PR's CI state; writes @prci (glyph) +
# @pfg (color) — surfaced on the dash's PR column. Single writer of @prci/@pfg.
US=$'\x1f'
for sock in $SOCKETS; do
tmux -L "$sock" list-windows -a -F "#{session_name}${US}#{session_name}:#{window_index}${US}#{pane_current_path}${US}#{@prci}" 2>/dev/null | \
while IFS="$US" read -r sess win path cur; do
  [ -z "$path" ] && continue
  # each window matches against ITS fleet's prmap — routed through fleet_cache so
  # the read side has a single slug-resolution truth (issue #180). Cold-start
  # fallback is the un-slug'd name, which simply won't exist ⇒ no glyph.
  prmf=$(fleet_cache prmap "$sess")
  key=$(cache_key "$path")
  branch=$(cut -f1 "$G/git_$key" 2>/dev/null)
  bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
  glyph=""; pfg=""
  if [ -n "$bare" ] && [ "$bare" != "-" ]; then
    hit=$(awk -F'\t' -v x="$bare" '$1==x{print;exit}' "$prmf" 2>/dev/null)
    # a live window sitting on a MERGED branch is a deploy-state candidate (#541):
    # hand its merge sha to the deploy pass below (this loop is a pipeline subshell,
    # so the hand-off is a PID-unique temp file, swept by the EXIT trap).
    if [ -n "$hit" ] && [ "$(echo "$hit"|cut -f3)" = "MERGED" ]; then
      msha=$(echo "$hit"|cut -f6)
      [ -n "$msha" ] && printf '%s\t%s\n' "${prmf%/*}" "$msha" >> "$C/deploy-live.$$"
    fi
    if [ -n "$hit" ] && [ "$(echo "$hit"|cut -f3)" = "OPEN" ]; then
      ready=$(echo "$hit"|cut -f5)
      case "$(echo "$hit"|cut -f4)" in
        ✗) glyph="✗"; pfg="#f7768e";;   # real CI failure → attention
        ✓) case "$ready" in             # green: decorate by land-readiness (#533)
             behind)   glyph="✓↑"; pfg="#e0af68";;   # green but behind base → update-branch
             conflict) glyph="✓!"; pfg="#f7768e";;   # green but conflicting → rebase
             blocked)  glyph="✓·"; pfg="#e0af68";;   # green+mergeable but blocked (protection)
             draft)    glyph="✓d"; pfg="#565f89";;   # green but a DRAFT → gh pr ready (muted)
             unknown)  glyph="✓?"; pfg="#a9b1d6";;   # green, mergeability not computed yet
             *)        glyph="✓";  pfg="#9ece6a";;   # green + mergeable, awaiting merge
           esac;;
      esac
    fi
  fi
  if [ "$cur" != "$glyph" ]; then
    tmux -L "$sock" set-window-option -t "$win" @prci "$glyph" 2>/dev/null
    tmux -L "$sock" set-window-option -t "$win" @pfg "$pfg" 2>/dev/null
  fi
done
done

# --- deploy state for MERGED PRs (issue #541) ---
# "merged" ≠ "live". For every queued repo whose fleet sets FLEET_DEPLOY_REF (a local
# checkout that IS the deployment — claude-fleet's ~/.claude/fleet) or
# FLEET_DEPLOY_CHECK=actions (post-merge workflow runs for the merge sha), probe the
# MERGED candidates and cache `<state>\t<epoch>` at fleets/<slug>/deploy_<sha>.
# Candidates = the newest 20 MERGED PRs (so the ⌃t landed list has data) ∪ every
# MERGED branch a live window sits on (collected by the loop above). `live` is
# terminal and never re-probed; ref mode re-probes the rest every tick (one local
# git each — cheap); actions mode re-probes only entries older than FLEET_DEPLOY_TTL
# (60s) — so a merged PR that went live minutes ago costs ZERO gh calls from then on.
# Neither knob set ⇒ nothing written, and the readers keep rendering `merged`.
deploy_conf_for() {   # $1=repo → DEP_REF / DEP_CHECK from the fleet conf bound to it
  local want r _s cf
  want=$(fleet_slug "$(fleet_norm_repo "$1")")
  DEP_REF=''; DEP_CHECK=''
  while IFS=$'\t' read -r _s cf; do
    [ -f "$cf" ] || continue
    # unset first: the global fleet.conf sourced at the top may carry these keys for
    # ITS repo, and a per-fleet conf that doesn't set them must not inherit them.
    r=$( unset FLEET_REPO FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK; . "$cf" >/dev/null 2>&1
         printf '%s\t%s\t%s' "$(fleet_slug "$(fleet_norm_repo "${FLEET_REPO:-}")")" "${FLEET_DEPLOY_REF:-}" "${FLEET_DEPLOY_CHECK:-}" )
    case "$r" in
      "$want"$'\t'*) r=${r#*$'\t'}; DEP_REF=${r%%$'\t'*}; DEP_CHECK=${r#*$'\t'}
                      [ -n "$DEP_REF$DEP_CHECK" ] && return 0 ;;
    esac
  done < <(fleet_each_conf)
  # the global fleet.conf's knobs apply to the global FLEET_REPO only
  if [ -n "$REPO" ] && [ "$(fleet_slug "$(fleet_norm_repo "$REPO")")" = "$want" ]; then
    DEP_REF="${FLEET_DEPLOY_REF:-}"; DEP_CHECK="${FLEET_DEPLOY_CHECK:-}"
  fi
  return 0
}
DEP_TTL="${FLEET_DEPLOY_TTL:-60}"; case "$DEP_TTL" in ''|*[!0-9]*) DEP_TTL=60;; esac
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; i=$((i+1))
  FD=$(fleet_cache_dir "$sg")
  [ -s "$FD/prmap" ] || continue
  deploy_conf_for "$rp"
  [ -n "$DEP_REF$DEP_CHECK" ] || continue
  cands=$(awk -F'\t' '$3=="MERGED" && $6!="" {n=$2; sub(/^#/,"",n); print n "\t" $6}' "$FD/prmap" 2>/dev/null \
          | sort -t"$(printf '\t')" -k1,1nr | head -20 | cut -f2)
  [ -f "$C/deploy-live.$$" ] && cands="$cands"$'\n'"$(awk -F'\t' -v d="$FD" '$1==d{print $2}' "$C/deploy-live.$$" 2>/dev/null)"
  nowts=$(now)
  printf '%s\n' "$cands" | sort -u | while read -r sha; do
    [ -n "$sha" ] || continue
    f="$FD/deploy_$sha"; st=''; ts=0
    [ -f "$f" ] && { IFS=$'\t' read -r st ts < "$f" || :; }
    [ "$st" = live ] && continue                               # terminal — never re-probed
    if [ -z "$DEP_REF" ]; then                                 # actions mode: TTL-gated gh read
      case "$ts" in ''|*[!0-9]*) ts=0;; esac
      [ $(( nowts - ts )) -ge "$DEP_TTL" ] || continue
    fi
    new=$(fleet_deploy_probe "$rp" "$sha" "$DEP_REF" "$DEP_CHECK") || continue   # gh failed → keep the cached state
    [ -n "$new" ] || continue
    printf '%s\t%s\n' "$new" "$nowts" > "$f.$$" && mv "$f.$$" "$f"
  done
  # a sha's file outlives its PR's 100-row prmap window by a fortnight, then goes.
  find "$FD" -maxdepth 1 -name 'deploy_*' -mtime +14 -delete 2>/dev/null || true
done
exit 0
