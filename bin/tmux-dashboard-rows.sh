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
# Execs per render: tmux + sort + perl(sub-second clock) ≈ 3. ~30ms total.
set -uo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} must count chars, not bytes
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
E=$'\033['
CY="${E}38;2;125;207;255m"; RD="${E}38;2;247;118;142m"; GN="${E}38;2;158;206;106m"
IN="${E}38;2;187;154;247m"; GY="${E}38;2;86;95;137m";  TX="${E}38;2;169;177;214m"
R="${E}0m"; US=$'\x1f'
WFMT="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{pane_current_path}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{window_id}${US}#{@issue}"

# pad/truncate a plaintext string to N DISPLAY chars (locale-aware ${#}) → $fld_out
fld() { local w="$1" s="$2" n=${#2}
  if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
  else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }

# working glyph rotates: quarter-second frames from perl HiRes (macOS date has
# no %N and /bin/bash 3.2 no EPOCHREALTIME) — one frame per 4Hz repaint.
SPINF='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
TICK=$(perl -MTime::HiRes=time -e 'printf "%d", time()*4' 2>/dev/null || date +%s)
FRAME=${SPINF:$(( TICK % 10 )):1}

# state → color/glyph/rank (set vars; no subshells)
state_v() { case "$1" in
  needs)   gc=$RD; gl='!';      rk=0;;
  done)    gc=$GN; gl='✓';      rk=1;;
  working) gc=$CY; gl=$FRAME;   rk=2;;
  looping) gc=$IN; gl='↻';      rk=3;;
  *)       gc=$GY; gl='·';      rk=4;;
esac; }

# model → short name + context window (FLEET_CTX_WINDOW; haiku 200k)
model_v() { case "$1" in
  *opus*) msht='opus';; *sonnet*) msht='sonnet';; *fable*) msht='fable';;
  *haiku*) msht='haiku';; *mythos*) msht='mythos';; '') msht='';; *) msht='model';; esac
  case "$1" in *haiku*) cwin=200000;; *) cwin=${FLEET_CTX_WINDOW:-200000};; esac; }

PRMAP=""; [ -s "$C/prmap" ] && PRMAP=$(<"$C/prmap")
PRMAPN=$'\n'"$PRMAP"

# multi-fleet: each row matches against ITS fleet's prmap (session→slug via the
# collector's sessmap). Preloaded here into indexed arrays so the hot loop stays
# fork-free; falls back to the flat PRMAP when nothing resolves (single-fleet).
declare -a MS_SESS MS_SLUG PS_SLUG PS_DATA
if [ -s "$C/sessmap" ]; then
  while IFS=$'\t' read -r _s _sl _r; do
    [ -z "$_s" ] && continue
    MS_SESS+=("$_s"); MS_SLUG+=("$_sl")
    case " ${PS_SLUG[*]:-} " in *" $_sl "*) ;; *)
      _d=""; [ -s "$C/prmap_$_sl" ] && _d=$(<"$C/prmap_$_sl")
      PS_SLUG+=("$_sl"); PS_DATA+=("$_d");;
    esac
  done < "$C/sessmap"
fi
# PMN = newline-prefixed prmap for session $1 (fallback: flat PRMAPN)
prmapn_for() {
  local s="$1" i n=${#MS_SESS[@]} sl j m
  PMN="$PRMAPN"
  for ((i=0;i<n;i++)); do
    [ "${MS_SESS[$i]}" = "$s" ] || continue
    sl="${MS_SLUG[$i]}"; m=${#PS_SLUG[@]}
    for ((j=0;j<m;j++)); do
      [ "${PS_SLUG[$j]}" = "$sl" ] && { PMN=$'\n'"${PS_DATA[$j]}"; return; }
    done
    return
  done
}

buf=""
while IFS=$US read -r sess idx name path state _ wid iss; do
  [ -z "$name" ] && continue
  # strict per-fleet: only windows from the viewing dash's own tmux session.
  # FLEET_SESSION exported by tmux-dashboard.sh; unset ⇒ show all (single-fleet).
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac   # panels, not Claude sessions
  # collision-free cache key — keep byte-identical to cache_key() in tmux-dash-collect.sh
  key=${path//_/_u}; key=${key//\//_s}; key=${key// /_w}
  prmapn_for "$sess"   # PMN = this fleet's prmap (flat fallback)

  branch='-'
  [ -f "$C/git_$key" ] && { IFS=$'\t' read -r branch _ < "$C/git_$key" || :; }

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
      tail=${PMN#*$'\n'"$bare"$'\t'}
      if [ "$tail" != "$PMN" ]; then
        line=${tail%%$'\n'*}
        num=${line%%$'\t'*}; rest=${line#*$'\t'}; st=${rest%%$'\t'*}; ci=${rest#*$'\t'}
        case "$st" in
          MERGED) pcol=$IN; ptxt="merged";;
          CLOSED) pcol=$GY; ptxt="closed";;
          *) case "$ci" in ✓) pcol=$GN;; ✗) pcol=$RD;; …) pcol=$TX;; *) pcol=$GY;; esac; ptxt="$ci";;
        esac
        break
      fi
    done
  fi

  # model + ctx%
  cmodel=''; ctok=''
  [ -f "$C/ctx_$key" ] && { IFS=$'\t' read -r cmodel ctok < "$C/ctx_$key" || :; }
  model_v "$cmodel"
  pct='·'; pcolr=$GY
  case "$ctok" in
    ''|*[!0-9]*) : ;;
    *) pct=$(( ctok * 100 / cwin ))
       if   [ "$pct" -ge 80 ]; then pcolr=$RD
       elif [ "$pct" -ge 55 ]; then pcolr=$TX; fi
       pct="${pct}%";;
  esac

  # one-line summary (first line of the cache file)
  idn=${wid//[^0-9]/}; smry=''
  [ -f "$C/summary_$idn" ] && { read -r smry < "$C/summary_$idn" || :; }
  smry=${smry:0:120}

  issd=''; [ -n "$iss" ] && issd="#$iss"
  # full row: glyph1·issue5·PR7·ctx4·name22·summary  (issue# in old idx slot; summary trails name)
  fld 5  "$issd"; f_iss=$fld_out
  fld 22 "$name"; f_name=$fld_out
  fld 7  "$ptxt"; f_pr=$fld_out
  fld 4  "$pct";  f_pct=$fld_out
  disp="${gc}${gl}${R} ${GN}${f_iss}${R} ${pcol}${f_pr}${R} ${pcolr}${f_pct}${R} ${nmcol}${f_name}${R}  ${TX}${smry}${R}"

  buf+="$rk	$idx	$sess:$idx$US$wid$US$disp"$'\n'
done < <(tmux list-windows -a -F "$WFMT")

# column header — pinned at top of the list by fzf --header-lines=1. Widths match
# the fld() calls above; leading "  " fills the glyph(1)+space slot so labels line
# up under their columns. Underlined muted-grey to read as a rule, not a row.
fld 5  "issue";  h_i=$fld_out
fld 7  "PR";     h_p=$fld_out
fld 4  "ctx";    h_c=$fld_out
fld 22 "window"; h_n=$fld_out
printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  ${h_i} ${h_p} ${h_c} ${h_n}  summary${R}"

# emit sorted by status rank (color/order conveys grouping)
printf '%s' "$buf" | sort -t'	' -k1,1n -k2,2n | while IFS='	' read -r rk _ line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line"
done
