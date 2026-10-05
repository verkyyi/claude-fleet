#!/bin/bash
# fleet-shell.sh — the fleet on YOUR OWN computer (issue #1484, EPIC #1479 C5).
#
#   fleet                      ⇒ this, once tmux ≥ 3.2 is installed (bin/fleet)
#   fleet-shell.sh [MACHINE]   start the shell — or re-attach to the one running —
#                              with MACHINE (default: the hub's pick, /v1/fleet/home)
#                              in the right pane
#
# What you get: LEFT, the list the hub gives you — your sessions on every machine,
# one source, one look, no machine tag on a row (fleet-sidebar.py on the hub's
# cache, #1480); BOTTOM, the bar the hub gives you — the machine the right pane is
# on, its account's quota, 入口 ●/○ (tmux-status.sh in hub mode, #1482/#1483);
# RIGHT, a DIRECT ssh into the session you are looking at (fleet-remote-view.sh,
# routed by `fleet connect` — tailnet / gateway port / hub relay last, #1413). A
# row on the SAME machine as the right pane is selected over that pane's own ssh
# connection (`fleet-remote-view.sh select`, no reconnect); a row on ANOTHER machine
# switches to that machine's window. The list and the bar never move.
#
# How it is built — nothing new is rendered here (EPIC #1479 「两套行生成器漂移」):
#   · its OWN tmux server, `-L fleet-shell` (FLEET_SHELL_SESSION), one session of
#     that name — a fleet's socket label IS its session name, so every in-pane
#     script resolves this server the way it resolves a fleet's; never a fleet's
#     server, never its conf;
#   · ONE WINDOW PER MACHINE, each a proxy window (`⇄m4 <name>`, `@remote=<node>:
#     <wid>`) exactly as a fleet opens one on a remote row (#1424/#1475), its pane
#     `fleet-remote-view.sh run --shell`: the far end registers a SHELL client and
#     hides its own list, bar and prefix while only shells are attached (#1485);
#   · the list pane joins whichever window is current (fleet-sidebar.py `jump`),
#     and the conf's hooks put one back after a window closes (`sync`);
#   · the data: `fleet-hub-sessions.sh --loop` in CLIENT MODE
#     (FLEET_HUB_SESSIONS_CLIENT=<session>) — one pseudo-fleet, every row remote,
#     signed by THIS device's certificate (`fleet-sessions@claude-fleet`, so the
#     hub answers only your rows, #1475) — into a cache of the shell's own
#     ($TMPDIR = <cache>/tmp, so $FLEET_C is <cache>/tmp/.claude-dash and a node's
#     own caches are never touched); writes (the row menu's 发消息 / 停 / 继续 /
#     答授权 / 回收) go through fleet-hub-write.sh, the one write client (#1487);
#   · a CONF-FREE mirror of bin/ (<cache>/bin, one symlink per file — the
#     selftest-shadow-root.sh idea): every script resolves `$BIN/../fleet.conf`,
#     and on a machine that is itself a node that file is the OPERATOR's — its
#     FLEET_SIDEBAR_SOURCE would override the shell's. The mirror has no sibling
#     conf, so the shell reads exactly the environment it sets. Once the machine
#     has its one fleet.conf (issue #1623) that sibling is gone (fleet.conf.bak)
#     and the node's settings sit in a section the shell skips: the mirror is
#     kept one version, for a node not yet migrated, then goes with the old paths.
#   · the far end of the right pane runs `fleet connect <machine>` (the routes the
#     hub measured, this device's certificate; `--enter` renews it first), through
#     the `ssh` mode below — unless the machine is THIS computer, where the attach
#     is nested directly (no ssh to yourself; C6's rule hides the node's own list).
#
# Modes used by the pieces (not by a person):
#   ssh <ssh args…>        the proxy pane's ssh program (FLEET_REMOTE_SSH_CMD): a
#                          master connection goes through `fleet connect`; a slave
#                          (`-S`, `-O`) is plain ssh over the master's socket; a
#                          host that is this computer runs the command right here
#   open-url <url>         the fleet-open back channel: a url from the far end
#                          opens on THIS computer (`open` / `xdg-open`)
#   keeper <session>       keeps the refresh loop alive while the server lives
#   wait <session>         the first window when no machine is online: a note,
#                          gone as soon as a row opens a real one
#   env [MACHINE]          print the environment the server would get (debug, tests)
#
# ~/.config/claude-fleet/fleet.conf — the machine's one config file (issue #1623):
# FLEET_HUB_URL in [common], the keys below in [client]; its [node] section is
# never read here. shell.conf is its predecessor, still read for one version:
# ~/.config/claude-fleet/shell.conf (optional, sourced): CCQUOTA_HUB_URL (else
# hub.json's url, what `fleet login` remembered), FLEET_NODE_ALIASES (else derived
# from the hub's route list: `<hostname>=<alias>`), FLEET_SHELL_PREFIX (C-b),
# FLEET_SHELL_SESSION (fleet-shell), FLEET_SHELL_CACHE (~/.cache/claude-fleet/shell),
# FLEET_SHELL_WIDTH (the list's width, 30), FLEET_UI_LANG, and any FLEET_HUB_* /
# FLEET_REMOTE_* knob fleet-hub-sessions.sh and fleet-remote-view.sh read.
#
# The shell is the default way in; bin/fleet falls back to `fleet connect --enter`
# (ssh into the machine's own list) only on one of four (issue #1628): no tmux /
# tmux < 3.2 (plus one line on how to install it), an iPad / iPhone, you asking
# (`fleet connect`, FLEET_SHELL=0) — or THIS script failing before it attaches:
# then it writes why to FLEET_SHELL_FAIL_FILE (fail_start) and exits 1, and the
# fallback's bar carries that reason. Exit: 0 (the attach's); 1 no machine / tmux
# missing when run directly / could not start; 2 no hub URL (as `fleet` says it).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"                      # the bin/ this runs from (the mirror, once started)
SELF="$0"; [ -L "$SELF" ] && SELF=$(readlink "$SELF")   # the real file's dir has conf/ beside it
REAL_BIN="$(cd "$(dirname "$SELF")" && pwd)"

