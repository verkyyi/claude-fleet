#!/bin/bash
# fleet-agent-team-selftest.sh — the team layer: fleet default < team < local
# (issue #1726, EPIC #1718 C8). Drives bin/fleet-agent-team.py in a throwaway
# HOME, the hub's answer through the FLEET_TEAM_BUNDLE_CMD seam:
#
#   A. degenerate  no hub, no cache → sync exits 3, writes nothing at all
#                  (no agent-effective.json, every file byte for byte)
#   B. team adds   an MCP server (Claude + Codex), a hook, a skill, a setting →
#                  every computer gets them; agent-effective.json names the
#                  source of each row; `status` prints the version
#   C. local wins  a server this login wrote under the team's name, and a team
#                  item edited here, keep this login's value on every version
#   D. > default   a team value replaces an untouched fleet default; the
#                  rollback (a PUT of v1's body) puts the default back
#   E. dropped     an item the team stops handing out is taken back; a Codex
#                  key goes back to the fleet default
#   F. team: off   agent-overrides.json `team: off` takes back what the team
#                  wrote and adds nothing new
#   G. secrets     a bundle carrying a credential is refused: exit 2, the
#                  cached version kept, nothing applied
#   H. again       a second sync on the same version changes no file
#   I. override    an item listed in agent-overrides.json is never written
#   J. install     fleet-install-apply.sh runs the team step after the agents
#                  pass; the client package carries the script
#   K. fetch       over HTTP (a loopback stub of /v1/fleet/team-bundle): the
#                  node token from node.env as Bearer, If-None-Match → 304 is
#                  "unchanged", a 401 without a certificate is exit 1 and the
#                  cache stays; the personal read answered 404 is no layer
#
# The personal layer (issue #1857, EPIC #1855 C2): local > personal > team >
# default, the person's answer through FLEET_PERSON_BUNDLE_CMD:
#   L. degenerate  no personal layer (no answer / version 0 / 404) → every output
#                  — sync, status, session, expected, agent-effective.json, the
#                  files — byte for byte what it is with no personal read at all
#   M. layers      personal over team (MCP, setting, Codex key, hook, skill);
#                  a personal hook lands wrapped, under claude.hooks.personal (#1858);
#                  this login's own value over the personal layer's
#   N. rollback    a personal version that drops items takes back only what the
#                  personal layer wrote and nobody touched: a team item returns
#                  to the team's value, a hand-edited one stays
#   O. off         agent-overrides.json `personal: off` leaves the layer
#   P. session     `session claude` src names personal:vN; its fingerprint moves
#                  with the personal layer's values; `expected` with it; its
#                  `say` line is `status --short`'s person-facing line verbatim
#                  (团队 vN · 个人 vM · 本机独有 K 项 — EPIC #1855 C6; L pins that
#                  with no personal layer neither changes)
#   R. hint        a 本机 item new since the last launch → ONE `hint promote <item>`
#                  line from `session` (#1863); the next launch none; a sync keeps
#                  `hinted`; FLEET_PROMOTE_HINT=0 none (L pins: no personal layer,
#                  no hint and no field)
#   S. codex      the same personal hooks reach a Codex session (#1864): `session
#                  codex` hands `c hooks.<Event>=` = the fleet's own groups +
#                  the wrapped personal ones; an event / tool Codex lacks → note
#   Q. refused     a credential in the personal layer is refused (the cache is
#                  kept); hook_scripts is personal-only
#
# The hub's push (issue #1899, EPIC #1906 C6) — the node agent runs
# `sync --hub-version N` when the hub says the team is at vN:
#   A. degenerate  never fetched, never pushed → `status --team` prints nothing,
#                  exit 3 (the doctor shows no team row); no team-push.json
#   T. push        sync --hub-version N applies vN in the one run, records
#                  team-push.json, refreshes global/agent-cfg.expected; the
#                  doctor row reads 入口 vN · 本机 vN · 拉到 <UTC>; a failed sync
#                  is recorded (rc) and, past FLEET_TEAM_PUSH_WARN_SECS, WARNs
#                  尚未生效; the retry clears it
#
# A person's roles and rules, kept on the hub (issue #2784, EPIC #2781 C3):
#   U. roles       a personal layer carrying `roles` / `rules` is taken (the
#                  hub's allow-list, kept in step; no role name is checked since
#                  the role programs left, issue #4340): a role over 16 KiB, a literal token in an overlay are refused, the cache
#                  kept; `person` reads the layer alone (no team read, no apply)
#                  and records person-sync.json; `sync --person-version N` records
#                  the push; `status --roles` is the doctor's row — 入口 vN · 本机 vN
#                  · 拉到 …, WARN past a day or behind the push; no layer → no
#                  file, no row; two logins on one machine (two FLEET_CONF_DIRs)
#                  each keep their own person's
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
real="$BIN/fleet-agent-team.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
T="$REPO/bin/fleet-agent-team.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-agent-team-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
st_tally
PY="$(command -v python3)"
# The personal layer's MCP commands exist on this "machine": a server whose command
# is not here is left out of the layer (issue #1862, fleet-break-it personal-mcp-*).
mkdir -p "$WORK/stubs"
for c in me-shared me-shared@3 p-mcp p-mcp@2 p-new; do printf '#!/bin/sh\n' > "$WORK/stubs/$c"; chmod +x "$WORK/stubs/$c"; done
PATH="$WORK/stubs:$PATH"

