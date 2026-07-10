#!/bin/bash
# fleet-watch.sh [--dry-run] [session...] — the ZERO-TOKEN fleet watcher (issue #147).
#
# An always-on daemon that sleeps on the whole fleet and wakes the steward ONLY on
# decision-worthy events — the firstmate. It replaces the steward hand-running
# PR-green pollers: instead of a human watching the dash, this watcher watches the
# STATE the other daemons already maintain and pings the steward through the #146
# control-issue channel when something needs a decision.
#
# ZERO-TOKEN / NO NEW POLLING. Every tick reads only local state the collector +
# pr-refresh already wrote — window `@claude_state`/`@issue`, the per-repo
# `prmap` (branch→PR state/ci/ready)/`issues_<slug>`/`labels_<slug>` caches, and tmux
# session counts. It calls
# NO LLM and issues NO per-tick `gh` reads; the only outbound work is a single
# `gh issue comment` when (and only when) a NEW edge fires. So an idle fleet costs
# nothing but a few cache reads per tick.
#
# EDGE-TRIGGERED + DEDUPED. We wake on TRANSITIONS, not levels. Each tick computes
# the set of currently-firing event KEYS (e.g. `prgreen:<slug>:<pr>`); a per-repo
# persisted keyset holds what was already firing. New keys (now − seen) are the
# edges → one batched wake comment. A condition that persists stays in the set and
# never re-fires; if it clears and later recurs it fires again. First run for a repo
# SEEDS the set silently (no history flood), mirroring the issue-bridge watermark.
#
# DELIVERY = the steward control issue (#146). On an edge we post a compact comment
# to this fleet's FLEET_STEWARD_ISSUE via bin/fleet-comment.sh --to-worker (UNMARKED
# so the issue-bridge relays it into the @steward hub pane). The watcher never talks
# to the steward pane directly — the bridge is its only channel, so a fleet with no
# FLEET_STEWARD_ISSUE (or no running bridge) is simply not watched.
#
# Events (issue #147 initial set):
#   prgreen    a worker PR is CI-green AND landable (prmap ready∈{ready,behind}; a
#              conflicting/blocked/unknown-mergeability PR is suppressed, issue #187)
#                                                              → "PR #<n> (#<iss>) green — /land <n>?"
#   propened   a worker opened a PR (prmap gained an OPEN PR)  → "#<iss> shipped PR #<n> — review?"
#   stuck      a worker looks stuck (@claude_state=looping)    → "#<iss> looks stuck (looping) — investigate?"
#   needs      the needs-attention count ROSE                  → "<k> window(s) need attention"
#   prodalert  a new `prod-alert`-labelled issue appeared      → "prod-alert #<n> filed — first-response?"
#   slotfree   caps have headroom + eligible backlog (autofill off) → "slot free — spawn #<n> (<title>)?"
#
# OFF BY DEFAULT. A fleet opts in with FLEET_WATCH=1 in its conf. The watcher spends
# no tokens ITSELF, but a wake makes the STEWARD take an LLM turn — so, like every
# other steward-driving daemon (issue-bridge/dispatch), it is explicitly enabled per
# fleet rather than on by default. Requires FLEET_STEWARD_ISSUE (its delivery channel)
# and, in practice, FLEET_ISSUE_BRIDGE=1 (what relays the wake into the steward).
#
# Single-writer per repo (mkdir lease, steal-if-stale) + disk-gated (fleet-diskguard
# --gate), exactly like fleet-dispatch.sh. Run from launchd (com.claude-fleet.watch,
# ~45s) / a systemd timer, or by hand (optionally --dry-run to just print edges).
#
# Env knobs (per-fleet in $FLEET_CONF_DIR/<session>.conf or the global fleet.conf):
#   FLEET_WATCH               1 to watch this fleet                 (default 0/off)
#   FLEET_STEWARD_ISSUE       control-issue number = wake channel   (required; #146)
#   FLEET_AUTOFILL            if 1, the dispatcher owns slot-fill so the slotfree
#                             event is suppressed (no double-drive) (default 0)
#   FLEET_MAX_SESSIONS        per-fleet session ceiling (headroom)  (default 0/unlimited)
#   FLEET_GLOBAL_MAX_SESSIONS system-wide ceiling (headroom)        (default 8)
#   FLEET_WATCH_STATE_DIR     dedup/keyset state dir  (default ~/.config/claude-fleet/watch)
#   FLEET_WATCH_LEASE_TTL     lease lifetime, seconds               (default 120)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C" 2>/dev/null || :
STATE="${FLEET_WATCH_STATE_DIR:-$HOME/.config/claude-fleet/watch}"
mkdir -p "$STATE" 2>/dev/null || :
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"
LEASE_TTL="${FLEET_WATCH_LEASE_TTL:-120}"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           printf 'fleet-watch: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

