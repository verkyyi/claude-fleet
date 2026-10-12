#!/bin/bash
# fleet-epic-hub-selftest.sh — a batch on a repo whose tickets live on the hub
# (issue #3599, EPIC #3570 C6): the steward, the batch and the evidence go through
# the ticket door, and GitHub is never asked.
#
# Hermetic: a stand-in hub (python, 127.0.0.1, an ephemeral port) answers C1's
# /v1/fleet/tickets routes in memory; a `gh` shim on PATH records every call and
# fails. The repo is `FLEET_TICKETS=hub` + `FLEET_FORGE=none` — no GitHub at all.
#
#   P. plan: preflight passes with no gh (tickets · labels · base off the checkout),
#      the label seeder has nothing to seed, the EPIC + 2 members filed through the
#      filer (--parent hangs them), the charter's member list written back (edit)
#   R. run, two ticks: fleet_sub_issues (members + states, repo carried),
#      fleet_epic_agent (the charter's agent), each member's 上线证据 line, before /
#      after evidence (the EPIC resolved off the hub's parent), a member labelled
#      blocked and unlabelled, a comment on the parent; tick 2 closes a member
#   S. the steward: fleet_decision.parent_of / fetch_comments, the health card's
#      find_open, fleet_breakage_find, fleet_park's issue condition, the mcp `gh`
#      tool's issue read (fleet-gh.sh issue view) — all off the hub
#   T. report: fleet-evidence.sh list --epic shows both members' evidence
#   Z. 0 gh calls through all of it
#   N. degenerate: a repo with no FLEET_TICKETS keeps its gh: id and its gh argv
#
# Drives: bin/fleet-ticket.sh, bin/fleet_ticket.py, bin/fleet-evidence.sh,
# bin/fleet-epic-preflight.sh, bin/fleet-labels-seed.sh, bin/fleet-issue-file.sh,
# bin/fleet-gh.sh, bin/fleet_decision.py, bin/fleet_steward_health.py,
# bin/fleet_park.py, bin/fleet_followup.py, fleet_sub_issues / fleet_epic_agent /
# fleet_breakage_find (bin/fleet-lib.sh).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-ticket.sh fleet_ticket.py fleet-evidence.sh fleet-epic-preflight.sh fleet-labels-seed.sh \
         fleet-issue-file.sh fleet-gh.sh fleet-lib.sh fleet_decision.py fleet_steward_health.py fleet_park.py; do
  [ -f "$BIN/$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }
unset TMUX TMUX_PANE CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_TICKETS FLEET_TICKET_BACKEND FLEET_HUB CF_REPO FLEET_REPO \
      FLEET_FORGE FLEET_MAIN FLEET_BASE_BRANCH FLEET_SESSION
WORK="$(mktemp -d "${TMPDIR:-/tmp}/epic-hub-selftest.XXXXXX")" || exit 2
HUBPID=''
trap '[ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/fakebin" "$WORK/conf/fleets/fs/repos" "$WORK/tmp"
GHLOG="$WORK/gh.log"; : > "$GHLOG"
cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
printf 'gh' >> "$GH_LOG"; for a in "$@"; do printf ' [%s]' "${a//$'\n'/\\n}" >> "$GH_LOG"; done; echo >> "$GH_LOG"
[ "${GH_OK:-0}" = 1 ] || exit 1
case "$1 $2" in 'issue view') echo '{"number": 5, "state": "OPEN", "title": "gh"}' ;; esac
exit 0
EOF
chmod +x "$WORK/fakebin/gh"

