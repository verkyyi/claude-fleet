#!/bin/bash
# fleet-webhook.sh — FRESH (~1s) PR/issue/CI status via `gh webhook forward`, with
# NO public endpoint (issue #315).
#
# The dash/status bar learns of "CI went green" / "PR merged" / a new issue only
# when the pollers next tick — the collector (~60s, issues) and pr-refresh (~15s,
# PR/CI). This daemon makes those edges near-instant by wiring GitHub's real-time
# webhook stream to the SAME single-writer refreshers — without exposing any port.
#
# HOW (no endpoint): there is no `gh` push/stream API; GitHub's only real-time push
# is webhooks, which normally need a public URL. `gh webhook forward` (the
# cli/gh-webhook extension) avoids that — it registers the repo webhook against
# GitHub's OWN hosted relay, then PULLS deliveries over an authenticated channel
# (the gh token) and re-POSTs each to a LOCALHOST url. No ngrok/tunnel, no exposed
# HMAC endpoint. Prereq: `gh extension install cli/gh-webhook`.
#
# SHAPE — one long-lived (KeepAlive) supervisor, like the spinner, running:
#   • ONE local handler on http://127.0.0.1:<port> (python3, a fleet dep) that
#     receives each delivery and hands it to `--route`.
#   • ONE `gh webhook forward` per opted-in LIVE fleet repo, all pointed at that
#     same --url. Fanned out over every live fleet (like fleet-watch), deduped per
#     repo (single forward per repo), dead forwards auto-restarted each rescan.
#
# The handler TRIGGERS A TARGETED REFRESH — it never writes a cache itself:
#   • pull_request / check_run / check_suite / status  → tmux-pr-refresh.sh --repo
#     <repo> (the SINGLE writer of prmap/@prci) for that repo, now.
#   • issues                                           → tmux-dash-collect.sh
#     --issues <repo> (the collector OWNS issues_<slug>) for that repo, now.
# So the write-side ownership rails (issue #180/#81) are unchanged; the webhook is a
# freshness kick into the existing writers, routed by the repo in the payload.
#
# POLLING STAYS THE BACKSTOP. pr-refresh (~15s) + collector (~60s) keep running, so
# a missed delivery / a dead forward / a relay hiccup can only cost freshness, never
# correctness. This daemon is a freshness optimization, not a replacement.
#
# OFF BY DEFAULT — a fleet opts in with FLEET_WEBHOOK=1 (like the other
# token/infra-spending daemons). No opted-in live fleet ⇒ this idles cheaply.
#
# Modes (default = the supervisor):
#   (none)              supervise: handler + forwards, restart-on-death, rescan loop
#   --route --event E   read ONE delivery JSON on stdin, verify HMAC (if a secret is
#                       set), and kick the targeted refresh for its repo. NO cache
#                       write of its own. Ignores unknown event types.
#   --handler           run the localhost python3 receiver (spawned by supervise)
#   --desired [sess..]  print the repos to forward (opted-in, deduped); default set
#                       is the live fleet sockets, or the given sessions
#   --reconcile [sess..] one reconcile pass: start missing forwards, reap departed
#   --once              with supervise: run a single handler-start + reconcile, then
#                       exit (used by the selftest / a manual poke)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

LOGP="$BIN/../logs"; mkdir -p "$LOGP" 2>/dev/null || :
log() { printf '%s fleet-webhook: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }
now() { date +%s 2>/dev/null || echo 0; }

# --- config (globals: one machine-wide daemon; opt-in is per-fleet) ------------
PORT="${FLEET_WEBHOOK_PORT:-8917}";        case "$PORT" in ''|*[!0-9]*) PORT=8917;; esac
SECRET="${FLEET_WEBHOOK_SECRET:-}"
EVENTS="${FLEET_WEBHOOK_EVENTS:-pull_request,check_run,check_suite,status,issues}"
RESCAN="${FLEET_WEBHOOK_RESCAN:-30}";      case "$RESCAN" in ''|*[!0-9]*) RESCAN=30;; esac
# Coalesce a delivery STORM (a CI run fires many check_run/status events per PR):
# skip a kick for the same (class,repo) fired < DEBOUNCE seconds ago. The polling
# backstop still catches anything skipped. 0 disables (every delivery kicks).
DEBOUNCE="${FLEET_WEBHOOK_DEBOUNCE:-3}";   case "$DEBOUNCE" in ''|*[!0-9]*) DEBOUNCE=3;; esac
URL="http://127.0.0.1:$PORT"

