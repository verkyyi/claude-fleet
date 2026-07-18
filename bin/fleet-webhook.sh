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
#     SLEEP-SURVIVAL (issue #391): before each (re)spawn we REAP the repo's orphaned
#     forwarder hook (a prior forward's hook that GitHub's relay left registered when
#     the host slept) — else the fresh forward's create 422s "Hook already exists"
#     and crash-loops. The restart itself backs off exponentially (capped) so a
#     persistently-failing create can't hot-loop.
#     WAKE-TRIGGERED RESTORE (issue #410): finishes the sleep-survival story. The
#     supervisor idles in short chunks and infers a host SUSPEND from the wall-clock
#     gap across a chunk (bash has no monotonic clock), so on wake it reconciles
#     within SECONDS instead of up to a full rescan later. And every forward
#     (re)spawn is paired with a one-shot CATCH-UP (pr-refresh + collect --issues)
#     for that repo — `gh webhook forward` never replays deliveries missed while it
#     was down, so this reconciles whatever changed during the gap the moment the
#     forward is back, with no manual --issues kick.
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
#   --reconcile [sess..] one reconcile pass: start missing forwards (each paired
#                       with a catch-up refresh on (re)connect), reap departed
#   --once              with supervise: run a single handler-start + reconcile, then
#                       exit (used by the selftest / a manual poke)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

LOGP="$BIN/../logs"; mkdir -p "$LOGP" 2>/dev/null || :
log() { printf '%s fleet-webhook: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }
now() {  # wall-clock seconds; FLEET_WH_NOW_FILE overrides with a scripted clock (selftest)
  local f="${FLEET_WH_NOW_FILE:-}" v
  if [ -n "$f" ]; then v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0;; esac; printf '%s\n' "$v"; return; fi
  date +%s 2>/dev/null || echo 0
}

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

# Forwarder-hook reconcile + restart backoff (issue #391). `gh webhook forward`
# registers a REAL repo hook against GitHub's relay and OWNS it for its lifetime;
# on host sleep the forward dies but the hook LINGERS, so the next forward's create
# hits HTTP 422 "Hook already exists" and crash-loops (zero delivery). We reap the
# orphan before each (re)spawn, and back the restart loop off so a persistent create
# failure can't hot-loop. Seams/knobs are overridable so the selftest needs no gh.
FWD_HOOK_HOST="${FLEET_WH_HOOK_HOST:-webhook-forwarder.github.com}"  # relay host in a forwarder hook's config.url
WH_HOOKS_LIST_CMD="${FLEET_WH_HOOKS_LIST_CMD:-}"  # <repo> → TSV rows: id \t active \t last_code \t config_url
WH_HOOK_DEL_CMD="${FLEET_WH_HOOK_DEL_CMD:-}"      # <repo> <id> → delete that hook
WH_BACKOFF_BASE="${FLEET_WH_BACKOFF_BASE:-5}";  case "$WH_BACKOFF_BASE" in ''|*[!0-9]*) WH_BACKOFF_BASE=5;; esac
WH_BACKOFF_CAP="${FLEET_WH_BACKOFF_CAP:-300}";  case "$WH_BACKOFF_CAP"  in ''|*[!0-9]*) WH_BACKOFF_CAP=300;; esac

# Wake-triggered reconcile (issue #410). The supervisor idles between reconcile
# passes in WH_TICK-second chunks and treats a chunk whose WALL-clock overran its
# sleep by >= WH_WAKE_SLACK as a host suspend (bash has no monotonic clock), waking
# to reconcile immediately rather than up to a full RESCAN later. WH_SLEEP_CMD is the
# chunk sleeper — overridable so the hermetic selftest drives the loop with a
# scripted clock and no real waiting. WH_TICK is floored at 1 and clamped to RESCAN.
WH_TICK="${FLEET_WEBHOOK_WAKE_TICK:-5}";        case "$WH_TICK"       in ''|*[!0-9]*) WH_TICK=5;; esac
[ "$WH_TICK" -lt 1 ] && WH_TICK=1
[ "$RESCAN" -ge 1 ] && [ "$WH_TICK" -gt "$RESCAN" ] && WH_TICK="$RESCAN"
WH_WAKE_SLACK="${FLEET_WEBHOOK_WAKE_SLACK:-5}";  case "$WH_WAKE_SLACK" in ''|*[!0-9]*) WH_WAKE_SLACK=5;; esac
[ "$WH_WAKE_SLACK" -lt 1 ] && WH_WAKE_SLACK=1
WH_SLEEP_CMD="${FLEET_WH_SLEEP_CMD:-sleep}"

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

# =================== forwarder-hook reconcile (issue #391) =====================
# host of a config.url ("https://webhook-forwarder.github.com/hook" → the host).
wh_url_host() { local u="${1#*://}"; printf '%s' "${u%%/*}"; }

