#!/bin/bash
# tmux-dashboard-rows.sh — emit rows for the interactive dash (fzf), GROUPED by
# status with aligned (display-width-correct) columns.
# Line format:  <sess:idx>US<window-id>US<colored display>
#   field1 = jump target · field2 = stable summary key (window-id) · field3 = display
# Data: @claude_state (no LLM), everything slow from collector caches.
# (DASH_COMPACT mode retired with the 2026-07 fork-free rewrite.)
#
# HOT PATH (2026-07-07): this runs on every dash repaint (4×/s) — the loop is
# exec-fork-free (bash builtins only: read/expansion instead of cat/cut/sed/awk).
# Execs per render: tmux + sort + perl(sub-second clock) + one fleet_cache slug
# lookup ≈ 4. ~30ms total.
set -uo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} must count chars, not bytes
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"   # fleet_cache: route prmap through THIS fleet's slug'd cache
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
G="$C/global"                       # machine-wide caches (git_/ctx_/summary_) — issue #181

# live⇄landed view toggle (dash ⌃t writes $C/dash_view_<session>, per-fleet). In
# LANDED mode this producer hands off to the history ledger's row emitter, so
# finished (merged + cleaned-up) sessions are one keystroke away with the same row
# ergonomics (#130). Keyed by FLEET_SESSION so one fleet's toggle can't flip
# another's dash (they share $C); FLEET_SESSION is exported by tmux-dashboard.sh.
if [ "$(cat "$G/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  exec bash "$BIN/fleet-history.sh" rows
fi

E=$'\033['
CY="${E}38;2;125;207;255m"; RD="${E}38;2;247;118;142m"; GN="${E}38;2;158;206;106m"
IN="${E}38;2;187;154;247m"; GY="${E}38;2;86;95;137m";  TX="${E}38;2;169;177;214m"
AM="${E}38;2;224;175;104m"   # amber — green PR that isn't land-ready (behind/blocked)
R="${E}0m"; US=$'\x1f'
WFMT="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{pane_current_path}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{window_id}${US}#{@issue}${US}#{@origin}${US}#{@worktree}"

# pad/truncate a plaintext string to N DISPLAY chars (locale-aware ${#}) → $fld_out
fld() { local w="$1" s="$2" n=${#2}
  if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
  else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }

# working glyph rotates: quarter-second frames from perl HiRes (macOS date has
# no %N and /bin/bash 3.2 no EPOCHREALTIME) — one frame per 4Hz repaint. The same
# tick doubles as the fork-free NOW (epoch seconds) for the activity column:
# perl's time()*4 ÷ 4 == floor(now), so no extra `date` fork on the hot path; the
# no-perl fallback reads whole seconds from `date` (one fork, as before).
SPINF='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
TICK=$(perl -MTime::HiRes=time -e 'printf "%d", time()*4' 2>/dev/null)
if [ -n "$TICK" ]; then NOW=$(( TICK / 4 )); else TICK=$(date +%s); NOW=$TICK; fi
FRAME=${SPINF:$(( TICK % 10 )):1}

# state → color/glyph/rank (set vars; no subshells)
state_v() { case "$1" in
  needs)   gc=$RD; gl='!';      rk=0;;
  done)    gc=$GN; gl='✓';      rk=1;;
  working) gc=$CY; gl=$FRAME;   rk=2;;
  looping) gc=$IN; gl='↻';      rk=3;;
  *)       gc=$GY; gl='·';      rk=4;;
esac; }

