#!/bin/bash
# whats-new-selftest.sh — a working session is told, once, at its next turn, what
# changed in the fleet (issue #1897, EPIC #1906 C4).
#
# bin/fleet-whats-new.sh reads a sandbox git history (FLEET_WHATS_NEW_REPO) whose
# commits add a fleet tool, touch a worker skill, touch a guard and change
# internals; the hook runs against an ISOLATED tmux server through a PATH shim.
#   A. brief     — header + the three relevant items + 「另有 N 项内部改动」, ≤ 5 lines
#   B. unrelated — a range of internal commits only: ONE summary line
#   C. overflow  — more relevant changes than fit: still ≤ 5 lines, 「看全部」
#   D. rollback / unknown sha — one line each
#   E. hook      — @agent_ver old, expected ver new: the note as UserPromptSubmit
#                  additionalContext, @ver_told stamped; the next turn says nothing;
#                  the next move is told from @ver_told; no stamps ⇒ baselined
#                  silently; FLEET_WHATS_NEW=0 / no pane ⇒ nothing
#   F. degenerate — no `ver` line expected, or the same version ⇒ no output, no stamp
#   G. Codex     — hooks/settings-hooks.json wires the hook on UserPromptSubmit and
#                  fleet-hooks-emit.sh --target codex carries it
#   H. tool      — fleet-mcp.py lists whats_new and runs `fleet-whats-new.sh --full`
# Drives fleet-whats-new.sh, hooks/settings-hooks.json, fleet-hooks-emit.sh,
# fleet-mcp.py. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WN="$BIN/fleet-whats-new.sh"
command -v python3 >/dev/null 2>&1 || { echo 'whats-new selftest: python3 absent — SKIP'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'whats-new selftest: tmux absent — SKIP'; exit 0; }
command -v git >/dev/null 2>&1 || { echo 'whats-new selftest: git absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/whatsnew-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
S="whatsnew$$"
trap '"$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset TMUX TMUX_PANE FLEET_WHATS_NEW
export FLEET_CONF_DIR="$WORK/conf" FLEET_WHATS_NEW_REPO="$WORK/repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$WORK/conf/global" "$WORK/shim" "$WORK/repo"
EXP="$WORK/conf/global/agent-cfg.expected"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }
lines() { printf '%s\n' "$1" | grep -c .; }

# --- the sandbox history ------------------------------------------------------
g() { git -C "$WORK/repo" "$@"; }
commit() { g add -A && g -c user.name=t -c user.email=t@t commit -q -m "$1" && g rev-parse --short=12 HEAD; }
mcp() {   # mcp <tool names…> — a fleet-mcp.py with that TOOLS table
  mkdir -p "$WORK/repo/bin"
  { printf 'TOOLS = {\n'; for t in "$@"; do printf '    "%s": (tool_%s, {}),\n' "$t" "$t"; done
    printf '}\n\nLEGACY = {\n    "list_agents": (tool_agents, {}),\n}\n'; } > "$WORK/repo/bin/fleet-mcp.py"
}
g init -q
mkdir -p "$WORK/repo/commands" "$WORK/repo/hooks" "$WORK/repo/docs" "$WORK/repo/skills/fleet-open"
mcp status brief
printf '<!-- fleet skill · owner: worker -->\nv1\n' > "$WORK/repo/commands/fleet-claim.md"
printf '<!-- fleet skill · owner: hub -->\nv1\n'    > "$WORK/repo/commands/fleet-epic-run.md"
printf 'v1\n' > "$WORK/repo/hooks/bash-guard.py"
printf 'v1\n' > "$WORK/repo/lib.sh"
V0=$(commit "base")
mcp status brief whats_new; echo whats_new > "$WORK/repo/docs/FLEET-MCP.md"; commit "新工具 whats_new (#1897) (#2001)" >/dev/null
printf 'v2\n' >> "$WORK/repo/commands/fleet-claim.md"; commit "交付前多一步 fleet.evidence after (#1810)" >/dev/null
printf 'v2\n' >> "$WORK/repo/hooks/bash-guard.py";   V3=$(commit "直接敲 fleet-comment.sh 会被记录")
printf 'v2\n' >> "$WORK/repo/lib.sh";                commit "内部一" >/dev/null
printf 'v3\n' >> "$WORK/repo/lib.sh";                commit "内部二" >/dev/null
printf 'v2\n' >> "$WORK/repo/commands/fleet-epic-run.md"; V6=$(commit "hub 技能改了")

