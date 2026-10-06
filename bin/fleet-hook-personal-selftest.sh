#!/bin/bash
# fleet-hook-personal-selftest.sh — a personal hook is add-only (issue #1858,
# EPIC #1855 C3). Drives bin/fleet-hook-personal.sh directly and
# bin/fleet-agent-team.py / bin/fleet-hooks-merge.py in a throwaway HOME, the
# person's answer through the FLEET_PERSON_BUNDLE_CMD seam:
#
#   A. rewrite     a personal PreToolUse answering `updatedInput` comes out
#                  without it (the allow kept); a deny — exit 2 or a JSON
#                  permissionDecision "deny" — goes through as it was; any other
#                  output passes byte for byte
#   B. timeout     a hung hook is cut off at FLEET_PERSONAL_HOOK_TIMEOUT, its
#                  process group with it, exit 1 (non-blocking), in time
#   C. wired       sync writes the hook through the wrapper under
#                  claude.hooks.personal.<Event>.<key>; fleet-hooks-merge.py
#                  leaves it where it is (never stale, never folded), twice over
#   D. enforce     FLEET_AGENT_LOCK=enforce with `claude.hooks` locked: the
#                  personal hook stays in the session's rows, is handed when the
#                  login lacks it, and is never in the ignored list; a team hook
#                  still is
#   E. degenerate  no personal layer → settings.json byte for byte what the team
#                  layer alone writes (no wrapper anywhere)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
real="$BIN/fleet-hook-personal.sh"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
W="$REPO/bin/fleet-hook-personal.sh"
T="$REPO/bin/fleet-agent-team.py"
M="$REPO/bin/fleet-hooks-merge.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-hook-personal-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
PY="$(command -v python3)"
j() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))" "$@" 2>/dev/null; }

# ── A — no rewrite; a deny is a deny ─────────────────────────────────────────
IN='{"tool_name":"Bash","tool_input":{"command":"sh fleet-heavy.sh -- git push"}}'
cat > "$WORK/rewrite.sh" <<'EOF'
cat >/dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"fine","updatedInput":{"command":"git push"}}}'
EOF
out=$(printf '%s' "$IN" | sh "$W" PreToolUse -- "sh $WORK/rewrite.sh" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | j /dev/stdin "d['hookSpecificOutput']")" = \
    '{"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "fine"}' ] \
  && grep -q 'updatedInput dropped' "$WORK/err" \
  && ok "A updatedInput is dropped, the allow + reason kept" || bad "A rewrite rc=$rc: $out // $(cat "$WORK/err")"
printf '%s' "$IN" > "$WORK/in.json"
out=$(printf '%s' "$IN" | sh "$W" PermissionRequest -- \
  "cat >/dev/null; echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"x\"}}}}'" 2>/dev/null)
[ "$(printf '%s' "$out" | j /dev/stdin "d['hookSpecificOutput']['decision']")" = '{"behavior": "allow"}' ] \
  && ok "A a PermissionRequest decision loses its updatedInput too" || bad "A permreq: $out"
out=$(printf '%s' "$IN" | sh "$W" PreToolUse -- 'cat >/dev/null; echo "no pushing" >&2; exit 2' 2>"$WORK/err"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && [ "$(cat "$WORK/err")" = "no pushing" ] \
  && ok "A exit 2 + stderr (deny) goes through as it was" || bad "A deny rc=$rc: $out // $(cat "$WORK/err")"
DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
out=$(printf '%s' "$IN" | sh "$W" PreToolUse -- "cat >/dev/null; printf '%s' '$DENY'"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$DENY" ] && ok "A a JSON deny passes byte for byte" || bad "A json deny rc=$rc: $out"
out=$(printf '%s' "$IN" | sh "$W" UserPromptSubmit -- 'cat; printf "x\ty\n"')
[ "$out" = "$IN"$'x\ty' ] && ok "A stdin forwarded, other output byte for byte" || bad "A passthrough: $out"
sh "$W" PreToolUse </dev/null >/dev/null 2>&1; [ "$?" = 2 ] && ok "A a malformed wiring exits 2" || bad "A usage"

# ── B — timeout ─────────────────────────────────────────────────────────────────
t0=$(date +%s)
out=$(echo '{}' | FLEET_PERSONAL_HOOK_TIMEOUT=1 sh "$W" Stop -- "sleep 60 & echo \$! > $WORK/kid; sleep 60" 2>"$WORK/err"); rc=$?
dt=$(( $(date +%s) - t0 ))
sleep 0.3
kid=$(cat "$WORK/kid" 2>/dev/null)
[ "$rc" = 1 ] && [ "$dt" -le 4 ] && grep -q 'cut off after 1s' "$WORK/err" \
  && ok "B a hung hook is cut off at 1s (${dt}s), exit 1, one line" || bad "B rc=$rc dt=$dt $(cat "$WORK/err")"
[ -n "$kid" ] && ! kill -0 "$kid" 2>/dev/null \
  && ok "B its background child dies with it" || { bad "B child $kid still alive"; kill "$kid" 2>/dev/null; }

# ── C — wired by sync, left alone by the merge ─────────────────────────────────
H="$WORK/home"
CONF="$H/.config/claude-fleet"
mkdir -p "$H/.claude" "$CONF"
echo '{}' > "$H/.claude.json"
echo '{"theme": "dark"}' > "$H/.claude/settings.json"
LOCKROOT="$WORK/root"           # the repo's conf/, with `claude.hooks` locked whatever the list says
mkdir -p "$LOCKROOT"
cp -R "$REPO/conf" "$REPO/hooks" "$LOCKROOT/"
printf 'claude.hooks\n' >> "$LOCKROOT/conf/agent-locked.list"
team() {
  env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" FLEET_TEAM_BUNDLE_CMD="cat $WORK/resp.json" \
    ${PSEAM:+FLEET_PERSON_BUNDLE_CMD="$PSEAM"} "$PY" "$T" "$@" --root "$LOCKROOT" \
    --claude-config "$H/.claude.json" --claude-settings "$H/.claude/settings.json" \
    --claude-skills "$H/.claude/skills" --codex-home "$WORK/nocodex" 2>&1
}
echo '{"version":1,"prev":0,"bundle":{"hooks":{"Stop":[{"command":"echo team-stop","timeout":5}]}}}' > "$WORK/resp.json"
echo '{"version":1,"prev":0,"bundle":{"hooks":{"PreToolUse":[{"matcher":"Bash","command":"my-check '"'"'it'"'"'"}],
  "Stop":[{"command":"echo team-stop"}]}}}' > "$WORK/presp.json"
