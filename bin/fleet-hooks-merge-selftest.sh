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

[ "$(stat -f %Lp "$S2" 2>/dev/null || stat -c %a "$S2")" = 600 ] || fail "merge loosened settings.json's mode"
m check --settings "$S2" >"$WORK/c3" || fail "check still unhappy after the merge" "$(cat "$WORK/c3")"
grep -q '^ok ' "$WORK/c3" || fail "check did not print ok" "$(cat "$WORK/c3")"
ok "after merge: check passes, mode 0600 kept"

printf 'PASS  fleet-hooks-merge-selftest (%d checks)\n' "$pass"
