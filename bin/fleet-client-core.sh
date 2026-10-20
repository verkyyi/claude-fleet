#!/bin/bash
# fleet-client-core.sh — the small library a client-only computer's scripts read
# (issue #4825, EPIC #4823 C2). bin/fleet-lib.sh is the machine's library: 11k
# lines, changed by nearly every fleet PR, and before this every client script
# that needed one helper sourced all of it — so a change there could break a
# colleague's client, and it was the biggest file in the client package.
#
# This file holds what the client roads use, and it is the ONLY place those
# helpers are defined: fleet-lib.sh sources it first, so the machine side calls
# the very same code. A client script sources THIS file; a branch of it that only
# a hosting machine takes (a fleet of its own, a pane in one) loads the rest with
# fleet_host_lib, which answers 1 where fleet-lib.sh is not installed — a pure
# client never has it. bin/client-core-selftest.sh holds the client's files to it.
#
# Sourced, never run: no `set -u` / `pipefail` (fleet-lib.sh's rule) — safe under a
# caller's `set -u`, under zsh (a skill's Bash tool) and bash 3.2.

# The dash cache is THIS login's (issue #2442): never the /tmp/.claude-dash every
# login on the machine shares — the first login to create it makes it 0700 and the
# next one is locked out of its own fleet. A process with no TMPDIR (a `sudo -u`
# half of a same-machine fleet-move, a tmux server it started) takes the login's
# own temp dir: on macOS the per-user one launchd hands the daemons
# (`getconf DARWIN_USER_TEMP_DIR`), EXPORTED so every child — a tmux server, a
# pane, a script that spells the path inline — reads the daemons' directory;
# elsewhere `/tmp/claude-fleet-<uid>`, the same fallback every inline spelling
# writes (`${TMPDIR:-/tmp/claude-fleet-$(id -u)}`). BREAK-IT `tmpdir-shared-root`.
fleet_user_tmpdir() {
  local d=''
  [ "$(uname -s 2>/dev/null)" = Darwin ] && d=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
  [ -n "$d" ] && [ -d "$d" ] || d="/tmp/claude-fleet-$(id -u)"
  printf '%s' "$d"
}
if [ -z "${TMPDIR:-}" ]; then
  _fleet_ut=$(fleet_user_tmpdir)
  case "$_fleet_ut" in /tmp/claude-fleet-*) ;; *) TMPDIR=$_fleet_ut; export TMPDIR ;; esac
  unset _fleet_ut
fi
FLEET_C="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash"
# …and never ANOTHER login's (issue #2450): a TMPDIR that is the shared /tmp, or a
# /tmp/claude-fleet-<uid> someone else made first, would put this login's state in
# a directory it does not own — 0700 locks every spawn out, anything looser leaks
# it. A cache that exists and is not ours is refused with one stderr line; the
# per-uid one takes over, then one under $HOME. `[ -O ]` is a builtin: no fork on
# the common path. BREAK-IT `tmpdir-shared-root`.
if [ -e "$FLEET_C" ] && [ ! -O "$FLEET_C" ]; then
  _fleet_cu="/tmp/claude-fleet-${UID:-$(id -u)}"
  if { [ -e "$_fleet_cu" ] && [ ! -O "$_fleet_cu" ]; } || { [ -e "$_fleet_cu/.claude-dash" ] && [ ! -O "$_fleet_cu/.claude-dash" ]; }; then
    _fleet_cu="${HOME:-/nonexistent}/.cache/claude-fleet"
  fi
  printf 'fleet-lib: %s belongs to another login; using %s/.claude-dash\n' "$FLEET_C" "$_fleet_cu" >&2
  FLEET_C="$_fleet_cu/.claude-dash"
  unset _fleet_cu
fi
# Per-fleet configs live here. Override FLEET_CONF_DIR to relocate (used by the
# test harness).
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# The directory this file is in: fleet-lib.sh says it (no fork); a client script
# sourcing this file directly resolves it here.
[ -n "${_FLEET_CORE_DIR:-}" ] || _FLEET_CORE_DIR="$(_s="${BASH_SOURCE[0]:-$0}"; [ "${_s#*/}" = "$_s" ] && _s="./$_s"
  cd "${_s%/*}/" 2>/dev/null && pwd)" 2>/dev/null