H="$WORK/home"
CONF="$H/.config/claude-fleet"
mkdir -p "$H/.claude" "$H/.codex" "$CONF"
CTX7=$("$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["mcpServers"]["context7"]))' \
         "$REPO/conf/agent-defaults/claude/mcp.default.json")
cat > "$H/.claude.json" <<EOF
{"numStartups": 1, "mcpServers": {"context7": $CTX7, "mine": {"command": "my-mcp", "args": ["--mine"]}}}
EOF
echo '{"theme": "dark"}' > "$H/.claude/settings.json"
cat > "$H/.codex/config.toml" <<'EOF'
# this login's own
approval_policy = "never"
model_reasoning_effort = "xhigh"

[mcp_servers.mine]
command = "my-mcp"
EOF

# team <args…> — the script, sandboxed; the hub's answer is $WORK/resp.json
team() {
  env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" CODEX_HOME="$H/.codex" \
    ${SEAM:+FLEET_TEAM_BUNDLE_CMD="$SEAM"} ${PSEAM:+FLEET_PERSON_BUNDLE_CMD="$PSEAM"} \
    ${PHINT:+FLEET_PROMOTE_HINT="$PHINT"} ${FLEET_PERSONAL:+FLEET_PERSONAL="$FLEET_PERSONAL"} "$PY" "$T" "$@" --root "$REPO" \
    --claude-config "$H/.claude.json" --claude-settings "$H/.claude/settings.json" \
    --claude-skills "$H/.claude/skills" --codex-home "$H/.codex" 2>&1
}
status() { env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" "$PY" "$T" status "$@" 2>&1; }
PSEAM=''
presp() { printf '%s\n' "$1" > "$WORK/presp.json"; }
resp() { printf '%s\n' "$1" > "$WORK/resp.json"; }
snap() {
  # ./Library/Caches: macOS's python writes its .pyc cache under $HOME on first run
  (cd "$H" && find . -type f ! -path './Library/Caches/*' 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done)
}
j() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))" "$@" 2>/dev/null; }
src() { j "$CONF/agent-effective.json" "d['items'].get('$1', {}).get('source')"; }

# ── A — no hub, no cache: nothing ────────────────────────────────────────────
before=$(snap)
SEAM='' out=$(team sync); rc=$?
[ "$rc" = 3 ] && [ ! -e "$CONF/agent-effective.json" ] && [ "$(snap)" = "$before" ] \
  && st_ok_all "A no hub → exit 3, no file written ($out)" || st_miss "A rc=$rc out=$out"
out=$(SEAM='' team apply); [ ! -e "$CONF/agent-effective.json" ] && [ "$(snap)" = "$before" ] \
  && st_ok_all "A apply with no layer writes nothing" || st_miss "A apply wrote: $out"
out=$(status --team); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && [ ! -e "$CONF/team-push.json" ] \
  && st_ok_all "A no team layer → status --team prints nothing, exit 3 (no doctor row)" || st_miss "A status --team rc=$rc: $out"

SEAM="cat $WORK/resp.json"
# ── B — the team adds ─────────────────────────────────────────────────────────
resp '{"version":1,"prev":0,"bundle":{
  "mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]},"mine":{"command":"team-mcp"}},
  "hooks":{"Stop":[{"command":"echo team-stop","timeout":5}]},
  "skills":{"team-notes":"---\nname: team-notes\n---\n# notes\n"},
  "claude_settings":{"includeCoAuthoredBy":false},
  "codex_config":{"sandbox_mode":"workspace-write"}}}'
out=$(team sync); rc=$?
[ "$rc" = 0 ] || st_miss "B sync rc=$rc: $out"
[ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args'][-1]")" = '"--read-only"' ] \
  && grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" \
  && st_ok_all "B the team's MCP server reached Claude and Codex" || st_miss "B docs-ro missing: $out"
[ "$(j "$H/.claude/settings.json" "d['hooks']['Stop'][0]['hooks'][0]['command']")" = '"echo team-stop"' ] \
  && [ "$(j "$H/.claude/settings.json" "d['includeCoAuthoredBy']")" = false ] \
  && [ "$(j "$H/.claude/settings.json" "d['theme']")" = '"dark"' ] \
  && st_ok_all "B hook + setting landed in settings.json, the login's keys kept" || st_miss "B settings: $(cat "$H/.claude/settings.json")"
[ -f "$H/.claude/skills/team-notes/SKILL.md" ] && [ -f "$H/.codex/skills/team-notes/SKILL.md" ] \
  && st_ok_all "B the team's skill reached both agents" || st_miss "B skill missing"
grep -q '^sandbox_mode = "workspace-write"' "$H/.codex/config.toml" && head -1 "$H/.codex/config.toml" | grep -q '^# this login' \
  && st_ok_all "B a Codex key the login lacked is set; its own lines stay" || st_miss "B codex: $(cat "$H/.codex/config.toml")"
[ "$(src claude.mcp.docs-ro)" = '"team"' ] && [ "$(src claude.mcp.context7)" = '"default"' ] \
  && [ "$(src claude.mcp.mine)" = '"local"' ] && [ "$(src codex.mcp.docs-ro)" = '"team"' ] \
  && [ "$(j "$CONF/agent-effective.json" "d['team']['version']")" = 1 ] \
  && st_ok_all "B agent-effective.json: docs-ro team · context7 default · mine local, v1" || st_miss "B effective: $(cat "$CONF/agent-effective.json")"
case "$(status --short)" in "team v1") st_ok_all "B status: team v1" ;; *) st_miss "B status: $(status --short)" ;; esac

# ── C — local wins ────────────────────────────────────────────────────────────
[ "$(j "$H/.claude.json" "d['mcpServers']['mine']['command']")" = '"my-mcp"' ] \
  && grep -A1 '^\[mcp_servers.mine\]' "$H/.codex/config.toml" | grep -q 'my-mcp' \
  && grep -q '^model_reasoning_effort = "xhigh"' "$H/.codex/config.toml" \
  && st_ok_all "C a name this login already had keeps its value (Claude + Codex)" || st_miss "C mine overwritten"
"$PY" - "$H/.claude.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"]["docs-ro"]["args"] = ["my", "own"]; json.dump(d, open(p, "w"))
PY
resp '{"version":2,"prev":1,"bundle":{
  "mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp@2","--read-only"]},"mine":{"command":"team-mcp"}},
  "hooks":{"Stop":[{"command":"echo team-stop","timeout":5}]},
  "skills":{"team-notes":"---\nname: team-notes\n---\n# notes v2\n"},
  "claude_settings":{"includeCoAuthoredBy":false},
  "codex_config":{"sandbox_mode":"workspace-write"}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args']")" = '["my", "own"]' ] && [ "$(src claude.mcp.docs-ro)" = '"local"' ] \
  && grep -A2 '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" | grep -q 'docs-mcp@2' \
  && grep -q 'notes v2' "$H/.claude/skills/team-notes/SKILL.md" \
  && st_ok_all "C an item edited here stays this login's on v2; untouched team items follow v2" || st_miss "C v2: $out"

