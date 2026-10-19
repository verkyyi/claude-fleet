#!/bin/bash
# fleet-authority-default-selftest.sh — a NEW repo's tasks start on the hub, a
# repo someone already used stays legacy (issue #4885).
#
#   A  no hub here: fleet-repo.sh add writes no FLEET_TASK_AUTHORITY and asks nothing
#   B  a hub here, a repo it never saw: add asks `init` (revision 0, the tickets'
#      home) and writes FLEET_TASK_AUTHORITY="hub"; the repo already hosted keeps
#      every byte (CLAUDE.md «adding a repo changes nothing for the others»)
#   C  a hub here, a repo another login already used (the hub refuses init): no
#      line — legacy — and the add still succeeds
#   D  --authority legacy on a hub login: no line, the hub is not asked
#   E  --authority hub on a used repo: refused:authority, nothing written;
#      a bad --authority: refused:invalid-authority
#   F  the hub cannot be reached: no line, the add still succeeds
#   G  an earlier add of the same repo already took it (init refused, gate says
#      hub): hub
#
# The hub is a stand-in on 127.0.0.1 answering /v1/fleet/tickets/authority as
# the real one does (tokenledger's TestRepoAuthorityAPIInitNewRepo pins that side).
# Drives bin/fleet-repo.sh, bin/fleet_repo_authority.py (--init-new), bin/fleet-lib.sh
# (fleet_repo_register, fleet_repo_authority_init, fleet_ticket_hub_ready).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { echo 'selftest: git not installed — SKIP' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/authority-default.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HUBPID=''
trap '[ -n "$HUBPID" ] && { kill "$HUBPID"; wait "$HUBPID"; } 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/conf"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
export FLEET_SKIP_GLOBAL_CONF=1 _FLEET_REGISTER_NO_KICK=1 GIT_TERMINAL_PROMPT=0 FLEET_HUB_TIMEOUT=5
unset TMUX TMUX_PANE CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_TICKETS FLEET_SESSION \
      FLEET_TASK_AUTHORITY FLEET_HUB_AUTHORITY_CMD CCQUOTA_FLEET

FAILS=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }

# ---- the hub stand-in: init succeeds once per repo it never saw; USED repos are
# refused (409); every request is one line in $WORK/hub.log.
cat > "$WORK/hub.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
work, used = sys.argv[1], set(sys.argv[2].split(","))
taken = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, doc):
        b = json.dumps(doc).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def route(self, body):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        with open(work + "/hub.log", "a") as f:
            f.write("%s %s %s %s\n" % (self.command, u.path, q.get("repo", ""), json.dumps(body, sort_keys=True)))
        if self.headers.get("Authorization") != "Bearer t0k":
            return self.answer(401, {"error": "token"})
        if u.path != "/v1/fleet/tickets/authority":
            return self.answer(404, {"error": "path"})
        repo = q.get("repo", "")
        if self.command == "GET":
            return self.answer(200, taken.get(repo, {"repo": repo, "mode": "legacy", "revision": 0}))
        if body.get("action") != "init" or body.get("expected_revision") != 0:
            return self.answer(400, {"error": "bad"})
        if repo in used or repo in taken:
            return self.answer(409, {"error": "repo authority refuses: repo is not new on the hub (a fleet hosts it)"})
        taken[repo] = {"repo": repo, "mode": "hub", "revision": 1, "legacy_tickets": body.get("legacy_tickets")}
        return self.answer(200, taken[repo])
    def do_GET(self): self.route({})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.route(json.loads(self.rfile.read(n) or b"{}"))
s = HTTPServer(("127.0.0.1", 0), H)
open(work + "/hub.port", "w").write(str(s.server_port))
s.serve_forever()
EOF
python3 "$WORK/hub.py" "$WORK" "o/used,o/used2" & HUBPID=$!
for _ in $(seq 1 50); do [ -s "$WORK/hub.port" ] && break; sleep 0.1; done
PORT=$(cat "$WORK/hub.port" 2>/dev/null)
[ -n "$PORT" ] || { echo 'selftest: hub stand-in did not start' >&2; exit 1; }

g() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkrepo() {   # $1=dir $2=owner/name
  mkdir -p "$(dirname "$1")"
  g init -q "$1" && g -C "$1" commit -q --allow-empty -m init && g -C "$1" branch -q -M master \
    && g -C "$1" remote add origin "https://github.com/$2.git" \
    && g -C "$1" update-ref refs/remotes/origin/master HEAD
}
for r in a b used legacy used2 off again; do mkrepo "$WORK/src/$r" "o/$r"; done