# fleet_host_lib — load the machine's library (fleet-lib.sh beside this file) into
# the CURRENT shell: rc 0 when it is loaded (or already was), rc 1 when this
# computer does not have it — a client-only install (EPIC #4823) — so the caller's
# machine-only branch is skipped. Call it in the shell that needs the functions,
# never inside a $(…). A caller that must not read the global conf sets
# FLEET_SKIP_GLOBAL_CONF=1 for the call, as for a direct source.
fleet_host_lib() {
  [ -n "${_FLEET_LIB_DIR:-}" ] && return 0
  [ -f "${_FLEET_CORE_DIR:-.}/fleet-lib.sh" ] || return 1
  # shellcheck source=fleet-lib.sh
  . "$_FLEET_CORE_DIR/fleet-lib.sh"
}

# ---- the fleet confs on this login -----------------------------------------------

# fleet_conf_reserved <name> — rc 0 when $FLEET_CONF_DIR/<name>.conf is NOT a
# fleet's legacy flat conf: fleet.conf is the MACHINE's config (#1623, and `fleet`
# is the default session name), shell.conf the shell's (#1484), hub-defaults.conf
# the hub's client defaults (#1722). Every reader or mover of a flat <sess>.conf
# asks this first (issue #1887: the layout migrator once filed fleet.conf away as
# fleet `fleet`'s stale duplicate and deleted it on every sync).
fleet_conf_reserved() { case "${1:-}" in fleet|shell|hub-defaults) return 0 ;; esac; return 1; }

# Enumerate configured fleets → one "<sess>\t<conf-path>" line each. The new layout
# (fleets/<sess>/conf) is preferred; a legacy flat <sess>.conf is emitted ONLY when
# that session has no new-layout dir yet — so a half-migrated estate lists each
# fleet exactly once. Replaces every `for cf in "$FLEET_CONF_DIR"/*.conf` loop.
fleet_each_conf() {
  local d conf sess hdr
  # An empty conf estate must expand to NOTHING, not abort. zsh's NOMATCH (on by
  # default) errors `no matches found` on an unmatched glob — so when this lib is
  # sourced into a zsh shell and the `fleets/*/` or legacy `*.conf` glob matches
  # nothing, the whole function used to die noisily (issue #295). bash instead
  # passes the literal pattern through, which the per-entry `[ -d ]`/`[ -f ]`
  # guards below already skip. Enable null_glob function-locally under zsh (the
  # local_options save/restore is scoped to this function); bash needs no change.
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  if [ -d "$FLEET_CONF_DIR/fleets" ]; then
    for d in "$FLEET_CONF_DIR"/fleets/*/; do
      [ -d "$d" ] || continue
      conf="${d}conf"; [ -f "$conf" ] || continue
      sess=${d%/}; sess=${sess##*/}
      # A name with a `.` is never a fleet (issue #2430): fleet-up turns `.` into
      # `-` (tmux session names hold none), so `fleets/fleet.ghost-bak-<stamp>/`
      # is somebody's backup — on mac-b it was reported to the hub as a fleet.
      case "$sess" in *.*) continue ;; esac
      # The machine's own config stranded under fleets/ by the pre-#1887 migrator
      # is not a fleet (issue #2059) — `fleet-conf.sh migrate` puts it back — and
      # neither is a renamed copy of it (issue #2430): the header, whatever the
      # directory's name. Read with the `read` builtin: no fork on this hot path (#888).
      hdr=''; IFS= read -r hdr < "$conf" || true
      case "$hdr" in "# claude-fleet — this machine's ONE config file"*) continue ;; esac
      printf '%s\t%s\n' "$sess" "$conf"
    done
  fi
  for conf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    sess=${conf##*/}; sess=${sess%.conf}          # basename … .conf, no fork (#888)
    fleet_conf_reserved "$sess" && continue   # the machine's config + the shell's (#1623) + the hub's defaults (#1722), not fleets
    # dedup only when the NEW-layout conf FILE exists — a fleets/<sess>/ dir that
    # holds just restore.map/bridge/watch (no conf yet) must NOT hide the legacy conf.
    [ -f "$FLEET_CONF_DIR/fleets/$sess/conf" ] && continue
    printf '%s\t%s\n' "$sess" "$conf"
  done
}

