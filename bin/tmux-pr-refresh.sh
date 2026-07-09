#!/bin/bash
# tmux-pr-refresh.sh — dedicated FAST refresher for PR/CI status on the dash +
# status bar. The PR pipeline used to ride the collector's 60s tick
# (tmux-dash-collect.sh), so "CI went green" / "PR merged" took up to a minute to
# surface — exactly when the steward is watching to /land. This script owns that
# pipeline on its own ~15s cadence (FLEET_PR_REFRESH_INTERVAL) instead.
#
# SINGLE WRITER of prmap_<slug> (+ the flat prmap mirror) and each window's
# @prci/@pfg options. tmux-dash-collect.sh no longer touches ANY PR state, so
# there is no double-writer race on these caches — the collector keeps git/usage/
# issues on 60s, PR status refreshes here on 15s.
#
# Writes under $C = $TMPDIR/.claude-dash:
#   prmap_<slug>  — branch<TAB>#num<TAB>state<TAB>ci<TAB>ready  per repo (same
#                   contract as before; see tmux-dash-collect.sh header)
#   prmap         — flat mirror of the PRIMARY (FLEET_REPO) slug'd file
#   @prci / @pfg  — per-window tmux options (glyph + color)
# Reads (owned by the collector, read-only here): sessmap (session→slug→repo)
# and git_<key> (window branch). Run from launchd (com.claude-fleet.pr-refresh,
# StartInterval FLEET_PR_REFRESH_INTERVAL) or a systemd user timer.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
# Sweep this run's PID-unique temps on exit (a failed gh fetch only `mv`s on
# success, so it would otherwise orphan a 0-byte prmap_<slug>.$$ forever).
trap 'rm -f "$C"/*.'"$$" EXIT
REPO="${FLEET_REPO:-}"
now() { date +%s; }

# atomic_write / cache_key — byte-identical to bin/tmux-dash-collect.sh. Both
# scripts write the same cache dir, so these MUST stay in lockstep (a reader
# can't tell which process wrote a file). See that file for the full rationale
# (rename(2) atomicity; collision-free reversible worktree key).
atomic_write() {
  local dest="$1" tmp="$1.$$"
  cat > "$tmp" && mv "$tmp" "$dest"
}
cache_key() {
  local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"
}

tmux info >/dev/null 2>&1 || exit 0
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
# job. Seed with the primary FLEET_REPO (so its flat mirror stays fresh with no
# session), add every repo a live session resolved to, then the configured
# fleets (FLEET_REPOS + per-fleet confs) so a watched-but-unopened repo refreshes.
declare -a Q_REPO Q_SLUG          # unique (repo,slug) fetch queue (bash 3.2 ok)
SEEN=' '
queue() {                          # $1=repo → add once
  local r="$1" s
  [ -z "$r" ] && return
  s=$(fleet_slug "$r")
  case "$SEEN" in *" $s "*) return;; esac
  SEEN="$SEEN$s "; Q_REPO+=("$r"); Q_SLUG+=("$s")
}
PRIMARY_SLUG=''
if [ -n "$REPO" ]; then PRIMARY_SLUG=$(fleet_slug "$(fleet_norm_repo "$REPO")"); queue "$(fleet_norm_repo "$REPO")"; fi
if [ -f "$C/sessmap" ]; then
  while IFS=$'\t' read -r _ _ rp; do
    [ -n "$rp" ] && queue "$(fleet_norm_repo "$rp")"
  done < "$C/sessmap"
fi
for r in ${FLEET_REPOS:-}; do queue "$(fleet_norm_repo "$r")"; done
if [ -d "$FLEET_CONF_DIR" ]; then
  for cf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$cf" ] || continue
    r=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$r" ] && queue "$(fleet_norm_repo "$r")"
  done
fi

