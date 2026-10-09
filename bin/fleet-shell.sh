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
# switches the right pane to that machine. The list and the bar never move — and
# never repaint: a switch, to the same machine or another, rewrites the right
# pane alone (issue #1759).
#
# How it is built — nothing new is rendered here (EPIC #1479 「两套行生成器漂移」):
#   · its OWN tmux server, `-L fleet-shell` (FLEET_SHELL_SESSION), one session of
#     that name — a fleet's socket label IS its session name, so every in-pane
#     script resolves this server the way it resolves a fleet's; never a fleet's
#     server, never its conf;
#   · ONE WINDOW on it, `home` (`@shell_frame`): the list pane on the left, and on
#     the right a NESTED client of the STAGE (`viewer` below) — a second server of
#     the shell's, `-L <session>-stage` (conf/tmux-shell-stage.conf), holding ONE
#     WINDOW PER MACHINE, each a proxy window (`m4 <name>`, `@remote=<node>:<wid>`)
#     exactly as a fleet opens one on a remote row (#1424/#1475), its pane
#     `fleet-remote-view.sh run --shell`: the far end registers a SHELL client and
#     hides its own list, bar and prefix while only shells are attached (#1485).
#     Switching machines is a `select-window` on the stage (fleet-remote-view.sh
#     `open`, FLEET_SHELL_STAGE): tmux repaints every client of the server a
#     window op runs on, so on the stage that is the nested client — the right
#     pane — and the shell's own server, with the list, its borders and the bar,
#     sees nothing at all (issue #1759; #1702's window-per-machine swap repainted
#     the whole screen). The stage's status line, on its top, is the right pane's
#     title (the machine, the session, 中转 / 失联 / 旧);
#   · the list pane sits in `home` and never moves; the conf's hooks draw it
#     (`sync`), and it reads which row is current off the stage;
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
#   actions <session>      does what a session anywhere asks to show you, on THIS
#                          device (issue #1717) — see `actions` below
#   warm <session> [--once] keeps ONE ssh master per machine you have sessions on
#                          (issue #1631) — see `warm` below
#   viewer <session>       the right pane of `home`: a nested client of the stage,
#                          started again (with the stage, when it is gone) for as
#                          long as the shell's server lives
#   wait <session> [<machine>]  the stage's first window when no machine is online: a
#                          note, gone as soon as a row opens a real one. With a
#                          machine (THIS computer, no fleet of this login here —
#                          issue #2219): the home page, how to start, instead
#   portal <session>       ⌘N / prefix c / a tap on 「新任务」 (issue #1953): the
#                          stage's writing-area window (`@fleet_role portal`,
#                          `@remote new`, bin/fleet-compose.py) made once and
#                          selected — the right pane shows it, the list its row;
#                          one an older client started (`@portal_ver`) is
#                          respawned on the new code first (issue #2113)
#   keys <session>         retired with ⌘/ (issue #2362): does nothing, exit 0 —
#                          only a bind an older conf still holds calls it
#   reload <session> [--from <old home>]   a newer client into the running one,
#                          same servers (issue #1781) — see `reload` below
#   ask <kind> [arg…]      a short question on ONE line at the bottom of the stage
#                          (issue #1950): the list asks it (`<kind>` as its row
#                          menu does — rename @id, message wid:…, answer wid:… ask,
#                          sub @id, repo, new [machine]) and its answer takes that
#                          kind's path; the list's actions are kinds too (restore,
#                          scratch, view, reload, info, needs). Exit 0 asked, 1 no
#                          list on screen. A bare question (no kind of the list's):
#                          bin/fleet-ask.py open --below <pane> --kind --prompt.
#   layout <auto|single|split|multi|solo> [<session>]   the client's layout, live
#                          (issue #2265): `@fleet_layout`, the stage's top line,
#                          a sync — the switcher's 「打开多会话视图」 (#2266)
#   solo <machine> <worker id>  `fleet claude`'s own one-session view (issue #2349)
#                          — see `solo` below
#   quit [<session>]       退出 fleet (issue #2349): every process of the client
#                          here, the sessions untouched — see `quit` below
#   running [--say]        exit 0 while the client runs here (`fleet status`)
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
# The client is the ONLY way in (issue #1628): no tmux / tmux < 3.2 → one line on
# installing it, exit 1; a start that fails before the attach → one line on why
# (fail_start), exit 1 — never a fallback to ssh-ing into a machine's own list.
# Run over ssh (an iPad / iPhone on a machine with the fleet), it is the same
# client on that machine, and its bar says 客户端在 <machine> 上运行 (client_where).
# NO HUB (issue #1712, EPIC #1710 C2): with no hub address anywhere — a single
# computer that only wants the tools, or the hub not set up yet — this is the
# SAME client, reading this machine: `fleet connect --pick` answers THIS computer
# (reason `local`), its window nests the attach right here (the ssh mode's
# this_machine), and the list is this machine's own sessions —
# FLEET_SIDEBAR_SOURCE=local + FLEET_HUB_SESSIONS_LOCAL=1, the loop asking
# `fleet-remote-view.sh sessions` here instead of the hub. With an address the
# environment is byte for byte what it was.
# Exit: 0 (the attach's); 1 no machine / no tmux / could not start; 2 a picker
# that still says «no hub URL» (an older fleet-connect.py).
set -uo pipefail
# a session's test or drill is the TEST identity (issue #1931): its own lease,
# never the person's — fleet-client-lease.py reads FLEET_CLIENT_IDENTITY, and the
# keeper / actions loops started below inherit it
if [ "${1:-}" = --test-identity ]; then
  export FLEET_CLIENT_IDENTITY=test
  shift
fi
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
# The team's defaults from the hub (issue #1722), FIRST so every file below
# wins: written only by fleet-client-update.sh, each line fills a gap only.
# shellcheck source=/dev/null
[ -f "$CONF_DIR/hub-defaults.conf" ] && . "$CONF_DIR/hub-defaults.conf"
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
STAGE="$SESS-stage"                      # the proxies' server (issue #1759): label = session