# --- A: the brief -------------------------------------------------------------
out=$("$WN" "$V0" "$V6"); rc=$?
eq "A: exit" 0 "$rc" "$out"
has "A: header" "$out" "fleet 已从 ${V0:0:7} 更新到 ${V6:0:7}，和你有关的："
has "A: new tool" "$out" "· 新工具 fleet.whats_new"
has "A: worker skill" "$out" "· 技能 /fleet-claim：交付前多一步 fleet.evidence after"
has "A: guard" "$out" "· 守卫：直接敲 fleet-comment.sh 会被记录"
has "A: the rest counted (two internal + a hub skill)" "$out" "另有 3 项内部改动。"
hasnt "A: the tool's own commit is not listed twice" "$out" "工具："
hasnt "A: PR numbers stripped" "$out" "(#2001)"
hasnt "A: a hub skill is not a worker's" "$out" "fleet-epic-run"
eq "A: five lines" 5 "$(lines "$out")" "$out"

# --- B: internal only → one line ----------------------------------------------
out=$("$WN" "$V3" "$V6")
eq "B: one line" 1 "$(lines "$out")" "$out"
has "B: the summary" "$out" "没有影响执行会话的改动（3 项内部改动）"

# --- C: overflow --------------------------------------------------------------
for i in 1 2 3; do printf 'x%s\n' "$i" >> "$WORK/repo/commands/fleet-claim.md"; commit "技能改动 $i" >/dev/null; done
V9=$(g rev-parse --short=12 HEAD)
out=$("$WN" "$V0" "$V9")
eq "C: five lines" 5 "$(lines "$out")" "$out"
has "C: overflow points at the tool" "$out" "另有 3 项和你有关（fleet.whats_new 看全部）、3 项内部改动。"
full=$("$WN" --full "$V0" "$V9")
eq "C: --full lists all six" 8 "$(lines "$full")" "$full"

# --- D: rollback / an unknown sha ---------------------------------------------
out=$("$WN" "$V6" "$V3")
eq "D: rollback is one line" 1 "$(lines "$out")" "$out"
has "D: rollback" "$out" "退回到 ${V3:0:7}（撤下 3 项改动）"
out=$("$WN" deadbeefcafe "$V3")
has "D: unknown sha" "$out" "看不到变化明细"
"$WN" "$V3" "$V3" >/dev/null; eq "D: same version → exit 1" 1 "$?"

# --- E: the hook on an isolated server ----------------------------------------
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$S" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
"$REAL_TMUX" -L "$S" -f /dev/null new-session -d -s t -n w1 'sleep 600'
"$REAL_TMUX" -L "$S" new-window -d -t t -n w2 'sleep 600'
P1=$("$REAL_TMUX" -L "$S" display-message -p -t t:w1 '#{pane_id}')
P2=$("$REAL_TMUX" -L "$S" display-message -p -t t:w2 '#{pane_id}')
opt() { "$REAL_TMUX" -L "$S" show-options -wqv -t "$1" "$2"; }
hook() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | PATH="$WORK/shim:$PATH" TMUX="x" TMUX_PANE="$1" "$WN" --hook; }
printf 'claude aaa default:x\nver %s\n' "$V6" > "$EXP"
"$REAL_TMUX" -L "$S" set-option -w -t "$P1" @agent_ver "$V0"
out=$(hook "$P1"); rc=$?
eq "E: hook exit" 0 "$rc"
ctx=$(printf '%s' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin)["hookSpecificOutput"]; assert o["hookEventName"]=="UserPromptSubmit"; print(o["additionalContext"])') \
  || fail "E: not a UserPromptSubmit additionalContext" "$out"