PSEAM="cat $WORK/presp.json" out=$(team sync); rc=$?
KEY=$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:10])' "my-check 'it'")
WANT="sh \"\$HOME/.claude/fleet/bin/fleet-hook-personal.sh\" PreToolUse -- 'my-check '\\''it'\\'''"
[ "$rc" = 0 ] && [ "$(j "$H/.claude/settings.json" "d['hooks']['PreToolUse']")" = \
    "$("$PY" -c 'import json,sys;print(json.dumps([{"hooks":[{"command":sys.argv[1],"type":"command"}],"matcher":"Bash"}],sort_keys=True))' "$WANT")" ] \
  && [ "$(j "$CONF/agent-effective.json" "d['items']['claude.hooks.personal.PreToolUse.$KEY']['source']")" = '"personal"' ] \
  && ok "C sync wires it through the wrapper as claude.hooks.personal.PreToolUse.<key>" || bad "C sync rc=$rc: $out // $(cat "$H/.claude/settings.json")"
[ "$(j "$H/.claude/settings.json" "[h['command'] for g in d['hooks']['Stop'] for h in g['hooks']]")" = '["echo team-stop"]' ] \
  && ok "C a personal hook the team already hands is the team's, not added twice" || bad "C dedupe: $(cat "$H/.claude/settings.json")"
inner=$("$PY" - "$M" "$WANT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.personal_inner(sys.argv[2]), m.identity("PreToolUse", {"matcher": "Bash"}, {"command": sys.argv[2]}))
PY
)
[ "$inner" = "('PreToolUse', \"my-check 'it'\") None" ] && ok "C the wrapped line unwraps; identity() is None (not a fleet hook)" || bad "C unwrap: $inner"
cp "$H/.claude/settings.json" "$WORK/s0.json"
for i in 1 2; do "$PY" "$M" merge --settings "$H/.claude/settings.json" --source "$REPO/hooks/settings-hooks.json" >"$WORK/merge$i" 2>&1; done
n=$(j "$H/.claude/settings.json" "sum(1 for g in d['hooks'].get('PreToolUse', []) for h in g['hooks'] if 'fleet-hook-personal.sh' in h['command'])")
[ "$n" = 1 ] && ! grep -q 'fleet-hook-personal\.sh' "$WORK/merge1" "$WORK/merge2" \
  && "$PY" "$M" check --settings "$H/.claude/settings.json" --source "$REPO/hooks/settings-hooks.json" >"$WORK/check" 2>&1 \
  && ok "C two hook merges leave the personal hook once, untouched; check is ok" \
  || bad "C merge: n=$n $(cat "$WORK/merge1" "$WORK/check")"
cp "$WORK/s0.json" "$H/.claude/settings.json"
out=$(PSEAM="cat $WORK/presp.json" team sync)
cmp -s "$WORK/s0.json" "$H/.claude/settings.json" && ok "C a second sync writes nothing" || bad "C resync: $out"

