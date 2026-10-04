#!/bin/bash
# fleet-hooks-merge-selftest.sh — the hook table merges by IDENTITY (issue #818).
#
# The failure this test exists to prevent: /fleet-sync-install appended the hook
# table and de-duplicated on the command STRING, so changing a guard's
# interpreter path (`/opt/homebrew/bin/python3 …` -> `python3 …`) left the old
# entry beside the new one and every Bash / Edit / Artifact call ran the guard
# twice. bin/fleet-hooks-merge.py keys on (event, matcher, script basename).
# What is pinned here:
#
#   1. FIRST INSTALL APPENDS — an empty settings.json gets the whole table, and a
#      second merge is a no-op (no write, no backup).
#   2. A CHANGED COMMAND STRING IS REPLACED, NOT APPENDED — and a pre-existing
#      duplicate (the #818 live state) collapses to one entry, listed in output.
#   3. THE USER'S OWN HOOKS ARE UNTOUCHED — a non-fleet hook sharing a group with
#      a fleet one, and a non-fleet group on the same matcher, survive byte-equal.
#   4. STALE FLEET HOOKS ARE PRUNED — an identity the table no longer wires.
#   5. CHECK IS THE DOCTOR'S EYE — exit 1 naming duplicate/missing/stale before
#      the merge, exit 0 after; the backup is written and the file mode kept.
#   6. THE SOURCE TABLE ITSELF HAS UNIQUE IDENTITIES — else "replace by identity"
#      would be ambiguous.
#   7. DEFAULT CLAUDE SETTINGS (issue #1558, folding #1528) — `defaults` fills
#      conf/claude-settings.default.json into settings.json ("settings") and
#      Claude Code's GLOBAL config .claude.json ("globalConfig",
#      leftArrowOpensAgents=false — the only place that key is read), FILL ONLY:
#      an empty settings.json gets every default key; a key the login set to
#      another value is left as it is (a user `true` is NOT corrected — #1528's
#      pin became a fill); permissions.defaultMode lands beside the login's own
#      permissions.allow; a key listed in settings.fleet-override.json (or
#      --skip, the FLEET_KEEP_AGENTS_KEY=1 opt-out) is never written; a second
#      run is a no-op (no write, no backup); an absent .claude.json is not
#      created; a held `.claude.json.lock` (Claude Code's own save in flight) is
#      never stolen — exit 2, nothing written there; the repo's own file ships
#      neither model nor enabledPlugins nor hooks; and defaults-check is the
#      doctor's `settings` eye.
#
# Hermetic: temp fixtures only; no tmux, no network, no writes to the repo.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
MERGE="$BIN/fleet-hooks-merge.py"
SRC="$ROOT/hooks/settings-hooks.json"

for f in "$MERGE" "$SRC"; do
  [ -r "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-hooks-merge.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

m() { python3 "$MERGE" "$@" --source "$SRC"; }
nbak() { find "$WORK" -name "$1.bak.*" | wc -l | tr -d ' '; }

# Count the fleet entries per identity; every identity in the table must be 1.
all_once() {
  S="$1" SRC="$SRC" python3 - <<'PY'
import json, os, sys
import importlib.util
spec = importlib.util.spec_from_file_location("m", os.path.dirname(os.environ["SRC"]) + "/../bin/fleet-hooks-merge.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
_, table = mod.source_table(os.environ["SRC"])
c = mod.census(json.load(open(os.environ["S"])))
sys.exit(0 if c == {k: 1 for k in table} else 1)
PY
}

# --- 6. the source table has unique identities --------------------------------
m check --settings "$WORK/none.json" >/dev/null 2>"$WORK/err"
[ ! -s "$WORK/err" ] || fail "source table is not identity-unique" "$(cat "$WORK/err")"
ok "source table: every (event, matcher, script) is wired once"

# --- 1. first install appends; a re-run is a no-op ----------------------------
S1="$WORK/first.json"; printf '{"model": "x"}\n' > "$S1"
m check --settings "$S1" >"$WORK/c1"; rc=$?
[ "$rc" = 1 ] && grep -q '^missing' "$WORK/c1" || fail "check on an empty install should report missing (rc=$rc)" "$(cat "$WORK/c1")"
m merge --settings "$S1" >"$WORK/o1" || fail "first merge exited non-zero" "$(cat "$WORK/o1")"
all_once "$S1" || fail "first install did not wire every hook exactly once" "$(cat "$S1")"
python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["model"] != "x")' "$S1" \
  || fail "first install lost an unrelated settings key"
ok "first install: table appended, other settings kept"

before="$(nbak first.json)"; cp "$S1" "$WORK/first.snap"
m merge --settings "$S1" >"$WORK/o1b" || fail "re-merge exited non-zero"
grep -q '^unchanged' "$WORK/o1b" || fail "re-merge should report unchanged" "$(cat "$WORK/o1b")"
cmp -s "$S1" "$WORK/first.snap" && [ "$(nbak first.json)" = "$before" ] \
  || fail "re-merge rewrote the file or took a backup"
ok "re-merge: no-op, no write, no backup"

# --- 2/3/4/5. the #818 live shape ----------------------------------------------
S2="$WORK/live.json"
cat > "$S2" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "/opt/homebrew/bin/python3 ~/.claude/hooks/guard.py" } ] },
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "/opt/homebrew/bin/python3 ~/.claude/fleet/hooks/bash-guard.py" } ] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [
        { "type": "command", "command": "/opt/homebrew/bin/python3 ~/.claude/fleet/hooks/base-readonly-guard.py" },
        { "type": "command", "command": "sh ~/my-own-edit-hook.sh", "timeout": 5 } ] },
      { "matcher": "Artifact", "hooks": [
        { "type": "command", "command": "/opt/homebrew/bin/python3 ~/.claude/fleet/hooks/artifact-guard.py" } ] },
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "python3 ~/.claude/fleet/hooks/bash-guard.py" } ] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [
        { "type": "command", "command": "python3 ~/.claude/fleet/hooks/base-readonly-guard.py" } ] },
      { "matcher": "Artifact", "hooks": [
        { "type": "command", "command": "python3 ~/.claude/fleet/hooks/artifact-guard.py" } ] }
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "sh ~/.claude/fleet/bin/summarize-hook.sh" } ] }
    ]
  }
}
JSON
chmod 600 "$S2"