note() { printf 'fleet: %s\n' "$*" >&2; }
# fail_start <why> — the client could not start (nothing attached yet): one line
# saying why, exit 1. Nothing else opens instead (issue #1628: the client is the
# only way in).
fail_start() {
  note "客户端起不来：$*"
  exit 1
}
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
T() { tmux -L "$SESS" "$@"; }
TS() { tmux -L "$STAGE" "$@"; }

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
  note '客户端要 tmux ≥ 3.2：macOS `brew install tmux`，Debian/Ubuntu `sudo apt install tmux`，装好再敲 fleet。'
}
# client_where — a client run over ssh (an iPad / iPhone has no client of its own:
# it ssh's into a machine with the fleet and runs `fleet` there, issue #1628) says
# so on its bar — 客户端在 <machine> 上运行 — for THIS tty's client alone
# (`@fleet_client_remote` = `<tty>|<machine>`, tmux-status.sh's `cr=`). A local
# attach on the tty that holds the mark clears it; no tty, nothing.
client_where() {
  local tt me a cur
  tt=$(tty 2>/dev/null) || return 0
  case "$tt" in /dev/*) ;; *) return 0 ;; esac
  if [ -n "${SSH_CONNECTION:-}" ]; then
    me=$(hostname -s 2>/dev/null); me=${me%%.*}
    for a in ${FLEET_NODE_ALIASES:-}; do case "$a" in "$me="*) me=${a#*=} ;; esac; done
    [ -n "$me" ] && T set-option -g @fleet_client_remote "$tt|$me" 2>/dev/null
  else
    cur=$(T show-options -gqv @fleet_client_remote 2>/dev/null)
    [ -n "$cur" ] && [ "${cur%%|*}" = "$tt" ] && T set-option -gu @fleet_client_remote 2>/dev/null
  fi
  return 0
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

# --- one person, several clients (issue #1715, EPIC #1710 C5; #1932, EPIC #1906 C13)
# The hub holds a lease per client (POST /v1/fleet/client), up to 4 a person
# (FLEET_CLIENT_MAX on the hub): opening the client takes one of its own — a
# MacBook, an iPhone and an iPad side by side, none pushing another off — and the
# keeper renews it every FLEET_CLIENT_LEASE_EVERY (15 s). The PRIMARY — where a
# page, a file or a note goes, what fleet-client-where.sh names — is the client
# typed into last: every FLEET_CLIENT_INPUT_EVERY (5 s) the keeper reads tmux's
# #{client_activity} of the clients attached here and, when it moved, reports it
# (`input`, at most once per 5 s) with that client's where; a renewal carries
# the session the stage is showing (`viewing`, the top line's 「也在 iPhone 上打开」)
# and the where in use here (client.where.json — a hub restart forgets every
# lease, and the renewal that re-adopts ours tells it the device again, #1995).
# Only two things send this server to STANDBY now: a fifth client asked this one,
# the least recently used, to leave (reason evicted), or you disconnected it from
# another client's 我的客户端 (revoked). Then every attached client gets a
# full-screen popup saying which — Enter takes a lease again — the list stops
# asking the hub (fleet-hub-sessions.sh skips its rounds), no write goes out
# (fleet-hub-write.sh refuses), the warm loop opens nothing, and the keeper stops
# renewing. An older hub (one lease a person, taken over by the next client)
# still answers taken_over without a reason: the old screen, 「正在 <device> 上使
# 用 · 按回车接回」. On ONE machine a second `fleet` attaches to the running server
# (never a second one) and both clients simply work. No hub (no URL — or one
# without the lease) → no lease. State, under $CACHE/tmp (the server's TMPDIR):
#   client.lease    our lease id             client.standby  present = standby
#   client.by       the device that did it   client.why      evicted | revoked | ''
#   client.nohub    the hub keeps no lease   keeper.pid      the one keeper
#   client.dev/<tty> each client's device
#   client.where/<tty>.json  each client's whole where (issue #1716: device os
#                   terminal via host caps, fleet-client-lease.py device --save)
#   client.where.json        the one in use now (the last typed into) — what
#                   fleet-client-where.sh reads when there is no hub (its mtime = since)
#   client.list.json         the person's clients as the hub last said (#1932:
#                   lease, primary, clients) — 我的客户端, the top line
CL_DIR="$CACHE/tmp"
# the lease's action key (issue #1717): fleet-client-lease.py writes it on every
# active acquire / renewal, fleet-client-actions.py checks each action with it
export FLEET_CLIENT_KEY_FILE="$CL_DIR/client.key"
export FLEET_CLIENT_LIST_FILE="$CL_DIR/client.list.json"
LEASE_CMD="${FLEET_CLIENT_LEASE_CMD:-python3 $BIN/fleet-client-lease.py}"
cl_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
# lease <action> [args…] → L_STATE L_ID L_BY L_WHY; rc 1 = the hub was not asked
lease() {
  local line
  L_STATE=''; L_ID=''; L_BY=''; L_WHY=''
  line=$($LEASE_CMD "$@" 2>/dev/null) || return 1
  # TAB is whitespace to `read`: two in a row (an empty field) would collapse
  line=${line//$'\t'/$'\037'}
  IFS=$'\037' read -r L_STATE L_ID L_BY _ L_WHY _ <<< "$line"
  [ -n "$L_STATE" ]
}
standby_on() { [ -f "$CL_DIR/client.standby" ]; }
# standby_popup <client> — the standby screen on that client (a popup is the
# client's own, so the session's other clients keep their screen); a popup
# holds its caller until the popup closes, so it runs in the background. Through
# the popup lib's one door (fleet_popup_screen; dash-popup-selftest greps for it).
standby_popup() {
  ( . "$BIN/fleet-popup-lib.sh" && fleet_popup_screen "$SESS" "$1" \
      "exec bash $(sq "$SHADOW/fleet-shell.sh") standby $(sq "$SESS") $(sq "$1")" </dev/null >/dev/null 2>&1 & )
}
# others_standby <client|''> <device> — every client of the session but that one
# to standby, naming the device now in use
others_standby() {
  local c
  printf '%s\n' "$2" > "$CL_DIR/client.by" 2>/dev/null
  for c in $(T list-clients -t "=$SESS" -F '#{client_name}' 2>/dev/null); do
    [ "$c" = "$1" ] && continue
    standby_popup "$c"
  done
  return 0
}
# where_file <client> — that client's saved where (issue #1716)
where_file() { printf '%s/client.where/%s.json' "$CL_DIR" "$(cl_key "$1")"; }
jstr() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
# where_now <client|''> <device> <terminal> — that client is the one in use:
# client.where.json is its saved where, or (none saved) what we know of it
where_now() {
  local f=''
  [ -n "$1" ] && f=$(where_file "$1")
  if [ -n "$f" ] && [ -s "$f" ]; then
    cp "$f" "$CL_DIR/client.where.json.tmp" 2>/dev/null
  else
    printf '{"device": %s, "terminal": %s}\n' "$(jstr "${2:-未知设备}")" "$(jstr "${3:-}")" > "$CL_DIR/client.where.json.tmp" 2>/dev/null
  fi
  mv -f "$CL_DIR/client.where.json.tmp" "$CL_DIR/client.where.json" 2>/dev/null
  return 0
}
# client_take <client|''> <device> <terminal> — this server holds a lease: the
# hub's (a new one, or ours kept), standby off. The clients attached here keep
# working beside it (#1932). rc 1 = the hub could not be asked (nothing changed).
client_take() {
  local old='' wf=''
  mkdir -p "$CL_DIR/client.dev" 2>/dev/null
  { read -r old < "$CL_DIR/client.lease"; } 2>/dev/null
  [ -n "$old" ] || { read -r old < "$CL_DIR/client.lease.old"; } 2>/dev/null
  [ -n "$1" ] && wf=$(where_file "$1") && [ -s "$wf" ] || wf=''
  lease acquire ${old:+--lease "$old"} --device "$2" ${3:+--terminal "$3"} ${wf:+--where-file "$wf"} || return 1
  rm -f "$CL_DIR/client.lease.old"
  case "$L_STATE" in
    active) printf '%s\n' "$L_ID" > "$CL_DIR/client.lease"; rm -f "$CL_DIR/client.nohub" ;;
    *) rm -f "$CL_DIR/client.lease"; : > "$CL_DIR/client.nohub" ;;   # nohub: no lease to keep
  esac
  [ -n "$1" ] && printf '%s\n' "$2" > "$CL_DIR/client.dev/$(cl_key "$1")"
  rm -f "$CL_DIR/client.standby" "$CL_DIR/client.why"
  where_now "$1" "$2" "$3"
  return 0
}
# go_standby <device> <reason> — our lease is no longer held (evicted: a client
# past the limit asked this one to leave; revoked: disconnected from another
# client; '': an older hub's takeover): every client here to standby, the lease
# id kept aside for taking one again
go_standby() {
  local id=''
  { read -r id < "$CL_DIR/client.lease"; } 2>/dev/null
  [ -n "$id" ] && printf '%s\n' "$id" > "$CL_DIR/client.lease.old"
  rm -f "$CL_DIR/client.lease" "$CL_DIR/client.where.json" "$CL_DIR/client.key" "$CL_DIR/client.list.json"
  printf '%s\n' "${2:-}" > "$CL_DIR/client.why"
  : > "$CL_DIR/client.standby"
  others_standby '' "${1:-未知设备}"
}
# latest_client <session> — the attached client typed into last: "<activity> <name>"
latest_client() {
  T list-clients -t "=$1" -F '#{client_activity} #{client_name}' 2>/dev/null | sort -n | tail -n 1
}
# viewing <session> — the session the stage shows (its worker id), '' none
viewing() {
  local r
  r=$(tmux -L "$1-stage" display-message -p -t "=$1-stage:" '#{@remote}' 2>/dev/null) || r=''
  case "$r" in *:?*) printf '%s' "${r#*:}" ;; esac
}

# have_hub — is a hub address configured anywhere `fleet connect` would look
# (issue #1712)? FLEET_HUB_URL / CCQUOTA_HUB_URL (the env, fleet.conf's [common],
# shell.conf — all sourced above), else hub.json's old "url". No address = the
# client on THIS computer alone: the list is this machine's own sessions
# (fleet-hub-sessions.sh FLEET_HUB_SESSIONS_LOCAL), FLEET_SIDEBAR_SOURCE=local.
have_hub() {
  [ -n "${FLEET_HUB_URL:-}${CCQUOTA_HUB_URL:-}" ] && return 0
  [ -f "$CONF_DIR/hub.json" ] || return 1
  python3 -c 'import json, sys
try:
    sys.exit(0 if str(json.load(open(sys.argv[1])).get("url") or "").strip() else 1)
except Exception:
    sys.exit(1)' "$CONF_DIR/hub.json" 2>/dev/null
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
  # The list's source follows the hub address (issue #1712): none → this machine
  # answers for itself (FLEET_HUB_SESSIONS_LOCAL, appended last so a hub client's
  # environment is byte for byte what it was).
  SRC=hub; have_hub || SRC=local
  SHELL_ENV="FLEET_SHELL=1
FLEET_SHELL_SESSION=$SESS
FLEET_SHELL_STAGE=$STAGE
FLEET_HUB_SESSIONS_CLIENT=$SESS
CCQUOTA_FLEET=1
FLEET_SIDEBAR_SOURCE=$SRC
TMPDIR=$CACHE/tmp
FLEET_REMOTE_SSH_CMD=${FLEET_REMOTE_SSH_CMD:-$SHADOW/fleet-shell.sh ssh}
FLEET_REMOTE_OPENER=${FLEET_REMOTE_OPENER:-$SHADOW/fleet-shell.sh open-url}
FLEET_SIDEBAR_WIDTH=${FLEET_SHELL_WIDTH:-${FLEET_SIDEBAR_WIDTH:-30}}
FLEET_NODE_ALIASES=$FLEET_NODE_ALIASES"
  for n in CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_HUB_SESSIONS_CMD FLEET_HUB_NODES_CMD FLEET_HUB_LIMITS_CMD \
           FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_EVERY FLEET_HUB_SESSIONS_WATCHED_EVERY \
           FLEET_HUB_SESSIONS_LOOP_SECS FLEET_HUB_NODE_TIMEOUT FLEET_HUB_WRITE_CMD FLEET_REMOTE_BIN FLEET_REMOTE_SSH FLEET_REMOTE_VIA_HUB FLEET_CONF_DIR FLEET_CERT \
           FLEET_SHELL_WARM FLEET_SHELL_WARM_MAX FLEET_SHELL_WARM_EVERY FLEET_SHELL_WARM_CONNECT \
           CCQUOTA_VIEWER_TOKEN FLEET_UI_LANG FLEET_SIDEBAR_WIDTH_MAX XDG_CONFIG_HOME XDG_CACHE_HOME FLEET_SHELL_CACHE \
           FLEET_SKIP_GLOBAL_CONF LANG LC_ALL FLEET_CLIENT_LAYOUT FLEET_SWITCH_STATE XDG_STATE_HOME FLEET_NOTIFY FLEET_NOTIFY_JUMP_SECS; do
    eval "v=\${$n:-}"
    [ -n "$v" ] && SHELL_ENV="$SHELL_ENV
$n=$v"
  done
  [ "$SRC" = local ] && SHELL_ENV="$SHELL_ENV
FLEET_HUB_SESSIONS_LOCAL=1"
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
# stamp_ver — which client the running server was loaded from, on the server
# (@client_version, the .client-version beside the real bin/; nothing for a
# checkout): fleet-client-update.sh compares it with the files on disk, and
# files that moved under a running client are reloaded into it (issue #1829).
# Set at a new start and by `reload` — never on a re-attach, which loads nothing.
# Beside it @client_digest, the same client by CONTENT (issue #2145): a home
# with no .client-version is told apart by that — fleet-client-update.sh's
# client_digest is the one list of files.
stamp_ver() {
  local v
  v=$(sed -n 's/^version=//p' "$REAL_BIN/../.client-version" 2>/dev/null | head -n 1)
  [ -n "$v" ] && T set-option -g @client_version "$v" 2>/dev/null
  v=$(bash "$REAL_BIN/fleet-client-update.sh" digest --root "$REAL_BIN/.." 2>/dev/null)
  [ -n "$v" ] && T set-option -g @client_digest "$v" 2>/dev/null
  return 0
}
# portal_ver — the code the writing area runs (issue #2113): fleet-compose.py and
# the texts it loads, by content — so a checkout (no .client-version) and a
# reload that moved nothing else are told apart the same way.
portal_ver() {
  cat "${SHADOW:-$BIN}/fleet-compose.py" "${SHADOW:-$BIN}/fleet-ui-lang.sh" 2>/dev/null | cksum | awk '{ print $1 "-" $2 }'
}
# code_sum <file…> — the code a long-lived client process runs, by content
# (issue #2345): each loop writes it beside its pid file when it takes the pid
# (<pid file>.code), and `reload`
# restarts the ones whose code on disk is not what they started from — never
# judged by a link, which already points at the new files.
code_sum() { cat "$@" 2>/dev/null | cksum | awk '{ print $1 "-" $2 }'; }
# portal_fresh <window id> [--force] — the stage's portal window on the code on
# disk: a window started by another version (@portal_ver differs, or none) has
# its pane respawned in place — same window id, same @fleet_role / @remote, so
# the list's row stays put. The draft is on disk (fleet-compose.py saves it on
# the SIGHUP the respawn sends), so nothing typed is lost.
portal_fresh() {
  local w="$1" force="${2:-}" v
  v=$(portal_ver)
  [ -z "$force" ] && [ "$(TS show-window-option -v -t "$w" @portal_ver 2>/dev/null)" = "$v" ] && return 0
  TS respawn-pane -k -t "$w" "exec python3 $(sq "${SHADOW:-$BIN}/fleet-compose.py") --session $(sq "$SESS")" 2>/dev/null || return 1
  TS set-window-option -t "$w" @portal_ver "$v" 2>/dev/null
  return 0
}
# iterm_keys — the iTerm2 profile `fleet` (issue #1903): its ⌘ chords send the
# switch codes conf/tmux-shell.conf catches. Written (only when it changed) at
# every start and reload, so the install line and each update leave it current;
# nothing at all off a Mac with iTerm2 (bin/fleet-iterm-profile.py).
iterm_keys() { python3 "$SHADOW/fleet-iterm-profile.py" write >/dev/null 2>&1 || :; }
# attach_client — the attach, exec'd as always; in an iTerm2 window, with the
# profile there, the window wears it while attached and goes back to the profile
# it came from after the detach — outside the client iTerm2 is as it was.
attach_client() {
  local back="${ITERM_PROFILE:-}" rc iterm=''
  if [ -n "$back" ] && [ "$back" != fleet ] && [ "${FLEET_ITERM_KEYS:-1}" != 0 ] \
     && { [ "${TERM_PROGRAM:-}" = iTerm.app ] || [ "${LC_TERMINAL:-}" = iTerm2 ]; } \
     && [ -f "${FLEET_ITERM_DIR:-$HOME/Library/Application Support/iTerm2/DynamicProfiles}/fleet.json" ] \
     && { : > /dev/tty; } 2>/dev/null; then
    iterm=1
  fi
  # the one-session view (issue #2265) does not exec the attach either: once it
  # returns — ⌃D, prefix d, or the session's own /exit (fleet-sidebar.py
  # solo_ended) — the terminal is told where the session is and how to come
  # back (fleet-topbar.py goodbye). Any other layout: exactly as before.
  if [ -z "$iterm" ] && [ "$(tmux -L "$SESS" show-options -gqv @fleet_layout 2>/dev/null)" != solo ]; then
    exec tmux -L "$SESS" attach-session -t "=$SESS"
  fi
  [ -n "$iterm" ] && printf '\033]1337;SetProfile=fleet\007' > /dev/tty
  tmux -L "$SESS" attach-session -t "=$SESS"; rc=$?
  [ -n "$iterm" ] && printf '\033]1337;SetProfile=%s\007' "$back" > /dev/tty
  if [ "$(tmux -L "$SESS" show-options -gqv @fleet_layout 2>/dev/null)" = solo ]; then
    python3 "${SHADOW:-$BIN}/fleet-topbar.py" goodbye \
      "node=$(tmux -L "$SESS" show-options -gqv @fleet_view_node 2>/dev/null)" 2>/dev/null || :
  fi
  exit "$rc"
}
# write_conf — conf/tmux-shell.conf (the shell's server) and conf/tmux-shell-stage.conf
# (the stage's, issue #1759) with the paths filled + the environment
write_conf() {
  local name out line tpl
  for name in tmux-shell tmux-shell-stage; do
    tpl="$BIN/../conf/$name.conf"
    [ -f "$tpl" ] || tpl="$REAL_BIN/../conf/$name.conf"   # run from the mirror: beside the real bin/
    [ -f "$tpl" ] || fail_start "缺 $tpl"
    out="$CACHE/tmux.conf"; [ "$name" = tmux-shell ] || out="$CACHE/tmux-stage.conf"
    {
      sed -e "s|__BIN__|$SHADOW|g" -e "s|__PREFIX__|$PREFIX|g" -e "s|__STAGE__|$STAGE|g" -e "s|__SESS__|$SESS|g" "$tpl"
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *"'"*) continue ;; esac     # a value no single-quoted tmux string can hold
        printf "set-environment -g %s '%s'\n" "${line%%=*}" "${line#*=}"
      done <<EOF
$SHELL_ENV
EOF
    } > "$out" || return 1
  done
}
# stage_up [<command> <@remote> <name>] — the stage server and its session, with
# that first window (default: the `wait` note, `@remote=-:`). Already up: nothing.
stage_up() {
  local cmd="${1:-}" remote="${2:--:}" title="${3:-fleet}" w
  TS has-session -t "=$STAGE" 2>/dev/null && return 0
  [ -f "$CACHE/tmux-stage.conf" ] || return 1
  # the home page's machine (issue #2219), so a stage started again shows the same
  local hm=''; { read -r hm < "$CACHE/home-machine"; } 2>/dev/null
  [ -n "$cmd" ] || cmd="exec bash $(sq "$SHADOW/fleet-shell.sh") wait $(sq "$SESS")${hm:+ $(sq "$hm")}"
  w=$(TS -f "$CACHE/tmux-stage.conf" new-session -d -P -F '#{window_id}' -s "$STAGE" -n "$title" -c "$HOME" -x 180 -y 50 "$cmd") \
    || return 1
  TS set-window-option -t "$w" @remote "$remote" \; set-window-option -t "$w" automatic-rename off 2>/dev/null
  [ "$(T show-options -gqv @fleet_layout 2>/dev/null)" = solo ] && TS set-option -g status off 2>/dev/null
  return 0
}
# layout_apply [<layout>] — the client's layout on the running servers (issue
# #2265, EPIC #2259 共同约定 1): `@fleet_layout` on the shell's (the bar, ⌃D and
# the list read it) and, in `solo`, the stage's top line off — the one-session
# view has its bottom line only. No argument: FLEET_CLIENT_LAYOUT (auto).
layout_apply() {
  local lay="${1:-${FLEET_CLIENT_LAYOUT:-auto}}" st=on
  case "$lay" in auto|single|split|multi|solo) ;; *) lay=auto ;; esac
  [ "$lay" = solo ] && st=off
  T set-option -g @fleet_layout "$lay" 2>/dev/null
  TS has-session -t "=$STAGE" 2>/dev/null && TS set-option -g status "$st" 2>/dev/null
  # and no border line over the session: `home`'s own pane-border-status, off in
  # solo, else unset — the conf's `top` again
  T list-windows -t "=$SESS" -F '#{window_id} #{@shell_frame}' 2>/dev/null \
    | while read -r w f; do
        [ "$f" = 1 ] || continue
        if [ "$lay" = solo ]; then T set-option -w -t "$w" pane-border-status off 2>/dev/null
        else T set-option -uw -t "$w" pane-border-status 2>/dev/null; fi
      done
  return 0
}
# solo_last — the row the one-session view showed last (issue #2265): the head
# of the switch history the list keeps (fleet-quickopen.py's `mru`), read before
# a new start's list writes its first visit. Empty: none.
solo_last() {
  python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("q", sys.argv[1])
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
print((q.load().get("mru") or [""])[0])' "${SHADOW:-$BIN}/fleet-quickopen.py" 2>/dev/null
}
# solo_resume <key> <since> — `fleet` with nothing running comes back to the
# session it left (issue #2265, EPIC #2259 共同约定 3), in the background: a local
# row (@<id>, no hub) by the list's own jump; a row on a machine once the list's
# first read since <since> (epoch) is in — opened on the stage
# (fleet-remote-view.sh open) when it is still there, else a new HOME session
# (`home-session claude`), as when there was none. A newcomer still owed the
# first one is first_home's. FLEET_HOME_OPEN_WAIT bounds the wait for the read;
# FLEET_HOME_OPEN_CMD / FLEET_SOLO_NEW_CMD are the selftests' seams.
#
# A client `fleet claude|codex` started for its own ask (FLEET_SHELL_NO_FIRST)
# resumes nothing (issue #2403): its session is the one it asked for — the
# `else` below would open a SECOND one, a Claude, beside a `fleet codex`.
solo_resume() {
  local key="$1" since="$2"
  [ "${FLEET_CLIENT_LAYOUT:-}" = solo ] || return 0
  [ "${FLEET_SHELL_NO_FIRST:-0}" != 1 ] || return 0
  [ -e "$CONF_DIR/home-session.first" ] || return 0
  (
    cd "$HOME" 2>/dev/null || :; trap '' HUP
    case "$key" in
      @*)
        lp=$(T list-panes -a -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == 1 { print $1; exit }')
        [ -n "$lp" ] && T set-option -pa -t "$lp" @sidebar_do "jump=$key " \; send-keys -t "$lp" F12 2>/dev/null
        exit 0 ;;
    esac
    rf="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/remote_$SESS"
    n=$(( ${FLEET_HOME_OPEN_WAIT:-60} * 4 )); i=0
    while [ "$i" -lt "$n" ]; do
      m=$(stat -c %Y "$rf" 2>/dev/null || stat -f %m "$rf" 2>/dev/null) || m=0
      case "$m" in ''|*[!0-9]*) m=0 ;; esac
      [ "$m" -ge "$since" ] && break
      sleep 0.25; i=$((i + 1))
    done
    [ "$i" -lt "$n" ] || exit 0                    # no read at all: the stage stays as it is
    if [ -n "$key" ] && LC_ALL=C awk -F $'\037' -v k="$key" '$1 == k { f = 1; exit } END { exit !f }' "$rf" 2>/dev/null; then
      ${FLEET_HOME_OPEN_CMD:-bash "$SHADOW/fleet-remote-view.sh" open} "$key"
    else
      ${FLEET_SOLO_NEW_CMD:-bash "$SHADOW/fleet-shell.sh" home-session claude}
    fi
  ) </dev/null >"$CACHE/solo-resume.log" 2>&1 &
}
# stage_select <machine> — the stage's window on that machine current (rc 1: none)
stage_select() {
  local w
  w=$(TS list-windows -t "=$STAGE" -F '#{window_id} #{@remote}' 2>/dev/null | awk -v n="$1:" 'index($2, n) == 1 { print $1; exit }')
  [ -n "$w" ] && TS select-window -t "$w" 2>/dev/null
}

mode="${1:-}"
case "$mode" in
# ---------------------------------------------------------------------------------
# A question asked from anywhere (issue #1950): parked on the list of the shell's
# `home` as its row menu parks one (@sidebar_ask, fleet-sidebar-menu.sh `ask`) and
# the list woken with F12 — it opens the line under the session (bin/fleet-ask.py)
# and runs the answer through the kind's own path. Every word is a token (an @id,
# a wid:…, a machine); no shell or tmux parser sees an answer.
ask)
  shift
  [ $# -gt 0 ] || { note 'ask: <kind> [arg…]'; exit 2; }
  side=$(T list-panes -s -t "=$SESS" -F '#{@sidebar} #{pane_dead} #{pane_id}' 2>/dev/null | awk '$1 == 1 && $2 != 1 { print $3; exit }')
  [ -n "$side" ] || exit 1
  T set-option -p -t "$side" @sidebar_ask "$*" \; send-keys -t "$side" F12 2>/dev/null || exit 1
  exit 0
  ;;
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
  # A session on a master (`-S`, no `-O`) never re-asks the config's static
  # forwards (issue #1775): a `RemoteForward 2226` the master already holds is
  # refused the second time, and a refused mux client never attaches. The `-O
  # forward -L` of fleet-open's page bridge is an `-O`, untouched.
  if [ "$master" != 1 ]; then
    mux=0; for a in "$@"; do case "$a" in -S) mux=1 ;; ClearAllForwardings=*) mux=2; break ;; esac; done
    [ "$mux" = 1 ] && [ -z "$op" ] && exec ssh -o ClearAllForwardings=yes "$@"
    exec ssh "$@"
  fi
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
  SESS=$s; SHADOW=$BIN
  # one keeper per server: the lease must not be renewed twice
  mkdir -p "$CL_DIR" 2>/dev/null
  p=''; { read -r p < "$CL_DIR/keeper.pid"; } 2>/dev/null
  case "$p" in ''|*[!0-9]*) ;; *) [ "$p" != $$ ] && kill -0 "$p" 2>/dev/null && exit 0 ;; esac
  printf '%s\n' $$ > "$CL_DIR/keeper.pid"
  code_sum "$BIN/fleet-shell.sh" > "$CL_DIR/keeper.pid.code" 2>/dev/null
  # every FLEET_CLIENT_INPUT_EVERY (5 s): an input on a client here is reported
  # (#1932); the renewal and the rest every FLEET_CLIENT_LEASE_EVERY (15 s)
  every=${FLEET_CLIENT_LEASE_EVERY:-15}; tick=${FLEET_CLIENT_INPUT_EVERY:-5}
  [ "$tick" -le "$every" ] 2>/dev/null || tick=$every
  sent=$(latest_client "$s"); sent=${sent%% *}; last=0
  while tmux -L "$s" has-session -t "=$s" 2>/dev/null; do
    now=$(date +%s)
    if ! standby_on; then
      id=''; { read -r id < "$CL_DIR/client.lease"; } 2>/dev/null
      lc=$(latest_client "$s"); act=${lc%% *}; c=${lc#* }
      case "$act" in ''|*[!0-9]*) act=0 ;; esac
      typed=''
      if [ "$act" -gt "${sent:-0}" ] 2>/dev/null; then
        # typed into: that client is the one in use here (what
        # fleet-client-where.sh reads with no hub) — and the hub hears it below
        sent=$act; typed=1
        d=''; [ -n "$c" ] && { read -r d < "$CL_DIR/client.dev/$(cl_key "$c")"; } 2>/dev/null
        where_now "$c" "${d:-未知设备}" ''
      fi
      if [ -n "$id" ]; then
        what=''
        if [ -n "$typed" ]; then
          what=input   # ≤ 1 per tick
        elif [ $((now - last)) -ge "$every" ]; then
          what=renew
        fi
        if [ -n "$what" ]; then
          wf=''; [ "$what" = input ] && [ -n "$c" ] && wf=$(where_file "$c") && [ -s "$wf" ] || wf=''
          # a renewal carries the where in use here too: the hub keeps leases
          # in memory, and one that restarted learns the device from it (#1995)
          [ "$what" = renew ] && [ -s "$CL_DIR/client.where.json" ] && wf="$CL_DIR/client.where.json"
          v=$(viewing "$s")
          # an older hub knows no `input`: the renewal it does know, so the
          # lease never lapses under someone typing
          if lease "$what" --lease "$id" ${act:+--last-input "$act"} --viewing "$v" ${wf:+--where-file "$wf"} \
             || { [ "$what" = input ] && lease renew --lease "$id"; }; then
            last=$now
            case "$L_STATE" in
              taken_over) go_standby "$L_BY" "$L_WHY" ;;
              active) [ -z "$L_ID" ] || [ "$L_ID" = "$id" ] || printf '%s\n' "$L_ID" > "$CL_DIR/client.lease" ;;
            esac
          fi
        fi
      elif [ ! -f "$CL_DIR/client.nohub" ] && [ $((now - last)) -ge "$every" ]; then
        # not held (the hub was out of reach at the start): take it now, as the
        # device of the client attached
        last=$now
        c=$(T list-clients -t "=$s" -F '#{client_name}' 2>/dev/null | head -n 1)
        d=''; [ -n "$c" ] && { read -r d < "$CL_DIR/client.dev/$(cl_key "$c")"; } 2>/dev/null
        client_take "$c" "${d:-未知设备}" '' || :
      fi
      if [ $((now - ${slow:-0})) -ge "$every" ]; then
        slow=$now
        bash "$BIN/fleet-hub-sessions.sh" --ensure >/dev/null 2>&1 || :
        # the connection certificate (issue #2112): 12 hours, and an open shell
        # never re-enters `fleet-connect.py --enter` — so with less than
        # FLEET_CERT_RENEW_UNDER (3600 s) left, renew it here, quietly, at most
        # every FLEET_CERT_CHECK_EVERY (300 s). Only exit 3 (scan again) is the
        # person's: one message on each client here, once until it clears.
        if [ $((now - ${certck:-0})) -ge "${FLEET_CERT_CHECK_EVERY:-300}" ]; then
          certck=$now
          crc=0
          ${FLEET_CERT_RENEW_CMD:-python3 "$BIN/fleet-login.py" renew} --quiet --if-under "${FLEET_CERT_RENEW_UNDER:-3600}" \
            >/dev/null 2>&1 || crc=$?
          if [ "$crc" = 3 ]; then
            if [ ! -f "$CL_DIR/client.rescan" ]; then
              : > "$CL_DIR/client.rescan"
              T list-clients -t "=$s" -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
                [ -n "$c" ] && T display-message -c "$c" -d 10000 "$(sh "$BIN/fleet-ui-lang.sh" t badge_rescan_note 2>/dev/null)" 2>/dev/null
              done
            fi
          elif [ "$crc" = 0 ]; then
            rm -f "$CL_DIR/client.rescan"
          fi
        fi
        # a newer client, taken in place once you are idle (issue #1781); applied
        # (4) → this keeper is the old one's code: the new one takes over, same pid
        bash "$BIN/fleet-client-update.sh" tick "$s" >/dev/null 2>&1
        [ $? -eq 4 ] && exec bash "$BIN/fleet-shell.sh" keeper "$s"
      fi
    fi
    sleep "$tick"
  done
  # the server is gone: give the lease up at once, so the next client anywhere
  # takes nothing over
  id=''; { read -r id < "$CL_DIR/client.lease"; } 2>/dev/null
  [ -n "$id" ] && lease release --lease "$id"
  rm -f "$CL_DIR/client.lease" "$CL_DIR/client.lease.old" "$CL_DIR/client.standby" "$CL_DIR/client.nohub" "$CL_DIR/keeper.pid" "$CL_DIR/client.where.json" "$CL_DIR/client.key" "$CL_DIR/client.list.json" "$CL_DIR/client.why" "$CL_DIR/client.rescan"
  # the stage (issue #1759) holds the connections: it goes with the shell — our
  # own server, never a fleet's
  tmux -L "$s-stage" kill-server 2>/dev/null
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# Open it on the device in your hands (issue #1717, EPIC #1710 C7): one loop per
# server long-polls the hub for this client's lease's actions — a page, a file or
# a note a session anywhere asked to show you — and does each here, checked
# against the lease's action key first (bin/fleet-client-actions.py run). Off in
# standby (no lease, nothing comes); no hub → it idles. Log: $TMPDIR/actions.log.
actions)
  s="${2:-$SESS}"
  [ "${FLEET_CLIENT_ACTIONS:-1}" != 0 ] || exit 0
  # its code, for reload (code_sum): written by the one that takes the pid
  FLEET_CLIENT_DIR="$CL_DIR" FLEET_ACTIONS_CODE="$(code_sum "$BIN/fleet-client-actions.py" "$BIN/fleet-client-lease.py")" \
    exec python3 "$BIN/fleet-client-actions.py" run --session "$s"
  ;;
# ---------------------------------------------------------------------------------
# The standby screen (issue #1715): what standby_popup runs on a client — why it
# is there (#1932: asked to leave past the limit, or disconnected; an older hub:
# taken over). Enter takes a lease again for this client; any other key is ignored.
standby)
  s="${2:-$SESS}"; c="${3:-}"
  SESS=$s; SHADOW=$BIN
  trap '' INT QUIT TSTP
  msg=''
  while :; do
    by=''; { read -r by < "$CL_DIR/client.by"; } 2>/dev/null
    why=''; { read -r why < "$CL_DIR/client.why"; } 2>/dev/null
    case "$why" in
      evicted) printf '\033[2J\033[H\n\n    客户端已开满，%s 打开时请这台（最久没用）下线 · 按回车重新连上\n' "${by:-另一台设备}" ;;
      revoked) printf '\033[2J\033[H\n\n    这台已在「我的客户端」里被断开 · 按回车重新连上\n' ;;
      *) printf '\033[2J\033[H\n\n    正在 %s 上使用 · 按回车接回\n' "${by:-另一台设备}" ;;
    esac
    [ -n "$msg" ] && printf '\n    %s\n' "$msg"
    # a timeout only redraws (another client here may have taken it since);
    # bash 3.2 answers a timeout like an EOF, so the tty decides which it was
    if ! IFS= read -r -s -n 1 -t 2 k; then [ -t 0 ] || exit 0; continue; fi
    [ -z "$k" ] || continue
    d=''; [ -n "$c" ] && { read -r d < "$CL_DIR/client.dev/$(cl_key "$c")"; } 2>/dev/null
    if client_take "$c" "${d:-未知设备}" ''; then
      bash "$BIN/fleet-hub-sessions.sh" --ensure >/dev/null 2>&1 || :
      exit 0
    fi
    msg='连不上入口，再按回车重试'
  done
  ;;
# ---------------------------------------------------------------------------------
# The warm loop (issue #1631): the lines you use are open before you need them.
# Every FLEET_SHELL_WARM_EVERY (5 s), off the sidebar's own cache (the #node lines
# fleet-hub-sessions.sh writes — never a network ask of its own), each machine the
# hub shows online with sessions of yours — at most FLEET_SHELL_WARM_MAX (4), the
# busiest first, never this computer — gets ONE ssh master at
# $TMPDIR/warm/<machine>.sock: `fleet connect <machine>` with ControlPersist=10m and
# no session (SessionType=none, forked after auth), keepalive 2 s × 3 so a dead
# line is gone in ≤ 6 s and simply comes back the next tick. A proxy window
# (fleet-remote-view.sh run --shell) finds it and opens a SESSION on it — the
# first switch to a machine is a new window, not a handshake. A machine that drops
# out (offline, or no session of yours left) has its master closed on the next
# tick — unless a window is riding it right now (`@remote_ctl`); the server gone,
# every master is closed and the loop ends. A master that will not come up (an
# OpenSSH older than 8.7, a host key never accepted: BatchMode) leaves the window to
# connect the old way. FLEET_SHELL_WARM=0 turns it off. Its log: warm/warm.log.
warm)
  s="${2:-$SESS}"; once=''; [ "${3:-}" = --once ] && once=1
  [ "${FLEET_SHELL_WARM:-1}" != 0 ] || exit 0
  WD="${TMPDIR:-/tmp}/warm"
  mkdir -p "$WD" 2>/dev/null || exit 0
  if [ -z "$once" ]; then
    p=''; { read -r p < "$WD/loop.pid"; } 2>/dev/null
    case "$p" in ''|*[!0-9]*) ;; *) [ "$p" != $$ ] && kill -0 "$p" 2>/dev/null && exit 0 ;; esac
    printf '%s\n' $$ > "$WD/loop.pid"
    code_sum "$BIN/fleet-shell.sh" > "$WD/loop.pid.code" 2>/dev/null
  fi
  SSHC="${FLEET_REMOTE_SSH_CMD:-ssh}"
  CACHEF="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/remote_$s"
  wlog() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$WD/warm.log" 2>/dev/null; }
  whost() {   # its ssh host (FLEET_REMOTE_SSH, as fleet-remote-view.sh)
    local h
    h=$(printf '%s\n' ${FLEET_REMOTE_SSH:-} | awk -F= -v n="$1" '$1 == n { print $2; exit }')
    printf '%s' "${h:-$1}"
  }
  walive() { [ -S "$WD/$1.sock" ] && $SSHC -S "$WD/$1.sock" -O check "$(whost "$1")" >/dev/null 2>&1; }
  # wanted → one label per line: online (or 维护中), n > 0, busiest first, capped
  wanted() {
    [ -s "$CACHEF" ] || return 0
    LC_ALL=C awk -F $'\037' '$1 == "#node" && $3 != "lost" && $4 + 0 > 0 && $2 ~ /^[A-Za-z0-9._-]+$/ { print $4 "\t" $2 }' "$CACHEF" \
      | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2 \
      | while IFS= read -r m; do this_machine "$m" || printf '%s\n' "$m"; done \
      | head -n "${FLEET_SHELL_WARM_MAX:-4}"
  }
  wstart() {   # <label> — in the background; the pid sits in <sock>.pending
    local m="$1" sock="$WD/$1.sock" p=''
    { read -r p < "$sock.pending"; } 2>/dev/null
    case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && return 0 ;; esac
    rm -f "$sock" "$sock.route"
    wlog "start $m"
    (
      export FLEET_CONNECT_ROUTE_FILE="$sock.route"
      set -- "$m" -o ControlMaster=yes -o "ControlPath=$sock" -o ControlPersist=10m \
             -o SessionType=none -o ForkAfterAuthentication=yes -o StdinNull=yes -o BatchMode=yes \
             -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o ConnectTimeout=8 \
             -o "IPQoS=lowdelay throughput" -o Compression=no \
             -o ExitOnForwardFailure=no
      # ↑ a static forward another line already holds (issue #1775) costs the
      #   opener, never the warm master
      if [ -n "${FLEET_SHELL_WARM_CONNECT:-}" ]; then exec $FLEET_SHELL_WARM_CONNECT "$@"
      else exec python3 "$BIN/fleet-connect.py" "$@"; fi
    ) </dev/null >>"$WD/warm.log" 2>&1 &
    printf '%s\n' $! > "$sock.pending"
  }
  wstop() {    # <label>
    local sock="$WD/$1.sock"
    wlog "close $1"
    $SSHC -S "$sock" -O exit "$(whost "$1")" >/dev/null 2>&1
    rm -f "$sock" "$sock.route" "$sock.pending"
  }
  # riding <sock> — a window's proxy session is on it right now
  # (the stage's windows, issue #1759 — and a shell's own, started before it)
  riding() {
    { tmux -L "$s-stage" list-windows -t "=$s-stage" -F '#{@remote_ctl}' 2>/dev/null
      tmux -L "$s" list-windows -t "=$s" -F '#{@remote_ctl}' 2>/dev/null; } | grep -qxF "$1"
  }
  while :; do
    if ! tmux -L "$s" has-session -t "=$s" 2>/dev/null && [ -z "$once" ]; then
      for f in "$WD"/*.sock; do [ -e "$f" ] || continue; f=${f##*/}; wstop "${f%.sock}"; done
      rm -f "$WD/loop.pid"
      exit 0
    fi
    # standby (issue #1715): open nothing new; what is open lapses on its own
    if [ -f "${TMPDIR:-/tmp}/client.standby" ] && [ -z "$once" ]; then sleep "${FLEET_SHELL_WARM_EVERY:-5}"; continue; fi
    want=$(wanted)
    for m in $want; do walive "$m" || wstart "$m"; done
    for f in "$WD"/*.sock "$WD"/*.sock.pending; do
      [ -e "$f" ] || continue
      f=${f##*/}; m=${f%.pending}; m=${m%.sock}
      case " $(printf '%s ' $want)" in *" $m "*) continue ;; esac
      riding "$WD/$m.sock" && continue
      wstop "$m"
    done
    [ -n "$once" ] && exit 0
    sleep "${FLEET_SHELL_WARM_EVERY:-5}"
  done
  ;;
