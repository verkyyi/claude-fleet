#!/bin/bash
# fleet-client-retire.sh — what the OLD client (the two-pane tmux client,
# fleet-shell.sh — deleted with issue #3008) may still have running on THIS
# computer, and taking it away.
#
#   fleet-client-retire.sh running        exit 0 when something of it still runs here
#   fleet-client-retire.sh stop [--quiet] [--if-unattached]
#   fleet-client-retire.sh count          `<processes>TAB<ssh masters>` left in the background
#   fleet-client-retire.sh background     the client doctor's `background` row:
#                                         `PASS|WARN<TAB><text>` (issue #4827)
#
# A computer that ran the old client before this version keeps its processes
# until they are stopped: its tmux servers (`-L fleet-shell` and the companion stage server, or `fleet-node-client[-stage]` on a managed machine, plus a
# one-session view's `<label>-solo-<pid>`), its keeper, hub loop, action loop and
# warm lines — every one running from the old client's mirror, the cache's bin/
# (~/.cache/claude-fleet/shell/bin, FLEET_SHELL_CACHE). `stop` first runs that
# mirror's own `fleet-shell.sh quit` when it is still there (it gives the hub its
# lease back), then TERMs — and after FLEET_RETIRE_GRACE (3) seconds KILLs — what
# still runs from the mirror, then takes the servers down. The cache's logs stay
# (the debug bundle reads them); the thin client (fleet-thin.py) runs nothing in
# the background and is never touched. `--if-unattached`: a server someone still
# looks at is left alone (exit 3). fleet-node-shell-retire.sh is the same for a
# managed machine's logins, run by its daemon.
#
# ANY client's leftovers too (issue #4827, EPIC #4823 C4): on a client-only
# install (no checkout, no bin/fleet-up.sh, FLEET_HOST not 1, no node.env — a
# 承载 machine's or a node's own daemons run from ~/.claude/fleet with no
# parent, and are never ours to stop) a process of this login whose parent is gone (PPID 1), that has no
# terminal and whose argv names the client's install (<home>, <home>.versions,
# ~/.local/share/claude-fleet) or the fleet's cache (~/.cache/claude-fleet) —
# an ssh master a dead client left with ControlPersist, a loop an older client
# disowned — is stopped with its whole process tree. The thin client runs no
# background of its own, so none of this is someone's: a thin client in a
# terminal has one, and the updater's background `stage` (and this script)
# are passed over. `background` counts them (and the files an update left
# beside the install: version dirs past the current + the one before + a
# staged one, crashed staging dirs) for `fleet doctor`.
#
# Exit: 0 stopped / nothing ran · 1 something still runs · 2 usage · 3 left alone
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CACHE="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}"
SOCKDIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
LABELS="fleet-shell fleet-node-client"
# the client's install home: the one <home>.versions/ belongs to when run from a version dir
ROOTP="$(cd "$BIN/.." && pwd -P)"
HOMEDIR="${FLEET_CLIENT_ROOT:-$ROOTP}"
case "$HOMEDIR" in *.versions/*) [ -n "${FLEET_CLIENT_ROOT:-}" ] || HOMEDIR=${HOMEDIR%.versions/*} ;; esac
# the same home as a process may spell it: through ~/.claude/fleet's link, or a
# /var → /private/var one
HOMEL="$(cd "$BIN/.." && pwd)"
case "$HOMEL" in *.versions/*) HOMEL=${HOMEL%.versions/*} ;; esac
HOMEC="$HOME/.claude/fleet"
[ "$(cd "$HOMEC" 2>/dev/null && pwd -P)" = "$ROOTP" ] || HOMEC=$HOMEL
FCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet"
# client_only — a client-only install: its background is all the client's
client_only() {
  [ -e "$ROOTP/.git" ] || [ -f "$ROOTP/bin/fleet-up.sh" ] && return 1
  [ "${FLEET_HOST:-}" = 1 ] && return 1
  # a node (fleet node join): its agent runs with no parent too
  [ -f "${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/node.env" ] && return 1
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?FLEET_HOST=["'"'"']?1' \
    "${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/fleet.conf" 2>/dev/null && return 1
  return 0
}

# labels — every tmux server label of the old client on this login that answers
labels() {
  local l f
  for l in $LABELS; do
    printf '%s\n%s-stage\n' "$l" "$l"
    for f in "$SOCKDIR/$l"-solo-*; do [ -S "$f" ] && printf '%s\n' "${f##*/}"; done
  done | while IFS= read -r l; do
    tmux -L "$l" list-sessions >/dev/null 2>&1 && printf '%s\n' "$l"
  done
}
# pids — this login's processes running from the old client's mirror, and its
# warm lines: an ssh master whose ControlPath is in the cache's tmp/ (issue #4283
# — the warm loop opened one every 5 s with ControlPersist=10m, ~120 at a time,
# each holding a hub relay on the relay route until TOO_MANY). The paths ride the
# environment, so the awk's own argv never matches them.
pids() {
  ps -axo pid=,user=,command= 2>/dev/null | RETIRE_PAT="$CACHE/bin/" RETIRE_TMP="ControlPath=$CACHE/tmp/" \
    awk -v u="$(id -un)" -v me=$$ \
    '$2 == u && $1 != me && (index($0, ENVIRON["RETIRE_PAT"]) || index($0, ENVIRON["RETIRE_TMP"])) { print $1 }'
  orphans
}
# orphans [masters] — any client's leftovers (issue #4827, above): each one and
# every process under it; `masters` prints only the ssh masters among the tops
orphans() {
  client_only || return 0
  ps -axo pid=,ppid=,user=,tty=,command= 2>/dev/null | python3 -c 'import os, sys
me, u, only = int(sys.argv[1]), sys.argv[2], sys.argv[3]
pats = [p for p in sys.argv[4:] if p]
kids, tops, masters = {}, [], []
for line in sys.stdin:
    f = line.split(None, 4)
    if len(f) < 5 or not f[0].isdigit() or not f[1].isdigit():
        continue
    pid, ppid, user, tty, cmd = int(f[0]), int(f[1]), f[2], f[3], f[4].rstrip("\n")
    kids.setdefault(ppid, []).append(pid)
    if user != u or pid == me or ppid != 1 or tty not in ("??", "?", "-"):
        continue
    if not any(p in cmd for p in pats):
        continue
    if "fleet-client-retire.sh" in cmd or "fleet-client-update.sh stage" in cmd or "ccquota" in cmd.split()[0]:
        continue
    tops.append(pid)
    if os.path.basename(cmd.split()[0]) in ("ssh", "ssh:"):
        masters.append(pid)
if only == "masters":
    out = masters
else:
    out, todo = [], list(tops)
    while todo:
        p = todo.pop()
        if p in out:
            continue
        out.append(p)
        todo.extend(kids.get(p, []))
for p in out:
    print(p)' "$$" "$(id -un)" "${1:-}" "$HOMEDIR/" "$HOMEDIR.versions/" "$HOMEL/" "$HOMEL.versions/" "$HOMEC/" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet" "$FCACHE/"
}
# attached — someone looks at one of its servers. A `-stage` server's client is
# the old client's own viewer inside the main server (fleet-shell.sh attached it
# there), never a person: counting it held every unattended client forever (#4283)
attached() {
  local l
  for l in $(labels); do
    case "$l" in *-stage) continue ;; esac
    [ -n "$(tmux -L "$l" list-clients -F '#{client_name}' 2>/dev/null)" ] && return 0
  done
  return 1
}

