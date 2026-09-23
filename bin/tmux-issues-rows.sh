#!/bin/bash
# tmux-issues-rows.sh [roadmap|unplanned|all] — emit fzf rows for a backlog panel.
# Renders one FLAT list (issue #377): no milestone group-header rows — each issue
# instead shows its milestone in a fixed-width dim COLUMN. roadmap = only
# milestoned issues; unplanned = only no-milestone; all = both. READ-ONLY: reads
# THIS fleet's cache via fleet_cache (the collector writes $C/issues_<slug>:
# milestone\t#num\tassignee\ttitle; no flat mirror — issue #180).
# Line: <#num>US<colored display>US<milestone>. The FIRST line is always the
# column-title header row (issue #374) — empty field1, dim titles in field2 —
# which the backlog pins at the top via --header-lines=1.
# A fleet hosting 2+ repos (issue #794) lists its CURRENT repo's issues
# (fleet_backlog_repos), or under `all` every hosted repo's — one block per repo,
# each title led by the repo's short tag — and every row gains a 4th field, its
# repo (owner/name), which every backlog action passes on as --repo=. A one-repo
# fleet renders byte-for-byte as before: three fields, the per-session cache.
set -uo pipefail
MODE="${1:-all}"
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
C="${TMPDIR:-/tmp}/.claude-dash"
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
# this fleet's issues cache (slug'd via sessmap; flat fallback). FLEET_SESSION is
# exported by tmux-issues.sh so reload-binds inherit it.
SRC=$(fleet_cache issues "${FLEET_SESSION:-}")
GY='86;95;137'; GN='158;206;106'
P0='247;118;142'; P1='224;175;104'; P2='224;204;122'   # priority tier tags (red/orange/yellow)
c(){ printf '\033[38;2;%sm' "$1"; }; R=$'\033[0m'; US=$'\x1f'
NOMS='· no milestone'

# Column-title header row (issue #374). Emit it as the VERY FIRST output line —
# before every exit path below (loading / no-issues / all-bound) and before the
# milestone-grouped emit loop — so the backlog's `--header-lines=1` (bin/tmux-
# issues.sh) always pins EXACTLY these titles at the TOP, heading the rows, never
# a milestone header or a status line. fzf draws `--header-lines` at the top and
# `--header` (the hint line) at the bottom simultaneously in --layout=reverse-list.
# Same <#num>US<display>US<milestone> shape as a row so --with-nth=2 shows field2:
# empty field1 (never spawns) + the dim, width-aligned titles from
# fleet_backlog_col_header, which uses the SAME FLEET_BL_W_* geometry the rows do
# (fleet-lib.sh) — backlog-header-cols-selftest.sh pins the two in step.
printf '%s%s%s\n' "$US" "$(fleet_backlog_col_header)" "$US"

# The repos this backlog lists (issue #794): none = the one-repo fleet, which keeps
# the per-session SRC above; else the current repo, or every hosted repo under `all`.
BLREPOS=''
[ -n "${FLEET_SESSION:-}" ] && BLREPOS=$(fleet_backlog_repos "$FLEET_SESSION")
BADGE=0; case "$BLREPOS" in *$'\n'*) BADGE=1 ;; esac      # `all` over 2+ repos: tag each title
RB='122;162;247'                                          # repo tag (blue)

# rank milestones: version-sorted order (so "Week 2" < "Week 10"), no-milestone last.
# Byte-safe (issue #382): cut/grep -F/sort here only SPLIT and ORDER bytes — they
# need no UTF-8 collation (a milestone's rank is its position in MS_LIST, not CJK
# collation), so run them under LC_ALL=C, which tolerates an invalid-UTF-8 byte in
# the source instead of aborting with "Illegal byte sequence" (a stray bad byte in
# the monorepo fleet's issue/milestone data crashed the whole panel).
# MS_LIST is per source (render_src below): each repo ranks its own milestones.
mrank(){ case "$1" in "$NOMS") echo 99; return;; esac
  local r; r=$(printf '%s\n' "$MS_LIST" | LC_ALL=C grep -nxF "$1" | LC_ALL=C cut -d: -f1)
  echo "${r:-98}"; }

# active bindings: issue-number → session window name (from @issue window options)
# NB tmux -F emits LITERAL \t → must inject a real tab.
TAB=$'\t'
ACTIVE=''; BOUND=''
if [ -z "$BLREPOS" ]; then
  ACTIVE=$(tmux list-windows -a -F "#{session_name}${TAB}#{@issue}${TAB}#{window_name}" 2>/dev/null \
    | awk -F'\t' -v s="${FLEET_SESSION:-}" '$2!="" && (s=="" || $1==s){print $2"\t"$3}')
