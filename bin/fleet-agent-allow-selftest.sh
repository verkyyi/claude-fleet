#!/usr/bin/env bash
# fleet-agent-allow-selftest.sh — the new-session pickers and the admin's
# subscription allowlists (issue #3826).
#
# A person whose allowlist names only a Codex account (fleet.cred_allow.user.*)
# must SEE the agent choice, Claude grey with 「管理员暂未开放」, and get a session
# that starts — Codex, told so — never a hidden choice that reads as a broken
# client. And a thin client behind the hub's client_version is told to update.
#
#   A  bin/fleet_agent_allow.py: asks GET /v1/node/agents (a fake hub on
#      127.0.0.1) with the node token, keeps the answer, fails OPEN (no hub ⇒ {})
#   B  fleet-quick-dispatch.py grid / agent --view: Claude blocked ⇒ grey why +
#      `blocked`, the ⌘N pick is Codex with why; nothing blocked ⇒ as before
#   C  fleet_view.py: the ⚡ cells say Agent ‹Codex› + 「只开放了 Codex」, ↵ rides
#      --agent codex; ⌘N's new_agent picks Codex with why, and asks nothing
#      (no subprocess) when nothing is blocked
#   D  fleet-client-behind.py: same version ⇒ silent; older ⇒ 「客户端不是最新 …
#      fleet update」; no version (an older client) ⇒ silent
#   E  fleet-thin.py hands its version= to the home as FLEET_CLIENT_VER, and
#      fleet-remote-view.sh attach --thin reads it
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/selftest-lib.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/agent-allow.XXXXXX")
st_tally
export FLEET_CONF_DIR="$W/conf" HOME="$W/home" FLEET_UI_LANG=zh
mkdir -p "$FLEET_CONF_DIR/global" "$HOME"
unset FLEET_AGENTS_BLOCKED FLEET_HUB_CLIENT_VERSION TMUX TMUX_PANE

# ---- A: the hub read --------------------------------------------------------
cat > "$W/hub.py" <<'PY'
import http.server, json, sys, time
port_file, answer, log = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, "a") as f:
            f.write("%s %s\n" % (self.path, self.headers.get("Authorization", "")))
        if self.path == "/v1/node/agents":
            body = open(answer, "rb").read()
            self.send_response(200)
        else:
            body = b"{}"
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.timeout = 0.5
end = time.time() + 60        # never outlives the test
while time.time() < end:
    s.handle_request()
PY
printf '{"agents":[{"agent":"claude","blocked":true,"reason":"policy"},{"agent":"codex"}]}' > "$W/answer.json"
python3 "$W/hub.py" "$W/port" "$W/answer.json" "$W/hub.log" &
HUBPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/port" ] && break; sleep 0.2; done
PORT=$(cat "$W/port" 2>/dev/null)
[ -n "$PORT" ] || st_miss "A: the fake hub did not start"

got=$(CCQUOTA_HUB_URL="http://127.0.0.1:$PORT" CCQUOTA_TOKEN=tok-a python3 "$BIN/fleet_agent_allow.py" blocked)
[ "$got" = claude ] && st_ok_all "A: the hub's verdict read: claude blocked" || st_miss "A: blocked = '$got'"
grep -q '^/v1/node/agents Bearer tok-a$' "$W/hub.log" && st_ok_all "A: asked with the node token" || st_miss "A: hub log: $(cat "$W/hub.log")"
[ -s "$FLEET_CONF_DIR/global/agent-allow.json" ] && st_ok_all "A: the answer is kept" || st_miss "A: nothing kept"
n=$(wc -l < "$W/hub.log" | tr -d ' ')
CCQUOTA_HUB_URL="http://127.0.0.1:$PORT" CCQUOTA_TOKEN=tok-a python3 "$BIN/fleet_agent_allow.py" blocked >/dev/null
[ "$(wc -l < "$W/hub.log" | tr -d ' ')" = "$n" ] && st_ok_all "A: a second read inside the TTL asks nothing" || st_miss "A: asked the hub again"
rm -f "$FLEET_CONF_DIR/global/agent-allow.json"
got=$(CCQUOTA_HUB_URL="http://127.0.0.1:1" CCQUOTA_TOKEN=tok-a FLEET_AGENT_ALLOW_TIMEOUT=1 python3 "$BIN/fleet_agent_allow.py" blocked)
[ -z "$got" ] && st_ok_all "A: no hub ⇒ nothing blocked (fails open)" || st_miss "A: no hub still blocked '$got'"
[ -e "$FLEET_CONF_DIR/global/agent-allow.json" ] && st_miss "A: an unanswered ask was kept as a verdict"
kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null

# ---- B: ⌘T / the ⚡ grid and the ⌘N pick ---------------------------------------
export FLEET_DISPATCH_AGENTS_HERE=claude,codex FLEET_AGENT=claude
g=$(FLEET_AGENTS_BLOCKED=claude python3 "$BIN/fleet-quick-dispatch.py" grid --view fl@view-v1)
python3 - "$g" <<'PY' && st_ok_all "B: grid: claude grey 「管理员暂未开放」, blocked=[claude]" || st_miss "B: grid $g"
import json, sys
g = json.loads(sys.argv[1])
assert g["missing"] == {"claude": "Claude：管理员暂未开放"}, g
assert g["blocked"] == ["claude"] and g["agent"] == "claude", g
PY
a=$(FLEET_AGENTS_BLOCKED=claude python3 "$BIN/fleet-quick-dispatch.py" agent --view fl@view-v1)
[ "$a" = '{"agent": "codex", "why": "Claude：管理员暂未开放"}' ] && st_ok_all "B: ⌘N's pick is Codex, with why" || st_miss "B: agent $a"
a=$(FLEET_AGENTS_BLOCKED='' python3 "$BIN/fleet-quick-dispatch.py" agent --view fl@view-v1)
[ "$a" = '{"agent": "claude", "why": ""}' ] && st_ok_all "B: nothing blocked ⇒ the default, no why" || st_miss "B: unblocked agent $a"
g=$(FLEET_AGENTS_BLOCKED='' python3 "$BIN/fleet-quick-dispatch.py" grid --view fl@view-v1)
case "$g" in *'"missing": {}'*'"blocked": []'*) st_ok_all "B: nothing blocked ⇒ the grid as before" ;; *) st_miss "B: unblocked grid $g" ;; esac