# ---------------------------------------------------------------------------------
wait)
  s="${2:-$SESS}"
  # What it says follows the hub's word on the person's login (issue #2220):
  # the `#account` line fleet-hub-sessions.sh writes into hub_repos — a login
  # being opened for a newcomer (#2069) is 「正在为你开机器」, a failed or
  # missing one names who to ask. No line (a login they hold, no hub, an older
  # hub): the note as before. Read again every second, redrawn on a change.
  hr="${FLEET_STATUS_G:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global}/hub_repos"
  said='' seen='' n=0
  while :; do
    st='' eta='' mach='' ask=''
    acct=$(awk -F $'\037' '$1 == "#account" { print $2 FS $3 FS $4 FS $5; exit }' "$hr" 2>/dev/null)
    [ -n "$acct" ] && IFS=$'\037' read -r st eta mach ask <<EOF
$acct
EOF
    case "$st" in
      opening) note=$(sh "$BIN/fleet-ui-lang.sh" t shell_wait_opening_fmt "${mach:-…}" "${eta:-60}") ;;
      failed)  note=$(sh "$BIN/fleet-ui-lang.sh" t shell_wait_failed_fmt "${ask:-?}") ;;
      none)    note=$(sh "$BIN/fleet-ui-lang.sh" t shell_wait_none_fmt "${ask:-?}") ;;
      # the home page (issue #2219): the pick was THIS computer and this login
      # has no fleet here — a client that only looks and hands out work, not a
      # failed connection: how to start, instead
      *)       if [ -n "${3:-}" ]; then note=$(sh "$BIN/fleet-ui-lang.sh" t shell_wait_home_fmt "$3")
               else note=$(sh "$BIN/fleet-ui-lang.sh" t shell_wait_nohost); fi ;;
    esac
    # a newcomer's first session that did not open (issue #2240): its three lines
    [ -s "$CACHE/home-first.failed" ] && note="$(sed '2,$s/^/  /' "$CACHE/home-first.failed")

  $note"
    note="$note
  $(sh "$BIN/fleet-ui-lang.sh" t shell_wait_leave)"
    if [ "$note" != "$said" ]; then
      printf '\033[H\033[2J\n  %s\n' "$note"
      said=$note
    fi
    # its own server's windows: the stage's (issue #1759), or — a shell started
    # before it — the shell's own. The stage comes up BEFORE the shell's server
    # (issue #2219): a shell not there yet is not a shell gone — up to 10 s of
    # grace, else this page closed at once and the viewer's restart showed another
    [ "$(tmux list-windows -F x 2>/dev/null | grep -c x)" -le 1 ] || exit 0
    if tmux -L "$s" has-session -t "=$s" 2>/dev/null; then seen=1
    elif [ -n "$seen" ] || [ "$n" -ge 10 ]; then exit 0; fi
    n=$((n + 1)); sleep 1
  done
  ;;