# ── D — team over an untouched default, then the rollback ─────────────────────
resp '{"version":3,"prev":2,"bundle":{"mcp":{"context7":{"command":"npx","args":["-y","@team/context7"]}},
  "codex_config":{"model_reasoning_effort":"low"}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['context7']['args'][-1]")" = '"@team/context7"' ] && [ "$(src claude.mcp.context7)" = '"team"' ] \
  && st_ok_all "D the team's context7 replaced the untouched fleet default" || st_miss "D context7: $out"
grep -q '^model_reasoning_effort = "xhigh"' "$H/.codex/config.toml" && [ "$(src codex.model_reasoning_effort)" = '"local"' ] \
  && st_ok_all "D a Codex key this login set itself stays (xhigh), source local" || st_miss "D codex key: $(cat "$H/.codex/config.toml")"
# ── E — what the team dropped (v3 has no docs-ro / hook / skill / setting) ────
[ ! -e "$H/.claude/skills/team-notes" ] && [ ! -e "$H/.codex/skills/team-notes" ] \
  && [ "$(j "$H/.claude/settings.json" "'hooks' in d or 'includeCoAuthoredBy' in d")" = false ] \
  && ! grep -q '^sandbox_mode = "workspace-write"' "$H/.codex/config.toml" \
  && ! grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args']")" = '["my", "own"]' ] \
  && st_ok_all "E dropped items taken back (skill, hook, setting, Codex key + server); the one edited here stays" \
  || st_miss "E: $out // $(cat "$H/.codex/config.toml")"
# the rollback = v1's body again, as v4
resp '{"version":4,"prev":3,"bundle":{"mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['context7']")" = "$("$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$CTX7")" ] \
  && [ "$(src claude.mcp.context7)" = '"default"' ] \
  && st_ok_all "D rollback: context7 is the fleet default again" || st_miss "D rollback: $out"
grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" && st_ok_all "E a re-added team server returns where it was not this login's" || st_miss "E codex docs-ro back"

# ── H — again: nothing moves ──────────────────────────────────────────────────
before=$(snap); out=$(team sync); out2=$(team apply)
[ "$(snap | grep -v agent-effective.json)" = "$(printf '%s\n' "$before" | grep -v agent-effective.json)" ] \
  && printf '%s\n' "$out2" | grep -q 'changed 0 item' && st_ok_all "H a second sync / apply changes no file" || st_miss "H: $out2"

# ── I — an override shields one item ──────────────────────────────────────────
echo '["claude.mcp.extra"]' > "$CONF/agent-overrides.json"
resp '{"version":5,"prev":4,"bundle":{"mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]},"extra":{"command":"x"}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "'extra' in d['mcpServers']")" = false ] && grep -q '^\[mcp_servers.extra\]' "$H/.codex/config.toml" \
  && st_ok_all "I claude.mcp.extra listed in agent-overrides.json is not written (Codex still gets it)" || st_miss "I: $out"

# ── F — team: off ──────────────────────────────────────────────────────────────
echo '{"team": "off"}' > "$CONF/agent-overrides.json"
out=$(team sync)
! grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" && ! grep -q '^\[mcp_servers.extra\]' "$H/.codex/config.toml" \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args']")" = '["my", "own"]' ] \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['mine']['command']")" = '"my-mcp"' ] \
  && st_ok_all "F team: off takes back what the team wrote; this login's own stay" || st_miss "F: $out"
case "$(status --short)" in "team off") st_ok_all "F status: team off" ;; *) st_miss "F status: $(status --short)" ;; esac
resp '{"version":6,"prev":5,"bundle":{"mcp":{"brand-new":{"command":"x"}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "'brand-new' in d['mcpServers']")" = false ] && st_ok_all "F team: off adds nothing new" || st_miss "F added: $out"
rm -f "$CONF/agent-overrides.json"
out=$(team sync)
[ "$(j "$H/.claude.json" "'brand-new' in d['mcpServers']")" = true ] && st_ok_all "F back on: v6 applies" || st_miss "F back on: $out"

# ── G — a credential (or fleet-infra, #3586) is refused ───────────────────────────────────────────────
for b in '{"mcp":{"gh":{"command":"x","env":{"GITHUB_TOKEN":"abc123"}}}}' \
         '{"mcp":{"gh":{"command":"x","args":["ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}}' \
         '{"claude_settings":{"apiKeyHelper":"/bin/echo"}}' '{"accounts":{}}' \
         '{"claude_settings":{"enabledPlugins":{"fleet-infra@claude-fleet":true}}}'; do
  before=$(snap)
  resp "{\"version\":7,\"prev\":6,\"bundle\":$b}"
  out=$(team sync); rc=$?
  [ "$rc" = 2 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 6 ] && [ "$(snap)" = "$before" ] \
    && st_ok_all "G refused, v6 kept, nothing written: $(printf '%s' "$out" | head -1 | cut -c1-90)" || st_miss "G rc=$rc $out"
done
resp '{"version":7,"prev":6,"bundle":{"mcp":{"gh":{"command":"x","env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}}}}'
out=$(team sync); [ "$?" = 0 ] && [ "$(src claude.mcp.gh)" = '"team"' ] && st_ok_all "G a \${VAR} reference is not a credential" || st_miss "G ref: $out"

# ── J — the install's team step ──────────────────────────────────────────────
grep -q 'fleet-agent-team.py' "$REPO/bin/fleet-install-apply.sh" && st_ok_all "J fleet-install-apply.sh runs the team step" || st_miss "J no team step in install-apply"
grep -q 'fleet-agent-team.py' "$REPO/conf/agent-bundle.manifest" && st_ok_all "J the client package carries fleet-agent-team.py" || st_miss "J not in agent-bundle.manifest"