# List repo R's hooks as TSV rows "id\tactive\tlast_code\tconfig_url". Overridable
# for the hermetic selftest; the real path is `gh api`. Empty output when gh is
# absent — the reap then no-ops (best-effort; the polling backstop covers freshness).
wh_hooks_list() { # $1=repo
  local repo="$1"
  if [ -n "$WH_HOOKS_LIST_CMD" ]; then $WH_HOOKS_LIST_CMD "$repo"; return; fi
  command -v gh >/dev/null 2>&1 || return 0
  gh api "repos/$repo/hooks" \
    --jq '.[] | [(.id|tostring), (.active|tostring), ((.last_response.code // "")|tostring), (.config.url // "")] | @tsv' \
    2>/dev/null
}

# Delete hook <id> on repo R. Overridable for the selftest; real path is `gh api`.
wh_hook_delete() { # $1=repo $2=id
  local repo="$1" id="$2"
  if [ -n "$WH_HOOK_DEL_CMD" ]; then $WH_HOOK_DEL_CMD "$repo" "$id"; return; fi
  command -v gh >/dev/null 2>&1 || return 1
  gh api -X DELETE "repos/$repo/hooks/$id" >/dev/null 2>&1
}

# Reap every FORWARDER hook (config.url host = the relay) for repo R. Called before
# each (re)spawn: we only spawn when the prior forward is dead, so any surviving
# forwarder hook is an ORPHAN whose lingering registration would 422 the fresh
# create. Non-forwarder hooks (a user's own webhook) never match the relay host, so
# they're left untouched. Best-effort: a list/delete failure is logged, never fatal.
wh_reap_forwarder_hook() { # $1=repo
  local repo="$1" id active code url host
  while IFS=$'\t' read -r id active code url; do
    [ -n "$id" ] || continue
    host=$(wh_url_host "$url")
    [ "$host" = "$FWD_HOOK_HOST" ] || continue
    if wh_hook_delete "$repo" "$id"; then
      log "reaped orphaned forwarder hook $id for $repo (active=$active last=$code)"
    else
      log "could not delete forwarder hook $id for $repo (active=$active last=$code)"
    fi
  done <<EOF
$(wh_hooks_list "$repo")
EOF
  return 0
}

# Gate a dead forward's respawn with exponential backoff (issue #391). Returns 0
# when it's time to (re)spawn — recording this death: bump the consecutive-fail
# counter and set the next deadline = now + min(BASE·2^(fails-1), CAP). Returns 1
# while still inside a prior deadline (caller skips the respawn this pass). The
# counter is cleared by wh_reconcile the moment the forward is next seen ALIVE, so a
# forward that recovers starts fresh; one that keeps dying fast throttles toward CAP.
wh_backoff_ready() { # $1=repo $2=base(=pidfile without .pid) $3=deadpid
  local repo="$1" base="$2" deadpid="$3" t deadline fails backoff i
  t=$(now)
  deadline=$(cat "$base.until" 2>/dev/null); case "$deadline" in ''|*[!0-9]*) deadline=0;; esac
  [ "$deadline" -gt 0 ] && [ "$t" -lt "$deadline" ] && return 1   # still backing off
  fails=$(cat "$base.fails" 2>/dev/null); case "$fails" in ''|*[!0-9]*) fails=0;; esac
  fails=$((fails + 1)); echo "$fails" > "$base.fails" 2>/dev/null || :
  backoff="$WH_BACKOFF_BASE"; i=1
  while [ "$i" -lt "$fails" ] && [ "$backoff" -lt "$WH_BACKOFF_CAP" ]; do
    backoff=$((backoff * 2)); i=$((i + 1))
  done
  [ "$backoff" -gt "$WH_BACKOFF_CAP" ] && backoff="$WH_BACKOFF_CAP"
  echo "$((t + backoff))" > "$base.until" 2>/dev/null || :
  log "forward for $repo died (pid $deadpid, fail #$fails) — restarting; next backoff ${backoff}s"
  return 0
}

