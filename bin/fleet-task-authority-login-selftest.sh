#!/bin/bash
# fleet-task-authority-login-selftest.sh — who runs tasks is a LOGIN's person's,
# not a repo's (issue #4901, the node half of #4896).
#
# One machine, two logins (two FLEET_CONF_DIRs, two node tokens: alice and bob),
# ONE repo both host. A loopback stand-in for the hub answers /v1/fleet/authority
# per token, as #4896's hub does.
#
#   N  no hub: the guard asks nothing and opens as before, byte for byte
#   A  alice cuts over (dry-run → freeze → apply): her fleet.conf [node] says hub,
#      bob's login and every repo overlay keep every byte
#   O  opening: alice's local open is refused (hub wants an accepted task); bob's
#      opens and reserves a start of HIS node — twice (a restart) — while alice is
#      frozen or hub; bob's freeze in turn does not touch alice's gate
#   S  settle: each login's `--settle --apply` (no repo = every hosted repo) closes
#      only its own node's dead starts
#   Y  the hub's push: bob's authority-sync writes nothing; alice's re-reads hub
#   R  rollback: alice back to legacy, her login opens again; bob never moved
#
# Drives bin/fleet_repo_authority.py, bin/fleet-repo.sh (authority),
# bin/fleet-lib.sh (fleet_repo_authority_guard, fleet_task_authority),
# bin/fleet-conf.sh (set-node), bin/fleet-hub-node.sh (authority-sync),
# bin/fleet_hub_rest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/task-authority-login.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HUBPID=''
trap '[ -n "$HUBPID" ] && { kill "$HUBPID"; wait "$HUBPID"; } 2>/dev/null; rm -rf "$WORK"' EXIT
unset TMUX TMUX_PANE CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_SESSION FLEET_LAUNCH \
      FLEET_TASK_AUTHORITY FLEET_HUB_AUTHORITY_CMD CCQUOTA_FLEET FLEET_SKIP_GLOBAL_CONF \
      FLEET_AUTHORITY_START _FLEET_GLOBAL_CONF_SOURCED
export HOME="$WORK/home" FLEET_HUB_TIMEOUT=5
mkdir -p "$HOME"

FAILS=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: [$3] not in [$2]" ;; esac; }

# ---- the hub stand-in: one authority row per PERSON (the token's), local
# starts kept per node; every request is one line in $WORK/hub.log.
cat > "$WORK/hub.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
who = {"Bearer t-alice": ("alice", "ep-alice"), "Bearer t-bob": ("bob", "ep-bob")}
rows = {o: {"owner": o, "mode": "legacy", "revision": 0} for o in ("alice", "bob")}
starts = {}
OLD = "2026-01-01T00:00:00Z"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, doc):
        b = json.dumps(doc).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def route(self, body):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        ident = who.get(self.headers.get("Authorization", ""))
        with open(work + "/hub.log", "a") as f:
            f.write("%s %s %s %s %s\n" % (ident[0] if ident else "-", self.command, u.path,
                                          urllib.parse.urlencode(sorted(q.items())), json.dumps(body, sort_keys=True)))
        if not ident:
            return self.answer(401, {"error": "token"})
        owner, ep = ident
        a = rows[owner]
        if u.path == "/v1/fleet/authority":
            if self.command == "GET":
                if q.get("gate") == "1":
                    return self.answer(200, a)
                return self.answer(200, {"authority": a, "nodes": [], "legacy_owners": [], "blockers": [],
                                         "starts": [], "tasks": [], "tickets": []})
            if body.get("expected_revision") != a["revision"]:
                return self.answer(409, {"error": "stale revision"})
            a.update(mode={"freeze": "frozen", "apply": "hub", "rollback": "legacy"}[body["action"]],
                     revision=a["revision"] + 1)
            return self.answer(200, a)
        if u.path == "/v1/fleet/authority/start":
            repo = q.get("repo", "")
            if self.command == "GET" and q.get("list") == "1":
                mine = [dict(s) for s in starts.values() if s["endpoint_id"] == ep and s["repo"] == repo
                        and s["phase"] not in ("cancelled", "stopped", "abandoned")]
                return self.answer(200, {"repo": repo, "endpoint_id": ep, "starts": mine})
            key, action = body.get("reservation", ""), body.get("action", "")
            if action == "reserve":
                if a["mode"] != "legacy":
                    return self.answer(409, {"error": "task authority refuses a local start: " + a["mode"]})
                starts[key] = {"reservation": key, "repo": repo, "owner": owner, "endpoint_id": ep,
                               "phase": "reserved", "updated": OLD}
                return self.answer(200, starts[key])
            s = starts.get(key)
            if not s or s["endpoint_id"] != ep:
                return self.answer(409, {"error": "original reservation is unavailable in this scope"})
            if action == "cancel" and s["phase"] == "reserved":
                s["phase"] = "cancelled"
                return self.answer(200, s)
            return self.answer(409, {"error": "bad transition"})
        return self.answer(404, {"error": "path " + u.path})
    def do_GET(self): self.route({})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.route(json.loads(self.rfile.read(n) or b"{}"))
