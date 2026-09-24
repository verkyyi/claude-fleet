#!/usr/bin/env bash
# Render Markdown -> styled HTML and host it on this machine's Tailscale tailnet URL.
#
# Multi-session safe: all shares APPEND to one shared collection behind a FIXED URL.
# A new share never removes existing shared docs or changes the URL; the root page
# lists everything currently being shared (across every session).
#
#   share.sh <file.md|file.html> [more ...]   # add doc(s)/page(s) to the shared list; prints READY <url>
#   share.sh --tunnel <file> [more ...]  # same, but on a PUBLIC cloudflared quick tunnel — no tailnet
#                                      # (.md → GitHub-styled viewer; .html → served as-is, #526)
#   share.sh --list                    # show what is currently shared
#   share.sh --remove <substr>         # drop entries whose id/title/path matches <substr>
#   share.sh --refresh                 # re-render all shared docs with the current template
#                                        (same URLs; also picks up source-file edits)
#   share.sh --publish   <id|substr>   # expose ONE doc publicly via Funnel; prints the /p/<id>/ URL
#   share.sh --unpublish <id|substr>   # take that doc back off the public internet
#   share.sh --pubstatus <id|substr>   # print whether a doc is public + its URL
#   share.sh --stop                    # tear everything down (all sessions; public links off)
#
# Publishing is per-document and normally driven by the in-page "公开链接" toggle (shown only
# when the doc is viewed over the tailnet). Tailnet sharing stays private; only explicitly
# published docs are reachable on the public internet, each at its own /p/<id>/ path.
#
# Two serving modes, recorded in $ROOT/mode (issue #1093):
#   https        the loopback server.py fronted by `tailscale serve` (HTTPS on the tailnet).
#   http-direct  the login is NOT tailscale's operator (one per machine) and has no root,
#                so `tailscale serve` is refused: server.py binds this machine's tailscale
#                IPv4 directly and the URL is http://<magicdns>:<port>/ — plain http, but
#                only reachable inside the tailnet, whose link is WireGuard-encrypted.
#                Sticky until --stop; public (Funnel) links need serve rights, so none here.
#   tunnel       no tailnet at all (issue #1151): opt-in with --tunnel or DOC_PREVIEW_MODE=tunnel.
#                server.py on loopback in its `public` mode, fronted by `cloudflared tunnel
#                --url` (a quick tunnel: no account, no config). The URL is a random
#                https://<words>.trycloudflare.com — PUBLIC to anyone who has it, index
#                included; doc headers + source paths are stripped and /_ctl is 404.
#                Sticky until --stop. The hostname changes whenever cloudflared restarts
#                (reboot, --stop), so old links die with it: a live preview, not hosting.
#
# Set DOC_PREVIEW_SESSION to label your session in the list (default: hostname).
# No npm install needed: rendering is client-side (CDN libs in the viewer's browser).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HOME/.cache/claude-doc-preview"
SERVE_DIR="$ROOT/serve"
ENTRIES_DIR="$ROOT/entries"
PIDFILE="$ROOT/server.pid"
PORTFILE="$ROOT/server.port"
HTTPSFILE="$ROOT/https.port"
FUNNELPORTFILE="$ROOT/funnel.port"   # tailnet HTTPS port used for public (Funnel) doc mounts
MODEFILE="$ROOT/mode"                # https | http-direct | tunnel (see the header)
TUNNELPIDFILE="$ROOT/tunnel.pid"     # tunnel mode: the cloudflared process
TUNNELURLFILE="$ROOT/tunnel.url"     # …its https://*.trycloudflare.com origin
TUNNELPORTFILE="$ROOT/tunnel.port"   # …and the loopback port it fronts
LOCK="$ROOT/.lock"
SESSION="${DOC_PREVIEW_SESSION:-$(hostname -s 2>/dev/null || echo session)}"

mkdir -p "$ROOT" "$SERVE_DIR/d" "$ENTRIES_DIR"

host() { tailscale status --json | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))"; }
rebuild_index() { node "$HERE/render.mjs" index "$SERVE_DIR/index.html" "$ENTRIES_DIR" >/dev/null; }
# Serving mode; an install from before the mode file existed is https iff it has a route.
mode() {
  if [ -f "$MODEFILE" ]; then cat "$MODEFILE"; elif [ -f "$HTTPSFILE" ]; then echo https; fi
}
sharing() { [ -f "$HTTPSFILE" ] || [ "$(mode)" = http-direct ] || [ "$(mode)" = tunnel ]; }
current_url() {
  if [ "$(mode)" = tunnel ]; then echo "$(cat "$TUNNELURLFILE" 2>/dev/null)/"; return; fi
  if [ "$(mode)" = http-direct ]; then echo "http://$(host):$(cat "$PORTFILE" 2>/dev/null)/"; return; fi
  local hp sfx=""; hp="$(cat "$HTTPSFILE" 2>/dev/null || echo 443)"
  [ "$hp" = 443 ] || sfx=":$hp"
  echo "https://$(host)$sfx/"
}