# ============================ forward supervision ==============================
wh_spawn_forward() { # $1=repo $2=pidfile
  local repo="$1" pidf="$2" fl="$LOGP/webhook.forward.log"
  wh_reap_forwarder_hook "$repo"   # delete any orphaned relay hook first (issue #391)
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

# Catch-up reconcile after a forward (re)connects (issue #410). `gh webhook
# forward` NEVER replays deliveries that fired while it was down (a host sleep, a
# network blip), so once it's back the repo's caches are still stale for whatever
# changed during the gap. Pair each (re)spawn with ONE kick of the SAME two
# single-writers the live route path uses — pr-refresh (PR/CI) + collect --issues —
# so the gap is reconciled the instant the forward returns, with no manual --issues
# kick. Best-effort (a failed kick is logged, never fatal); the ~15s/~60s pollers
# stay the backstop.
wh_catchup() { # $1=repo
  local repo="$1"
  log "catch-up on (re)connect for $repo → pr-refresh + collect --issues"
  "$PR_REFRESH_CMD"     --repo   "$repo" >/dev/null 2>&1 || log "catch-up: pr-refresh kick failed for $repo"
  "$ISSUES_REFRESH_CMD" --issues "$repo" >/dev/null 2>&1 || log "catch-up: issues collect failed for $repo"
}

# One reconcile pass: start a forward for every desired repo not already running
# (or whose forward died), and reap forwards whose repo left the desired set.
wh_reconcile() { # [session...]
  mkdir -p "$FWD" 2>/dev/null || :
  local want live=' ' repo slug pidf base pid
  want=$(wh_desired_repos "$@")
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    slug=$(fleet_slug "$repo"); live="$live$slug "
    pidf="$FWD/$slug.pid"; base="$FWD/$slug"
    pid=$(cat "$pidf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      rm -f "$base.fails" "$base.until" 2>/dev/null || :   # healthy ⇒ clear backoff state
      continue
    fi
    # Dead (or never started). A forward that keeps dying fast — e.g. a persistent
    # create failure — must NOT hot-loop respawns, so gate a *death* on exponential
    # backoff (issue #391). A first-ever spawn (no prior pid) skips straight to launch.
    if [ -n "$pid" ] && ! wh_backoff_ready "$repo" "$base" "$pid"; then continue; fi
    # (re)connect: launch the forward, then catch up its caches for anything that
    # changed while it was down (issue #410) — gh webhook forward never replays it.
    if wh_spawn_forward "$repo" "$pidf"; then wh_catchup "$repo"; fi
  done <<EOF
$want
EOF
  # reap departed repos (opted out, or fleet went down)
  for pidf in "$FWD"/*.pid; do
    [ -f "$pidf" ] || continue
    slug=$(basename "$pidf" .pid); base="${pidf%.pid}"
    case "$live" in *" $slug "*) continue;; esac
    pid=$(cat "$pidf" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$pidf" "$base.fails" "$base.until"
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
# Decide whether a sleep chunk that ASKED for $1 seconds but saw $2 seconds of
# wall-clock pass straddled a host SUSPEND (issue #410). A normal chunk sees ~$1
# (±scheduler jitter); a suspend inflates the wall delta far past it. Flag a wake
# once the overrun reaches WH_WAKE_SLACK — chosen above jitter, well below any real
# suspend gap — so jitter never false-fires but a real sleep always does.
wh_is_wake() { # $1=tick $2=wall_delta → 0 (wake) when delta >= tick + slack
  [ "$2" -ge $(( $1 + WH_WAKE_SLACK )) ]
}

# Idle between reconcile passes in WH_TICK-second chunks, watching each chunk's
# wall-clock delta for a host-suspend gap (issue #410). Bash has no monotonic clock,
# so we infer a suspend from the mismatch between how long we asked to sleep and how
# much wall-clock actually passed. Returns 1 the instant a wake is detected (the
# caller reconciles NOW — restore ≈ seconds, not up to a full RESCAN, after wake);
# returns 0 when the full RESCAN elapsed uneventfully.
wh_sleep_or_wake() {
  local remaining="$RESCAN" tick t0 t1 delta
  while [ "$remaining" -gt 0 ]; do
    tick="$WH_TICK"; [ "$tick" -gt "$remaining" ] && tick="$remaining"
    t0=$(now); "$WH_SLEEP_CMD" "$tick"; t1=$(now)
    delta=$(( t1 - t0 )); [ "$delta" -lt 0 ] && delta=0
    if wh_is_wake "$tick" "$delta"; then
      log "wake detected (slept ${tick}s, wall +${delta}s) — reconciling now"
      return 1
    fi
    remaining=$(( remaining - tick ))
  done
  return 0
}

wh_supervise() {
  # Singleton is guaranteed in production by launchd KeepAlive / systemd, so a stale
  # handler pidfile from a killed run is the only real hazard — a second bind fails
  # loudly in the handler log. Clear any stale handler pid up front.
  wh_handler_alive || rm -f "$HANDLER_PIDF" 2>/dev/null || :
  trap 'wh_shutdown' EXIT INT TERM
  wh_start_handler
  local woke=0
  while :; do
    wh_handler_alive || { log "handler not alive — restarting"; wh_start_handler; }
    if [ "$woke" = 1 ]; then
      # A host wake was just detected (issue #410): clear any backoff deadline so a
      # forward the sleep killed respawns immediately — not gated by a pre-sleep
      # deadline — then let wh_reconcile reap the orphan hook, recreate the forward,
      # and catch its caches up, all within seconds of wake.
      rm -f "$FWD"/*.until "$FWD"/*.fails 2>/dev/null || :
      woke=0
    fi
    wh_reconcile
    [ "${WEBHOOK_ONCE:-0}" = 1 ] && break
    wh_sleep_or_wake || woke=1
  done
}

# =============================== dispatch ======================================
# When SOURCED (the hermetic selftest sources this file to unit-test wh_is_wake /
# wh_sleep_or_wake without kicking off the supervisor), stop here: defining the
# functions + config above is all a source wants. `return` is valid only in a
# sourced context, and the guard runs it only when sourced (BASH_SOURCE != $0).
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then return 0 2>/dev/null || true; fi

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