# The login's fleet (issue #979): one login runs ONE fleet, holding all its repos.
# Prints that fleet's session when exactly one fleet is configured (rc 0). None
# configured → nothing, rc 1 (a brand-new fleet is named "fleet"). Two or more — an
# estate from before the fold (fleet-repo.sh fold) — → nothing, rc 2: there is no
# single answer, and a caller must never guess one.
fleet_login_fleet() {
  local all rest
  all=$(fleet_each_conf); [ -n "$all" ] || return 1
  rest=${all#*
}
  [ "$rest" = "$all" ] || return 2
  printf '%s\n' "${all%%	*}"
}

# ---- per-fleet tmux socket (issue #159) -------------------------------------
# A fleet ≡ a tmux SESSION ≡ its OWN tmux server on a NAMED socket, so one
# fleet's fatal crash — or a bypass-permissions worker's stray `tmux kill-server`
# — can only take down ITS OWN fleet, not every fleet sharing the machine (the
# old single `default` socket made the server a whole-machine single point of
# failure). The socket LABEL is the session name itself: fleet-up.sh already
# makes it unique per fleet and sanitizes it (no '.', ':' or space), so one
# string is BOTH the `-L` socket and the `-t` session target.
#
# The dividing line for callers:
#   • INSIDE a pane (Claude hooks, dash producers, zoom/F9 binds, spawn scripts,
#     commands/*.md): tmux inherits the right socket via $TMUX — call bare tmux,
#     no `-L` needed. New windows/sessions they open land on the same (correct)
#     socket automatically.
#   • OUTSIDE any session (launchd/systemd daemons; fleet-up/-down/-restore run
#     from a plain shell): there is no $TMUX, so every tmux call MUST pass
#     `-L "$(fleet_socket "$sess")"`. A daemon that used ONE server-wide
#     `tmux list-windows -a` must instead fan out over fleet_sockets and run its
#     per-fleet logic against each socket (writes stay on the same `-L` label).
fleet_socket() { printf '%s' "$1"; }

# List the socket labels of all fleets with a CURRENTLY-LIVE tmux server, one per
# line. Source of truth: the configured fleets enumerated by fleet_each_conf —
# the new per-fleet layout (fleets/<sess>/conf, label = the DIRECTORY basename)
# with a dual-read of the legacy flat <sess>.conf (issue #203) — filtered to those
# whose server actually answers (`tmux -L <label> has-session`). Routing through
# fleet_each_conf is what makes the socket-aware daemons (bridge/watch/collector-
# fanout/dispatch) find fleets post-#181; a hand-rolled `for cf in …/*.conf` glob
# matched NOTHING after the confs moved under fleets/<sess>/. A downed-but-
# configured fleet (conf kept, server gone) is skipped, and the user's own
# default-socket tmux is never touched. Safe under a `set -u` caller.
fleet_sockets() {
  local sess conf tab
  [ -d "$FLEET_CONF_DIR" ] || return 0
  tab=$(printf '\t')                                 # POSIX tab (ANSI-C quoting is a bashism dash ignores)
  while IFS="$tab" read -r sess conf; do
    [ -n "$sess" ] || continue
    tmux -L "$sess" has-session -t "$sess" 2>/dev/null && printf '%s\n' "$sess"
  done <<EOF
$(fleet_each_conf)
EOF
}

# ---- where the tools are ---------------------------------------------------------

# Where claude and tmux live when PATH does not say (issue #1774, #1784). A shell
# started by ssh or a daemon on mac-a had neither ~/.local/bin (Claude Code's native
# install) nor /opt/homebrew/bin (tmux) on PATH, so `exec claude` failed and a
# restore parked at a shell twice. FLEET_TOOL_DIRS is the fixed search order after
# PATH; a selftest points it at a sandbox.
FLEET_TOOL_DIRS="${FLEET_TOOL_DIRS:-$HOME/.local/bin /opt/homebrew/bin /usr/local/bin}"

