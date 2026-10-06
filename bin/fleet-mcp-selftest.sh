#!/bin/sh
# fleet-mcp-selftest.sh — the fleet tool service's contract (issue #1807, EPIC #1813 C5).
#
# bin/fleet-mcp.py is the ONE stdio MCP server Claude and Codex sessions both mount
# (docs/FLEET-MCP.md). Driven against fake scripts in a sandbox bin/:
#   A  initialize + tools/list: server `fleet`, exactly the seven tools, every
#      schema closed (additionalProperties false)
#   B  refusals: an unknown argument, a wrong type, a missing argument, an
#      out-of-range timeout, a malformed repo, a repo this fleet does not host,
#      an unknown tool — each answered isError with the reason, and NOTHING ran
#   C  each tool runs its script once, with exactly its argv; the script's exit
#      code, stdout and stderr come back as they came (a non-zero exit is data)
#   D  degenerate (EPIC #1813 rule 1): no hub at all — every hub variable unset —
#      and every tool is still listed and still runs
#   E  the legacy fleet-peer shim still serves list_agents / send_message
#   F  `--mount codex` derives Codex's -c value from conf/mcp-worker.json, with
#      the env Codex withholds and a per-call timeout an await fits in
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
SUT="$BIN/fleet-mcp.py"
[ -f "$SUT" ] || { echo "selftest: fleet-mcp.py missing" >&2; exit 2; }
[ -f "$BIN/fleet-peer-mcp.py" ] || { echo "selftest: fleet-peer-mcp.py missing" >&2; exit 2; }
[ -f "$BIN/../conf/mcp-worker.json" ] || { echo "selftest: conf/mcp-worker.json missing" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-mcp.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/conf"
cp "$SUT" "$WORK/bin/fleet-mcp.py"
cp "$BIN/fleet-peer-mcp.py" "$WORK/bin/fleet-peer-mcp.py"
cp "$BIN/../conf/mcp-worker.json" "$WORK/conf/mcp-worker.json"
LOG="$WORK/runs"; : > "$LOG"

cat > "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_origin_key() { printf 'issue-1807'; }
_fleet_hosts_many() { return 1; }
fleet_origin_win() { printf '@77'; }
fleet_win_for_key() { [ "$1" = issue-77 ] && printf '@77'; }
SH
# Every fake script logs its argv, one line per run, to $LOG.
fake() { # fake <name> <body>
  { printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\n' "$1" "$LOG"; printf '%s\n' "$2"; } > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}
fake fleet-repo.sh 'printf "fleet tf hosts:\n  acme/app                 main=/x/app  base=main  [conf]\n  acme/lib                 main=/x/lib  base=main  [repos/acme-lib.conf]\n"'
fake fleet-children.sh 'if [ "${1:-}" = --json ]; then printf "%s\n" "{\"children\":[{\"child\":\"issue-99\",\"outcome\":\"merged\"}]}"; else printf "issue-99  merged  PR #5\n1/1 ✓\n"; fi'
fake dash-issue-session.sh 'echo "spawned issue-$1"; echo "cap note" >&2; exit 2'
fake fleet-await.sh 'echo "MERGED #$1 pr=42"; exit 0'
fake fleet-peer-send.sh 'text=$(cat); printf "sent -> %s (%s)\n" "$1" "$text"'

cat > "$WORK/tmux" <<'SH'
#!/bin/sh
if [ "$1" = display-message ]; then
  case "$*" in
    *session_name*) printf 'tf\n' ;;
    *'window #{window_name}'*) printf 'window issue-1807 · issue=1807 repo=acme/app state=working lifecycle= origin=issue-77\n' ;;
    *'#{@origin}'*) printf 'issue-77\n' ;;
  esac
  exit 0
fi
if [ "$1" = list-windows ]; then
  printf '@1\ttf\tissue-1807\t1807\tcodex\tworking\t\tissue-77\t\t\t/tmp/repo-issue-1807\t/tmp/repo-issue-1807\n'
  printf '@2\ttf\tissue-77\t77\t\tidle\t\t\t\t\t/tmp/repo-issue-77\t/tmp/repo-issue-77\n'
  printf '@3\ttf\tissue-99\t99\t\tidle\t\tissue-1807\t\t\t/tmp/repo-issue-99\t/tmp/repo-issue-99\n'
  printf '@4\ttf\thome\t\t\tidle\t\t\t\t\t/tmp\t/tmp\n'
  exit 0
fi
exit 1
SH
chmod +x "$WORK/tmux"