# --- per-repo PR map (TTL-gated) — the ONLY writer of prmap_<slug> ---
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; i=$((i+1))
  command -v gh >/dev/null 2>&1 || break
  pts=$(cat "$C/prmap_$sg.ts" 2>/dev/null || echo 0)
  if [ $(( $(now) - pts )) -ge "$PR_TTL" ]; then
    # shellcheck disable=SC2016  # $r/$ci/$ready are jq vars, not shell — keep single-quoted
    gh pr list --repo "$rp" --state all --limit 100 \
      --json number,headRefName,state,mergeable,mergeStateStatus,statusCheckRollup \
      --jq 'group_by(.headRefName)[] | max_by(.number) |
            (.statusCheckRollup // []) as $r |
            (if   ($r|length)==0                     then "·"
             elif ($r|any(.conclusion=="FAILURE"))   then "✗"
             elif ($r|any(.status!="COMPLETED"))     then "…"
             elif ($r|any(.conclusion=="SUCCESS"))   then "✓"
             else "…" end) as $ci |
            (if .state=="OPEN" and $ci=="✓" then
               (if   (.mergeStateStatus=="CLEAN" or .mergeStateStatus=="HAS_HOOKS") then "ready"
                elif .mergeStateStatus=="BEHIND"                                    then "behind"
                elif (.mergeStateStatus=="DIRTY" or .mergeable=="CONFLICTING")      then "conflict"
                elif .mergeStateStatus=="BLOCKED"                                   then "blocked"
                else "" end)
             else "" end) as $ready |
            .headRefName + "\t#" + (.number|tostring) + "\t" + .state + "\t" + $ci + "\t" + $ready' \
      > "$C/prmap_$sg.$$" 2>/dev/null && mv "$C/prmap_$sg.$$" "$C/prmap_$sg"
    now > "$C/prmap_$sg.ts"
  fi
done

# --- back-compat flat mirror: PRIMARY repo → the un-slug'd prmap name ---
if [ -n "$PRIMARY_SLUG" ] && [ -s "$C/prmap_$PRIMARY_SLUG" ]; then
  atomic_write "$C/prmap" < "$C/prmap_$PRIMARY_SLUG"
fi

# --- PR/CI attention signal ---
# Maps each window's branch → its open PR's CI state; writes @prci (glyph) +
# @pfg (color). window-status-format renders them after the window name and
# tmux-sort-windows.sh treats ✗ like 'needs'. Single writer of @prci/@pfg.
US=$'\x1f'
tmux list-windows -a -F "#{session_name}${US}#{session_name}:#{window_index}${US}#{pane_current_path}${US}#{@prci}" 2>/dev/null | \
while IFS="$US" read -r sess win path cur; do
  [ -z "$path" ] && continue
  # each window matches against ITS fleet's prmap (slug from sessmap), flat fallback
  slug=$(fleet_slug_cached "$sess")
  prmf="$C/prmap"; [ -n "$slug" ] && [ -f "$C/prmap_$slug.ts" ] && prmf="$C/prmap_$slug"
  key=$(cache_key "$path")
  branch=$(cut -f1 "$C/git_$key" 2>/dev/null)
  bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
  glyph=""; pfg=""
  if [ -n "$bare" ] && [ "$bare" != "-" ]; then
    hit=$(awk -F'\t' -v x="$bare" '$1==x{print;exit}' "$prmf" 2>/dev/null)
    if [ -n "$hit" ] && [ "$(echo "$hit"|cut -f3)" = "OPEN" ]; then
      ready=$(echo "$hit"|cut -f5)
      case "$(echo "$hit"|cut -f4)" in
        ✗) glyph="✗"; pfg="#f7768e";;   # real CI failure → attention
        ✓) case "$ready" in             # green: decorate by land-readiness
             behind)   glyph="✓↑"; pfg="#e0af68";;   # green but behind base → update-branch
             conflict) glyph="✓!"; pfg="#f7768e";;   # green but conflicting → rebase
             blocked)  glyph="✓·"; pfg="#e0af68";;   # green+mergeable but blocked (protection)
             *)        glyph="✓";  pfg="#9ece6a";;   # green, awaiting merge
           esac;;
      esac
    fi
  fi
  if [ "$cur" != "$glyph" ]; then
    tmux set-window-option -t "$win" @prci "$glyph" 2>/dev/null
    tmux set-window-option -t "$win" @pfg "$pfg" 2>/dev/null
  fi
done
exit 0