STATE="${FLEET_WEBHOOK_STATE_DIR:-$HOME/.config/claude-fleet/webhook}"
FWD="$STATE/forwards"                       # one <slug>.pid per running forward
HANDLER_PIDF="$STATE/handler.pid"
mkdir -p "$FWD" 2>/dev/null || :

# The targeted refreshers. Overridable so the hermetic selftest can substitute a
# recorder — the DEFAULTS are the real single-writers, so the handler itself never
# writes a cache (it only invokes the owner).
PR_REFRESH_CMD="${FLEET_PR_REFRESH_CMD:-$BIN/tmux-pr-refresh.sh}"
ISSUES_REFRESH_CMD="${FLEET_ISSUES_REFRESH_CMD:-$BIN/tmux-dash-collect.sh}"
# The forward launcher. Overridable so the selftest can supervise a fake forward
# without gh/network; empty ⇒ the real `gh webhook forward`.
FWD_CMD="${FLEET_WH_FORWARD_CMD:-}"

# =============================== ingress: --route ==============================
# Extract owner/name (+ best-effort number) from a delivery on stdin, verifying the
# HMAC when a secret is configured. python3 does HMAC + JSON in one pass over the
# RAW bytes (jq can't HMAC; openssl can't parse JSON) — the same shape as the
# issue-bridge --deliver path. Prints "owner/name\t<num>"; non-zero (no output) on
# a bad signature or unparseable body, so route then does nothing.
wh_extract() {
  command -v python3 >/dev/null 2>&1 || { log "--route needs python3"; return 2; }
  FLEET_SECRET="$SECRET" FLEET_SIG="${FLEET_DELIVERY_SIG:-}" python3 -c '
import sys, os, hmac, hashlib, json
raw = sys.stdin.buffer.read()
secret = os.environ.get("FLEET_SECRET", "")
sig = os.environ.get("FLEET_SIG", "")
# Optional defense-in-depth: the handler binds to localhost, so an unsigned
# delivery can at worst cause a spurious LOCAL refresh (never a write of its own).
# When a secret IS set we still verify — a mismatch is refused.
if secret:
    want = "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, sig or ""):
        sys.stderr.write("HMAC mismatch\n"); sys.exit(4)
try:
    d = json.loads(raw or b"{}")
except Exception as e:
    sys.stderr.write("bad JSON: %s\n" % e); sys.exit(5)
repo = ((d.get("repository") or {}).get("full_name")) or ""
num = ""
for k in ("pull_request", "issue", "check_run", "check_suite"):
    o = d.get(k)
    if isinstance(o, dict) and o.get("number"):
        num = str(o["number"]); break
if not repo:
    sys.stderr.write("no repository.full_name\n"); sys.exit(7)
print(repo + "\t" + num)
'
}

# Debounce a (class, slug) kick. Returns 0 (SKIP) when the same pair fired within
# DEBOUNCE seconds; else records now and returns 1 (proceed). DEBOUNCE=0 ⇒ never skip.
wh_debounced() { # $1=class $2=slug
  [ "$DEBOUNCE" -gt 0 ] || return 1
  local f="$STATE/kick_${1}_${2}" last t
  t=$(now); last=$(cat "$f" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $(( t - last )) -lt "$DEBOUNCE" ]; then return 0; fi
  echo "$t" > "$f" 2>/dev/null || :
  return 1
}

# Route ONE delivery (stdin) of event type $1 to the right targeted refresher. The
# event class picks the writer; the repo comes from the payload. Never writes a
# cache directly — it invokes the owner (pr-refresh / collector), which are the
# single writers. Unknown event types are ignored.
wh_route() { # $1=event
  local event="${1:-}" class row repo num slug
  case "$event" in
    pull_request|check_run|check_suite|status) class="pr" ;;
    issues)                                    class="issues" ;;
    ping)   log "route: ping — webhook wired"; return 0 ;;
    '')     log "route: no event type — ignoring"; return 0 ;;
    *)      log "route: ignoring event '$event'"; return 0 ;;
  esac
  row=$(wh_extract) || { log "route: $event delivery rejected (HMAC/parse) — no refresh"; return 0; }
  IFS=$'\t' read -r repo num <<EOF