m check --settings "$S2" >"$WORK/c2"; rc=$?
[ "$rc" = 1 ] || fail "check should exit 1 on the duplicated shape (rc=$rc)" "$(cat "$WORK/c2")"
for want in 'duplicate  PreToolUse\[Bash\] bash-guard.py ×2' \
            'duplicate  PreToolUse\[Edit|Write|MultiEdit|NotebookEdit\] base-readonly-guard.py ×2' \
            'duplicate  PreToolUse\[Artifact\] artifact-guard.py ×2' \
            'stale      Stop\[\*\] summarize-hook.sh' \
            'missing    PreToolUse\[Agent\] agent-guard.py'; do
  grep -q "^$want" "$WORK/c2" || fail "check did not report: $want" "$(cat "$WORK/c2")"
done
ok "check (doctor's eye): duplicates, stale and missing all named, exit 1"

m merge --settings "$S2" >"$WORK/o2" || fail "merge exited non-zero" "$(cat "$WORK/o2")"
[ "$(nbak live.json)" = 1 ] || fail "merge did not leave exactly one backup"
all_once "$S2" || fail "merge left a fleet identity wired != 1 time" "$(cat "$S2")"
grep -q '^removed dup .*bash-guard.py' "$WORK/o2" \
  && grep -q '^replaced .*base-readonly-guard.py: /opt/homebrew/bin/python3' "$WORK/o2" \
  && grep -q '^removed stale .*summarize-hook.sh' "$WORK/o2" \
  || fail "merge output does not list what it removed/replaced" "$(cat "$WORK/o2")"
ok "merge: changed command replaced in place, duplicates + stale removed and listed"

S2="$S2" python3 - <<'PY' || fail "a user-owned hook was changed or dropped" "$(cat "$S2")"
import json, os, sys
pre = json.load(open(os.environ["S2"]))["hooks"]["PreToolUse"]
cmds = [h for g in pre for h in g["hooks"]]
guard = {"type": "command", "command": "/opt/homebrew/bin/python3 ~/.claude/hooks/guard.py"}
mine = {"type": "command", "command": "sh ~/my-own-edit-hook.sh", "timeout": 5}
sys.exit(0 if cmds.count(guard) == 1 and cmds.count(mine) == 1 else 1)
PY
ok "user hooks: untouched, including one sharing a group with a fleet guard"

# python, not stat: GNU `stat -f` is FILESYSTEM status and succeeds, so a
# `stat -f %Lp … || stat -c %a …` fallback never reaches the Linux half.
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$S2")" = 600 ] \
  || fail "merge loosened settings.json's mode"
m check --settings "$S2" >"$WORK/c3" || fail "check still unhappy after the merge" "$(cat "$WORK/c3")"
grep -q '^ok ' "$WORK/c3" || fail "check did not print ok" "$(cat "$WORK/c3")"
ok "after merge: check passes, mode 0600 kept"

# --- 7. default Claude settings (issue #1558) ---
DEFS="$ROOT/conf/claude-settings.default.json"
[ -r "$DEFS" ] || fail "conf/claude-settings.default.json missing"
DEFS="$DEFS" python3 - <<'PY' || fail "claude-settings.default.json: wrong shape or content" "$(cat "$DEFS")"
import json, os, sys
d = json.load(open(os.environ["DEFS"]))
ok = (set(d) <= {"settings", "globalConfig"}
      and d["settings"]["permissions"]["defaultMode"] == "bypassPermissions"
      and d["globalConfig"]["leftArrowOpensAgents"] is False
      and not {"model", "enabledPlugins", "hooks"} & set(d["settings"]))
