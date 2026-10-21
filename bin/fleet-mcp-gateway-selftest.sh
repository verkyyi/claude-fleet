#!/bin/bash
# fleet-mcp-gateway-selftest.sh — the MCP servers a session opens when it needs
# them (bin/fleet_mcp_gateway.py through bin/fleet-mcp.py's `fleet` server, T716 F).
#
#   A  the core server's tools/list carries mcp_list / mcp_enable / mcp_disable;
#      mcp_list names what the login configured (user · project · plugin · the
#      fleet layer), a remote one as the agent's own, never the fleet's servers
#   B  mcp_enable starts a stub stdio server: list_changed is sent, its tools are
#      served as <server>__<tool> and a call reaches it; the session's fleet
#      credential is not in its environment; one line in logs/mcp-enable.ndjson
#   C  a server that dies answers its own calls with an error, the others go on;
#      a name nobody configured is refused, nothing started
#   D  mcp_disable stops it: list_changed, its tools gone; FLEET_MCP_GATEWAY=0
#      serves none of the three
#   E  lean-config: GitHub + every remote server + FLEET_MCP_EXTRA, 0600; stats
#      counts enables per repo
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_sandbox "${TMPDIR:-/tmp}/fmcpgw.XXXXXX"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$HOME/.claude" "$FLEET_CONF_DIR" "$WORK/repo"
unset TMUX TMUX_PANE FLEET_MCP_GATEWAY FLEET_MCP_EXTRA FLEET_MCP_TEAM_FILE
FAIL=0; : "$FAIL"   # st_miss counts in it, st_done reads it

# a stub MCP server: echo + die + the env it sees
cat > "$WORK/stub.py" <<'PY'
import json, os, sys
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    meth, rid = m.get("method"), m["id"]
    if meth == "initialize":
        r = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "stub"}}
    elif meth == "tools/list":
        r = {"tools": [{"name": "echo", "description": "say it back", "inputSchema": {"type": "object"}},
                       {"name": "die", "description": "exit", "inputSchema": {"type": "object"}}]}
    elif meth == "tools/call":
        p = m["params"]
        if p["name"] == "die":
            sys.exit(3)
        r = {"content": [{"type": "text", "text": "echo:%s cred=%s" % (p["arguments"].get("w"),
                                                                     os.environ.get("FLEET_WORKER_CRED", "-"))}]}
    else:
        r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": r}), flush=True)
PY
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]
stub = {"type": "stdio", "command": sys.executable, "args": [os.path.join(w, "stub.py")]}
json.dump({"mcpServers": {"stub": stub, "stub2": stub, "github": {"command": "true"},
                          "remote": {"type": "http", "url": "https://example.invalid/mcp"},
                          "fleet": {"command": "nope"}}},
          open(os.path.join(w, "home", ".claude.json"), "w"))
json.dump({"mcpServers": {"proj": stub}}, open(os.path.join(w, "repo", ".mcp.json"), "w"))
PY

# drive the core server with one batch of requests; print what it wrote
serve() { ( cd "$WORK/repo" && FLEET_WORKER_CRED=secret-cred python3 "$BIN/fleet-mcp.py" ) 2>/dev/null; }
E='{}'
req() { printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$1" "$2" "${3:-$E}"; }
call() { req "$1" tools/call "{\"name\":\"$2\",\"arguments\":${3:-$E}}"; }

out=$( { req 1 initialize '{"protocolVersion":"2024-11-05"}'; req 2 tools/list
         call 3 mcp_list
         call 4 mcp_enable '{"name":"stub"}'; req 5 tools/list
         call 6 stub__echo '{"w":"hi"}'
         call 7 mcp_enable '{"name":"stub2"}'; call 8 stub2__die; call 9 stub2__echo '{"w":"x"}'; call 10 stub__echo '{"w":"again"}'
         call 11 mcp_enable '{"name":"nobody"}'
         call 12 mcp_disable '{"name":"stub"}'; req 13 tools/list; } | serve )
printf '%s\n' "$out" > "$WORK/out"

python3 - "$WORK/out" "$FLEET_CONF_DIR" <<'PY' && st_ok "A..D the gateway: list, enable (list_changed, proxied calls, no credential), a dead one isolated, disable" || st_miss "A..D gateway"
import json, os, sys
msgs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {m["id"]: m for m in msgs if "id" in m}
notes = [i for i, m in enumerate(msgs) if m.get("method") == "notifications/tools/list_changed"]
names = lambda i: [t["name"] for t in by[i]["result"]["tools"]]
text = lambda i: "".join(c.get("text", "") for c in by[i]["result"]["content"])
# A
assert {"mcp_list", "mcp_enable", "mcp_disable"} <= set(names(2)), names(2)
assert not any("__" in n for n in names(2)), names(2)
lst = text(3)
for want in ("stub ", "stub2 ", "proj ", "remote ", "github "):
    assert want in lst, (want, lst)
assert "fleet " not in lst.replace("fleet-", ""), lst
assert "remote " in lst and "远程" in lst.split("remote", 1)[1].split("\n")[0], lst
# B
assert "已打开" in text(4) and "stub__echo" in text(4), text(4)
assert "stub__echo" in names(5) and "stub__die" in names(5), names(5)
assert text(6) == "echo:hi cred=-", text(6)               # the session's credential stays out
assert len(notes) >= 2, notes
# C: stub2 died on its own call; stub still answers
assert by[8]["result"].get("isError"), by[8]
assert by[9]["result"].get("isError"), by[9]
assert text(10) == "echo:again cred=-", text(10)
assert "没有名为" in text(11), text(11)
# D
assert "已关闭" in text(12), text(12)
assert not any(n.startswith("stub__") for n in names(13)), names(13)
log = [json.loads(l) for l in open(os.path.join(sys.argv[2], "logs", "mcp-enable.ndjson"))]
assert [(r["name"], r["action"]) for r in log] == [("stub", "enable"), ("stub2", "enable"), ("stub", "disable")], log
PY

out=$( { req 1 initialize '{}'; req 2 tools/list; } | ( cd "$WORK/repo" && FLEET_MCP_GATEWAY=0 python3 "$BIN/fleet-mcp.py" 2>/dev/null ) )
printf '%s\n' "$out" | grep -q '"mcp_enable"' && st_miss "D FLEET_MCP_GATEWAY=0 still served the gateway"

# E
( cd "$WORK/repo" && FLEET_MCP_EXTRA=proj python3 "$BIN/fleet_mcp_gateway.py" lean-config "$WORK/lean.json" ) >/dev/null
python3 - "$WORK/lean.json" <<'PY' && st_ok "E lean-config: github + remote + FLEET_MCP_EXTRA, 0600" || st_miss "E lean-config"
import json, os, stat, sys
d = json.load(open(sys.argv[1]))["mcpServers"]
assert sorted(d) == ["github", "proj", "remote"], sorted(d)
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
[ "$(python3 "$BIN/fleet_mcp_gateway.py" stats)" = "$(printf -- '-\tstub\t1\n-\tstub2\t1')" ] \
  && st_ok "E stats: enables per repo · server" || st_miss "E stats: $(python3 "$BIN/fleet_mcp_gateway.py" stats)"
st_done
