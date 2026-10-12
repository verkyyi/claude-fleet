#!/bin/bash
# fleet-ticket-dispatch-selftest.sh — dispatch, claim and the panels go through the
# ticket door for a repo whose tickets live on the hub (issue #3598, EPIC #3570 C5).
#
# A repo with FLEET_TICKETS=hub and FLEET_FORGE=none: list its tickets, preview one,
# open a session on it (dash-issue-session.sh — the hub's atomic claim is the
# pre-spawn gate), refuse a second session's claim (exit 3), release a claim
# (fleet_issue_release_claim), set its priority (dash-issue-priority.sh), name its
# window (fleet_issue_win_name) and close it (dash-issue-close.sh) — with a `gh`
# stand-in that records every call and fails, asserted at 0 calls.
#
# Hermetic: a stand-in hub (python, 127.0.0.1, an ephemeral port) answers C1's
# /v1/fleet/tickets routes in memory; git and tmux are faked on PATH.
#
#   L. list + the collector's cache + the preview (tmux-issue-preview.sh)
#   S. spawn: the claim is taken by this machine's claimant, the window opens
#   R. a second machine's spawn is refused (exit 3, names the holder), no window
#   U. release (fleet_issue_release_claim): claim dropped, one record-only line
#   P. priority through dash-issue-priority.sh --commit (the ticket's own field)
#   W. fleet_issue_win_name reads the body (and an EPIC parent) through the door
#   C. close through dash-issue-close.sh
#   Z. 0 gh calls through all of it
#
# The GitHub side (FLEET_TICKETS unset) is each script's own selftest, unchanged:
# dash-issue-prespawn-dedup-selftest.sh, dash-issue-priority-selftest.sh,
# dash-issue-close-selftest.sh, fleet-bind-selftest.sh, fleet-claim-brief-selftest.sh.
#
# Drives: bin/dash-issue-session.sh, bin/dash-issue-priority.sh, bin/dash-issue-close.sh,
# bin/tmux-issue-preview.sh, bin/fleet-ticket.sh, fleet_ticket_hub / fleet_ticket_view /
# fleet_ticket_claimant / fleet_issue_release_claim / fleet_issue_win_name (bin/fleet-lib.sh).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in dash-issue-session.sh dash-issue-priority.sh dash-issue-close.sh tmux-issue-preview.sh fleet-ticket.sh fleet_ticket.py fleet-lib.sh; do
  [ -f "$BIN/$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq absent — SKIP" >&2; exit 0; }
unset TMUX TMUX_PANE CCQUOTA_HUB_URL CCQUOTA_TOKEN CCQUOTA_FLEET FLEET_TICKETS FLEET_TICKET_BACKEND FLEET_HUB CF_REPO \
      FLEET_REPO FLEET_TICKET_BY FLEET_PRESPAWN_DEDUP FLEET_SESSION
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ticket-dispatch-selftest.XXXXXX")" || exit 2
HUBPID=''
trap '[ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2
         printf -- '--- gh log ---\n%s\n' "$(cat "$GHLOG" 2>/dev/null)" >&2; exit 1; }

mkdir -p "$WORK/fakebin" "$WORK/conf/fleets/testsess/repos" "$WORK/tmp" "$WORK/main/.git"
GHLOG="$WORK/gh.log"; : > "$GHLOG"; TMUXLOG="$WORK/tmux.log"; : > "$TMUXLOG"
cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
exit 1
EOF
cat > "$WORK/fakebin/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  rev-parse) case "$*" in *--show-toplevel*) pwd -P ;; *--abbrev-ref*) echo master ;; *) echo deadbeef ;; esac ;;
  remote) echo "git@example.org:acme/app.git" ;;
  *) : ;;
esac
exit 0
EOF
cat > "$WORK/fakebin/tmux" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in
  display-message)
    case "$*" in
      *-p*) case "$*" in *window_id*) echo '@9' ;; *session_name*) echo 'testsess' ;; *) echo '' ;; esac ;;
      *) shift; printf 'display %s\n' "$*" >> "$TMUX_LOG" ;;
    esac ;;
  new-window) printf 'new-window %s\n' "$*" >> "$TMUX_LOG"; echo '@9' ;;
  run-shell) shift; [ "${1:-}" = -b ] && shift; bash -c "$1" ;;   # fleet_bg, run inline
  show-options|list-windows) : ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/git" "$WORK/fakebin/tmux"