# fleet_path_fill — PATH with every existing FLEET_TOOL_DIRS dir it lacks APPENDED:
# the order PATH already has wins, so a PATH that finds both tools is unchanged.
fleet_path_fill() {
  local dir out=$PATH
  for dir in $FLEET_TOOL_DIRS; do
    [ -d "$dir" ] || continue
    case ":$out:" in *":$dir:"*) ;; *) out="${out:+$out:}$dir" ;; esac
  done
  printf '%s' "$out"
}

# fleet_find_tool <claude|tmux> — the binary to run: $FLEET_CLAUDE_BIN /
# $FLEET_TMUX_BIN (unset: the install line's static tmux,
# ~/.local/share/claude-fleet-vendor/bin/tmux, when there is one — #2260) when it is executable, else the bare name when PATH (or a
# function) answers — byte for byte the old `exec claude` — else the first
# FLEET_TOOL_DIRS hit. rc 1 + one stderr line naming every place tried.
fleet_find_tool() {
  local name="$1" pin='' dir tried=''
  case "$name" in
    claude) pin=${FLEET_CLAUDE_BIN:-} ;;
    # no pin: the static tmux the install line put here (#2260), when it did
    tmux) pin=${FLEET_TMUX_BIN:-}
      [ -n "$pin" ] || [ ! -x "${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet-vendor/bin/tmux" ] \
        || pin="${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet-vendor/bin/tmux" ;;
  esac
  if [ -n "$pin" ]; then
    [ -x "$pin" ] && { printf '%s\n' "$pin"; return 0; }
    tried="$pin "
  fi
  command -v "$name" >/dev/null 2>&1 && { printf '%s\n' "$name"; return 0; }
  tried="${tried}PATH"
  for dir in $FLEET_TOOL_DIRS; do
    [ -x "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    tried="$tried $dir/$name"
  done
  printf 'fleet: %s not found — tried %s\n' "$name" "$tried" >&2
  return 1
}

# ---- this login's node.env (issue #1491) -----------------------------------------

# node.env holds the node token: it is READ here, never sourced, and the token
# never enters an exported variable (fleet-lib.sh's _fleet_hub_env is the one
# place that exports it, inside the subshell that runs a hub command).
# fleet_node_env_file → this login's node.env path.
fleet_node_env_file() { printf '%s/node.env' "$FLEET_CONF_DIR"; }

# _fleet_node_env_val <KEY> → the value node.env assigns KEY ('' when none; rc 1
# when there is no readable file). READ, never sourced: it holds a credential.
#
# Separated (issue #1971, bin/fleet-credsep.sh) node.env is a symlink into the
# role account's store and unreadable here: CCQUOTA_TOKEN is then a short-lived
# fcpn1. credential for the credential proxy's hub broker (_fleet_node_broker),
# every other key comes from node.pub.env — the token-less copy.
_fleet_node_env_val() {
  local f; f=$(fleet_node_env_file)
  if [ ! -r "$f" ] && _fleet_node_separated; then
    if [ "$1" = CCQUOTA_TOKEN ]; then
      f=$(_fleet_node_broker) || return 1
      printf '%s\n' "${f#*	}"; return 0
    fi
    f="$FLEET_CONF_DIR/node.pub.env"
  fi
  [ -r "$f" ] || return 1
  sed -n "s/^$1=//p" "$f" | head -n 1
}

# _fleet_node_separated → rc 0 when this login's credentials live in the role
# account's store (bin/fleet-credsep.sh wrote $FLEET_CONF_DIR/credsep.json).
_fleet_node_separated() { [ -f "$FLEET_CONF_DIR/credsep.json" ]; }

# _fleet_node_broker → `<broker url>TAB<fcpn1.…>`: the hub through the credential
# proxy, which puts the node token in on the way out and never forwards
# POST /v1/node/credentials. rc 1 = the proxy did not answer.
_fleet_node_broker() {
  local out
  out=$(bash "${_FLEET_LIB_DIR:-${_FLEET_CORE_DIR:-$HOME/.claude/fleet/bin}}/fleet-cred-proxy.sh" node-token 2>/dev/null) || return 1
  case "$out" in http://127.0.0.1:*"	"fcpn1.*) printf '%s\n' "$out" ;; *) return 1 ;; esac
}

