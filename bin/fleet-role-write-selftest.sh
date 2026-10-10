#!/bin/bash
# fleet-role-write-selftest.sh — say one sentence, the person's layer changes
# (issue #2785, EPIC #2781 C4). The fleet-config skill turns a sentence into one
# bin/fleet-role.py write — set · unset · rule-set · rule-unset · undo — which
# reads the person's layer from the hub (bin/fleet-config.py's client, its
# FLEET_PERSON_HUB_CMD seam), makes the smallest change, says 改前 → 改后 per
# item, and PUTs it (base = the version read) only with --yes.
#
#   A  the six sentences of the issue, replayed: 换模型 · 加外接工具 · 减工具 ·
#      加一段说明 · 改规则档 · 撤回 — each the expected minimal change on the hub,
#      one new version each, the 「已改 … （入口 vN）」 line and the effect line
#   B  without --yes nothing is written (exit 4) and the lines say 改 … → …
#   C  a worker's window (@fleet_role worker, a PATH-shim tmux) is refused:
#      exit 3, nothing written; show / rules still answer there
#   D  a token in the sentence is refused before sending: exit 2, the wrapper-
#      script hint, nothing written
#   E  a 409 (written elsewhere meanwhile) re-reads and redoes it once; a change
#      that moves nothing on the merged definition writes nothing
#   F  the cache takes the hub's answer at once: `show --sources` says 你的 vN
#   G  rule-set new numbers from 100; a number no layer has is refused
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
R="$BIN/fleet-role.py"
PY=python3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/role-write-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
mkdir -p "$WORK/hub" "$WORK/conf" "$WORK/home" "$WORK/shim"

# the fake hub: the person's versions in $WORK/hub/p.json; `hub M Q` answers
# {"status": N, …} as /v1/fleet/person-bundle does (?version=N, {restore, base})
cat > "$WORK/fakehub.py" <<'EOF'
import json, os, sys
d = os.environ["HUBDIR"]; f = os.path.join(d, "p.json")
st = json.load(open(f)) if os.path.exists(f) else {"versions": []}
def cur():
    return st["versions"][-1] if st["versions"] else {"version": 0, "prev": 0, "bundle": {}}
m = sys.argv[1]; q = sys.argv[2] if len(sys.argv) > 2 else ""
if m == "GET":
    if q.startswith("version="):
        old = [v for v in st["versions"] if v["version"] == int(q[8:])]
        print(json.dumps(dict(old[0], status=200) if old else {"status": 404, "error": "no version"})); sys.exit(0)
    print(json.dumps(dict(cur(), status=200))); sys.exit(0)
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
    b = [v for v in st["versions"] if v["version"] == body["restore"]][0]["bundle"]
else:
    b = body["bundle"]
n = {"version": c["version"] + 1, "prev": c["version"], "bundle": b, "actor": "me", "note": body.get("note", "")}
st["versions"].append(n); json.dump(st, open(f, "w"))
print(json.dumps(dict(n, status=200)))
EOF
HUBCMD="HUBDIR='$WORK/hub' '$PY' '$WORK/fakehub.py'"
# the window's @fleet_role, as tmux would answer it
cat > "$WORK/shim/tmux" <<'EOF'
#!/bin/sh
cat "$ROLEFILE" 2>/dev/null
EOF
chmod +x "$WORK/shim/tmux"

role() {   # role <args…> — sandboxed, outside any window
  env -i PATH="$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" \
    FLEET_PERSON_HUB_CMD="$HUBCMD \"\$@\"" "$PY" "$R" "$@" 2>&1
}
inwin() {  # inwin <@fleet_role> <args…> — inside a fleet window
  local seat=$1; shift
  printf '%s\n' "$seat" > "$WORK/rolefile"
  env -i PATH="$WORK/shim:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" TMUX=/tmp/x,1,0 TMUX_PANE=%9 \
    ROLEFILE="$WORK/rolefile" FLEET_PERSON_HUB_CMD="$HUBCMD \"\$@\"" "$PY" "$R" "$@" 2>&1
}
ver() { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["versions"][-1]["version"] if s["versions"] else 0)' "$WORK/hub/p.json" 2>/dev/null || echo 0; }
pb()  { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); b=s["versions"][-1]["bundle"]
for k in sys.argv[2].split("."):
    b = b.get(k) if isinstance(b, dict) else None