CONF_DIR="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
# The machine's ONE config file (issue #1623): a client that still keeps its
# settings the old way (shell.conf, hub.json's url) folds them in once, here —
# each old file kept as .bak. Two file tests when there is nothing to do.
if [ ! -f "$CONF_DIR/fleet.conf" ] && { [ -f "$CONF_DIR/shell.conf" ] || [ -f "$CONF_DIR/hub.json" ]; } \
   && [ -f "$REAL_BIN/fleet-conf.sh" ]; then
  FLEET_CONF_DIR=$CONF_DIR bash "$REAL_BIN/fleet-conf.sh" migrate --quiet >&2 || :
fi
# shellcheck source=/dev/null
[ -f "$CONF_DIR/shell.conf" ] && . "$CONF_DIR/shell.conf"
# The machine's ONE config file (issue #1623): its [common] + [client] sections —
# the [node] one sits in a FLEET_SHELL guard, and the shell is the shell.
if [ -f "$CONF_DIR/fleet.conf" ]; then
  _fsv=${FLEET_SHELL-}; FLEET_SHELL=1
  # shellcheck source=/dev/null
  . "$CONF_DIR/fleet.conf"
  FLEET_SHELL=$_fsv; unset _fsv
fi
SESS="${FLEET_SHELL_SESSION:-fleet-shell}"
case "$SESS" in ''|*[!A-Za-z0-9._-]*) SESS=fleet-shell ;; esac
CACHE="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}"
PREFIX="${FLEET_SHELL_PREFIX:-C-b}"

note() { printf 'fleet: %s\n' "$*" >&2; }
# fail_start <why> — the shell could not start (nothing attached yet): say so, and
# tell bin/fleet why (FLEET_SHELL_FAIL_FILE), which then takes the direct way with
# that reason on its bar (issue #1628). Exit 1.
fail_start() {
  note "$*"
  [ -n "${FLEET_SHELL_FAIL_FILE:-}" ] && printf '%s' "$*" > "$FLEET_SHELL_FAIL_FILE" 2>/dev/null
  exit 1
}
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
T() { tmux -L "$SESS" "$@"; }