mode=${1:-}; [ $# -gt 0 ] && shift
quiet='' ifun=''
for a in "$@"; do
  case "$a" in
    --quiet) quiet=1 ;;
    --if-unattached) ifun=1 ;;
    *) printf 'fleet-client-retire: unknown %s\n' "$a" >&2; exit 2 ;;
  esac
done
say() { [ -n "$quiet" ] || { sh "$BIN/fleet-ui-lang.sh" t "$@"; echo; }; }

# extra_files — the files an update left beside the install (issue #4827): the
# version dirs past the current one, .prev's and .next's, and staging dirs
extra_files() {
  local cur='' prev='' next='' d k
  [ -d "$HOMEDIR.versions" ] || { echo 0; return 0; }
  [ -L "$HOMEDIR" ] && cur=$(basename "$(readlink "$HOMEDIR")")
  { read -r prev < "$HOMEDIR.versions/.prev"; } 2>/dev/null
  { read -r next < "$HOMEDIR.versions/.next"; } 2>/dev/null
  for d in "$HOMEDIR.versions"/* "$HOMEDIR.versions"/.staging*; do
    [ -d "$d" ] || continue
    k=${d##*/}
    case "$k" in .lock) continue ;; esac
    [ -n "$k" ] && { [ "$k" = "$cur" ] || [ "$k" = "$prev" ] || [ "$k" = "$next" ]; } && continue
    find "$d" -type f 2>/dev/null
  done | wc -l | tr -d ' '
}

case "$mode" in
  count)
    printf '%s\t%s\n' "$(pids | sort -u | grep -c .)" "$(orphans masters | grep -c .)"
    exit 0 ;;
  background)
    np=$(pids | sort -u | grep -c .); nm=$(orphans masters | grep -c .); nl=$(labels | grep -c .); nf=$(extra_files)
    np=$((np + nl))
    if [ "$np" -eq 0 ] && [ "$nm" -eq 0 ] && [ "$nf" -eq 0 ]; then
      printf 'PASS\tfleet 后台进程 0 · ssh 主连接 0 · 多余文件 0\n'
    else
      printf 'WARN\tfleet 后台进程 %s · ssh 主连接 %s · 多余文件 %s · 修法：fleet quit 收后台；多余文件下次启动 fleet 时清\n' "$np" "$nm" "$nf"
    fi
    exit 0 ;;
  running)
    [ -n "$(labels)$(pids)" ] ;;
  stop)
    if [ -z "$(labels)$(pids)" ]; then say retire_none; exit 0; fi
    [ -n "$ifun" ] && attached && exit 3
    if [ -f "$CACHE/bin/fleet-shell.sh" ]; then
      bash "$CACHE/bin/fleet-shell.sh" quit --quiet </dev/null >/dev/null 2>&1 &
      qp=$!; i=0
      while kill -0 "$qp" 2>/dev/null && [ "$i" -lt "${FLEET_RETIRE_QUIT_WAIT:-20}" ]; do sleep 1; i=$((i + 1)); done
      kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
    fi
    left=$(pids)
    if [ -n "$left" ]; then
      # shellcheck disable=SC2086  # a list of numeric pids
      kill $left 2>/dev/null
      sleep "${FLEET_RETIRE_GRACE:-3}"
      left=$(pids)
      # shellcheck disable=SC2086
      [ -z "$left" ] || kill -9 $left 2>/dev/null
    fi
    for l in $(labels); do tmux -L "$l" kill-server 2>/dev/null; done
    if [ -n "$(labels)$(pids)" ]; then
      [ -n "$quiet" ] || printf 'fleet · 旧客户端还有进程没停下：ps -ax | grep %s\n' "$CACHE/bin" >&2
      exit 1
    fi
    say retire_done
    exit 0 ;;
  *)
    sed -n '6,7p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2 ;;
esac