print(json.dumps(b, ensure_ascii=False, sort_keys=True))' "$WORK/hub/p.json" "$1" 2>/dev/null; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

# ── B — a preview writes nothing ─────────────────────────────────────────────
out=$(role set steward model sonnet); rc=$?
{ [ $rc = 4 ] && [ "$(ver)" = 0 ] && has "$out" '改 管家 · 模型：opus → sonnet' && has "$out" '--yes'; } \
  && ok "B no --yes: exit 4, the 改前 → 改后 line, nothing on the hub" || bad "B preview: rc=$rc v=$(ver) $out"

# ── A — the six sentences ────────────────────────────────────────────────────
# 1 换模型 「管家换成 sonnet」
out=$(role set steward model sonnet --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 1 ] && [ "$(pb roles.steward.front)" = '{"model": "sonnet"}' ] \
  && has "$out" '已改 管家 · 模型：opus → sonnet（入口 v1）' && has "$out" '重开管家'; } \
  && ok "A1 换模型: roles.steward.front = {model: sonnet}, v1" || bad "A1: rc=$rc $(pb roles) $out"
# 2 加外接工具 「编排会话加上企微存档」 — the name, its command, the env var's NAME
out=$(role set orchestrator mcpServers wecom '{"command": "/opt/fleet/wecom-mcp.sh", "env": {"WECOM_TOKEN": "${WECOM_TOKEN}"}}' --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 2 ] && has "$(pb roles.orchestrator.front.mcpServers.wecom)" '"command": "/opt/fleet/wecom-mcp.sh"' \
  && [ "$(pb roles.steward.front)" = '{"model": "sonnet"}' ] && has "$out" '外接工具：fleet → fleet、wecom（内联）'; } \
  && ok "A2 加外接工具: roles.orchestrator mcpServers.wecom, the rest untouched" || bad "A2: rc=$rc $(pb roles) $out"
# 3 减工具 「执行会话别用 WebFetch」 — a role with every tool: a disallowedTools entry
out=$(role set worker tools -WebFetch --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 3 ] && [ "$(pb roles.worker.front)" = '{"tools": ["-WebFetch"]}' ] \
  && has "$out" '执行会话 · 禁用工具：（无） → WebFetch' && has "$out" '下次开的执行会话生效'; } \
  && ok "A3 减工具: tools -WebFetch → disallowedTools WebFetch" || bad "A3: rc=$rc $(pb roles.worker) $out"
# 4 加一段说明
out=$(role set orchestrator body '回答先给结论，再给细节。' --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 4 ] && [ "$(pb roles.orchestrator.body)" = '"回答先给结论，再给细节。\n"' ] \
  && has "$(pb roles.orchestrator.front.mcpServers)" wecom && has "$out" '说明（你加的）：（无） → 回答先给结论，再给细节。'; } \
  && ok "A4 加一段说明: appended to the overlay body, mcpServers kept" || bad "A4: rc=$rc $(pb roles.orchestrator) $out"
# 5 改规则档 「让管家别自动答金额相关的问题」 → rule 14 to ask
out=$(role rule-set 14 --tier ask --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 5 ] && has "$(pb rules)" '"n": 14' && has "$(pb rules)" '"tier": "ask"' \
  && has "$out" '已改 管家 · 规则 14：问题带了建议或默认，到点没人答 → 必须问你（入口 v5）'; } \
  && ok "A5 改规则档: the person's row 14, tier ask" || bad "A5: rc=$rc $(pb rules) $out"
# 6 撤回
out=$(role undo --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = 6 ] && [ "$(pb rules)" = null ] && has "$(pb roles.orchestrator.body)" 回答先给结论 \
  && has "$out" '已撤回 管家 · 规则 14：问题带了建议或默认，到点没人答 → 到点按默认走（入口 v6 = v4 的内容）'; } \
  && ok "A6 撤回: v6 = v4's content (the rule row gone, the rest kept)" || bad "A6: rc=$rc $(pb rules) $out"

