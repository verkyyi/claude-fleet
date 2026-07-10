#!/bin/bash
# tmux-issues-rows.sh [roadmap|unplanned|all] — emit fzf rows for a backlog panel.
# roadmap = milestoned issues grouped by milestone; unplanned = no-milestone flat
# list. READ-ONLY: reads THIS fleet's cache via fleet_cache (the collector writes
# $C/issues_<slug>: milestone\t#num\tassignee\ttitle; no flat mirror — issue #180).
# Line: <#num>US<colored display>US<milestone>. Milestone headers have empty
# field1 (Enter no-ops on them).
set -uo pipefail
MODE="${1:-all}"
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
C="${TMPDIR:-/tmp}/.claude-dash"
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
# this fleet's issues cache (slug'd via sessmap; flat fallback). FLEET_SESSION is
# exported by tmux-issues.sh so reload-binds inherit it.
SRC=$(fleet_cache issues "${FLEET_SESSION:-}")
IN='187;154;247'; GY='86;95;137'; TX='169;177;214'; GN='158;206;106'; CY='125;207;255'
c(){ printf '\033[38;2;%sm' "$1"; }; R=$'\033[0m'; US=$'\x1f'
NOMS='· no milestone'
if [ ! -s "$SRC" ]; then   # empty-but-fetched = 0 open issues; absent = not loaded yet
  [ -e "$SRC" ] && m='(no open issues)' || m='(loading issues…)'
  printf '%s%s%s%s\n' "$US" "$(c "$GY")" "$m" "$R"; exit 0
fi

# rank milestones: version-sorted order (so "Week 2" < "Week 10"), no-milestone last
MS_LIST=$(cut -f1 "$SRC" | grep -vxF "$NOMS" | sort -Vu)
mrank(){ case "$1" in "$NOMS") echo 99; return;; esac
  local r; r=$(printf '%s\n' "$MS_LIST" | grep -nxF "$1" | cut -d: -f1)
  echo "${r:-98}"; }

# active bindings: issue-number → session window name (from @issue window options)
# NB tmux -F emits LITERAL \t → must inject a real tab.
TAB=$'\t'
ACTIVE=$(tmux list-windows -a -F "#{session_name}${TAB}#{@issue}${TAB}#{window_name}" 2>/dev/null \
  | awk -F'\t' -v s="${FLEET_SESSION:-}" '$2!="" && (s=="" || $1==s){print $2"\t"$3}')
active_win(){ printf '%s\n' "$ACTIVE" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

# hide-bound state (per-fleet, keyed by session): by default an issue already
# bound to a live worker window is hidden; the ⌃b toggle (dash-toggle-show-bound.sh)
# creates this file to reveal them. Existence = show, absent = hide.
SHOW_BOUND=0
[ -f "$C/global/backlog_show_bound_${FLEET_SESSION:-_}" ] && SHOW_BOUND=1

buf=""; hidden_any=""
while IFS=$'\t' read -r ms num asg title; do
  [ -z "$num" ] && continue
  r=$(mrank "$ms")
  case "$MODE" in roadmap) [ "$r" -ge 99 ] && continue;; unplanned) [ "$r" -lt 99 ] && continue;; esac
  n=${num#\#}; awin=$(active_win "$n")
  # Hide rows bound to a live worker unless the toggle is on. Skipping here (not
  # at emit time) keeps the milestone counts below in step with the visible rows.
  if [ -n "$awin" ] && [ "$SHOW_BOUND" = 0 ]; then hidden_any=1; continue; fi
  # Fixed-width columns so the TITLE starts at the same screen column on every
  # row: num padded to 5, then an owner column of a 2-col marker + a 14-col name
  # (both active ▶window and idle assignee use the SAME 16-col owner width).
  # Precision (%-14.14s) pads *and* truncates the name; the marker sits outside
  # it so the multibyte ▶ doesn't skew the byte-counted width.
  if [ -n "$awin" ]; then
    row=$(printf '%s%-5s%s %s▶ %-14.14s%s %s%s%s' \
      "$(c "$GN")" "$num" "$R" "$(c "$CY")" "$awin" "$R" "$(c "$GY")" "$title" "$R")
  else
    # assignees are ASCII (14 bytes = 14 cols); the unassigned '·' is 1 col but 2
    # bytes (and the collector already writes it into this field), so widen its
    # byte budget by 1 to keep the 14-col visible width.
    asg_disp="${asg:-·}"; pad=14; [ "$asg_disp" = "·" ] && pad=15
    row=$(printf "%s%-5s%s %s  %-${pad}.${pad}s%s %s%s%s" \
      "$(c "$GN")" "$num" "$R" "$(c "$TX")" "$asg_disp" "$R" "$(c "$GY")" "$title" "$R")
  fi
  buf+="$r	$ms	$n	$row"$'\n'
done < "$SRC"

# All open issues (in this MODE) are bound + hidden → a friendly line instead of
# a bare blank/"(no open issues)", so the steward knows why the panel is empty.
if [ -z "$buf" ] && [ "$SHOW_BOUND" = 0 ] && [ -n "$hidden_any" ]; then
  printf '%s%s%s%s\n' "$US" "$(c "$GY")" '(all open issues have a live worker — ⌃b to show)' "$R"
  exit 0
fi

# collapse state (milestone names, one per line) + per-milestone counts
COLLAPSED=""; [ -f "$C/global/collapsed" ] && COLLAPSED=$(cat "$C/global/collapsed")
is_collapsed(){ printf '%s\n' "$COLLAPSED" | grep -qxF "$1"; }
counts=$(printf '%s' "$buf" | awk -F'\t' 'NF>=2{c[$2]++} END{for(m in c) print m"\t"c[m]}')
count_of(){ printf '%s\n' "$counts" | awk -F'\t' -v m="$1" '$1==m{print $2; exit}'; }

# emit: field1=num(empty for header)·field2=display·field3=milestone(for collapse toggle)
last=''
printf '%s' "$buf" | sort -t'	' -k1,1n -k3,3n | while IFS='	' read -r _ ms num row; do
  [ -z "$num" ] && continue
  if [ "$MODE" != unplanned ] && [ "$ms" != "$last" ]; then
    if is_collapsed "$ms"; then ind='▸'; else ind='▾'; fi
    printf '%s%s%s %s (%s)%s%s%s\n' "$US" "$(c "$IN")" "$ind" "$ms" "$(count_of "$ms")" "$R" "$US" "$ms"
    last="$ms"
  fi
  { [ "$MODE" != unplanned ] && is_collapsed "$ms"; } && continue
  printf '%s%s%s%s%s\n' "$num" "$US" "$row" "$US" "$ms"
done
