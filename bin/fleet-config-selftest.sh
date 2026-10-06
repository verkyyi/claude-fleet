#!/bin/bash
# fleet-config-selftest.sh — `fleet config` (issue #1860, EPIC #1855 C5): see
# every item's source, change the personal layer, promote a local item, roll
# back. Drives bin/fleet-config.py in a throwaway HOME; the hub is a fake behind
# the FLEET_PERSON_HUB_CMD seam (writes) and FLEET_PERSON_BUNDLE_CMD /
# FLEET_TEAM_BUNDLE_CMD (fleet-agent-team.py's reads, for the sync after a write):
#
#   A. no hub     show prints every item; add / promote / history exit 3 「没有入口」
#   B. show       one row of each source — fleet (a default MCP), 团队 (a team
#                 MCP), 个人 (a personal MCP), 本机 (this login's own); --json
#                 rows carry source default|team|personal|local
#   C. add        version +1, the item in the layer; a second add of another
#                 name is +1 again; set over an existing name; rm
#   D. 409        a write whose base moved meanwhile re-reads and lands
#   E. promote    a local MCP lands in the personal layer; show still says 本机
#   F. secret     a local MCP carrying a token literal is refused before
#                 anything is sent, naming the field and the ${VAR} spelling
#   G. machine    a value naming this login's home asks for --yes (exit 4)
#   H. restore    back to the previous version's body, as a new version
#   I. package    the client manifests carry the script; `fleet config` dispatches
#   J. people     the operator's list (#1866): two fake people, version · items ·
#                 who changed it, never a bundle; no viewer token over HTTP = exit 2
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
real="$BIN/fleet-config.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
C="$REPO/bin/fleet-config.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-config-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
PY="$(command -v python3)"
# The personal layer's MCP commands exist on this "machine": a server whose command
# is not here is left out of the layer (issue #1862, fleet-break-it personal-mcp-*).
mkdir -p "$WORK/stubs"
for c in pers-mcp r gh-mcp x my-mcp team-mcp; do printf '#!/bin/sh\n' > "$WORK/stubs/$c"; chmod +x "$WORK/stubs/$c"; done
PATH="$WORK/stubs:$PATH"