# ── F — the cache took the hub's answer ──────────────────────────────────────
out=$(env -i PATH="$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_ROLE_STALE=0 "$PY" "$R" show steward --sources 2>&1)
printf '%s\n' "$out" | grep -q '^model: sonnet .*# 你的 v6' \
  && ok "F show --sources: model sonnet from 你的 v6, no sync waited for" || bad "F: $out"

# ── C — a worker's window only reads ─────────────────────────────────────────
v0=$(ver)
out=$(inwin worker set steward model haiku --yes); rc=$?
{ [ $rc = 3 ] && [ "$(ver)" = "$v0" ] && has "$out" '只能看不能改'; } \
  && ok "C worker window: set refused exit 3, nothing written" || bad "C set: rc=$rc $out"
out=$(inwin worker undo --yes); rc=$?
[ $rc = 3 ] && [ "$(ver)" = "$v0" ] && ok "C worker window: undo refused exit 3" || bad "C undo: rc=$rc $out"
out=$(inwin worker show steward); rc=$?
[ $rc = 0 ] && has "$out" 'name: steward' && ok "C worker window: show still answers" || bad "C show: rc=$rc $out"
out=$(inwin orchestrator set steward effort high --yes); rc=$?
[ $rc = 0 ] && [ "$(ver)" = $((v0 + 1)) ] && ok "C the orchestrator's window writes" || bad "C orch: rc=$rc $out"

# ── D — a token is refused before anything is sent ───────────────────────────
v0=$(ver)
out=$(role set orchestrator mcpServers wecom '{"command": "x", "env": {"WECOM_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}' --yes); rc=$?
{ [ $rc = 2 ] && [ "$(ver)" = "$v0" ] && has "$out" '拒收，什么都没写' && has "$out" 'bin/mcp-github.sh'; } \
  && ok "D token in a server's env: exit 2, the wrapper hint, nothing written" || bad "D env: rc=$rc $out"
out=$(role set steward body '用这个 key：sk-ant-api03-abcdefghijklmnopqrstuvwx' --yes); rc=$?
{ [ $rc = 2 ] && [ "$(ver)" = "$v0" ]; } && ok "D token in the body: refused, nothing written" || bad "D body: rc=$rc $out"

# ── E — 409 once more; no movement, no write ─────────────────────────────────
v0=$(ver); touch "$WORK/hub/bump"
out=$(role set steward model haiku --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = $((v0 + 2)) ] && [ "$(pb roles.steward.front.model)" = '"haiku"' ]; } \
  && ok "E 409: re-read, redone once on the new base" || bad "E 409: rc=$rc v=$(ver) $out"
v0=$(ver)
out=$(role set steward model haiku --yes); rc=$?
{ [ $rc = 0 ] && [ "$(ver)" = "$v0" ] && has "$out" '没有变化'; } \
  && ok "E a change that moves nothing writes nothing" || bad "E same: rc=$rc $out"
out=$(role unset steward model --yes); rc=$?
{ [ $rc = 0 ] && [ "$(pb roles.steward.front.model)" = null ] && has "$out" '模型：haiku → opus'; } \
  && ok "E unset: back to the built-in" || bad "E unset: rc=$rc $out"

# ── G — new rules from 100; unknown numbers refused ──────────────────────────
out=$(role rule-set new --role steward --cond '问题和金额有关' --action '必须问你（never:money）' --tier ask --keywords '金额, 报价' --yes); rc=$?
{ [ $rc = 0 ] && has "$(pb rules)" '"n": 100' && has "$out" '管家 · 规则 100（新）'; } \
  && ok "G rule-set new → 100" || bad "G new: rc=$rc $(pb rules) $out"
out=$(role rule-set 77 --tier ask --yes); rc=$?
[ $rc = 2 ] && has "$out" '没有 77' && ok "G rule 77 (no layer has it) refused" || bad "G 77: rc=$rc $out"
out=$(role rule-unset 100 --yes); rc=$?
{ [ $rc = 0 ] && [ "$(pb rules)" = null ]; } && ok "G rule-unset 100" || bad "G unset: rc=$rc $(pb rules) $out"

echo
[ "$fails" = 0 ] && { echo "fleet-role-write-selftest: all passed"; exit 0; }
echo "fleet-role-write-selftest: $fails failed"; exit 1
