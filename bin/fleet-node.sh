#!/bin/bash
# fleet-node.sh — `fleet node join` / `fleet node status` (issue #1627): adding
# a machine as a node is the same one command and one scan as `fleet login`.
#
#   fleet node join [--hub URL] [--invert] [--compute 0|1]
#                   [--no-fleet] [--no-deps] [--no-admin]
#       Run on the new machine, as the login that will run the fleet. No code,
#       no web page, no switches: the hub address is the one `fleet login` uses
#       (FLEET_HUB_URL / fleet.conf — fleet-login.py hub), the device key is the
#       one `fleet login` made (or makes it), and the QR opens the same
#       confirmation page, titled 「把 <机器名> 加为节点」. The confirmation
#       returns this machine's node pass; then fleet-node-join.sh runs its deps /
#       agent / service / online / fleet steps on their defaults, one `✓ …` line
#       each, and a failure is one `✗ …` line ending 「重跑同一条命令即可」.
#       A rerun whose node.env token the hub still accepts skips the scan and
#       redoes only what is missing. The hub address lands in fleet.conf
#       (fleet-conf.sh set-hub); joining is not 承载 by itself — FLEET_HOST
#       is `fleet host on`'s (issue #1806), which runs this join for you.
#       A first join only COORDINATES (issue #1719): node.env gets
#       CCQUOTA_FLEET_COMPUTE=0, so the hub places no session here and leases no
#       account; --compute 1 opens it. --no-fleet / --no-deps / --no-admin go to
#       fleet-node-join.sh as they are — the install line (fleet-install.sh)
#       joins with all three: the client is already there, and a laptop needs
#       no Homebrew packages and runs no account ops.
#       登录即登记 (issue #2212): a computer `fleet login` already registered
#       is never scanned twice — the join asks for its node pass with the device
#       key (`fleet-login.py node-pass`); the QR appears only when that road is
#       not open (never logged in, an older hub, a name the hub trusts).
#   fleet node ensure [--hub URL]
#       The silent half of 登录即登记 (issue #2212): `fleet login`, `fleet login
#       status`, `fleet run` and the client shell's start run it. When node.env
#       holds no token for the hub and this computer is logged in, it takes the
#       node pass by the device key and joins coordinate-only (--no-fleet
#       --no-deps --no-admin; a first node.env gets COMPUTE=0 and PERSONAL=1) —
#       no scan, no output (the detail in node-join.log). A computer that is a
#       node already (joined by a scan or a code) shows the hub its token once
#       per hub instead (node-login.ok): the hub ties that node to this device
#       and records whose login it is (登录即认人) — no second node.
#       A refused pass — or one whose login the hub did not record as the
#       person's (account_refused, issue #2249) — writes no node-login.ok; the
#       reason goes to node-join.log and node-login.why, and `fleet login`
#       says it as its last line.
#       No hub ⇒ nothing. Exit 0 a token is in node.env · 2 no hub · 3 not
#       logged in · 4 the hub offers no such door · 1 anything else.
#   sudo fleet node install --join <码> [--hub URL]
#       Make this Mac a MANAGED machine (issue #2330, EPIC #2329): join with the
#       hub's 托管 code as the machine, then the root runtime, the machine
#       daemon, the ssh CA — bin/fleet-node-install.sh, one line per step; the
#       same command again repairs whatever is missing. On a managed machine
#       `fleet node join` / `fleet host on` point here (and still work).
#   fleet node status
#       Like `fleet login status`: is this login a node, of which hub, and does
#       the hub see it online. Exit 0 only when it does.
#   fleet node compute on [--force] [--personal|--shared] | off | status
#       Whether the hub may run sessions here (issue #1720, EPIC #1718 C2) —
#       node.env's CCQUOTA_FLEET_COMPUTE, the agent re-reads it every beat (no
#       restart). `on` probes first (fleet-node-probe.sh: egress region, Claude /
#       OpenAI reachable) and refuses with the reason unless the verdict is ok;
#       --force opens it anyway, and the hub writes that into its audit and keeps
#       it open over the region rule. `off` = coordinate only. A laptop is only
#       noted. The other place compute is decided is the hub's team policy
#       fleet.compute_auto (default off).
#       --personal (issue #1721, EPIC #1718 C3; a laptop's default, --shared
#       says no): this is a person's own computer — node.env's
#       CCQUOTA_FLEET_PERSONAL=1. The hub places on it only what is asked from
#       it (its own client, a session already there): never another machine's
#       auto, never a start named at it from elsewhere. Its spawns default to
#       local (FLEET_SPAWN_NODE), and before it sleeps the agent flags it
#       维护中 (reason sleep), tells the client how many sessions still run,
#       and clears the flag on waking. Neither flag: a laptop is personal, a
#       machine that already chose keeps its choice, anything else is shared.
#   fleet node leave [--reason <text>] [--hub-only] [--dry-run]
#       Take this login off the hub (issue #1928): the hub retires its node
#       token and drops it from the machines page, then the agent stops and
#       node.env is deleted — bin/fleet-node-leave.sh, which says each step.
#
# The old way — a join code from the hub's /nodes page and
# `fleet-node-join.sh --hub … --token fj_…` — still works for one version
# (EPIC #1615 decision 11).
#
# Env: FLEET_CONF_DIR (~/.config/claude-fleet) · FLEET_NODE_JOIN_ARGS (extra
# fleet-node-join.sh options, the selftest's seam — never needed by a person).
# Exit: 0 joined / online / compute set · 1 a step failed (rerun the same
#   command) or `compute on` refused · 2 usage
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
ENVF="$CONF/node.env"
# `fleet login`'s certificate: present = this computer is logged in (#2212)
CERT="$HOME/.ssh/fleet-cert-cert.pub"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# separated (issue #2316): credsep moved node.env into the store — $ENVF is a
# link this login cannot read, node.pub.env holds every line but the token
separated() { [ -f "$CONF/credsep.json" ]; }
# envval <KEY> — one value from node.env ('' when absent)
envval() {
  local f="$ENVF"
  [ -r "$ENVF" ] || ! separated || f="$CONF/node.pub.env"
  [ -f "$f" ] && sed -n "s/^$1=//p" "$f" | head -n 1
}
# is_node — a token here, or (separated) one in the store behind the link
is_node() { [ -n "$(envval CCQUOTA_TOKEN)" ] || { separated && [ -L "$ENVF" ]; }; }