H="$WORK/home"
CONF="$H/.config/claude-fleet"
mkdir -p "$H/.claude" "$H/.codex" "$CONF" "$WORK/hub"
CTX7=$("$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["mcpServers"]["context7"]))' \
         "$REPO/conf/agent-defaults/claude/mcp.default.json")
cat > "$H/.claude.json" <<EOF
{"numStartups": 1, "mcpServers": {"context7": $CTX7, "mine": {"command": "my-mcp", "args": ["--mine"]}}}
EOF
echo '{"theme": "dark"}' > "$H/.claude/settings.json"
printf '# own\napproval_policy = "never"\n' > "$H/.codex/config.toml"

# the fake hub: one person's versions in $WORK/hub/p.json, the team's answer in
# $WORK/team.json. `hub M Q` answers {"status": N, …}; `hub raw` = the GET body
# fleet-agent-team.py's FLEET_PERSON_BUNDLE_CMD seam expects (empty = none).
cat > "$WORK/fakehub.py" <<'EOF'
import json, os, sys
d = os.environ["HUBDIR"]; f = os.path.join(d, "p.json")
st = json.load(open(f)) if os.path.exists(f) else {"versions": []}
def cur():
    return st["versions"][-1] if st["versions"] else {"version": 0, "prev": 0, "bundle": {}}
m = sys.argv[1]; q = sys.argv[2] if len(sys.argv) > 2 else ""
if m == "raw":
    print(json.dumps(cur()) if st["versions"] else ""); sys.exit(0)
if m == "GET" and "all=1" in q:
    print(json.dumps({"status": 200, "people": json.load(open(os.path.join(d, "people.json")))})); sys.exit(0)
if m == "GET":
    r = dict(cur(), status=200)
    if "history=1" in q:
        r["history"] = list(reversed(st["versions"]))
    print(json.dumps(r)); sys.exit(0)
body = json.load(sys.stdin)
bump = os.path.join(d, "bump")
if os.path.exists(bump):        # someone else wrote meanwhile (once)
    os.remove(bump)
    c = cur(); st["versions"].append({"version": c["version"] + 1, "prev": c["version"], "bundle": c["bundle"],
                                      "actor": "other", "note": "meanwhile"})
c = cur()
if "base" in body and body["base"] != c["version"]:
    json.dump(st, open(f, "w")); print(json.dumps({"status": 409, "error": "changed"})); sys.exit(0)
if "restore" in body:
    old = [v for v in st["versions"] if v["version"] == body["restore"]]
    if not old:
        print(json.dumps({"status": 404, "error": "no version"})); sys.exit(0)
    b = old[0]["bundle"]
else:
    b = body["bundle"]
n = {"version": c["version"] + 1, "prev": c["version"], "bundle": b, "actor": "me", "note": body.get("note", "")}
st["versions"].append(n); json.dump(st, open(f, "w"))
print(json.dumps(dict(n, status=200)))
EOF
HUBCMD="HUBDIR='$WORK/hub' '$PY' '$WORK/fakehub.py'"
TEAMCMD="cat '$WORK/team.json'"
echo '{"version": 2, "bundle": {"mcp": {"teamtool": {"command": "team-mcp"}}}}' > "$WORK/team.json"

# cfg <args…> — the script, sandboxed; HUB=0 = no hub at all
cfg() {
  if [ "${HUB:-1}" = 0 ]; then
    env -i PATH="$PATH" HOME="$H" USER=selftestuser FLEET_CONF_DIR="$CONF" CODEX_HOME="$H/.codex" \
      "$PY" "$C" "$@" 2>&1
  else
    env -i PATH="$PATH" HOME="$H" USER=selftestuser FLEET_CONF_DIR="$CONF" CODEX_HOME="$H/.codex" \
      FLEET_PERSON_HUB_CMD="$HUBCMD \"\$@\"" FLEET_PERSON_BUNDLE_CMD="$HUBCMD raw" \
      FLEET_TEAM_BUNDLE_CMD="$TEAMCMD" "$PY" "$C" "$@" 2>&1
  fi
}
ver() { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["versions"][-1]["version"] if s["versions"] else 0)' "$WORK/hub/p.json" 2>/dev/null || echo 0; }
pb()  { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps(s["versions"][-1]["bundle"], sort_keys=True))' "$WORK/hub/p.json" 2>/dev/null; }
row() { printf '%s\n' "$1" | awk -v p="$2" '$1 == p {print $2; exit}'; }

# ── A — no hub ───────────────────────────────────────────────────────────────
out=$(HUB=0 cfg show); rc=$?
[ $rc = 0 ] && [ "$(row "$out" claude.mcp.context7)" = fleet ] && [ "$(row "$out" claude.mcp.mine)" = 本机 ] \
  && ok "A show works with no hub (fleet + 本机 rows)" || bad "A show without a hub: rc=$rc $out"
nohub() {
  out=$(HUB=0 cfg "$@"); rc=$?
  { [ $rc = 3 ] && printf '%s' "$out" | grep -q '没有入口'; } && ok "A $* → exit 3 没有入口" || bad "A $*: rc=$rc $out"
}
nohub add --personal mcp x '{"command": "x"}'
nohub promote claude.mcp.mine
nohub history
nohub restore 1

# sync the team layer in, so show has a 团队 row
env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" CODEX_HOME="$H/.codex" FLEET_TEAM_BUNDLE_CMD="$TEAMCMD" \
  "$PY" "$REPO/bin/fleet-agent-team.py" sync >/dev/null 2>&1

# ── C — add / set / rm ───────────────────────────────────────────────────────
v0=$(ver)
out=$(cfg add --personal mcp perstool '{"command": "pers-mcp", "args": ["--p"]}'); rc=$?
[ $rc = 0 ] && [ "$(ver)" = $((v0 + 1)) ] && pb | grep -q '"perstool"' \
  && ok "C add → v$((v0 + 1)), perstool in the personal layer" || bad "C add: rc=$rc v=$(ver) $out"
out=$(cfg add --personal settings verbose true); rc=$?
[ $rc = 0 ] && [ "$(ver)" = $((v0 + 2)) ] && pb | grep -q '"claude_settings": {"verbose": true}' \
  && ok "C a second add → +1, both kept" || bad "C second add: rc=$rc $(pb) $out"
out=$(cfg add --personal settings verbose false); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'set' && ok "C add over a different value refuses (use set)" || bad "C add-over: rc=$rc $out"
out=$(cfg set --personal settings verbose false); rc=$?
[ $rc = 0 ] && pb | grep -q '"verbose": false' && ok "C set replaces" || bad "C set: rc=$rc $(pb)"
out=$(cfg rm --personal settings verbose); rc=$?
[ $rc = 0 ] && ! pb | grep -q claude_settings && ok "C rm takes it out" || bad "C rm: rc=$rc $(pb)"

# ── B — show: one row of each source ─────────────────────────────────────────
out=$(cfg show); rc=$?
r_d=$(row "$out" claude.mcp.context7); r_t=$(row "$out" claude.mcp.teamtool)
r_p=$(row "$out" claude.mcp.perstool); r_l=$(row "$out" claude.mcp.mine)
want_p=个人 want_ps=personal
[ $rc = 0 ] && [ "$r_d" = fleet ] && [ "$r_t" = 团队 ] && [ "$r_p" = "$want_p" ] && [ "$r_l" = 本机 ] \
  && ok "B show: fleet · 团队 · 个人 · 本机" || bad "B show sources: d=$r_d t=$r_t p=$r_p l=$r_l
$out"
js=$(cfg show --json claude.mcp.)
srcs=$(printf '%s' "$js" | "$PY" -c 'import json,sys; d=json.load(sys.stdin)["items"]; print(" ".join(d.get(k, {}).get("source", "") for k in ("claude.mcp.context7","claude.mcp.teamtool","claude.mcp.perstool","claude.mcp.mine")))' 2>&1)
[ "$srcs" = "default team $want_ps local" ] && ok "B --json sources: $srcs" || bad "B --json: $srcs"
out=$(cfg show claude.mcp.nosuch); [ $? = 2 ] && ok "B show of an unknown item exits 2" || bad "B unknown item: $out"

# ── D — 409: re-read, retry once ─────────────────────────────────────────────
touch "$WORK/hub/bump"; v1=$(ver)
out=$(cfg add --personal mcp racer '{"command": "r"}'); rc=$?
[ $rc = 0 ] && [ "$(ver)" = $((v1 + 2)) ] && pb | grep -q '"racer"' && pb | grep -q '"perstool"' \
  && ok "D a 409 re-reads and lands on top of the other write" || bad "D 409: rc=$rc v=$(ver) $out"

# ── E — promote a local MCP ──────────────────────────────────────────────────
out=$(cfg promote claude.mcp.mine); rc=$?
[ $rc = 0 ] && pb | grep -q '"mine": {"args": \["--mine"\], "command": "my-mcp"}' \
  && ok "E promote: mine is in the personal layer" || bad "E promote: rc=$rc $(pb) $out"
# identical here and in the layer, it composes as 个人; changed here, 本机 wins
"$PY" - "$H/.claude.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"]["mine"]["args"] = ["--mine", "--here"]
json.dump(d, open(p, "w"))
PYEOF
out=$(cfg show claude.mcp.mine)
[ "$(row "$out" claude.mcp.mine)" = 本机 ] && printf '%s' "$out" | grep -q -- '--here' \
  && ok "E a local change still wins over the personal layer" || bad "E local over personal: $out"