# tmux_ok — tmux ≥ 3.2 on PATH (the key-table binds and `-e` need it).
tmux_ok() {
  local v
  command -v tmux >/dev/null 2>&1 || return 1
  v=$(tmux -V 2>/dev/null); v=${v#tmux }; v=${v%%[!0-9.]*}
  case "$v" in
    ''|*[!0-9.]*) return 1 ;;
    *.*) [ "${v%%.*}" -gt 3 ] || { [ "${v%%.*}" -eq 3 ] && [ "${v#*.}" -ge 2 ]; } ;;
    *)   [ "$v" -ge 4 ] ;;
  esac
}
tmux_hint() {
  note '装上 tmux 就是这套壳（左边列表、底下一栏、右边直连）：macOS `brew install tmux`，Debian/Ubuntu `sudo apt install tmux`；先按今天的方式直连。'
}
# this_machine <host-label> — is that machine THIS computer? (its hostname, or
# FLEET_NODE_ALIASES mapping this hostname to that label)
this_machine() {
  local me a
  me=$(hostname -s 2>/dev/null); me=${me%%.*}
  [ -n "$me" ] || return 1
  [ "$1" = "$me" ] && return 0
  for a in ${FLEET_NODE_ALIASES:-}; do [ "$a" = "$me=$1" ] && return 0; done
  return 1
}

# --- the environment the server gets --------------------------------------------
# shell_env <machine-json> — sets SHELL_ENV (one `NAME=value` per line) and the
# derived globals; the names listed are the ones the pieces read.
shell_env() {
  local node_aliases="${FLEET_NODE_ALIASES:-}" n v
  [ -n "$node_aliases" ] || node_aliases=$(printf '%s' "${1:-}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
out = []
for m in d.get("machines") or []:
    h = (m.get("hostname") or "").split(".", 1)[0]; a = m.get("alias") or ""
    if h and a and h != a and " " not in h + a:
        out.append("%s=%s" % (h, a))
print(" ".join(out))
' 2>/dev/null)
  FLEET_NODE_ALIASES="$node_aliases"
  SHELL_ENV="FLEET_SHELL=1
FLEET_SHELL_SESSION=$SESS
FLEET_HUB_SESSIONS_CLIENT=$SESS
CCQUOTA_FLEET=1
FLEET_SIDEBAR_SOURCE=hub
TMPDIR=$CACHE/tmp
FLEET_REMOTE_SSH_CMD=${FLEET_REMOTE_SSH_CMD:-$SHADOW/fleet-shell.sh ssh}
FLEET_REMOTE_OPENER=${FLEET_REMOTE_OPENER:-$SHADOW/fleet-shell.sh open-url}
FLEET_SIDEBAR_WIDTH=${FLEET_SHELL_WIDTH:-${FLEET_SIDEBAR_WIDTH:-30}}
FLEET_NODE_ALIASES=$FLEET_NODE_ALIASES"
  for n in CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_HUB_SESSIONS_CMD FLEET_HUB_NODES_CMD FLEET_HUB_LIMITS_CMD \
           FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_EVERY FLEET_HUB_SESSIONS_WATCHED_EVERY \
           FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_NODE_TIMEOUT FLEET_HUB_WRITE_CMD FLEET_REMOTE_BIN FLEET_REMOTE_SSH FLEET_REMOTE_VIA_HUB FLEET_CONF_DIR FLEET_CERT \
           CCQUOTA_VIEWER_TOKEN FLEET_UI_LANG FLEET_SIDEBAR_WIDTH_MAX XDG_CONFIG_HOME XDG_CACHE_HOME \
           FLEET_SKIP_GLOBAL_CONF LANG LC_ALL; do
    eval "v=\${$n:-}"
    [ -n "$v" ] && SHELL_ENV="$SHELL_ENV
$n=$v"
  done
  return 0
}
# export_env — SHELL_ENV into this process (the keeper and the first refresh)
export_env() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    export "${line%%=*}=${line#*=}"
  done <<EOF
$SHELL_ENV
EOF
}
# mirror — the conf-free bin/ the shell runs from: one symlink per file of the
# real bin/, refreshed (ln -sf) on every start so a synced install is picked up;
# a link to a file that is gone stays dangling and harmless.
mirror() {
  local f
  SHADOW="$CACHE/bin"
  mkdir -p "$SHADOW" "$CACHE/tmp" || fail_start "写不了 $CACHE"
  for f in "$REAL_BIN"/*; do [ -f "$f" ] && ln -sf "$f" "$SHADOW/${f##*/}"; done
  # the colour table (issue #1534): the bar, the rows and the list read it as
  # $BIN/../conf/fleet-palette.conf — a table, not a config, so the mirror has it
  f="$REAL_BIN/../conf/fleet-palette.conf"
  [ -f "$f" ] && mkdir -p "$CACHE/conf" && ln -sf "$f" "$CACHE/conf/fleet-palette.conf"
  return 0
}
# write_conf — conf/tmux-shell.conf with the paths filled + the environment
write_conf() {
  local tpl="$BIN/../conf/tmux-shell.conf" line
  [ -f "$tpl" ] || tpl="$REAL_BIN/../conf/tmux-shell.conf"   # run from the mirror: beside the real bin/
  [ -f "$tpl" ] || fail_start "缺 $tpl"
  {
    sed -e "s|__BIN__|$SHADOW|g" -e "s|__PREFIX__|$PREFIX|g" "$tpl"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in *"'"*) continue ;; esac     # a value no single-quoted tmux string can hold
      printf "set-environment -g %s '%s'\n" "${line%%=*}" "${line#*=}"
    done <<EOF
$SHELL_ENV
EOF
  } > "$CACHE/tmux.conf"
}

