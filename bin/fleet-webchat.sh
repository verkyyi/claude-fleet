#!/usr/bin/env bash
# fleet-webchat.sh — talk to a Claude session from a browser, the smallest version
# (issue #3567). The server is extras/web-chat/server.mjs: the Claude Agent SDK
# run as THIS login, on its own `claude`, each turn through the pool's credential
# proxy (a session credential from fleet-session-cred.sh, like any fleet session).
#
#   fleet-webchat.sh start            install the SDK once (pinned, into the state
#                                     dir) and start the server on 127.0.0.1
#   fleet-webchat.sh link [--tailnet|--print]
#                                     a ONE-TIME login link (10 min): opened on the
#                                     person's own computer over their ssh
#                                     (fleet-open.sh :port/…) — --tailnet puts the
#                                     loopback port behind `tailscale serve` (HTTPS,
#                                     the tailnet only) for a phone; --print only prints
#   fleet-webchat.sh status           one line: on · port · pid, or off
#   fleet-webchat.sh stop             stop it (and the tailnet route it added)
#
# Only this login's person comes in: the link is minted with admin.token, a 0600
# file in this login's 0700 state dir — another login on this machine cannot read
# it, and without a link's cookie every page is 403. No credential is ever on an
# argv, in a file here, or in the server's log (bin/fleet-webchat-selftest.sh).
#
# State: $FLEET_CONF_DIR/webchat/ (port · pid · admin.token · cookies.json, hashed ·
# server.log · deps/). FLEET_WEBCHAT_PORT (18961) · FLEET_WEBCHAT_CWD (where a new
# chat runs, $HOME) · FLEET_WEBCHAT_NODE (node).
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

start() {
  if pid_live && healthy; then echo "fleet-webchat: on · http://127.0.0.1:$(port)/ · pid $(cat "$STATE/pid")"; return 0; fi
  mkdir -p "$STATE" && chmod 700 "$STATE"
  deps
  local name hosts='' p="${FLEET_WEBCHAT_PORT:-18961}" claude
  name=$(ts_name)
  [ -n "$name" ] && hosts="$name,$name:$p"
  claude=$(command -v claude 2>/dev/null || true)
  rm -f "$STATE/port"
  # launched with no tmux pane, no fleet credential of the caller, its cwd outside any worktree
  (cd "$STATE" && env -u TMUX -u TMUX_PANE -u FLEET_WORKER_CRED -u FLEET_WORKER_ASSERT \
     FLEET_WEBCHAT_STATE="$STATE" FLEET_WEBCHAT_PORT="$p" FLEET_WEBCHAT_HOSTS="$hosts" \
     FLEET_WEBCHAT_SDK="$SDK" FLEET_WEBCHAT_CLAUDE="$claude" \
     FLEET_WEBCHAT_SESSION_CRED="$BIN/fleet-session-cred.sh" \
     nohup "$NODE" "$APP/server.mjs" >>"$STATE/server.out" 2>&1 </dev/null &)
  local i
  for i in $(seq 1 50); do healthy && break; sleep 0.2; done
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
  if pid_live; then kill "$(cat "$STATE/pid")" 2>/dev/null; fi
  rm -f "$STATE/pid" "$STATE/port"
  echo "fleet-webchat: off"
}

case "${1:-status}" in
  start) start ;;
  link) shift; link "${1:-open}" ;;
  stop) stop ;;
  status) if pid_live && healthy; then echo "on · http://127.0.0.1:$(port)/ · pid $(cat "$STATE/pid")$([ -f "$STATE/tailnet" ] && echo ' · tailnet')"; else echo off; fi ;;
  -h|--help|help) sed -n '2,26p' "$0" ;;
  *) die "usage: fleet-webchat.sh start|link [--tailnet|--print]|status|stop" 2 ;;
esac