# ---- C: fleet_view's ⚡ cells and ⌘N ---------------------------------------------
FLEET_AGENTS_BLOCKED=claude python3 - "$BIN" <<'PY' && st_ok_all "C: ⚡ shows Agent ‹Codex› + 「只开放了 Codex」, ↵ rides --agent codex; ⌘N picks Codex" || st_miss "C: see above"
import sys
sys.path.insert(0, sys.argv[1])
import fleet_view as v
g = {"repos": [], "last": "", "agent": "claude", "missing": {"claude": "Claude：管理员暂未开放"}, "blocked": ["claude"]}
st = v.bolt_new(g)
cells, note = v.bolt_cells(st, "")
assert cells[1][0] == "Agent ‹Codex›", cells
assert "Claude：管理员暂未开放" in note and "只开放了 Codex，就用它" in note, note
v.view_fleet = lambda vid, row=None: "fl"
class QO: __file__ = "qo.py"
argv, _, where = v.bolt_argv(QO, "v1", "", st, "")
assert argv[argv.index("--agent") + 1] == "codex", argv
assert where.endswith("Codex"), where
# not installed (no allowlist): grey why, but never 「只开放了」
st = v.bolt_new({"repos": [], "last": "", "agent": "claude", "missing": {"claude": "x 这台没装 claude"}, "blocked": []})
assert "只开放了" not in v.bolt_cells(st, "")[1]
a, why = v.new_agent("fl", "v1")
assert (a, why) == ("codex", "Claude：管理员暂未开放"), (a, why)
assert v.say("view_new_agent_fmt", why, "Codex") == "Claude：管理员暂未开放 — 这次用 Codex 开"
PY
FLEET_AGENTS_BLOCKED='' python3 - "$BIN" <<'PY' && st_ok_all "C: nothing blocked ⇒ ⌘N names no agent and runs nothing" || st_miss "C: unblocked ⌘N"
import subprocess, sys
sys.path.insert(0, sys.argv[1])
import fleet_view as v
def boom(*a, **k):
    raise AssertionError("a subprocess on the fast path: %r" % (a,))
subprocess.run = boom
assert v.new_agent("fl", "v1") == ("", "")
PY
grep -q 'agent, why = new_agent(fleet, vid)' "$BIN/fleet_view.py" && st_ok_all "C: go_new asks new_agent when no agent is named" || st_miss "C: go_new does not ask"

# ---- D: 请更新客户端 ------------------------------------------------------------------
out=$(FLEET_HUB_CLIENT_VERSION=bbbbbbbbbb python3 "$BIN/fleet-client-behind.py" bbbbbbbbbb)
[ -z "$out" ] && st_ok_all "D: the latest client ⇒ nothing said" || st_miss "D: same version said '$out'"
out=$(FLEET_HUB_CLIENT_VERSION=bbbbbbbbbb python3 "$BIN/fleet-client-behind.py" aaaaaaaaaa)
case "$out" in *客户端不是最新*aaaaaaa*bbbbbbb*'fleet update'*) st_ok_all "D: behind ⇒ 「${out}」" ;; *) st_miss "D: behind said '$out'" ;; esac
out=$(FLEET_HUB_CLIENT_VERSION=bbbbbbbbbb python3 "$BIN/fleet-client-behind.py" '')
[ -z "$out" ] && st_ok_all "D: an older client (no version) ⇒ nothing said" || st_miss "D: no version said '$out'"
out=$(FLEET_HUB_CLIENT_VERSION='' python3 "$BIN/fleet-client-behind.py" aaaaaaaaaa)
[ -z "$out" ] && st_ok_all "D: the hub names no client ⇒ nothing said" || st_miss "D: unknown latest said '$out'"

# ---- E: the thin client carries it ------------------------------------------------
mkdir -p "$W/thin/bin"
cp "$BIN/fleet-thin.py" "$W/thin/bin/"
printf 'version=cafe1234cafe1234\ncompat=1\ncommit=cafe1234\nhub=https://h\nat=1\n' > "$W/thin/.client-version"
python3 - "$W/thin/bin/fleet-thin.py" <<'PY' && st_ok_all "E: fleet-thin.py hands FLEET_CLIENT_VER to the home" || st_miss "E: thin remote()"
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("thin", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
self = types.SimpleNamespace(view="v1", resume=False, want="", device="ZA==", keys="")
cmd = m.Thin.remote(self, "tok", "r")
assert cmd.startswith("FLEET_CLIENT_VER=cafe1234cafe1234 FLEET_CLIENT_CAPS=show bash "), cmd
PY
grep -q 'fleet-client-behind.py" "$FLEET_CLIENT_VER"' "$BIN/fleet-remote-view.sh" \
  && st_ok_all "E: attach --thin asks fleet-client-behind.py with it" || st_miss "E: attach --thin does not read FLEET_CLIENT_VER"

rm -rf "$W"
st_done