mode="${1:-}"
case "$mode" in
# ---------------------------------------------------------------------------------
ssh)
  shift
  master=0; for a in "$@"; do [ "$a" = ControlMaster=yes ] && master=1; done
  # The host: the first word that is not an option (ssh's options with a value).
  host=''; i=0; op=''
  args=("$@")
  while [ "$i" -lt "${#args[@]}" ]; do
    a=${args[$i]}
    case "$a" in
      -O) op=${args[$((i+1))]:-}; i=$((i+2)) ;;
      -o|-S|-F|-i|-l|-p|-L|-R|-D|-J|-W|-b|-c|-e|-m|-Q|-w|-B|-E|-I) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) host=$a; i=$((i+1)); break ;;
    esac
  done
  if [ -n "$host" ] && this_machine "$host"; then
    # This computer is that machine: the command runs here, nested (C6 hides the
    # node's own list for a shell client); the master's -O answers are yeses.
    [ -n "$op" ] && exit 0
    cmd=''; while [ "$i" -lt "${#args[@]}" ]; do cmd="$cmd${cmd:+ }${args[$i]}"; i=$((i+1)); done
    unset TMUX TMUX_PANE
    cd "$HOME" 2>/dev/null || :
    exec bash -c "$cmd"
  fi
  [ "$master" = 1 ] || exec ssh "$@"
  # A master: `fleet connect` picks the route and the identity; keep the control /
  # keepalive options, drop what it decides (ProxyCommand, the key), -tt → RequestTTY.
  opts=(); i=0; host=''
  while [ "$i" -lt "${#args[@]}" ]; do
    a=${args[$i]}
    case "$a" in
      -o) case "${args[$((i+1))]:-}" in ProxyCommand=*|HostKeyAlias=*|CertificateFile=*) ;; *) opts+=(-o "${args[$((i+1))]:-}") ;; esac; i=$((i+2)) ;;
      -tt|-t) opts+=(-o RequestTTY=force); i=$((i+1)) ;;
      -S|-F|-i|-l|-p|-L|-R|-D|-J|-W|-b|-c|-e|-m|-O|-Q|-w|-B|-E|-I) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) host=$a; i=$((i+1)); break ;;
    esac
  done
  [ -n "$host" ] || { note 'ssh: no host'; exit 2; }
  rest=(); while [ "$i" -lt "${#args[@]}" ]; do rest+=("${args[$i]}"); i=$((i+1)); done
  exec python3 "$BIN/fleet-connect.py" --enter "$host" ${opts[@]+"${opts[@]}"} -- ${rest[@]+"${rest[@]}"}
  ;;
# ---------------------------------------------------------------------------------
open-url)
  url="${2:-}"
  case "$url" in http://*|https://*) ;; *) exit 2 ;; esac
  if command -v open >/dev/null 2>&1; then exec open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then exec xdg-open "$url"
  else printf '%s\n' "$url"; fi
  exit 0
  ;;