# ---------------------------------------------------------------------------------
# The writing area (issue #1953, EPIC #1949 C4): ONE stage window, told by its
# `@fleet_role portal` (never its name — the person may rename it), whose
# `@remote new` is the row key the list paints as 「新任务」 (`@remote` names no
# machine — no `<node>:` — so no machine's `open` ever retargets it). Made the
# first time, selected every time after: the draft lives in the pane and on disk
# (fleet-compose.py), so leaving and coming back loses nothing. The list is woken
# (F12) so its ▶ moves at once rather than on its next tick.
portal)
  s="${2:-$SESS}"
  SESS=$s; STAGE="$s-stage"; SHADOW=$BIN
  stage_up || exit 1
  # ⌘N again ON the writing area (issue #2146): the orchestrating session, no
  # draft — fleet-compose.py --orch, carry()'s own jump to orch_<sess>'s window.
  # From the orchestrator (or anywhere else) ⌘N is the writing area, as below. No
  # orchestrator: nothing changes — the writing area stays, no line.
  if [ "$(TS display-message -p -t "=$STAGE:" '#{@fleet_role}' 2>/dev/null)" = portal ] \
     && [ -s "${FLEET_STATUS_G:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global}/orch_$s" ] \
     && python3 "$BIN/fleet-compose.py" --orch "$s" >/dev/null 2>&1; then
    exit 0
  fi
  w=$(TS list-windows -t "=$STAGE" -F '#{window_id} #{@fleet_role}' 2>/dev/null | awk '$2 == "portal" { print $1; exit }')
  if [ -z "$w" ]; then
    w=$(TS new-window -d -P -F '#{window_id}' -t "=$STAGE:" -n "$(sh "$BIN/fleet-ui-lang.sh" t compose_title 2>/dev/null || echo 新任务)" -c "$HOME" \
          "exec python3 $(sq "$BIN/fleet-compose.py") --session $(sq "$s")") || exit 1
    # fleet_win_role_stamp's write, on the stage's socket (fleet-lib.sh is the
    # node's whole library; the one option is all this needs of it)
    TS set-window-option -t "$w" @fleet_role portal \; set-window-option -t "$w" @remote new \; \
      set-window-option -t "$w" @portal_ver "$(portal_ver)" \; \
      set-window-option -t "$w" automatic-rename off 2>/dev/null
  else
    portal_fresh "$w"       # made by an older client: on the new code (issue #2113)
  fi
  TS select-window -t "$w" 2>/dev/null || exit 1
  # ⌘N puts the three options back to their defaults (issue #2231): a private
  # ESC[928~ the area reads as «brought up» — the session in view may have changed
  TS send-keys -t "$w" -H 1b 5b 39 32 38 7e 2>/dev/null
  lp=$(T list-panes -a -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == 1 { print $1; exit }')
  [ -n "$lp" ] && T send-keys -t "$lp" F12 2>/dev/null
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# `keys` (issue #1952) opened the page of keys; it went with ⌘/ (issue #2362).
# A bind a running server still holds from an older conf calls it until the
# reload: it does nothing, rather than read `keys` as a machine to connect to.
# compat-1v: 下一批删
keys) exit 0 ;;
# ---------------------------------------------------------------------------------
# The right pane of `home` (issue #1759): a nested client of the stage — its
# TMUX unset, so tmux does not refuse the nesting. The stage gone (its last
# window closed) is started again with the `wait` note; the shell's server gone,
# this ends with it.
viewer)
  s="${2:-$SESS}"
  SESS=$s; STAGE="$s-stage"; SHADOW=$BIN
  while tmux -L "$s" has-session -t "=$s" 2>/dev/null; do
    if stage_up; then
      env -u TMUX -u TMUX_PANE tmux -L "$STAGE" attach-session -t "=$STAGE"
    else
      printf '\033[2J\033[H  fleet: 右侧起不来（%s）· 1 秒后再试\n' "$CACHE/tmux-stage.conf"
      sleep 1
    fi
    sleep 0.2
  done
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# A newer client into the RUNNING one (issue #1781): what
# fleet-client-update.sh `apply` runs, from the NEW client, right after it
# switched the install's link. The mirror again (onto the link, so it follows
# it), both confs written from the new templates and sourced into the two
# servers (the same servers, the same pids); the list drawn again where its
# code moved (its content stamp, VIEW_STAMP); a proxy pane respawned only when
# fleet-remote-view.sh itself changed (`--from <old home>` to compare with — no
# `--from`, none is); the warm loop, the actions loop, the data loop and the
# keeper restarted when their script changed or they run other code than the
# files' now (code_sum, issue #2345). `--all` (issue #1829: files that moved under the running
# client, so what it runs is unknown) counts every script as changed — every
# proxy pane respawned, every loop and the keeper restarted (`--in-keeper`: the
# keeper is the caller and restarts itself). Exit non-zero = the caller rolls back.
reload)
  s="${2:-$SESS}"; from='' all='' inkeeper=''
  shift 2 2>/dev/null || shift $#
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 2>/dev/null || shift $# ;;
      --all) all=1; shift ;;
      --in-keeper) inkeeper=1; shift ;;
      *) shift ;;
    esac
  done
  SESS=$s; STAGE="$s-stage"
  T has-session -t "=$SESS" 2>/dev/null || exit 0          # nothing running: nothing to reload
  mirror || exit 1
  [ -n "${FLEET_NODE_ALIASES:-}" ] \
    || FLEET_NODE_ALIASES=$(T show-environment -g FLEET_NODE_ALIASES 2>/dev/null | sed -n 's/^FLEET_NODE_ALIASES=//p')
  shell_env ''
  write_conf || exit 1
  iterm_keys
  T source-file "$CACHE/tmux.conf" || exit 1
  if TS has-session -t "=$STAGE" 2>/dev/null; then
    TS source-file "$CACHE/tmux-stage.conf" || exit 1
  fi
  layout_apply
  export_env
  T run-shell -b -t "=$SESS:" "bash $(sq "$SHADOW/fleet-sidebar.sh") sync '#{session_id}' >/dev/null 2>&1 || :"
  # changed <file> — that script is not what the old client ran
  changed() { [ -n "$all" ] || { [ -n "$from" ] && ! cmp -s "$from/bin/$1" "$REAL_BIN/$1"; }; }
  # stale <pid file> <file…> — that loop is running, and not on this code: what it
  # wrote at its start (<pid file>.code; none = a loop older than the stamp) is
  # not the files' now (issue #2345 — a reload with no `--from`, or one whose
  # old home already had these files, used to leave it on its old code)
  stale() {
    local pf="$1" p='' c=''
    shift
    { read -r p < "$pf"; } 2>/dev/null
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$p" 2>/dev/null || return 1
    { read -r c < "$pf.code"; } 2>/dev/null
    [ "$c" != "$(code_sum "$@")" ]
  }
  if changed fleet-remote-view.sh; then
    TS list-panes -s -t "=$STAGE" -F '#{pane_id} #{pane_start_command}' 2>/dev/null \
      | while read -r p c; do
          case "$c" in *fleet-remote-view.sh*) TS respawn-pane -k -t "$p" 2>/dev/null ;; esac
        done
  fi
  # the stage's long-lived windows (issue #2113): the writing area on the new
  # code when what it runs moved (its draft is on disk) — told by @fleet_role,
  # never a name. A keys page an older client opened (`keys`, issue #1952) is
  # closed: the page went with ⌘/ (issue #2362). compat-1v: 下一批删
  TS list-windows -t "=$STAGE" -F '#{window_id} #{@fleet_role}' 2>/dev/null \
    | while read -r w r; do
        case "$r" in
          portal) portal_fresh "$w" ${all:+--force} ;;
          keys)   TS kill-window -t "$w" 2>/dev/null ;;
        esac
      done
  # restart_loop <pid-file> <start command…> — that loop, on the new code
  restart_loop() {
    local pf="$1" p=''
    shift
    { read -r p < "$pf"; } 2>/dev/null
    case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
    rm -f "$pf"
    ( nohup "$@" </dev/null >/dev/null 2>&1 & )
  }
  if changed fleet-shell.sh || stale "$CACHE/tmp/warm/loop.pid" "$SHADOW/fleet-shell.sh"; then
    restart_loop "$CACHE/tmp/warm/loop.pid" bash "$SHADOW/fleet-shell.sh" warm "$SESS"
  fi
  if changed fleet-client-actions.py || stale "$CL_DIR/actions.pid" "$SHADOW/fleet-client-actions.py" "$SHADOW/fleet-client-lease.py"; then
    restart_loop "$CL_DIR/actions.pid" bash "$SHADOW/fleet-shell.sh" actions "$SESS"
  fi
  if changed fleet-hub-sessions.sh || changed fleet-lib.sh; then
    p=$(bash "$SHADOW/fleet-hub-sessions.sh" --status 2>/dev/null | sed -n 's/^loop \([0-9][0-9]*\).*/\1/p')
    [ -n "$p" ] && kill "$p" 2>/dev/null
    bash "$SHADOW/fleet-hub-sessions.sh" --ensure >/dev/null 2>&1 || :
  fi
  # the keeper too, when what it runs is unknown — a new one takes over once the
  # old one's pid is gone (one keeper per server)
  # (never the keeper this reload runs under — its update tick takes exit 4 and
  # execs itself on the new code)
  under() {   # under <pid> — this process descends from it
    local q=$$
    while [ "${q:-0}" -gt 1 ] 2>/dev/null; do
      [ "$q" = "$1" ] && return 0
      q=$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' ')
    done
    return 1
  }
  kp=''; { read -r kp < "$CL_DIR/keeper.pid"; } 2>/dev/null
  if [ -z "$inkeeper" ] && ! { [ -n "$kp" ] && under "$kp"; } \
     && { [ -n "$all" ] || stale "$CL_DIR/keeper.pid" "$SHADOW/fleet-shell.sh"; }; then
    restart_loop "$CL_DIR/keeper.pid" bash "$SHADOW/fleet-shell.sh" keeper "$SESS"
  fi
  stamp_ver
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# The client's layout, live (issue #2265): `@fleet_layout`, the server's
# FLEET_CLIENT_LAYOUT (what the list's next sync reads) and the stage's top
# line, then a sync. It does not write fleet.conf — remembering it is the caller's.
#   layout <auto|single|split|multi|solo> [<session>]      Exit 1: no client running.
layout)
  lay="${2:-}"
  case "$lay" in auto|single|split|multi|solo) ;; *) note 'layout: auto|single|split|multi|solo'; exit 2 ;; esac
  [ -n "${3:-}" ] && { SESS=$3; STAGE="$3-stage"; }
  T has-session -t "=$SESS" 2>/dev/null || exit 1
  layout_apply "$lay"
  T set-environment -g FLEET_CLIENT_LAYOUT "$lay" 2>/dev/null
  T run-shell -b -t "=$SESS:" "bash $(sq "$BIN/fleet-sidebar.sh") sync '#{session_id}' >/dev/null 2>&1 || :"
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# The sessions from the command line (issue #2365): `fleet ls | show | open |
# rename | close | reap | answer` (bin/fleet-session-cli.py) read the client's own
# rows and act through its hub identity, so they run with THIS server's
# environment — imported here as home-session does — and with TMUX naming its
# socket, so a bare `tmux` (the rows' producer, the list's queue) reaches it.
#   cli <verb> [args…]       Exit: the verb's; 1 when no client is running.
cli)
  shift
  T has-session -t "=$SESS" 2>/dev/null || { note "客户端没在运行（${SESS}）：先敲 fleet 打开它，⌃D / prefix d 离开后它仍在后台"; exit 1; }
  while IFS= read -r line; do
    case "$line" in FLEET_*=*|CCQUOTA_*=*|TMPDIR=*|XDG_*=*) export "${line?}" ;; esac
  done <<EOF
