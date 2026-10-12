#!/usr/bin/env bash
# fleet-webchat.sh — talk to a Claude session from a browser, the smallest version
# (issue #3567). The server is extras/web-chat/server.mjs: the Claude Agent SDK
# run as THIS login, on its own `claude`, each turn through the pool's credential
# proxy (a session credential from fleet-session-cred.sh, like any fleet session).
#
# The road (issue #3643, EPIC #3642): the server is a registered service of this
# login (docs/dev/MANAGED-NODE.md §10) listening only on the unix socket
# $FLEET_CONF_DIR/webchat/chat.sock (0600, its dir 0700) — the node program's
# relay (C2) is what reaches it. No TCP port, no login link, no admin.token.
#
#   fleet-webchat.sh serve            run the server on the socket, in the
#                                     foreground (what the service runs)
#   fleet-webchat.sh enable           register it: fleet service add webchat
#                                     --path <state dir> -- fleet-webchat.sh serve
#   fleet-webchat.sh disable          fleet service rm webchat
#   fleet-webchat.sh ensure           on demand (issue #3647, D1): registered when
#                                     missing, started when stopped or idle, then
#                                     waits for the socket's /healthz (3 tries) —
#                                     the daemon's `service ensure`, the same one
#                                     the node runs when a person opens /chat
#   fleet-webchat.sh move --to <login>
#                                     the chat follows its person (C5): fleet service
#                                     move webchat — the state dir (conversation.json,
#                                     chain, transcripts/) goes to <login>'s home, the
#                                     server there puts the transcripts back
#   fleet-webchat.sh status           one line: socket on · pid, local on · port, or off
#
# Idle: the server exits 75 after FLEET_WEBCHAT_IDLE_SECS (7200) with no turn and
# no page connected; the daemon keeps it off (`idle`), the entry kept, until the
# next ensure.
#
# The local mode — 127.0.0.1 + a one-time link — is kept for developing and
# debugging, OFF by default (D3): FLEET_WEBCHAT_LOCAL=1 turns on these four.
#   fleet-webchat.sh start            install the SDK once (pinned, into the state
#                                     dir) and start the server on 127.0.0.1
#   fleet-webchat.sh link [--tailnet|--print]
#                                     a ONE-TIME login link (10 min): opened on the
#                                     person's own computer over their ssh
#                                     (fleet-open.sh :port/…) — --tailnet puts the
#                                     loopback port behind `tailscale serve` (HTTPS,
#                                     the tailnet only) for a phone; --print only prints
#   fleet-webchat.sh stop             stop it (and the tailnet route it added)
#
# Socket mode: only this login can connect (the file's mode, the dir's mode).
# Local mode: only this login's person comes in: the link is minted with admin.token, a 0600
# file in this login's 0700 state dir — another login on this machine cannot read
# it, and without a link's cookie every page is 403. No credential is ever on an
# argv, in a file here, or in the server's log (bin/fleet-webchat-selftest.sh).
#
# State: $FLEET_CONF_DIR/webchat/ (chat.sock · pid · conversation.json · budget.json ·
# transcripts/ · server.log · deps/; local mode adds port · admin.token · cookies.json, hashed).
# FLEET_WEBCHAT_PORT (18961) · FLEET_WEBCHAT_CWD (where a new chat runs, $HOME) ·
# FLEET_WEBCHAT_NODE (node) · FLEET_WEBCHAT_SERVICE (the `fleet service` command).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
STATE="$CONF/webchat"
APP="$BIN/../extras/web-chat"
DEPS="$STATE/deps"
SDK="$DEPS/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
NODE="${FLEET_WEBCHAT_NODE:-node}"
die() { printf 'fleet-webchat: %s\n' "$1" >&2; exit "${2:-1}"; }

