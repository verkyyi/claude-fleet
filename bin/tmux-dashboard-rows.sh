#!/bin/bash
# tmux-dashboard-rows.sh — emit rows for the interactive dash (fzf), sorted by
# status urgency with aligned (display-width-correct) columns.
# Line format:  <sess:idx>US<window-id>US<colored display>
#   field1 = jump target · field2 = stable summary key (window-id) · field3 = display
# Data: @claude_state (no LLM); everything slow comes from caches written by
# tmux-dash-collect.sh — this producer is READ-ONLY so the dash renders instantly.
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} must count chars, not bytes
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
now() { date +%s; }
CY='125;207;255'; RD='247;118;142'; GN='158;206;106'; IN='187;154;247'; GY='86;95;137'; TX='169;177;214'
c() { printf '\033[38;2;%sm' "$1"; }
R=$'\033[0m'; US=$'\x1f'
WFMT="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{pane_current_path}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{window_id}${US}#{@issue}"

# pad/truncate a plaintext string to N DISPLAY chars (locale-aware ${#})
fld() { local w="$1" s="$2" n=${#2}
  if [ "$n" -gt "$w" ]; then printf '%s' "${s:0:$w}"; else printf "%s%*s" "$s" $((w-n)) ''; fi; }

# READ-ONLY: the collector (tmux-dash-collect.sh, launchd) writes these caches.
gh_map()   { cat "$C/prmap" 2>/dev/null; }
git_info() { cat "$C/git_$(printf '%s' "$1" | tr '/ ' '__')" 2>/dev/null || printf '%s\t' '-'; }
age() { local t="$1"; case "$t" in ''|*[!0-9]*) printf '·'; return;; esac
  local s=$(( $(now) - t ))
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm' $(( s/60 ))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $(( s/3600 ))
  else printf '%dd' $(( s/86400 )); fi; }
gcolor() { case "$1" in needs) printf '%s' "$RD";; working) printf '%s' "$CY";;
  looping) printf '%s' "$IN";; done) printf '%s' "$GN";; *) printf '%s' "$GY";; esac; }
gchar()  { case "$1" in needs) printf '!';; working) printf '⠿';;
  looping) printf '↻';; done) printf '✓';; *) printf '·';; esac; }
rank()   { case "$1" in needs) echo 0;; done) echo 1;; working) echo 2;; looping) echo 3;; *) echo 4;; esac; }
# plaintext PR cell + its color, via cached map;  echoes "txt<TAB>color"
prcell() {
  local branch="$1" bare hit num st ci col txt
  txt='—'; col="$GY"
  if [ "$branch" != '-' ]; then
    # strip ONLY the trailing +ahead/-behind suffix — branch names contain hyphens
    bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
    hit=$(printf '%s\n' "$PRMAP" | awk -F'\t' -v x="$bare" '$1==x{print;exit}')
    if [ -n "$hit" ]; then
      num=$(echo "$hit"|cut -f2); st=$(echo "$hit"|cut -f3); ci=$(echo "$hit"|cut -f4)
      case "$st" in
        MERGED) col="$IN"; txt="$num merged";;
        CLOSED) col="$GY"; txt="$num closed";;
        *) case "$ci" in ✓) col="$GN";; ✗) col="$RD";; …) col="$TX";; *) col="$GY";; esac; txt="$num $ci";;
      esac
    fi
  fi
  printf '%s\t%s' "$txt" "$col"
}
ctx_read()   { cat "$C/ctx_$(printf '%s' "$1" | tr '/ ' '__')" 2>/dev/null; }
sum_read()   { head -1 "$C/summary_${1//[^0-9]/}" 2>/dev/null | cut -c1-120; }
modelshort() { case "$1" in *opus*) printf 'opus';; *sonnet*) printf 'sonnet';;
  *fable*) printf 'fable';; *haiku*) printf 'haiku';; *mythos*) printf 'mythos';; '') printf '';; *) printf 'model';; esac; }
