#!/usr/bin/env bash
# fleet-console-ticket.sh — a read-only console ticket for THIS session's person
# (task T844): a one-time link into production's /app, as the person who owns
# this login, reads only. What an acceptance session photographs the 上线后怎么
# 验收 (A300) card with — phone 390 + desktop 1440, signed in, never by a login
# of its own.
#
#   fleet-console-ticket.sh [--next /app/<page>] [--ttl SECS] [--json]
#        → one line on stdout: the link (https://<hub>/auth/ticket?t=…). Open it
#          ONCE, within 2 minutes, in the browser that shoots (Playwright's
#          browser_navigate); it sets a read-only session for SECS (default 900,
#          60…1800) and lands on --next (default /app). --json prints the hub's
#          whole answer instead.
#        exit 0 the link · 2 usage · 3 no hub / node token here · 4 this session
#        has no worker assertion (not a fleet session, or no hub) · 1 the hub said
#        no (its words on stderr: a login no person owns, a person off the list,
#        revoked, the machine off for them)
#
# The hub (POST /v1/node/console-ticket) takes the node token AND this session's
# own worker assertion, so the ticket is always the login owner's and is audited
# with this session's worker id (fleet_audit console_ticket / console_ticket_used).
# The session it opens refuses every write, websocket and the conversation, and
# an admin's is a member's — docs/dev/FLEET-HUB.md «只读控制台票据». The node token
# is read inside python, never exported (issue #1491); the link is a credential
# for two minutes: print it to the browser, never into a page, an issue or a log.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"

die() { printf 'fleet-console-ticket: %s\n' "$1" >&2; exit "${2:-1}"; }

next="" ttl="" json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --next) [ $# -ge 2 ] || die "--next needs a path" 2; next="$2"; shift 2 ;;
    --ttl) [ $# -ge 2 ] || die "--ttl needs seconds" 2; ttl="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
case "$next" in ''|/app|/app/*|/app\?*) ;; *) die "--next must be a console page (/app…)" 2 ;; esac
case "$ttl" in ''|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;; *) die "--ttl must be seconds" 2 ;; esac

a="${FLEET_WORKER_ASSERT:-}"
[ -n "$a" ] || a=$(python3 "$BIN/fleet-mcp.py" --cred assert 2>/dev/null)
[ -n "$a" ] || die "this session has no worker assertion (FLEET_WORKER_CRED, a hub) — no ticket" 4

# separated (credsep.json, issue #1971): node.env is the role account's; the
# credential proxy's hub broker puts the node token in on the way out
br=""
if [ ! -r "$CONF/node.env" ] && [ -f "$CONF/credsep.json" ]; then
  br=$(bash "$BIN/fleet-cred-proxy.sh" node-token 2>/dev/null) || br=""
  case "$br" in http://127.0.0.1:*"	"fcpn1.*) ;; *) br="" ;; esac
fi

FCT_CONF="$CONF" FCT_BROKER="$br" FLEET_WORKER_ASSERT="$a" FCT_NEXT="$next" FCT_TTL="$ttl" FCT_JSON="$json" \
  python3 -I - <<'PY'
import json, os, sys, urllib.error, urllib.request
ne = {}
try:
    for line in open(os.path.join(os.environ["FCT_CONF"], "node.env")):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ne[k.strip()] = v.strip().strip('"').strip("'")
except OSError:
    pass
hub = (ne.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL", "")).rstrip("/")
public = hub
tok = ne.get("CCQUOTA_TOKEN", "")
if "\t" in os.environ.get("FCT_BROKER", ""):
    hub, tok = os.environ["FCT_BROKER"].split("\t", 1)
if not hub or not tok:
    sys.stderr.write("fleet-console-ticket: no hub / node token here (node.env)\n")
    sys.exit(3)
body = {}
if os.environ.get("FCT_NEXT"):
    body["next"] = os.environ["FCT_NEXT"]
if os.environ.get("FCT_TTL"):
    body["ttl_sec"] = int(os.environ["FCT_TTL"])
req = urllib.request.Request(hub.rstrip("/") + "/v1/node/console-ticket", data=json.dumps(body).encode(),
                             method="POST", headers={"Authorization": "Bearer " + tok,
                                                     "X-Fleet-Worker": os.environ["FLEET_WORKER_ASSERT"],
                                                     "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.loads(r.read() or b"{}")
except urllib.error.HTTPError as e:
    words = ""
    try:
        words = json.loads(e.read() or b"{}").get("error", "")
    except Exception:
        pass
    sys.stderr.write("fleet-console-ticket: the hub refused a ticket (%s%s)\n" % (e.code, ": " + words if words else ""))
    sys.exit(1)
except Exception as e:
    sys.stderr.write("fleet-console-ticket: the hub did not answer (%s)\n" % type(e).__name__)
    sys.exit(1)
path = d.get("path", "")
if not path.startswith("/auth/ticket?t="):
    sys.stderr.write("fleet-console-ticket: the hub's answer carries no ticket\n")
    sys.exit(1)
if os.environ.get("FCT_JSON") == "1":
    print(json.dumps(d))
else:
    url = d.get("url", "")
    # the broker's loopback is no address for a browser: the public one is
    print(url if url.startswith("https://") or not public else public + path)
PY
