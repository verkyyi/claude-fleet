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
#                  cache stays
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
real="$BIN/fleet-agent-team.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
T="$REPO/bin/fleet-agent-team.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-agent-team-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
PY="$(command -v python3)"

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
    ${SEAM:+FLEET_TEAM_BUNDLE_CMD="$SEAM"} "$PY" "$T" "$@" --root "$REPO" \
    --claude-config "$H/.claude.json" --claude-settings "$H/.claude/settings.json" \
    --claude-skills "$H/.claude/skills" --codex-home "$H/.codex" 2>&1
}
status() { env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" "$PY" "$T" status "$@" 2>&1; }
resp() { printf '%s\n' "$1" > "$WORK/resp.json"; }
snap() {
  (cd "$H" && find . -type f 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done)
}
j() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))" "$@" 2>/dev/null; }
src() { j "$CONF/agent-effective.json" "d['items'].get('$1', {}).get('source')"; }

# ── A — no hub, no cache: nothing ────────────────────────────────────────────
before=$(snap)
SEAM='' out=$(team sync); rc=$?
[ "$rc" = 3 ] && [ ! -e "$CONF/agent-effective.json" ] && [ "$(snap)" = "$before" ] \
  && ok "A no hub → exit 3, no file written ($out)" || bad "A rc=$rc out=$out"
out=$(SEAM='' team apply); [ ! -e "$CONF/agent-effective.json" ] && [ "$(snap)" = "$before" ] \
  && ok "A apply with no layer writes nothing" || bad "A apply wrote: $out"

SEAM="cat $WORK/resp.json"
# ── B — the team adds ─────────────────────────────────────────────────────────
resp '{"version":1,"prev":0,"bundle":{
  "mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]},"mine":{"command":"team-mcp"}},
  "hooks":{"Stop":[{"command":"echo team-stop","timeout":5}]},
  "skills":{"team-notes":"---\nname: team-notes\n---\n# notes\n"},
  "claude_settings":{"includeCoAuthoredBy":false},
  "codex_config":{"sandbox_mode":"workspace-write"}}}'
out=$(team sync); rc=$?
[ "$rc" = 0 ] || bad "B sync rc=$rc: $out"
[ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args'][-1]")" = '"--read-only"' ] \
  && grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" \
  && ok "B the team's MCP server reached Claude and Codex" || bad "B docs-ro missing: $out"
[ "$(j "$H/.claude/settings.json" "d['hooks']['Stop'][0]['hooks'][0]['command']")" = '"echo team-stop"' ] \
  && [ "$(j "$H/.claude/settings.json" "d['includeCoAuthoredBy']")" = false ] \
  && [ "$(j "$H/.claude/settings.json" "d['theme']")" = '"dark"' ] \
  && ok "B hook + setting landed in settings.json, the login's keys kept" || bad "B settings: $(cat "$H/.claude/settings.json")"
[ -f "$H/.claude/skills/team-notes/SKILL.md" ] && [ -f "$H/.codex/skills/team-notes/SKILL.md" ] \
  && ok "B the team's skill reached both agents" || bad "B skill missing"
grep -q '^sandbox_mode = "workspace-write"' "$H/.codex/config.toml" && head -1 "$H/.codex/config.toml" | grep -q '^# this login' \
  && ok "B a Codex key the login lacked is set; its own lines stay" || bad "B codex: $(cat "$H/.codex/config.toml")"
[ "$(src claude.mcp.docs-ro)" = '"team"' ] && [ "$(src claude.mcp.context7)" = '"default"' ] \
  && [ "$(src claude.mcp.mine)" = '"local"' ] && [ "$(src codex.mcp.docs-ro)" = '"team"' ] \
  && [ "$(j "$CONF/agent-effective.json" "d['team']['version']")" = 1 ] \
  && ok "B agent-effective.json: docs-ro team · context7 default · mine local, v1" || bad "B effective: $(cat "$CONF/agent-effective.json")"
case "$(status --short)" in "team v1") ok "B status: team v1" ;; *) bad "B status: $(status --short)" ;; esac

