#!/bin/bash
# fleet-ticket-hub-selftest.sh — the ticket door's hub backend (issue #3595, EPIC
# #3570 C2): a repo whose FLEET_TICKETS=hub opens, reads, comments, claims, labels,
# links and closes its tickets on the hub, and never once asks GitHub.
#
# Hermetic: a stand-in hub (python, 127.0.0.1, an ephemeral port) answers C1's
# /v1/fleet/tickets routes in memory and logs every request; a `gh` shim on PATH
# records every call and fails. The node token sits in the sandbox's node.env and
# is checked on every request.
#
#   A. home / id / url: the hub repo's id is hub:<repo>#N, the other repo's gh:
#   B. every verb on a hub ticket — new (the filer: marker + taxonomy), new --filed,
#      read (gh-shaped JSON), comment (fleet-comment.sh: footer + no-relay marker),
#      post, edit, state closed/open, claim (+ 409 → exit 3, release), label
#      add/rm, priority, link + children, list, find, the python door's run()
#   C. the collector's cache: issues / labels / parents in GitHub's exact shape
#   D. 0 gh calls through all of A–C
#   E. hub down (ticket-hub-down): a verb exits 4 saying 入口不通; the cache keeps
#      the last good copy
#   F. degenerate (FLEET_TICKETS unset = github): fleet-comment.sh and the filer
#      hand gh the very argv they always did, stdout = gh's URL
#   N. (n) adding a hub repo changes nothing for the fleet's other repo: its home,
#      its id and its comment's gh argv, byte for byte
#
# Drives: bin/fleet-ticket.sh, bin/fleet_ticket.py, bin/fleet-comment.sh,
# bin/fleet-issue-file.sh, fleet_ticket_home (bin/fleet-lib.sh).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-ticket.sh fleet_ticket.py fleet-comment.sh fleet-issue-file.sh fleet-lib.sh fleet-gh-lib.sh; do
  [ -f "$BIN/$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }
unset TMUX TMUX_PANE CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_TICKETS FLEET_TICKET_BACKEND FLEET_HUB CF_REPO FLEET_REPO
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ticket-hub-selftest.XXXXXX")" || exit 2
HUBPID=''
trap '[ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/fakebin" "$WORK/conf/fleets/fs/repos" "$WORK/tmp"
GHLOG="$WORK/gh.log"; : > "$GHLOG"
cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
printf 'gh' >> "$GH_LOG"; for a in "$@"; do a=${a//$'\n'/\\n}; printf ' [%s]' "$a" >> "$GH_LOG"; done; echo >> "$GH_LOG"
[ "${GH_OK:-0}" = 1 ] || exit 1
case "$1 $2" in
  'issue comment') echo "https://github.com/$5/issues/$3#issuecomment-1" ;;
  'issue create')  echo "https://github.com/$4/issues/77" ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin/gh"

# ---- the stand-in hub --------------------------------------------------------
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
printf 'FLEET_TICKETS=hub\n' > "$WORK/conf/fleets/fs/repos/acme-app.conf"
printf 'acme-app\n' > "$WORK/conf/fleets/fs/repos/.order"

T()  { env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" \
         GH_LOG="$GHLOG" FLEET_GH_WRITE_GAP=0 bash "$BIN/fleet-ticket.sh" "$@"; }
FC() { env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" \
         GH_LOG="$GHLOG" FLEET_GH_WRITE_GAP=0 bash "$BIN/$1" "${@:2}"; }

# ============================ A: home / id / url ===============================
[ "$(T home acme/app)" = hub ] || fail "A home of the hub repo"
[ "$(T home acme/lib)" = github ] || fail "A home of a repo without FLEET_TICKETS"
[ "$(T id acme/app 5)" = 'hub:acme/app#5' ] || fail "A id mints hub:" "$(T id acme/app 5 2>&1)"
[ "$(T id acme/lib 5)" = 'gh:acme/lib#5' ] || fail "A id mints gh:"
[ "$(T url 'hub:acme/app#5')" = "http://127.0.0.1:$PORT/fleet/tickets/acme/app/5" ] || fail "A url of a hub ticket" "$(T url 'hub:acme/app#5' 2>&1)"
ok "A home · id · url by the repo's FLEET_TICKETS"

# ============================ B: every verb ===================================
out=$(T new --repo acme/app --title '桌面单' --body 'first line' 2>"$WORK/err") || fail "B new (desk)" "$(cat "$WORK/err")"
[ "${out%%	*}" = 'hub:acme/app#1' ] || fail "B new prints the hub id" "$out"
body=$(T read 'hub:acme/app#1' --json body,labels) || fail "B read"
case "$body" in *'first line'*'fleet:from'*'"desk"'*'"_source": "hub"'*) ;; *) fail "B the desk ticket went through the filer (marker + desk label)" "$body" ;; esac
url=$(FC fleet-issue-file.sh --repo acme/app --title '入口单' --body 'b' --label bug --priority p1 2>"$WORK/err") \
  || fail "B the filer opens a hub ticket" "$(cat "$WORK/err")"