ts_ip4() { tailscale ip -4 2>/dev/null | head -1; }
# A real bind() probe, NOT lsof: lsof lists only this login's sockets, so a port held by
# ANOTHER login's doc-preview server looked free and our server.py died on EADDRINUSE
# after share.sh had already recorded its pid/port (issue #1093).
port_free() { # <addr> <port>
  python3 -c 'import socket,sys
s=socket.socket()
try: s.bind((sys.argv[1],int(sys.argv[2])))
except OSError: sys.exit(1)' "$1" "$2"
}
port_up() { # <addr> <port> — is something accepting connections there?
  python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(0.5)
sys.exit(0 if s.connect_ex((sys.argv[1],int(sys.argv[2])))==0 else 1)' "$1" "$2"
}
# Start ONE server.py on <addr> at the first free port from DOC_PREVIEW_PORT. pid/port are
# recorded only once it ANSWERS, so a failed start never leaves a half-written state.
start_server() { # <addr> [public]; sets PORT
  local addr="$1" pub="${2:-}" p="${DOC_PREVIEW_PORT:-8765}" end launches=0 pid
  end=$((p + 50))
  rm -f "$PIDFILE" "$PORTFILE"
  while [ "$p" -lt "$end" ] && [ "$launches" -lt 5 ]; do
    if port_free "$addr" "$p"; then
      launches=$((launches + 1))
      nohup python3 "$HERE/server.py" "$p" "$SERVE_DIR" "$HERE" "$addr" $pub >"$ROOT/server.log" 2>&1 &
      pid=$!
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        if port_up "$addr" "$p"; then echo "$pid" >"$PIDFILE"; echo "$p" >"$PORTFILE"; PORT="$p"; return 0; fi
        sleep 0.1
      done
      kill "$pid" 2>/dev/null || true   # lost a race for the port, or never came up: next one
    fi
    p=$((p + 1))
  done
  return 1
}
# The tailnet HTTPS port whose "/" already proxies to 127.0.0.1:<port>, if any — e.g. a
# route an admin set up once with `sudo tailscale serve` for a non-operator login.
serve_route_port() { # <port>
  tailscale serve status --json 2>/dev/null | python3 -c '
import sys, json
want = "http://127.0.0.1:" + sys.argv[1]
try: web = (json.load(sys.stdin) or {}).get("Web") or {}
except Exception: sys.exit(0)
for hostport, cfg in web.items():
    if (((cfg or {}).get("Handlers") or {}).get("/") or {}).get("Proxy", "").rstrip("/") == want:
        print(hostport.rsplit(":", 1)[1] if ":" in hostport else "443"); break
' "$1" 2>/dev/null || true
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
funnel_url() { # <id> <fport>
  local sfx=""; [ "$2" = 443 ] || sfx=":$2"
  echo "https://$(host)$sfx/p/$1/"
}
is_published() { tailscale funnel status 2>/dev/null | grep -q "/p/$1 "; }
resolve_id() { # <arg> -> the single matching entry id, or empty
  local a="$1" id hit=()
  [ -n "$a" ] || return 0
  if [ -d "$SERVE_DIR/d/$a" ]; then echo "$a"; return 0; fi
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
# Turn off every /p/<id> Funnel mount (used by --stop and --remove).
unpublish_all() {
  command -v tailscale >/dev/null 2>&1 || return 0
  local fp id; fp="$(cat "$FUNNELPORTFILE" 2>/dev/null || true)"; [ -n "$fp" ] || return 0
  for id in $(tailscale funnel status 2>/dev/null | sed -n 's#.*/p/\([0-9-]*\) proxy.*#\1#p'); do
    tailscale funnel --https="$fp" --set-path="/p/$id" off >/dev/null 2>&1 || true
  done
}

stop() {
  unpublish_all
  stop_tunnel
  tailscale serve reset >/dev/null 2>&1 || true
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  pkill -f "http.server" 2>/dev/null || true
  pkill -f "doc-preview/server.py" 2>/dev/null || true
  rm -rf "$SERVE_DIR" "$ENTRIES_DIR" "$PIDFILE" "$PORTFILE" "$HTTPSFILE" "$FUNNELPORTFILE" "$MODEFILE"
  echo "doc-preview stopped (all shared docs removed, public links off, tunnel closed, tailscale serve reset)."
}

case "${1:-}" in
  --stop) stop; exit 0 ;;
  --pubstatus|--publish|--unpublish)
    act="$1"; arg=""; json=0
    for a in "${@:2}"; do case "$a" in --json) json=1 ;; *) [ -z "$arg" ] && arg="$a" ;; esac; done
    fail() { [ "$json" = 1 ] && echo "{\"error\":\"$1\"}" || echo "$1" >&2; exit 1; }
    emit() { # <public true|false> <url-or-empty>
      if [ "$json" = 1 ]; then
        [ -n "$2" ] && echo "{\"public\":$1,\"url\":\"$2\",\"id\":\"$id\"}" \
                    || echo "{\"public\":$1,\"url\":null,\"id\":\"$id\"}"
      else
        [ "$1" = true ] && echo "public ON:  $2" || echo "public OFF ($id)"
      fi
    }
    if [ "$(mode)" = tunnel ]; then
      # Every doc on a tunnel is already public — there is nothing to toggle.
      id="$(resolve_id "$arg")"; [ -n "$id" ] || fail "no shared doc matches '$arg'"
      case "$act" in
        --unpublish) fail "tunnel mode: every shared doc is public — --remove it instead" ;;
        *) emit true "$(current_url)d/$id/" ;;
      esac
      exit 0
    fi
    command -v tailscale >/dev/null 2>&1 || fail "tailscale not installed"
    id="$(resolve_id "$arg")"; [ -n "$id" ] || fail "no shared doc matches '$arg'"
    case "$act" in
      --pubstatus)
        if is_published "$id"; then emit true "$(funnel_url "$id" "$(pick_funnel_port)")"; else emit false ""; fi ;;
      --publish)
        [ "$(mode)" = http-direct ] && fail "public links need tailscale serve rights — this login is not tailscale's operator (http-direct mode)"
        SERVEPORT="$(cat "$PORTFILE" 2>/dev/null || true)"; [ -n "$SERVEPORT" ] || fail "server not running"
        FP="$(pick_funnel_port)"
        if tailscale funnel --bg --https="$FP" --set-path="/p/$id" "http://127.0.0.1:$SERVEPORT/_pub/$id/" >/dev/null 2>&1; then
          echo "$FP" >"$FUNNELPORTFILE"; emit true "$(funnel_url "$id" "$FP")"
        else
          fail "funnel failed — enable Funnel node attribute in the tailnet ACLs + HTTPS certs"
        fi ;;
      --unpublish)
        FP="$(pick_funnel_port)"
        tailscale funnel --https="$FP" --set-path="/p/$id" off >/dev/null 2>&1 || true
        emit false "" ;;
    esac
    exit 0 ;;
  --list)
    if ! sharing; then echo "nothing is being shared."; exit 0; fi
    echo "Shared docs at: $(current_url)"
    node "$HERE/render.mjs" list "$ENTRIES_DIR"
    exit 0 ;;
  --refresh)
    n=0
    for j in "$ENTRIES_DIR"/*.json; do
      [ -e "$j" ] || continue
      id="$(basename "$j" .json)"
      node "$HERE/render.mjs" repage "$j" "$SERVE_DIR/d/$id/index.html" >/dev/null && n=$((n+1))
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
        id="$(basename "$j" .json)"
        if command -v tailscale >/dev/null 2>&1 && is_published "$id"; then
          tailscale funnel --https="$(pick_funnel_port)" --set-path="/p/$id" off >/dev/null 2>&1 || true
        fi
        rm -f "$j"; rm -rf "${SERVE_DIR:?}/d/$id"; n=$((n+1))
      fi
    done
    rebuild_index
    echo "removed $n entr$( [ "$n" = 1 ] && echo y || echo ies ) matching '$pat'."
    if sharing; then echo "still sharing at: $(current_url)"; fi
    exit 0 ;;
esac

WANT_TUNNEL=0
[ "${DOC_PREVIEW_MODE:-}" = tunnel ] && WANT_TUNNEL=1
if [ "${1:-}" = --tunnel ]; then WANT_TUNNEL=1; shift; fi
[ $# -ge 1 ] || { echo "usage: share.sh [--tunnel] <file.md|file.html> [more ...] | --list | --remove <substr> | --publish <id> | --unpublish <id> | --stop" >&2; exit 1; }
# Tunnel mode is sticky (like http-direct); a live tailnet share is never silently made public.
MODE="$(mode)"
if [ "$WANT_TUNNEL" = 1 ] && [ "$MODE" != tunnel ] && sharing; then
  echo "doc-preview: already sharing on the tailnet ($MODE) — refusing to turn it into a public tunnel." >&2
  echo "Run share.sh --stop first (removes every session's shares), then share.sh --tunnel <file>." >&2
  exit 1
fi
[ "$WANT_TUNNEL" = 1 ] && MODE=tunnel
NO_TAILNET_HINT="no tailnet? share.sh --tunnel <file> hosts it on a PUBLIC https://*.trycloudflare.com URL instead (needs cloudflared; anyone with the link can read it)"
if [ "$MODE" = tunnel ]; then
  command -v cloudflared >/dev/null || { echo "doc-preview: tunnel mode needs cloudflared (brew install cloudflared)" >&2; exit 1; }
else
  command -v tailscale >/dev/null || { echo "tailscale not installed — $NO_TAILNET_HINT" >&2; exit 1; }
  tailscale status >/dev/null 2>&1 || { echo "tailscale is not running / logged out — $NO_TAILNET_HINT" >&2; exit 1; }
fi

# Serialize concurrent shares (port pick / index rebuild) across sessions.
for _ in $(seq 1 100); do mkdir "$LOCK" 2>/dev/null && break || sleep 0.2; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Render each input as a NEW entry. Existing entries are left untouched.
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
  id="$(date '+%Y%m%d-%H%M%S')-$RANDOM"
  ID="$id" HREF="/d/$id/" ADDED="$(date '+%Y-%m-%d %H:%M')" SESSION="$SESSION" DISP="$disp" SRC="$abs" \
    node "$HERE/render.mjs" page "$f" "$SERVE_DIR/d/$id/index.html" "$ENTRIES_DIR/$id.json" >/dev/null
  new+=("/d/$id/"); ids+=("$id")
done
rebuild_index

# A failed share leaves nothing behind: drop the entries this run added.
rollback() {
  local id
  for id in ${ids[@]+"${ids[@]}"}; do rm -f "$ENTRIES_DIR/$id.json"; rm -rf "${SERVE_DIR:?}/d/$id"; done
  rebuild_index
}
server_fail() { # <addr>
  rm -f "$PIDFILE" "$PORTFILE"
  echo "doc-preview: could not start server.py on $1 (ports ${DOC_PREVIEW_PORT:-8765}+ busy or bind refused) — see $ROOT/server.log:" >&2
  tail -3 "$ROOT/server.log" 2>/dev/null >&2 || true
  rollback; exit 1
}

PUB=""
if [ "$MODE" = http-direct ]; then
  ADDR="$(ts_ip4)"; [ -n "$ADDR" ] || { echo "doc-preview: no tailscale IPv4 (tailscale ip -4)" >&2; rollback; exit 1; }
else
  ADDR=127.0.0.1
  [ "$MODE" = tunnel ] && PUB=public
fi

# Ensure ONE static server is running (reuse the existing one — keeps the port/URL fixed).
if [ -f "$PIDFILE" ] && [ -f "$PORTFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  PORT="$(cat "$PORTFILE")"
else
  start_server "$ADDR" $PUB || server_fail "$ADDR"
fi

if [ "$MODE" = tunnel ] && ! ensure_tunnel "$PORT"; then
  echo "doc-preview: cloudflared quick tunnel did not come up within ${DOC_PREVIEW_TUNNEL_WAIT:-30}s — see $ROOT/tunnel.log:" >&2
  tail -3 "$ROOT/tunnel.log" 2>/dev/null >&2 || true
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE" "$PORTFILE"
  rollback; exit 1
fi

# https mode: ensure tailscale serve points at it. Reuse the existing route (never
# `reset`, so other sessions' sharing keeps working); only configure one if it's missing.
if [ "$MODE" = https ] || [ -z "$MODE" ]; then
  HP="$(serve_route_port "$PORT")"
  if [ -z "$HP" ]; then
    HP="$(cat "$HTTPSFILE" 2>/dev/null || true)"
    if [ -z "$HP" ] || lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; then
      HP=443
      if lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; then
        HP=8443; while lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; do HP=$((HP + 1)); done
      fi
    fi
    if ! err="$(tailscale serve --bg --https="$HP" "http://127.0.0.1:$PORT" 2>&1 >/dev/null)"; then
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
  [ "$MODE" = http-direct ] || { echo "$HP" >"$HTTPSFILE"; MODE=https; }
fi
echo "$MODE" >"$MODEFILE"
NOTE=""
[ "$MODE" = tunnel ] && NOTE="  (tunnel: PUBLIC — anyone with this link can read it and the index; the URL changes if cloudflared restarts)"
[ "$MODE" = http-direct ] && NOTE="  (http-direct: plain http inside the tailnet — this login is not tailscale's operator, so no tailscale serve/HTTPS)"

URL="$(current_url)"; BASE="${URL%/}"
# Lead with the specific doc URL when this share added exactly one doc; only show the
# directory/index when multiple docs were added (or none, e.g. all paths were missing).
if [ "${#new[@]}" -eq 1 ]; then
  echo "READY ${BASE}${new[0]}${NOTE}"   # direct link to the shared doc
  echo "INDEX ${URL}"             # full list (other shared docs), for reference
else
  echo "READY ${URL}${NOTE}"             # directory/index listing
  for h in ${new[@]+"${new[@]}"}; do echo "ADDED ${BASE}$h"; done
fi