$(T show-environment -g 2>/dev/null)
EOF
  sock=$(T display-message -p '#{socket_path}' 2>/dev/null)
  [ -n "$sock" ] && TMUX="$sock,0,0" && export TMUX
  export FLEET_SHELL=1 FLEET_SESSION="$SESS" FLEET_CLIENT_DIR="$CL_DIR"
  exec python3 "$BIN/fleet-session-cli.py" "$@"
  ;;
# ---------------------------------------------------------------------------------
# A HOME session (issue #2264, EPIC #2259 共同约定 2) — `fleet claude` / `fleet codex`
# (bin/fleet-home-session.sh) and a newcomer's first session (`--first`, below):
# a session of no repo, in the machine's $HOME, with that agent. ONE road —
# fleet-client-place.sh `- home`, the hub's scratch + no_repo, which the node
# takes from its pool (#2233) or opens cold — signed by the lease THIS client
# holds, so the client must be up (rc 1 when it is not). The ask runs in the
# foreground and says what it is waiting for; once it is placed, a background
# step turns the stage onto it as soon as the list has its row. `--first` also
# puts the first-screen hint on the client's line.
#   home-session <claude|codex> [--node <m>] [--body-file <f>] [--first] [--no-stage]
# Exit: fleet-client-place.sh's code (0 placed); 1 no client here; 2 usage.
home-session)
  shift
  hagent="${1:-}"; [ $# -gt 0 ] && shift
  hnode=auto; hbody=''; hfirst=0; hnostage=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --node)      [ $# -ge 2 ] || exit 2; hnode="${2:-auto}"; shift 2 ;;
      --body-file) [ $# -ge 2 ] || exit 2; hbody="$2"; shift 2 ;;
      --first)     hfirst=1; shift ;;
      --no-stage)  hnostage=1; shift ;;
      *) note "home-session: unknown $1"; exit 2 ;;
    esac
  done
  case "$hagent" in claude|codex) ;; *) note 'home-session: claude or codex'; exit 2 ;; esac
  T has-session -t "=$SESS" 2>/dev/null || { note "客户端没在运行（${SESS}）"; exit 1; }
  # the server's environment (write_conf's set-environment lines): the hub, the
  # cache's TMPDIR (so $FLEET_C is the shell's), the stage — what a row's own
  # jump runs with
  while IFS= read -r line; do
    case "$line" in FLEET_*=*|CCQUOTA_*=*|TMPDIR=*|XDG_*=*) export "${line?}" ;; esac
  done <<EOF
