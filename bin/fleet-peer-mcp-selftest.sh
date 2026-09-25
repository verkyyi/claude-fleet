#!/bin/sh
# fleet-peer-mcp-selftest.sh — fleet-peer stdio MCP contract (issue #1185).
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
SUT="$BIN/fleet-peer-mcp.py"
[ -f "$SUT" ] || { echo "selftest: fleet-peer-mcp.py missing" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-peer-mcp.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$WORK/bin"
cp "$SUT" "$WORK/bin/fleet-peer-mcp.py"
cat > "$WORK/bin/fleet-lib.sh" <<'SH'
fleet_origin_key() { printf 'issue-1185'; }
_fleet_hosts_many() { return 1; }
fleet_win_for_key() { [ "$1" = issue-77 ] && printf '@77'; }
SH
cat > "$WORK/bin/fleet-children.sh" <<'SH'
#!/bin/sh
printf '%s\n' '{"children":[{"child":"issue-99"}]}'
SH
cat > "$WORK/bin/fleet-peer-send.sh" <<'SH'
#!/bin/sh
target=$1; mode=$2; text=$(cat)
[ "$mode" = "-" ] || exit 2
[ "$target" = issue:99 ] || [ "$target" = @77 ] || { echo "bad target $target" >&2; exit 1; }
printf 'sent -> %s (%s)\n' "$target" "$text"
SH
chmod +x "$WORK/bin/fleet-children.sh" "$WORK/bin/fleet-peer-send.sh"

cat > "$WORK/tmux" <<'SH'
#!/bin/sh
if [ "$1" = display-message ]; then
  case "$*" in
    *session_name*) printf 'tf\n' ;;
    *'#{@origin}'*) printf 'issue-77\n' ;;
  esac
  exit 0
fi
if [ "$1" = list-windows ]; then
  printf '@1\ttf\tissue-1185\t1185\tcodex\tworking\t\tissue-77\t\t\t/tmp/repo-issue-1185\t/tmp/repo-issue-1185\n'
  printf '@2\ttf\tissue-77\t77\t\tidle\t\t\t\t\t/tmp/repo-issue-77\t/tmp/repo-issue-77\n'
  printf '@3\ttf\tissue-99\t99\t\tidle\t\tissue-1185\t\t\t/tmp/repo-issue-99\t/tmp/repo-issue-99\n'
  printf '@4\ttf\tdash\t\t\tidle\t\t\t\t\t/tmp\t/tmp\n'
  exit 0
fi
exit 1
SH
chmod +x "$WORK/tmux"

PATH="$WORK:$PATH" TMUX=1 TMUX_PANE=%1 python3 "$WORK/bin/fleet-peer-mcp.py" > "$WORK/out" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_agents","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"issue:99","text":"hello child"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"parent","text":"hello parent"}}}
EOF

python3 - "$WORK/out" <<'PY'
import json, sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert rows[0]["result"]["serverInfo"]["name"] == "fleet-peer"
tools={t["name"] for t in rows[1]["result"]["tools"]}
assert tools == {"list_agents", "send_message"}, tools
agents=rows[2]["result"]["structuredContent"]["agents"]
me=next(a for a in agents if a["issue"] == 1185)
parent=next(a for a in agents if a["issue"] == 77)
child=next(a for a in agents if a["issue"] == 99)
assert me["agent"] == "codex" and me["is_self"]
assert parent["is_parent"]
assert child["is_child"]
assert rows[3]["result"]["structuredContent"]["receipt"].startswith("sent -> issue:99")
assert rows[4]["result"]["structuredContent"]["receipt"].startswith("sent -> @77")
PY

printf 'fleet-peer-mcp-selftest OK\n'