[ "$url" = "http://127.0.0.1:$PORT/fleet/tickets/acme/app/2" ] || fail "B the filer prints the ticket URL, number last" "$url"
FC fleet-issue-file.sh --repo acme/app --title 'x' --label nonsense-label >/dev/null 2>&1 && fail "B the taxonomy still refuses an off-list label"
FC fleet-issue-file.sh --repo acme/app --title '子单' --parent 2 >/dev/null 2>"$WORK/err" || fail "B the filer with --parent" "$(cat "$WORK/err")"
grep -q 'linked #3 as a sub-issue of #2' "$WORK/err" || fail "B --parent hangs it on the hub" "$(cat "$WORK/err")"
[ "$(T children 'hub:acme/app#2')" = "$(printf 'hub:acme/app#3\topen')" ] || fail "B children" "$(T children 'hub:acme/app#2' 2>&1)"
j=$(T read 'hub:acme/app#2' --json state,labels,number) || fail "B read #2"
case "$j" in *'"state": "OPEN"'*'priority:p1'*'"number": 2'*) ;; *) fail "B read: gh field names, priority as its label" "$j" ;; esac
c=$(FC fleet-comment.sh 2 --repo acme/app --body '进展' 2>"$WORK/err") || fail "B fleet-comment.sh on a hub repo" "$(cat "$WORK/err")"
case "$c" in "http://127.0.0.1:$PORT/fleet/tickets/acme/app/2#comment-1") ;; *) fail "B the comment URL" "$c" ;; esac
cm=$(T read 'hub:acme/app#2' --json comments)
case "$cm" in *'进展'*'fleet:from'*'fleet:no-relay'*) ;; *) fail "B the comment carries footer + no-relay marker" "$cm" ;; esac
T comment 'hub:acme/app#2' --body 'via door' >/dev/null 2>&1 || fail "B comment through the door"
T post 'hub:acme/app#2' --body 'raw' >/dev/null || fail "B post"
[ "$(T edit 'hub:acme/app#2' --body 'new body')" = edited ] || fail "B edit"
case "$(T read 'hub:acme/app#2' --json body)" in *'new body'*) ;; *) fail "B edit replaced the body" ;; esac
[ "$(T claim 'hub:acme/app#2' --by issue-2)" = "$(printf 'claimed\tissue-2')" ] || fail "B claim"
T claim 'hub:acme/app#2' --by issue-9 2>"$WORK/err"; rc=$?
[ "$rc" = 3 ] && grep -q 'claimed by issue-2' "$WORK/err" || fail "B a second claim exits 3 naming the holder (rc=$rc)" "$(cat "$WORK/err")"
[ "$(T claim 'hub:acme/app#2' --release)" = released ] || fail "B claim --release"
[ "$(T label add 'hub:acme/app#2' later area/ui)" = 'bug,later,area/ui' ] || fail "B label add" "$(T read 'hub:acme/app#2' --json labels)"
[ "$(T label rm 'hub:acme/app#2' later)" = 'bug,area/ui' ] || fail "B label rm"
[ "$(T priority 'hub:acme/app#2' p0)" = p0 ] || fail "B priority"
[ "$(T priority 'hub:acme/app#2' none)" = none ] || fail "B priority none"
[ "$(T link 'hub:acme/app#2' 'hub:acme/app#1')" = linked ] || fail "B link"
[ "$(T children 'hub:acme/app#2' | wc -l | tr -d ' ')" = 2 ] || fail "B link hung a second child"
[ "$(T link 'hub:acme/app#2' 'hub:acme/app#1' --remove)" = unlinked ] || fail "B link --remove"
[ "$(T state 'hub:acme/app#3' closed --reason not_planned)" = closed ] || fail "B state closed"
FC fleet-comment.sh 1 --repo acme/app --close --body '收尾' >/dev/null 2>&1 || fail "B fleet-comment.sh --close on a hub repo"
[ "$(T list --repo acme/app --state open)" = "$(printf 'hub:acme/app#2\topen')" ] || fail "B list open" "$(T list --repo acme/app --state open 2>&1; tail -5 "$HUBLOG")"
[ "$(T state 'hub:acme/app#3' open)" = open ] || fail "B state open"
f=$(T find --repo acme/app --marker '桌面') ; [ $? = 1 ] || fail "B find: a marker in no open body is exit 1" "$f"
f=$(T find --repo acme/app --marker 'fleet:from') || fail "B find"
[ "${f%%	*}" = 'hub:acme/app#3' ] || fail "B find names the first open ticket carrying it" "$f"
py=$(cd "$BIN" && env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" GH_LOG="$GHLOG" \
       python3 -c 'import fleet_ticket as t; print(t.call(["read", "hub:acme/app#2", "--json", "title"]))') || fail "B the python door"
case "$py" in *'"title": "入口单"'*) ;; *) fail "B fleet_ticket.call reads the same ticket" "$py" ;; esac
T bogus 2>/dev/null; [ $? = 2 ] || fail "B an unknown verb is usage (2)"
ok "B new · new --filed · read · comment · post · edit · state · claim (409 → 3) · label · priority · link · children · list · find · python"