# ── K — the HTTP fetch ─────────────────────────────────────────────────────────
cat > "$WORK/stub.py" <<'PY2'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write("%s %s %s\n" % (self.path, self.headers.get("Authorization"), self.headers.get("If-None-Match")))
        if self.path.startswith("/v1/fleet/person-bundle"):
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"error":"no person for this login"}'); return
        if self.headers.get("Authorization") != "Bearer node-tok":
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":"no"}'); return
        if self.headers.get("If-None-Match") == '"team-v9"':
            self.send_response(304); self.end_headers(); return
        b = json.dumps({"version": 9, "prev": 8, "bundle": {"mcp": {"docs-ro": {"command": "npx"}}}}).encode()
        self.send_response(200); self.send_header("ETag", '"team-v9"'); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
import os, time
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(sys.argv[1] + ".tmp", sys.argv[1])   # listening before the port is readable
s.timeout = 0.5
end = time.time() + 120
while time.time() < end:
    s.handle_request()
PY2
"$PY" "$WORK/stub.py" "$WORK/port" "$WORK/req.log" &
STUB=$!
# a slow runner (macOS CI) takes seconds to start python: wait up to 30s
i=0; while [ ! -s "$WORK/port" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
PORT=$(cat "$WORK/port" 2>/dev/null)
[ -n "$PORT" ] || st_miss "K the loopback stub never started"
printf 'CCQUOTA_TOKEN=node-tok\nCCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$PORT" > "$CONF/node.env"
out=$(SEAM='' team sync); rc=$?
[ "$rc" = 0 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 9 ] && grep -q 'Bearer node-tok' "$WORK/req.log" \
  && [ "$(j "$CONF/agent-effective.json" "d['team']['version']")" = 9 ] \
  && st_ok_all "K fetched v9 with the node token and composed it" || st_miss "K fetch rc=$rc: $out"
grep -q '^/v1/fleet/person-bundle Bearer node-tok' "$WORK/req.log" && [ ! -e "$CONF/person-bundle.json" ] \
  && ! printf '%s' "$out" | grep -q '^personal' \
  && [ "$(j "$CONF/agent-effective.json" "'personal' in d or 'personal_version' in d or 'hinted' in d or 'local_seen' in d")" = false ] \
  && st_ok_all "K the personal read answered 404 (no person) → no cache, no line, no record" || st_miss "K person 404: $out"
out=$(SEAM='' team fetch); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'unchanged' && grep '^/v1/fleet/team-bundle' "$WORK/req.log" | tail -1 | grep -q '"team-v9"' \
  && st_ok_all "K If-None-Match the cached version → 304, unchanged" || st_miss "K 304: rc=$rc $out"
printf 'CCQUOTA_TOKEN=wrong\nCCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$PORT" > "$CONF/node.env"
out=$(SEAM='' team sync); rc=$?
[ "$rc" = 1 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 9 ] \
  && st_ok_all "K a refused token (no certificate) is exit 1; v9 stays cached" || st_miss "K 401: rc=$rc $out"
kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null
rm -f "$CONF/node.env"

# ── L — no personal layer: byte for byte ──────────────────────────────────────
SEAM="cat $WORK/resp.json"
resp '{"version":10,"prev":9,"bundle":{"mcp":{"shared":{"command":"team-shared"}},
  "claude_settings":{"includeCoAuthoredBy":false},"codex_config":{"sandbox_mode":"workspace-write"}}}'
team sync >/dev/null
# everything a reader sees, minus agent-effective.json's applied clock
picture() {
  team sync --force; team session claude; team session codex; team expected; status; status --short
  j "$CONF/agent-effective.json" "{k: v for k, v in d.items() if k != 'team'}"
  j "$CONF/agent-effective.json" "{k: v for k, v in d['team'].items() if k != 'applied'}"
  snap | grep -v -e agent-effective.json -e agent-cfg
}
base=$(PSEAM='' picture)
for ps in 'printf ""' "printf '%s' '{\"version\":0,\"bundle\":{}}'"; do
  got=$(PSEAM="$ps" picture)
  [ "$got" = "$base" ] && [ ! -e "$CONF/person-bundle.json" ] \
    && st_ok_all "L no personal layer ($ps) → every output byte for byte as without one" \
    || st_miss "L degenerate differs ($ps): $(diff <(printf '%s\n' "$base") <(printf '%s\n' "$got") | head -8)"
done

# ── M — personal over team, local over personal ───────────────────────────────
PSEAM="cat $WORK/presp.json"
presp '{"version":1,"prev":0,"bundle":{
  "mcp":{"shared":{"command":"me-shared"},"pmine":{"command":"p-mcp"}},
  "hooks":{"Stop":[{"command":"echo me-stop"}]},
  "skills":{"me-notes":"---\nname: me-notes\n---\n# mine\n"},
  "claude_settings":{"includeCoAuthoredBy":true},
  "codex_config":{"sandbox_mode":"read-only"}}}'
out=$(team sync); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^personal: v1 (new)' || st_miss "M sync rc=$rc: $out"
[ "$(j "$H/.claude.json" "d['mcpServers']['shared']['command']")" = '"me-shared"' ] && [ "$(src claude.mcp.shared)" = '"personal"' ] \
  && [ "$(src claude.mcp.pmine)" = '"personal"' ] \
  && grep -A1 '^\[mcp_servers.shared\]' "$H/.codex/config.toml" | grep -q me-shared && [ "$(src codex.mcp.shared)" = '"personal"' ] \
  && st_ok_all "M a personal MCP server wins over the team's of the same name (Claude + Codex)" || st_miss "M mcp: $out"
[ "$(j "$H/.claude/settings.json" "d['includeCoAuthoredBy']")" = true ] && [ "$(src claude.settings.includeCoAuthoredBy)" = '"personal"' ] \
  && grep -q '^sandbox_mode = "read-only"' "$H/.codex/config.toml" && [ "$(src codex.sandbox_mode)" = '"personal"' ] \
  && st_ok_all "M a personal setting / Codex key wins over the team's" || st_miss "M keys: $(cat "$H/.codex/config.toml")"