has "E: the note" "$ctx" "fleet 已从 ${V0:0:7} 更新到 ${V6:0:7}"
has "E: the tool" "$ctx" "fleet.whats_new"
eq "E: ≤ 5 lines" 5 "$(lines "$ctx")" "$ctx"
eq "E: @ver_told stamped" "$V6" "$(opt "$P1" @ver_told)"
eq "E: the next turn says nothing" "" "$(hook "$P1")"
printf 'claude aaa default:x\nver %s\n' "$V9" > "$EXP"
out=$(hook "$P1")
has "E: the next move is told from @ver_told" "$out" "fleet 已从 ${V6:0:7} 更新到 ${V9:0:7}"
eq "E: …and stamped" "$V9" "$(opt "$P1" @ver_told)"
eq "E: no stamps → nothing said" "" "$(hook "$P2")"
eq "E: …but baselined" "$V9" "$(opt "$P2" @ver_told)"
"$REAL_TMUX" -L "$S" set-option -wu -t "$P1" @ver_told
eq "E: FLEET_WHATS_NEW=0 → nothing" "" "$(FLEET_WHATS_NEW=0 hook "$P1")"
eq "E: …and no stamp" "" "$(opt "$P1" @ver_told)"
eq "E: no pane → nothing" "" "$(hook "")"

# --- F: degenerate ------------------------------------------------------------
printf 'claude aaa default:x\ncodex bbb default:y\n' > "$EXP"
eq "F: no ver expected → nothing" "" "$(hook "$P1")"
eq "F: …no stamp" "" "$(opt "$P1" @ver_told)"
rm -f "$EXP"
eq "F: no expected file → nothing" "" "$(hook "$P1")"
printf 'ver %s\n' "$V0" > "$EXP"
eq "F: the same version → nothing" "" "$(hook "$P1")"
eq "F: …no stamp" "" "$(opt "$P1" @ver_told)"

# --- G: wired for Claude and Codex --------------------------------------------
SRC="$BIN/../hooks/settings-hooks.json"
python3 - "$SRC" <<'PY' || fail "G: settings-hooks.json does not run fleet-whats-new.sh --hook on UserPromptSubmit"
import json, sys
cmds = [h["command"] for b in json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"] for h in b["hooks"]]
assert any(c.endswith("bin/fleet-whats-new.sh --hook") for c in cmds), cmds
PY
CHECKS=$((CHECKS+1))
cdx=$("$BIN/fleet-hooks-emit.sh" --target codex --event UserPromptSubmit 2>&1) || fail "G: codex emit failed" "$cdx"
has "G: Codex carries it" "$cdx" "fleet-whats-new.sh' --hook"

# --- H: the tool --------------------------------------------------------------
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"whats_new\",\"arguments\":{\"from\":\"$V0\",\"to\":\"$V6\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"whats_new\",\"arguments\":{\"to\":\"$V6\"}}}" \
  | env -u FLEET_WORKER_CRED FLEET_MCP_RELOAD=0 PATH="$WORK/shim:$PATH" TMUX=x TMUX_PANE="$P1" \
    python3 "$BIN/fleet-mcp.py" > "$WORK/mcp.out" 2>/dev/null
python3 - "$V0" "$WORK/mcp.out" <<'PY' || fail "H: whats_new tool" "$(cat "$WORK/mcp.out")"
import json, sys
rows = {r["id"]: r for r in (json.loads(l) for l in open(sys.argv[2]) if l.strip())}
assert "whats_new" in {t["name"] for t in rows[1]["result"]["tools"]}
r = rows[2]["result"]
assert r["structuredContent"]["exit"] == 0, r
text = r["content"][0]["text"]
assert "fleet 已从 %s" % sys.argv[1][:7] in text and "fleet.whats_new" in text, text
assert rows[3]["result"].get("isError"), rows[3]          # to without from is refused
PY
CHECKS=$((CHECKS+1))

echo "whats-new-selftest: PASS ($CHECKS checks)"
