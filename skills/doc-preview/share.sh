#!/usr/bin/env bash
# Render Markdown -> styled HTML and host it on this machine's Tailscale tailnet URL.
#
# Multi-session safe: all shares APPEND to one shared collection behind a FIXED URL.
# A new share never removes existing shared docs or changes the URL; the root page
# lists everything currently being shared (across every session).
#
#   share.sh <file.md> [more.md ...]   # add doc(s) to the shared list; prints READY <url>
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
LOCK="$ROOT/.lock"
SESSION="${DOC_PREVIEW_SESSION:-$(hostname -s 2>/dev/null || echo session)}"

mkdir -p "$ROOT" "$SERVE_DIR/d" "$ENTRIES_DIR"

host() { tailscale status --json | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))"; }
rebuild_index() { node "$HERE/render.mjs" index "$SERVE_DIR/index.html" "$ENTRIES_DIR" >/dev/null; }
current_url() {
  local hp sfx=""; hp="$(cat "$HTTPSFILE" 2>/dev/null || echo 443)"
  [ "$hp" = 443 ] || sfx=":$hp"
  echo "https://$(host)$sfx/"
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
  tailscale serve reset >/dev/null 2>&1 || true
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  pkill -f "http.server" 2>/dev/null || true
  pkill -f "doc-preview/server.py" 2>/dev/null || true
  rm -rf "$SERVE_DIR" "$ENTRIES_DIR" "$PIDFILE" "$PORTFILE" "$HTTPSFILE" "$FUNNELPORTFILE"
  echo "doc-preview stopped (all shared docs removed, public links off, tailscale serve reset)."
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
    command -v tailscale >/dev/null 2>&1 || fail "tailscale not installed"
    id="$(resolve_id "$arg")"; [ -n "$id" ] || fail "no shared doc matches '$arg'"
    case "$act" in
      --pubstatus)
        if is_published "$id"; then emit true "$(funnel_url "$id" "$(pick_funnel_port)")"; else emit false ""; fi ;;
      --publish)
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
    if [ ! -f "$HTTPSFILE" ]; then echo "nothing is being shared."; exit 0; fi
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
    [ -f "$HTTPSFILE" ] && echo "still sharing at: $(current_url)"
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
    [ -f "$HTTPSFILE" ] && echo "still sharing at: $(current_url)"
    exit 0 ;;
esac

[ $# -ge 1 ] || { echo "usage: share.sh <file.md> [more.md ...] | --list | --remove <substr> | --publish <id> | --unpublish <id> | --stop" >&2; exit 1; }
command -v tailscale >/dev/null || { echo "tailscale not installed" >&2; exit 1; }
tailscale status >/dev/null 2>&1 || { echo "tailscale is not running / logged out" >&2; exit 1; }

# Serialize concurrent shares (port pick / index rebuild) across sessions.
for _ in $(seq 1 100); do mkdir "$LOCK" 2>/dev/null && break || sleep 0.2; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Render each input as a NEW entry. Existing entries are left untouched.
new=()
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
  new+=("/d/$id/")
done
rebuild_index

# Ensure ONE static server is running (reuse the existing one — keeps the port/URL fixed).
if [ -f "$PIDFILE" ] && [ -f "$PORTFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  PORT="$(cat "$PORTFILE")"
else
  PORT="${DOC_PREVIEW_PORT:-8765}"
  while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT + 1)); done
  nohup python3 "$HERE/server.py" "$PORT" "$SERVE_DIR" "$HERE" >"$ROOT/server.log" 2>&1 &
  echo $! >"$PIDFILE"; echo "$PORT" >"$PORTFILE"; sleep 1
fi

# Ensure tailscale serve points at it. Reuse the existing route (never `reset`, so other
# sessions' sharing keeps working). Only (re)configure if the route is missing.
if ! { tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$PORT"; } || [ ! -f "$HTTPSFILE" ]; then
  HP="$(cat "$HTTPSFILE" 2>/dev/null || true)"
  if [ -z "$HP" ] || lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; then
    HP=443
    if lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; then
      HP=8443; while lsof -nP -iTCP:"$HP" -sTCP:LISTEN >/dev/null 2>&1; do HP=$((HP + 1)); done
    fi
  fi
  if ! tailscale serve --bg --https="$HP" "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    echo "tailscale serve failed. Enable HTTPS certs (admin console -> DNS -> HTTPS Certificates)," >&2
    echo "then run: tailscale serve --bg --https=$HP http://127.0.0.1:$PORT" >&2
    exit 1
  fi
  echo "$HP" >"$HTTPSFILE"
fi

URL="$(current_url)"; BASE="${URL%/}"
# Lead with the specific doc URL when this share added exactly one doc; only show the
# directory/index when multiple docs were added (or none, e.g. all paths were missing).
if [ "${#new[@]}" -eq 1 ]; then
  echo "READY ${BASE}${new[0]}"   # direct link to the shared doc
  echo "INDEX ${URL}"             # full list (other shared docs), for reference
else
  echo "READY ${URL}"             # directory/index listing
  for h in "${new[@]}"; do echo "ADDED ${BASE}$h"; done
fi
