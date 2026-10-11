#!/bin/bash
# fleet-view-peer-rig.sh — SOURCED, never run: three machines on one box for the
# peer-window tests (issue #2751, EPIC #2999 C4) — bin/fleet-view-peer-selftest.sh
# and the peer-window-* drills of bin/fleet-break-it-peerlink-selftest.sh.
#
#   home   the thin client's home: fleet session $PR_HS on `-L $PR_HS`, workers
#          l1 l2, the C5 keeper (fleet-peerlink.py run) and a 看台 `v1` attached
#          from a TERMINAL server (`-L $PR_TL`, its pane = the person's screen)
#   far1   another machine: fleet session $PR_FS1, workers a b + an orchestrator
#   far2   a third: fleet session $PR_FS2, worker c
#
# Each machine is its own FLEET_CONF_DIR / TMPDIR / HOME (`pr_env <m>` prints them as
# `env` arguments) with its own machine id, so its fleet UUID ($PR_U_<m>) is its own.
# No network, no sshd: `$PR_WORK/ssh.sh` plays ssh — a master and `-O` go to
# bin/fleet-peerlink-fake-ssh.py (a process serving its -S socket), a channel needs
# that socket and runs its command HERE as the far machine (`pr_env <host>`), so
# `fleet-remote-view.sh attach --thin` / `select` really run on that machine's
# server. Its tty is the caller's, as with `ssh -tt`.
#
# Needs BIN, PR_WORK (empty dir) and REAL_TMUX set (PR_TAG: a suffix for the socket
# labels, before sourcing); `pr_up` builds it, `pr_down` takes every server and
# process away.
# the socket labels: unique per rig (PR_TAG, a drill's own) so two never meet
PR_HS="prH${PR_TAG:-$$}"; PR_FS1="prA${PR_TAG:-$$}"; PR_FS2="prB${PR_TAG:-$$}"; PR_TL="prT${PR_TAG:-$$}"
PR_US=$'\037'
# what pr_machine / pr_up fill in (fleet UUIDs, window ids) — named here so a
# reader (and shellcheck) sees them assigned
# shellcheck disable=SC2034  # read by the scripts that source this
PR_U_home='' PR_U_far1='' PR_U_far2='' PR_W_home_l1='' PR_W_home_l2='' PR_KP=''
PR_ME=$(id -un)

pr_env() {   # <machine> — its environment, as `env` arguments
  local d="$PR_WORK/m/$1"
  printf 'FLEET_CONF_DIR=%s TMPDIR=%s HOME=%s FLEET_SIDEBAR_HOST=%s FLEET_PEERLINK_HOME=%s FLEET_UI_LANG=zh' \
    "$d/conf" "$d/tmp" "$d/home" "$1" "$1"
  printf ' FLEET_PEERLINK_SSH=%s FLEET_PEERLINK_CERT_CMD=%s FLEET_REMOTE_BIN=%s FAKESSH_DIR=%s PR_WORK=%s PR_BIN=%s' \
    "$PR_WORK/ssh.sh" "$PR_WORK/cert.sh" "$BIN" "$PR_WORK/fs" "$PR_WORK" "$BIN"
  printf ' FLEET_PEERLINK_TICK=%s FLEET_VIEW_KEEP_SECS=%s LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8\n' \
    "${PR_TICK:-0.5}" "${PR_KEEP:-600}"
}
pr_t() { local m="$1"; shift; "$REAL_TMUX" -L "$(pr_sock "$m")" "$@"; }
pr_sock() { case "$1" in home) printf '%s' "$PR_HS" ;; far1) printf '%s' "$PR_FS1" ;; far2) printf '%s' "$PR_FS2" ;; term) printf '%s' "$PR_TL" ;; esac; }
# shellcheck disable=SC2046  # pr_env's words ARE the env arguments
pr_in() { local m="$1"; shift; env -u TMUX -u TMUX_PANE $(pr_env "$m") "$@"; }   # run as <machine>

# pr_machine <label> <machine id> <window>… — a fleet session whose windows each
# print `SCREEN-<label>-<window>` and sleep; `orch` is the orchestrator.
pr_machine() {
  local m="$1" mid="$2" s d w wid u; shift 2
  s=$(pr_sock "$m"); d="$PR_WORK/m/$m"
  mkdir -p "$d/conf/control" "$d/conf/fleets/$s" "$d/tmp/.claude-dash/global" "$d/home"
  printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$d/main" > "$d/conf/fleets/$s/conf"
  python3 - "$d/conf/control/state.sqlite3" "$mid" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
c.execute("INSERT INTO metadata VALUES ('machine_id', ?)", (sys.argv[2],)); c.commit()
PY
  pr_in "$m" "$REAL_TMUX" -L "$s" -f /dev/null new-session -d -s "$s" -n home -x 160 -y 40 \
    "printf 'SCREEN-$m-home\n'; while :; do sleep 300; done" || return 1
  pr_t "$m" set-option -g status off
  for w in "$@"; do
    wid=$(pr_t "$m" new-window -d -P -F '#{window_id}' -t "=$s:" -n "$w" "printf 'SCREEN-$m-$w\n'; while :; do sleep 300; done")
    if [ "$w" = orch ]; then pr_t "$m" set-option -w -t "$wid" @fleet_role orchestrator \; set-option -w -t "$wid" @fleet_id "fid-$w"
    else pr_t "$m" set-option -w -t "$wid" @fleet_role worker \; set-option -w -t "$wid" @fleet_id "fid-$w"; fi
    eval "PR_W_${m}_$w=\$wid"
  done
  u=$(pr_in "$m" bash -c '. "$1/fleet-lib.sh"; fleet_uuid "$2"' _ "$BIN" "$s")
  [ -n "$u" ] || return 1
  eval "PR_U_$m=\$u"
}