# window → its OWN ledger key (issue #503): `issue-<N>` from @issue, else the
# `scratch-<N>` slug — read from @worktree FIRST and the pane cwd only as a
# fallback (issue #529). @worktree is stamped once at spawn and never moves; the
# cwd does, and a scratch whose Claude `cd`s into a subdir yields basename `docs`,
# no key, and so used to render as an un-addressable row with a blank id cell.
# That is the same @worktree-first rule fleet_origin_key already follows, so the
# two provenance readers no longer disagree about the same window.
# Same strict digits-only shape as fleet_scratch_key (both the bare `scratch-<N>`
# and the `<repo>-scratch-<N>` dir form) — inlined because $(fleet_scratch_key)
# would fork a subshell on the 4Hz hot path.
# Empty = not addressable as a spawn parent. Sets $okey; no subshells.
okey_v() { okey=''
  if [ -n "$1" ]; then okey="issue-$1"; return; fi
  local cand bn sn
  for cand in "$2" "$3"; do
    bn=${cand##*/}
    case "$bn" in
      scratch-*)   sn=${bn#scratch-} ;;
      *-scratch-*) sn=${bn##*-scratch-} ;;
      *)           continue ;;
    esac
    case "$sn" in ''|*[!0-9]*) continue;; *) okey="scratch-$sn"; return;; esac
  done
}

# model → context window (FLEET_CTX_WINDOW; haiku 200k). The model short name was
# dropped from the row in #36, so only cwin is computed now.
model_v() {
  case "$1" in *haiku*) cwin=200000;; *) cwin=${FLEET_CTX_WINDOW:-200000};; esac; }

# This fleet's PR map — slug-resolved for THIS dash's own session (issue #180:
# all fleets equal, no privileged "primary" flat mirror). The row loop below
# strictly filters to FLEET_SESSION, so one slug'd cache is exactly this fleet's
# PR status and can never be another fleet's; fleet_cache's flat name is only a
# cold-start fallback before the slug'd .ts marker lands. Loaded once (not
# per-row) so the hot loop stays fork-free.
PRMAP=""; _pf=$(fleet_cache prmap "${FLEET_SESSION:-}"); [ -s "$_pf" ] && PRMAP=$(<"$_pf")
PRMAPN=$'\n'"$PRMAP"

# List width, to right-align the PR/ctx block to the edge and give the summary
# the full remaining span. Prefer fzf's own viewport width — FZF_COLUMNS is
# exported to reload/transform child procs (fzf ≥0.53) and is the TRUE list
# width. `tput cols </dev/tty` is unreliable here (it reads the client tty, not
# the pane), so it's only a fallback for the very first pre-fzf render before
# FZF_COLUMNS exists; 120 as a last resort. Keep a 2-col gutter + 2-col right
# margin so fzf never clips the ctx% digits. Layout column widths:
#   LEFTW  = glyph1+sp + issue5+sp + window22+sp = 31
#   RIGHTW = act8+sp + PR7+sp + ctx4 = 21   (act = last-activity, issue #228)
# NB: LEFTW/ACTW/RIGHTW MUST stay in step with fleet-history.sh cmd_rows so the
# live list and the landed history list render the SAME aligned columns (#228).
COLS=${FZF_COLUMNS:-}
case "$COLS" in ''|*[!0-9]*) COLS=$( { tput cols </dev/tty; } 2>/dev/null );; esac
case "$COLS" in ''|*[!0-9]*) COLS=120;; esac
LEFTW=31; ACTW=8; RIGHTW=21; USABLE=$(( COLS - 4 ))
[ "$USABLE" -lt $(( LEFTW + RIGHTW + 1 )) ] && USABLE=$(( LEFTW + RIGHTW + 1 ))

# One tmux read, iterated twice (issue #503): pass A below builds the parent
# lookup table the grouping needs (a child can appear BEFORE its parent in window
# order); pass B renders. Herestring iteration, no extra forks.
WLIST=$(tmux list-windows -a -F "$WFMT")

# pass A — KEYTAB: one `<key>\t<rk>\t<idx>\t<origin>` line per addressable window,
# the parent-resolution table for the spawn-provenance grouping (issue #503).
KEYTAB=''
while IFS=$US read -r sess idx name path state _ _ iss origin wt; do
  [ -z "$name" ] && continue
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac
  okey_v "$iss" "$wt" "$path"
  [ -z "$okey" ] && continue
  state_v "$state"
  KEYTAB+="$okey"$'\t'"$rk"$'\t'"$idx"$'\t'"$origin"$'\n'
done <<< "$WLIST"

