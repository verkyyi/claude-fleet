#!/usr/bin/env bash
# Render Markdown -> styled HTML and host it on this machine's Tailscale tailnet URL.
#
# Multi-session safe: all shares APPEND to one shared collection behind a FIXED URL.
# A new share never removes existing shared docs or changes the URL; the index page
# lists everything currently being shared (across every session of this login).
#
#   share.sh <file.md|file.html> [more ...]   # add doc(s)/page(s) to the shared list; prints READY <url>
#   share.sh --ttl 3d <file> [more ...]  # the link stops working after 3d (default 7d; N[smhd], 0 = never)
#   share.sh --tunnel <file> [more ...]  # same, but on a PUBLIC cloudflared quick tunnel — no tailnet
#                                      # (.md → GitHub-styled viewer; .html → served as-is, #526)
#   share.sh --local <file> [more ...] # same, but NO tailscale: the loopback server only; prints
#                                      # READY http://127.0.0.1:<port>/d/<code>/ — hand it to fleet-open
#   share.sh --open [--local] <file>   # share, then bin/fleet-open.sh the doc URL: it opens in the
#                                      # operator's OWN browser over their ssh (issue #1379)
#   share.sh --list                    # show what is currently shared (+ the time each has left)
#   share.sh --remove <substr>         # drop entries whose id/title/path matches <substr>
#   share.sh --refresh                 # re-render all shared docs with the current template
#                                        (same URLs; also picks up source-file edits)
#   share.sh --publish [--ttl 7d] <id|substr>  # expose ONE doc publicly via Funnel; prints its /p/<code>/ URL
#   share.sh --unpublish <id|substr>   # take that doc back off the public internet (verified, or exit 1)
#   share.sh --pubstatus <id|substr>   # print whether a doc is public + its URL
#   share.sh --health                  # one line for fleet-doctor: public mounts, their age, serve routes
#   share.sh --upgrade [--check]       # restart a server.py older than this copy, same port (#2415)
#   share.sh --stop                    # tear everything down (all sessions; public links off)
#
# Every link carries a code (issue #1153): a doc is /d/<128-bit random code>/, the
# index /i/<this login's index code>/, a public link /p/<its own random code>/. The
# server answers 404 to anything else — `/`, a directory, a wrong or EXPIRED code — so
# a link cannot be guessed, and another login on this machine reaching the port sees
# nothing. A doc expires --ttl after it was shared (default 7 days, DOC_PREVIEW_TTL), a
# public link --ttl after it was published (default 7 days, DOC_PREVIEW_PUBLISH_TTL);
# server.py enforces both on every request (its `--tool` half is the one copy of that
# rule share.sh reads), and every share.sh run prunes what has expired. --refresh keeps
# every link as it is. A pre-#1153 doc keeps its old link until 7 days after it was
# shared. A running server.py from an older version is restarted on the SAME port —
# by the next share, or at once by `share.sh --upgrade` (install-apply runs it, #2415).
#
# Publishing is per-document and normally driven by the in-page "公开链接" toggle (shown only
# when the doc is viewed over the tailnet). Tailnet sharing stays private; only explicitly
# published docs are reachable on the public internet, each at its own /p/<code>/ path.
#
# Two serving modes, recorded in $ROOT/mode (issue #1093):
#   https        the loopback server.py fronted by `tailscale serve` (HTTPS on the tailnet).
#                ONE tailnet port per login: a restarted server re-points the route it
#                had, never opens another, and every run drops the extra routes that
#                point at this server or at a dead port this login once served.
#   http-direct  the login is NOT tailscale's operator (one per machine) and has no root,
#                so `tailscale serve` is refused: server.py binds this machine's tailscale
#                IPv4 directly and the URL is http://<magicdns>:<port>/ — plain http, but
#                only reachable inside the tailnet, whose link is WireGuard-encrypted.
#                Sticky until --stop; public (Funnel) links need serve rights, so none here.
#   tunnel       no tailnet at all (issue #1151): opt-in with --tunnel or DOC_PREVIEW_MODE=tunnel.
#                server.py on loopback in its `public` mode, fronted by `cloudflared tunnel
#                --url` (a quick tunnel: no account, no config). The URL is a random
#                https://<words>.trycloudflare.com — PUBLIC to anyone who has a link;
#                doc headers + source paths are stripped and /_ctl is 404.
#                Sticky until --stop. The hostname changes whenever cloudflared restarts
#                (reboot, --stop), so old links die with it: a live preview, not hosting.
#   local        no tailnet involved (issue #1379): opt-in with --local or DOC_PREVIEW_MODE=local
#                (set it in the login shell of a machine whose readers have no tailnet). server.py on
#                127.0.0.1 only (#1154), the URL http://127.0.0.1:<port>/ — reachable from
#                this machine alone, which is the point: bin/fleet-open.sh forwards it to the
#                operator's browser over their ssh. A later share WITHOUT --local turns it
#                into https (same loopback server, `tailscale serve` added). --local beside
#                an https or tunnel share reuses their loopback server and only prints the
#                loopback URL; beside http-direct (server on the tailnet IP) it refuses.
#
# tailscale: the CLI on PATH, else the App's own binary (called directly — a symlink to
# it crashes on its bundleIdentifier); DOC_PREVIEW_TAILSCALE overrides. Every tailscale
# step that changes what is public checks its exit code AND re-reads `funnel status`:
# --unpublish never prints OFF while the mount is still there.
#
# Set DOC_PREVIEW_SESSION to label your session in the list (default: hostname).
# No npm install needed: rendering is client-side (CDN libs in the viewer's browser).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$HERE/server.py"
ROOT="$HOME/.cache/claude-doc-preview"
SERVE_DIR="$ROOT/serve"
ENTRIES_DIR="$ROOT/entries"
PIDFILE="$ROOT/server.pid"
PORTFILE="$ROOT/server.port"
HTTPSFILE="$ROOT/https.port"
FUNNELPORTFILE="$ROOT/funnel.port"   # tailnet HTTPS port used for public (Funnel) doc mounts
MODEFILE="$ROOT/mode"                # https | http-direct | tunnel | local (see the header)
TUNNELPIDFILE="$ROOT/tunnel.pid"     # tunnel mode: the cloudflared process
TUNNELURLFILE="$ROOT/tunnel.url"     # …its https://*.trycloudflare.com origin
TUNNELPORTFILE="$ROOT/tunnel.port"   # …and the loopback port it fronts
VERFILE="$ROOT/server.ver"           # cksum of the server.py that is running (restart on change)
OWNEDFILE="$ROOT/served.ports"       # every loopback port this login's server has listened on
INDEXFILE="$ROOT/index.token"        # this login's index code: /i/<code>/
LOCK="$ROOT/.lock"
SESSION="${DOC_PREVIEW_SESSION:-$(hostname -s 2>/dev/null || echo session)}"