now() { date +%s 2>/dev/null || echo 0; }
log() { printf '%s fleet-watch: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# cache_key — byte-identical to bin/tmux-dash-collect.sh / tmux-pr-refresh.sh (the
# collision-free reversible worktree key those daemons hash a pane path into).
cache_key() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }

# --- headroom (mirrors fleet-dispatch.sh) --------------------------------------
global_headroom() {
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}"
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac
  [ "$gmax" -eq 0 ] && { echo 9999; return; }
  echo $(( gmax - $(fleet_session_count) ))
}
fleet_headroom() {
  local fmax="${FLEET_MAX_SESSIONS:-0}"
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  [ "$fmax" -eq 0 ] && { echo 9999; return; }
  echo $(( fmax - $(fleet_session_count_for "$1") ))
}

# --- per-repo single-writer lease (mkdir; steal-if-stale). Mirrors fleet-dispatch. -
lease_acquire() { # $1 = lease path, $2 = holder id
  local lease="$1" me="$2" now exp holder
  mkdir -p "$LEASE_DIR" 2>/dev/null
  now=$(now)
  if mkdir "$lease" 2>/dev/null; then
    printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"; return 0
  fi
  holder=$(sed -n 1p "$lease/holder" 2>/dev/null)
  exp=$(sed -n 2p "$lease/holder" 2>/dev/null); exp="${exp//[^0-9]/}"; exp="${exp:-0}"
  if [ "$now" -ge "$exp" ]; then
    rm -rf "$lease" 2>/dev/null
    if mkdir "$lease" 2>/dev/null; then
      printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"
      log "stole stale lease (was ${holder:-?})"; return 0
    fi
  fi
  return 1
}
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap
lease_release() { # $1 = lease path, $2 = holder id
  [ "$(sed -n 1p "$1/holder" 2>/dev/null)" = "$2" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# --- PR lookup: window branch → its OPEN PR row from the per-slug prmap ----------
# prmap line: branch<TAB>#num<TAB>state<TAB>ci<TAB>ready. Prints
# "#num<TAB>state<TAB>ci<TAB>ready" for the branch's PR, or empty. The `ready`
# column (pr-refresh's mergeability verdict) is surfaced so prgreen can gate the
# /land wake on landability, not CI alone (issue #187). Mirrors the
# branch-normalisation in tmux-pr-refresh.
pr_for_path() { # $1 = pane path, $2 = prmap file
  local path="$1" prmf="$2" key branch bare
  [ -s "$prmf" ] || return 0
  key=$(cache_key "$path")
  branch=$(cut -f1 "$C/global/git_$key" 2>/dev/null)
  bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
  [ -z "$bare" ] || [ "$bare" = "-" ] && return 0
  awk -F'\t' -v x="$bare" '$1==x{print $2"\t"$3"\t"$4"\t"$5; exit}' "$prmf" 2>/dev/null
}

# =============================== per-fleet scan =================================
# Computes this repo's firing keyset (KEY<TAB>MESSAGE lines on stdout) + the current
# needs-attention count (printed as the FIRST line, "needs<TAB>N"). Pure w.r.t. its
# inputs: tmux window state + the $C caches. The engine (watch_fleet) diffs the keys
# against the persisted set and does the level-compare for needs.
compute_keys() { # $1=slug $2=steward_issue $3=autofill $4=gh_headroom $5=fleet_headroom
  local slug="$1" steward="$2" autofill="$3" ghhd="$4" flhd="$5"
  # per-fleet runtime cache (issue #181): fleets/<slug>/{prmap,labels,issues}, with a
  # dual-read fallback to the legacy flat slug-suffixed files across the migrate window.
  local FD; FD=$(fleet_cache_dir "$slug")
  local prmf labf issf
  if   [ -f "$FD/prmap.ts" ];      then prmf="$FD/prmap"
  elif [ -f "$C/prmap_$slug.ts" ]; then prmf="$C/prmap_$slug"
  else prmf="$FD/prmap"; fi
  labf="$FD/labels"; [ -s "$labf" ] || { [ -s "$C/labels_$slug" ] && labf="$C/labels_$slug"; }
  if   [ -s "$FD/issues" ];        then issf="$FD/issues"
  elif [ -s "$C/issues_$slug" ];   then issf="$C/issues_$slug"
  else issf="$FD/issues"; fi
  local needs=0
  local live_issues=' '     # issue numbers with a live window (for slotfree anti-collision)
  local US=$'\x1f'

  # Resolve THIS slug's sessions ONCE (a single sessmap read) instead of forking an
  # awk per window to re-run fleet_slug_cached — the watcher must stay light on the
  # very tmux server it protects (review finding #10). Same source/semantics as
  # fleet_slug_cached: a stale/missing sessmap yields no match, exactly as before.
  local slugsess=' ' _s _sl
  if [ -f "$C/sessmap" ]; then
    while IFS=$'\t' read -r _s _sl _; do
      [ "$_sl" = "$slug" ] && slugsess="$slugsess$_s "
    done < "$C/sessmap"
  fi

  # ONE tmux scan of every window; keep only this repo's (slug match) worker windows.
  while IFS="$US" read -r sess win name issue st path; do
    [ -z "$sess" ] && continue
    case "$name" in plan|dash|backlog) continue;; esac   # hub panels, not workers
    case "$slugsess" in *" $sess "*) : ;; *) continue;; esac
    [ -n "$issue" ] && live_issues="$live_issues$issue "

    # per-window PR events (PR number + CI + mergeability from the prmap row)
    local prrow pnum pstate pci pready
    prrow=$(pr_for_path "$path" "$prmf")
    pnum=$(printf '%s' "$prrow" | cut -f1); pnum="${pnum#\#}"
    pstate=$(printf '%s' "$prrow" | cut -f2)
    pci=$(printf '%s' "$prrow" | cut -f3)
    pready=$(printf '%s' "$prrow" | cut -f4)
    if [ -n "$pnum" ] && [ "$pstate" = OPEN ]; then
      printf 'propened:%s:%s\t#%s shipped PR #%s — review?\n' "$slug" "$pnum" "${issue:-?}" "$pnum"
      # green + LANDABLE. Gate on the prmap `ready` column (pr-refresh's authoritative
      # mergeability verdict from mergeStateStatus/mergeable), NOT the @prci glyph
      # (issue #187). The glyph conflates "ready" and "mergeability-not-yet-computed"
      # as a bare "✓" (ready="" ⇒ default glyph), so a glyph-only gate fires /land on a
      # PR that later resolves CONFLICTING. Only ci-green PRs carry a ready verdict:
      #   ready  → landable now                            → /land wake
      #   behind → landable (update-branch fast-forwards it) → /land wake
      #   conflict/blocked/"" (unknown) → NOT a /land wake (author/human/GitHub must act)
      if [ "$pci" = "✓" ]; then
        case "$pready" in
          ready)  printf 'prgreen:%s:%s\tPR #%s (#%s) green — /land %s?\n' "$slug" "$pnum" "$pnum" "${issue:-?}" "$pnum" ;;
          behind) printf 'prgreen:%s:%s\tPR #%s (#%s) green (behind base) — /land %s?\n' "$slug" "$pnum" "$pnum" "${issue:-?}" "$pnum" ;;
        esac
      fi
    fi

    # worker-state events
    case "$st" in
      looping) printf 'stuck:%s:%s\t#%s looks stuck (looping) — investigate?\n' "$slug" "${issue:-$win}" "${issue:-$win}" ;;
      needs)   needs=$((needs + 1)) ;;
    esac
  done < <(tmux list-windows -a -F \
      "#{session_name}${US}#{window_id}${US}#{window_name}${US}#{@issue}${US}#{@claude_state}${US}#{pane_current_path}" 2>/dev/null)

  # prod-alert: any OPEN issue carrying the `prod-alert` label (from labels_<slug>).
  if [ -s "$labf" ]; then
    while IFS=$'\t' read -r n labels; do
      [ -z "$n" ] && continue
      case ",$labels," in *,prod-alert,*)
        printf 'prodalert:%s:%s\tprod-alert #%s filed — first-response?\n' "$slug" "$n" "$n" ;;
      esac
    done < "$labf"
  fi

  # slotfree: only when the dispatcher is NOT autofilling (else it double-drives),
  # both caps have headroom, and the backlog has an eligible issue. GATED on the
  # labels cache existing: without labels we can't exclude epic/meta/blocked, and a
  # WRONG "spawn this" suggestion is worse than none, so we stay silent rather than
  # suggest a disqualified issue (a transient gap — the collector writes labels_
  # every ~GH_TTL). Suggest the highest-PRIORITY eligible issue (same ranking the
  # dispatcher uses), so the two "what's next" pickers agree.
  if [ "$autofill" != 1 ] && [ "$ghhd" -gt 0 ] && [ "$flhd" -gt 0 ] \
     && [ -s "$issf" ] && [ -s "$labf" ]; then
    local top top_num top_title
    top=$(watch_top_eligible "$issf" "$labf" "$live_issues")
    if [ -n "$top" ]; then
      top_num=$(printf '%s' "$top" | cut -f1); top_title=$(printf '%s' "$top" | cut -f2)
      printf 'slotfree:%s:%s\tslot free — spawn #%s (%s)?\n' "$slug" "$top_num" "$top_num" "$top_title"
    fi
  fi

  printf 'needs\t%s\n' "$needs"   # ALWAYS last: the level for the rise-compare
}

