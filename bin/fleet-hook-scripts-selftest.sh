#!/bin/bash
# fleet-hook-scripts-selftest.sh — a personal hook's PROGRAM travels with the
# personal layer (issue #1859, EPIC #1855 C4). Drives bin/fleet-agent-team.py
# and bin/fleet-hook-personal.sh in throwaway HOMEs, the person's answer through
# the FLEET_PERSON_BUNDLE_CMD seam:
#
#   A. land        sync lands hook_scripts as $FLEET_CONF_DIR/personal-hooks/<name>:
#                  directory 0700, file 0700, `# fleet personal hook` after the
#                  `#!`; agent-effective.json row hook_scripts.<name> source personal
#   B. runs        the wired hook (`$FLEET_PERSONAL_HOOKS/<name>`) runs through the
#                  wrapper and writes its log
#   C. addressed   a second sync rewrites nothing; a new text is rewritten
#   D. rollback    a version without the program removes it; a file of the
#                  person's own in the directory (no mark) and a program edited
#                  here are left alone
#   E. fresh       a computer that only fetched (never applied): `session claude`
#                  lands the missing program, and the next sync takes it as its own
#   F. degenerate  no hook_scripts → no personal-hooks directory, no row
#   G. refused     a program over 32 KiB, a bad name, a key in its text → the
#                  personal read is refused (one line), nothing landed
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
real="$BIN/fleet-agent-team.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
T="$REPO/bin/fleet-agent-team.py"
W="$REPO/bin/fleet-hook-personal.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-hook-scripts-selftest.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
PY="$(command -v python3)"
j() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))" "$@" 2>/dev/null; }
mode() { "$PY" -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1" 2>/dev/null; }
ino()  { "$PY" -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1" 2>/dev/null; }

mkhome() {   # mkhome <dir>
  mkdir -p "$1/.claude" "$1/conf"
  ln -s "$REPO" "$1/.claude/fleet"     # the install a wired hook spells ($HOME/.claude/fleet/bin/…)
  echo '{}' > "$1/.claude.json"; echo '{"theme": "dark"}' > "$1/.claude/settings.json"
}
# team <home> <args…> — the script, sandboxed; the person's answer is $WORK/presp.json
team() {
  local hm="$1"; shift
  env -i PATH="$PATH" HOME="$hm" FLEET_CONF_DIR="$hm/conf" FLEET_TEAM_BUNDLE_CMD="printf '%s' '{\"version\":0,\"bundle\":{}}'" \
    FLEET_PERSON_BUNDLE_CMD="cat $WORK/presp.json" "$PY" "$T" "$@" --root "$REPO" \
    --claude-config "$hm/.claude.json" --claude-settings "$hm/.claude/settings.json" \
    --claude-skills "$hm/.claude/skills" 2>&1
}
presp() { printf '%s\n' "$1" > "$WORK/presp.json"; }
bundle() {   # bundle <version> <program text> — a hook and the program it runs
  "$PY" - "$1" "$2" <<'PY'
import json, sys
v, txt = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"version": v, "prev": v - 1, "bundle": {
    "hooks": {"PostToolUse": [{"command": "sh \"$FLEET_PERSONAL_HOOKS/log-tool.sh\""}]},
    "hook_scripts": {"log-tool.sh": txt}}}))
PY
}
PROG1='#!/bin/sh
cat >/dev/null
echo "ran v1" >> "$HOME/hook.log"'
H="$WORK/a"; mkhome "$H"; D="$H/conf/personal-hooks"

# ── A — land ──────────────────────────────────────────────────────────────────
presp "$(bundle 1 "$PROG1")"
out=$(team "$H" sync); rc=$?
[ "$rc" = 0 ] && [ -f "$D/log-tool.sh" ] && [ "$(mode "$D")" = 0o700 ] && [ "$(mode "$D/log-tool.sh")" = 0o700 ] \
  && [ "$(sed -n 2p "$D/log-tool.sh")" = '# fleet personal hook' ] && [ "$(sed -n 1p "$D/log-tool.sh")" = '#!/bin/sh' ] \
  && [ "$(j "$H/conf/agent-effective.json" "d['items']['hook_scripts.log-tool.sh']['source']")" = '"personal"' ] \
  && ok "A the program lands 0700 in a 0700 directory, marked after #!, row source personal" \
  || bad "A rc=$rc: $out // $(ls -la "$D" 2>&1)"

# ── B — the wired hook runs it ─────────────────────────────────────────────────
cmd=$(j "$H/.claude/settings.json" "[h['command'] for g in d['hooks']['PostToolUse'] for h in g['hooks']][0]" | "$PY" -c 'import json,sys;print(json.load(sys.stdin))')
echo '{"tool_name":"Bash"}' | env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$H/conf" sh -c "$cmd" >"$WORK/b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$H/hook.log" 2>/dev/null)" = "ran v1" ] && case "$cmd" in *fleet-hook-personal.sh*) true ;; *) false ;; esac \
  && ok "B the wrapped hook finds \$FLEET_PERSONAL_HOOKS/log-tool.sh and runs it" || bad "B rc=$rc cmd=$cmd: $(cat "$WORK/b.out")"
: > "$H/hook.log"
echo '{}' | env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$H/conf" sh "$W" PostToolUse -- 'printf %s "$FLEET_PERSONAL_HOOKS"' >"$WORK/b2" 2>&1
[ "$(cat "$WORK/b2")" = "$H/conf/personal-hooks" ] && ok "B the wrapper sets FLEET_PERSONAL_HOOKS from FLEET_CONF_DIR" || bad "B env: $(cat "$WORK/b2")"