sys.exit(0 if ok else 1)
PY
# every default leaf, as `path<TAB>json` — the oracle the legs below compare against
DEFS="$DEFS" python3 - > "$WORK/leaves" <<'PY'
import json, os
d = json.load(open(os.environ["DEFS"]))
def walk(o, pre=""):
    for k in sorted(o):
        if isinstance(o[k], dict) and o[k]: walk(o[k], pre + k + ".")
        else: print("%s\t%s" % (pre + k, json.dumps(o[k])))
walk(d["settings"])
PY
NS=$(wc -l < "$WORK/leaves" | tr -d ' ')
has_leaf() { # $1 file $2 path $3 json — the file holds exactly that value at that path
  F="$1" P="$2" V="$3" python3 -c '
import json, os, sys
cur = json.load(open(os.environ["F"]))
for part in os.environ["P"].split("."):
    if not isinstance(cur, dict) or part not in cur: sys.exit(1)
    cur = cur[part]
sys.exit(0 if cur == json.loads(os.environ["V"]) else 1)'
}
all_leaves() { while IFS=$'\t' read -r p v; do has_leaf "$1" "$p" "$v" || return 1; done < "$WORK/leaves"; }
d() { python3 "$MERGE" "$@" --defaults "$DEFS" --override "$WORK/override.json"; }
S7="$WORK/d/settings.json"; K="$WORK/d/claude.json"; mkdir -p "$WORK/d"
# leg: empty settings.json + no .claude.json
printf '{}\n' > "$S7"
d defaults --settings "$S7" --config "$K" >"$WORK/d1" || fail "defaults on an empty settings.json failed" "$(cat "$WORK/d1")"
all_leaves "$S7" || fail "defaults left a default key out of an empty settings.json" "$(cat "$S7")"
[ "$(grep -c '^set            settings.json ' "$WORK/d1")" = "$NS" ] || fail "defaults did not report one set per default key" "$(cat "$WORK/d1")"
[ -e "$K" ] && fail "defaults created a .claude.json Claude Code never wrote"
grep -q '^absent ' "$WORK/d1" || fail "defaults did not say .claude.json is absent" "$(cat "$WORK/d1")"
d defaults-check --settings "$S7" --config "$K" >"$WORK/d1c" && fail "defaults-check passed with no .claude.json at all"
grep -q '^missing    claude.json leftArrowOpensAgents' "$WORK/d1c" || fail "defaults-check did not name the global key" "$(cat "$WORK/d1c")"
ok "defaults: an empty settings.json gets every default key; an absent .claude.json is not created"
# leg: the login's own values survive — a different effortLevel, permissions.allow beside the filled defaultMode, hooks
printf '{"effortLevel": "high", "permissions": {"allow": ["Bash(x)"]}, "hooks": {"Stop": [{"hooks": []}]}, "model": "m"}\n' > "$S7"
printf '{\n  "numStartups": 7,\n  "oauthAccount": {"emailAddress": "a@b"},\n  "projects": {"/x": {"hasTrustDialogAccepted": true}}\n}\n' > "$K"
chmod 600 "$K"
mkdir "$K.lock"
FLEET_KEYS_LOCK_WAIT=0.3 d defaults --settings "$S7" --config "$K" >"$WORK/dl" 2>&1 && fail "defaults wrote through a held .claude.json.lock" "$(cat "$WORK/dl")"
grep -q leftArrowOpensAgents "$K" && fail "defaults changed .claude.json while the lock was held"
[ -d "$K.lock" ] || fail "defaults removed someone else's lock"
rmdir "$K.lock"
ok "defaults: a held .claude.json.lock is never stolen"
d defaults --settings "$S7" --config "$K" >"$WORK/d2" || fail "defaults over a login's own values failed" "$(cat "$WORK/d2")"
[ -e "$K.lock" ] && fail "defaults left its lock behind"
S7="$S7" python3 - <<'PY' || fail "defaults overwrote a login value, or missed a default" "$(cat "$S7")"
import json, os, sys
s = json.load(open(os.environ["S7"]))
sys.exit(0 if s["effortLevel"] == "high" and s["permissions"]["allow"] == ["Bash(x)"]
         and s["permissions"]["defaultMode"] == "bypassPermissions" and s["hooks"] == {"Stop": [{"hooks": []}]}
         and s["model"] == "m" and s["outputStyle"] == "Concise" else 1)