pid_live() { local p; p=$(cat "$STATE/pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
port() { cat "$STATE/port" 2>/dev/null; }
healthy() { local p; p=$(port) && [ -n "$p" ] && curl -fsS -m 3 "http://127.0.0.1:$p/healthz" >/dev/null 2>&1; }
sock_healthy() { [ -S "$STATE/chat.sock" ] && curl -fsS -m 3 --unix-socket "$STATE/chat.sock" http://webchat/healthz >/dev/null 2>&1; }
local_on() { [ "${FLEET_WEBCHAT_LOCAL:-0}" = 1 ] || die "the local mode (127.0.0.1 + a login link) is off — FLEET_WEBCHAT_LOCAL=1 turns it on (the road is the socket service: fleet-webchat.sh enable)" 2; }
SERVICE=${FLEET_WEBCHAT_SERVICE:-"$BIN/fleet-service.sh"}

ts_bin() {
  local t; t=$(command -v tailscale 2>/dev/null) || t=''
  [ -z "$t" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && t=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  printf '%s' "$t"
}
ts_name() { # this machine's MagicDNS name, or nothing
  local t; t=$(ts_bin); [ -n "$t" ] || return 0
  "$t" status --json 2>/dev/null | python3 -I -c 'import json,sys
try: print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))
except Exception: pass' 2>/dev/null
}

serve_routed() { # <tailscale> <name> <port> — rc 0 ⇔ https://<name>:<port>/ already proxies to our loopback port
  "$1" serve status --json 2>/dev/null | python3 -I -c 'import json,sys
name, port = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
h = ((d.get("Web") or {}).get("%s:%s" % (name, port)) or {}).get("Handlers") or {}
sys.exit(0 if any((v or {}).get("Proxy", "").rstrip("/") in ("http://127.0.0.1:" + port, "127.0.0.1:" + port) for v in h.values()) else 1)' "$2" "$3"
}

deps() { # the pinned SDK, installed once per lockfile into the state dir (no optional native binary: the login's own claude runs)
  command -v "$NODE" >/dev/null 2>&1 || die "node not found (FLEET_WEBCHAT_NODE)"
  command -v npm >/dev/null 2>&1 || die "npm not found"
  if [ -f "$SDK" ] && cmp -s "$APP/package-lock.json" "$DEPS/package-lock.json"; then return 0; fi
  mkdir -p "$DEPS" && cp "$APP/package.json" "$APP/package-lock.json" "$DEPS/" || die "cannot write $DEPS"
  (cd "$DEPS" && npm ci --omit=optional --no-audit --no-fund --loglevel=error >/dev/null) || die "npm ci failed in $DEPS"
  [ -f "$SDK" ] || die "the Agent SDK did not install ($SDK)"
}

# the environment both modes run the server with: no tmux pane, no fleet
# credential of the caller, its cwd outside any worktree
server_env() {
  env -u TMUX -u TMUX_PANE -u FLEET_WORKER_CRED -u FLEET_WORKER_ASSERT \
    FLEET_WEBCHAT_STATE="$STATE" FLEET_WEBCHAT_SDK="$SDK" FLEET_WEBCHAT_CLAUDE="$(command -v claude 2>/dev/null || true)" \
    FLEET_WEBCHAT_SESSION_CRED="$BIN/fleet-session-cred.sh" "$@"
}

serve() { # the service's command: the socket, in the foreground
  mkdir -p "$STATE" && chmod 700 "$STATE"
  deps
  cd "$STATE" || die "cannot enter $STATE"
  server_env "$NODE" "$APP/server.mjs" --socket
}

start() {
  if pid_live && healthy; then echo "fleet-webchat: on · http://127.0.0.1:$(port)/ · pid $(cat "$STATE/pid")"; return 0; fi
  mkdir -p "$STATE" && chmod 700 "$STATE"
  deps
  local name hosts='' p="${FLEET_WEBCHAT_PORT:-18961}"
  name=$(ts_name)
  [ -n "$name" ] && hosts="$name,$name:$p"
  rm -f "$STATE/port"
  (cd "$STATE" && server_env FLEET_WEBCHAT_LOCAL=1 FLEET_WEBCHAT_PORT="$p" FLEET_WEBCHAT_HOSTS="$hosts" \
     nohup "$NODE" "$APP/server.mjs" >>"$STATE/server.out" 2>&1 </dev/null &)
  local _
  for _ in $(seq 1 50); do healthy && break; sleep 0.2; done
  healthy || die "the server did not come up (see $STATE/server.out)"
  echo "fleet-webchat: on · http://127.0.0.1:$(port)/ · pid $(cat "$STATE/pid")"
}

mint_link() { # → the one-time path; the admin token goes over stdin-read file, never an argv
  python3 -I - "$STATE" <<'PY'
import json, sys, urllib.request
st = sys.argv[1]
port = open(st + "/port").read().strip()
tok = open(st + "/admin.token").read().strip()
req = urllib.request.Request("http://127.0.0.1:%s/api/link" % port, data=b"{}", method="POST",
                             headers={"X-Fleet-Webchat-Admin": tok, "Host": "127.0.0.1:%s" % port})
print(json.load(urllib.request.urlopen(req, timeout=5))["path"])
PY
}

link() {
  local how="${1:-open}" lpath p t name
  start >/dev/null || exit 1
  p=$(port); lpath=$(mint_link) || die "could not mint a login link"
  case "$how" in
    --print) echo "http://127.0.0.1:$p$lpath" ;;
    --tailnet)
      t=$(ts_bin); name=$(ts_name)
      [ -n "$t" ] && [ -n "$name" ] || die "no tailnet here (tailscale not found / not up) — use: fleet-webchat.sh link"
      if serve_routed "$t" "$name" "$p"; then :                      # an admin's route (sudo, once) — kept
      elif "$t" serve --bg --https="$p" "http://127.0.0.1:$p" >/dev/null 2>&1; then echo "$p" >"$STATE/tailnet"
      else die "this login is not tailscale's operator — an admin runs once: sudo tailscale serve --bg --https=$p http://127.0.0.1:$p   (or: fleet-webchat.sh link, over ssh)"
      fi
      echo "https://$name:$p$lpath   (一次性，10 分钟内有效；只在 tailnet 里能打开)" ;;
    open|'')
      echo "http://127.0.0.1:$p$lpath   (一次性，10 分钟内有效)"
      bash "$BIN/fleet-open.sh" ":$p$lpath" 2>/dev/null || true ;;
    *) die "usage: fleet-webchat.sh link [--tailnet|--print]" 2 ;;
  esac
}