# ---- the stand-in hub (the same as fleet-ticket-hub-selftest.sh's) ------------
cat > "$WORK/hub.py" <<'EOF'
import json, os, sys, re, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
T, C, SEQ = {}, {}, {}
LOG, TOK = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, code, doc):
        b = json.dumps(doc).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}') if n else {}
    def go(self, m):
        with open(LOG, 'a') as f: f.write(f'{m} {self.path}\n')
        if self.headers.get('Authorization') != 'Bearer ' + TOK:
            return self.out(401, {'error': 'no'})
        path, _, q = self.path.partition('?')
        qs = dict(urllib.parse.parse_qsl(q))
        rest = path[len('/v1/fleet/tickets'):].strip('/')
        if not rest:
            if m == 'POST':
                d = self.body(); r = d['repo']; SEQ[r] = SEQ.get(r, 0) + 1; n = SEQ[r]
                t = {'id': f'hub:{r}#{n}', 'repo': r, 'number': n, 'owner': 'me', 'backend': 'hub',
                     'title': d['title'], 'body': d.get('body', ''), 'state': 'open', 'labels': d.get('labels') or [],
                     'priority': d.get('priority', ''), 'parent': d.get('parent', ''), 'assignee': '',
                     'created_at': '2026-10-12T00:00:00Z', 'updated_at': '2026-10-12T00:00:00Z'}
                T[(r, n)] = t; C[(r, n)] = []
                return self.out(201, t)
            ts = [t for t in T.values() if t['repo'] == qs.get('repo', t['repo'])
                  and (not qs.get('state') or t['state'] == qs['state'])]
            return self.out(200, {'tickets': ts})
        p = rest.split('/'); key = (p[0] + '/' + p[1], int(p[2])); sub = p[3] if len(p) > 3 else ''
        t = T.get(key)
        if not t: return self.out(404, {'error': 'no such ticket of yours'})
        if sub == '' and m == 'GET': return self.out(200, {'ticket': t, 'comments': C[key]})
        if sub == '' and m == 'PATCH':
            d = self.body()
            for k in ('title', 'body', 'state', 'labels', 'priority', 'parent', 'state_reason'):
                if k in d: t[k] = d[k]
            return self.out(200, t)
        if sub == 'comments' and m == 'POST':
            d = self.body(); c = {'id': len(C[key]) + 1, 'body': d['body'], 'author': 'node', 'source': d.get('source', 'hub')}
            C[key].append(c); return self.out(201, c)
        if sub == 'claim':
            d = self.body(); by = d.get('by') or 'node'
            if d.get('release'): t['assignee'] = ''; return self.out(200, t)
            if t['assignee'] and t['assignee'] != by:
                return self.out(409, {'error': 'already claimed', 'assignee': t['assignee']})
            t['assignee'] = by; return self.out(200, t)
        if sub == 'children':
            ref = f'{key[0]}#{key[1]}'
            if m == 'POST':
                d = self.body(); cr, cn = d['child'].rsplit('#', 1); ch = T[(cr, int(cn))]
                ch['parent'] = '' if d.get('remove') else ref; return self.out(200, ch)
            return self.out(200, {'parent': ref, 'children': [x for x in T.values() if x['parent'] == ref]})
        return self.out(405, {'error': 'method'})
    def do_GET(self): self.go('GET')
    def do_POST(self): self.go('POST')
    def do_PATCH(self): self.go('PATCH')
s = HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[3], 'w').write(str(s.server_address[1]))
s.serve_forever()
EOF
HUBLOG="$WORK/hub.log"; : > "$HUBLOG"
python3 "$WORK/hub.py" "$HUBLOG" sekret "$WORK/port" & HUBPID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || fail "the stand-in hub did not start"
PORT=$(cat "$WORK/port")
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=sekret\n' "$PORT" > "$WORK/conf/node.env"
printf 'FLEET_TICKETS=hub\nFLEET_FORGE=none\nFLEET_LAND=fleet\n' > "$WORK/conf/fleets/testsess/repos/acme-app.conf"
printf 'acme-app\n' > "$WORK/conf/fleets/testsess/repos/.order"

E() { env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" \
        GH_LOG="$GHLOG" TMUX_LOG="$TMUXLOG" FLEET_GH_WRITE_GAP=0 FLEET_SESSION=testsess "$@"; }
T() { E bash "$BIN/fleet-ticket.sh" "$@"; }
asg() { T read "hub:acme/app#$1" --json assignees | jq -r '[.assignees[].login] | join(",")'; }
spawn() { # <N> [VAR=value…] — the real spawn, its exit in $WORK/rc
  local n="$1"; shift
  : > "$TMUXLOG"; rm -rf "$WORK/tmp/.claude-dash"
  E FLEET_REPO=acme/app FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master FLEET_CODEX_READY_CHECK=0 \
    "$@" bash "$BIN/dash-issue-session.sh" "$n" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  echo $? > "$WORK/rc"
}

T new --filed --repo acme/app --title '入口里的一张单' --body '先做这个' >/dev/null || fail "seed #1"
T new --filed --repo acme/app --title '第二张' --body 'b' --label bug >/dev/null || fail "seed #2"

# ============================ L: list · cache · preview ========================
[ "$(T list --repo acme/app)" = "$(printf 'hub:acme/app#1\topen\nhub:acme/app#2\topen')" ] \
  || fail "L list the hub repo's tickets" "$(T list --repo acme/app 2>&1)"
D="$WORK/cache"
E python3 "$BIN/fleet_ticket.py" cache --repo acme/app --dir "$D" || fail "L the collector's cache"
grep -qF "$(printf '#1\t·\t入口里的一张单')" "$D/issues" || fail "L the sidebar's row" "$(cat "$D/issues")"
pv=$(E FZF_PREVIEW_COLUMNS=80 bash "$BIN/tmux-issue-preview.sh" 1 --repo=acme/app 2>&1)
case "$pv" in *'入口里的一张单'*'先做这个'*) ;; *) fail "L the preview renders the hub ticket" "$pv" ;; esac
ok "L list · the collector's cache · the preview, all from the hub"