else
  # A fleet hosting 2+ repos (issues #790/#794): a row is issue N of ONE repo, so
  # only THAT repo's windows count as bound — repo A's #12 window must not mark repo
  # B's #12 as live. One read of the fleet's `<repo>#N` keys; each block filters it.
  BOUND=$(fleet_bound_windows "$FLEET_SESSION")
fi
active_win(){ printf '%s\n' "$ACTIVE" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

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

# hide-bound state (per-fleet, keyed by session): by default an issue already
# bound to a live worker window is hidden; the ⌃b toggle (dash-toggle-show-bound.sh)
# creates this file to reveal them. Existence = show, absent = hide.
SHOW_BOUND=0
[ -f "$C/global/backlog_show_bound_${FLEET_SESSION:-_}" ] && SHOW_BOUND=1

# render_src <issues-file> <repo|''> <tag|''> — append one source's sorted rows to
# OUT. <repo> empty = the one-repo fleet: three fields, byte-for-byte as before.
# Runs in THIS shell (never $(…)), so hidden_any/loaded/fetched reach the caller.
OUT=''; hidden_any=''; loaded=0; fetched=0; MS_LIST=''; PRIOS=''; PARENTS=''
render_src() {
  local src="$1" repo="$2" tag="$3" buf ms num title r n awin tier ptag ms_disp mscol row ttl
  [ -e "$src" ] && fetched=1
  [ -s "$src" ] || return 0
  loaded=1
  MS_LIST=$(LC_ALL=C cut -f1 "$src" | LC_ALL=C grep -vxF "$NOMS" | LC_ALL=C sort -Vu)
  [ -n "$repo" ] && ACTIVE=$(printf '%s\n' "$BOUND" \
    | awk -F'\t' -v p="$repo#" 'index($1, p)==1 { print substr($1, length(p)+1) "\t" $3 }')

  # priority per issue: read the collector's labels cache (num<TAB>comma-labels — the
  # SAME fetch the backlog uses, no extra gh call) and map the priority:p{0,1,2} label
  # to a tier 0/1/2 (3 = unprioritised). Drives both the row tag and the in-milestone
  # sort below, and the whole file degrades to "no tags, number order" if it's absent.
  PRIOS=$(cat "$(fleet_backlog_cache labels "${FLEET_SESSION:-}" "$repo")" 2>/dev/null)

  # parent→child links (issue #335): the collector's per-fleet `parents` cache
  # (child<TAB>parent, from a small GraphQL sub-issues pass — bin/tmux-dash-collect.sh)
  # lets us NEST a sub-issue under its parent row (indented) in the backlog — the
  # visual "this may overlap live parent work" cue. The nesting is cosmetic only:
  # pre-spawn dedup (bin/dash-issue-session.sh) stays the single collision authority,
  # and a child keeps its own field1 issue number so Enter still spawns it. Absent/
  # cold cache ⇒ empty map ⇒ the backlog renders FLAT (pre-#335 behaviour). Each
  # repo reads its OWN map, so a parent link never crosses repos.
  PARENTS=$(cat "$(fleet_backlog_cache parents "${FLEET_SESSION:-}" "$repo")" 2>/dev/null)

  buf=""
  while IFS=$'\t' read -r ms num _ title; do
    [ -z "$num" ] && continue
    r=$(mrank "$ms")
    case "$MODE" in roadmap) [ "$r" -ge 99 ] && continue;; unplanned) [ "$r" -lt 99 ] && continue;; esac
    n=${num#\#}; awin=$(active_win "$n")
    # Hide rows bound to a live worker unless the toggle is on. Skipping here (not
    # at emit time) keeps the milestone counts below in step with the visible rows.
    if [ -n "$awin" ] && [ "$SHOW_BOUND" = 0 ]; then hidden_any=1; continue; fi
    tier=$(prio_tier "$n"); ptag=$(prio_tag "$tier")
    # Milestone column (issue #377): a fixed-width dim column BETWEEN the priority
    # tag and the title so the flat list still shows each issue's milestone (grouping
    # dropped). Truncated+padded to $FLEET_BL_W_MS *display cells* via
    # fleet_pad_display — NOT `printf %-N.Ns`, which counts BYTES and so mis-sizes a
    # CJK milestone (3 bytes but 2 cells/glyph), drifting every following column off
    # the header on repos with Chinese milestone names (issue #432). A no-milestone
    # issue shows a lone '·'; the cell-aware pad handles its 1-col/2-byte width with
    # no special budget. Prebuilt with its own color+reset so it splices into the row
    # as one %s ahead of the title.
    if [ "$ms" = "$NOMS" ]; then ms_disp='·'; else ms_disp="$ms"; fi
    mscol=$(printf '%s%s%s' "$(c "$GY")" "$(fleet_pad_display "$ms_disp" "$FLEET_BL_W_MS")" "$R")
    # Fixed-width columns so the TITLE starts at the same screen column on every row
    # (widths are the shared FLEET_BL_W_* geometry in fleet-lib.sh, which the backlog
    # header aligns to — issue #371): num padded to $FLEET_BL_W_NUM, a 2-col priority
    # tag ($FLEET_BL_W_PRI), TWO gap cols, the milestone column, then the title. The
    # 2-col gap after the priority tag (vs 1 elsewhere) lets the 3-char `pri` HEADER
    # label clear the `milestone` label — the fleet-lib.sh header math uses the same
    # +2 so header and rows stay pinned. The owner column (▶window / ◦assignee / ⇡pr)
    # was dropped in issue #389 — active and idle rows now render identically, so
    # $awin is resolved above only to gate the hide-bound filter, never rendered.
    # Under `all` (issue #794) the title is led by its repo's short tag, so two
    # repos' #12 read apart; every column before it is untouched.
    ttl="$(c "$GY")$title"
    [ -n "$tag" ] && ttl="$(c "$RB")$tag$R $ttl"
    row=$(printf "%s%-${FLEET_BL_W_NUM}s%s %s  %s %s%s" \
      "$(c "$GN")" "$num" "$R" "$ptag" "$mscol" "$ttl" "$R")
    buf+="$r	$ms	$tier	$n	$row"$'\n'
  done < "$src"
  [ -n "$buf" ] || return 0

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

  # emit ONE flat list (issue #377): field1=num · field2=display · field3=milestone,
  # and field4=repo in a 2+ repo fleet (issue #794 — what every backlog action
  # passes on as --repo=). Milestone grouping is gone — no ' ▾ <name> (count) '
  # group-header rows and no collapse; every issue instead carries its milestone in
  # the dim column built above. buf rows are: rank<TAB>milestone<TAB>pathkey<TAB>
  # num<TAB>display. Sort by milestone rank, then by the materialized PATH key — a
  # lexical sort of which is a pre-order DFS: top-level rows stay in priority-tier→
  # number order (issue #235 "reorder") and a sub-issue lands directly under its
  # same-milestone parent (issue #335). The path already encodes num, so -k4,4n is
  # just a stable final tiebreak. field3 of the OUTPUT stays the milestone
  # (metadata; --with-nth=2 hides it). Under `all` each repo is its own sorted block,
  # in fleet_repos order.
  # LC_ALL=C on this final sort (issue #382): its keys (rank, path, num) are all ASCII
  # digits, so C-locale byte order == the intended numeric/lexical order, and C-locale
  # tolerates any invalid-UTF-8 byte elsewhere in the row (a colored title/milestone)
  # instead of aborting the sort with "Illegal byte sequence".
  OUT+=$(printf '%s' "$buf" | LC_ALL=C sort -t'	' -k1,1n -k3,3 -k4,4n | while IFS='	' read -r _ ms _key num row; do
    [ -z "$num" ] && continue
    if [ -n "$repo" ]; then printf '%s%s%s%s%s%s%s\n' "$num" "$US" "$row" "$US" "$ms" "$US" "$repo"
    else printf '%s%s%s%s%s\n' "$num" "$US" "$row" "$US" "$ms"; fi
  done)$'\n'
}