grep -q '"mine"' "$H/.claude.json" && ok "E the local file is untouched" || bad "E local file changed"

# ── F — a credential is refused, naming the field ─────────────────────────────
"$PY" - "$H/.claude.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["mcpServers"]["leaky"] = {"command": "gh-mcp", "env": {"GITHUB_TOKEN": "ghp_" + "a" * 36}}
json.dump(d, open(p, "w"))
EOF
v2=$(ver)
out=$(cfg promote claude.mcp.leaky); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'bundle.mcp.leaky.env.GITHUB_TOKEN' && printf '%s' "$out" | grep -q '${GITHUB_TOKEN}' \
  && [ "$(ver)" = "$v2" ] && ok "F token promote refused: names the field, suggests \${GITHUB_TOKEN}, nothing sent" \
  || bad "F secret: rc=$rc v=$(ver) $out"

# ── G — a value naming this computer asks first ──────────────────────────────
"$PY" - "$H/.claude.json" "$H" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["mcpServers"]["homey"] = {"command": sys.argv[2] + "/bin/homey"}
json.dump(d, open(p, "w"))
EOF
out=$(cfg promote claude.mcp.homey); rc=$?
[ $rc = 4 ] && printf '%s' "$out" | grep -q '只在本机有效' && [ "$(ver)" = "$v2" ] \
  && ok "G a home path asks for --yes (exit 4)" || bad "G machine-bound: rc=$rc $out"