PY
grep -q '^differs    settings.json effortLevel = "high" (default "xhigh")' "$WORK/d2" || fail "defaults did not report the login's own effortLevel" "$(cat "$WORK/d2")"
grep -q '^set            claude.json leftArrowOpensAgents = false' "$WORK/d2" || fail "defaults did not fill leftArrowOpensAgents" "$(cat "$WORK/d2")"
K="$K" python3 - <<'PY' || fail "defaults touched another .claude.json key or missed its own" "$(cat "$K")"
import json, os, sys
s = json.load(open(os.environ["K"]))
sys.exit(0 if s == {"numStartups": 7, "oauthAccount": {"emailAddress": "a@b"},
                    "projects": {"/x": {"hasTrustDialogAccepted": True}},
                    "leftArrowOpensAgents": False} else 1)
PY
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$K")" = 600 ] \
  || fail "defaults loosened .claude.json's mode"
ok "defaults: the login's effortLevel / permissions.allow / hooks / model survive, defaultMode fills in beside them, .claude.json gets its key at mode 0600"
# leg: idempotent — no write, no backup; check passes except for the login's own key
cp "$S7" "$WORK/s.before"; cp "$K" "$WORK/k.before"
d defaults --settings "$S7" --config "$K" >"$WORK/d3" || fail "second defaults run failed" "$(cat "$WORK/d3")"
grep -q '^unchanged' "$WORK/d3" || fail "second defaults run was not a no-op" "$(cat "$WORK/d3")"
cmp -s "$S7" "$WORK/s.before" || fail "no-op defaults rewrote settings.json"
cmp -s "$K" "$WORK/k.before" || fail "no-op defaults rewrote .claude.json"
[ "$(nbak settings.json)" = 0 ] && [ "$(nbak claude.json)" = 0 ] || fail "defaults wrote a backup"
d defaults-check --settings "$S7" --config "$K" >"$WORK/d3c" && fail "defaults-check passed over the login's own effortLevel" "$(cat "$WORK/d3c")"
head -1 "$WORK/d3c" | grep -q '^1 key(s) differ from claude-settings.default.json' || fail "defaults-check's first line is not the count" "$(cat "$WORK/d3c")"
grep -q '^differs    settings.json effortLevel' "$WORK/d3c" || fail "defaults-check did not name the differing key" "$(cat "$WORK/d3c")"
ok "defaults: idempotent (no write, no backup); defaults-check counts the login's own key as 1 differ"
# leg: the override file and --skip shield keys; a user true in .claude.json is kept, not corrected
printf '["theme", "permissions"]\n' > "$WORK/override.json"
printf '{}\n' > "$S7"
printf '{"leftArrowOpensAgents": true, "theme": "dark"}\n' > "$K"
d defaults --settings "$S7" --config "$K" >"$WORK/d4" || fail "defaults with an override failed" "$(cat "$WORK/d4")"
S7="$S7" python3 - <<'PY' || fail "override did not shield theme / permissions" "$(cat "$S7")"
import json, os, sys
s = json.load(open(os.environ["S7"]))
sys.exit(0 if "theme" not in s and "permissions" not in s and s["effortLevel"] == "xhigh" else 1)
PY
grep -q '^kept    2 key(s) left to this login: permissions.defaultMode, theme' "$WORK/d4" || fail "defaults did not list the kept keys" "$(cat "$WORK/d4")"
grep -q '^differs    claude.json leftArrowOpensAgents = true (default false)' "$WORK/d4" || fail "defaults did not report the user's true" "$(cat "$WORK/d4")"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s=={"leftArrowOpensAgents": True, "theme": "dark"} else 1)' "$K" \
  || fail "defaults corrected a user true — the fill became a pin" "$(cat "$K")"
d defaults-check --settings "$S7" --config "$K" --skip leftArrowOpensAgents >"$WORK/d4c" || fail "defaults-check with override + --skip unhappy" "$(cat "$WORK/d4c")"
grep -q '^ok .*left to this login: permissions.defaultMode, theme, leftArrowOpensAgents' "$WORK/d4c" || fail "defaults-check did not list the shielded keys" "$(cat "$WORK/d4c")"
d defaults-check --settings "$S7" --config "$K" >"$WORK/d4d" && fail "defaults-check ignored the user's true without --skip"
ok "defaults: the override file and --skip shield keys; a user true is kept and reported, never corrected"
# leg: a malformed defaults file is refused
printf '{"settings": {}, "bogus": {}}\n' > "$WORK/bad.json"
python3 "$MERGE" defaults-check --defaults "$WORK/bad.json" --settings "$S7" --config "$K" >/dev/null 2>&1; [ $? = 2 ] || fail "a malformed defaults file was not refused with exit 2"
ok "defaults: a defaults file with a section other than settings/globalConfig exits 2"

printf 'PASS  fleet-hooks-merge-selftest (%d checks)\n' "$pass"
