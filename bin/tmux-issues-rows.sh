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
P0='247;118;142'; P1='224;175;104'; P2='224;204;122'   # priority tier tags (red/orange/yellow)
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

# priority per issue: read the collector's labels cache (num<TAB>comma-labels — the
# SAME fetch the backlog uses, no extra gh call) and map the priority:p{0,1,2} label
# to a tier 0/1/2 (3 = unprioritised). Drives both the row tag and the in-milestone
# sort below, and the whole file degrades to "no tags, number order" if it's absent.
LBL=$(fleet_cache labels "${FLEET_SESSION:-}")
PRIOS=$(cat "$LBL" 2>/dev/null)
prio_tier(){ # $1 = bare issue number → 0/1/2/3
  local ls; ls=$(printf '%s\n' "$PRIOS" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}')
  case ",$ls," in
    *,priority:p0,*) echo 0 ;; *,priority:p1,*) echo 1 ;; *,priority:p2,*) echo 2 ;; *) echo 3 ;;
  esac
}
prio_tag(){ # $1 = tier → a fixed 2-col colored tag (or 2 spaces for none)
  case "$1" in
    0) printf '%sp0%s' "$(c "$P0")" "$R" ;; 1) printf '%sp1%s' "$(c "$P1")" "$R" ;;
    2) printf '%sp2%s' "$(c "$P2")" "$R" ;; *) printf '  ' ;;
  esac
}

# Pre-flight PR cross-ref (issue #331): the spawn gate refuses an issue whose
# issue-<N> branch already has an OPEN PR (in flight elsewhere), but that PR is
# INVISIBLE in the backlog today. The SINGLE-WRITER prmap cache
# (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready — bin/tmux-pr-refresh.sh) lets us
# flag such a row with ZERO extra gh (no network on render). Absent/cold cache ⇒
# no PR flags, so this degrades cleanly to today's behaviour.
PRMAP=$(fleet_cache prmap "${FLEET_SESSION:-}")
PRROWS=$(cat "$PRMAP" 2>/dev/null)
open_pr(){ # $1 = bare issue number → "#<prnum>" if issue-<N> has an OPEN PR, else empty
  printf '%s\n' "$PRROWS" | awk -F'\t' -v b="issue-$1" '$1==b && $3=="OPEN"{print $2; exit}'
}

# parent→child links (issue #335): the collector's per-fleet `parents` cache
# (child<TAB>parent, from a small GraphQL sub-issues pass — bin/tmux-dash-collect.sh)
# lets us NEST a sub-issue under its parent row (indented) in the backlog — the
# visual "this may overlap live parent work" cue. The nesting is cosmetic only:
# pre-spawn dedup (bin/dash-issue-session.sh) stays the single collision authority,
# and a child keeps its own field1 issue number so Enter still spawns it. Absent/
# cold cache ⇒ empty map ⇒ the backlog renders FLAT (pre-#335 behaviour).
PARMAP=$(fleet_cache parents "${FLEET_SESSION:-}")
PARENTS=$(cat "$PARMAP" 2>/dev/null)

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
  tier=$(prio_tier "$n"); ptag=$(prio_tag "$tier")
  # Fixed-width columns so the TITLE starts at the same screen column on every
  # row: num padded to 5, a 2-col priority tag, then an owner column of a 2-col
  # marker + a 14-col name (both active ▶window and idle assignee use the SAME
  # 16-col owner width). Precision (%-14.14s) pads *and* truncates the name; the
  # marker and the tag sit outside it so multibyte glyphs don't skew the width.
  if [ -n "$awin" ]; then
    row=$(printf '%s%-5s%s %s %s▶ %-14.14s%s %s%s%s' \
      "$(c "$GN")" "$num" "$R" "$ptag" "$(c "$CY")" "$awin" "$R" "$(c "$GY")" "$title" "$R")
  else
    # Pre-flight "will-refuse" flag (issue #331): the spawn gate refuses an issue
    # that is ASSIGNED (claimed by a peer / other machine) or has an OPEN issue-<N>
    # PR (in flight elsewhere) — but neither reads as "will-refuse" here today: a
    # foreign claim shows a bare assignee name (no cue) and an open PR is wholly
    # invisible. FLAG (not hide) them — dim + a marker — so a would-refuse row
    # reads differently from a free one at a glance; you still SEE it (⌃o still
    # opens it) and the spawn gate stays the SINGLE authority on the real refusal
    # (a row flagged stale that has since freed still spawns fine — the gate is
    # truth). The owner column keeps its 2-col marker + name geometry.
    #
    # assignees are ASCII (14 bytes = 14 cols); the unassigned '·' is 1 col but 2
    # bytes (and the collector already writes it into this field), so widen its
    # byte budget by 1 to keep the 14-col visible width.
    asg_disp="${asg:-·}"; pad=14; [ "$asg_disp" = "·" ] && pad=15
    pr=$(open_pr "$n")
    if [ -n "$pr" ]; then                 # OPEN PR in flight elsewhere → PR marker, dim
      mk='⇡'; mkc="$P1"; own="$pr"; ownc="$GY"; opad=14
    elif [ "$asg_disp" != "·" ]; then     # foreign claim (assigned) → claim marker, dim
      mk='◦'; mkc="$GY"; own="$asg_disp"; ownc="$GY"; opad=14
    else                                  # free → plain (unchanged: blank marker, TX name)
      mk=' '; mkc="$TX"; own="$asg_disp"; ownc="$TX"; opad="$pad"
    fi
    row=$(printf "%s%-5s%s %s %s%s %s%-${opad}.${opad}s%s %s%s%s" \
      "$(c "$GN")" "$num" "$R" "$ptag" "$(c "$mkc")" "$mk" "$(c "$ownc")" "$own" "$R" "$(c "$GY")" "$title" "$R")
  fi
  buf+="$r	$ms	$tier	$n	$row"$'\n'