s = HTTPServer(("127.0.0.1", 0), H)
open(work + "/hub.port", "w").write(str(s.server_port))
s.serve_forever()
EOF
python3 "$WORK/hub.py" "$WORK" & HUBPID=$!
for _ in $(seq 1 50); do [ -s "$WORK/hub.port" ] && break; sleep 0.1; done
PORT=$(cat "$WORK/hub.port" 2>/dev/null)
[ -n "$PORT" ] || { echo 'selftest: hub stand-in did not start' >&2; exit 1; }

# ---- two logins, one repo: each its own conf dir, fleet `fx`, overlay o/app.
for who in alice bob; do
  d="$WORK/$who"; mkdir -p "$d/fleets/fx/repos"
  : > "$d/fleets/fx/conf"
  printf 'FLEET_REPO="o/app"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_TICKETS="github"\n' "$WORK/src" \
    > "$d/fleets/fx/repos/o-app.conf"
  printf 'o-app\n' > "$d/fleets/fx/repos/.order"
done
hub_on() { printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=t-%s\n' "$PORT" "$1" > "$WORK/$1/node.env"
           chmod 600 "$WORK/$1/node.env"; }
digest() { find "$WORK/$1" -type f ! -name '*.lock' -print0 | sort -z | xargs -0 cat | cksum; }
# as <login> <cmd…> — run as that login: its conf dir, its own lib load.
as() { local who="$1"; shift; FLEET_CONF_DIR="$WORK/$who" "$@"; }
guard() {   # guard <login> <--gate|--finish> → "rc<TAB>reservation" (stderr → $WORK/guard.err)
  FLEET_CONF_DIR="$WORK/$1" CCQUOTA_FLEET="${CQ:-1}" bash -c '. "$1/fleet-lib.sh"
    fleet_repo_authority_guard o/app "$2" fx >/dev/null; rc=$?
    printf "%s\t%s" "$rc" "${FLEET_AUTHORITY_START:-}"' _ "$BIN" "$2" 2>"$WORK/guard.err"
}
asked() { [ -f "$WORK/hub.log" ] && grep -c "^$1 " "$WORK/hub.log" || echo 0; }
login_mode() { as "$1" bash -c '. "$1/fleet-lib.sh"; fleet_task_authority fx o/app' _ "$BIN"; }

# ---- N: no hub here ----
pre=$(digest alice)
chk "N no hub, no selection: the guard opens as before" "$(CQ=0 guard alice --finish)" "0	"
chk "N …and asks nothing" "$(asked alice)" 0
chk "N …nothing written" "$(digest alice)" "$pre"
chk "N no selection reads empty" "$(login_mode alice)" ""