[ "$(j "$H/.claude/settings.json" "[h['command'] for g in d['hooks']['Stop'] for h in g['hooks']]")" = \
    "[\"sh \\\"\$HOME/.claude/fleet/bin/fleet-hook-personal.sh\\\" Stop -- 'echo me-stop'\"]" ] \
  && [ "$(j "$CONF/agent-effective.json" "[k for k in d['items'] if k.startswith('claude.hooks.')]")" = \
    "[\"claude.hooks.personal.Stop.$("$PY" -c 'import hashlib;print(hashlib.sha256(b"echo me-stop").hexdigest()[:10])')\"]" ] \
  && [ -f "$H/.claude/skills/me-notes/SKILL.md" ] && [ "$(src claude.skills.me-notes)" = '"personal"' ] \
  && st_ok_all "M a personal hook + skill land, source personal" || st_miss "M hook/skill: $(cat "$H/.claude/settings.json")"
[ "$(j "$CONF/agent-effective.json" "[d['personal']['version'], d['personal']['state'], d['personal_version']]")" = '[1, "on", 1]' ] \
  && st_ok_all "M agent-effective.json records personal v1" || st_miss "M record: $(cat "$CONF/agent-effective.json")"
case "$(status --short)" in "团队 v10 · 个人 v1 · 本机独有 "[0-9]*" 项（fleet config promote 可带走）")
  st_ok_all "M status --short: the person-facing line (团队 v10 · 个人 v1 · 本机独有 N 项)" ;; *) st_miss "M status: $(status --short)" ;; esac
"$PY" - "$H/.claude.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"]["pmine"]["command"] = "by-hand"; json.dump(d, open(p, "w"))
PY
presp '{"version":2,"prev":1,"bundle":{
  "mcp":{"shared":{"command":"me-shared"},"pmine":{"command":"p-mcp@2"}},
  "hooks":{"Stop":[{"command":"echo me-stop"}]},
  "skills":{"me-notes":"---\nname: me-notes\n---\n# mine\n"},
  "claude_settings":{"includeCoAuthoredBy":true},
  "codex_config":{"sandbox_mode":"read-only"}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['pmine']['command']")" = '"by-hand"' ] && [ "$(src claude.mcp.pmine)" = '"local"' ] \
  && printf '%s' "$out" | grep -q "own .*claude.mcp.pmine — this login's value wins over the personal layer's" \
  && grep -A1 '^\[mcp_servers.pmine\]' "$H/.codex/config.toml" | grep -q 'p-mcp@2' \
  && st_ok_all "M this login's hand edit wins over the personal layer's v2; untouched items follow v2" || st_miss "M local: $out"

# ── P — the session (taken here, before the rollback) ─────────────────────────
s1=$(team session claude)
printf '%s\n' "$s1" | grep -q $'^src\tdefault:[0-9a-f]* team:v10 personal:v2 local:' \
  && st_ok_all "P session src names personal:v2" || st_miss "P src: $s1"
printf '%s\n' "$s1" | grep -qxF "$(printf 'say\t%s' "$(status --short)")" \
  && st_ok_all "P session's say line is status --short's, verbatim (EPIC #1855 C6)" || st_miss "P say: $s1 // $(status --short)"
presp '{"version":3,"prev":2,"bundle":{
  "mcp":{"shared":{"command":"me-shared@3"},"pmine":{"command":"p-mcp@2"}},
  "hooks":{"Stop":[{"command":"echo me-stop"}]},
  "skills":{"me-notes":"---\nname: me-notes\n---\n# mine\n"},
  "claude_settings":{"includeCoAuthoredBy":true},
  "codex_config":{"sandbox_mode":"read-only"}}}'
team sync >/dev/null
s2=$(team session claude)
[ "$(printf '%s\n' "$s1" | grep '^fp')" != "$(printf '%s\n' "$s2" | grep '^fp')" ] \
  && printf '%s\n' "$s2" | grep -q 'personal:v3' \
  && st_ok_all "P a new personal version moves the session fingerprint" || st_miss "P fp: $s1 // $s2"
fp3=$(team session claude | sed -n 's/^fp	//p')
grep -q "^claude $fp3 .*personal:v3" "$CONF/global/agent-cfg.expected" \
  && st_ok_all "P the cached expected fingerprint carries the personal layer" || st_miss "P expected: $(cat "$CONF/global/agent-cfg.expected")"

# ── R — a new 本机 item is said once (issue #1863) ─────────────────────────────
hints() { team session claude | grep $'^hint\t'; }
[ -z "$(hints)" ] && [ "$(j "$CONF/agent-effective.json" "'claude.mcp.mine' in d['local_seen']")" = true ] \
  && st_ok_all "R what was always here is recorded, never hinted" || st_miss "R baseline: $(hints) // $(cat "$CONF/agent-effective.json")"
addmcp() {
  "$PY" - "$H/.claude.json" "$1" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"][sys.argv[2]] = {"command": "here-only"}; json.dump(d, open(p, "w"))
PY2
}
addmcp fresh
[ "$(hints)" = "$(printf 'hint\tpromote claude.mcp.fresh')" ] \
  && st_ok_all "R a new local MCP → one hint line (hint promote claude.mcp.fresh)" || st_miss "R new: $(team session claude)"
[ -z "$(hints)" ] && st_ok_all "R the next launch says nothing" || st_miss "R again: $(hints)"
team sync --force >/dev/null
[ -z "$(hints)" ] && [ "$(j "$CONF/agent-effective.json" "d['hinted']")" = '["claude.mcp.fresh"]' ] \
  && st_ok_all "R a sync keeps what was said (hinted survives apply)" || st_miss "R after sync: $(hints)"
addmcp quiet
[ -z "$(PHINT=0 hints)" ] && st_ok_all "R FLEET_PROMOTE_HINT=0 → no hint" || st_miss "R off: $(PHINT=0 hints)"
# both launchers hand the composer's lines to the one shared step (T620)
grep -q '^ *hint) .*本机新加了' "$REPO/bin/fleet-launch-lib.sh" && st_ok_all "R fleet-launch-lib.sh prints the hint on its start line" || st_miss "R fleet-launch-lib.sh has no hint) arm"
for f in fleet-claude.sh fleet-codex.sh; do
  grep -q '^fleet_launch_cfg ' "$REPO/bin/$f" && st_ok_all "R $f runs it" || st_miss "R $f has no hint) arm"
