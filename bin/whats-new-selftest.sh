#!/bin/bash
# whats-new-selftest.sh — changes are available on demand, never injected into
# a conversation (issue #4324; summary behaviour from #1897, EPIC #1906 C4).
#
# bin/fleet-whats-new.sh reads a sandbox git history (FLEET_WHATS_NEW_REPO) whose
# commits add a fleet tool, touch a worker skill, touch a guard and change
# internals; the hook runs against an ISOLATED tmux server through a PATH shim.
#   A. brief     — header + the three relevant items + 「另有 N 项内部改动」, ≤ 5 lines
#   B. unrelated — a range of internal commits only: ONE summary line
#   C. overflow  — more relevant changes than fit: still ≤ 5 lines, 「看全部」
#   D. rollback / unknown sha — one line each
#   E. full      — --full reads the session's launch version and the expected one
#   F. degenerate — no `ver` line expected, or the same version ⇒ no output, no stamp
#   G. wiring    — Claude and Codex carry no whats-new hook; where/refocus stay
#   H. tool      — fleet-mcp.py lists whats_new and runs `fleet-whats-new.sh --full`
#   I. install   — fresh sandbox HOME defaults + hook merge: whats-new absent,
#                  where/refocus present; upgrade preserves personal settings/hooks
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
unset TMUX TMUX_PANE
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
mkdir -p "$WORK/repo/commands" "$WORK/repo/hooks" "$WORK/repo/docs/dev" "$WORK/repo/skills/fleet-open"
mcp status brief
printf '<!-- fleet skill · owner: worker -->\nv1\n' > "$WORK/repo/commands/fleet-claim.md"
printf '<!-- fleet skill · owner: hub -->\nv1\n'    > "$WORK/repo/commands/fleet-epic-run.md"
printf 'v1\n' > "$WORK/repo/hooks/bash-guard.py"
printf 'v1\n' > "$WORK/repo/lib.sh"
V0=$(commit "base")
mcp status brief whats_new; echo whats_new > "$WORK/repo/docs/dev/FLEET-MCP.md"; commit "新工具 whats_new (#1897) (#2001)" >/dev/null
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

# --- E: --full on an isolated server -------------------------------------------
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$S" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
"$REAL_TMUX" -L "$S" -f /dev/null new-session -d -s t -n w1 'sleep 600'
P1=$("$REAL_TMUX" -L "$S" display-message -p -t t:w1 '#{pane_id}')
opt() { "$REAL_TMUX" -L "$S" show-options -wqv -t "$1" "$2"; }
printf 'claude aaa default:x\nver %s\n' "$V6" > "$EXP"
"$REAL_TMUX" -L "$S" set-option -w -t "$P1" @agent_ver "$V0"
out=$(PATH="$WORK/shim:$PATH" TMUX=x TMUX_PANE="$P1" "$WN" --full)
has "E: on-demand full output reads launch/expected versions" "$out" "fleet 已从 ${V0:0:7} 更新到 ${V6:0:7}"

# --- F: degenerate ------------------------------------------------------------
printf 'claude aaa default:x\ncodex bbb default:y\n' > "$EXP"
eq "F: no ver expected → nothing" "" "$(hook "$P1")"
eq "F: …no stamp" "" "$(opt "$P1" @ver_told)"
rm -f "$EXP"
eq "F: no expected file → nothing" "" "$(hook "$P1")"
printf 'ver %s\n' "$V0" > "$EXP"
eq "F: the same version → nothing" "" "$(hook "$P1")"
eq "F: …no stamp" "" "$(opt "$P1" @ver_told)"

# --- G: no injection for Claude or Codex --------------------------------------
SRC="$BIN/../hooks/settings-hooks.json"
python3 - "$SRC" <<'PY' || fail "G: hook table removed whats-new but must preserve where/refocus"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
cmds = [h["command"] for groups in hooks.values() for b in groups for h in b["hooks"]]
assert not any("fleet-whats-new.sh" in c for c in cmds), cmds
assert any("fleet-where-hook.sh" in h["command"] for b in hooks["SessionStart"] for h in b["hooks"])
assert any("refocus-hook.sh" in h["command"] for b in hooks["SessionStart"] if b.get("matcher") == "compact" for h in b["hooks"])
PY
CHECKS=$((CHECKS+1))
cdx=$("$BIN/fleet-hooks-emit.sh" --target codex 2>&1) || fail "G: codex emit failed" "$cdx"
hasnt "G: Codex carries no whats-new hook" "$cdx" "fleet-whats-new.sh"
has "G: Codex keeps device context" "$cdx" "fleet-where-hook.sh"
has "G: Codex keeps compact refocus" "$cdx" "refocus-hook.sh"

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

# --- I: the default install in a fresh HOME, then an existing login ------------
python3 - "$BIN" "$WORK" <<'PY' || fail "I: sandbox default install / upgrade"
import json, os, pathlib, subprocess, sys

bin_dir, work = map(pathlib.Path, sys.argv[1:])
home = work / "home"
(home / ".claude").mkdir(parents=True)
settings = home / ".claude/settings.json"
config = home / ".claude.json"
config.write_text("{}\n")
env = dict(os.environ, HOME=str(home), CLAUDE_CONFIG_DIR=str(home / ".claude"))

def install():
    for args in [("defaults", "--config", str(config)), ("merge",)]:
        subprocess.run([sys.executable, str(bin_dir / "fleet-hooks-merge.py"), *args],
                       env=env, check=True, stdout=subprocess.DEVNULL)
    return json.loads(settings.read_text())

def commands(data):
    return [h["command"] for groups in data["hooks"].values() for g in groups for h in g["hooks"]]

fresh = install()
cmds = commands(fresh)
assert not any("fleet-whats-new.sh" in c for c in cmds), cmds
for name in ("fleet-where-hook.sh", "refocus-hook.sh"):
    assert sum(name in c for c in cmds) == 1, cmds
print("  sandbox install: whats-new=0 where=1 refocus=1")

# Simulate a login with the old managed hook and personal settings/hook.
personal = {"type": "command", "command": "echo personal"}
fresh["hooks"]["UserPromptSubmit"][0]["hooks"].append(personal)
fresh["theme"] = "dark"
expected = json.loads(json.dumps(fresh))
fresh["hooks"]["UserPromptSubmit"][0]["hooks"].append(
    {"type": "command", "command": "bash ~/.claude/fleet/bin/fleet-whats-new.sh --hook"})
settings.write_text(json.dumps(fresh))
upgraded = install()
assert upgraded == expected, upgraded
print("  sandbox upgrade: retired hook removed; other hooks/order and personal settings preserved")
PY
CHECKS=$((CHECKS+1))

echo "whats-new-selftest: PASS ($CHECKS checks)"