pr_up() {
  mkdir -p "$PR_WORK/fs/down" "$PR_WORK/fs/login" "$PR_WORK/down"
  cat > "$PR_WORK/ssh.sh" <<'EOF'
#!/bin/bash
# a master or a control command: the fake ssh
case " $* " in *" -M "*|*" -O "*) exec python3 "$PR_BIN/fleet-peerlink-fake-ssh.py" "$@" ;; esac
sock=''
while [ $# -gt 0 ]; do
  case "$1" in -S) sock=$2; shift 2 ;; -l|-o|-i|-p|-F|-E) shift 2 ;; -*) shift ;; *) break ;; esac
done
host=$1; shift
[ -S "$sock" ] || { printf 'Control socket connect(%s): No such file or directory\n' "$sock" >&2; exit 255; }
[ -f "$PR_WORK/down/$host" ] && exit 255
cd "$PR_WORK/m/$host/home" 2>/dev/null || exit 255
exec env -u TMUX -u TMUX_PANE $(cat "$PR_WORK/env/$host") bash -c "$*"
EOF
  printf '#!/bin/sh\nexit 3\n' > "$PR_WORK/cert.sh"
  chmod +x "$PR_WORK/ssh.sh" "$PR_WORK/cert.sh"
  mkdir -p "$PR_WORK/env"
  for m in home far1 far2; do pr_env "$m" > "$PR_WORK/env/$m"; done
  pr_machine far1 1a1a1a1a-0000-4000-8000-000000000001 orch a b || return 1
  pr_machine far2 2b2b2b2b-0000-4000-8000-000000000002 c || return 1
  pr_machine home 3c3c3c3c-0000-4000-8000-000000000003 orch l1 l2 || return 1
  # the hub's rows on home: your sessions on far1 and far2 (same login)
  local g="$PR_WORK/m/home/tmp/.claude-dash/global" u
  { printf '#me%shome\n' "$PR_US"
    for u in "$PR_U_far1/fid-a far1" "$PR_U_far1/fid-b far1" "$PR_U_far1/orchestrator far1" "$PR_U_far2/fid-c far2"; do
      set -- $u
      printf 'wid:%s%s%s%sonline%s1%sacme/app%sworking%sclaude%sn%s%s%s0\n' "$1" "$PR_US" "$2" "$PR_US" "$PR_US" "$PR_US" "$PR_US" "$PR_US" "$PR_US" "$PR_US" "$PR_US" "$PR_US"
    done
  } > "$g/remote_$PR_HS"
  printf '%s\t%s\n%s\t%s\n' "$PR_U_far1" "$PR_ME" "$PR_U_far2" "$PR_ME" > "$g/fleet_logins"
  # the keeper (C5)
  # straight through env (exec), so $! IS the keeper — pr_in in the background
  # would be a subshell, and killing it would leave the keeper running
  # shellcheck disable=SC2046  # pr_env's words ARE the env arguments
  env -u TMUX -u TMUX_PANE $(pr_env home) python3 "$BIN/fleet-peerlink.py" run >>"$PR_WORK/keeper.err" 2>&1 </dev/null & PR_KP=$!
  "$REAL_TMUX" -L "$PR_TL" -f /dev/null new-session -d -s "$PR_TL" -n idle -x 160 -y 40 'while :; do sleep 300; done'
}

# pr_attach — the person's terminal attaches the thin 看台 `v1` on home
pr_attach() {
  "$REAL_TMUX" -L "$PR_TL" new-window -d -t "=$PR_TL:" -n view \
    "env -u TMUX -u TMUX_PANE $(pr_env home) bash '$BIN/fleet-remote-view.sh' attach --thin --view v1 --route lan --token t1 --device e30=; sleep 300"
}
pr_view() { printf '%s@view-v1' "$PR_HS"; }
pr_cur() { pr_t home display-message -p -t "=$(pr_view):" '#{window_id}' 2>/dev/null; }
pr_screen() { "$REAL_TMUX" -L "$PR_TL" capture-pane -p -t "=$PR_TL:view" 2>/dev/null; }
pr_peer() { pr_t home list-windows -t "=$PR_HS" -F '#{@peer}|#{@peer_view}|#{window_id}' 2>/dev/null | awk -F '|' -v p="$1@$PR_ME" '$1 == p && $2 == "v1" { print $3; exit }'; }
pr_go() { pr_in home bash "$BIN/fleet-view-go.sh" v1 "$@"; }
pr_up_link() {   # <machine> — C5 says the link is up
  python3 - "$PR_WORK/m/home/conf/peerlink/state.json" "$1@$PR_ME" <<'PY' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
sys.exit(0 if any("%s@%s" % (l["machine"], l["login"]) == sys.argv[2] and l["phase"] == "up" for l in s["links"]) else 1)
PY
}
pr_wait() {  # <secs> <cmd…>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
pr_tree() {  # <pid> — it and every descendant
  local p="$1" k
  printf '%s\n' "$p"
  for k in $(pgrep -P "$p" 2>/dev/null); do pr_tree "$k"; done
}
pr_down() {
  [ -n "${PR_KP:-}" ] && { kill "$PR_KP" 2>/dev/null; wait "$PR_KP" 2>/dev/null; }
  local s
  for s in "$PR_TL" "$PR_HS" "$PR_FS1" "$PR_FS2"; do
    "$REAL_TMUX" -L "$s" kill-server 2>/dev/null
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"   # a -L socket file outlives its server on macOS
  done
  awk '$1 == "master" { print $4 }' "$PR_WORK/fs/log" 2>/dev/null | while read -r s; do kill "$s" 2>/dev/null; done
  return 0
}