# ---------------------------------------------------------------------------------
keeper)
  s="${2:-$SESS}"
  while tmux -L "$s" has-session -t "=$s" 2>/dev/null; do
    bash "$BIN/fleet-hub-sessions.sh" --ensure >/dev/null 2>&1 || :
    sleep 20
  done
  exit 0
  ;;
# ---------------------------------------------------------------------------------
wait)
  s="${2:-$SESS}"
  printf '\n  入口没有在线的机器，或者连不上入口。\n  左边是入口给的列表（缓存也算）：点一行就进那台机器；底下一栏说入口通不通。\n  prefix d 离开；再敲 fleet 回来。\n'
  while [ "$(tmux -L "$s" list-windows -t "=$s" -F x 2>/dev/null | grep -c x)" -le 1 ]; do sleep 1; done
  exit 0
  ;;
# ---------------------------------------------------------------------------------
env) machine="${2:-}" ;;
'')  machine='' ;;
-*)  note "unknown option $mode"; exit 2 ;;
*)   machine="$mode" ;;
esac

# --- start (or re-attach) --------------------------------------------------------
if [ "$mode" != env ] && ! tmux_ok; then
  tmux_hint
  exec python3 "$BIN/fleet-connect.py" --enter ${machine:+"$machine"}
fi
command -v python3 >/dev/null 2>&1 || fail_start '没有 python3'

# 1. the certificate and the machine (fleet-connect.py --pick: renew or scan, then
#    the hub's pick — or the name checked against the route list). No hub URL: its
#    own words, exit 2. None online: exit 1 from it, the shell still opens (the
#    list and the bar come from the hub; a row opens a window).
pick=$(python3 "$BIN/fleet-connect.py" --pick ${machine:+"$machine"}); rc=$?
case "$rc" in
  0) ;;
  2) exit 2 ;;
  *) [ -n "$machine" ] && exit "$rc"; pick='' ;;
esac
node=$(printf '%s' "$pick" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("machine") or "")
except Exception: print("")' 2>/dev/null)
case "$node" in *[!A-Za-z0-9._-]*) node='' ;; esac

mirror || exit 1
shell_env "$pick"
if [ "$mode" = env ]; then printf '%s\n' "$SHELL_ENV"; exit 0; fi
export_env

# 2. already running? Re-attach — onto the named machine's window when there is one.
if T has-session -t "=$SESS" 2>/dev/null; then
  if [ -n "$node" ]; then
    w=$(T list-windows -t "=$SESS" -F '#{window_id} #{@remote}' 2>/dev/null | awk -v n="$node:" 'index($2, n) == 1 { print $1; exit }')
    [ -n "$w" ] && T select-window -t "$w" 2>/dev/null
  fi
  ( nohup bash "$SHADOW/fleet-shell.sh" keeper "$SESS" </dev/null >/dev/null 2>&1 & )
  exec tmux -L "$SESS" attach-session -t "=$SESS"
fi

# 3. the server: conf (keys, hooks, bar, environment) + the first window
write_conf || fail_start "写不了 $CACHE/tmux.conf"
if [ -n "$node" ]; then
  title="⇄$node"
  cmd="exec bash $(sq "$SHADOW/fleet-remote-view.sh") run --shell $(sq "$node") -"
  remote="$node:"
else
  title="⇄"
  cmd="exec bash $(sq "$SHADOW/fleet-shell.sh") wait $(sq "$SESS")"
  remote="-:"
fi
w=$(tmux -L "$SESS" -f "$CACHE/tmux.conf" new-session -d -P -F '#{window_id}' -s "$SESS" -n "$title" -c "$HOME" -x 220 -y 60 "$cmd") \
  || fail_start 'tmux 开不了会话'
T set-window-option -t "$w" @remote "$remote" \; set-window-option -t "$w" automatic-rename off 2>/dev/null
# 4. the data: the refresh loop, kept alive while the server lives
( nohup bash "$SHADOW/fleet-shell.sh" keeper "$SESS" </dev/null >/dev/null 2>&1 & )
[ "${FLEET_SHELL_NO_ATTACH:-0}" = 1 ] && { printf '%s\n' "$SESS"; exit 0; }
exec tmux -L "$SESS" attach-session -t "=$SESS"
