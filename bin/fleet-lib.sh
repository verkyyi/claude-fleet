#!/bin/bash
# fleet-lib.sh — shared helpers for the multi-fleet model (a fleet ≡ a tmux
# session ≡ one repo). Sourced by the collector (write side) and the read-side
# producers (dashboard/backlog). See docs/ARCHITECTURE.md.
#
# The collector does the EXPENSIVE session→repo resolution once per cycle and
# records it in $C/sessmap (session<TAB>slug<TAB>repo). Read-side producers use
# the CHEAP cached lookups below (no git/tmux forks), and fall back to the flat
# prmap/issues names when nothing resolves — so a single-fleet install behaves
# exactly as before.
#
# Shell-options policy (see CONTRIBUTING.md): this file is SOURCED, so it must
# NOT `set -u`/`set -o pipefail` — those would leak into every caller's shell and
# change behaviour far from here. Instead it is written to be safe under a `set -u`
# caller: every optional expansion is defaulted (`${VAR:-}`) and every helper
# returns cleanly.

FLEET_C="${TMPDIR:-/tmp}/.claude-dash"
# Per-fleet configs live here, one <session>.conf per fleet (Phase 2). Override
# FLEET_CONF_DIR to relocate (used by the test harness).
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# git remote URL (or owner/name) → owner/name. Empty if it isn't GitHub-ish.
fleet_norm_repo() {
  printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'
}

# The tmux session the caller is running in (pane-targeted, client fallback).
fleet_current_session() {
  local s
  s=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
  [ -z "$s" ] && s=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  printf '%s' "$s"
}

# Overlay a fleet's per-session conf ON TOP of the already-sourced global
# fleet.conf, so FLEET_REPO/FLEET_MAIN/FLEET_BASE_BRANCH/... target THIS fleet.
# Sources into the caller's shell (call it non-subshelled). No-op if absent.
fleet_load_conf() {
  local conf="$FLEET_CONF_DIR/${1}.conf"
  [ -f "$conf" ] && . "$conf"
  return 0
}

