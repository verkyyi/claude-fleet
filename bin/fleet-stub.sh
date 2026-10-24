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
case "${FLEET_UI_LANG:-}" in en*) EN=1 ;; *) EN=0 ;; esac
# say <zh> <en> → $said (printf -v: no subshell — the first frame forks nothing)
say() { if [ "$EN" = 1 ]; then said=$2; else said=$1; fi; }
buf='' queue=() paste=0 escs=0 t0=$SECONDS st='' said=''
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
  case "$st" in "✗"*) ;; *) printf -v out '%s\033[2m · %ss\033[0m' "$out" "$s" ;; esac
  out="$out"$'\n'
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
      case "$ch" in [[:cntrl:]]) ;; *) buf="$buf$ch" ;; esac
      ;;
  esac
  tick
  draw
done