# ---- the stand-in hub (C1's routes, in memory) ----------------------------------
cat > "$WORK/hub.py" <<'EOF'
import json, sys, urllib.parse
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
                t = {'repo': r, 'number': n, 'owner': 'me', 'backend': 'hub', 'title': d['title'],
                     'body': d.get('body', ''), 'state': 'open', 'labels': d.get('labels') or [],
                     'priority': d.get('priority', ''), 'parent': d.get('parent', ''), 'assignee': '',
                     'created_at': '2026-10-12T00:00:00Z', 'updated_at': '2026-10-12T00:00:00Z'}
                T[(r, n)] = t; C[(r, n)] = []
                return self.out(201, t)
            ts = [t for t in T.values() if t['repo'] == qs.get('repo', t['repo'])
                  and (not qs.get('state') or t['state'] == qs['state'])
                  and (not qs.get('label') or qs['label'] in t['labels'])]
            return self.out(200, {'tickets': ts[:int(qs.get('limit') or 100)]})
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
            d = self.body(); c = {'id': len(C[key]) + 1, 'body': d['body'], 'author': 'node',
                                  'created_at': '2026-10-12T01:00:00Z'}
            C[key].append(c); return self.out(201, c)
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
python3 "$WORK/hub.py" "$HUBLOG" sekret "$WORK/port" & HUBPID=$!; disown "$HUBPID" 2>/dev/null
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || fail "the stand-in hub did not start"
PORT=$(cat "$WORK/port")

# ---- the fleet: one repo, tickets on the hub, no forge; a checkout with origin --
MAIN="$WORK/app"
git init -q -b main "$WORK/origin.git" --bare 2>/dev/null || git init -q --bare "$WORK/origin.git"
git init -q "$MAIN" && git -C "$MAIN" checkout -q -b main 2>/dev/null
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" remote add origin "$WORK/origin.git" && git -C "$MAIN" push -q origin main 2>/dev/null
git -C "$MAIN" remote set-head origin main >/dev/null 2>&1 || git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=sekret\n' "$PORT" > "$WORK/conf/node.env"
printf 'FLEET_SESSION=fs\nFLEET_REPO=acme/app\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\n' "$MAIN" > "$WORK/conf/fleets/fs/conf"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\nFLEET_TICKETS=hub\nFLEET_FORGE=none\nFLEET_LAND=fleet\n' \
  "$MAIN" > "$WORK/conf/fleets/fs/repos/acme-app.conf"
printf 'acme-app\n' > "$WORK/conf/fleets/fs/repos/.order"

E() { env FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" \
        GH_LOG="$GHLOG" FLEET_GH_WRITE_GAP=0 FLEET_SESSION=fs "$@"; }
B() { E bash "$BIN/$1" "${@:2}"; }
L() { E bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; shift; "$@"' _ "$BIN" "$@"; }
P() { (cd "$BIN" && E python3 -c "$1"); }
T() { B fleet-ticket.sh "$@"; }

# ============================ P: plan ===========================================
out=$(B fleet-epic-preflight.sh --session fs --repo acme/app 2>&1); rc=$?
case "$out" in *'gh'*'not needed'*) ;; *) fail "P preflight: gh not needed on a forge-less repo" "$out" ;; esac
case "$out" in *"tickets live on the hub"*) ;; *) fail "P preflight: the hub answers for the EPIC's tickets" "$out" ;; esac
case "$out" in *'nothing to seed'*) ;; *) fail "P preflight: labels are the fleet's table" "$out" ;; esac
case "$out" in *'main — the repo default'*) ;; *) fail "P preflight: the base off the checkout's origin" "$out" ;; esac
printf '%s\n' "$out" | grep -q 'FAIL' && fail "P preflight has no FAIL row (rc=$rc)" "$out"
seed=$(B fleet-labels-seed.sh --repo acme/app 2>&1) || fail "P the label seeder exits 0 on a hub repo" "$seed"
case "$seed" in *'nothing to seed'*) ;; *) fail "P the seeder says why" "$seed" ;; esac

epic=$(B fleet-issue-file.sh --repo acme/app --label epic --no-breakage --title 'EPIC: 小批次' \
         --body $'<!-- fleet:epic repo=acme/app short=小 agent=claude -->\n## Core\n- [ ] **C1** #new — 甲\n- [ ] **C2** #new — 乙' 2>"$WORK/err") \
  || fail "P the EPIC filed on the hub" "$(cat "$WORK/err")"