# self <hub> <token> — the hub's /v1/node/self body; exit 0 iff it answered 200
self() { curl -fsS --max-time 15 -H "Authorization: Bearer $2" "$1/v1/node/self" 2>/dev/null; }

jfield() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }

# managed_hint — on a managed machine (#2330) the old road still works for one
# version, but the machine's own command is `fleet node install`
managed_hint() {
  [ -e "${FLEET_NODE_STATE:-/var/db/fleet-node}/machine.env" ] || return 0
  echo "! 这台是托管机器：加入 / 修复用 sudo fleet node install --join <码>（这条旧命令一个版本内照旧可用）" >&2
}

cmd_join() {
  managed_hint
  local hub_arg="" invert="" hub tok work rc
  local pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --hub) hub_arg="${2:-}"; shift ;;
      --hub=*) hub_arg="${1#--hub=}" ;;
      --invert) invert=--invert ;;
      --compute) pass+=(--compute "${2:-}"); shift ;;
      --no-fleet|--no-deps|--no-admin) pass+=("$1") ;;
      -h|--help) usage; return 0 ;;
      *) echo "fleet node join: unknown option $1 (see fleet node --help)" >&2; return 2 ;;
    esac
    shift
  done
  if [ -n "$hub_arg" ]; then hub=$("$here/fleet-login.py" hub --hub "$hub_arg") || return 2
  else hub=$("$here/fleet-login.py" hub) || return 2; fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node.XXXXXX") || { echo "fleet node join: no temp dir" >&2; return 1; }
  # the node pass is a credential: it lives in this 0700 dir only until
  # fleet-node-join.sh has moved it into node.env
  chmod 700 "$work"
  local joined=()
  tok=$(envval CCQUOTA_TOKEN)
  if is_node && [ "$(envval CCQUOTA_HUB_URL)" = "$hub" ] && { [ -z "$tok" ] || self "$hub" "$tok" >/dev/null; }; then
    : # already a node of this hub: no scan; the join script skips its join step
    # (separated, #2316: the token is in the store, unread — the link says it is there)
  elif [ -z "$invert" ] && [ -f "$CERT" ] && "$here/fleet-login.py" node-pass --hub "$hub" --out "$work/node.json" --quiet; then
    # 登录即登记 (issue #2212): logged in already — the device key, no scan
    joined=(--joined "$work/node.json")
    echo "✓ 已用这台电脑的登录登记（不再扫码）" >&2
  else
    # shellcheck disable=SC2086
    "$here/fleet-login.py" node --hub "$hub" --out "$work/node.json" $invert || { rc=$?; rm -rf "$work"; return "$rc"; }
    joined=(--joined "$work/node.json")
  fi
  "$here/fleet-conf.sh" set-hub "$hub" >/dev/null 2>&1 \
    || echo "! 没能在 $CONF/fleet.conf 里记下入口地址（fleet-conf.sh set-hub）" >&2

  # shellcheck disable=SC2086
  "$here/fleet-node-join.sh" --hub "$hub" --ui ${joined[@]+"${joined[@]}"} ${pass[@]+"${pass[@]}"} ${FLEET_NODE_JOIN_ARGS:-}
  rc=$?
  rm -rf "$work"
  # Can it run sessions? One line, plus 「可以打开：fleet host on」 when
  # it can (issue #1720) — never a reason to fail the join.
  [ "$rc" = 0 ] && FLEET_CONF_DIR="$CONF" "$here/fleet-node-probe.sh" 2>/dev/null
  return "$rc"
}

