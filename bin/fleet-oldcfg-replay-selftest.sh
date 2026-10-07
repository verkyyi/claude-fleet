#!/bin/bash
# fleet-oldcfg-replay-selftest.sh — bin/fleet-oldcfg-replay.py, the release gate that
# replays an OLD session's start (stable's hook table, the mod's tool list, the MCP
# servers) against the NEW tree (issue #2075, EPIC #2074 C2).
#
# Hermetic: a temp git repo with its own hook table, hook scripts, a tools.ts, an
# mcp-worker.json and a fake fleet-mcp.py stands in for the fleet; `stable` is a tag
# on it. Nothing real is read, nothing on the machine is touched.
#
#   A  degenerate: old == new ⇒ GREEN at once (under 2s), nothing run
#   B  green: a commit that changes nothing an old session uses ⇒ GREEN, every hook /
#      tool / server reported ok, the counts right
#   C  a hook script deleted ⇒ RED naming the script and its event; restored ⇒ GREEN
#   D  a mod tool's handler dropped (TOOL_RE) ⇒ RED naming the tool; restored ⇒ GREEN
#   E  an MCP tool dropped from the server ⇒ RED naming server.tool; a forward the
#      service no longer knows (exit 2) is still an answer; restored ⇒ GREEN
#   F  a hook that exits non-zero ⇒ RED (ERROR, exit code, BLOCK for 2); one that
#      hangs ⇒ RED (TIMEOUT) under --timeout; restored ⇒ GREEN
#   G  --new-dir: the working tree is what is replayed (an uncommitted deletion is red)
#   H  --json: one object with items + verdict; -q: findings and the last line only
#   I  the sandbox: a hook sees the replay's HOME / FLEET_CONF_DIR and a tmux that
#      fails — never the caller's
#   J  this repo's own table against itself (old = HEAD, new = the live tree): every
#      hook, the mod's fallback tools and the fleet server replay GREEN — a hook that
#      cannot run in the sandbox is red HERE, on the PR, not at the operator's release
#   K  the real thing when the `stable` tag is here (not in CI's tagless checkout):
#      stable → HEAD must be GREEN — the red the next release would hit
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-oldcfg-replay.py"
[ -f "$SUT" ] || { printf 'selftest: %s not found\n' "$SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "fleet-oldcfg-replay-selftest SKIP (no git)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "fleet-oldcfg-replay-selftest SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oldcfg-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]" "${4:-}"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]" "$2";; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output contains [$3]" "$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# ---------------------------------------------------------------- the rig ------
REPO="$WORK/repo"
git init -q -b master "$REPO"
mkdir -p "$REPO/hooks" "$REPO/bin" "$REPO/conf" "$REPO/mod/fleet/hooks"
cat > "$REPO/hooks/settings-hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "sh ~/.claude/fleet/bin/h-start.sh" } ] },
      { "matcher": "compact", "hooks": [ { "type": "command", "command": "sh ~/.claude/fleet/bin/h-env.sh $WORK/env.out" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "python3 ~/.claude/fleet/hooks/g-bash.py" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "sh ~/.claude/fleet/bin/h-stop.sh" } ] }
    ],
    "SessionEnd": [
      { "matcher": "prompt_input_exit|logout", "hooks": [ { "type": "command", "command": "bash ~/.claude/fleet/bin/h-end.sh" } ] }
    ]
  }
}
EOF
# Each hook checks it was handed the event Claude Code would hand it.
printf '#!/bin/sh\ngrep -q "\\"hook_event_name\\": *\\"SessionStart\\"" || exit 9\nexit 0\n' > "$REPO/bin/h-start.sh"
# shellcheck disable=SC2016  # the single quotes write a script; its $HOME expands when the hook runs
printf '#!/bin/sh\ncat >/dev/null\nprintf "HOME=%%s CONF=%%s TMUX=%%s\\n" "$HOME" "$FLEET_CONF_DIR" "$(tmux ls 2>&1)" > "$1"\nexit 0\n' > "$REPO/bin/h-env.sh"
printf 'import json, sys\ne = json.load(sys.stdin)\nassert e["hook_event_name"] == "PreToolUse" and e["tool_name"] == "Bash" and e["tool_input"]["command"], e\n' > "$REPO/hooks/g-bash.py"
printf '#!/bin/sh\ngrep -q "\\"stop_hook_active\\"" || exit 9\nexit 0\n' > "$REPO/bin/h-stop.sh"
printf '#!/bin/bash\ngrep -q "\\"reason\\": *\\"prompt_input_exit\\"" || exit 9\nexit 0\n' > "$REPO/bin/h-end.sh"
cat > "$REPO/mod/fleet/hooks/tools.ts" <<'EOF'
export const FALLBACK = ['status', 'spawn', 'await'] as const
export const TOOL_RE = /^mcp__fleet__fleet_(status|spawn|await)$/
EOF
cat > "$REPO/conf/mcp-worker.json" <<'EOF'
{ "mcpServers": { "fleet": { "command": "bash", "args": [ "-c", "exec python3 \"${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py\"" ] } } }
EOF
# The fake service: tools/list over stdio, --call <tool> (exit 2 for one it does not know).
cat > "$REPO/bin/fleet-mcp.py" <<'EOF'
import json, sys
TOOLS = ["status", "spawn", "await", "brief"]
if sys.argv[1:2] == ["--call"]:
    known = sys.argv[2] in TOOLS
    print("ok %s" % sys.argv[2] if known else "fleet-mcp: unknown tool %s" % sys.argv[2])
    sys.exit(0 if known else 2)