# ── D — enforce keeps it ───────────────────────────────────────────────────────
sess() {
  env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" ${PSEAM:+FLEET_PERSON_BUNDLE_CMD="$PSEAM"} \
    "$PY" - "$T" "$LOCKROOT" "$H" "$@" <<'PY'
import importlib.util, json, sys
t, root, h = sys.argv[1:4]
s = importlib.util.spec_from_file_location("t", t); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
a = m.build_parser().parse_args(["session", "claude", "--lock", "enforce", "--root", root,
                                 "--claude-config", h + "/.claude.json", "--claude-settings", h + "/.claude/settings.json",
                                 "--claude-skills", h + "/.claude/skills"])
x = m.Session(a, "claude").compose()
print(json.dumps({"rows": {p: [r["source"], r["locked"]] for p, r in x.rows.items() if p.startswith("claude.hooks.")},
                  "hand": sorted(p for p in x.hand if p.startswith("claude.hooks.")),
                  "ignored": sorted(p for p, w, _ in x.overrides if w == "ignored")}, sort_keys=True))
PY
}
P="claude.hooks.personal.PreToolUse.$KEY"
TK="claude.hooks.Stop.$("$PY" -c 'import hashlib;print(hashlib.sha256(b"echo team-stop").hexdigest()[:10])')"
r=$(PSEAM="cat $WORK/presp.json" sess)
[ "$(printf '%s' "$r" | j /dev/stdin "d['rows'].get('$P')")" = '["personal", false]' ] \
  && [ "$(printf '%s' "$r" | j /dev/stdin "'$P' in d['ignored']")" = false ] \
  && [ "$(printf '%s' "$r" | j /dev/stdin "d['rows'].get('$TK')")" = '["team", true]' ] \
  && ok "D enforce: the personal hook is a row, unlocked, not ignored (the team hook is locked)" || bad "D rows: $r"
"$PY" - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["hooks"].pop("PreToolUse")
d["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 99          # this login's edit of a LOCKED team hook
json.dump(d, open(p, "w"))
PY
r=$(PSEAM="cat $WORK/presp.json" sess)
[ "$(printf '%s' "$r" | j /dev/stdin "'$P' in d['hand'] and '$P' not in d['ignored']")" = true ] \
  && [ "$(printf '%s' "$r" | j /dev/stdin "'$TK' in d['ignored']")" = true ] \
  && ok "D enforce: a login without it is handed the personal hook; the edited team hook is ignored" || bad "D hand: $r"
s=$(cd "$WORK" && env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$CONF" FLEET_PERSON_BUNDLE_CMD="cat $WORK/presp.json" \
      "$PY" "$T" session claude --lock enforce --root "$LOCKROOT" --claude-config "$H/.claude.json" \
      --claude-settings "$H/.claude/settings.json" --claude-skills "$H/.claude/skills" 2>&1)
f=$(printf '%s\n' "$s" | sed -n 's/^settings	//p')
[ -n "$f" ] && [ "$(j "$f" "[h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks'] if 'personal' in h['command']]")" = \
    "$("$PY" -c 'import json,sys;print(json.dumps([sys.argv[1]]))' "$WANT")" ] \
  && ! printf '%s\n' "$s" | grep -q "^lock	claude.hooks.personal" \
  && ok "D the launch's --settings carries the wrapped personal hook under its own event" || bad "D launch: $s"

# ── E — no personal layer: settings.json as the team alone writes it ──────────
for d in a b; do
  rm -rf "$WORK/$d"; mkdir -p "$WORK/$d/.claude" "$WORK/$d/conf"
  echo '{}' > "$WORK/$d/.claude.json"; echo '{"theme": "dark"}' > "$WORK/$d/.claude/settings.json"
done
E() {   # E <home> <person seam>
  env -i PATH="$PATH" HOME="$WORK/$1" FLEET_CONF_DIR="$WORK/$1/conf" FLEET_TEAM_BUNDLE_CMD="cat $WORK/resp.json" \
    ${2:+FLEET_PERSON_BUNDLE_CMD="$2"} "$PY" "$T" sync --root "$LOCKROOT" --claude-config "$WORK/$1/.claude.json" \
    --claude-settings "$WORK/$1/.claude/settings.json" --claude-skills "$WORK/$1/.claude/skills" --codex-home "$WORK/nocodex" >/dev/null 2>&1
}
E a ''
E b "printf '%s' '{\"version\":0,\"bundle\":{}}'"
want='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo team-stop","timeout":5}]}]},"theme":"dark"}'
[ "$(j "$WORK/a/.claude/settings.json" "d")" = "$(printf '%s' "$want" | j /dev/stdin "d")" ] \
  && cmp -s "$WORK/a/.claude/settings.json" "$WORK/b/.claude/settings.json" \
  && ! grep -q fleet-hook-personal "$WORK/a/.claude/settings.json" \
  && ok "E no personal layer (none / version 0) → settings.json byte for byte the team's alone" \
  || bad "E degenerate: $(cat "$WORK/a/.claude/settings.json") // $(cat "$WORK/b/.claude/settings.json")"

[ "$fail" = 0 ] && echo "fleet-hook-personal-selftest: PASS" || echo "fleet-hook-personal-selftest: FAIL"
exit "$fail"