# ensure [--hub URL] — 登录即登记's silent join (issue #2212); see the header.
cmd_ensure() {
  local hub_arg="" hub work rc fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hub) hub_arg="${2:-}"; shift ;;
      --hub=*) hub_arg="${1#--hub=}" ;;
      *) echo "fleet node ensure: unknown option $1" >&2; return 2 ;;
    esac
    shift
  done
  if [ -n "$hub_arg" ]; then hub=$("$here/fleet-login.py" hub --hub "$hub_arg" 2>/dev/null) || return 2
  else hub=$("$here/fleet-login.py" hub 2>/dev/null) || return 2; fi
  [ -f "$CERT" ] || { is_node && return 0; return 3; }
  if is_node; then
    # A node already (a scan / code join, before #2212): once per hub, show
    # the hub its token by the device key — it ties that node to this device
    # and records whose login this is (登录即认人), no new node, no scan.
    [ "$(cat "$CONF/node-login.ok" 2>/dev/null)" = "$hub" ] && return 0
    work=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node.XXXXXX") || return 0
    chmod 700 "$work"
    if "$here/fleet-login.py" node-pass --hub "$hub" --out "$work/node.json" 2>"$work/err"; then
      local newtok
      newtok=$(jfield token < "$work/node.json")
      # the hub reissues only when the token here was dead: then it is the one
      [ -n "$newtok" ] && [ "$newtok" != "$(envval CCQUOTA_TOKEN)" ] && setenv CCQUOTA_TOKEN "$newtok"
      passed "$hub" "$work/node.json"
    else
      notpassed "$(tail -n 1 "$work/err")"
    fi
    rm -rf "$work"
    return 0
  fi
  [ -f "$ENVF" ] || fresh=1
  mkdir -p "$CONF" 2>/dev/null
  work=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node.XXXXXX") || return 1
  chmod 700 "$work"
  "$here/fleet-login.py" node-pass --hub "$hub" --out "$work/node.json" 2>"$work/err"
  rc=$?
  if [ "$rc" != 0 ]; then notpassed "$(tail -n 1 "$work/err")"; rm -rf "$work"; return "$rc"; fi
  cp "$work/node.json" "$work/pass.json"
  "$here/fleet-conf.sh" set-hub "$hub" >/dev/null 2>&1
  # shellcheck disable=SC2086
  FLEET_CONF_DIR="$CONF" "$here/fleet-node-join.sh" --hub "$hub" --joined "$work/node.json" \
    --no-fleet --no-deps --no-admin --wait 20 ${FLEET_NODE_JOIN_ARGS:-} >>"$CONF/node-join.log" 2>&1
  is_node || { rm -rf "$work"; return 1; }
  # a computer that only coordinates is a person's own (#1721)
  [ "$fresh" = 1 ] && [ -z "$(envval CCQUOTA_FLEET_PERSONAL)" ] && setenv CCQUOTA_FLEET_PERSONAL 1
  passed "$hub" "$work/pass.json"   # tied to this device already
  rm -rf "$work"
  return 0
}