# ---- A: alice cuts over; bob and every overlay keep every byte ----
hub_on alice; hub_on bob
r=$(guard alice --finish); chk "A alice (legacy) opens and reserves" "${r%%	*}" 0; SA=${r#*	}
r=$(guard bob --finish); chk "A bob (legacy) opens and reserves" "${r%%	*}" 0; SB=${r#*	}
bob_before=$(digest bob); ov_before=$(cksum < "$WORK/alice/fleets/fx/repos/o-app.conf")
for stage in freeze apply; do
  as alice bash "$BIN/fleet-repo.sh" authority --dry-run > "$WORK/m.json" 2>"$WORK/a.err" \
    || fail "A dry-run: $(cat "$WORK/a.err")"
  as alice bash "$BIN/fleet-repo.sh" authority o/app --"$stage" --manifest "$WORK/m.json" >/dev/null 2>"$WORK/a.err" \
    || fail "A $stage: $(cat "$WORK/a.err")"
done
chk "A alice's login now reads hub" "$(login_mode alice)" hub
grep -q '^if \[ "${FLEET_SHELL:-0}" != 1 \]; then$' "$WORK/alice/fleet.conf" \
  && grep -q '^FLEET_TASK_AUTHORITY="hub"$' "$WORK/alice/fleet.conf" \
  && ok "A …written in fleet.conf [node]" || fail "A fleet.conf: $(cat "$WORK/alice/fleet.conf")"
chk "A alice's repo overlay unchanged" "$(cksum < "$WORK/alice/fleets/fx/repos/o-app.conf")" "$ov_before"
chk "A bob's login unchanged (same machine, same repo)" "$(digest bob)" "$bob_before"
chk "A bob still legacy" "$(login_mode bob)" ""
if grep '^alice POST /v1/fleet/authority ' "$WORK/hub.log" | grep -q 'repo='; then
  fail "A a cutover POST named a repo"; else ok "A every cutover POST is the person's (no repo)"; fi

# ---- O: opening and restarting, each login on its own ----
r=$(guard alice --finish)
chk "O alice's local open refused (hub wants an accepted task)" "${r%%	*}" 1
has "O …saying why" "$(cat "$WORK/guard.err")" "accepted, verified launch"
r=$(guard bob --finish); chk "O bob opens while alice is hub" "${r%%	*}" 0; SB2=${r#*	}
r=$(guard bob --finish); chk "O bob restarts (a new admission)" "${r%%	*}" 0
[ -n "$SB2" ] && [ "$SB2" != "${r#*	}" ] && ok "O …each a reservation of its own" || fail "O reservations: $SB2 ${r#*	}"
grep -q "^bob POST /v1/fleet/authority/start repo=o%2Fapp .*\"reserve\"" "$WORK/hub.log" \
  && ok "O bob's start names the repo it opens in" || fail "O start request: $(grep '^bob' "$WORK/hub.log")"
as bob bash "$BIN/fleet-repo.sh" authority --dry-run > "$WORK/mb.json" 2>/dev/null
as bob bash "$BIN/fleet-repo.sh" authority --freeze --manifest "$WORK/mb.json" >/dev/null 2>&1
chk "O bob froze himself" "$(login_mode bob)" frozen
r=$(guard bob --gate); chk "O …bob's own open refused" "${r%%	*}" 1
has "O …as frozen" "$(cat "$WORK/guard.err")" "frozen"
r=$(guard alice --gate); chk "O bob's freeze does not touch alice's gate" "${r%%	*}" 0

# ---- S: each login settles only its own node's starts ----
as alice python3 "$BIN/fleet_repo_authority.py" --settle --apply > "$WORK/sa.json" 2>"$WORK/s.err" \
  || fail "S alice settle: $(cat "$WORK/s.err")"
chk "S alice's settle walks her hosted repo" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(r["repo"] for r in d["repos"]))' "$WORK/sa.json")" "o/app"
chk "S …and cancels only her own dead start" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(s["reservation"]+"="+s.get("result","") for r in d["repos"] for s in r["starts"]))' "$WORK/sa.json")" \
  "$SA=cancelled"
as bob python3 "$BIN/fleet_repo_authority.py" o/app --settle > "$WORK/sb.json" 2>/dev/null
chk "S bob's (dry) settle sees only his node's three" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["starts"]), d["endpoint_id"], d["apply"])' "$WORK/sb.json")" "3 ep-bob False"
grep -q "\"reservation\": \"$SB\"" "$WORK/sb.json" && ok "S …his first start still open" || fail "S bob lost $SB"

# ---- Y: the hub's push re-reads the PERSON's row ----
out=$(as bob bash "$BIN/fleet-hub-node.sh" authority-sync o/app 2>&1)
has "Y bob's sync writes nothing new (already frozen)" "$out" '"changed": []'
printf 'FLEET_HOST=1\n' > "$WORK/alice/fleet.conf"   # alice's line lost: the next push puts it back
out=$(as alice bash "$BIN/fleet-hub-node.sh" authority-sync o/app 2>&1)
has "Y alice's sync re-reads hub" "$out" '"changed": ["fleet.conf"]'
chk "Y …her login reads hub again" "$(login_mode alice)" hub
grep -q '^FLEET_HOST=1$' "$WORK/alice/fleet.conf" && ok "Y …the rest of her fleet.conf kept" || fail "Y fleet.conf: $(cat "$WORK/alice/fleet.conf")"

# ---- R: alice rolls back; bob's row never moved for her ----
as alice bash "$BIN/fleet-repo.sh" authority --dry-run > "$WORK/m.json" 2>/dev/null
as alice bash "$BIN/fleet-repo.sh" authority --rollback --manifest "$WORK/m.json" >/dev/null 2>"$WORK/a.err" \
  || fail "R rollback: $(cat "$WORK/a.err")"
chk "R alice back to legacy" "$(login_mode alice)" legacy
r=$(guard alice --finish); chk "R …and opens locally again" "${r%%	*}" 0
chk "R bob is still where HE put himself" "$(login_mode bob)" frozen

[ "$FAILS" = 0 ] && { echo "fleet-task-authority-login-selftest: PASS"; exit 0; }
echo "fleet-task-authority-login-selftest: $FAILS failure(s)" >&2; exit 1