stop() {
  local p t
  if [ -f "$STATE/tailnet" ]; then
    p=$(cat "$STATE/tailnet"); t=$(ts_bin)
    [ -n "$t" ] && "$t" serve --https="$p" off >/dev/null 2>&1
    rm -f "$STATE/tailnet"
  fi
  # the socket server is a service: its daemon would only start it again
  if [ -f "$STATE/port" ] && pid_live; then kill "$(cat "$STATE/pid")" 2>/dev/null; rm -f "$STATE/pid"; fi
  rm -f "$STATE/port"
  if sock_healthy; then echo "fleet-webchat: local off · the socket service still runs (fleet-webchat.sh disable)"; else echo "fleet-webchat: off"; fi
}

enable() { # register the socket server as this login's service; its state dir travels with it (service move)
  [ -e "$SERVICE" ] || die "no fleet service here ($SERVICE)"
  mkdir -p "$STATE" && chmod 700 "$STATE"
  bash "$SERVICE" add webchat --path "$STATE" -- "$BIN/fleet-webchat.sh" serve
}
disable() {
  [ -e "$SERVICE" ] || die "no fleet service here ($SERVICE)"
  bash "$SERVICE" rm webchat
}
ensure() { # the daemon's own `service ensure` (root, through fleet service's sudo road)
  [ -e "$SERVICE" ] || die "no fleet service here ($SERVICE)"
  if sock_healthy; then echo "fleet-webchat: on · socket $STATE/chat.sock"; return 0; fi
  bash "$SERVICE" __root ensure --login "${FLEET_SERVICE_LOGIN:-$(id -un)}" --name webchat --wait 3
}
move() {
  [ "${1:-}" = --to ] && [ -n "${2:-}" ] || die "usage: fleet-webchat.sh move --to <login>" 2
  [ -e "$SERVICE" ] || die "no fleet service here ($SERVICE)"
  bash "$SERVICE" move webchat --to "$2"
}

case "${1:-status}" in
  serve) serve ;;
  enable) enable ;;
  disable) disable ;;
  ensure) ensure ;;
  move) shift; move "$@" ;;
  start) local_on; start ;;
  link) local_on; shift; link "${1:-open}" ;;
  stop) stop ;;
  status)
    if sock_healthy; then echo "on · socket $STATE/chat.sock · pid $(cat "$STATE/pid" 2>/dev/null)"
    elif pid_live && healthy; then echo "on · local http://127.0.0.1:$(port)/ · pid $(cat "$STATE/pid")$([ -f "$STATE/tailnet" ] && echo ' · tailnet')"
    else echo off; fi ;;
  -h|--help|help) sed -n '2,54p' "$0" ;;
  *) die "usage: fleet-webchat.sh serve|enable|disable|ensure|move --to <login>|status   (FLEET_WEBCHAT_LOCAL=1: start|link [--tailnet|--print]|stop)" 2 ;;
esac