$row
EOF
  repo=$(fleet_norm_repo "$repo")
  [ -n "$repo" ] || { log "route: $event — no repo in delivery, ignoring"; return 0; }
  slug=$(fleet_slug "$repo")
  if wh_debounced "$class" "$slug"; then
    log "route: $event $repo${num:+ #$num} — debounced (<${DEBOUNCE}s)"; return 0
  fi
  case "$class" in
    pr)     log "route: $event $repo${num:+ #$num} → pr-refresh --repo";  "$PR_REFRESH_CMD" --repo "$repo" >/dev/null 2>&1 || log "route: pr-refresh kick failed for $repo" ;;
    issues) log "route: $event $repo${num:+ #$num} → collect --issues";  "$ISSUES_REFRESH_CMD" --issues "$repo" >/dev/null 2>&1 || log "route: issues kick failed for $repo" ;;
  esac
  return 0
}

# ============================== ingress: --handler =============================
# The localhost receiver: a threaded HTTP server on 127.0.0.1:<port>. Each POST is
# a `gh webhook forward` re-delivery — read the body + X-GitHub-Event +
# X-Hub-Signature-256 headers, ACK 200 immediately (so the relay never backs off on
# a slow kick), then run `--route` in this request's thread (reaped, no zombie).
# ThreadingHTTPServer ⇒ a slow kick never head-of-line-blocks the next delivery.
wh_handler() {
  command -v python3 >/dev/null 2>&1 || { log "--handler needs python3"; exit 2; }
  log "handler listening on $URL (events: $EVENTS)"
  WH_SELF="$0" WH_PORT="$PORT" python3 - <<'PY'
import os, sys, subprocess, http.server, socketserver
SELF = os.environ["WH_SELF"]; PORT = int(os.environ.get("WH_PORT", "8917"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass                     # quiet; we log in --route
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n > 0 else b""
            event = self.headers.get("X-GitHub-Event", "") or ""
            sig = self.headers.get("X-Hub-Signature-256", "") or ""
        except Exception as e:
            sys.stderr.write("handler read error: %s\n" % e)
            self.send_response(400); self.end_headers(); return
        # ACK first — decouple the relay from the kick latency.
        self.send_response(200); self.end_headers()
        try: self.wfile.write(b"ok")
        except Exception: pass
        env = dict(os.environ); env["FLEET_DELIVERY_SIG"] = sig
        try:
            subprocess.run(["/bin/bash", SELF, "--route", "--event", event],
                           input=body, env=env)
        except Exception as e:
            sys.stderr.write("handler route error: %s\n" % e)
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
try:
    Server(("127.0.0.1", PORT), H).serve_forever()
except Exception as e:
    sys.stderr.write("handler bind/serve failed on 127.0.0.1:%d: %s\n" % (PORT, e))
    sys.exit(1)
PY
}

# ============================ fleet selection ==================================
# session → its FLEET_REPO IFF that fleet opts in (FLEET_WEBHOOK=1), else empty.
# Read in a subshell so the per-fleet conf never leaks into ours (we don't
# fleet_load_conf: FLEET_WEBHOOK is a plain per-fleet bool, FLEET_REPO is identity).
wh_opted_in_repo() { # $1=session
  local sess="${1:-}" conf on repo
  conf=$(fleet_conf_file "$sess"); [ -f "$conf" ] || return 0
  IFS=$'\t' read -r on repo < <( ( . "$conf" >/dev/null 2>&1
    printf '%s\t%s\n' "${FLEET_WEBHOOK:-0}" "$(fleet_norm_repo "${FLEET_REPO:-}")" ) )
  [ "$on" = 1 ] || return 0
  [ -n "$repo" ] && printf '%s\n' "$repo"
  return 0
}

# The repos to forward: opted-in, one line each, DEDUPED per repo (single forward
# per repo — two sessions on one repo don't double-forward). Default session set is
# the live fleet sockets (like fleet-watch); explicit sessions override (selftest).
wh_desired_repos() { # [session...]
  local sessions seen=' ' sess repo
  if [ "$#" -gt 0 ]; then sessions=$(printf '%s\n' "$@"); else sessions=$(fleet_sockets); fi
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    repo=$(wh_opted_in_repo "$sess"); [ -n "$repo" ] || continue
    case "$seen" in *" $repo "*) continue;; esac
    seen="$seen$repo "
    printf '%s\n' "$repo"
  done <<EOF
$sessions
EOF
}

# ============================ forward supervision ==============================
wh_spawn_forward() { # $1=repo $2=pidfile
  local repo="$1" pidf="$2" fl="$LOGP/webhook.forward.log"
  if [ -n "$FWD_CMD" ]; then
    # selftest seam: a fake forward (stays alive so restart can be exercised)
    $FWD_CMD --repo "$repo" --events "$EVENTS" --url "$URL" >>"$fl" 2>&1 &
  elif ! command -v gh >/dev/null 2>&1; then
    log "gh not found — cannot forward $repo"; return 1
  elif [ -n "$SECRET" ]; then
    gh webhook forward --repo "$repo" --events "$EVENTS" --url "$URL" --secret "$SECRET" >>"$fl" 2>&1 &
  else
    gh webhook forward --repo "$repo" --events "$EVENTS" --url "$URL" >>"$fl" 2>&1 &
  fi
  echo $! > "$pidf"
  log "forward up: $repo (pid $(cat "$pidf" 2>/dev/null))"
  return 0
}

# One reconcile pass: start a forward for every desired repo not already running
# (or whose forward died), and reap forwards whose repo left the desired set.
wh_reconcile() { # [session...]
  mkdir -p "$FWD" 2>/dev/null || :
  local want live=' ' repo slug pidf pid
  want=$(wh_desired_repos "$@")
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug=$(fleet_slug "$repo"); live="$live$slug "
    pidf="$FWD/$slug.pid"
    pid=$(cat "$pidf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi   # already forwarding
    [ -n "$pid" ] && log "forward for $repo died (pid $pid) — restarting"
    wh_spawn_forward "$repo" "$pidf"
  done <<EOF
$want
EOF
  # reap departed repos (opted out, or fleet went down)
  for pidf in "$FWD"/*.pid; do
    [ -f "$pidf" ] || continue
    slug=$(basename "$pidf" .pid)
    case "$live" in *" $slug "*) continue;; esac
    pid=$(cat "$pidf" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$pidf"
    log "forward down: $slug (no longer a live opted-in fleet)"
  done
}

# =============================== supervise =====================================
wh_handler_alive() { local p; p=$(cat "$HANDLER_PIDF" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
wh_start_handler() {
  "$0" --handler >>"$LOGP/webhook.handler.log" 2>&1 &
  echo $! > "$HANDLER_PIDF"
  log "handler started (pid $!)"
}
# shellcheck disable=SC2317  # invoked via the EXIT/INT/TERM trap
wh_shutdown() {
  local pidf p
  for pidf in "$FWD"/*.pid "$HANDLER_PIDF"; do
    [ -f "$pidf" ] || continue
    p=$(cat "$pidf" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -f "$pidf"
  done
}
wh_supervise() {
  # Singleton is guaranteed in production by launchd KeepAlive / systemd, so a stale
  # handler pidfile from a killed run is the only real hazard — a second bind fails
  # loudly in the handler log. Clear any stale handler pid up front.
  wh_handler_alive || rm -f "$HANDLER_PIDF" 2>/dev/null || :
  trap 'wh_shutdown' EXIT INT TERM
  wh_start_handler
  while :; do
    wh_handler_alive || { log "handler not alive — restarting"; wh_start_handler; }
    wh_reconcile
    [ "${WEBHOOK_ONCE:-0}" = 1 ] && break
    sleep "$RESCAN"
  done
}

# =============================== dispatch ======================================
MODE=supervise EVENT=''
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --route)      MODE=route ;;
    --event)      EVENT="${2:-}"; shift ;;
    --handler)    MODE=handler ;;
    --desired)    MODE=desired;   shift; ARGS=("$@"); break ;;
    --reconcile)  MODE=reconcile; shift; ARGS=("$@"); break ;;
    --once)       WEBHOOK_ONCE=1 ;;
    -h|--help)    sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           log "unknown flag: $1"; exit 2 ;;
    *)            log "unexpected argument: $1"; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  route)      wh_route "$EVENT" ;;
  handler)    wh_handler ;;
  desired)    wh_desired_repos ${ARGS[@]+"${ARGS[@]}"} ;;
  reconcile)  wh_reconcile   ${ARGS[@]+"${ARGS[@]}"} ;;
  supervise)  wh_supervise ;;
esac