# The highest-PRIORITY eligible backlog issue. Prints "num<TAB>title" or empty.
# Eligible = unassigned (issues_<slug> assignee field "·"), no live window, and no
# disqualifying label. Ranking mirrors fleet-dispatch.sh::eligible_issues so the
# watcher's spawn suggestion agrees with what autofill would pick: priority:p0<p1<p2
# tier first (unlabeled last), then FIFO by issue number within a tier. prod-alert
# is EXCLUDED here — it gets its own first-response wake, so it must not ALSO fire a
# slotfree "spawn" wake for the same issue (that would double-drive one number).
watch_top_eligible() { # $1=issues file $2=labels file $3=" live issues "
  local issf="$1" labf="$2" live="$3" best='' btier='' btitle='' n labels tier
  while IFS=$'\t' read -r _ num asg title; do
    n="${num#\#}"
    [ -z "$n" ] && continue
    [ "$asg" = "·" ] || continue                       # unassigned only
    case "$live" in *" $n "*) continue;; esac          # not already bound
    labels=$(awk -F'\t' -v x="$n" '$1==x{print $2; exit}' "$labf" 2>/dev/null)
    case ",$labels," in
      *,epic,*|*,meta,*|*,blocked,*|*,steward-control,*|*,prod-alert,*) continue;;
    esac
    case ",$labels," in
      *,priority:p0,*) tier=0;; *,priority:p1,*) tier=1;;
      *,priority:p2,*) tier=2;; *) tier=3;;
    esac
    # better = lower tier, or same tier + lower number (FIFO)
    if [ -z "$best" ] || [ "$tier" -lt "$btier" ] \
       || { [ "$tier" -eq "$btier" ] && [ "$n" -lt "$best" ]; }; then
      best="$n"; btier="$tier"; btitle="$title"
    fi
  done < "$issf"
  [ -n "$best" ] && printf '%s\t%s' "$best" "$btitle"
}