# serve <out> [extra server args] < requests — one stdio session, no hub anywhere.
serve() {
  out=$1; shift
  env -u CCQUOTA_FLEET -u FLEET_HUB_URL -u CCQUOTA_HUB_URL -u CCQUOTA_URL \
    PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 python3 "$WORK/bin/fleet-mcp.py" "$@" > "$out"
}
call() { # call <id> <tool> <json args>
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"
}

# --- A: the tool list ---------------------------------------------------------
serve "$WORK/a" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
python3 - "$WORK/a" <<'PY' || fail "A: initialize / tools/list" "$(cat "$WORK/a")"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, rows                       # the notification got no answer
assert rows[0]["result"]["serverInfo"]["name"] == "fleet", rows[0]
assert rows[0]["result"]["protocolVersion"] == "2025-06-18", rows[0]
tools = {t["name"]: t for t in rows[1]["result"]["tools"]}
assert set(tools) == {"status", "children", "repos", "agents", "spawn", "await", "send"}, sorted(tools)
for t in tools.values():
    assert t["inputSchema"]["additionalProperties"] is False, t
    assert t["description"], t
assert tools["spawn"]["inputSchema"]["required"] == ["issue"]
assert tools["send"]["inputSchema"]["required"] == ["to", "text"]
PY
ok "A server \`fleet\`, the seven tools, every schema closed"

# --- B: refusals — nothing runs -----------------------------------------------
: > "$LOG"
{
  call 10 spawn '{"issue":5,"force":true}'
  call 11 spawn '{"issue":"5"}'
  call 12 spawn '{}'
  call 13 await '{"issue":5,"timeout":9999}'
  call 14 spawn '{"issue":5,"repo":"--force"}'
  call 15 spawn '{"issue":5,"repo":"other/repo"}'
  call 16 await '{"issue":5,"repo":"other/repo"}'
  call 17 status '{"issue":5}'
  call 18 send '{"to":"rm -rf","text":"x"}'
  call 19 nope '{}'
  call 20 spawn '{"issue":true}'
} | serve "$WORK/b"
python3 - "$WORK/b" <<'PY' || fail "B: a bad call was not refused with its reason" "$(cat "$WORK/b")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
want = {10: 'unknown argument "force"', 11: "must be an integer", 12: 'missing required argument "issue"',
        13: "≤ 570", 14: "owner/name", 15: "not hosted by this fleet", 16: "acme/app, acme/lib",
        17: "takes no arguments", 18: "issue:<N>, scratch-<N> or parent", 19: "unknown tool",
        20: "must be an integer"}
for i, why in want.items():
    res = rows[i]["result"]
    assert res.get("isError") is True, (i, res)
    text = res["content"][0]["text"]
    assert why in text and "Nothing ran." in text, (i, text)
PY
# The repo check READS fleet-repo.sh list; nothing else may have run.
ran=$(grep -v '^fleet-repo.sh list$' "$LOG")
[ -z "$ran" ] || fail "B: a refused call ran a script" "$ran"
ok "B unknown arg · wrong type · missing · out of range · bad/unhosted repo · unknown tool: refused, nothing ran"

# --- C: each tool runs its script once ----------------------------------------
: > "$LOG"
{
  call 30 status '{}'
  call 31 children '{}'
  call 32 repos '{}'
  call 33 agents '{}'
  call 34 spawn '{"issue":12,"repo":"acme/lib"}'
  call 35 await '{"issue":12,"timeout":60}'
  call 36 send '{"to":"issue:99","text":"hello child"}'
  call 37 send '{"to":"parent","text":"hello parent"}'
} | serve "$WORK/c"
python3 - "$WORK/c" <<'PY' || fail "C: a tool's result is wrong" "$(cat "$WORK/c")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
for i, r in rows.items():
    assert not r.get("isError"), (i, r)