# ============================ C: the collector's cache =========================
D="$WORK/cache"
env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" GH_LOG="$GHLOG" \
  python3 "$BIN/fleet_ticket.py" cache --repo acme/app --dir "$D" || fail "C cache"
[ "$(cat "$D/issues")" = "$(printf '· no milestone\t#2\t·\t入口单\n· no milestone\t#3\t·\t子单')" ] || fail "C issues in GitHub's shape" "$(cat "$D/issues")"
[ "$(cat "$D/labels")" = "$(printf '2\tbug,area/ui\n3\t')" ] || fail "C labels" "$(cat "$D/labels")"
[ "$(cat "$D/parents")" = "$(printf '3\t2')" ] || fail "C parents" "$(cat "$D/parents")"
ok "C the collector's issues / labels / parents, same shape as GitHub's"

# ============================ D: GitHub never asked ============================
[ ! -s "$GHLOG" ] || fail "D a hub repo's verbs called gh" "$(cat "$GHLOG")"
ok "D 0 gh calls for a hub repo ($(wc -l < "$HUBLOG" | tr -d ' ') hub requests)"

# ============================ E: hub down ======================================
kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; HUBPID=''
T read 'hub:acme/app#2' 2>"$WORK/err" >/dev/null; rc=$?
[ "$rc" = 4 ] && grep -q '入口不通' "$WORK/err" || fail "E hub down: exit 4, 入口不通 (rc=$rc)" "$(cat "$WORK/err")"
env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 python3 "$BIN/fleet_ticket.py" cache --repo acme/app --dir "$D" 2>/dev/null
[ $? = 4 ] || fail "E the cache pass says 4 when the hub is down"
grep -q '入口单' "$D/issues" || fail "E the last good cache stays"
FC fleet-comment.sh 2 --repo acme/app --body x >/dev/null 2>&1; [ $? = 4 ] || fail "E a comment on a hub repo says 4, never falls back to GitHub"
[ ! -s "$GHLOG" ] || fail "E hub down fell back to gh" "$(cat "$GHLOG")"
ok "E hub down: exit 4 · 入口不通 · last cache kept · no GitHub fallback"

# ============================ F: degenerate (github) ===========================
: > "$GHLOG"
c=$(GH_OK=1 FC fleet-comment.sh 9 --repo acme/lib --no-footer --body 'hello' 2>/dev/null) || fail "F fleet-comment.sh on a github repo"
[ "$c" = 'https://github.com/acme/lib/issues/9#issuecomment-1' ] || fail "F stdout is gh's URL" "$c"
grep -qxF 'gh [issue] [comment] [9] [--repo] [acme/lib] [--body] [hello\n\n<!-- fleet:no-relay -->]' "$GHLOG" \
  || fail "F the argv gh gets is what it always got" "$(cat "$GHLOG")"
: > "$GHLOG"
u=$(GH_OK=1 FC fleet-issue-file.sh --repo acme/lib --title 'plain' --body 'b' --label bug 2>/dev/null) || fail "F the filer on a github repo"
[ "$u" = 'https://github.com/acme/lib/issues/77' ] || fail "F the filer prints gh's URL" "$u"
grep -q '^gh \[issue\] \[create\] \[--repo\] \[acme/lib\] \[--title\] \[plain\] \[--body\] \[b\\n\\n<!-- fleet:from .*\] \[--label\] \[bug\]$' "$GHLOG" \
  || fail "F the create argv is what it always was" "$(cat "$GHLOG")"
ok "F FLEET_TICKETS unset: comment + filer hand gh the same argv, stdout gh's URL"

# ============================ N: (n) adding a hub repo =========================
rm -f "$WORK/conf/fleets/fs/repos/acme-app.conf"; printf '' > "$WORK/conf/fleets/fs/repos/.order"
: > "$GHLOG"
GH_OK=1 FC fleet-comment.sh 9 --repo acme/lib --no-footer --body 'hello' >"$WORK/n0" 2>/dev/null; cp "$GHLOG" "$WORK/g0"
b0="$(T home acme/lib) $(T id acme/lib 9)"
printf 'FLEET_TICKETS=hub\n' > "$WORK/conf/fleets/fs/repos/acme-app.conf"; printf 'acme-app\n' > "$WORK/conf/fleets/fs/repos/.order"
: > "$GHLOG"
GH_OK=1 FC fleet-comment.sh 9 --repo acme/lib --no-footer --body 'hello' >"$WORK/n1" 2>/dev/null
b1="$(T home acme/lib) $(T id acme/lib 9)"
cmp -s "$WORK/n0" "$WORK/n1" && cmp -s "$WORK/g0" "$GHLOG" && [ "$b0" = "$b1" ] \
  || fail "N a hub repo beside it changed the other repo's door" "$b0 / $b1"
ok "N (n) adding a hub repo changes nothing for the other repo"

printf 'fleet-ticket-hub selftest: OK (%d legs)\n' "$pass"
