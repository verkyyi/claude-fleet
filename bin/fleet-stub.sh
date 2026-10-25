#!/bin/bash
# fleet-stub.sh <dir> <label> — a new session's input line while it starts (T992).
#
# ⌘P's 「新会话」 ↵ opens this window first (bin/fleet_stub.py open, ≤ 0.1 s: one
# tmux new-window, no interpreter), and the road that makes the session — the
# task record, the placement, the worktree, the agent — runs behind it. The
# person types here at once; nothing they type is lost:
#   typing        the line (⌫ · ⌃U / ⌃C clear · a paste keeps its newlines)
#   ↵             the line is queued: the agent gets it, submitted, once it is up
#   esc ×2        closes this window; the session still opens (it is on the list)
# The road says how it goes in <dir>/status (one line; `✗ …` = it failed, and
# the window stays with the words until esc); the road types ESC [ 9 9 9 8 ~
# into this pane to have it re-read now. The handoff (fleet_stub.py handoff,
# from fleet_view.go) types ESC [ 9 9 9 9 ~: in band, so every key the person
# typed before it is taken first — this writes <dir>/q.<n> (the queued lines),
# <dir>/buf (the unsent line) and <dir>/frozen, then ends. (Not a signal: on
# bash 3.2 one landing in a raw-mode `read -t` wedges it for good.)
# <dir>/pid names the road; it gone with no handoff is said as a failure too.
# bash 3.2 (a Mac's /bin/bash) is enough: builtins only on the key path.
dir="${1:?dir}" label="${2:-}"
case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) export LC_ALL=en_US.UTF-8 ;; esac
utf=${LC_ALL:-${LC_CTYPE:-${LANG:-en_US.UTF-8}}}
case "${FLEET_UI_LANG:-}" in en*) EN=1 ;; *) EN=0 ;; esac
# say <zh> <en> → $said (printf -v: no subshell — the first frame forks nothing)
say() { if [ "$EN" = 1 ]; then said=$2; else said=$1; fi; }
buf='' queue=() paste=0 escs=0 t0=$SECONDS st='' said='' prog='' typical=''
cols=${FLEET_STUB_COLS:-80}
case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
trap 'size; draw' WINCH
trap 'exit 0' HUP TERM
size() { local s; s=$(stty size 2>/dev/null) && cols=${s#* }; case "$cols" in ''|*[!0-9]*) cols=80 ;; esac; [ "$cols" -gt 20 ] || cols=80; }
finish() {
  local i=0
  for q in ${queue[@]+"${queue[@]}"}; do printf '%s' "$q" >"$dir/q.$i"; i=$((i + 1)); done
  printf '%s' "$buf" >"$dir/buf"
  : >"$dir/frozen"
  printf '\033[?2004l'
  stty "$saved" 2>/dev/null
  exit 0
}
draw() {
  local w=$((cols - 2)) shown line s=$((SECONDS - t0)) color='2' out
  shown=${buf//$'\n'/⏎}
  [ ${#shown} -gt $((w - 4)) ] && shown="…${shown: -$((w - 5))}"
  printf -v line '%*s' "$w" ''
  line=${line// /─}
  case "$st" in "✗"*) color='31' ;; esac
  say 新会话 'New session'
  printf -v out '\033[H\033[2J\n  \033[1m✻ %s\033[0m  \033[2m%s\033[0m\n\n' "$said" "$label"
  if [ -n "$st" ]; then printf -v out '%s  \033[%sm%s\033[0m' "$out" "$color" "$st"
  else say 启动中 Starting; printf -v out '%s  \033[2m%s\033[0m' "$out" "$said"; fi
  case "$st" in "✗"*) ;; *) printf -v out '%s\033[2m · %ss%s\033[0m' "$out" "$s" "$typical" ;; esac
  out="$out"$'\n'
  case "$st" in "✗"*) ;; *) out="$out$prog" ;; esac
  if [ ${#queue[@]} -gt 0 ]; then
    say "已排队 ${#queue[@]} 条，会话起来就发给它" "${#queue[@]} queued — sent the moment it is up"
    printf -v out '%s  \033[33m%s\033[0m\n' "$out" "$said"
  fi
  case "$st" in
    "✗"*) say '按两下 esc 关掉这个窗口' 'esc twice closes this window' ;;
    *) say '先打字 · ↵ 排队 · 会话起来自动交给它' 'type now · ↵ queues · handed over when it is up' ;;
  esac
  # one write per frame; the cursor parked after the text (save · restore)
  # (no right edge: CJK is two columns wide, a counted edge would wander)
  printf '%s\n %s\n ❯ %s\033[s\n %s\n  \033[2m%s\033[0m\n\033[u' "$out" "$line" "$shown" "$line" "$said"
}
# label <seg> → $said: what a stage of the start is, in words (fleet_timing's segs)
label() {
  case "$1" in
    record) say 记下任务 'Task recorded' ;;        placed) say 选好机器 'Machine chosen' ;;
    checked) say 检查通过 'Checks passed' ;;        worktree) say 建好工作区 'Worktree made' ;;
    window) say 开好窗口 'Window open' ;;           wrap) say 准备启动 'Launcher ready' ;;
    exec) say '启动 agent' 'Agent launched' ;;        filled) say 文件到齐 'Files in place' ;;
    ready) say 'agent 起来了' 'Agent up' ;;         input) say 能打字了 'Ready to type' ;;
    *) said=$1 ;;
  esac
}
# secs <ms> → $said: 1 decimal, builtins only
secs() { local m=${1%.*}; case "$m" in ''|*[!0-9]*) m=0 ;; esac; said="$((m / 1000)).$(((m % 1000) / 100))s"; }
# progress — this start's stages so far (its run in the timing ledger, the ↵ in
# <dir>/t0) against the stages a start here usually goes through (<dir>/expect,
# `seg ms` — the median of recent ones): ✓ done (its time) · ▸ now · ○ to come
# (~its usual time). One awk a second, never before the first frame.
progress() {
  local tf='' rt0='' got seg ms v cur=0 out='' w lbl t nb seen=' '
  [ -f "$dir/timing" ] && IFS= read -r tf <"$dir/timing"
  [ -f "$dir/t0" ] && IFS= read -r rt0 <"$dir/t0"
  [ -n "$tf" ] && [ -f "$tf" ] && [ -n "$rt0" ] || return 0
  got=" $(awk -v t0="$rt0" 'index($0, "\"what\": \"session\"") && match($0, /"ts": [0-9.]+/) {
      ts = substr($0, RSTART + 6, RLENGTH - 6) + 0
      if (ts - t0 < 0.005 && t0 - ts < 0.005 && match($0, /"seg": "[a-z.]+"/)) {
        sg = substr($0, RSTART + 8, RLENGTH - 9)
        if (match($0, /"ms": [0-9.]+/)) printf "%s=%d ", sg, substr($0, RSTART + 6, RLENGTH - 6)
      } }' "$tf" 2>/dev/null) "
  row() {   # <mark> <seg> <ms> <color> <prefix>
    label "$2"; lbl=$said; secs "$3"; t=$said
    # padded by display width: a CJK character is three bytes and two columns
    # (printf pads bytes; a bracket range is the locale's collation, not ASCII)
    w=${#lbl}; LC_ALL=C; nb=${#lbl}; LC_ALL=$utf
    w=$((14 - w - (nb - w) / 2)); [ "$w" -gt 0 ] || w=1
    printf -v w '%s%*s' "$lbl" "$w" ''
    printf -v out '%s    \033[%sm%s %s %s%s\033[0m\n' "$out" "$4" "$1" "$w" "$5" "$t"
  }
  if [ -f "$dir/expect" ]; then
    while read -r seg ms; do
      [ -n "$seg" ] || continue
      case "$seg" in input) typical=$ms ;; esac
      seen="$seen$seg "
      case "$got" in
        *" $seg="*) v=${got#* $seg=}; v=${v%% *}; row ✓ "$seg" "$v" 32 '' ;;
        *) if [ "$cur" = 0 ]; then cur=1; row ▸ "$seg" "$ms" 1 '~'; else row ○ "$seg" "$ms" 2 '~'; fi ;;
      esac
    done <"$dir/expect"
  else
    for v in $got; do
      seg=${v%%=*}
      case "$seg" in shown|switched|total) continue ;; esac
      row ✓ "$seg" "${v#*=}" 32 ''
    done
  fi
  if [ -n "$typical" ]; then
    secs "$typical"; v=${said%%.*}
    if [ "$v" -gt 0 ] 2>/dev/null; then say "（通常 $v 秒左右）" " (usually about $v s)"; typical=$said; else typical=''; fi
  fi
  prog=$out
}
tick() {
  local now='' p=''
  [ -f "$dir/status" ] && IFS= read -r now <"$dir/status"
  if [ -z "$now" ] && [ -f "$dir/pid" ] && [ ! -f "$dir/frozen" ]; then
    IFS= read -r p <"$dir/pid"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
      sleep 1   # the handoff's last word may be on its way
      [ -f "$dir/status" ] && IFS= read -r now <"$dir/status"
      say '启动进程已退出，会话没有开出来' 'the start ended without a session'
      [ -n "$now" ] || now="✗ $said"
    fi
  fi
  [ "$now" = "$st" ] && return 1
  st=$now
  return 0
}
# the frame first (no fork before it), the terminal's modes after
printf '\033[?2004h'
draw
saved=$(stty -g 2>/dev/null)
stty -echo -icanon -ixon min 1 time 0 2>/dev/null
while :; do
  ch=''
  IFS= read -rsn1 -t 1 ch
  rc=$?
  if [ $rc -ne 0 ] && [ -z "$ch" ]; then
    tick
    progress
    draw
    continue
  fi
  case "$ch" in
    $'\033')
      seq=''
      IFS= read -rsn1 -t 1 c2 || c2=''
      if [ "$c2" = '[' ]; then
        while IFS= read -rsn1 -t 1 c3; do seq="$seq$c3"; case "$c3" in [@-~]) break ;; esac; done
        case "$seq" in 200~) paste=1 ;; 201~) paste=0 ;; 9999~) finish ;; 9998~) ;; esac
        escs=0
      elif [ -z "$c2" ] || [ "$c2" = $'\033' ]; then
        escs=$((escs + 1))
        [ "$c2" = $'\033' ] && escs=2
        if [ $escs -ge 2 ]; then printf '\033[?2004l\033[H\033[2J'; stty "$saved" 2>/dev/null; exit 0; fi
      fi
      ;;
    $'\r'|$'\n'|'')
      escs=0
      if [ "$paste" = 1 ]; then buf="$buf"$'\n'
      elif [ -n "$buf" ]; then queue+=("$buf"); buf=''
      fi
      ;;
    $'\177'|$'\b') escs=0; buf=${buf%?} ;;
    $'\025'|$'\003') escs=0; buf='' ;;
    $'\t') escs=0; buf="$buf " ;;
    *)
      escs=0
      # bash 3.2 reads a byte at a time: only an ASCII control is dropped — a
      # [[:cntrl:]] would eat UTF-8 continuation bytes 0x80–0x9F (一 下 登 录 …)
      case "$ch" in [$'\001'-$'\037']) ;; *) buf="$buf$ch" ;; esac
      ;;
  esac
  tick
  draw
done