# ── C — content-addressed ──────────────────────────────────────────────────────
i0=$(ino "$D/log-tool.sh")
out=$(team "$H" sync --force)
[ "$(ino "$D/log-tool.sh")" = "$i0" ] && ok "C the same text again: the file is not rewritten" || bad "C resync: $out"
presp "$(bundle 2 "${PROG1/v1/v2}")"
out=$(team "$H" sync)
grep -q 'ran v2' "$D/log-tool.sh" && [ "$(mode "$D/log-tool.sh")" = 0o700 ] \
  && ok "C a new text replaces it (still 0700)" || bad "C new: $out"

# ── D — the rollback takes back only its own ────────────────────────────────────
printf '#!/bin/sh\necho mine\n' > "$D/mine.sh"; chmod 755 "$D/mine.sh"
presp '{"version":3,"prev":2,"bundle":{"hook_scripts":{"keep.sh":"echo keep"}}}'
out=$(team "$H" sync)
presp '{"version":4,"prev":3,"bundle":{"hook_scripts":{"edited.sh":"echo e"}}}'
out=$(team "$H" sync)
echo 'echo edited here' >> "$D/edited.sh"
presp '{"version":5,"prev":4,"bundle":{"mcp":{"x":{"command":"x"}}}}'
out=$(team "$H" sync); rc=$?
[ "$rc" = 0 ] && [ ! -e "$D/log-tool.sh" ] && [ ! -e "$D/keep.sh" ] \
  && ok "D a version without the programs removes them" || bad "D drop rc=$rc: $out // $(ls "$D")"
[ "$(cat "$D/mine.sh" 2>/dev/null)" = "$(printf '#!/bin/sh\necho mine')" ] && [ "$(mode "$D/mine.sh")" = 0o755 ] \
  && grep -q 'edited here' "$D/edited.sh" \
  && ok "D the person's own file (no mark) and a program edited here are left alone" || bad "D kept: $(ls -la "$D")"

# ── E — a fresh computer: session lands it before any apply ────────────────────
H2="$WORK/b"; mkhome "$H2"; D2="$H2/conf/personal-hooks"
presp "$(bundle 1 "$PROG1")"
team "$H2" fetch >/dev/null
[ ! -e "$D2" ] || bad "E fetch alone wrote programs"
s=$(cd "$WORK" && team "$H2" session claude)
f=$(printf '%s\n' "$s" | sed -n 's/^settings	//p')
[ -f "$D2/log-tool.sh" ] && [ "$(mode "$D2/log-tool.sh")" = 0o700 ] && [ -n "$f" ] && grep -q 'FLEET_PERSONAL_HOOKS/log-tool.sh' "$f" \
  && ok "E session claude hands the hook and lands its program on a computer that never applied" || bad "E session: $s // $(ls -la "$D2" 2>&1)"
cmd=$(j "$f" "[h['command'] for g in d['hooks']['PostToolUse'] for h in g['hooks'] if 'log-tool' in h['command']][0]" | "$PY" -c 'import json,sys;print(json.load(sys.stdin))')
echo '{}' | env -i PATH="$PATH" HOME="$H2" FLEET_CONF_DIR="$H2/conf" sh -c "$cmd" >/dev/null 2>&1
[ "$(cat "$H2/hook.log" 2>/dev/null)" = "ran v1" ] && ok "E the handed hook runs there" || bad "E run: $cmd"
out=$(team "$H2" sync --force)
[ "$(j "$H2/conf/agent-effective.json" "d['items']['hook_scripts.log-tool.sh']['source']")" = '"personal"' ] \
  && ! printf '%s' "$out" | grep -q '^own .*hook_scripts' \
  && ok "E the next sync takes the landed program as the layer's" || bad "E adopt: $out"
presp '{"version":2,"prev":1,"bundle":{}}'
out=$(team "$H2" sync)
[ ! -e "$D2/log-tool.sh" ] && ok "E … so a rollback there removes it too" || bad "E drop: $out"

# ── F — no hook_scripts: no directory, no row ──────────────────────────────────
H3="$WORK/c"; mkhome "$H3"
presp '{"version":1,"prev":0,"bundle":{"mcp":{"x":{"command":"x"}}}}'
team "$H3" sync >/dev/null; (cd "$WORK" && team "$H3" session claude >/dev/null)
[ ! -e "$H3/conf/personal-hooks" ] && [ "$(j "$H3/conf/agent-effective.json" "[k for k in d['items'] if k.startswith('hook_scripts')]")" = '[]' ] \
  && ok "F no hook_scripts → no personal-hooks directory, no row" || bad "F: $(ls "$H3/conf")"

# ── G — refused ─────────────────────────────────────────────────────────────────
H4="$WORK/d"; mkhome "$H4"
for b in "{\"x.sh\":\"$(head -c 33000 /dev/zero | tr '\0' a)\"}" '{"../x":"echo"}' \
         '{"x.sh":"curl -H \"Authorization: Bearer abcdefghijklmnopqrstuvwxyz\" x"}'; do
  presp "{\"version\":1,\"prev\":0,\"bundle\":{\"hook_scripts\":$b}}"
  out=$(team "$H4" sync); rc=$?
  printf '%s' "$out" | grep -q '^personal: refused v1: bundle.hook_scripts' && [ ! -e "$H4/conf/personal-hooks" ] \
    && [ ! -e "$H4/conf/person-bundle.json" ] || bad "G rc=$rc: ${out:0:200}"
done
[ "$fail" = 0 ] && ok "G over 32 KiB / a bad name / a key in the text → refused, nothing cached, nothing landed"

[ "$fail" = 0 ] && echo "fleet-hook-scripts-selftest: PASS" || echo "fleet-hook-scripts-selftest: FAIL"
exit "$fail"