E_N=${epic##*/}; [ "$E_N" = 1 ] || fail "P the EPIC is ticket 1" "$epic"
for k in 1 2; do
  B fleet-issue-file.sh --repo acme/app --parent "$E_N" --no-breakage --title "成员 $k" \
    --body $'做点事\n\n上线证据：成员 '"$k"$' 的进度行\n<!-- fleet:epic-member epic=1 key=C'"$k"' -->' >/dev/null 2>"$WORK/err" \
    || fail "P member $k filed under the EPIC" "$(cat "$WORK/err")"
done
body=$(T read "hub:acme/app#$E_N" --json body | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
body=${body/'**C1** #new — 甲'/'**C1** #2 — 甲 (codex)'}; body=${body/'**C2** #new'/'**C2** #3'}
[ "$(printf '%s' "$body" | T edit "hub:acme/app#$E_N" --body-file -)" = edited ] || fail "P the charter's list written back"
ok "P plan: preflight green with no gh · nothing to seed · EPIC + 2 members filed and hung · list written back"

# ============================ R: run, two ticks ==================================
subs=$(L fleet_sub_issues acme/app "$E_N") || fail "R fleet_sub_issues"
[ "$subs" = "$(printf 'acme/app\t2\topen\nacme/app\t3\topen')" ] || fail "R tick 1: two open members, repo carried" "$subs"
[ "$(L fleet_epic_agent acme/app "$E_N" acme/app 2)" = codex ] || fail "R the charter's agent for C1" "$(L fleet_epic_agent acme/app "$E_N" acme/app 2 2>&1)"
[ "$(L fleet_epic_agent acme/app "$E_N" acme/app 3)" = claude ] || fail "R the EPIC marker's agent for C2"
for k in 2 3; do
  [ "$(B fleet-evidence.sh line --session fs --repo acme/app --issue "$k")" = "成员 $((k-1)) 的进度行" ] \
    || fail "R member #$k's 上线证据 line" "$(B fleet-evidence.sh line --session fs --repo acme/app --issue "$k" 2>&1)"
  printf 'before %s\n' "$k" | B fleet-evidence.sh before --session fs --repo acme/app --issue "$k" --note "改动前 $k" --name b.txt - >/dev/null 2>"$WORK/err" \
    || fail "R before evidence for #$k" "$(cat "$WORK/err")"
  printf 'after %s\n' "$k" | B fleet-evidence.sh after --session fs --repo acme/app --issue "$k" --note "改动后 $k" --name a.txt - >/dev/null 2>"$WORK/err" \
    || fail "R after evidence for #$k" "$(cat "$WORK/err")"
done
[ -s "$WORK/conf/fleets/fs/epic/$E_N/evidence/2/manifest.tsv" ] || fail "R the EPIC resolved off the hub's parent (evidence under epic/$E_N)" "$(find "$WORK/conf/fleets/fs" -name manifest.tsv)"
[ "$(T label add 'hub:acme/app#3' blocked)" = blocked ] || fail "R a member labelled blocked"
[ "$(T label rm 'hub:acme/app#3' blocked)" = '' ] || fail "R … and unblocked"
T comment "hub:acme/app#$E_N" --note --body '第 1 拍：2 个成员在跑' >/dev/null 2>"$WORK/err" || fail "R the tick's line on the parent" "$(cat "$WORK/err")"
[ "$(T state 'hub:acme/app#2' closed --reason completed)" = closed ] || fail "R tick 2: C1 lands"
subs=$(L fleet_sub_issues acme/app "$E_N")
[ "$subs" = "$(printf 'acme/app\t2\tclosed\nacme/app\t3\topen')" ] || fail "R tick 2 reads the landed member" "$subs"
ok "R run: members + states · agents · 上线证据 lines · before/after under the EPIC · blocked label · parent comment · tick 2"

# ============================ S: the steward's reads ============================
par=$(P 'import fleet_decision as fd; print(fd.parent_of("acme/app", 3))') || fail "S parent_of"
[ "$par" = "('acme/app', '1')" ] || fail "S fleet_decision.parent_of off the hub" "$par"
cm=$(P 'import fleet_decision as fd; print(len(fd.fetch_comments("acme/app", 1)))') || fail "S fetch_comments"
[ "$cm" = 1 ] || fail "S the decision sheet reads the parent's comments" "$cm"
src=$(P 'import fleet_decision as fd; print(fd._src("", "acme/app", 3))')
[ "$src" = 'hub:acme/app#3' ] || fail "S a decision row's src is the hub id" "$src"
src=$(P 'import fleet_decision as fd; print(fd._src("http://h/fleet/tickets/acme/app/3#comment-1"))')
[ "$src" = 'hub:acme/app#3' ] || fail "S a hub comment URL reads back as its ticket" "$src"
mk='<!-- fleet:health key=disk -->'
T comment "hub:acme/app#3" --note --body "x" >/dev/null 2>&1
[ "$(T edit 'hub:acme/app#3' --body "health card $mk")" = edited ] || fail "S a ticket carrying a marker"
fo=$(P "import fleet_steward_health as h; h.MARK = '<!-- fleet:health key=%s -->'; print(h.find_open('acme/app', 'disk'))")
[ "$fo" = 3 ] || fail "S the health card's find_open off the hub" "$fo"
L eval 'fleet_breakage_marker() { printf "<!-- fleet:health key=disk -->"; }; fleet_breakage_find acme/app k' >"$WORK/bf" 2>&1 \
  || fail "S fleet_breakage_find off the hub" "$(cat "$WORK/bf")"
grep -q "/fleet/tickets/acme/app/3\$" "$WORK/bf" || fail "S fleet_breakage_find prints the ticket's URL" "$(cat "$WORK/bf")"
pk=$(P 'import fleet_park as p; print(p.check("issue:acme/app#2:closed"), p.check("issue:acme/app#3:closed"))')
[ "$pk" = "(True, 'closed') (False, 'open')" ] || fail "S a park's issue condition read off the hub" "$pk"
j=$(B fleet-gh.sh issue view 3 --repo acme/app --json state,title) || fail "S fleet-gh.sh issue view (the mcp gh tool)"
case "$j" in *'"state": "OPEN"'*'"title": "成员 2"'*) ;; *) fail "S the mcp gh tool's issue read answers off the hub" "$j" ;; esac
ok "S steward: parent_of · comments · row src · health find_open · breakage find · park condition · gh tool"

# ============================ T: report =========================================
rep=$(B fleet-evidence.sh list --session fs --repo acme/app --epic "$E_N" 2>&1) || fail "T the report's list" "$rep"
for k in 2 3; do
  printf '%s\n' "$rep" | grep -q "^$k	before	" || fail "T member #$k's before row" "$rep"
  printf '%s\n' "$rep" | grep -q "^$k	after	" || fail "T member #$k's after row" "$rep"
done
ok "T report: both members' before + after, members read off the hub"

# ============================ Z: GitHub never asked =============================
[ ! -s "$GHLOG" ] || fail "Z a hub repo's batch called gh" "$(cat "$GHLOG")"
ok "Z 0 gh calls (hub: $(wc -l < "$HUBLOG" | tr -d ' ') requests)"

# ============================ N: degenerate =====================================
[ "$(P 'import fleet_ticket as t; print(t.tid("acme/lib", 4))')" = 'gh:acme/lib#4' ] || fail "N a repo with no FLEET_TICKETS keeps gh:"
GH_OK=1 B fleet-gh.sh issue view 5 --repo acme/lib --json number,state,title --max-age 0 >/dev/null 2>&1
grep -q '^gh \[issue\] \[view\] \[5\] \[--repo\] \[acme/lib\]' "$GHLOG" || fail "N fleet-gh.sh still asks gh for a GitHub repo" "$(cat "$GHLOG")"
ok "N degenerate: a GitHub repo's id and its gh argv unchanged"

printf 'fleet-epic-hub selftest: OK (%s legs)\n' "$pass"