done
"$PY" - "$H/.claude.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); [d["mcpServers"].pop(k) for k in ("fresh", "quiet")]; json.dump(d, open(p, "w"))
PY2

# ── N — the personal rollback takes back only its own ─────────────────────────
presp '{"version":4,"prev":3,"bundle":{"mcp":{"pmine":{"command":"p-mcp@2"}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['shared']['command']")" = '"team-shared"' ] && [ "$(src claude.mcp.shared)" = '"team"' ] \
  && [ "$(j "$H/.claude/settings.json" "d['includeCoAuthoredBy']")" = false ] && [ "$(src claude.settings.includeCoAuthoredBy)" = '"team"' ] \
  && grep -q '^sandbox_mode = "workspace-write"' "$H/.codex/config.toml" \
  && st_ok_all "N items the team also hands go back to the team's value" || st_miss "N team back: $out"
[ ! -e "$H/.claude/skills/me-notes" ] && [ "$(j "$H/.claude/settings.json" "'hooks' in d")" = false ] \
  && printf '%s' "$out" | grep -q 'drop .*claude.skills.me-notes (the personal layer no longer hands it out)' \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['pmine']['command']")" = '"by-hand"' ] \
  && st_ok_all "N personal-only items are dropped; the hand-edited one stays" || st_miss "N dropped: $out"

# ── O — personal: off ──────────────────────────────────────────────────────────
presp '{"version":5,"prev":4,"bundle":{"mcp":{"pnew":{"command":"p-new"},"shared":{"command":"me-shared"}}}}'
team sync >/dev/null
[ "$(src claude.mcp.pnew)" = '"personal"' ] || st_miss "O pnew not applied"
echo '{"personal": "off"}' > "$CONF/agent-overrides.json"
out=$(team sync)
[ "$(j "$H/.claude.json" "'pnew' in d['mcpServers']")" = false ] \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['shared']['command']")" = '"team-shared"' ] \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['pmine']['command']")" = '"by-hand"' ] \
  && st_ok_all "O personal: off takes back what the personal layer wrote; the team's and this login's stay" || st_miss "O: $out"
case "$(status --short)" in "团队 v10 · 个人 已关 · 本机独有 "*) st_ok_all "O status: 个人 已关" ;; *) st_miss "O status: $(status --short)" ;; esac
team session claude | grep -q 'personal:off' && st_ok_all "O session src: personal:off" || st_miss "O src"
rm -f "$CONF/agent-overrides.json"
out=$(team sync)
[ "$(src claude.mcp.pnew)" = '"personal"' ] && st_ok_all "O back on: v5 applies" || st_miss "O back on: $out"

# ── Q — refused ────────────────────────────────────────────────────────────────
before=$(snap)
presp '{"version":6,"prev":5,"bundle":{"mcp":{"gh":{"command":"x","env":{"GITHUB_TOKEN":"abc123"}}}}}'
out=$(team sync)
printf '%s' "$out" | grep -q '^personal: refused v6: .*GITHUB_TOKEN looks like a credential — the personal layer' \
  && [ "$(j "$CONF/person-bundle.json" "d['version']")" = 5 ] && [ "$(snap | grep -v -e agent- -e person-sync)" = "$(printf '%s\n' "$before" | grep -v -e agent- -e person-sync)" ] \
  && st_ok_all "Q a credential in the personal layer is refused; v5 kept, nothing written" || st_miss "Q: $out"
presp '{"version":6,"prev":5,"bundle":{"hook_scripts":{"x.sh":"echo hi"},"mcp":{"pnew":{"command":"p-new"}}}}'
out=$(team sync)
printf '%s' "$out" | grep -q '^personal: v6 (new)' && st_ok_all "Q hook_scripts is accepted in the personal layer" || st_miss "Q hook_scripts: $out"
resp '{"version":11,"prev":10,"bundle":{"hook_scripts":{"x.sh":"echo hi"}}}'
out=$(team sync); [ "$?" = 2 ] && st_ok_all "Q hook_scripts is refused in the team layer" || st_miss "Q team hook_scripts: $out"

# ── S — the same personal hooks in a Codex session (issue #1864) ──────────────
presp '{"version":7,"prev":6,"bundle":{
  "hooks":{"PreToolUse":[{"matcher":"Bash","command":"echo me-pre"},{"matcher":"Edit|Write","command":"echo me-edit"},
                         {"matcher":"Artifact","command":"echo me-art"}],
           "Stop":[{"command":"echo me-stop","timeout":5}],
           "Notification":[{"command":"echo me-note"}]}}}'
team sync >/dev/null
sc=$(team session codex)
emit=$("$REPO/bin/fleet-hooks-emit.sh" --target codex --root "$REPO")
fpre=$(printf '%s\n' "$emit" | sed -n 's/^PreToolUse	\[\(.*\)\]$/\1/p')
fstop=$(printf '%s\n' "$emit" | sed -n 's/^Stop	\[\(.*\)\]$/\1/p')
wrap() { printf 'sh \\"$HOME/.claude/fleet/bin/fleet-hook-personal.sh\\" %s -- '"'"'%s'"'" "$1" "$2"; }
pre=$(printf '%s\n' "$sc" | sed -n 's/^c	hooks\.PreToolUse=//p')
[ -n "$fpre" ] && [ "$pre" = "[$fpre,{matcher=\"Bash\",hooks=[{type=\"command\",command=\"$(wrap PreToolUse 'echo me-pre')\"}]},{matcher=\"apply_patch\",hooks=[{type=\"command\",command=\"$(wrap PreToolUse 'echo me-edit')\"}]}]" ] \
  && st_ok_all "S session codex: c hooks.PreToolUse = the fleet's own groups + the personal hooks (Edit|Write → apply_patch)" \
  || st_miss "S PreToolUse: $pre"
