#!/bin/bash
# fleet-authority-default-selftest.sh — a NEW repo selects nothing: who runs
# tasks is the login's person's (issue #4901), so #4885's per-repo hub default
# is gone.
#
#   A  no hub here: fleet-repo.sh add writes no FLEET_TASK_AUTHORITY and asks nothing
#   B  a hub here: add still writes no line and asks the hub nothing; the repo
#      already hosted keeps every byte (CLAUDE.md «adding a repo changes nothing
#      for the others»)
#   C  --authority hub|legacy|<anything> (read one version, # compat-1v): added,
#      no line, nothing asked, one stderr line saying it is ignored
#   D  `fleet_repo_authority.py --init-new` (an older caller): says legacy, asks nothing
#   E  `fleet-conf.sh migrate` comments an overlay's old line out — the rest of
#      the overlay byte for byte; until then fleet_task_authority reads it, and
#      the login's fleet.conf [node] line wins over it
#
# The hub is a stand-in on 127.0.0.1 that logs every request; an authority one fails it.
# Drives bin/fleet-repo.sh, bin/fleet_repo_authority.py (--init-new), bin/fleet-lib.sh
# (fleet_repo_register, fleet_task_authority, fleet_ticket_hub_ready), bin/fleet-conf.sh.
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

# ---- the hub stand-in: answers anything, logs every request to $WORK/hub.log.
cat > "$WORK/hub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
work = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def route(self):
        with open(work + "/hub.log", "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
        b = json.dumps({"owner": "alice", "mode": "legacy", "revision": 0}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = route
s = HTTPServer(("127.0.0.1", 0), H)
open(work + "/hub.port", "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$WORK/hub.py" "$WORK" & HUBPID=$!
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
for r in a b c1 c2 c3; do mkrepo "$WORK/src/$r" "o/$r"; done

S=fa
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
: > "$FLEET_CONF_DIR/fleets/$S/conf"
conf() { printf '%s/fleets/%s/repos/o-%s.conf' "$FLEET_CONF_DIR" "$S" "$1"; }
add() { bash "$BIN/fleet-repo.sh" add --session "$S" "$@" 2>"$WORK/add.err"; }
auth() { sed -n 's/^FLEET_TASK_AUTHORITY=//p' "$(conf "$1")"; }
# Authority requests only: an add on a hub login reads other things (/v1/node/self).
asked() { if [ -f "$WORK/hub.log" ]; then grep -c /authority "$WORK/hub.log"; else echo 0; fi; }
hub_on()  { printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=t0k\n' "$1" > "$FLEET_CONF_DIR/node.env"; chmod 600 "$FLEET_CONF_DIR/node.env"; }

# ---- A: no hub here ----
out=$(add o/a "$WORK/src/a" --base master)
chk "A add o/a" "$out" "added:o-a"
chk "A no hub ⇒ no FLEET_TASK_AUTHORITY" "$(auth a)" ""
chk "A no hub ⇒ nothing asked" "$(asked)" 0

# ---- B: a hub here — still nothing selected, nothing asked ----
hub_on "$PORT"
cp "$(conf a)" "$WORK/a.before"
out=$(add o/b "$WORK/src/b" --base master)
chk "B add o/b" "$out" "added:o-b"
chk "B a hub ⇒ still no line" "$(auth b)" ""
chk "B …and the hub is not asked" "$(asked)" 0
chk "B FLEET_TICKETS still hub" "$(grep '^FLEET_TICKETS=' "$(conf b)")" 'FLEET_TICKETS="hub"'
cmp -s "$WORK/a.before" "$(conf a)" && ok "B o/a's conf unchanged by adding o/b" || fail "B o/a's conf changed"

# ---- C: --authority is read one version and only said ----
n=1
for v in hub legacy maybe; do
  out=$(add "o/c$n" "$WORK/src/c$n" --base master --authority "$v")
  chk "C --authority $v ⇒ added" "$out" "added:o-c$n"
  chk "C --authority $v ⇒ no line" "$(auth "c$n")" ""
  grep -q 'ignored' "$WORK/add.err" && ok "C --authority $v ⇒ said" || fail "C stderr: $(cat "$WORK/add.err")"
  n=$((n + 1))
done
chk "C …nothing asked" "$(asked)" 0

# ---- D: an older caller's --init-new ----
out=$(python3 "$BIN/fleet_repo_authority.py" o/new --init-new --tickets hub 2>/dev/null)
chk "D --init-new says legacy" "$out" legacy
chk "D …asking nothing" "$(asked)" 0

# ---- E: migrate comments an overlay's old line out; the login's line wins ----
printf 'FLEET_TASK_AUTHORITY="hub"\n' >> "$(conf a)"
ta() { bash -c '. "$1/fleet-lib.sh"; fleet_task_authority "$2" o/a' _ "$BIN" "$S"; }
chk "E an old overlay line is read one version" "$(ta)" hub
chk "E …the login's line wins over it" "$(FLEET_TASK_AUTHORITY=legacy ta)" legacy
bash "$BIN/fleet-conf.sh" migrate --quiet >/dev/null 2>&1
grep -q '^# moved to fleet.conf \[node\] #4901: FLEET_TASK_AUTHORITY="hub"$' "$(conf a)" \
  && ok "E migrate comments it out" || fail "E overlay: $(cat "$(conf a)")"
head -n "$(wc -l < "$WORK/a.before")" "$(conf a)" | cmp -s - "$WORK/a.before" \
  && ok "E …the rest of the overlay byte for byte" || fail "E overlay changed: $(cat "$(conf a)")"
chk "E …and it is read no more" "$(ta)" ""

[ "$FAILS" = 0 ] && { echo "fleet-authority-default-selftest: PASS"; exit 0; }
echo "fleet-authority-default-selftest: $FAILS failure(s)" >&2; exit 1