# WAKE: post one batched comment to the steward issue (unmarked → bridge relays it).
watch_wake() { # $1=repo $2=steward_issue $3=slug $4=body
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$4" | sed 's/^/  [dry-run wake] /' >&2
    return 0
  fi
  "$BIN/fleet-comment.sh" "$2" --repo "$1" --to-worker --body "$4" >/dev/null 2>&1 \
    || { log "$slug: wake post failed (steward issue #$2)"; return 1; }
  return 0
}

# --- watch ONE fleet (subshell so its per-fleet conf never leaks) --------------
watch_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  if [ "${FLEET_WATCH:-0}" != 1 ]; then
    log "$sess: watch off (FLEET_WATCH≠1) — skip"; exit 0
  fi
  steward="${FLEET_STEWARD_ISSUE:-}"
  if [ -z "$steward" ]; then
    log "$sess: no FLEET_STEWARD_ISSUE (no wake channel) — skip"; exit 0
  fi
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; exit 0; }
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")

  # Single-writer per REPO: two sessions serving one repo don't double-wake. The
  # lease holder scans the whole repo (all its windows), the others skip this tick.
  lease="$LEASE_DIR/watch-$slug.lock"
  me="watch:$sess:$$@$(hostname -s 2>/dev/null || echo host)"
  if [ "$DRY" = 0 ]; then
    lease_acquire "$lease" "$me" || { log "$slug: another watcher holds the lease — skip"; exit 0; }
    trap 'lease_release "$lease" "$me"' EXIT
  fi

  autofill="${FLEET_AUTOFILL:-0}"
  ghhd=$(global_headroom); flhd=$(fleet_headroom "$sess")

  # Compute the current firing keyset + needs level.
  local out; out=$(compute_keys "$slug" "$steward" "$autofill" "$ghhd" "$flhd")
  local cur_needs; cur_needs=$(printf '%s\n' "$out" | awk -F'\t' '$1=="needs"{print $2; exit}')
  cur_needs="${cur_needs:-0}"
  # every non-needs line = a firing "key<TAB>message"
  local firing; firing=$(printf '%s\n' "$out" | awk -F'\t' '$1!="needs"')

  # One directory per fleet (issue #181): the edge dedup keyset + needs level move to
  # fleets/<sess>/watch/{keys,needs}. The watch STATE is per-REPO (the lease is
  # per-slug and two sessions can serve one repo) — so key it by the CANONICAL
  # session for this repo (fleet_sess_for_repo = first-matching conf, exactly what
  # the migrator targets), NOT whichever session happens to hold the lease this tick.
  # Otherwise a change of lease holder would read an empty per-session keyset and
  # re-seed an already-firing edge, missing the wake.
  local csess; csess=$(fleet_sess_for_repo "$repo"); [ -n "$csess" ] || csess="$sess"
  local wdir="$FLEET_CONF_DIR/fleets/$csess/watch"
  mkdir -p "$wdir" 2>/dev/null
  # Dual-read PER FILE (keys and needs independently): a not-yet-migrated legacy
  # watch_<slug>.* file is read in place, so a half-migrated pair (keys moved, needs
  # not — or vice versa) never presents a fresh-empty file that would spuriously fire.
  local keysf="$wdir/keys" needsf="$wdir/needs"
  [ ! -f "$keysf" ]  && [ -f "$STATE/watch_$slug.keys" ]  && keysf="$STATE/watch_$slug.keys"
  [ ! -f "$needsf" ] && [ -f "$STATE/watch_$slug.needs" ] && needsf="$STATE/watch_$slug.needs"
  local first=0; [ -f "$keysf" ] || first=1

  # A tiny helper: persist the firing keyset + needs level. Called ONLY after a wake
  # succeeds (or when there was nothing to wake on) — never before the post, so a
  # transient wake-post failure leaves the prior state intact and the edge retries
  # next tick instead of being silently marked seen (review finding #1).
  # shellcheck disable=SC2317  # called below within this subshell
  persist_state() {
    [ "$DRY" = 0 ] || return 0
    printf '%s\n' "$firing" | awk -F'\t' 'NF{print $1}' > "$keysf.$$" && mv "$keysf.$$" "$keysf"
    printf '%s\n' "$cur_needs" > "$needsf"
  }

  # Assemble the new-edge wake body. `wsubs` accumulates a COALESCING SUBJECT per
  # emitted `- ` line, in the same order (issue #198) — the issue-bridge reads them
  # from a trailing marker to collapse superseded/duplicate wakes on drain. The
  # subject KEEPS the edge kind, so semantically-distinct edges that happen to share
  # a GitHub number (a `stuck` worker on a `prodalert` issue) never collapse into
  # each other. The ONE deliberate exception is the PR lifecycle: `propened` and
  # `prgreen` for the same PR map to a shared `pr:<slug>:<num>` subject so a green
  # (landable) wake supersedes the earlier shipped-for-review wake.
  local wake='' wsubs='' prev_needs
  prev_needs=$(cat "$needsf" 2>/dev/null)
  # If the .needs level is missing or garbled while the keyset EXISTS (partial state,
  # an interrupted write, manual cleanup), a bare 0 baseline would spuriously fire a
  # "N need attention" wake. Seed the baseline to the current count instead so we
  # only ever wake on a REAL rise (review finding #6); a genuine first-ever rise is
  # then just deferred one tick, which self-heals.
  case "$prev_needs" in ''|*[!0-9]*) prev_needs="$cur_needs";; esac

  if [ "$first" = 0 ]; then
    # per-key edges: a firing line whose KEY is not in the persisted set.
    while IFS=$'\t' read -r key msg; do
      [ -z "$key" ] && continue
      if ! grep -qxF "$key" "$keysf" 2>/dev/null; then
        wake="$wake- $msg"$'\n'
        case "$key" in
          prgreen:*|propened:*) wsubs="${wsubs}pr:${key#*:} " ;;  # PR lifecycle: green ≻ opened
          *)                    wsubs="${wsubs}${key} " ;;        # every other kind stays distinct
        esac
      fi
    done <<EOF