# fleet_node_pair [<hub url>] → `<url>TAB<token>`: where this login's NODE token
# is good, and the token (issue #3106; #2665: a token is good only at the address
# it came with). node.env readable → its CCQUOTA_TOKEN at its CCQUOTA_HUB_URL
# (else <hub url>); separated (issue #1971) → the credential proxy's hub broker
# pair, whose fcpn1. the proxy swaps for the node token on the way out. rc 1 =
# no node token here. Keep the answer in a shell variable — never export it,
# never put the token on an argv (curl -K - takes the header on stdin).
fleet_node_pair() {
  local f t u
  f=$(fleet_node_env_file)
  if [ -r "$f" ]; then
    t=$(sed -n 's/^CCQUOTA_TOKEN=//p' "$f" | head -n 1); t=${t#[\"\']}; t=${t%[\"\']}
    u=$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$f" | head -n 1); u=${u#[\"\']}; u=${u%[\"\']}
    u=${u:-${1:-}}
    [ -n "$t" ] && [ -n "$u" ] || return 1
    printf '%s\t%s\n' "${u%/}" "$t"
    return 0
  fi
  _fleet_node_separated || return 1
  _fleet_node_broker
}

# fleet_node_is_self <name> — is <name> this machine? `local` / `here`, this
# host's short name, or its FLEET_NODE_ALIASES alias (`mac-c=mac-b` → mac-b), any case.
fleet_node_is_self() {
  local n h
  n=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$n" in '') return 1 ;; local|here) return 0 ;; esac
  h=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); h=${h%%.*}
  [ -n "$h" ] || return 1
  [ "$n" = "$h" ] && return 0
  printf '%s\n' ${FLEET_NODE_ALIASES:-} | tr '[:upper:]' '[:lower:]' | grep -qx -- "$h=$n"
}

# ---- a refused hub read, written down (issue #2630) ------------------------------

# fleet_hub_auth_note <reader> ok|fail [reason] — the ONE record of a node-side
# hub READ the hub refused (issue #2630): `$FLEET_C/global/hub_auth_fail`, one
# line per reader — `<reader><TAB><since><TAB><last><TAB><reason>`. A refusal
# keeps the since of the reader's line (so a reader can say how LONG it has been
# refused) and moves its last; `ok` drops the line. Before this every reader
# swallowed its own 401 — the quota watch read nothing for a day and the doctor
# said so only as 「盲」. Read by fleet_hub_auth_rows / the doctor's `hubauth` row.
# Cheap when nothing is wrong: an `ok` with no file (or no line of its) writes
# nothing — the sessions loop calls it every round.
fleet_hub_auth_note() {
  local reader="$1" verdict="$2" reason="${3:-}" f now since='' r s l why tmp out=''
  [ -n "$reader" ] || return 0
  f="$FLEET_C/global/hub_auth_fail"
  if [ "$verdict" = ok ]; then
    [ -s "$f" ] || return 0
    grep -q "^${reader}	" "$f" 2>/dev/null || return 0
  fi
  reason=$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-200)
  now=$(date +%s)
  if [ -s "$f" ]; then
    while IFS=$'\t' read -r r s l why; do
      [ -n "$r" ] || continue
      if [ "$r" = "$reader" ]; then since=$s; continue; fi
      out="${out}${r}	${s}	${l}	${why}
"
    done < "$f"
  fi
  if [ "$verdict" != ok ]; then
    case "$since" in ''|*[!0-9]*) since=$now ;; esac
    out="${out}${reader}	${since}	${now}	${reason}
"
  fi
  mkdir -p "$FLEET_C/global" 2>/dev/null || return 0
  if [ -z "$out" ]; then rm -f "$f"; return 0; fi
  tmp="$f.$$.new"
  printf '%s' "$out" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  return 0
}