out=$(cfg promote claude.mcp.homey --yes); rc=$?
[ $rc = 0 ] && pb | grep -q '"homey"' && ok "G --yes takes it" || bad "G --yes: rc=$rc $out"

# ── H — restore ──────────────────────────────────────────────────────────────
v3=$(ver); prev_body=$("$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps(s["versions"][-2]["bundle"], sort_keys=True))' "$WORK/hub/p.json")
out=$(cfg restore $((v3 - 1))); rc=$?
[ $rc = 0 ] && [ "$(ver)" = $((v3 + 1)) ] && [ "$(pb)" = "$prev_body" ] \
  && ok "H restore v$((v3 - 1)) → v$((v3 + 1)) with its body" || bad "H restore: rc=$rc v=$(ver) $out"
out=$(cfg history); printf '%s' "$out" | grep -q "当前 v$((v3 + 1))" && ok "H history lists the versions" || bad "H history: $out"

# ── I — the package ──────────────────────────────────────────────────────────
grep -q '^bin/fleet-config.py' "$REPO/conf/agent-bundle.manifest" && ok "I agent-bundle.manifest carries it" || bad "I not in agent-bundle.manifest"
grep -q '^bin/fleet-config.py' "$REPO/tokenledger/internal/api/fleetclient/manifest" && ok "I the hub client manifest carries it" || bad "I not in fleetclient/manifest"
out=$(env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" CODEX_HOME="$H/.codex" sh "$REPO/bin/fleet" config show claude.mcp.context7 2>&1)
printf '%s' "$out" | grep -q 'claude.mcp.context7' && ok "I \`fleet config\` dispatches" || bad "I dispatch: $out"

# ── J — people: every person's version, the operator's ───────────────────────
cat > "$WORK/hub/people.json" <<'EOF'
[{"principal": "wx-alice", "display_name": "Alice", "version": 4, "updated": "2026-10-06T08:00:00Z", "actor": "operator", "items": 3},
 {"principal": "wx-bob", "version": 0, "items": 0}]
EOF
out=$(cfg people); rc=$?
{ [ $rc = 0 ] && printf '%s\n' "$out" | grep 'wx-alice' | grep -q 'v4.*3.*2026-10-06 08:00:00.*operator' \
  && printf '%s\n' "$out" | grep 'wx-bob' | grep -q '未写过'; } \
  && ok "J people lists two people: version · items · when · by whom" || bad "J people: rc=$rc $out"
out=$(cfg people --json); rc=$?
[ $rc = 0 ] && [ "$(printf '%s' "$out" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 2 ] \
  && ! printf '%s' "$out" | grep -q '"bundle"' && ok "J --json: two rows, no bundle" || bad "J --json: rc=$rc $out"
out=$(env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" "$PY" "$C" people --hub http://127.0.0.1:9 2>&1); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'CCQUOTA_VIEWER_TOKEN' && ok "J no viewer token → exit 2 before asking the hub" || bad "J no token: rc=$rc $out"

[ "$fail" = 0 ] && echo "fleet-config-selftest: PASS" || echo "fleet-config-selftest: FAIL"
exit "$fail"