if [ -z "$BLREPOS" ]; then
  render_src "$SRC" '' ''
else
  while IFS= read -r _rp; do
    [ -n "$_rp" ] || continue
    _tag=''; [ "$BADGE" = 1 ] && _tag=$(fleet_repo_short_of "$FLEET_SESSION" "$_rp")
    render_src "$(fleet_backlog_cache issues "$FLEET_SESSION" "$_rp")" "$_rp" "$_tag"
  done <<REPOS
$BLREPOS
REPOS
fi

if [ "$loaded" = 0 ]; then   # empty-but-fetched = 0 open issues; absent = not loaded yet
  [ "$fetched" = 1 ] && m='(no open issues)' || m='(loading issues…)'
  printf '%s%s%s%s\n' "$US" "$(c "$GY")" "$m" "$R"; exit 0
fi

# All open issues (in this MODE) are bound + hidden → a friendly line instead of
# a bare blank/"(no open issues)", so you know why the panel is empty.
if [ -z "$OUT" ] && [ "$SHOW_BOUND" = 0 ] && [ -n "$hidden_any" ]; then
  printf '%s%s%s%s\n' "$US" "$(c "$GY")" '(all open issues have a live worker — ⌃b to show)' "$R"
  exit 0
fi
printf '%s' "$OUT"