# ── C — local wins ────────────────────────────────────────────────────────────
[ "$(j "$H/.claude.json" "d['mcpServers']['mine']['command']")" = '"my-mcp"' ] \
  && grep -A1 '^\[mcp_servers.mine\]' "$H/.codex/config.toml" | grep -q 'my-mcp' \
  && grep -q '^model_reasoning_effort = "xhigh"' "$H/.codex/config.toml" \
  && ok "C a name this login already had keeps its value (Claude + Codex)" || bad "C mine overwritten"
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
  && ok "C an item edited here stays this login's on v2; untouched team items follow v2" || bad "C v2: $out"

# ── D — team over an untouched default, then the rollback ─────────────────────
resp '{"version":3,"prev":2,"bundle":{"mcp":{"context7":{"command":"npx","args":["-y","@team/context7"]}},
  "codex_config":{"model_reasoning_effort":"low"}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['context7']['args'][-1]")" = '"@team/context7"' ] && [ "$(src claude.mcp.context7)" = '"team"' ] \
  && ok "D the team's context7 replaced the untouched fleet default" || bad "D context7: $out"
grep -q '^model_reasoning_effort = "xhigh"' "$H/.codex/config.toml" && [ "$(src codex.model_reasoning_effort)" = '"local"' ] \
  && ok "D a Codex key this login set itself stays (xhigh), source local" || bad "D codex key: $(cat "$H/.codex/config.toml")"
# ── E — what the team dropped (v3 has no docs-ro / hook / skill / setting) ────
[ ! -e "$H/.claude/skills/team-notes" ] && [ ! -e "$H/.codex/skills/team-notes" ] \
  && [ "$(j "$H/.claude/settings.json" "'hooks' in d or 'includeCoAuthoredBy' in d")" = false ] \
  && ! grep -q '^sandbox_mode = "workspace-write"' "$H/.codex/config.toml" \
  && ! grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args']")" = '["my", "own"]' ] \
  && ok "E dropped items taken back (skill, hook, setting, Codex key + server); the one edited here stays" \
  || bad "E: $out // $(cat "$H/.codex/config.toml")"
# the rollback = v1's body again, as v4
resp '{"version":4,"prev":3,"bundle":{"mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "d['mcpServers']['context7']")" = "$("$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$CTX7")" ] \
  && [ "$(src claude.mcp.context7)" = '"default"' ] \
  && ok "D rollback: context7 is the fleet default again" || bad "D rollback: $out"
grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" && ok "E a re-added team server returns where it was not this login's" || bad "E codex docs-ro back"

# ── H — again: nothing moves ──────────────────────────────────────────────────
before=$(snap); out=$(team sync); out2=$(team apply)
[ "$(snap | grep -v agent-effective.json)" = "$(printf '%s\n' "$before" | grep -v agent-effective.json)" ] \
  && printf '%s\n' "$out2" | grep -q 'changed 0 item' && ok "H a second sync / apply changes no file" || bad "H: $out2"

# ── I — an override shields one item ──────────────────────────────────────────
echo '["claude.mcp.extra"]' > "$CONF/agent-overrides.json"
resp '{"version":5,"prev":4,"bundle":{"mcp":{"docs-ro":{"command":"npx","args":["-y","docs-mcp","--read-only"]},"extra":{"command":"x"}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "'extra' in d['mcpServers']")" = false ] && grep -q '^\[mcp_servers.extra\]' "$H/.codex/config.toml" \
  && ok "I claude.mcp.extra listed in agent-overrides.json is not written (Codex still gets it)" || bad "I: $out"

# ── F — team: off ──────────────────────────────────────────────────────────────
echo '{"team": "off"}' > "$CONF/agent-overrides.json"
out=$(team sync)
! grep -q '^\[mcp_servers.docs-ro\]' "$H/.codex/config.toml" && ! grep -q '^\[mcp_servers.extra\]' "$H/.codex/config.toml" \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['docs-ro']['args']")" = '["my", "own"]' ] \
  && [ "$(j "$H/.claude.json" "d['mcpServers']['mine']['command']")" = '"my-mcp"' ] \
  && ok "F team: off takes back what the team wrote; this login's own stay" || bad "F: $out"