stop=$(printf '%s\n' "$sc" | sed -n 's/^c	hooks\.Stop=//p')
[ -n "$fstop" ] && [ "$stop" = "[$fstop,{hooks=[{type=\"command\",command=\"$(wrap Stop 'echo me-stop')\"}]}]" ] \
  && st_ok_all "S session codex: c hooks.Stop carries the fleet's Stop + the personal one" || st_miss "S Stop: $stop"
[ "$(j "$H/.claude/settings.json" "[h['command'] for g in d['hooks']['Stop'] for h in g['hooks']]")" = \
    "[\"sh \\\"\$HOME/.claude/fleet/bin/fleet-hook-personal.sh\\\" Stop -- 'echo me-stop'\"]" ] \
  && st_ok_all "S the same wrapped command as Claude's settings.json" || st_miss "S claude: $(cat "$H/.claude/settings.json")"
printf '%s\n' "$sc" | grep -q '^note	个人自动规则 Notification「echo me-note」：Codex 没有这个事件' \
  && printf '%s\n' "$sc" | grep -q '^note	个人自动规则 PreToolUse「echo me-art」：Codex 没有工具 Artifact' \
  && [ "$(printf '%s\n' "$sc" | grep -c '^c	hooks\.')" = 2 ] \
  && st_ok_all "S an event / tool Codex has not got: a note, no hook" || st_miss "S notes: $sc"
team session codex --lock enforce | grep -q '^lock	codex.hooks.personal' \
  && st_miss "S a personal hook inherited the codex.hooks lock" || st_ok_all "S codex.hooks.personal is outside the codex.hooks lock"
sp=$(FLEET_PERSONAL=0 team session codex)
! printf '%s\n' "$sp" | grep -q '^c	hooks\.' && st_ok_all "S FLEET_PERSONAL=0: no personal hook in the Codex session" || st_miss "S off: $sp"

# ── L again — the personal layer goes away (404): everything it wrote goes ────
resp '{"version":10,"prev":9,"bundle":{"mcp":{"shared":{"command":"team-shared"}},
  "claude_settings":{"includeCoAuthoredBy":false},"codex_config":{"sandbox_mode":"workspace-write"}}}'
out=$(PSEAM='printf ""' team sync)
[ ! -e "$CONF/person-bundle.json" ] && [ "$(j "$H/.claude.json" "'pnew' in d['mcpServers']")" = false ] \
  && [ "$(j "$CONF/agent-effective.json" "'personal' in d or 'personal_version' in d or 'hinted' in d or 'local_seen' in d")" = false ] \
  && [ "$(status --short)" = "team v10" ] && ! team session claude | grep -q personal \
  && st_ok_all "L the person's layer gone (404) → taken back, no personal anywhere" || st_miss "L gone: $out"

# ── T — the hub's push (#1899): one run applies it, records it, moves expected ──
team expected --write >/dev/null
exp0=$(cat "$CONF/global/agent-cfg.expected" 2>/dev/null)
resp '{"version":11,"prev":10,"bundle":{"mcp":{"shared":{"command":"team-shared"}},
  "claude_settings":{"includeCoAuthoredBy":false},"codex_config":{"sandbox_mode":"read-only"}}}'
out=$(PSEAM='printf ""' team sync --hub-version 11); rc=$?
[ "$rc" = 0 ] && [ "$(j "$CONF/agent-effective.json" "d['team']['version']")" = 11 ] \
  && [ "$(j "$CONF/team-push.json" "[d['hub_version'], d['rc'], d['synced'] == d['heard']]")" = '[11, 0, true]' ] \
  && st_ok_all "T push v11 → applied in the one run, team-push.json recorded" || st_miss "T push rc=$rc: $out $(cat "$CONF/team-push.json" 2>&1)"
exp1=$(cat "$CONF/global/agent-cfg.expected" 2>/dev/null)
[ -n "$exp0" ] && [ "$exp1" != "$exp0" ] && printf '%s\n' "$exp1" | grep -q '^codex [0-9a-f]\{12\} .*team:v11' \
  && st_ok_all "T the expected fingerprint moved with the push" || st_miss "T expected: before=$exp0 after=$exp1"
out=$(status --team); rc=$?
printf '%s\n' "$out" | grep -Eq '^入口 v11 · 本机 v11 · 拉到 20[0-9-]+T[0-9:]+Z$' && [ "$rc" = 0 ] \
  && st_ok_all "T doctor row: $out" || st_miss "T status --team rc=$rc: $out"
out=$(PSEAM='printf ""' SEAM='exit 7' team sync --hub-version 12); rc=$?
[ "$rc" = 1 ] && [ "$(j "$CONF/team-push.json" "[d['hub_version'], d['rc']]")" = '[12, 1]' ] \
  && st_ok_all "T a failed sync is recorded (rc 1, hub v12)" || st_miss "T failed rc=$rc: $out"
out=$(status --team); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '入口 v12 · 本机 v11 .*尚未生效' \
  && st_ok_all "T just pushed, behind: named, not yet a WARN" || st_miss "T behind rc=$rc: $out"
out=$(env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" FLEET_TEAM_PUSH_WARN_SECS=-1 "$PY" "$T" status --team 2>&1); rc=$?
[ "$rc" = 1 ] && st_ok_all "T behind past FLEET_TEAM_PUSH_WARN_SECS → exit 1 (WARN)" || st_miss "T warn rc=$rc: $out"
resp '{"version":12,"prev":11,"bundle":{"mcp":{"shared":{"command":"team-shared"}},
  "claude_settings":{"includeCoAuthoredBy":true},"codex_config":{"sandbox_mode":"read-only"}}}'