# ============================ S: spawn claims it ===============================
spawn 1
[ "$(cat "$WORK/rc")" = 0 ] || fail "S the spawn on a free hub ticket (rc=$(cat "$WORK/rc"))" "$(cat "$WORK/spawn.err")"
grep -q '^new-window' "$TMUXLOG" || fail "S the window opened" "$(cat "$TMUXLOG")"
me=$(E bash -c '. "$1/fleet-lib.sh"; fleet_ticket_claimant' _ "$BIN")
[ -n "$me" ] && [ "$(asg 1)" = "$me" ] || fail "S the hub holds the claim for this machine ($me)" "$(asg 1)"
grep -q 'POST /v1/fleet/tickets/acme/app/1/claim' "$HUBLOG" || fail "S claimed through the hub's claim route"
ok "S spawn: the hub's claim is the gate, taken by $me, window open"

# ============================ R: a second session is refused ===================
spawn 1 FLEET_TICKET_BY=other@elsewhere
[ "$(cat "$WORK/rc")" = 3 ] || fail "R a second machine's spawn exits 3 (rc=$(cat "$WORK/rc"))" "$(cat "$WORK/spawn.err")"
grep -qF "already claimed elsewhere (claimed by $me" "$WORK/spawn.err" || fail "R names the holder" "$(cat "$WORK/spawn.err")"
grep -q '^new-window' "$TMUXLOG" && fail "R no window for a refused spawn" "$(cat "$TMUXLOG")"
T claim 'hub:acme/app#1' --by other@elsewhere >/dev/null 2>&1; [ $? = 3 ] || fail "R the door's claim says 3 too"
[ "$(asg 1)" = "$me" ] || fail "R the claim stays with the first" "$(asg 1)"
ok "R a second session's claim is refused (exit 3), the first keeps it"

# ============================ U: release ======================================
E bash -c '. "$1/fleet-lib.sh"; fleet_issue_release_claim acme/app 1 "The session ended unlanded"' _ "$BIN" \
  || fail "U fleet_issue_release_claim"
[ -z "$(asg 1)" ] || fail "U the claim is released" "$(asg 1)"
cm=$(T read 'hub:acme/app#1' --json comments)
case "$cm" in *'The session ended unlanded. The ticket stays OPEN'*'fleet:no-relay'*) ;; *) fail "U one record-only line" "$cm" ;; esac
ok "U release: claim dropped, one record-only line on the ticket"

# ============================ P: priority =====================================
E bash "$BIN/dash-issue-priority.sh" 2 --commit p1 --repo=acme/app >/dev/null 2>&1 || fail "P set p1"
[ "$(T read 'hub:acme/app#2' --json priority | jq -r .priority)" = p1 ] || fail "P the ticket's priority is p1"
E bash "$BIN/dash-issue-priority.sh" 2 --commit '' --repo=acme/app >/dev/null 2>&1 || fail "P clear"
[ "$(T read 'hub:acme/app#2' --json priority | jq -r .priority)" = '' ] || fail "P cleared"
ok "P dash-issue-priority.sh sets / clears the hub ticket's priority"

# ============================ W: window name ==================================
T new --filed --repo acme/app --title '总单：不靠GH' --body '<!-- fleet:epic repo=acme/app short=不靠GH -->' >/dev/null || fail "W seed the EPIC"
T new --filed --repo acme/app --title '成员' --body '<!-- fleet:epic-member epic=3 key=C1 -->' >/dev/null || fail "W seed the member"
wn=$(E bash -c '. "$1/fleet-lib.sh"; FLEET_C="$2"; fleet_issue_win_name acme/app 4 "成员"' _ "$BIN" "$WORK/tmp") || fail "W fleet_issue_win_name"
case "$wn" in *不靠GH*) ;; *) fail "W the member's window wears its batch's 简称 (body + parent through the door)" "$wn" ;; esac
ok "W fleet_issue_win_name reads body and EPIC parent through the door ($wn)"

# ============================ C: close ========================================
printf 'y' | E bash "$BIN/dash-issue-close.sh" 2 --repo=acme/app >/dev/null 2>&1
for _ in $(seq 1 50); do [ "$(T read 'hub:acme/app#2' --json state | jq -r .state)" = CLOSED ] && break; sleep 0.1; done
[ "$(T read 'hub:acme/app#2' --json state | jq -r .state)" = CLOSED ] || fail "C dash-issue-close.sh closed the hub ticket"
ok "C dash-issue-close.sh closes the hub ticket"

# ============================ Z: GitHub never asked ============================
[ ! -s "$GHLOG" ] || fail "Z a hub repo's dispatch called gh"
ok "Z 0 gh calls ($(wc -l < "$HUBLOG" | tr -d ' ') hub requests)"

printf 'fleet-ticket-dispatch selftest: OK (%d legs)\n' "$pass"