umask 077   # the codes live in these files: this login only
mkdir -p "$ROOT" "$SERVE_DIR/d" "$ENTRIES_DIR"
chmod 700 "$ROOT" 2>/dev/null || true

# --- tailscale CLI -----------------------------------------------------------
TS_APP="${DOC_PREVIEW_TAILSCALE_APP:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
TS_BIN="${DOC_PREVIEW_TAILSCALE:-}"
if [ -z "$TS_BIN" ]; then
  TS_BIN="$(command -v tailscale 2>/dev/null || true)"
  # A symlink to the App's binary dies on its bundleIdentifier: call the App path itself.
  if [ -n "$TS_BIN" ] && [ -L "$TS_BIN" ] && [ -x "$TS_APP" ]; then
    case "$(readlink "$TS_BIN" 2>/dev/null)" in */Tailscale.app/Contents/MacOS/Tailscale) TS_BIN="$TS_APP" ;; esac
  fi
  if [ -z "$TS_BIN" ] && [ -x "$TS_APP" ]; then TS_BIN="$TS_APP"; fi
fi
ts() { [ -n "$TS_BIN" ] || return 127; "$TS_BIN" "$@"; }
# server.py --tool: the expiry rule + entry edits — one implementation with the server.
tool() { python3 "$SRV" --tool "$1" "$ROOT" "${@:2}"; }
new_code() { python3 -c 'import secrets;print(secrets.token_hex(16))'; }
index_code() {
  [ -s "$INDEXFILE" ] || new_code >"$INDEXFILE"
  cat "$INDEXFILE"
}

host() { ts status --json | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))"; }
rebuild_index() { node "$HERE/render.mjs" index "$SERVE_DIR/index.html" "$ENTRIES_DIR" >/dev/null; }
# Serving mode; an install from before the mode file existed is https iff it has a route.
mode() {
  if [ -f "$MODEFILE" ]; then cat "$MODEFILE"; elif [ -f "$HTTPSFILE" ]; then echo https; fi
}
sharing() { [ -f "$HTTPSFILE" ] || [ "$(mode)" = http-direct ] || [ "$(mode)" = tunnel ] || [ "$(mode)" = local ]; }
local_url() { echo "http://127.0.0.1:$(cat "$PORTFILE" 2>/dev/null)/"; }
current_url() {
  if [ "$(mode)" = local ]; then local_url; return; fi
  if [ "$(mode)" = tunnel ]; then echo "$(cat "$TUNNELURLFILE" 2>/dev/null)/"; return; fi
  if [ "$(mode)" = http-direct ]; then echo "http://$(host):$(cat "$PORTFILE" 2>/dev/null)/"; return; fi
  local hp sfx=""; hp="$(cat "$HTTPSFILE" 2>/dev/null || echo 443)"
  [ "$hp" = 443 ] || sfx=":$hp"
  echo "https://$(host)$sfx/"
}