# Context window per model — adjust to your plan (1M-context models vs 200k).
ctxwin()     { case "$1" in *haiku*) printf 200000;; *) printf "${FLEET_CTX_WINDOW:-200000}";; esac; }
ctxpct()     { local n="$1" w="$2"; case "$n" in ''|*[!0-9]*) printf '·'; return;; esac; printf '%d%%' $(( n*100/w )); }
ctxcol()     { local p="$1"; case "$p" in ''|*[!0-9]*) printf '%s' "$GY"; return;; esac
  if   [ "$p" -ge 80 ]; then printf '%s' "$RD"
  elif [ "$p" -ge 55 ]; then printf '%s' "$TX"
  else printf '%s' "$GY"; fi; }

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

PRMAP=$(gh_map)
buf=""
while IFS=$US read -r sess idx name path state ts wid iss; do
  [ -z "$name" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac   # panels, not Claude sessions
  gi=$(git_info "$path"); branch=$(echo "$gi"|cut -f1); dirty=$(echo "$gi"|cut -f2)
  gc=$(gcolor "$state"); gl=$(gchar "$state")
  nmcol="$TX"; { [ "$state" = idle ] || [ -z "$state" ]; } && nmcol="$GY"
  bd="${branch}${dirty:+ $dirty}"
  pc=$(prcell "$branch"); ptxt=$(echo "$pc"|cut -f1); pcol=$(echo "$pc"|cut -f2)
  cinfo=$(ctx_read "$path"); cmodel=$(printf '%s' "$cinfo" | cut -f1); ctok=$(printf '%s' "$cinfo" | cut -f2)
  msht=$(modelshort "$cmodel"); pct=$(ctxpct "$ctok" "$(ctxwin "$cmodel")"); pcolr=$(ctxcol "${pct%\%}")
  smry=$(sum_read "$wid")
  if [ -n "${DASH_COMPACT:-}" ]; then
    # narrow: glyph1·idx3·name22·pr12·age4·model6·ctx%
    disp=$(printf '%s%s%s %s%s%s %s%s%s %s%s%s %s%s%s %s%s%s %s%s%s' \
      "$(c "$gc")" "$gl" "$R" "$(c "$GY")" "$(fld 3 "$idx")" "$R" \
      "$(c "$nmcol")" "$(fld 22 "$name")" "$R" \
      "$(c "$pcol")" "$(fld 12 "$ptxt")" "$R" \
      "$(c "$GY")" "$(fld 4 "$(age "$ts")")" "$R" \
      "$(c "$GY")" "$(fld 6 "$msht")" "$R" \
      "$(c "$pcolr")" "$(fld 4 "$pct")" "$R")
  else
    # full: glyph1·idx3·name22·issue6·model6·ctx4·summary(one line)
    issd=$([ -n "$iss" ] && printf '#%s' "$iss" || printf '')
    disp=$(printf '%s%s%s %s%s%s %s%s%s %s%s%s %s%s%s %s%s%s  %s%s%s' \
      "$(c "$gc")" "$gl" "$R" "$(c "$GY")" "$(fld 3 "$idx")" "$R" \
      "$(c "$nmcol")" "$(fld 22 "$name")" "$R" \
      "$(c "$GN")" "$(fld 6 "$issd")" "$R" \
      "$(c "$GY")" "$(fld 6 "$msht")" "$R" \
      "$(c "$pcolr")" "$(fld 4 "$pct")" "$R" \
      "$(c "$TX")" "$smry" "$R")
  fi
  # sort-wrapper: rank<TAB>idx<TAB>emitline   (emitline uses US; no tab inside)
  buf+="$(rank "$state")	$idx	$sess:$idx$US$wid$US$disp"$'\n'
done < <(tmux list-windows -a -F "$WFMT")

# (usage/rate-limit shown in fzf's header, not as a list row — see tmux-dashboard.sh)

# emit sorted by status rank (color/order conveys grouping; no header lines)
printf '%s' "$buf" | sort -t'	' -k1,1n -k2,2n | while IFS='	' read -r rk ix line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line"
done