# Write a fleet's per-session conf, PRESERVING everything the operator added
# (issue #170). fleet-up.sh regenerates this conf on every restore; a naive
# truncating `cat >` silently drops FLEET_ISSUE_BRIDGE / FLEET_SELF_LAND /
# FLEET_AUTOFILL / FLEET_MAX_SESSIONS / FLEET_STEWARD_ISSUE / … — anything outside
# the derived three. Here we rewrite ONLY the three derived keys (repo/main/base)
# and re-emit every OTHER line from the existing conf verbatim — not just custom
# FLEET_* keys but comments, `source` includes, and plain vars too (dropping any
# of those is the same silent-content-loss class this fix exists to kill). The one
# thing we strip is OUR OWN regenerated header, so repeated rewrites don't stack
# stale headers. Atomic (temp + mv in the same dir) so an interrupted or failed
# write never leaves a truncated conf. Args:
#   $1=conf path  $2=session name  $3=repo  $4=main  $5=base  $6=timestamp string
fleet_write_conf() {
  local conf="$1" name="$2" repo="$3" main="$4" base="$5" stamp="$6"
  local tmp preserved=""
  # The three derived assignment lines we re-derive canonically (optional leading
  # whitespace / `export`), and our own 3-line auto-generated header (matched by
  # its fixed phrasing, timestamp-independent) — both are re-emitted below.
  local derived='^[[:space:]]*(export[[:space:]]+)?FLEET_(REPO|MAIN|BASE_BRANCH)='
  local ourhdr='^# (claude-fleet: fleet .* written by fleet-up\.sh|Overlays the global fleet\.conf|FLEET_\* keys \(see fleet\.conf\.example\))'
  if [ -f "$conf" ]; then
    preserved=$(grep -Ev "$derived" "$conf" 2>/dev/null | grep -Ev "$ourhdr")
  fi
  tmp="$conf.tmp.$$"
  {
    printf "# claude-fleet: fleet '%s' — written by fleet-up.sh %s\n" "$name" "$stamp"
    printf '# Overlays the global fleet.conf for this fleet'\''s tmux session. Add any other\n'
    printf '# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.\n'
    printf 'FLEET_REPO="%s"\n' "$repo"
    printf 'FLEET_MAIN="%s"\n' "$main"
    printf 'FLEET_BASE_BRANCH="%s"\n' "$base"
    # `if` (not `&&`) so an empty $preserved doesn't make the group exit non-zero.
    if [ -n "$preserved" ]; then printf '%s\n' "$preserved"; fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
}

# CHEAP: which SEAT is the caller running in? (see commands/README.md — the
# fleet-skill role-guard.) Prints:
#   worker  — the current tmux window has @issue set AND cwd is inside an
#             issue-<N> git worktree (a session bound to one issue)
#   steward — no @issue on the window AND cwd is the fleet base checkout
#             ($FLEET_MAIN — the hub session that triages, doesn't implement)
#   ""      — neither (ambiguous: a stray shell, or cwd elsewhere)
# Needs FLEET_MAIN in the environment to recognise the steward seat, so call
# fleet_load_conf first. Pure tmux + shell builtins, no git/gh forks.
fleet_seat() {
  local issue cwd main
  issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)
  # Match both the bare `issue-<N>` worktree name and the `<repo>-issue-<N>`
  # form that cw.zsh actually creates (dir="$root/../${repo}-${branch}"), where
  # `issue-<N>` is preceded by `-`, not `/`. `*/*issue-[0-9]*` still requires a
  # path separator (a real nested path) but tolerates the `<repo>-` prefix.
  case "$cwd" in
    */*issue-[0-9]*)
      [ -n "$issue" ] && { printf 'worker'; return; } ;;
  esac
  if [ -z "$issue" ] && [ -n "${FLEET_MAIN:-}" ]; then
    main=$(cd "$FLEET_MAIN" 2>/dev/null && pwd -P)
    [ -n "$main" ] && [ "$cwd" = "$main" ] && { printf 'steward'; return; }
  fi
  return 0
}

# Mark a pane with exactly ONE of the mutually-exclusive fleet role markers —
# @dash (the mission-control dashboard) or @steward (the steward hub). Both
# dash-/steward-zoom AND /fleet-sync-install key off these, so a pane must never
# carry both at once (it would read as both a dash to respawn and a steward hub).
# This sets the chosen role to 1 and UNSETS the other, on the pane the caller
# names — defaulting to the caller's OWN pane ($TMUX_PANE), NEVER the active
# pane. tmux's `set-option -p` alone targets the *active* pane, which is wrong
# when the dash relaunches while another pane is focused (issue #135): the marker
# would land on whatever pane happens to be active. Passing `-t <pane>` pins it.
# Args: <dash|steward> [pane-id]   (pane-id defaults to $TMUX_PANE)
fleet_mark_role() {
  local role="${1:-}" pane="${2:-${TMUX_PANE:-}}" on off
  [ -n "$pane" ] || return 0
  case "$role" in
    dash)    on='@dash';    off='@steward' ;;
    steward) on='@steward'; off='@dash' ;;
    *) return 1 ;;
  esac
  tmux set-option -p -t "$pane" "$on" 1  2>/dev/null || true
  tmux set-option -u -p -t "$pane" "$off" 2>/dev/null || true
}

# CHEAP: the @steward=1 pane_id in <session> (that fleet's steward hub pane), or
# empty if the session has none. The shared marker lookup for the SESSION-scoped
# callers steward-zoom.sh and steward-session.sh (issue #146). The issue-bridge
# does NOT use this — it scans @steward panes across ALL sessions in one pass and
# needs @claude_state(_ts) + repo-match in the same row, so it has its own
# machine-wide scan (bridge_find_steward); keep the @steward=1 marker semantics in
# step between the two. Scoped with -s so it never leaks a pane from another fleet.
# Pure tmux + awk, no git/gh forks.
fleet_steward_pane() {
  [ -n "${1:-}" ] || return 0
  tmux list-panes -s -t "$1" -F '#{pane_id} #{@steward}' 2>/dev/null \
    | awk '$2=="1"{print $1; exit}'
}

# The "clean + merged?" gate shared by the worktree janitor (worktree-autoclean.sh)
# and the dash reaper (dash-reap.sh) — ONE source for identical guarantees. Given a
# worktree, decides whether it is safe to auto-remove. Prints a reason token on
# stdout and sets the return code:
#   merged-pr   (rc 0) — clean AND a MERGED PR exists for the branch
#   ancestor    (rc 0) — clean AND the tip is an ancestor of the base ref
#   dirty       (rc 1) — has uncommitted/untracked changes (untracked counts)
#   unmerged    (rc 1) — clean but neither a merged PR nor an ancestor of base
# Args: <worktree-dir> <repo-root> <branch> <head-sha> <base-ref> <merged-branches>
# <merged-branches> is a newline-separated list of merged PR head-ref names (the
# caller's `gh pr list --state merged` output). A caller that only wants the two
# safe outcomes can just test the return code. Safe under a `set -u` caller.
fleet_reap_ok() {
  local wtdir="${1:-}" root="${2:-}" branch="${3:-}" head="${4:-}" base="${5:-}" merged="${6:-}"
  if [ -n "$wtdir" ] && [ -e "$wtdir" ] \
     && [ -n "$(git -C "$wtdir" status --porcelain 2>/dev/null)" ]; then
    printf 'dirty'; return 1
  fi
  if [ -n "$branch" ] && printf '%s\n' "$merged" | grep -qxF "$branch"; then
    printf 'merged-pr'; return 0
  fi
  if [ -n "$head" ] && [ -n "$base" ] \
     && git -C "$root" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
    printf 'ancestor'; return 0
  fi
  printf 'unmerged'; return 1
}

# Locate the worktree checked out on <branch> in <repo-root>. Prints
# "<worktree-dir>\t<HEAD-sha>" (tab-separated) or nothing if the branch has no
# worktree. Used by dash-reap.sh; the janitor keeps its own full-scan loop since
# it iterates EVERY worktree per cycle, not one branch. Safe under `set -u`.
fleet_worktree_head() {
  local root="${1:-}" branch="${2:-}" line d="" h=""
  [ -n "$root" ] && [ -n "$branch" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) d="${line#worktree }" ;;
      "HEAD "*)     h="${line#HEAD }" ;;
      "branch refs/heads/$branch") printf '%s\t%s' "$d" "$h"; return 0 ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  return 0
}

# Reap any processes still anchored to a worktree BEFORE it is removed (issue
# #151). A worker can detach processes — selftest tmux servers, backgrounded
# scripts, hung pipes — that outlive `git worktree remove`: reparented to init,
# invisible to the janitor, they keep burning CPU/fds against the SHARED tmux
# server (a since-fixed hang became a permanent 100%-core drain in crash #3).
# Nothing should outlive its worktree.
#
#   $1  worktree dir (required; a broad root like / or $HOME is refused)
#   $2  mode: "kill" (default) SIGTERM→grace→SIGKILL, or "dry" (report only)
#   $3  grace seconds before SIGKILL (default 2; ignored in dry mode)
#
# Finds them two ways because the crash-#3 orphan had a RELATIVE argv but its cwd
# was inside the worktree: (1) argv references the path (pgrep -f — catches e.g. a
# selftest `tmux -S <dir>/sock`), and (2) cwd is inside the path (lsof, or /proc
# on Linux). Never touches this process, its parent, pid≤1, or the shared tmux
# server. Prints a one-line summary to stdout (the caller logs it). Best-effort:
# absent pgrep/lsof simply narrow the search; it never fails the caller.
fleet_reap_worktree_procs() {
  local dir="${1:-}" mode="${2:-kill}" grace="${3:-2}"
  [ -n "$dir" ] || { printf 'no worktree dir\n'; return 0; }
  dir="${dir%/}"
  # Never sweep a broad root — a bad caller must not turn this into a mass kill.
  case "$dir" in ""|/|/Users|/home|/tmp|/var|"$HOME") printf 'refused (broad root: %s)\n' "$dir"; return 0 ;; esac

  # Canonical (symlink-resolved) form for the cwd match: lsof/readlink report the
  # PHYSICAL path (macOS /var → /private/var), so compare against that. argv match
  # keeps the path as passed (that's how the process references it on its cmdline).
  local cdir; cdir="$(cd "$dir" 2>/dev/null && pwd -P)"; [ -n "$cdir" ] || cdir="$dir"

  local pids="" p re
  # 1) argv references the worktree path. Escape ERE metacharacters so a `.` in
  #    the path can't over-match an unrelated process (pgrep -f is a regex).
  if command -v pgrep >/dev/null 2>&1; then
    re="$(printf '%s' "$dir" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    pids="$(pgrep -f "$re" 2>/dev/null)"
  fi
  # 2) cwd is inside the worktree. One lsof lists every process's cwd (macOS +
  #    Linux); fall back to /proc where lsof is absent. Exact prefix match on $cdir.
  if command -v lsof >/dev/null 2>&1; then
    pids="$pids
$(lsof -w -d cwd -Fpn 2>/dev/null | awk -v d="$cdir" '
        /^p/ { pid=substr($0,2) }
        /^n/ { path=substr($0,2)
               if (path==d || substr(path,1,length(d)+1)==d"/") print pid }')"
  elif [ -d /proc ]; then
    for p in /proc/[0-9]*/cwd; do
      case "$(readlink "$p" 2>/dev/null)" in
        "$cdir"|"$cdir"/*) p="${p#/proc/}"; pids="$pids ${p%/cwd}" ;;
      esac
    done
  fi

  # Dedupe → drop self, parent, pid≤1, and the shared tmux server → keep runnable.
  local self=$$ parent="${PPID:-0}" list="" tmuxpid=""
  command -v pgrep >/dev/null 2>&1 && tmuxpid="$(pgrep -x tmux 2>/dev/null; pgrep -f 'tmux: server' 2>/dev/null)"
  for p in $(printf '%s\n' $pids | grep -E '^[0-9]+$' | sort -un); do
    [ "$p" -gt 1 ] 2>/dev/null || continue
    [ "$p" = "$self" ] && continue
    [ "$p" = "$parent" ] && continue
    printf '%s\n' $tmuxpid | grep -qx "$p" && continue
    list="$list $p"
  done
  list="${list# }"
  [ -n "$list" ] || { printf 'no orphan procs\n'; return 0; }

  if [ "$mode" = dry ]; then printf 'would reap:%s\n' " $list"; return 0; fi

  kill -TERM $list 2>/dev/null
  # brief grace, then SIGKILL survivors (a spinning orphan may ignore SIGTERM).
  local i=0; while [ "$i" -lt "$grace" ]; do sleep 1; i=$((i+1)); done
  local survivors=""
  for p in $list; do kill -0 "$p" 2>/dev/null && survivors="$survivors $p"; done
  [ -n "$survivors" ] && kill -KILL $survivors 2>/dev/null
  printf 'reaped:%s%s\n' " $list" "${survivors:+ (SIGKILL$survivors)}"
}

# owner/name → filesystem-safe slug (owner-name).
fleet_slug() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
}

# issue title → short kebab window name (lowercase, ascii-alnum + single
# hyphens, ≤32 chars, no leading/trailing hyphen). Used to name a session's
# tmux window after the issue CONTENT instead of a bare "issue-<N>". Prints
# empty when the title has no usable ascii-alnum content (non-latin titles,
# symbols-only) — callers fall back to "issue-<N>". LC_ALL=C so tr classes
# operate byte-wise (multibyte chars collapse to hyphens, not errors).
fleet_win_name() {
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9\n' '-' \
    | LC_ALL=C tr -s '-' \
    | sed -e 's/^-//' -e 's/-$//' \
    | cut -c1-32 \
    | sed -e 's/-$//'
}

# EXPENSIVE: resolve a tmux session's repo. Order: per-session conf override
# (~/.config/claude-fleet/<sess>.conf, Phase 2), else the origin remote of the
# first git checkout among its windows, else the global FLEET_REPO. Prints
# owner/name or empty. Collector-only (runs once per cycle).
fleet_resolve_repo_for_session() {
  local sess="$1" conf repo path
  conf="$FLEET_CONF_DIR/${sess}.conf"
  if [ -f "$conf" ]; then
    repo=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$repo" ] && { fleet_norm_repo "$repo"; return; }
  fi
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
    repo=$(git -C "$path" remote get-url origin 2>/dev/null) || continue
    repo=$(fleet_norm_repo "$repo")
    [ -n "$repo" ] && { printf '%s' "$repo"; return; }
  done < <(tmux list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null | awk '!seen[$0]++')
  fleet_norm_repo "${FLEET_REPO:-}"
}

# CHEAP: session → slug from the collector's sessmap (single awk, no forks into
# git/tmux). Prints slug or empty.
fleet_slug_cached() {
  [ -f "$FLEET_C/sessmap" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$FLEET_C/sessmap"
}

# CHEAP: session → repo (owner/name) from the sessmap. Prints repo or empty.
fleet_repo_cached() {
  [ -f "$FLEET_C/sessmap" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $3; exit}' "$FLEET_C/sessmap"
}

# CHEAP: list the tmux sessions that are FLEETS — i.e. own a 'plan' or 'dash' hub
# window — one per line. The single source for "which sessions are fleets"; the
# plan/dash hub rule is otherwise copy-pasted across callers. Pure tmux + awk.
fleet_hub_sessions() {
  tmux list-windows -a -F '#{session_name} #{window_name}' 2>/dev/null | awk '
    { if ($2=="plan" || $2=="dash") f[$1]=1 } END { for (s in f) print s }'
}

# CHEAP: count the live Claude WORKING-session windows across every fleet on this
# tmux server (the system-wide count issue #28's cap measures). A fleet session
# is one that owns a hub window ('plan' or 'dash'); inside it, windows named
# dash/plan/backlog are panels — everything else is a Claude working session
# (the same rule the dashboard uses). Pure tmux + awk, no git/tmux-per-window
# forks. Prints an integer (0 if tmux isn't running or no fleets are up).
fleet_session_count() {
  tmux list-windows -a -F '#{session_name} #{window_name}' 2>/dev/null | awk '
    { rows[NR]=$0; if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        split(rows[i], a, " "); s=a[1]; w=a[2]
        if (fleet[s] && w!="dash" && w!="plan" && w!="backlog") c++
      }
      print c+0
    }'
}

# CHEAP: count the live Claude WORKING-session windows in ONE fleet session (the
# per-fleet analogue of fleet_session_count, for issue #70's FLEET_MAX_SESSIONS).
# Only counts if the session is a real fleet (owns a 'plan'/'dash' hub window);
# inside it, dash/plan/backlog are panels, everything else is a working session —
# the same rule the dashboard and the global count use. Prints an integer (0 if
# the session isn't a fleet, doesn't exist, or tmux isn't running).
# NB: the hub/panel names (plan/dash/backlog) are duplicated in fleet_session_count
# above — keep BOTH in sync, or the global and per-fleet caps count different sets.
fleet_session_count_for() {
  tmux list-windows -t "$1" -F '#{window_name}' 2>/dev/null | awk '
    { name=$0; if (name=="plan" || name=="dash") hub=1; rows[NR]=name }
    END {
      if (!hub) { print 0; exit }
      for (i=1; i<=NR; i++) {
        n=rows[i]
        if (n!="dash" && n!="plan" && n!="backlog") c++
      }
      print c+0
    }'
}

# Cap on concurrent Claude working sessions (issues #28, #70). Returns 0 if a new
# session may be spawned, non-zero if a cap is already reached. Two ceilings:
#   • GLOBAL   FLEET_GLOBAL_MAX_SESSIONS (default 8) — SYSTEM-WIDE across all
#              fleets; 0 ⇒ unlimited. Always checked.
#   • PER-FLEET FLEET_MAX_SESSIONS (default 0 = unlimited) — checked ONLY when a
#              session name is passed as $1 (so existing no-arg callers keep the
#              global-only behaviour unchanged) AND the cap is a positive number.
# On refusal, prints a human-readable reason on stdout for the caller to surface
# (tmux display-message); prints nothing when allowed.
fleet_session_cap_ok() {
  local sess="${1:-}"
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac   # tolerate a garbled conf value
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  if [ "$gmax" -ne 0 ]; then                   # 0 ⇒ unlimited
    n=$(fleet_session_count)
    if [ "$n" -ge "$gmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions running (global) — raise FLEET_GLOBAL_MAX_SESSIONS or close one first' "$n" "$gmax"
      return 1
    fi
  fi
  if [ -n "$sess" ] && [ "$fmax" -ne 0 ]; then
    n=$(fleet_session_count_for "$sess")
    if [ "$n" -ge "$fmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions in this fleet — raise FLEET_MAX_SESSIONS or close one first' "$n" "$fmax"
      return 1
    fi
  fi
  return 0
}

# Pick the cache file for <base> (prmap|issues) for a session: the slug'd file if
# the session resolved AND its fetch has COMPLETED (the .ts marker exists, even if
# the repo has 0 rows), else the flat fallback. Keying off .ts — not file size —
# so a fleet whose repo genuinely has 0 issues/PRs shows empty rather than reading
# a stale un-slug'd file. The flat (un-slug'd) name is ONLY a degenerate cold-start
# fallback: no producer writes it anymore (issue #180 removed the "primary" flat
# mirror — all fleets are equal), so it typically won't exist and readers treat
# absent as "loading". This is the SINGLE slug-resolution truth every reader uses.
fleet_cache() {
  local base="$1" slug
  slug=$(fleet_slug_cached "$2")
  if [ -n "$slug" ] && [ -f "$FLEET_C/${base}_${slug}.ts" ]; then
    printf '%s' "$FLEET_C/${base}_${slug}"
  else
    printf '%s' "$FLEET_C/${base}"
  fi
}