ts_ip4() { ts ip -4 2>/dev/null | head -1; }
# A real bind() probe, NOT lsof: lsof lists only this login's sockets, so a port held by
# ANOTHER login's doc-preview server looked free and our server.py died on EADDRINUSE
# after share.sh had already recorded its pid/port (issue #1093).
# SO_REUSEADDR as server.py's own bind() has it (allow_reuse_address): a port in TIME_WAIT
# after our restart is free to it, a port another socket LISTENs on is not.
port_free() { # <addr> <port>
  python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: s.bind((sys.argv[1],int(sys.argv[2])))
except OSError: sys.exit(1)' "$1" "$2"
}
port_up() { # <addr> <port> — is something accepting connections there?
  python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(0.5)
sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$1" "$2"
}
# Start ONE server.py on <addr> at the first free port from [first port] (default
# DOC_PREVIEW_PORT). pid/port are recorded only once it ANSWERS, so a failed start never
# leaves a half-written state. On failure START_FAIL says what the LAST launch did —
# exited, or alive but never accepting (issue #1500: five launches sat
# bound-but-not-listening for ~34s each, and "busy or bind refused" sent the reader to the
# wrong place for ten nightlies).
START_FAIL=""
start_server() { # <addr> [public] [first port]; sets PORT
  local addr="$1" pub="${2:-}" p="${3:-${DOC_PREVIEW_PORT:-8765}}" end launches=0 pid
  end=$((p + 50))
  START_FAIL="could not bind $addr on any port in $p..$((end - 1)) (all busy, or $addr is not an address of this machine)"
  rm -f "$PIDFILE" "$PORTFILE"
  while [ "$p" -lt "$end" ] && [ "$launches" -lt 5 ]; do
    if port_free "$addr" "$p"; then
      launches=$((launches + 1))
      # Its own session (setsid; macOS has no setsid(1)): a launchd job that restarts it
      # (install-apply's --upgrade, issue #2415) would otherwise take it down on exit.
      nohup python3 -c 'import os, sys
try: os.setsid()
except OSError: pass
os.execvp(sys.argv[1], sys.argv[1:])' python3 "$SRV" "$p" "$SERVE_DIR" "$HERE" "$addr" $pub >"$ROOT/server.log" 2>&1 &
      pid=$!
      START_FAIL="server.py (pid $pid) exited before it accepted a connection on $addr:$p"
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        if port_up "$addr" "$p"; then
          echo "$pid" >"$PIDFILE"; echo "$p" >"$PORTFILE"; PORT="$p"
          cksum <"$SRV" | awk '{print $1}' >"$VERFILE"
          grep -qx "$p" "$OWNEDFILE" 2>/dev/null || echo "$p" >>"$OWNEDFILE"
          return 0
        fi
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then   # alive but never came up (stuck before listen()): next one
        START_FAIL="server.py (pid $pid) was still running but never accepted a connection on $addr:$p — stuck between bind() and listen()"
        kill "$pid" 2>/dev/null || true
      fi
    fi
    p=$((p + 1))
  done
  return 1
}
srv_ver() { cksum <"$SRV" | awk '{print $1}'; }
# Our recorded server is alive but was started from another server.py (no server.ver =
# from before #1153, which knew no codes) — it keeps serving the old rules until restarted.
server_stale() {
  [ -f "$PIDFILE" ] && [ -f "$PORTFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null \
    && [ "$(cat "$VERFILE" 2>/dev/null)" != "$(srv_ver)" ]
}
# This login's server.py processes of THIS install that server.pid does not name — a pid
# file lost or overwritten leaves one serving whatever rules it started with (issue #2415).
stray_servers() {
  local me pid; me="$(cat "$PIDFILE" 2>/dev/null || true)"
  for pid in $(pgrep -u "$(id -u)" -f "$SRV [0-9]+ $SERVE_DIR " 2>/dev/null || true); do
    [ "$pid" = "$me" ] || echo "$pid"
  done
}
# The address (and public flag) the server binds in <mode>; sets ADDR, PUB.
server_addr() { # <mode>
  PUB=""
  if [ "$1" = http-direct ]; then
    ADDR="$(ts_ip4)"; [ -n "$ADDR" ] || { echo "doc-preview: no tailscale IPv4 (tailscale ip -4)" >&2; return 1; }
  else
    ADDR=127.0.0.1
    [ "$1" = tunnel ] && PUB=public
  fi
  return 0
}
# Replace a stale server on the SAME port (its tailscale serve route / tunnel stay valid).
restart_server() {
  local oldpid; oldpid="$(cat "$PIDFILE")"; PORT="$(cat "$PORTFILE")"
  kill "$oldpid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$oldpid" 2>/dev/null || break; sleep 0.1; done
  start_server "$ADDR" "$PUB" "$PORT"
}
# The tailnet HTTPS port whose "/" already proxies to 127.0.0.1:<port>, if any — e.g. a
# route an admin set up once with `sudo tailscale serve` for a non-operator login.
serve_route_port() { # <port>
  ts serve status --json 2>/dev/null | python3 -c '
import sys, json
want = "http://127.0.0.1:" + sys.argv[1]
try: web = (json.load(sys.stdin) or {}).get("Web") or {}
except Exception: sys.exit(0)
for hostport, cfg in web.items():
    if (((cfg or {}).get("Handlers") or {}).get("/") or {}).get("Proxy", "").rstrip("/") == want:
        print(hostport.rsplit(":", 1)[1] if ":" in hostport else "443"); break
' "$1" 2>/dev/null || true
}
# Every tailnet HTTPS port tailscale serve already uses (any login's), one per line.
serve_ports() {
  ts serve status --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin) or {}
except Exception: sys.exit(0)
ps = set((d.get("TCP") or {}).keys()) | {h.rsplit(":", 1)[1] for h in (d.get("Web") or {}) if ":" in h}
print("\n".join(sorted(ps)))' 2>/dev/null || true
}
# Drop the routes that leak (issue #1153: ~260 on one machine): every OTHER tailnet port
# whose "/" proxies to this server, and every route to a dead loopback port this login's
# server once used. Another login's routes are never touched.
serve_gc() { # <keep port> <our server port>
  local hp be kind
  ts serve status --json 2>/dev/null | tool routes "$2" "$OWNEDFILE" 2>/dev/null | while read -r hp be kind; do
    [ "$hp" = "$1" ] && continue
    case "$kind" in
      ours|dup|dead) ts serve --https="$hp" off >/dev/null 2>&1 || echo "doc-preview: could not drop the stale serve route :$hp → 127.0.0.1:$be" >&2 ;;
    esac
  done
}