S=fa
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
: > "$FLEET_CONF_DIR/fleets/$S/conf"
conf() { printf '%s/fleets/%s/repos/o-%s.conf' "$FLEET_CONF_DIR" "$S" "$1"; }
add() { bash "$BIN/fleet-repo.sh" add --session "$S" "$@" 2>"$WORK/add.err"; }
auth() { sed -n 's/^FLEET_TASK_AUTHORITY=//p' "$(conf "$1")"; }
asked() { [ -f "$WORK/hub.log" ] || { echo 0; return; }; grep -c " o/$1 " "$WORK/hub.log"; }
hub_on()  { printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=t0k\n' "$1" > "$FLEET_CONF_DIR/node.env"; chmod 600 "$FLEET_CONF_DIR/node.env"; }

# ---- A: no hub here ----
out=$(add o/a "$WORK/src/a" --base master)
chk "A add o/a" "$out" "added:o-a"
chk "A no hub ⇒ no FLEET_TASK_AUTHORITY" "$(auth a)" ""
chk "A no hub ⇒ nothing asked" "$(asked a)" 0

# ---- B: a hub, a repo it never saw ----
hub_on "$PORT"
cp "$(conf a)" "$WORK/a.before"
out=$(add o/b "$WORK/src/b" --base master)
chk "B add o/b" "$out" "added:o-b"
chk "B new repo ⇒ hub" "$(auth b)" '"hub"'
grep -q '^POST /v1/fleet/tickets/authority o/b .*"action": "init".*"legacy_tickets": "hub"' "$WORK/hub.log" \
  && ok "B asked init with the tickets' home" || fail "B init request: $(cat "$WORK/hub.log")"
chk "B FLEET_TICKETS still hub" "$(grep '^FLEET_TICKETS=' "$(conf b)")" 'FLEET_TICKETS="hub"'
cmp -s "$WORK/a.before" "$(conf a)" && ok "B o/a's conf unchanged by adding o/b" || fail "B o/a's conf changed"

# ---- C: a repo someone already used ----
out=$(add o/used "$WORK/src/used" --base master)
chk "C add o/used" "$out" "added:o-used"
chk "C used repo ⇒ legacy (no line)" "$(auth used)" ""
grep -q 'stays legacy' "$WORK/add.err" && ok "C says why it stays legacy" || fail "C stderr: $(cat "$WORK/add.err")"

# ---- D: --authority legacy ----
out=$(add o/legacy "$WORK/src/legacy" --base master --authority legacy)
chk "D add --authority legacy" "$out" "added:o-legacy"
chk "D --authority legacy ⇒ no line" "$(auth legacy)" ""
chk "D --authority legacy ⇒ nothing asked" "$(asked legacy)" 0

# ---- E: --authority hub on a used repo; a bad --authority ----
out=$(add o/used2 "$WORK/src/used2" --base master --authority hub); rc=$?
chk "E --authority hub on a used repo refused" "$out/$rc" "refused:authority/1"
[ -e "$(conf used2)" ] && fail "E refused add wrote a conf" || ok "E refused add wrote nothing"
out=$(add o/used2 "$WORK/src/used2" --base master --authority maybe); rc=$?
chk "E bad --authority refused" "$out/$rc" "refused:invalid-authority/1"

# ---- F: the hub cannot be reached ----
dead=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
hub_on "$dead"
out=$(add o/off "$WORK/src/off" --base master)
chk "F add with the hub down" "$out" "added:o-off"
chk "F hub down ⇒ no line" "$(auth off)" ""

# ---- G: taken by an earlier add (init refused, gate says hub) ----
hub_on "$PORT"
( . "$BIN/fleet-lib.sh"; fleet_repo_authority_init o/again hub github ) >/dev/null 2>&1
out=$(add o/again "$WORK/src/again" --base master)
chk "G add o/again" "$out" "added:o-again"
chk "G already the hub's ⇒ hub" "$(auth again)" '"hub"'

[ "$FAILS" = 0 ] && { echo "fleet-authority-default-selftest: PASS"; exit 0; }
echo "fleet-authority-default-selftest: $FAILS failure(s)" >&2; exit 1