$(T show-environment -g 2>/dev/null)
EOF
  export FLEET_CLIENT_DIR="$CL_DIR" FLEET_SESSION="$SESS"
  hopen=home_opening_fmt; [ "${FLEET_CLIENT_LAYOUT:-}" = solo ] && hopen=home_opening_solo_fmt
  note "$(sh "$BIN/fleet-ui-lang.sh" t "$hopen" "$hagent" 2>/dev/null)"
  # why THIS computer was not chosen (issue #2480), said after the failure line
  hwhy=$(mktemp "${TMPDIR:-/tmp}/fleet-place-why.XXXXXX" 2>/dev/null) || hwhy=''
  herr=$(mktemp "${TMPDIR:-/tmp}/fleet-place-err.XXXXXX" 2>/dev/null) || herr=/dev/null
  hout=$(FLEET_PLACE_WHY="$hwhy" bash "$BIN/fleet-client-place.sh" - home --agent "$hagent" --node "$hnode" ${hbody:+--body-file "$hbody"} 2>"$herr"); hrc=$?
  [ "$herr" = /dev/null ] || cat "$herr" >&2
  hline=$(printf '%s\n' "$hout" | tail -n1)
  if [ "$hrc" != 0 ]; then
    note "$(sh "$BIN/fleet-ui-lang.sh" t home_failed_fmt "${hline:-—}" 2>/dev/null)"
    if [ -n "$hwhy" ]; then
      while IFS= read -r line; do [ -n "$line" ] && note "$line"; done < "$hwhy"
    fi
    # FLEET_HOME_FAILED=<file> (issue #2240, first_home): why, in one line — the
    # place line's message, else what it said on stderr — then why THIS computer
    # was not chosen (#2480), each with what opens it
    if [ -n "${FLEET_HOME_FAILED:-}" ]; then
      hmsg=$(printf '%s' "$hline" | cut -f2 -s)
      [ -n "$hmsg" ] || hmsg=$hline
      [ -n "$hmsg" ] || hmsg=$(grep -v '^ *$' "$herr" 2>/dev/null | tail -n1)
      { printf '%s\n' "$hmsg"; [ -z "$hwhy" ] || grep -v '^ *$' "$hwhy"; } > "$FLEET_HOME_FAILED" 2>/dev/null
    fi
  fi
  [ -z "$hwhy" ] || rm -f "$hwhy"
  [ "$herr" = /dev/null ] || rm -f "$herr"
  [ "$hrc" = 0 ] || exit "$hrc"
  printf '%s\n' "$hline"
  # where it opened (issue #2339): the client's view machine (「入口选了 …」) and
  # the hub's placement are two choices — say the second, so one never reads as the other
  case "$hline" in REMOTE\ ?*) note "$(sh "$BIN/fleet-ui-lang.sh" t home_placed_fmt "$(printf '%s' "$hline" | awk '{ print $2 }')" 2>/dev/null)" ;; esac
  # a HOME session made: the newcomer's first is no longer owed (below)
  mkdir -p "$CONF_DIR" 2>/dev/null && : > "$CONF_DIR/home-session.first"
  # its row key: `REMOTE <m> <op> done <worker_id>` → wid:<worker_id>; with no hub
  # (`LOCAL <host>\t<window id> …`) the local list's own @<id>
  hkey=''
  case "$hline" in
    REMOTE\ *) hkey=$(printf '%s' "${hline%%$'\t'*}" | awk '{ print $5 }'); case "$hkey" in */*) hkey="wid:$hkey" ;; *) hkey='' ;; esac ;;
    LOCAL\ *)  hkey=$(printf '%s' "${hline#*$'\t'}" | awk '{ print $1 }'); case "$hkey" in @[0-9]*) ;; *) hkey='' ;; esac ;;
  esac
  # `fleet claude`'s own view shows it (--no-stage, issue #2349): the client's
  # stage stays on what it shows
  [ -n "$hnostage" ] && exit 0
  # the stage onto it, in the background: a placed session reaches the list on
  # the hub loop's next read; give up after FLEET_HOME_OPEN_WAIT (60 s), leaving
  # it on the list. FLEET_HOME_OPEN_CMD is the selftests' seam.
  (
    cd "$HOME" 2>/dev/null || :; trap '' HUP
    rf="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/remote_$SESS"
    n=$(( ${FLEET_HOME_OPEN_WAIT:-60} * 4 )); i=0
    case "$hkey" in
      wid:*)
        while [ "$i" -lt "$n" ]; do
          LC_ALL=C awk -F $'\037' -v k="$hkey" '$1 == k { f = 1; exit } END { exit !f }' "$rf" 2>/dev/null && break
          sleep 0.25; i=$((i + 1))
        done
        [ "$i" -lt "$n" ] && ${FLEET_HOME_OPEN_CMD:-bash "$BIN/fleet-remote-view.sh" open} "$hkey" >/dev/null 2>&1 ;;
    esac
    # the list: woken so its ▶ follows at once — and, for a local row, told the
    # jump itself (fleet-compose.py's hand: @sidebar_do + F12)
    lp=$(T list-panes -a -F '#{pane_id} #{@sidebar}' 2>/dev/null | awk '$2 == 1 { print $1; exit }')
    if [ -n "$lp" ]; then
      case "$hkey" in @*) T set-option -pa -t "$lp" @sidebar_do "jump=$hkey " 2>/dev/null ;; esac
      T send-keys -t "$lp" F12 2>/dev/null
    fi
    if [ "$hfirst" = 1 ]; then
      T display-message -d 15000 "$(sh "$BIN/fleet-ui-lang.sh" t home_first_hint 2>/dev/null)" 2>/dev/null
    fi
  ) </dev/null >/dev/null 2>&1 &
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# 退出 fleet (issue #2349) — not 放到后台 (prefix d / closing the window / the
# one-session view's ⌃D, after which everything runs on and `fleet` is back at
# once): every process of the CLIENT on this computer goes — the keeper (and
# with it the lease, given back here, so the next client anywhere takes nothing
# over), the hub loop, the actions loop, the warm loop and its ssh masters, the
# shell's server with the list and the bar, the stage with its connections.
# The sessions on the machines are not touched: a closed proxy only drops its
# connection. No question first — nothing is lost. `fleet quit`, ⌘Q / prefix Q,
# the last line of ⌘K and of the row menu. A call from inside the client (a key,
# a menu: its own server runs it) goes on in the background, since what runs it
# is about to go.
#   quit [<session>] [--quiet] [--if-unattached]   Exit 0 (also when nothing was
#                          running; --if-unattached: nothing while a terminal is on it).
quit)
  shift
  qquiet=''; qifun=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) qquiet=1; shift ;;
      --if-unattached) qifun=1; shift ;;   # `fleet claude`'s own: a client someone uses stays
      -*) note "quit: unknown $1"; exit 2 ;;
      *) SESS=$1; STAGE="$1-stage"; shift ;;
    esac
  done
  if [ -n "${TMUX:-}" ] && [ "${TMUX%%,*}" = "$(T display-message -p '#{socket_path}' 2>/dev/null)" ]; then
    ( trap '' HUP; cd "$HOME" 2>/dev/null || :
      nohup env -u TMUX -u TMUX_PANE bash "$SELF" quit "$SESS" --quiet </dev/null >/dev/null 2>&1 & )
    exit 0
  fi
  qrun=''; T has-session -t "=$SESS" 2>/dev/null && qrun=1
  [ -n "$qifun" ] && [ -n "$(T list-clients -F '#{client_name}' 2>/dev/null)" ] && exit 0
  # the server's environment: the hub, the device's certificate, the cache's
  # TMPDIR — what the keeper gives the lease back with
  if [ -n "$qrun" ]; then
    while IFS= read -r line; do
      case "$line" in FLEET_*=*|CCQUOTA_*=*|TMPDIR=*|XDG_*=*) export "${line?}" ;; esac
    done <<EOF
$(T show-environment -g 2>/dev/null)
EOF
  fi
  export TMPDIR="$CL_DIR"
  # the machines the sessions are on, read before the list's cache goes quiet
  qnodes=$(LC_ALL=C awk -F $'\037' '$1 ~ /^wid:/ && $2 != "" { print $2 }' \
             "$CL_DIR/.claude-dash/global/remote_$SESS" 2>/dev/null | sort -u | paste -sd / -)
  # qkill <pid file> <argv pattern> — that loop, when the pid is still it
  qkill() {
    local p='' c
    { read -r p < "$1"; } 2>/dev/null
    case "$p" in ''|*[!0-9]*) return 0 ;; esac
    c=$(ps -o command= -p "$p" 2>/dev/null) || c=''
    case "$c" in *$2*) kill "$p" 2>/dev/null ;; esac
    rm -f "$1"
  }
  # 1. the keeper first, so nothing renews what is given back here
  qkill "$CL_DIR/keeper.pid" 'fleet-shell.sh keeper'
  id=''; { read -r id < "$CL_DIR/client.lease"; } 2>/dev/null
  [ -n "$id" ] && lease release --lease "$id"
  rm -f "$CL_DIR/client.lease" "$CL_DIR/client.lease.old" "$CL_DIR/client.standby" "$CL_DIR/client.nohub" "$CL_DIR/client.where.json" "$CL_DIR/client.key" "$CL_DIR/client.list.json" "$CL_DIR/client.why" "$CL_DIR/client.rescan"
  # 2. the loops beside it, and the warm lines (closed, not left to ControlPersist)
  qkill "$CL_DIR/.claude-dash/global/hubsess.pid" 'fleet-hub-sessions.sh'
  qkill "$CL_DIR/actions.pid" 'fleet-client-actions.py'
  qkill "$CL_DIR/warm/loop.pid" 'fleet-shell.sh warm'
  for sk in "$CL_DIR"/warm/*.sock; do
    [ -S "$sk" ] && ssh -S "$sk" -O exit fleet >/dev/null 2>&1
    rm -f "$sk" "$sk.pending"
  done
  # 3. the two servers — the client's own, never a fleet's
  T kill-server 2>/dev/null
  TS kill-server 2>/dev/null
  if [ -z "$qquiet" ]; then
    if [ -z "$qrun" ]; then sh "$BIN/fleet-ui-lang.sh" t quit_none
    elif [ -n "$qnodes" ]; then sh "$BIN/fleet-ui-lang.sh" t quit_done_fmt "$qnodes"
    else sh "$BIN/fleet-ui-lang.sh" t quit_done; fi
    echo
  fi
  exit 0
  ;;
# ---------------------------------------------------------------------------------
# Whether the client runs here (issue #2349) — `fleet status`'s line with --say.
#   running [<session>] [--say]      Exit 0 it does, 1 it does not.
running)
  shift; rsay=''
  for a in "$@"; do case "$a" in --say) rsay=1 ;; *) SESS=$a; STAGE="$a-stage" ;; esac; done
  if T has-session -t "=$SESS" 2>/dev/null; then
    [ -n "$rsay" ] && { sh "$BIN/fleet-ui-lang.sh" t client_bg; echo; }
    exit 0
  fi
  [ -n "$rsay" ] && { sh "$BIN/fleet-ui-lang.sh" t client_off; echo; }
  exit 1
  ;;
# ---------------------------------------------------------------------------------
# `fleet claude` / `fleet codex`'s OWN view (issue #2349): one session, the whole
# terminal — no list, no top line, one bottom line 「⌃D 放到后台 · /exit 结束会话」
# with the machine on the right. It is not the client's layout (FLEET_CLIENT_LAYOUT
# is neither read nor written) and not its stage: a tmux server of its own,
# `-L <session>-solo-<pid>`, made from the stage's conf (its environment, its
# ssh) with this view's bar over it, holding ONE proxy window pinned to that
# session (fleet-remote-view.sh run --shell <machine> <worker id>) — so the
# client's own view, open in another terminal or not, never moves with it.
# Beside it, for as long as it lives and no longer, a watcher reads the row off
# the client's list cache: the session going `exited` (the agent's /exit) while
# watched ends the view. The attach returns either way — ⌃D, prefix d, closing
# the terminal, the session ending — and the server goes with it; the terminal
# gets one line: 「会话已结束（m5）」 or 「会话在后台继续（m5）。`fleet` 可以找回。」
# The client must be up: its warm lines and its list's cache are what this rides.
#   solo <machine> <worker id> [<session>]     Exit 0; 1 no client; 2 usage.
#   FLEET_SOLO_ATTACH=0 (the selftests): start it, print its socket, no attach.
solo)
  snode="${2:-}"; swid="${3:-}"
  [ -n "${4:-}" ] && { SESS=$4; STAGE="$4-stage"; }
  case "$snode" in ''|*[!A-Za-z0-9._-]*) note 'solo: <machine> <worker id>'; exit 2 ;; esac
  case "$swid" in ''|*[!A-Za-z0-9._/@:-]*) note 'solo: <machine> <worker id>'; exit 2 ;; esac
  T has-session -t "=$SESS" 2>/dev/null || { note "客户端没在运行（$SESS）"; exit 1; }
  [ -f "$CACHE/tmux-stage.conf" ] || { note "缺 $CACHE/tmux-stage.conf"; exit 1; }
  SOLO="$SESS-solo-$$"
  SB=$BIN; [ -x "$CACHE/bin/fleet-remote-view.sh" ] && SB="$CACHE/bin"
  OV="$CACHE/tmux-solo.$$.conf"
  # the bar's two lines — the session's, and the local shell's (⌃\, issue #2566):
  # each `key words` part with its key bold, as one tmux format (a `\` doubled
  # for the conf's double quotes)
  solo_bar() {
    local rest="$1 · " part out=''
    while [ -n "$rest" ]; do
      part=${rest%% · *}; rest=${rest#* · }
      [ -n "$out" ] && out="$out · "
      out="$out#[fg=#c0caf5]#[bold]${part%% *}#[nobold]#[fg=#565f89] ${part#* }"
    done
    printf '%s' "${out//\\/\\\\}"
  }
  bar=$(solo_bar "$(sh "$SB/fleet-ui-lang.sh" t solo_view_bar 2>/dev/null)")
  sbar=$(solo_bar "$(sh "$SB/fleet-ui-lang.sh" t solo_view_bar_shell 2>/dev/null)")
  # ⌃\'s shell (issue #2566): THIS computer, this login, in $HOME, with the
  # fleet's own commands on its PATH (a `'` in it would end the conf's quotes)
  spath="$HOME/.local/bin:$SB:$PATH"; spath=${spath//\'/}
  # ONE conf, read at the server's start: the stage's (its environment, its ssh)
  # with this view's bar after it — so not one line of the stage's top line
  # (fleet-topbar.py, the client's record) ever runs on this server
  { cat "$CACHE/tmux-stage.conf"; cat <<EOF
# fleet-shell.sh solo (issue #2349): this view's bar over the stage's conf
set -g status on
set -g status-position bottom
set -g status-interval 0
set -g status-style "bg=#1a1b26,fg=#565f89"
set -g status-left-length 200
set -g status-left " #[range=user|bg]#{?#{@solo_shell},${sbar},${bar}}#[norange]#[default]"
set -g status-right "#[fg=#565f89]$snode "
set -g status-right-length 40
set -g pane-border-status off
bind -n MouseDown1Status if -F '#{==:#{mouse_status_range},bg}' { detach-client }
bind -n C-d detach-client
# ⌃\\ (issue #2566, EPIC #2563 共同约定 5): to a shell on THIS computer and back —
# the view's second window, made on the first press (\`@solo_shell\`), then the
# two windows in turn; the session's own window and its connection never move.
# Its \`exit\` closes it, and the next press makes a new one.
bind -n 'C-\\' if -F '#{W:#{?#{@solo_shell},1,}}' { last-window } { new-window -n 本机shell -c '$HOME' -e 'PATH=$spath' ; set-window-option @solo_shell 1 }
# the client's prefix, with TWO keys: d, to the background as everywhere, and
# \\ — ⌃\\ for a keyboard that has no ⌃\\ (an iPad's Blink)
set -g prefix $PREFIX
unbind -a -T prefix
bind d detach-client
bind '\\' if -F '#{W:#{?#{@solo_shell},1,}}' { last-window } { new-window -n 本机shell -c '$HOME' -e 'PATH=$spath' ; set-window-option @solo_shell 1 }
EOF
  } > "$OV" || { note "写不了 $OV"; exit 1; }
  sw=$(tmux -L "$SOLO" -f "$OV" new-session -d -P -F '#{window_id}' -s "$SOLO" -n "$snode" -c "$HOME" \
         -x "$(tput cols 2>/dev/null || echo 180)" -y "$(tput lines 2>/dev/null || echo 50)" \
         "exec bash $(sq "$SB/fleet-remote-view.sh") run --shell $(sq "$snode") $(sq "$swid")") \
    || { rm -f "$OV"; note 'tmux 开不了会话'; exit 1; }
  tmux -L "$SOLO" set-window-option -t "$sw" @remote "$snode:$swid" \; \
    set-window-option -t "$sw" automatic-rename off 2>/dev/null
  rm -f "$OV"
  ended="$CL_DIR/solo-ended.$SOLO"; rm -f "$ended"; smain=$$
  [ "${FLEET_SOLO_ATTACH:-1}" = 0 ] && smain=''   # no attach to outlive: the caller ends it
  # the watcher: the row's state off the list's cache, once a second, while the
  # view lives — a change to `exited` it SAW ends the view (opening a session
  # already exited is no exit, as the client's own solo_ended)
  (
    trap '' HUP; cd "$HOME" 2>/dev/null || :
    rf="$CL_DIR/.claude-dash/global/remote_$SESS"; prev=''
    while tmux -L "$SOLO" has-session -t "=$SOLO" 2>/dev/null; do
      # the view's own process gone without its cleanup (SIGKILLed): the view too
      [ -z "$smain" ] || kill -0 "$smain" 2>/dev/null || { tmux -L "$SOLO" kill-server 2>/dev/null; break; }
      st=$(LC_ALL=C awk -F $'\037' -v k="wid:$swid" '$1 == k { print $6; exit }' "$rf" 2>/dev/null)
      if [ "$st" = exited ] && [ -n "$prev" ] && [ "$prev" != exited ]; then
        printf '%s\n' "$snode" > "$ended"
        tmux -L "$SOLO" detach-client -s "=$SOLO" 2>/dev/null
        break
      fi
      [ -n "$st" ] && prev=$st
      sleep "${FLEET_SOLO_WATCH_EVERY:-1}"
    done
  ) </dev/null >/dev/null 2>&1 &
  swatch=$!
  if [ "${FLEET_SOLO_ATTACH:-1}" = 0 ]; then printf '%s\n' "$SOLO"; exit 0; fi
  # the terminal closed under it (a HUP): the view goes all the same, silently
  trap 'kill "$swatch" 2>/dev/null; tmux -L "$SOLO" kill-server 2>/dev/null; rm -f "$ended"; exit 0' HUP TERM
  env -u TMUX -u TMUX_PANE tmux -L "$SOLO" attach-session -t "=$SOLO"
  trap - HUP TERM
  # whatever ended the attach, the view goes: its connection drops, the session
  # on its machine never notices
  kill "$swatch" 2>/dev/null
  tmux -L "$SOLO" kill-server 2>/dev/null
  if [ -s "$ended" ]; then sh "$SB/fleet-ui-lang.sh" t solo_view_ended_fmt "$snode"
  else sh "$SB/fleet-ui-lang.sh" t solo_view_left_fmt "$snode"; fi
  echo
  rm -f "$ended"
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
  exit 1
fi
command -v python3 >/dev/null 2>&1 || fail_start '没有 python3'

# 1. the certificate and the machine (fleet-connect.py --pick: renew or scan, then
#    the hub's pick — or the name checked against the route list). No hub URL
#    (#1712): THIS computer, reason `local` — the client reads this machine. None
#    online: exit 1 from it, the shell still opens (the list and the bar come
#    from the hub; a row opens a window).
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
iterm_keys

# team_check — the hub's team layer (issue #1726, EPIC #1718 C8): its version
# moved since the last start → composed again (fleet default < team < local), in
# the background, never in the way of the start. $BIN may be the conf-free
# mirror, so the package root is the script's REAL directory's parent. A computer
# with the full install (~/.claude/fleet) leaves it to that install's tick; no
# hub is nothing at all (exit 3, no file written).
team_check() {
  local tt root nr sr=()
  tt="$BIN/fleet-agent-team.py"
  [ -f "$tt" ] || return 0
  root=$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$tt") || return 0
  nr="${FLEET_INSTALL_NODE_ROOT:-$HOME/.claude/fleet}"
  if [ "$(cd "$root" && pwd -P)" != "$(cd "$nr" 2>/dev/null && pwd -P)" ]; then
    [ -f "$nr/bin/fleet-lib.sh" ] && return 0
    sr=(--scripts-root "$root")
  fi
  mkdir -p "$CACHE" 2>/dev/null
  ( nohup python3 "$root/bin/fleet-agent-team.py" sync --root "$root" ${sr[@]+"${sr[@]}"} </dev/null >"$CACHE/team.log" 2>&1 & )
}
team_check

# client_open — this run is a client (issue #1715): its device remembered for
# its tty (the name tmux gives its client), a lease taken (or this server's kept),
# the clients already attached here left working (#1932). A hub out of reach
# does not stop the start: the keeper takes the lease on its next tick.
client_open() {
  local dev tt
  tt=$(tty 2>/dev/null) || tt=''
  case "$tt" in /dev/*) ;; *) tt='' ;; esac
  mkdir -p "$CL_DIR/client.where" 2>/dev/null
  # the whole where saved for this tty (#1716): the lease carries it, and a
  # take-back from the standby screen hands the same again. No tty: saved all
  # the same (under notty), so client.where.json — what every renewal carries
  # (#1995) — is the whole of it, not the device alone
  dev=$($LEASE_CMD device --save "$(where_file "${tt:-notty}")" 2>/dev/null) || dev=''
  rm -f "$CL_DIR/client.nohub"
  client_take "${tt:-notty}" "${dev%%$'\t'*}" "$(printf '%s' "$dev" | cut -f2 -s)" && return 0
  rm -f "$CL_DIR/client.standby"
  mkdir -p "$CL_DIR/client.dev" 2>/dev/null
  [ -n "$tt" ] && printf '%s\n' "${dev%%$'\t'*}" > "$CL_DIR/client.dev/$(cl_key "$tt")"
  where_now "$tt" "${dev%%$'\t'*}" "$(printf '%s' "$dev" | cut -f2 -s)"
}

# first_home — a newcomer's first session (issue #2264, EPIC #2259 共同约定 1 + 2):
# a client set to `solo` (what a fresh install writes) opens ONE HOME Claude
# session, in the background, the first time it starts — `home-session.first` in
# the conf dir says it is done, and any HOME session made (`fleet claude` too)
# writes it. An existing install (no `solo`) never sees it; fleet-home-session.sh
# opens its own and says FLEET_SHELL_NO_FIRST. One at a time: a lock dir, taken
# over once it is older than a place can take.
#
# Not opened (issue #2240): the screen says so, not only home-first.log — three
# lines in home-first.failed (没开出来 · 原因 · 下一步), drawn by the solo view's
# `wait` page and put on the client's line, and ONE retry after
# FLEET_HOME_FIRST_RETRY (60) seconds unless a HOME session was made meanwhile.
first_home() {
  local lock="$CACHE/home-first.lock"
  [ "${FLEET_CLIENT_LAYOUT:-}" = solo ] || return 0
  [ "${FLEET_SHELL_NO_FIRST:-0}" != 1 ] || return 0
  [ ! -e "$CONF_DIR/home-session.first" ] || return 0
  mkdir -p "$CACHE" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || return 0
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 0
  fi
  ( trap '' HUP; cd "$HOME" 2>/dev/null || :
    failed="$CACHE/home-first.failed"; retry="${FLEET_HOME_FIRST_RETRY:-60}"; try=1
    rm -f "$failed" "$failed.why"
    while :; do
      if FLEET_HOME_FAILED="$failed.why" bash "$SHADOW/fleet-shell.sh" home-session claude --first; then
        rm -f "$failed" "$failed.why"; break
      fi
      why=$(sed -n 1p "$failed.why" 2>/dev/null); nxt=$(sed -n 2p "$failed.why" 2>/dev/null)
      [ -n "$why" ] || why='-'
      # (no multibyte text inside ${v:+…}: bash 3.2 mangles it)
      if [ "$try" = 1 ]; then
        rtxt=$(sh "$BIN/fleet-ui-lang.sh" t home_first_retry_fmt "$retry" 2>/dev/null)
        if [ -n "$nxt" ]; then nxt="$nxt; $rtxt"; else nxt=$rtxt; fi
      elif [ -z "$nxt" ]; then nxt=$(sh "$BIN/fleet-ui-lang.sh" t home_first_next 2>/dev/null); fi
      { sh "$BIN/fleet-ui-lang.sh" t home_first_failed; echo
        sh "$BIN/fleet-ui-lang.sh" t home_first_why_fmt "$why"; echo
        sh "$BIN/fleet-ui-lang.sh" t home_first_next_fmt "$nxt"; echo; } > "$failed" 2>/dev/null
      cat "$failed"
      T display-message -d 60000 "$(paste -sd '|' "$failed" | sed 's/|/ · /g')" 2>/dev/null
      [ "$try" = 1 ] || break
      try=2; sleep "$retry"
      [ ! -e "$CONF_DIR/home-session.first" ] || { rm -f "$failed" "$failed.why"; break; }
    done
    rm -f "$failed.why"; rmdir "$lock" 2>/dev/null
  ) </dev/null >"$CACHE/home-first.log" 2>&1 &
}

# 2. already running? Re-attach — onto the named machine's window when there is one.
if T has-session -t "=$SESS" 2>/dev/null; then
  if [ -n "$(T show-options -wqv -t "=$SESS:" @shell_frame 2>/dev/null)" ]; then
    # the stage (issue #1759): the named machine's window current there
    [ -n "$node" ] && stage_select "$node"
  elif [ -n "$node" ]; then
    # a shell started before the stage: one window per machine on its own server
    w=$(T list-windows -t "=$SESS" -F '#{window_id} #{@remote}' 2>/dev/null | awk -v n="$node:" 'index($2, n) == 1 { print $1; exit }')
    [ -n "$w" ] && T select-window -t "$w" 2>/dev/null
  fi
  layout_apply
  client_open
  ( nohup bash "$SHADOW/fleet-shell.sh" keeper "$SESS" </dev/null >/dev/null 2>&1 & )
  ( nohup bash "$SHADOW/fleet-shell.sh" warm "$SESS" </dev/null >/dev/null 2>&1 & )
  ( nohup bash "$SHADOW/fleet-shell.sh" actions "$SESS" </dev/null >/dev/null 2>&1 & )
  first_home
  client_where
  [ "${FLEET_SHELL_NO_ATTACH:-0}" = 1 ] && { printf '%s\n' "$SESS"; exit 0; }
  attach_client
fi

# the one-session view comes back to the row it left (issue #2265): read before
# the new list writes its first visit
solo_key=''; solo_since=$(date +%s)
[ "${FLEET_CLIENT_LAYOUT:-}" = solo ] && solo_key=$(solo_last)
# 3. the servers: conf (keys, hooks, bar, environment); the stage with the first
#    machine's window (issue #1759), then the shell's one window, `home`, whose
#    right pane looks at the stage
write_conf || fail_start "写不了 $CACHE/tmux.conf"
# The pick is THIS computer but this login has no fleet here (issue #2219: a
# newcomer's 「只看、只派」 client on the machine the hub knows them by): no
# connection that can only fail with 「没有活着的 fleet 会话」 — the home page,
# how to start, in its place.
home=''
if [ -n "$node" ] && this_machine "$node" && ! bash "$SHADOW/fleet-remote-view.sh" live >/dev/null 2>&1; then
  home=$node; node=''
fi
if [ -n "$home" ]; then printf '%s\n' "$home" > "$CACHE/home-machine"; else rm -f "$CACHE/home-machine"; fi
if [ -n "$node" ]; then
  title="$node"
  cmd="exec bash $(sq "$SHADOW/fleet-remote-view.sh") run --shell $(sq "$node") -"
  remote="$node:"
elif [ -n "$home" ]; then
  title="fleet"
  cmd="exec bash $(sq "$SHADOW/fleet-shell.sh") wait $(sq "$SESS") $(sq "$home")"
  remote="-:"
else
  title="fleet"   # no machine picked yet; known by @remote=-:, not the name (#1621)
  cmd=''          # stage_up's default: the `wait` note
  remote="-:"
fi
if TS has-session -t "=$STAGE" 2>/dev/null; then
  # a stage the last shell left (its keeper ends it, but not if it was killed):
  # its connections are kept, its conf is read again
  TS source-file "$CACHE/tmux-stage.conf" >/dev/null 2>&1
  [ -n "$node" ] && { stage_select "$node" || TS new-window -t "=$STAGE:" -n "$title" -c "$HOME" "$cmd" \; \
    set-window-option @remote "$remote" \; set-window-option automatic-rename off >/dev/null 2>&1; }
else
  stage_up "$cmd" "$remote" "$title" || fail_start 'tmux 开不了会话'
fi
w=$(tmux -L "$SESS" -f "$CACHE/tmux.conf" new-session -d -P -F '#{window_id}' -s "$SESS" -n home -c "$HOME" -x 220 -y 60 \
      "exec bash $(sq "$SHADOW/fleet-shell.sh") viewer $(sq "$SESS")") \
  || fail_start 'tmux 开不了会话'
T set-window-option -t "$w" @shell_frame 1 \; set-window-option -t "$w" automatic-rename off \; \
  set-option -p -t "$w" @shell_viewer 1 \; set-option -p -t "$w" remain-on-exit on 2>/dev/null
layout_apply
stamp_ver
# the right pane outlives whatever ends it (issue #1785): kept dead, the hooks'
# sync respawns it (fleet-sidebar.py heal_frame) — the window, so the server,
# never closes under the person
# 4. the lease (#1715) before anything renews it; the data: the refresh loop,
#    kept alive while the server lives; the warm connections (#1631) beside it
client_open
( nohup bash "$SHADOW/fleet-shell.sh" keeper "$SESS" </dev/null >/dev/null 2>&1 & )
( nohup bash "$SHADOW/fleet-shell.sh" warm "$SESS" </dev/null >/dev/null 2>&1 & )
( nohup bash "$SHADOW/fleet-shell.sh" actions "$SESS" </dev/null >/dev/null 2>&1 & )
# 登录即登记 (issue #2212): a logged-in computer with no node token yet takes
# its node pass by the device key, in the background — no scan, no output
[ -f "$BIN/fleet-node.sh" ] && ( nohup bash "$BIN/fleet-node.sh" ensure </dev/null >/dev/null 2>&1 & )
first_home
solo_resume "$solo_key" "$solo_since"
client_where
[ "${FLEET_SHELL_NO_ATTACH:-0}" = 1 ] && { printf '%s\n' "$SESS"; exit 0; }
attach_client