# --- public (Funnel) helpers: expose ONE document at a time via a per-doc path mount ---
# Funnel only supports ports 443/8443/10000; reuse a recorded one, else the first locally free.
pick_funnel_port() {
  local fp; fp="$(cat "$FUNNELPORTFILE" 2>/dev/null || true)"
  if [ -n "$fp" ]; then echo "$fp"; return; fi
  for p in 443 8443 10000; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || { echo "$p"; return; }
  done
  echo 10000
}
funnel_url() { # <public code> <fport>
  local sfx=""; [ "$2" = 443 ] || sfx=":$2"
  echo "https://$(host)$sfx/p/$1/"
}
# The funnel's mounts, one /p/<x> per line; rc != 0 = tailscale could not say (never "none").
funnel_mounts() {
  local out; out="$(ts funnel status 2>/dev/null)" || return 1
  printf '%s\n' "$out" | sed -n 's#.*\(/p/[0-9a-zA-Z-]*\) proxy.*#\1#p'
}
is_mounted() { funnel_mounts | grep -qx "/p/$1"; }   # <public code | legacy id>
# Is doc <id> public right now: its entry holds a public code AND the funnel mounts it.
# (A pre-#1153 doc was mounted at /p/<its id> — that counts too.)
is_published() { # <id>
  local pc; pc="$(tool get "$1" pub)"
  { [ -n "$pc" ] && is_mounted "$pc"; } || is_mounted "$1"
}
# Take doc <id>'s public link down and PROVE it: tailscale's exit code, then funnel status.
# rc 0 = not mounted any more (entry cleared); 1 = still mounted / could not verify (ERR).
ERR=""
unpublish_doc() { # <id>
  local id="$1" pc fp rc m mounts
  [ -n "$TS_BIN" ] || { ERR="tailscale CLI not found (not on PATH, no $TS_APP) — cannot take /p/ links down"; return 1; }
  pc="$(tool get "$id" pub)"; fp="$(pick_funnel_port)"
  for m in $pc $id; do
    mounts="$(funnel_mounts)" || { ERR="tailscale funnel status failed — cannot tell whether /p/$m is still public"; return 1; }
    printf '%s\n' "$mounts" | grep -qx "/p/$m" || continue
    rc=0; ts funnel --https="$fp" --set-path="/p/$m" off >/dev/null 2>&1 || rc=$?
    mounts="$(funnel_mounts)" || { ERR="tailscale funnel status failed after off — cannot verify /p/$m is gone"; return 1; }
    if printf '%s\n' "$mounts" | grep -qx "/p/$m"; then
      ERR="tailscale funnel off failed (exit $rc) — /p/$m is STILL public"; return 1
    fi
  done
  tool set "$id" pub= pub_since= pub_expires= 2>/dev/null || true
  return 0
}
# Drop doc <id> entirely (entry + page), its public link first.
drop_doc() { # <id>
  local id="${1:?}"
  if [ -n "$TS_BIN" ] && ! unpublish_doc "$id"; then echo "doc-preview: $ERR" >&2; fi
  rm -f "${ENTRIES_DIR:?}/$id.json"; rm -rf "${SERVE_DIR:?}/d/$id"
}
# Expired docs go (server.py already 404s them); an expired PUBLIC link is taken down.
prune() {
  local id n=0
  for id in $(tool expired 2>/dev/null); do drop_doc "$id"; n=$((n + 1)); done
  for id in $(tool pub-expired 2>/dev/null); do
    unpublish_doc "$id" || echo "doc-preview: $ERR" >&2
  done
  [ "$n" = 0 ] || rebuild_index
}
resolve_id() { # <arg> -> the single matching entry id, or empty
  local a="$1" id hit=()
  [ -n "$a" ] || return 0
  if [ -d "$SERVE_DIR/d/$a" ] && [ -f "$ENTRIES_DIR/$a.json" ]; then echo "$a"; return 0; fi
  for j in "$ENTRIES_DIR"/*.json; do
    [ -e "$j" ] || continue
    id="$(basename "$j" .json)"
    if [ "$id" = "$a" ] || [[ "$id" == *"$a"* ]] || grep -qi -- "$a" "$j"; then hit+=("$id"); fi
  done
  [ "${#hit[@]}" = 1 ] && echo "${hit[0]}"
}
stop_tunnel() {
  [ -f "$TUNNELPIDFILE" ] && kill "$(cat "$TUNNELPIDFILE")" 2>/dev/null || true
  rm -f "$TUNNELPIDFILE" "$TUNNELURLFILE" "$TUNNELPORTFILE"
}
# Tunnel mode: ONE cloudflared quick tunnel fronting 127.0.0.1:<port>. Reused while it is
# alive and still points at <port> (keeps the URL fixed); else (re)started, and recorded
# only once its trycloudflare URL shows up in the log.
ensure_tunnel() { # <port>
  local port="$1" pid url
  if [ -f "$TUNNELPIDFILE" ] && kill -0 "$(cat "$TUNNELPIDFILE")" 2>/dev/null \
     && [ "$(cat "$TUNNELPORTFILE" 2>/dev/null)" = "$port" ] && [ -s "$TUNNELURLFILE" ]; then
    return 0
  fi
  stop_tunnel
  nohup cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$port" >"$ROOT/tunnel.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 $(( ${DOC_PREVIEW_TUNNEL_WAIT:-30} * 5 ))); do
    kill -0 "$pid" 2>/dev/null || break
    url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$ROOT/tunnel.log" 2>/dev/null | head -1 || true)"
    if [ -n "$url" ]; then
      echo "$pid" >"$TUNNELPIDFILE"; echo "$url" >"$TUNNELURLFILE"; echo "$port" >"$TUNNELPORTFILE"
      return 0
    fi
    sleep 0.2
  done
  kill "$pid" 2>/dev/null || true
  return 1
}
# Turn off every /p/ Funnel mount (used by --stop).
unpublish_all() {
  [ -n "$TS_BIN" ] || return 0
  local fp m; fp="$(cat "$FUNNELPORTFILE" 2>/dev/null || true)"; [ -n "$fp" ] || return 0
  for m in $(funnel_mounts); do
    ts funnel --https="$fp" --set-path="$m" off >/dev/null 2>&1 || true
  done
  if funnel_mounts | grep -q .; then
    echo "doc-preview: WARNING — public mounts still up after --stop: $(funnel_mounts | tr '\n' ' ')" >&2
  fi
}

stop() {
  unpublish_all
  stop_tunnel
  ts serve reset >/dev/null 2>&1 || true
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  pkill -f "http.server" 2>/dev/null || true
  pkill -f "doc-preview/server.py" 2>/dev/null || true
  rm -rf "$SERVE_DIR" "$ENTRIES_DIR" "$PIDFILE" "$PORTFILE" "$HTTPSFILE" "$FUNNELPORTFILE" "$MODEFILE" "$VERFILE"
  echo "doc-preview stopped (all shared docs removed, public links off, tunnel closed, tailscale serve reset)."
}

case "${1:-}" in
  --stop) stop; exit 0 ;;
  --health)
    # fleet-doctor's docprev row reads this one line (issue #1153); server_stale (#2415)
    # counts this login's running server.py processes that serve an older copy.
    _st=0; server_stale && _st=1; _st=$((_st + $(stray_servers | wc -l)))
    echo "$({ ts serve status --json 2>/dev/null || true; } | tool health "$OWNEDFILE" "$(cat "$PORTFILE" 2>/dev/null || echo 0)") server_stale=$_st"
    exit 0 ;;
  --upgrade)
    # Run by fleet-install-apply.sh after the skills pass (issue #2415): a server.py
    # started before an install keeps the OLD rules until something restarts it — on
    # m4 one from before #1153 listed every share to anyone on the machine for a day.
    # Restart it on the SAME port now, and end any untracked copy, rather than wait
    # for the next share. --check: report only (exit 1 = something stale).
    if [ "${2:-}" = --check ]; then
      _bad=0
      server_stale && { echo "doc-preview: server.py pid $(cat "$PIDFILE") on :$(cat "$PORTFILE") runs an older copy"; _bad=1; }
      for _p in $(stray_servers); do echo "doc-preview: untracked server.py pid $_p"; _bad=1; done
      exit "$_bad"
    fi
    for _ in $(seq 1 100); do mkdir "$LOCK" 2>/dev/null && break || sleep 0.2; done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    for _p in $(stray_servers); do kill "$_p" 2>/dev/null && echo "doc-preview: ended untracked server.py pid $_p"; done
    if ! server_stale; then echo "doc-preview: server.py current (or none running)"; exit 0; fi
    server_addr "$(mode)" || exit 1
    if restart_server; then echo "doc-preview: restarted server.py on :$PORT with the installed copy"; exit 0; fi
    rm -f "$PIDFILE" "$PORTFILE"
    echo "doc-preview: could not restart server.py — ${START_FAIL:-}; the next share starts one" >&2
    exit 1 ;;
  --pubstatus|--publish|--unpublish)
    act="$1"; arg=""; json=0; pttl="${DOC_PREVIEW_PUBLISH_TTL:-7d}"; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json=1 ;;
        --ttl) pttl="${2:-}"; shift ;;
        --ttl=*) pttl="${1#--ttl=}" ;;
        *) [ -z "$arg" ] && arg="$1" ;;
      esac
      shift
    done
    fail() { [ "$json" = 1 ] && echo "{\"error\":\"$1\"}" || echo "$1" >&2; exit 1; }
    emit() { # <public true|false> <url-or-empty>
      if [ "$json" = 1 ]; then
        [ -n "$2" ] && echo "{\"public\":$1,\"url\":\"$2\",\"id\":\"$id\"}" \
                    || echo "{\"public\":$1,\"url\":null,\"id\":\"$id\"}"
      else
        [ "$1" = true ] && echo "public ON:  $2" || echo "public OFF ($id)"
      fi
    }
    prune
    if [ "$(mode)" = tunnel ]; then
      # Every doc on a tunnel is already public — there is nothing to toggle.
      id="$(resolve_id "$arg")"; [ -n "$id" ] || fail "no shared doc matches '$arg'"
      case "$act" in
        --unpublish) fail "tunnel mode: every shared doc is public — --remove it instead" ;;
        *) emit true "$(current_url)d/$id/" ;;
      esac
      exit 0
    fi
    [ -n "$TS_BIN" ] || fail "tailscale CLI not found (not on PATH, no $TS_APP)"
    id="$(resolve_id "$arg")"; [ -n "$id" ] || fail "no shared doc matches '$arg'"
    case "$act" in
      --pubstatus)
        pc="$(tool get "$id" pub)"
        if [ -n "$pc" ] && is_mounted "$pc"; then emit true "$(funnel_url "$pc" "$(pick_funnel_port)")"; else emit false ""; fi ;;
      --publish)
        [ "$(mode)" = http-direct ] && fail "public links need tailscale serve rights — this login is not tailscale's operator (http-direct mode)"
        SERVEPORT="$(cat "$PORTFILE" 2>/dev/null || true)"; [ -n "$SERVEPORT" ] || fail "server not running"
        secs="$(tool ttl "$pttl" 2>/dev/null)" || fail "bad --ttl '$pttl' (want N[smhd]; 0 = never)"
        now="$(date +%s)"; pexp=0; [ "$secs" = 0 ] || pexp=$((now + secs))
        FP="$(pick_funnel_port)"
        pc="$(tool get "$id" pub)"
        if [ -n "$pc" ] && is_mounted "$pc"; then   # already public: same link, new expiry
          tool set "$id" "pub_expires=$pexp"
          emit true "$(funnel_url "$pc" "$FP")"; exit 0
        fi
        pc="$(new_code)"
        tool set "$id" "pub=$pc" "pub_since=$now" "pub_expires=$pexp"
        if ts funnel --bg --https="$FP" --set-path="/p/$pc" "http://127.0.0.1:$SERVEPORT/_pub/$pc/" >/dev/null 2>&1 \
           && is_mounted "$pc"; then
          echo "$FP" >"$FUNNELPORTFILE"; emit true "$(funnel_url "$pc" "$FP")"
        else
          tool set "$id" pub= pub_since= pub_expires=
          fail "funnel failed — enable Funnel node attribute in the tailnet ACLs + HTTPS certs"
        fi ;;
      --unpublish)
        unpublish_doc "$id" || fail "$ERR"
        emit false "" ;;
    esac
    exit 0 ;;
  --list)
    prune
    if ! sharing; then echo "nothing is being shared."; exit 0; fi
    echo "Shared docs at: $(current_url)"
    echo "Index: $(current_url)i/$(index_code)/"
    node "$HERE/render.mjs" list "$ENTRIES_DIR"
    exit 0 ;;
  --refresh)
    prune
    n=0; IDX="$(index_code)"
    for j in "$ENTRIES_DIR"/*.json; do
      [ -e "$j" ] || continue
      id="$(basename "$j" .json)"
      INDEX_HREF="/i/$IDX/" node "$HERE/render.mjs" repage "$j" "$SERVE_DIR/d/$id/index.html" >/dev/null && n=$((n+1))
    done
    rebuild_index
    echo "re-rendered $n doc(s) with the current template."
    if sharing; then echo "still sharing at: $(current_url)"; fi
    exit 0 ;;
  --remove)
    pat="${2:-}"; [ -n "$pat" ] || { echo "usage: share.sh --remove <substr>" >&2; exit 1; }
    n=0
    for j in "$ENTRIES_DIR"/*.json; do
      [ -e "$j" ] || continue
      if grep -qi -- "$pat" "$j" || [[ "$(basename "$j" .json)" == *"$pat"* ]]; then
        drop_doc "$(basename "$j" .json)"; n=$((n+1))
      fi
    done
    rebuild_index
    echo "removed $n entr$( [ "$n" = 1 ] && echo y || echo ies ) matching '$pat'."
    if sharing; then echo "still sharing at: $(current_url)"; fi
    exit 0 ;;
esac

WANT_TUNNEL=0; WANT_LOCAL=0; WANT_OPEN=0; TTL="${DOC_PREVIEW_TTL:-7d}"
[ "${DOC_PREVIEW_MODE:-}" = tunnel ] && WANT_TUNNEL=1
[ "${DOC_PREVIEW_MODE:-}" = local ] && WANT_LOCAL=1   # a machine whose readers have no tailnet: every share loopback-only, delivered by fleet-open
while [ $# -gt 0 ]; do
  case "$1" in
    --tunnel) WANT_TUNNEL=1 ;;
    --local)  WANT_LOCAL=1 ;;
    --open)   WANT_OPEN=1 ;;
    --ttl)    TTL="${2:-}"; shift ;;
    --ttl=*)  TTL="${1#--ttl=}" ;;
    *) break ;;
  esac
  shift
done
[ $# -ge 1 ] || { echo "usage: share.sh [--tunnel|--local] [--open] [--ttl N[smhd]|0] <file.md|file.html> [more ...] | --list | --remove <substr> | --publish <id> | --unpublish <id> | --stop" >&2; exit 1; }
TTL_SECS="$(tool ttl "$TTL" 2>/dev/null)" || { echo "doc-preview: bad --ttl '$TTL' (want N[smhd], e.g. 7d / 12h; 0 = never)" >&2; exit 1; }
if [ "$WANT_LOCAL" = 1 ] && [ "$WANT_TUNNEL" = 1 ]; then
  echo "doc-preview: --local and --tunnel are opposites — pick one." >&2; exit 1
fi
# Tunnel mode is sticky (like http-direct); a live tailnet share is never silently made public.
MODE="$(mode)"
if [ "$WANT_TUNNEL" = 1 ] && [ "$MODE" != tunnel ] && sharing; then
  echo "doc-preview: already sharing on the tailnet ($MODE) — refusing to turn it into a public tunnel." >&2
  echo "Run share.sh --stop first (removes every session's shares), then share.sh --tunnel <file>." >&2
  exit 1
fi
[ "$WANT_TUNNEL" = 1 ] && MODE=tunnel
if [ "$WANT_LOCAL" = 1 ]; then
  if [ "$MODE" = http-direct ]; then
    echo "doc-preview: already sharing in http-direct mode — its server binds the tailscale IP, not 127.0.0.1, so --local has no loopback URL to give." >&2
    echo "Share without --local (the tailnet URL works with fleet-open too), or run share.sh --stop first." >&2
    exit 1
  fi
  [ -n "$MODE" ] || MODE=local
fi
NO_TAILNET_HINT="no tailnet? share.sh --tunnel <file> hosts it on a PUBLIC https://*.trycloudflare.com URL instead (needs cloudflared; anyone with the link can read it)"
if [ "$WANT_LOCAL" = 1 ]; then
  :   # no tailscale, no cloudflared: the loopback server is all --local needs
elif [ "$MODE" = tunnel ]; then
  command -v cloudflared >/dev/null || { echo "doc-preview: tunnel mode needs cloudflared (brew install cloudflared)" >&2; exit 1; }
else
  [ -n "$TS_BIN" ] || { echo "tailscale not installed — $NO_TAILNET_HINT" >&2; exit 1; }
  ts status >/dev/null 2>&1 || { echo "tailscale is not running / logged out — $NO_TAILNET_HINT" >&2; exit 1; }
fi

# Serialize concurrent shares (port pick / index rebuild) across sessions.
for _ in $(seq 1 100); do mkdir "$LOCK" 2>/dev/null && break || sleep 0.2; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
prune

# Render each input as a NEW entry. Existing entries are left untouched.
IDX="$(index_code)"
NOW="$(date +%s)"; EXPIRES=0; [ "$TTL_SECS" = 0 ] || EXPIRES=$((NOW + TTL_SECS))
new=(); ids=()
for f in "$@"; do
  if [ ! -f "$f" ]; then echo "skip (not found): $f" >&2; continue; fi
  abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  fdir="$(dirname "$abs")"
  # Display path = <repo name>/<path relative to worktree top>, not the full absolute path.
  # Use the MAIN repo name (parent of --git-common-dir), not the worktree folder name, which
  # is often meaningless. Fall back to the cwd folder name outside a git repo.
  top="$(git -C "$fdir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ]; then
    common="$(git -C "$fdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
              || git -C "$fdir" rev-parse --git-common-dir 2>/dev/null || echo "$top/.git")"
    case "$common" in /*) ;; *) common="$(cd "$fdir" && cd "$(dirname "$common")" && pwd)/$(basename "$common")" ;; esac
    name="$(basename "$(dirname "$common")")"; base="$top"
  else
    name="$(basename "$PWD")"; base="$PWD"
  fi
  rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$abs" "$base")"
  # File outside the repo/cwd (e.g. session scratchpad): a ../..-escaping relpath is noise —
  # show a short "<parent dir>/<file>" instead.
  case "$rel" in
    ..*) disp="$(basename "$(dirname "$abs")")/$(basename "$abs")" ;;
    *)   disp="$name/$rel" ;;
  esac
  id="$(new_code)"   # 128 random bits: the link IS the key (issue #1153)
  ID="$id" HREF="/d/$id/" ADDED="$(date '+%Y-%m-%d %H:%M')" SESSION="$SESSION" DISP="$disp" SRC="$abs" \
    EXPIRES="$EXPIRES" CREATED="$NOW" INDEX_HREF="/i/$IDX/" \
    node "$HERE/render.mjs" page "$f" "$SERVE_DIR/d/$id/index.html" "$ENTRIES_DIR/$id.json" >/dev/null
  new+=("/d/$id/"); ids+=("$id")
done
rebuild_index

# A failed share leaves nothing behind: drop the entries this run added.
rollback() {
  local id
  for id in ${ids[@]+"${ids[@]}"}; do rm -f "${ENTRIES_DIR:?}/${id:?}.json"; rm -rf "${SERVE_DIR:?}/d/${id:?}"; done
  rebuild_index
}
server_fail() { # <addr>
  rm -f "$PIDFILE" "$PORTFILE"
  echo "doc-preview: could not start server.py on $1 — ${START_FAIL:-ports ${DOC_PREVIEW_PORT:-8765}+ busy or bind refused}; see $ROOT/server.log:" >&2
  tail -3 "$ROOT/server.log" 2>/dev/null >&2 || true
  rollback; exit 1
}

server_addr "$MODE" || { rollback; exit 1; }
for _p in $(stray_servers); do kill "$_p" 2>/dev/null || true; done

# Ensure ONE static server is running (reuse the existing one — keeps the port/URL fixed).
# One started by an older server.py is replaced on the SAME port: an old server knows
# nothing of codes or expiry (issue #1153), and a new port would mean a new route.
if [ -f "$PIDFILE" ] && [ -f "$PORTFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  PORT="$(cat "$PORTFILE")"
  if server_stale; then restart_server || server_fail "$ADDR"; fi
else
  start_server "$ADDR" "$PUB" || server_fail "$ADDR"
fi

if [ "$WANT_LOCAL" = 0 ] && [ "$MODE" = tunnel ] && ! ensure_tunnel "$PORT"; then
  echo "doc-preview: cloudflared quick tunnel did not come up within ${DOC_PREVIEW_TUNNEL_WAIT:-30}s — see $ROOT/tunnel.log:" >&2
  tail -3 "$ROOT/tunnel.log" 2>/dev/null >&2 || true
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE" "$PORTFILE"
  rollback; exit 1
fi

# https mode: ensure tailscale serve points at it. Reuse the existing route (never
# `reset`, so other sessions' sharing keeps working); only configure one if it's missing —
# and then re-point the port this login had before a NEW one (issue #1153: a fresh port
# per server restart left ~260 routes behind on one machine).
if [ "$WANT_LOCAL" = 0 ] && { [ "$MODE" = https ] || [ "$MODE" = local ] || [ -z "$MODE" ]; }; then
  HP="$(serve_route_port "$PORT")"
  if [ -z "$HP" ]; then
    HP="$(cat "$HTTPSFILE" 2>/dev/null || true)"
    USED="$(serve_ports)"
    # The recorded port is ours to re-point when its route leads to a port this login
    # served; held by anything else (another login's route, a listener) → pick afresh.
    if [ -n "$HP" ] && printf '%s\n' "$USED" | grep -qx "$HP" \
       && ! { ts serve status --json 2>/dev/null | tool routes "$PORT" "$OWNEDFILE" 2>/dev/null | awk '$3 != "other" {print $1}' | grep -qx "$HP"; }; then
      HP=""
    fi
    if [ -n "$HP" ] && ! printf '%s\n' "$USED" | grep -qx "$HP" && lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; then
      HP=""
    fi
    if [ -z "$HP" ]; then
      HP=443
      while printf '%s\n' "$USED" | grep -qx "$HP" || lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; do
        if [ "$HP" = 443 ]; then HP=8443; else HP=$((HP + 1)); fi
      done
    fi
    if ! err="$(ts serve --bg --https="$HP" "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"; then
      case "$err" in
        *--operator*|*sudo*)
          # Not tailscale's operator (and no root): serve is refused, not misconfigured.
          # Fall back to http-direct — nothing proxies to the loopback server, so retire it.
          ADDR="$(ts_ip4)"
          [ -n "$ADDR" ] || { echo "doc-preview: tailscale serve refused ($err) and no tailscale IPv4 to fall back to" >&2; rollback; exit 1; }
          [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
          rm -f "$PIDFILE" "$PORTFILE" "$HTTPSFILE"
          start_server "$ADDR" || server_fail "$ADDR"
          MODE=http-direct ;;
        *)
          echo "tailscale serve failed: ${err:-no output}" >&2
          echo "If HTTPS certs are off, enable them (admin console -> DNS -> HTTPS Certificates)," >&2
          echo "then run: tailscale serve --bg --https=$HP http://127.0.0.1:$PORT" >&2
          rollback; exit 1 ;;
      esac
    fi
  fi
  if [ "$MODE" != http-direct ]; then
    echo "$HP" >"$HTTPSFILE"; MODE=https
    serve_gc "$HP" "$PORT"
  fi
fi
echo "$MODE" >"$MODEFILE"
NOTE=""
[ "$MODE" = tunnel ] && NOTE="  (tunnel: PUBLIC — anyone with this link can read it; the URL changes if cloudflared restarts)"
[ "$MODE" = http-direct ] && NOTE="  (http-direct: plain http inside the tailnet — this login is not tailscale's operator, so no tailscale serve/HTTPS)"

[ "$MODE" = local ] && NOTE="  (local: http on 127.0.0.1 only — open it on the operator's computer with fleet-open)"
if [ "$TTL_SECS" = 0 ]; then LEFT="never expires"; else LEFT="expires in $TTL"; fi

if [ "$WANT_LOCAL" = 1 ]; then URL="$(local_url)"; else URL="$(current_url)"; fi
BASE="${URL%/}"
IDX_URL="${BASE}/i/$IDX/"
# Lead with the specific doc URL when this share added exactly one doc; only show the
# index when multiple docs were added (or none, e.g. all paths were missing).
if [ "${#new[@]}" -eq 1 ]; then
  echo "READY ${BASE}${new[0]}${NOTE}"   # direct link to the shared doc
  echo "INDEX ${IDX_URL}"         # full list (other shared docs), for reference
else
  echo "READY ${IDX_URL}${NOTE}"         # index listing
  for h in ${new[@]+"${new[@]}"}; do echo "ADDED ${BASE}$h"; done
fi
[ "${#new[@]}" -eq 0 ] || echo "TTL ${LEFT} (share.sh --ttl N[smhd]|0 to change)"

# --open: the operator's own browser, over their ssh (bin/fleet-open.sh, issue #1379).
if [ "$WANT_OPEN" = 1 ]; then
  if [ "${#new[@]}" -eq 1 ]; then OPEN_URL="${BASE}${new[0]}"; else OPEN_URL="$IDX_URL"; fi
  FO="${FLEET_OPEN_BIN:-}"
  [ -n "$FO" ] || for c in "$HERE/../../bin/fleet-open.sh" "$HOME/.claude/fleet/bin/fleet-open.sh"; do
    [ -x "$c" ] && { FO="$c"; break; }
  done
  if [ -n "$FO" ]; then
    echo "OPEN $("$FO" "$OPEN_URL" | tail -n 1)"
  else
    echo "doc-preview: --open: fleet-open.sh not found (claude-fleet not installed?) — give the operator the READY URL" >&2
  fi
fi