buf=""
while IFS=$US read -r sess idx name path state state_ts wid iss origin wt; do
  [ -z "$name" ] && continue
  # strict per-fleet: only windows from the viewing dash's own tmux session.
  # FLEET_SESSION exported by tmux-dashboard.sh; unset ⇒ show all (single-fleet).
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac   # panels, not Claude sessions
  # collision-free cache key — keep byte-identical to cache_key() in tmux-dash-collect.sh
  key=${path//_/_u}; key=${key//\//_s}; key=${key// /_w}

  branch='-'
  [ -f "$G/git_$key" ] && { IFS=$'\t' read -r branch _ < "$G/git_$key" || :; }

  state_v "$state"
  nmcol=$TX; { [ "$state" = idle ] || [ -z "$state" ]; } && nmcol=$GY

  # PR cell: look up the branch in prmap. The cache branch may carry +ahead/-behind
  # decorations; try EXACT first (real branch names can end in -digits, e.g.
  # issue-231 — the old sed-strip wrongly ate that), then decoration-stripped.
  ptxt='—'; pcol=$GY
  if [ "$branch" != '-' ] && [ -n "$branch" ]; then
    b1=$branch
    b2=$b1; case "$b2" in *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9]|*-[0-9][0-9][0-9][0-9]) b2=${b2%-*};; esac
    b3=$b2; case "$b3" in *+[0-9]|*+[0-9][0-9]|*+[0-9][0-9][0-9]|*+[0-9][0-9][0-9][0-9]) b3=${b3%+*};; esac
    for bare in "$b1" "$b3" "$b2"; do
      tail=${PRMAPN#*$'\n'"$bare"$'\t'}
      if [ "$tail" != "$PRMAPN" ]; then
        line=${tail%%$'\n'*}
        # line = #num\tstate\tci\tready. Parse each; ready may be absent on a
        # stale 4-field cache (mid-upgrade) — tab-guard so it degrades to ''.
        pnum=${line%%$'\t'*}   # "#num" — field 1, surfaced into the OPEN-PR cell
        rest=${line#*$'\t'}; st=${rest%%$'\t'*}; after=${rest#*$'\t'}
        ci=${after%%$'\t'*}
        case "$after" in *$'\t'*) ready=${after#*$'\t'};; *) ready='';; esac
        case "$st" in
          MERGED) pcol=$IN; ptxt="merged";;
          CLOSED) pcol=$GY; ptxt="closed";;
          *) case "$ci" in
               ✓) pcol=$GN
                  # green: decorate by land-readiness (single-cell glyphs only —
                  # the metadata column is width-budgeted; no 2-cell emoji).
                  case "$ready" in
                    behind)   ptxt='✓↑'; pcol=$AM;;   # behind base → update-branch
                    conflict) ptxt='✓!'; pcol=$RD;;   # conflicting → rebase
                    blocked)  ptxt='✓·'; pcol=$AM;;   # mergeable+green but blocked
                    *)        ptxt='✓';;              # land-ready (or neutral)
                  esac;;
               ✗) pcol=$RD; ptxt="$ci";;
               …) pcol=$TX; ptxt="$ci";;
               *) pcol=$GY; ptxt="$ci";;
             esac
             # OPEN PR → prefix the number next to the glyph (e.g. #75✓, #75✓↑).
             # #<4-digit> + 2-cell readiness glyph = 7 = the fld 7 ceiling. All
             # these glyphs are single display cells so ${#}==width; prefix ONLY
             # when it fits, else keep the glyph (the land signal) glyph-only —
             # never let fld's right-clip eat the glyph on a huge PR number.
             [ $(( ${#pnum} + ${#ptxt} )) -le 7 ] && ptxt="$pnum$ptxt";;
        esac
        break
      fi
    done
  fi

  # model + ctx%
  cmodel=''; ctok=''
  [ -f "$G/ctx_$key" ] && { IFS=$'\t' read -r cmodel ctok < "$G/ctx_$key" || :; }
  model_v "$cmodel"
  pct='·'; pcolr=$GY
  case "$ctok" in
    ''|*[!0-9]*) : ;;
    *) pct=$(( ctok * 100 / cwin ))
       if   [ "$pct" -ge 80 ]; then pcolr=$RD
       elif [ "$pct" -ge 55 ]; then pcolr=$TX; fi
       pct="${pct}%";;
  esac

  # one-line summary (first line of the cache file). Keyed by <session>_<id>:
  # per-fleet tmux servers renumber windows from @1, so the bare id would read
  # another fleet's row (issue #208) — the session prefix pins it to THIS fleet.
  # Inlined (not fleet_summary_key) to keep this hot loop fork-free; MUST stay
  # byte-identical to that helper in fleet-lib.sh.
  smk=${sess//[^A-Za-z0-9._-]/_}_${wid//[^0-9]/}; smry=''
  [ -f "$G/summary_$smk" ] && { read -r smry < "$G/summary_$smk" || :; }
  smry=${smry:0:120}

  # last-activity (issue #228): friendly "time since" from @claude_state_ts (epoch
  # re-stamped by the hooks/spinner/classifier on every state change). fleet_reltime
  # is pure-bash (no fork) so it stays on the hot path; NOW was computed once above.
  # No timestamp yet (a window that never took a turn) → a muted dot.
  fleet_reltime "$state_ts" "$NOW"; act=${reltime_out:-}
  acol=$GY; [ -z "$act" ] && act='·'

  # --- the id cell (issue #529) ----------------------------------------------
  # `#<N>` in GREEN for an issue-bound worker; `~<N>` in INDIGO for a scratch —
  # the same `~` grammar key_label/`↳~12`//fleet-history list already speak, and
  # the same indigo the ↳ scratch-provenance tag is drawn in, so the column reads
  # green=issue / indigo=scratch. Colour is the half #502 was missing: it put a
  # GREEN `~<N>` here, found it "indistinguishable from `#<N>` at a glance", and
  # blanked the cell — which cost the scratch its only stable on-dash id, since
  # the window column holds a merely cosmetic name (`--name`, #225, or ⌃n rename
  # both erase the `scratch-<N>` default). Widths are unchanged: `~<N>` and
  # `#<N>` are the same width, still inside the 5-col cell.
  okey_v "$iss" "$wt" "$path"
  issd=''; icol=$GN
  case "$okey" in
    issue-*)   issd="#${okey#issue-}" ;;
    scratch-*) issd="~${okey#scratch-}"; icol=$IN ;;
  esac
  # --- spawn provenance (issue #503) -----------------------------------------
  # ↳ tag: rendered before the summary for every non-hub origin (`↳#483` for a
  # worker parent, `↳~12` for a scratch one — key_label's grammar — the literal
  # word for autofill/bridge). └ indent: only when the parent is a WINDOW kind
  # (issue-*/scratch-*), i.e. the row is a child in the grouped list.
  tagd=''; dname=$name
  case "$origin" in
    '') : ;;
    issue-*)   tagd="↳#${origin#issue-}";   dname="└ $name" ;;
    scratch-*) tagd="↳~${origin#scratch-}"; dname="└ $name" ;;
    *)         tagd="↳$origin" ;;
  esac
  # group sort key: a root keeps its own (rank, idx); a child resolves its parent
  # CHAIN (≤4 hops, grandchildren group under the ultimate live root) and inherits
  # that root's (rank, idx) with depth=1 so it sorts right below it; a chain that
  # breaks (parent window closed) is an ORPHAN → the 9/99999 sentinel sinks the
  # row below every live group, sub-sorted by its own rank/idx.
  grk=$rk; gidx=$idx; depth=0
  case "$origin" in
    issue-*|scratch-*)
      grk=9; gidx=99999; depth=1
      cur=$origin; hops=0
      while [ "$hops" -lt 4 ]; do
        t=$'\n'"$KEYTAB"
        m=${t#*$'\n'"$cur"$'\t'}
        # parent not on this dash at all (closed, or a key from ANOTHER fleet):
        # keep the ↳ tag but drop the └ indent — an orphan sinks below every live
        # group, and indenting it there reads as a child of an unrelated row.
        [ "$m" = "$t" ] && { [ "$hops" -eq 0 ] && dname=$name; break; }
        prow=${m%%$'\n'*}
        prk=${prow%%$'\t'*}; prest=${prow#*$'\t'}
        pidx=${prest%%$'\t'*}; porig=${prest#*$'\t'}
        case "$porig" in
          issue-*|scratch-*) cur=$porig; hops=$((hops+1)) ;;
          *) grk=$prk; gidx=$pidx; break ;;
        esac
      done ;;
  esac
  # full row: glyph1·issue5·window22·summary(flex)·⟨pad⟩·act8·PR7·ctx4
  # window+summary sit right after the issue; act/PR/ctx right-align to the edge,
  # the gap between summary and act flexing so the metadata block stays pinned right.
  fld 5  "$issd"; f_iss=$fld_out
  fld 22 "$dname"; f_name=$fld_out
  fld "$ACTW" "$act"; f_act=$fld_out
  fld 7  "$ptxt"; f_pr=$fld_out
  fld 4  "$pct";  f_pct=$fld_out
  avail=$(( USABLE - LEFTW - RIGHTW - 1 )); [ "$avail" -lt 0 ] && avail=0
  # the ↳ tag borrows its width (+1 space) from the summary's flex span so the
  # right-pinned act/PR/ctx block stays aligned; ↳/#/~ are all single-cell.
  [ -n "$tagd" ] && { avail=$(( avail - ${#tagd} - 1 )); [ "$avail" -lt 0 ] && avail=0; }
  # Clip + measure the summary by DISPLAY width, not code-point count (#63): a CJK
  # or emoji glyph is one ${#} char but two terminal columns, so a char-count clip
  # can be ~2x wide and overrun the flex span into the right-pinned PR/ctx block.
  # The implementation is shared with the /fleet-history rows producer
  # (fleet_clip_display in fleet-lib.sh) — it used to live here only, and the other
  # producer's char-count copy was still overrunning (issue #492). ASCII stays
  # fork-free; only a non-ASCII summary pays one perl/wcwidth fork.
  # (fld() at :24 shares the same ${#}=chars assumption; its inputs — issue/PR/
  #  ctx — are ASCII, and window names are rarely wide, so it's left as-is here.)
  fleet_clip_display "$avail" "$smry"; smry="${clip_out:-}"; dwidth="${clip_w:-0}"
  tagpfx=''
  [ -n "$tagd" ] && { tagpfx="${IN}${tagd}${R} "; dwidth=$(( dwidth + ${#tagd} + 1 )); }
  pad=$(( USABLE - LEFTW - dwidth - RIGHTW )); [ "$pad" -lt 1 ] && pad=1
  printf -v gap '%*s' "$pad" ''
  disp="${gc}${gl}${R} ${icol}${f_iss}${R} ${nmcol}${f_name}${R} ${tagpfx}${TX}${smry}${R}${gap}${acol}${f_act}${R} ${pcol}${f_pr}${R} ${pcolr}${f_pct}${R}"

  buf+="$grk	$gidx	$depth	$rk	$idx	$sess:$idx$US$wid$US$disp"$'\n'
done <<< "$WLIST"

# column header — pinned at top of the list by fzf --header-lines=1. Same
# right-aligned layout as the rows: leading "  " fills the glyph(1)+space slot,
# "summary" flexes, act/PR/ctx pinned right. Underlined muted-grey to read as a rule.
fld 5  "issue";  h_i=$fld_out
fld 22 "window"; h_n=$fld_out
fld "$ACTW" "act"; h_a=$fld_out
fld 7  "PR";     h_p=$fld_out
fld 4  "ctx";    h_c=$fld_out
h_pad=$(( USABLE - LEFTW - 7 - RIGHTW )); [ "$h_pad" -lt 1 ] && h_pad=1   # 7 = len("summary")
printf -v h_gap '%*s' "$h_pad" ''
printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  ${h_i} ${h_n} summary${h_gap}${h_a} ${h_p} ${h_c}${R}"

# emit grouped by spawn provenance (issue #503): roots (hub/autofill/bridge
# spawns) keep the status-rank order they always had; each root's children sort
# directly below it (depth breaks the tie, then the child's own rank/idx);
# orphans — children whose parent window closed — sink below every live group.
printf '%s' "$buf" | sort -t'	' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
| while IFS='	' read -r _ _ _ _ _ line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line"
done