st = rows[30]["structuredContent"]
assert st["window"].startswith("window issue-1807 · issue=1807"), st
assert st["children"]["exit"] == 0 and "1/1" in st["children"]["stdout"], st
assert st["repos"] == ["acme/app", "acme/lib"], st
assert "acme/lib" in rows[30]["content"][0]["text"]
ch = rows[31]["structuredContent"]
assert ch["exit"] == 0 and json.loads(ch["stdout"])["children"][0]["child"] == "issue-99", ch
assert rows[32]["structuredContent"]["repos"] == ["acme/app", "acme/lib"]
agents = rows[33]["structuredContent"]["agents"]
assert {a["key"] for a in agents} == {"issue-1807", "issue-77", "issue-99"}, agents
assert next(a for a in agents if a["key"] == "issue-1807")["is_self"]
assert next(a for a in agents if a["key"] == "issue-77")["is_parent"]
assert next(a for a in agents if a["key"] == "issue-99")["is_child"]
sp = rows[34]["structuredContent"]
assert (sp["command"], sp["exit"]) == ("dash-issue-session.sh", 2), sp           # exit code passes through
assert sp["stdout"] == "spawned issue-12\n" and sp["stderr"] == "cap note\n", sp
assert rows[34]["content"][0]["text"].startswith("exit 2 · dash-issue-session.sh"), rows[34]
aw = rows[35]["structuredContent"]
assert (aw["exit"], aw["stdout"]) == (0, "MERGED #12 pr=42\n"), aw
assert rows[36]["structuredContent"]["receipt"] == "sent -> issue:99 (hello child)", rows[36]
assert rows[37]["structuredContent"]["receipt"] == "sent -> @77 (hello parent)", rows[37]
PY
grep -qx 'dash-issue-session.sh 12 --repo acme/lib' "$LOG" || fail "C: spawn ran the wrong argv" "$(cat "$LOG")"
grep -qx 'fleet-await.sh 12 --timeout 60' "$LOG" || fail "C: await ran the wrong argv" "$(cat "$LOG")"
grep -qx 'fleet-children.sh --json' "$LOG" || fail "C: children did not run fleet-children.sh --json" "$(cat "$LOG")"
grep -qx 'fleet-peer-send.sh issue:99 -' "$LOG" && grep -qx 'fleet-peer-send.sh @77 -' "$LOG" \
  || fail "C: send ran the wrong argv" "$(cat "$LOG")"
[ "$(grep -c '^dash-issue-session.sh' "$LOG")" = 1 ] && [ "$(grep -c '^fleet-await.sh' "$LOG")" = 1 ] \
  || fail "C: a write tool ran more than once" "$(cat "$LOG")"
ok "C status · children · repos · agents · spawn · await · send each ran its script once; exit code + output pass through"

# --- D: degenerate — no hub, every tool available -----------------------------
: > "$LOG"
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
  call 40 spawn '{"issue":3}'
  call 41 await '{"issue":3}'
} | serve "$WORK/d"
python3 - "$WORK/d" <<'PY' || fail "D: with no hub a tool was missing or failed" "$(cat "$WORK/d")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert len(rows[1]["tools"]) == 7, rows[1]
assert rows[40]["structuredContent"]["exit"] == 2 and not rows[40].get("isError"), rows[40]
assert rows[41]["structuredContent"]["exit"] == 0, rows[41]
PY
grep -qx 'fleet-await.sh 3 --timeout 540' "$LOG" || fail "D: await's default timeout is not 540" "$(cat "$LOG")"
ok "D no hub configured: all seven tools listed, spawn/await run locally (await default 540s)"

# --- E: the legacy fleet-peer shim --------------------------------------------
PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 python3 "$WORK/bin/fleet-peer-mcp.py" > "$WORK/e" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"issue:99","text":"hi"}}}
EOF
python3 - "$WORK/e" <<'PY' || fail "E: the fleet-peer shim broke" "$(cat "$WORK/e")"
import json, sys
rows = {r["id"]: r["result"] for r in (json.loads(l) for l in open(sys.argv[1]) if l.strip())}
assert rows[1]["serverInfo"]["name"] == "fleet-peer"
assert {t["name"] for t in rows[2]["tools"]} == {"list_agents", "send_message"}
assert rows[3]["structuredContent"]["delivered"] is True
PY
ok "E fleet-peer-mcp.py still serves list_agents / send_message (one version)"

# --- F: the Codex mount, from the one definition ------------------------------
m=$(python3 "$WORK/bin/fleet-mcp.py" --mount codex) || fail "F: --mount codex failed"
case "$m" in
  'mcp_servers.fleet={command="bash",args=["-c",'*'fleet-mcp.py'*'],env_vars=["TMUX","TMUX_PANE",'*'"FLEET_MCP_BIN"],tool_timeout_sec=600}') : ;;
  *) fail "F: the Codex mount value is wrong" "$m" ;;
esac
python3 - "$WORK/conf/mcp-worker.json" <<'PY' || fail "F: conf/mcp-worker.json is not the one fleet server"
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"mcpServers"} and set(d["mcpServers"]) == {"fleet"}, d
assert "fleet-mcp.py" in " ".join(d["mcpServers"]["fleet"]["args"])
PY
ok "F conf/mcp-worker.json = server \`fleet\` only; --mount codex derives the -c value from it"

printf 'fleet-mcp-selftest: %d passed\n' "$pass"