# passed <hub> <node.json> — the node pass came. node-login.ok only when the
# hub also says this login is the person's (登录即认人): a pass whose
# account_refused is set is the node without the person (issue #2249), and the
# next ensure asks again.
passed() {
  local refused
  refused=$(jfield account_refused < "$2")
  if [ -n "$refused" ]; then notpassed "登录未认人：$refused"; return 0; fi
  printf '%s\n' "$1" > "$CONF/node-login.ok"
  rm -f "$CONF/node-login.why"
}

# notpassed <why> — the hub refused (or only half-answered) the node pass: no
# node-login.ok, the reason in node-join.log and in node-login.why, which
# `fleet login` says as its last line (issue #2249).
notpassed() {
  local why="${1#fleet login: }"
  [ -n "$why" ] || why="没拿到节点通行证"
  mkdir -p "$CONF" 2>/dev/null
  rm -f "$CONF/node-login.ok"
  printf '%s node pass: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$why" >> "$CONF/node-join.log"
  printf '%s\n' "$why" > "$CONF/node-login.why"
}

# credsep_setenv [--check] — bin/fleet-credsep.sh setenv for this conf's login;
# as root (an admin fixing a login) the login is the conf's owner, never root
credsep_setenv() {
  local who=()
  [ "$(id -u)" != 0 ] || who=(--login "$(python3 -I -c 'import os, pwd, sys; print(pwd.getpwuid(os.stat(sys.argv[1]).st_uid).pw_name)' "$CONF/credsep.json")")
  FLEET_CONF_DIR="$CONF" bash "$here/fleet-credsep.sh" setenv ${who[@]+"${who[@]}"} "$@"
}

# setenv <KEY> <value|''> — node.env's line for KEY replaced (or removed when
# the value is empty), every other line kept; 0600, atomic. Separated (issue
# #2316): credsep writes the store's copy in place — a mv here would swap the
# link for a plain file and put the token back in the home.
setenv() {
  if separated; then printf '%s=%s\n' "$1" "$2" | credsep_setenv >/dev/null; return; fi
  { grep -v "^$1=" "$ENVF"; [ -z "$2" ] || printf '%s=%s\n' "$1" "$2"; } > "$ENVF.tmp" \
    && chmod 600 "$ENVF.tmp" && mv "$ENVF.tmp" "$ENVF"
}

# nudge — the agent sends a beat now rather than at its next interval.
nudge() { mkdir -p "$CONF/global" 2>/dev/null && touch "$CONF/global/hub-nudge" 2>/dev/null; }

# laptop — the last probe's word on a battery (node-probe.json): true | false | ''
laptop() { [ -f "$CONF/node-probe.json" ] && sed -n 's/.*"laptop":\([a-z]*\).*/\1/p' "$CONF/node-probe.json" | head -n 1; }

personal_line() {
  echo "个人电脑：只跑在这台上开的会话，别的机器不往这台派；睡眠前提醒还有几个会话在跑，并标「维护中」，醒来恢复（改为共享：fleet host on --shared）"
}