out=$(PSEAM='printf ""' team sync --hub-version 12); rc=$?
out2=$(env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" FLEET_TEAM_PUSH_WARN_SECS=-1 "$PY" "$T" status --team 2>&1); rc2=$?
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && printf '%s\n' "$out2" | grep -q '^入口 v12 · 本机 v12 · 拉到 ' \
  && st_ok_all "T the retry applies v12 and clears the WARN" || st_miss "T retry rc=$rc/$rc2: $out / $out2"

# ── U — a person's roles and rules (#2784) ────────────────────────────────────
for who in alice bob; do mkdir -p "$WORK/u-$who/h" "$WORK/u-$who/c"; done
ut() {   # ut <login> <args…> — one login's script; its person's answer is $WORK/u-<login>.json
  local who="$1"; shift
  env -i PATH="$PATH" HOME="$WORK/u-$who/h" FLEET_CONF_DIR="$WORK/u-$who/c" \
    ${USEAM:+FLEET_PERSON_BUNDLE_CMD="$USEAM"} ${UWARN:+FLEET_ROLES_WARN_SECS="$UWARN"} \
    FLEET_TEAM_BUNDLE_CMD="printf '{\"version\":0,\"bundle\":{}}'" "$PY" "$T" "$@" 2>&1
}
out=$(USEAM='printf ""' ut alice person); rc=$?
out2=$(ut alice status --roles); rc2=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$rc2" = 3 ] && [ -z "$out2" ] && [ -z "$(ls -A "$WORK/u-alice/c")" ] \
  && st_ok_all "U no personal layer → person writes nothing, status --roles no row (exit 3)" || st_miss "U degenerate rc=$rc/$rc2: $out $out2 $(ls -A "$WORK/u-alice/c")"
printf '%s\n' '{"version":4,"prev":3,"bundle":{"roles":{"steward":"---\nmodel: sonnet\n---\n","worker":{"effort":"high"}},"rules":"| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 报价, 金额 |\n"}}' > "$WORK/u-alice.json"
printf '%s\n' '{"version":2,"prev":1,"bundle":{"roles":{"orchestrator":"---\neffort: max\n---\n"}}}' > "$WORK/u-bob.json"
for who in alice bob; do USEAM="cat $WORK/u-$who.json" ut "$who" person >/dev/null; done
[ "$(j "$WORK/u-alice/c/person-bundle.json" "[d['version'], sorted(d['bundle']['roles']), '| 101 | steward |' in d['bundle']['rules']]")" = '[4, ["steward", "worker"], true]' ] \
  && [ "$(j "$WORK/u-bob/c/person-bundle.json" "[d['version'], sorted(d['bundle']['roles'])]")" = '[2, ["orchestrator"]]' ] \
  && [ "$(j "$WORK/u-alice/c/person-sync.json" "[d['rc'], d['checked'] == d['tried']]")" = '[0, true]' ] \
  && [ ! -e "$WORK/u-alice/c/agent-effective.json" ] \
  && st_ok_all "U person: roles + rules taken, each login its own person's (alice v4, bob v2), no apply" \
  || st_miss "U person: $(cat "$WORK/u-alice/c/person-bundle.json" "$WORK/u-bob/c/person-bundle.json" 2>&1 | head -5)"
out=$(ut alice status --roles); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -Eq '^入口未推送（随同步拉） · 本机 v4 · 角色 steward worker · 拉到 20[0-9-]+T[0-9:]+Z（[0-9]+ 秒前）$' \
  && st_ok_all "U doctor row: $out" || st_miss "U status --roles rc=$rc: $out"
for bad_b in '{"roles":{"worker":3}}' '{"rules":{"r1":"x"}}' '{"rules":["x"]}' \
    '{"roles":{"worker":"---\nmcpServers:\n  gh: {env: {X: ghp_abcdefghijklmnopqrstuvwxyz0123}}\n---\n"}}' \
    "{\"roles\":{\"worker\":\"$(head -c 17000 /dev/zero | tr '\0' a)\"}}"; do
  printf '{"version":5,"prev":4,"bundle":%s}\n' "$bad_b" > "$WORK/u-bad.json"
  out=$(USEAM="cat $WORK/u-bad.json" ut alice person); rc=$?
  [ "$rc" = 2 ] && [ "$(j "$WORK/u-alice/c/person-bundle.json" "d['version']")" = 4 ] \
    && st_ok_all "U refused, v4 kept: $(printf '%s' "$out" | cut -c1-80)" || st_miss "U not refused rc=$rc: $out"
done
printf '%s\n' '{"version":5,"prev":4,"bundle":{"roles":{"steward":"---\nmodel: haiku\n---\n"}}}' > "$WORK/u-alice.json"
out=$(USEAM='exit 7' ut alice sync --person-version 5); rc=$?
out2=$(UWARN=999999 ut alice status --roles); rc2=$?
[ "$(j "$WORK/u-alice/c/person-sync.json" "[d['hub_version'], d['rc']]")" = '[5, 1]' ] && [ "$rc2" = 0 ] \
  && printf '%s\n' "$out2" | grep -q '^入口 v5 · 本机 v4 .*入口已推 v5，本机还没拿到' \
  && st_ok_all "U a push whose read failed: recorded, named, not yet a WARN" || st_miss "U push failed rc=$rc/$rc2: $out / $out2"
out=$(USEAM="cat $WORK/u-alice.json" ut alice sync --person-version 5); rc=$?
out2=$(ut alice status --roles); rc2=$?
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && printf '%s\n' "$out2" | grep -q '^入口 v5 · 本机 v5 · 角色 steward · 拉到 ' \
  && [ "$(j "$WORK/u-alice/c/person-bundle.json" "d['bundle']['roles']['steward']")" = '"---\nmodel: haiku\n---\n"' ] \
  && st_ok_all "U sync --person-version 5 → 入口 v5 = 本机 v5" || st_miss "U push rc=$rc/$rc2: $out / $out2"
out=$(UWARN=-1 ut alice status --roles); rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '缓存超过' && st_ok_all "U a read older than FLEET_ROLES_WARN_SECS → WARN" || st_miss "U stale rc=$rc: $out"
[ "$(j "$WORK/u-bob/c/person-bundle.json" "d['version']")" = 2 ] && [ "$(j "$WORK/u-bob/c/person-sync.json" "d.get('hub_version')")" = null ] \
  && st_ok_all "U bob's login untouched by alice's push" || st_miss "U bob crossed: $(cat "$WORK/u-bob/c/"*.json)"

st_done