done < "$SRC"

# All open issues (in this MODE) are bound + hidden → a friendly line instead of
# a bare blank/"(no open issues)", so the steward knows why the panel is empty.
if [ -z "$buf" ] && [ "$SHOW_BOUND" = 0 ] && [ -n "$hidden_any" ]; then
  printf '%s%s%s%s\n' "$US" "$(c "$GY")" '(all open issues have a live worker — ⌃b to show)' "$R"
  exit 0
fi

# Nest sub-issues under their parent (issue #335). The tier column (field3) becomes
# a MATERIALIZED-PATH sort key: for each visible row we walk the parent chain (from
# the `parents` cache) UP through ancestors that are themselves visible AND in the
# SAME milestone group, then emit one fixed-width `<tier><num0…>` segment per level
# root→self. A lexical sort of that key is a pre-order DFS — a child lands directly
# under its parent — while a top-level row (depth 0) keeps its plain tier→num order,
# so the flat-cache case is byte-identical to before. The display is indented 2 cols
# per level (a dim ↳ at the innermost) to show the nesting; field1 (num) is untouched
# so Enter still spawns the child. Cross-milestone / closed / hidden parents don't
# qualify (can't nest under a row that isn't there) → the child renders top-level.
buf=$(printf '%s' "$buf" | awk -F'\t' -v OFS='\t' -v gy="$(c "$GY")" -v rst="$R" \
  -v pf=<(printf '%s' "$PARENTS") '
  # The parents map is read in BEGIN (child→parent), NOT as a second input file:
  # the classic FNR==NR two-file idiom silently misparses ALL buf rows as parent
  # links when the parents cache is EMPTY (an empty first file leaves NR==FNR true
  # for the whole second file) — which is exactly the flat/degraded case. getline
  # from a path sidesteps that: buf (stdin) is the ONE record stream.
  BEGIN { while ((getline ln < pf) > 0) if (split(ln, a, "\t") >= 2 && a[1] != "" && a[2] != "") par[a[1]] = a[2] }
  {
    i++; brank[i]=$1; bms[i]=$2; bnum[i]=$4
    disp=$5; for (f=6; f<=NF; f++) disp=disp OFS $f      # keep any tab in the title
    bdisp[i]=disp
    vis[$4]=1; vms[$4]=$2; vtier[$4]=$3                  # visible index, by issue number
  }
  END {
    for (j=1; j<=i; j++) {
      n=bnum[j]; m=bms[j]; cn=0; cur=n
      while (1) {                                        # chain self→root (same-ms, visible ancestors)
        chain[cn++]=cur; p=par[cur]
        if (p=="" || !(p in vis) || vms[p]!=m || cn>=64) break
        cur=p
      }
      depth=cn-1; path=""
      for (k=cn-1; k>=0; k--) path=path sprintf("%d%07d", vtier[chain[k]], chain[k])
      ind=""
      if (depth>0) { for (k=1; k<depth; k++) ind=ind "  "; ind=ind gy "↳ " rst }
      print brank[j], m, path, n, (ind bdisp[j])
    }
  }
')

# collapse state (milestone names, one per line) + per-milestone counts
COLLAPSED=""; [ -f "$C/global/collapsed" ] && COLLAPSED=$(cat "$C/global/collapsed")
is_collapsed(){ printf '%s\n' "$COLLAPSED" | grep -qxF "$1"; }
counts=$(printf '%s' "$buf" | awk -F'\t' 'NF>=2{c[$2]++} END{for(m in c) print m"\t"c[m]}')
count_of(){ printf '%s\n' "$counts" | awk -F'\t' -v m="$1" '$1==m{print $2; exit}'; }

# emit: field1=num(empty for header)·field2=display·field3=milestone(for collapse toggle)
# buf rows are: rank<TAB>milestone<TAB>pathkey<TAB>num<TAB>display. Sort groups by
# milestone rank, then by the materialized PATH key — a lexical sort of which is a
# pre-order DFS: top-level rows stay in priority-tier→number order (issue #235
# "reorder") and a sub-issue lands directly under its parent (issue #335). The
# path already encodes num, so -k4,4n is just a stable final tiebreak.
last=''
printf '%s' "$buf" | sort -t'	' -k1,1n -k3,3 -k4,4n | while IFS='	' read -r _ ms _key num row; do
  [ -z "$num" ] && continue
  if [ "$MODE" != unplanned ] && [ "$ms" != "$last" ]; then
    if is_collapsed "$ms"; then ind='▸'; else ind='▾'; fi
    printf '%s%s%s %s (%s)%s%s%s\n' "$US" "$(c "$IN")" "$ind" "$ms" "$(count_of "$ms")" "$R" "$US" "$ms"
    last="$ms"
  fi
  { [ "$MODE" != unplanned ] && is_collapsed "$ms"; } && continue
  printf '%s%s%s%s%s\n' "$num" "$US" "$row" "$US" "$ms"
done