cmd_compute() {
  local verb="${1:-status}" force=0 personal='' line rc
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --personal) personal=1 ;;
      --shared) personal=0 ;;
      *) echo "fleet node compute: unknown option $1 — fleet node compute on [--force] [--personal|--shared] | off | status" >&2; return 2 ;;
    esac
    shift
  done
  if ! is_node; then
    echo "这台机器（$(id -un)）还没登记到入口 — 先运行：fleet host on（或只登记：fleet node join）"
    return 1
  fi
  case "$verb" in on|off)
    # separated: the store's copy is root's to write — say so before any probe
    if separated && ! credsep_setenv --check; then
      echo "✗ 凭据已隔离：node.env 在凭据库里，改它要 root 一次（上面一行是给管理员的命令）"
      return 1
    fi ;;
  esac
  case "$verb" in
    on)
      line=$(FLEET_CONF_DIR="$CONF" "$here/fleet-node-probe.sh" 2>&1); rc=$?
      [ "$rc" -le 1 ] || { echo "✗ 没测成：$line"; return 1; }
      printf '%s\n' "$line" | grep -v '^可以打开：'
      if [ "$rc" != 0 ] && [ "$force" != 1 ]; then
        echo "✗ 不打开：这台电脑不适合跑会话（上面一行是原因）。确要打开：fleet host on --force（会记进入口审计）"
        return 1
      fi
      setenv CCQUOTA_FLEET_COMPUTE 1 || { echo "✗ 写不了 $ENVF"; return 1; }
      if [ "$rc" != 0 ]; then setenv CCQUOTA_FLEET_COMPUTE_FORCE 1; else setenv CCQUOTA_FLEET_COMPUTE_FORCE ''; fi
      # personal (#1721): the flag, else the choice already made, else a laptop
      if [ -z "$personal" ]; then
        personal=$(envval CCQUOTA_FLEET_PERSONAL)
        [ -n "$personal" ] || { [ "$(laptop)" = true ] && personal=1; }
      fi
      [ -z "$personal" ] || setenv CCQUOTA_FLEET_PERSONAL "$personal"
      nudge
      if [ "$rc" != 0 ]; then
        echo "✓ 已强制打开：入口会往这台派会话、借账号（越过了本机判断，入口已记审计）"
      else
        echo "✓ 已打开：入口可以往这台派会话、借账号（下一次心跳生效；fleet host off 关回只协调）"
      fi
      if [ "$personal" = 1 ]; then personal_line; fi
      ;;
    off)
      setenv CCQUOTA_FLEET_COMPUTE 0 && setenv CCQUOTA_FLEET_COMPUTE_FORCE '' || { echo "✗ 写不了 $ENVF"; return 1; }
      nudge
      echo "✓ 已关闭：只协调 — 入口不往这台派会话、不借账号（本机跑会话用自己的账号）"
      ;;
    status)
      case "$(envval CCQUOTA_FLEET_COMPUTE)" in
        0) echo "只协调：入口不往这台派会话、不借账号（打开：fleet host on）" ;;
        *) if [ "$(envval CCQUOTA_FLEET_COMPUTE_FORCE)" = 1 ]; then echo "已强制打开（--force）"; else echo "已打开：入口可以往这台派会话"; fi
           [ "$(envval CCQUOTA_FLEET_PERSONAL)" = 1 ] && personal_line ;;
      esac
      FLEET_CONF_DIR="$CONF" "$here/fleet-node-probe.sh" --max-age 86400 2>/dev/null | grep -v '^可以打开：'
      return 0
      ;;
    *) echo "fleet node compute: on [--force] | off | status" >&2; return 2 ;;
  esac
}

cmd_status() {
  local hub tok body st label alog
  tok=$(envval CCQUOTA_TOKEN)
  hub=$(envval CCQUOTA_HUB_URL)
  if [ -z "$tok" ] && [ -n "$hub" ] && is_node; then
    # separated (#2316): the token is in the store — this login does not read it
    echo "✓ $(id -un) 登记在 ${hub}（凭据已隔离：通行证在凭据库里，本登录不读；在线与否看 fleet doctor 的 node 行）"
    return 0
  fi
  if [ -z "$tok" ] || [ -z "$hub" ]; then
    echo "这台机器（$(id -un)）还没登记到入口 — 运行：fleet host on（或只登记：fleet node join）"
    return 1
  fi
  if ! body=$(self "$hub" "$tok"); then
    echo "✗ $hub 不认这台机器的入口通行证（${ENVF}）— 重跑：fleet node join"
    return 1
  fi
  st=$(printf '%s' "$body" | jfield status)
  label="$(printf '%s' "$body" | jfield hostname)"
  [ -n "$label" ] || label=$(hostname -s 2>/dev/null || hostname)
  # separated (issue #2296): root writes the agent's log, outside the home
  alog="$HOME/.ccquota/agent.log"
  [ -f "$CONF/credsep.json" ] && alog="sudo tail /var/log/fleet-cred/$(id -un)/agent.log（凭据已隔离，日志归 root）"
  case "$st" in
    online) echo "✓ $label/$(id -un) 连着 ${hub}：在线" ;;
    *) echo "✗ $label/$(id -un) 连着 ${hub}，但入口看到的状态是「${st:-?}」— 看 $alog，或重跑：fleet node join"
       return 1 ;;
  esac
}

case "${1:-}" in
  join) shift; cmd_join "$@" ;;
  install) shift; exec "$here/fleet-node-install.sh" "$@" ;;
  status) shift; cmd_status "$@" ;;
  ensure) shift; cmd_ensure "$@" ;;
  compute) shift; cmd_compute "$@" ;;
  leave) shift; FLEET_CONF_DIR="$CONF" exec "$here/fleet-node-leave.sh" "$@" ;;
  ''|-h|--help|help) usage ;;
  *) echo "fleet node: unknown command ${1} — fleet node install | fleet node join | fleet node status | fleet node compute | fleet node leave" >&2; exit 2 ;;
esac