# ---- what this node is: client or managed (issue #4886) ----------------------
# The hub types every node: managed (a login of a 托管 machine, a cluster pod —
# the fleet runs tasks there) or client (a person's terminal: it connects, looks
# and opens windows, and hosts no repo, runs no task). The hub's word is the one
# record (endpoints.role, GET /v1/node/self); this login keeps it for
# FLEET_NODE_ROLE_TTL seconds (3600) in $FLEET_CONF_DIR/node-role.
#
# fleet_node_role → managed | client on stdout, rc 0; rc 1 and nothing when it is
# not known — no hub, no node token, a hub older than #4886, unreachable, or a
# row the operator never typed. Unknown is NEVER client: every caller then does
# what it did before, byte for byte. --fresh asks the hub whatever the age (a
# rare road that turns a node into a host: repo add, host on), falling back to
# the kept word when the hub cannot be asked; --kept never asks, whatever the age
# (a spawn: the diskguard tick keeps the word fresh — node_role_watch). FLEET_NODE_ROLE
# (managed|client|unknown) answers for a test; FLEET_HUB_CURL is the transport.
fleet_node_role() {
  local f="$FLEET_CONF_DIR/node-role" role='' at='' kept='' now tok url resp fresh='' only=''
  case "${1:-}" in --fresh) fresh=1 ;; --kept) only=1 ;; esac
  case "${FLEET_NODE_ROLE:-}" in
    managed|client) printf '%s\n' "$FLEET_NODE_ROLE"; return 0 ;;
    unknown) return 1 ;;
  esac
  now=$(date +%s)
  [ -z "$only" ] || [ -r "$f" ] || return 1
  if [ -r "$f" ]; then
    read -r kept at < "$f" 2>/dev/null || true
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    case "$kept" in managed|client) ;; *) kept='' ;; esac
    if [ -n "$only" ]; then [ -n "$kept" ] || return 1; printf '%s\n' "$kept"; return 0; fi
    if [ -z "$fresh" ] && [ $((now - at)) -lt "${FLEET_NODE_ROLE_TTL:-3600}" ]; then
      [ -n "$kept" ] || return 1
      printf '%s\n' "$kept"; return 0
    fi
  fi
  tok=${CCQUOTA_TOKEN:-$(_fleet_node_env_val CCQUOTA_TOKEN 2>/dev/null)}
  url=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)}}
  if [ -z "$tok" ] || [ -z "$url" ] || ! resp=$(printf 'Authorization: Bearer %s\n' "$tok" | "${FLEET_HUB_CURL:-curl}" -fsS \
       --max-time "${FLEET_NODE_ROLE_TIMEOUT:-4}" -H @- "${url%/}/v1/node/self" 2>/dev/null); then
    if [ -n "$kept" ]; then printf '%s\n' "$kept"; return 0; fi
    # Nothing kept and nothing heard: remember that much for the TTL, so an
    # unreachable hub costs one wait an hour, never one per spawn.
    [ -n "$tok" ] && [ -n "$url" ] && mkdir -p "$FLEET_CONF_DIR" 2>/dev/null \
      && printf -- '- %s\n' "$now" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
    rm -f "$f.$$" 2>/dev/null
    return 1
  fi
  role=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("role") or "")
except Exception: pass' 2>/dev/null)
  case "$role" in managed|client) ;; *) role='' ;; esac
  # The answer is kept either way (an untyped row too), so a busy road asks once
  # an hour, not on every call.
  mkdir -p "$FLEET_CONF_DIR" 2>/dev/null && printf '%s %s\n' "${role:--}" "$now" > "$f.$$" 2>/dev/null \
    && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
  [ -n "$role" ] || return 1
  printf '%s\n' "$role"
}

# fleet_client_refuse <what> [--fresh|--kept] — rc 0 (and the one line on stderr) when
# the hub typed this node a client: <what> would make it run tasks. rc 1
# otherwise — managed or unknown go on as before. FLEET_ALLOW_CLIENT_TASKS=1 is
# the hatch.
fleet_client_refuse() {
  [ "${FLEET_ALLOW_CLIENT_TASKS:-0}" = 1 ] && return 1
  [ "$(fleet_node_role ${2:+"$2"} 2>/dev/null)" = client ] || return 1
  printf 'fleet: 这台是客户端，任务在托管节点上跑 — %s 不在这里做（hub 记它为 client；改类型找管理员）\n' "$1" >&2
  return 0
}