for line in sys.stdin:
    if not line.strip():
        continue
    m = json.loads(line)
    if "id" not in m:
        continue
    if m["method"] == "initialize":
        r = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "0"}}
    elif m["method"] == "tools/list":
        r = {"tools": [{"name": t, "description": t, "inputSchema": {"type": "object"}} for t in TOOLS]}
    else:
        r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
EOF
chmod +x "$REPO"/bin/*.sh
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1" && git -C "$REPO" rev-parse HEAD; }
restore() { git -C "$REPO" checkout -q stable -- "$1"; }
S=$(commit stable); git -C "$REPO" tag stable "$S"
run() { OUT=$(python3 "$SUT" --dir "$REPO" "$@" 2>&1); RC=$?; }
secs() { python3 -c 'import time; print(int(time.time()))'; }

# --- A. degenerate ----------------------------------------------------------------
t0=$(secs)
run --old stable --new stable
eq "A: old == new exits 0" 0 "$RC" "$OUT"
contains "A: says nothing changed" "$OUT" "nothing changed, GREEN"
lacks "A: runs nothing" "$OUT" "hook  ok"
[ $(( $(secs) - t0 )) -le 2 ] || fail "A: the degenerate case took more than 2s"

# --- B. green ---------------------------------------------------------------------
printf 'x\n' > "$REPO/bin/new-thing.sh"; N1=$(commit "a new script nobody old calls")
run --old stable --new "$N1"
eq "B: a harmless release is GREEN" 0 "$RC" "$OUT"
contains "B: summary line" "$OUT" "oldcfg-replay: GREEN — 5 hook(s) · 3 mod tool(s) · 1 MCP server(s) replayed"
contains "B: SessionStart hook ok" "$OUT" "hook  ok       SessionStart                 sh ~/.claude/fleet/bin/h-start.sh"
contains "B: matcher hook ok" "$OUT" "hook  ok       PreToolUse[Bash]             python3 ~/.claude/fleet/hooks/g-bash.py"
contains "B: SessionEnd matcher ok" "$OUT" "hook  ok       SessionEnd[prompt_input_exit|logout]"
contains "B: mod tool forwarded" "$OUT" "tool  ok       mcp__fleet__fleet_status     handler in mod/fleet/hooks/tools.ts → fleet-mcp.py --call status: exit 0, answered"
contains "B: mcp server listed" "$OUT" "mcp   ok       fleet                        4 tool(s) of the old server still listed by the new"
contains "B: old named" "$OUT" "old=${S:0:8} 「stable」"
contains "B: new named" "$OUT" "new=${N1:0:8} 「a new script nobody old calls」"

# --- C. a hook script deleted ----------------------------------------------------------
git -C "$REPO" rm -q bin/h-stop.sh; N2=$(commit "drop h-stop.sh")
run --old stable --new "$N2"
eq "C: a deleted hook script is RED" 1 "$RC" "$OUT"
contains "C: names the event and the script" "$OUT" "hook  MISSING  Stop                         sh ~/.claude/fleet/bin/h-stop.sh — bin/h-stop.sh not in the new tree"
contains "C: summary RED, one finding" "$OUT" "oldcfg-replay: RED — 1 finding(s): an old session of ${S:0:8} would break on ${N2:0:8}"
restore bin/h-stop.sh; N3=$(commit "h-stop.sh back")
run --old stable --new "$N3"
eq "C: restored ⇒ GREEN" 0 "$RC" "$OUT"

# --- D. a mod tool's handler dropped ---------------------------------------------------
sed -i.bak 's/(status|spawn|await)/(spawn|await)/' "$REPO/mod/fleet/hooks/tools.ts"; rm -f "$REPO/mod/fleet/hooks/tools.ts.bak"
N4=$(commit "drop the status handler")
run --old stable --new "$N4"
eq "D: a dropped handler is RED" 1 "$RC" "$OUT"
contains "D: names the tool" "$OUT" "tool  MISSING  mcp__fleet__fleet_status     no tool.call handler in the new mod/fleet/hooks/tools.ts (TOOL_RE)"
contains "D: the other two still ok" "$OUT" "tool  ok       mcp__fleet__fleet_spawn"
contains "D: one finding" "$OUT" "RED — 1 finding(s)"
git -C "$REPO" rm -q mod/fleet/hooks/tools.ts; N4b=$(commit "no tools.ts at all")
run --old stable --new "$N4b"
eq "D: tools.ts gone ⇒ RED" 1 "$RC" "$OUT"
contains "D: every old tool named" "$OUT" "RED — 3 finding(s)"
restore mod/fleet/hooks/tools.ts; N5=$(commit "tools.ts back")
run --old stable --new "$N5"
eq "D: restored ⇒ GREEN" 0 "$RC" "$OUT"

# --- E. an MCP tool dropped; a forward the service no longer knows -------------------------
sed -i.bak 's/"await", "brief"\]/"await"]/' "$REPO/bin/fleet-mcp.py"; rm -f "$REPO/bin/fleet-mcp.py.bak"
N6=$(commit "drop brief from the service")
run --old stable --new "$N6"
eq "E: a dropped service tool is RED" 1 "$RC" "$OUT"
contains "E: names server.tool" "$OUT" "mcp   MISSING  fleet.brief                  the new server does not list it"
contains "E: one finding" "$OUT" "RED — 1 finding(s)"
sed -i.bak 's/"spawn", "await"\]/"spawn"]/' "$REPO/bin/fleet-mcp.py"; rm -f "$REPO/bin/fleet-mcp.py.bak"
N6b=$(commit "drop await too")
run --old stable --new "$N6b"
contains "E: a forward the service refuses with exit 2 is still an answer" "$OUT" "tool  ok       mcp__fleet__fleet_await      handler in mod/fleet/hooks/tools.ts → fleet-mcp.py --call await: exit 2, the mod answers «reopen the session»"
contains "E: but the service's own list is red for both" "$OUT" "mcp   MISSING  fleet.await"
contains "E: two findings" "$OUT" "RED — 2 finding(s)"
restore bin/fleet-mcp.py; N7=$(commit "service back")
run --old stable --new "$N7"
eq "E: restored ⇒ GREEN" 0 "$RC" "$OUT"

# --- F. a hook that errors, a hook that hangs -----------------------------------------
printf '#!/bin/sh\necho "no such fleet" >&2\nexit 3\n' > "$REPO/bin/h-stop.sh"; N8=$(commit "h-stop errors")
run --old stable --new "$N8"
eq "F: a failing hook is RED" 1 "$RC" "$OUT"
contains "F: ERROR with the exit code and stderr" "$OUT" "hook  ERROR    Stop                         sh ~/.claude/fleet/bin/h-stop.sh — exit 3 (a hook error, every turn): no such fleet"
printf '#!/bin/sh\nexit 2\n' > "$REPO/bin/h-stop.sh"; N8b=$(commit "h-stop blocks")
run --old stable --new "$N8b"
contains "F: exit 2 is named a BLOCK" "$OUT" "exit 2 (BLOCKS the call)"
printf '#!/bin/sh\nsleep 30\n' > "$REPO/bin/h-stop.sh"; N9=$(commit "h-stop hangs")
run --old stable --new "$N9" --timeout 1
eq "F: a hanging hook is RED" 1 "$RC" "$OUT"
contains "F: TIMEOUT named" "$OUT" "hook  TIMEOUT  Stop                         sh ~/.claude/fleet/bin/h-stop.sh — no answer within 1.0s"
restore bin/h-stop.sh; N10=$(commit "h-stop back")
run --old stable --new "$N10"
eq "F: restored ⇒ GREEN" 0 "$RC" "$OUT"

# --- G. --new-dir: the working tree ----------------------------------------------------
rm "$REPO/bin/h-end.sh"
run --old stable --new-dir "$REPO"
eq "G: an uncommitted deletion is RED" 1 "$RC" "$OUT"
contains "G: names it" "$OUT" "hook  MISSING  SessionEnd[prompt_input_exit|logout] bash ~/.claude/fleet/bin/h-end.sh — bin/h-end.sh not in the new tree"
contains "G: the dir is the new side" "$OUT" "new=$REPO"
git -C "$REPO" checkout -q -- bin/h-end.sh
run --old stable --new-dir "$REPO"
eq "G: back ⇒ GREEN" 0 "$RC" "$OUT"

# --- H. --json and -q ----------------------------------------------------------------------
run --old stable --new "$N10" --json
eq "H: --json exits 0" 0 "$RC" "$OUT"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "GREEN" and d["findings"] == 0, d
assert d["counts"] == {"hook": 5, "tool": 3, "mcp": 1}, d["counts"]
kinds = sorted(set(i["kind"] for i in d["items"]))
assert kinds == ["hook", "mcp", "tool"], kinds
assert all(i["verdict"] in ("ok", "none") for i in d["items"]), d["items"]
assert d["old"]["sha"] and d["new"]["sha"], d
' || fail "H: the JSON shape is wrong" "$OUT"
run --old stable --new "$N2" --json
eq "H: --json exits 1 on a finding" 1 "$RC" "$OUT"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "RED" and d["findings"] == 1, d
f = [i for i in d["items"] if i["verdict"] == "MISSING"]
assert len(f) == 1 and f[0]["kind"] == "hook" and f[0]["name"] == "Stop" and "bin/h-stop.sh" in f[0]["detail"], f
' || fail "H: the RED JSON shape is wrong" "$OUT"
run --old stable --new "$N10" -q
eq "H: -q on green prints the header and the summary only" 2 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "$OUT"
run --old stable --new "$N2" -q
eq "H: -q on red prints header, finding, summary" 3 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "$OUT"
contains "H: -q keeps the finding" "$OUT" "hook  MISSING  Stop"

# --- I. the sandbox ---------------------------------------------------------------------
rm -f "$WORK/env.out"
run --old stable --new "$N10"
[ -f "$WORK/env.out" ] || fail "I: the compact SessionStart hook did not run" "$OUT"
ENV_OUT=$(cat "$WORK/env.out")
lacks "I: HOME is not the caller's" "$ENV_OUT" "HOME=$HOME "
contains "I: HOME is the replay's" "$ENV_OUT" "HOME=/"; contains "I: HOME is under the replay work dir" "$ENV_OUT" "oldcfg-replay."
contains "I: FLEET_CONF_DIR is the replay's" "$ENV_OUT" "CONF=/"; lacks "I: not the caller's conf" "$ENV_OUT" "CONF=${FLEET_CONF_DIR:-/nonesuch} "
contains "I: tmux is shimmed to fail" "$ENV_OUT" "tmux: not available in the oldcfg replay sandbox"

# --- J. this repo's own table, replayed against its own live tree ----------------------------
REAL=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SUT")
RROOT=$(git -C "$(dirname "$REAL")" rev-parse --show-toplevel 2>/dev/null) || RROOT=""
ROOT="$(cd "$BIN/.." && pwd)"
if [ -z "$RROOT" ] || [ ! -f "$ROOT/hooks/settings-hooks.json" ]; then
  printf 'skip J: no git checkout behind %s (or no hooks/settings-hooks.json beside bin/)\n' "$SUT"
else
  OUT=$(python3 "$SUT" --dir "$RROOT" --old HEAD --new-dir "$ROOT" 2>&1); RC=$?
  eq "J: the repo's own hook table replays GREEN against its own tree" 0 "$RC" "$OUT"
  contains "J: the real mod's fallback tools are read and forwarded" "$OUT" "tool  ok       mcp__fleet__fleet_status     handler in mod/fleet/hooks/tools.ts → fleet-mcp.py --call status"
  contains "J: the real fleet server lists its tools" "$OUT" "mcp   ok       fleet "
  n=$(printf '%s\n' "$OUT" | grep -c '^hook  ok ')
  [ "$n" -ge 15 ] || fail "J: only $n hooks replayed — the real table has more" "$OUT"
  lacks "J: no hook of the real table is red" "$OUT" "hook  ERROR"
  lacks "J: no hook of the real table hangs" "$OUT" "hook  TIMEOUT"
fi

# --- K. stable → HEAD, when the tag is here ------------------------------------------
if [ -n "$RROOT" ] && git -C "$RROOT" rev-parse -q --verify 'refs/tags/stable^{commit}' >/dev/null 2>&1; then
  OUT=$(python3 "$SUT" --dir "$RROOT" --old stable --new HEAD -q 2>&1); RC=$?
  eq "K: an old session of the current stable runs on HEAD (what the next release gates on)" 0 "$RC" "$OUT"
else
  printf 'skip K: no refs/tags/stable in this checkout (git fetch origin +refs/tags/stable:refs/tags/stable)\n'
fi

printf 'fleet-oldcfg-replay-selftest OK (%d checks)\n' "$CHECKS"