$firing
EOF
    # needs-attention RISE (a level, not a set member): wake only when it climbs.
    if [ "$cur_needs" -gt "$prev_needs" ]; then
      wake="$wake- $cur_needs window(s) need attention"$'\n'
      wsubs="${wsubs}needs:$slug "
    fi
  fi

  if [ "$first" = 1 ]; then
    # Seed silently (no wake to fail) — persist the current firing set as the
    # baseline so a fleet enabled mid-flight doesn't backfill-flood the steward.
    persist_state
    local nkeys; nkeys=$(printf '%s\n' "$firing" | awk 'NF{c++} END{print c+0}')
    log "$slug: first run — seeded $nkeys key(s), needs=$cur_needs (no backfill wake)"
    # In --dry-run on a cold fleet there is nothing to diff against, so show the
    # conditions the watcher currently DETECTS (what a real first run would seed and
    # then stay silent on) — a useful "log mode" inspection instead of a blank run.
    if [ "$DRY" = 1 ] && [ "$nkeys" -gt 0 ]; then
      printf '%s\n' "$firing" | while IFS=$'\t' read -r _ msg; do
        [ -n "$msg" ] && printf '  [dry-run detected] %s\n' "$msg" >&2
      done
    fi
    exit 0
  fi

  if [ -z "$wake" ]; then
    # No new edges: persist so a CLEARED condition is dropped from the set and the
    # needs level tracks reality (nothing was posted, so nothing can be lost).
    persist_state
    log "$slug: no new edges (needs=$cur_needs)"
    exit 0
  fi

  local body; body="🛰️ fleet-watch — $slug"$'\n\n'"$wake"
  # Trailing coalescing marker (issue #198): the per-line subjects, in order, so the
  # issue-bridge can collapse superseded/duplicate wakes to one line per subject when
  # they drain to a briefly-busy steward. An HTML comment → invisible in the rendered
  # issue; the bridge greps it verbatim. Omitted when there are no subjects.
  [ -n "$wsubs" ] && body="$body"$'\n'"<!-- fleet:wake $wsubs-->"
  if watch_wake "$repo" "$steward" "$slug" "$body"; then
    # Wake delivered (or dry-run) — NOW it's safe to advance the persisted state.
    persist_state
    local nedges; nedges=$(printf '%s' "$wake" | grep -c '^- ')
    log "$slug: woke steward (#$steward) on $nedges edge(s)$([ "$DRY" = 1 ] && printf ' [dry-run]')"
  else
    # Post failed (watch_wake already logged): do NOT persist, so these edges are
    # re-detected and retried next tick rather than lost.
    log "$slug: wake not delivered — state NOT advanced, will retry next tick"
  fi
  exit 0
) }

# --- which fleets? argv wins; else every live fleet session (dispatch's rule). ---
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=("${ARGV_SESS[@]}")
else
  while IFS= read -r s; do [ -n "$s" ] && SESSIONS+=("$s"); done < <(fleet_hub_sessions | sort)
fi
if [ "${#SESSIONS[@]}" -eq 0 ]; then
  log "no fleet sessions found (nothing to watch)"; exit 0
fi

tmux info >/dev/null 2>&1 || { log "tmux not running — nothing to watch"; exit 0; }

# Disk gate is a machine-wide (per-volume) condition — answer ONCE per tick. A full
# volume is the crash trigger; don't add even light load below the floor. (The
# diskguard daemon itself notifies the operator on low disk, so a skipped watch tick
# loses nothing.) Mirrors fleet-dispatch.sh.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping this tick"; exit 0
fi

for s in "${SESSIONS[@]}"; do
  watch_fleet "$s"
done
exit 0