case "$(status --short)" in "team off") ok "F status: team off" ;; *) bad "F status: $(status --short)" ;; esac
resp '{"version":6,"prev":5,"bundle":{"mcp":{"brand-new":{"command":"x"}}}}'
out=$(team sync)
[ "$(j "$H/.claude.json" "'brand-new' in d['mcpServers']")" = false ] && ok "F team: off adds nothing new" || bad "F added: $out"
rm -f "$CONF/agent-overrides.json"
out=$(team sync)
[ "$(j "$H/.claude.json" "'brand-new' in d['mcpServers']")" = true ] && ok "F back on: v6 applies" || bad "F back on: $out"

# ── G — a credential is refused ───────────────────────────────────────────────
for b in '{"mcp":{"gh":{"command":"x","env":{"GITHUB_TOKEN":"abc123"}}}}' \
         '{"mcp":{"gh":{"command":"x","args":["ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}}' \
         '{"claude_settings":{"apiKeyHelper":"/bin/echo"}}' '{"accounts":{}}'; do
  before=$(snap)
  resp "{\"version\":7,\"prev\":6,\"bundle\":$b}"
  out=$(team sync); rc=$?
  [ "$rc" = 2 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 6 ] && [ "$(snap)" = "$before" ] \
    && ok "G refused, v6 kept, nothing written: $(printf '%s' "$out" | head -1 | cut -c1-90)" || bad "G rc=$rc $out"
done
resp '{"version":7,"prev":6,"bundle":{"mcp":{"gh":{"command":"x","env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}}}}'
out=$(team sync); [ "$?" = 0 ] && [ "$(src claude.mcp.gh)" = '"team"' ] && ok "G a \${VAR} reference is not a credential" || bad "G ref: $out"

# ── J — the install's team step ──────────────────────────────────────────────
grep -q 'fleet-agent-team.py' "$REPO/bin/fleet-install-apply.sh" && ok "J fleet-install-apply.sh runs the team step" || bad "J no team step in install-apply"
grep -q 'fleet-agent-team.py' "$REPO/conf/agent-bundle.manifest" && ok "J the client package carries fleet-agent-team.py" || bad "J not in agent-bundle.manifest"

# ── K — the HTTP fetch ─────────────────────────────────────────────────────────
cat > "$WORK/stub.py" <<'PY2'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(sys.argv[2], "a") as f:
            f.write("%s %s %s\n" % (self.path, self.headers.get("Authorization"), self.headers.get("If-None-Match")))
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
[ -n "$PORT" ] || bad "K the loopback stub never started"
printf 'CCQUOTA_TOKEN=node-tok\nCCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$PORT" > "$CONF/node.env"
out=$(SEAM='' team sync); rc=$?
[ "$rc" = 0 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 9 ] && grep -q 'Bearer node-tok' "$WORK/req.log" \
  && [ "$(j "$CONF/agent-effective.json" "d['team']['version']")" = 9 ] \
  && ok "K fetched v9 with the node token and composed it" || bad "K fetch rc=$rc: $out"
out=$(SEAM='' team fetch); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'unchanged' && tail -1 "$WORK/req.log" | grep -q '"team-v9"' \
  && ok "K If-None-Match the cached version → 304, unchanged" || bad "K 304: rc=$rc $out"
printf 'CCQUOTA_TOKEN=wrong\nCCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$PORT" > "$CONF/node.env"
out=$(SEAM='' team sync); rc=$?
[ "$rc" = 1 ] && [ "$(j "$CONF/team-bundle.json" "d['version']")" = 9 ] \
  && ok "K a refused token (no certificate) is exit 1; v9 stays cached" || bad "K 401: rc=$rc $out"
kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null

[ "$fail" = 0 ] && echo "fleet-agent-team-selftest: PASS" || echo "fleet-agent-team-selftest: FAIL"
exit "$fail"
