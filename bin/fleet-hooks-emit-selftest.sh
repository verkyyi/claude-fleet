#!/bin/bash
# fleet-hooks-emit-selftest.sh — ONE hook table, two agent targets (issue #611).
#
# The failure this test exists to prevent: the fleet's hook table drifting apart
# per agent. Before #611 bin/fleet-codex.sh carried its own hand-transcoded TOML
# copy of hooks/settings-hooks.json, so a hook added for Claude simply never
# reached a Codex worker and nothing said so. Now bin/fleet-hooks-emit.sh
# materialises the ONE source for both targets and hooks/codex-map.json DECLARES
# the Codex delta. What is pinned here:
#
#   1. CLAUDE TARGET IS THE SOURCE — every event and every command round-trips
#      unchanged. The Claude side must never be silently transformed.
#   2. CODEX TARGET IS THE SOURCE MINUS THE DECLARED DELTA — the wired events are
#      exactly those marked `true`, the edit matcher becomes apply_patch, the
#      Artifact group is gone, Claude-specific hooks are dropped — and every
#      surviving command still traces back to the source (nothing invented).
#   3. FAIL-CLOSED — a NEW event in the source that codex-map.json does not mark
#      `true` stays OUT of the Codex table. A new Claude hook can never silently
#      reach a Codex worker.
#   4. THE TOML PARSES — the emitted value is fed back through a real TOML parser,
#      so `-c hooks.<Event>=…` cannot ship a string codex would reject.
#   5. REHOMING — --root repoints the shipped ~/.claude/fleet paths at this
#      install and QUOTES them (a resolved path may contain spaces).
#
# Hermetic: temp fixtures only; no tmux, no network, no writes to the repo.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
EMIT="$BIN/fleet-hooks-emit.sh"
SRC="$ROOT/hooks/settings-hooks.json"
MAP="$ROOT/hooks/codex-map.json"

for f in "$EMIT" "$SRC" "$MAP"; do
  [ -r "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

st_sandbox "${TMPDIR:-/tmp}/fleet-hooks-emit.XXXXXX"
trap 'exit 130' INT TERM HUP

pass=0

# The LITERAL prefix the shipped table carries — a string to match and rewrite,
# never a path this script opens, so it must NOT expand to $HOME.
# shellcheck disable=SC2088
SHIPPED='~/.claude/fleet'

# --- 1. claude target round-trips the source ----------------------------------
out="$("$EMIT" --target claude --root "$SHIPPED")" || st_fail "claude target exited non-zero"
printf '%s' "$out" > "$WORK/claude.json"
SRC="$SRC" GOT="$WORK/claude.json" python3 - <<'PY' || st_fail "claude target is not the source table verbatim"
import json, os, sys
a = json.load(open(os.environ["SRC"]))["hooks"]
b = json.load(open(os.environ["GOT"]))["hooks"]
sys.exit(0 if a == b else 1)
PY
st_pass "claude target round-trips hooks/settings-hooks.json unchanged"

# --- 2. codex target = source minus the declared delta ------------------------
cdx="$("$EMIT" --target codex --root "$SHIPPED")" || st_fail "codex target exited non-zero"
printf '%s' "$cdx" > "$WORK/codex.tsv"

events="$(cut -f1 "$WORK/codex.tsv" | sort | paste -sd, -)"
[ "$events" = "PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit" ] \
  || st_fail "codex wired the wrong event set: $events" "$cdx"
st_pass "codex target wires state and lifecycle events declared in codex-map.json"

grep -q 'matcher="apply_patch"' "$WORK/codex.tsv" \
  || st_fail "the edit matcher was not translated to apply_patch" "$cdx"
grep -q 'Edit|Write' "$WORK/codex.tsv" \
  && st_fail "the Claude edit matcher leaked into the codex table" "$cdx"
grep -q 'artifact-guard' "$WORK/codex.tsv" \
  && st_fail "artifact-guard.py reached codex, which has no Artifact tool" "$cdx"
grep -q 'agent-guard' "$WORK/codex.tsv" \
  && st_fail "retired agent-guard.py reached the Codex hook table" "$cdx"
grep -q 'classify-hook' "$WORK/codex.tsv" \
  && st_fail "the retired screen classifier (issue #2543) is still wired on Codex Stop" "$cdx"
grep -q 'handoff-latch-reset-hook\|session-end-hook' "$WORK/codex.tsv" \
  && st_fail "Claude handoff or reason-based cleanup reached a Codex thread lifecycle hook" "$cdx"
grep '^SessionStart' "$WORK/codex.tsv" | grep -q 'fleet-emit.sh session.start' \
  || st_fail "Codex SessionStart must emit the lifecycle event" "$cdx"
grep '^SessionEnd' "$WORK/codex.tsv" | grep -q 'fleet-emit.sh session.end --via hook' \
  || st_fail "Codex SessionEnd must emit the lifecycle event without window cleanup" "$cdx"
grep -q 'base-readonly-guard.py' "$WORK/codex.tsv" \
  || st_fail "the base-checkout guard is missing from the codex table" "$cdx"
grep -q 'bash-guard.py' "$WORK/codex.tsv" \
  || st_fail "the bash deny-list guard is missing from the codex table" "$cdx"
st_pass "codex delta applied: guards and lifecycle events in, Claude-only cleanup/handoff out"

# Nothing invented: every emitted command must exist in the source table.
SRC="$SRC" TSV="$WORK/codex.tsv" python3 - <<'PY' || st_fail "the codex table contains a command that is not in hooks/settings-hooks.json"
import json, os, re, sys
src = json.load(open(os.environ["SRC"]))["hooks"]
known = {h["command"] for gs in src.values() for g in gs for h in g.get("hooks", [])}
got = set(re.findall(r'command="((?:[^"\\]|\\.)*)"', open(os.environ["TSV"]).read()))
got = {c.replace('\\"', '"').replace("\\\\", "\\") for c in got}
extra = got - known
if extra:
    sys.stderr.write("not in the source table: %r\n" % sorted(extra)); sys.exit(1)
PY
st_pass "every codex command traces back to the one source table"

# --- 3. fail-closed: a new source event does NOT reach codex ------------------
mkdir -p "$WORK/install/bin" "$WORK/install/hooks"
cp "$EMIT" "$WORK/install/bin/"; cp "$MAP" "$WORK/install/hooks/"
SRC="$SRC" OUT="$WORK/install/hooks/settings-hooks.json" python3 - <<'PY'
import json, os
d = json.load(open(os.environ["SRC"]))
d["hooks"]["PreCompact"] = [{"hooks": [{"type": "command", "command": "sh ~/.claude/fleet/bin/brand-new-hook.sh"}]}]
json.dump(d, open(os.environ["OUT"], "w"), indent=2)
PY
new="$("$WORK/install/bin/fleet-hooks-emit.sh" --target codex --root "$SHIPPED")" \
  || st_fail "emitter failed on a source with a new event"
printf '%s\n' "$new" | grep -q '^PreCompact' \
  && st_fail "a NEW Claude event reached codex without being declared in codex-map.json" "$new"
printf '%s\n' "$new" | grep -q 'brand-new-hook.sh' \
  && st_fail "a NEW Claude hook command leaked into the codex table" "$new"
# …while the Claude target picks it up immediately.
"$WORK/install/bin/fleet-hooks-emit.sh" --target claude --root "$SHIPPED" | grep -q 'brand-new-hook.sh' \
  || st_fail "the claude target dropped a hook that IS in the source"
st_pass "fail-closed: a new Claude event reaches claude at once and codex only when declared"

# --- 4. the emitted TOML actually parses --------------------------------------
TSV="$WORK/codex.tsv" python3 - <<'PY' || st_fail "the emitted codex value is not valid TOML"
import os, sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("tomllib unavailable (python < 3.11) — skipping the parse check\n")
    sys.exit(0)
for line in open(os.environ["TSV"]):
    line = line.rstrip("\n")
    if not line:
        continue
    ev, toml = line.split("\t", 1)
    try:
        got = tomllib.loads("v = %s" % toml)["v"]
    except Exception as e:
        sys.stderr.write("%s: %s\nin: %s\n" % (ev, e, toml)); sys.exit(1)
    if not isinstance(got, list) or not got:
        sys.stderr.write("%s did not parse to a non-empty array\n" % ev); sys.exit(1)
    for grp in got:
        for h in grp["hooks"]:
            if h["type"] != "command" or not h["command"]:
                sys.stderr.write("%s: malformed hook entry %r\n" % (ev, h)); sys.exit(1)
PY
st_pass "every emitted codex value parses as TOML into a well-formed hook array"

# --- 5. rehoming quotes the resolved path -------------------------------------
spacey="$WORK/a dir/install"
mkdir -p "$spacey"
re="$("$EMIT" --target codex --root "$spacey")" || st_fail "rehomed emit exited non-zero"
printf '%s\n' "$re" | grep -q "$SHIPPED" \
  && st_fail "the shipped ~/.claude/fleet prefix survived rehoming" "$re"
printf '%s\n' "$re" | grep -q "command=\"sh '$spacey/bin/set-claude-state.sh' busy\"" \
  || st_fail "a rehomed path with a space was not single-quoted" "$re"
st_pass "--root rehomes the shipped prefix and quotes a path containing spaces"

# --- 6. bad input fails loudly, never silently empty --------------------------
"$EMIT" --target bogus >/dev/null 2>&1; [ "$?" = 2 ] || st_fail "an unknown --target must exit 2"
mkdir -p "$WORK/broken/bin" "$WORK/broken/hooks"
cp "$EMIT" "$WORK/broken/bin/"; cp "$MAP" "$WORK/broken/hooks/"
printf 'not json{' > "$WORK/broken/hooks/settings-hooks.json"
"$WORK/broken/bin/fleet-hooks-emit.sh" --target codex >/dev/null 2>&1
[ "$?" = 3 ] || st_fail "a malformed source table must exit 3, not emit an empty table"
mkdir -p "$WORK/absent/bin"; cp "$EMIT" "$WORK/absent/bin/"
"$WORK/absent/bin/fleet-hooks-emit.sh" --target claude >/dev/null 2>&1
[ "$?" = 2 ] || st_fail "a missing source table must exit 2"
st_pass "unknown target → 2, malformed source → 3, missing source → 2"

ROOT="$ROOT" WORK="$WORK" python3 - <<'PY' || st_fail "native managed output contract"
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tomllib

root = Path(os.environ["ROOT"])
work = Path(os.environ["WORK"]) / "managed-fixture"
(work / "bin").mkdir(parents=True)
(work / "hooks").mkdir()
shutil.copyfile(root / "bin/fleet-hooks-emit.sh", work / "bin/fleet-hooks-emit.sh")
source = json.loads((root / "hooks/settings-hooks.json").read_text())
mapping = json.loads((root / "hooks/codex-map.json").read_text())
environment = {"PATH": os.environ["PATH"], "HOME": str(work), "PYTHONPATH": str(work)}
(work / "json.py").write_text('raise RuntimeError("untrusted fixture import")\n')
destination = str(work / "future image's hooks")
interpreter = str(work / "future Python's bin/python3")

def run(*arguments, table=None, delta=None, expected=0):
    (work / "hooks/settings-hooks.json").write_text(json.dumps(source if table is None else table))
    (work / "hooks/codex-map.json").write_text(json.dumps(mapping if delta is None else delta))
    result = subprocess.run(["bash", str(work / "bin/fleet-hooks-emit.sh"), *arguments],
                            env=environment, cwd=work, capture_output=True, text=True, timeout=10)
    assert result.returncode == expected, (arguments, result.returncode, result.stderr)
    if expected:
        assert not result.stdout, "invalid managed configuration produced partial output"
    return result.stdout

arguments = ("--target", "codex-managed", "--managed-dir", destination, "--python", interpreter)
rendered = run(*arguments)
assert run(*arguments) == rendered
requirements = tomllib.loads(rendered)
assert requirements["features"] == {"hooks": True}
assert set(requirements) == {"features", "hooks"}
assert set(requirements["hooks"]) == {"managed_dir", "PreToolUse"}
assert requirements["hooks"]["managed_dir"] == destination
groups = requirements["hooks"]["PreToolUse"]
assert [group["matcher"] for group in groups] == ["Bash", "apply_patch"]
assert [shlex.split(group["hooks"][0]["command"]) for group in groups] == [
    [interpreter, "-I", destination + "/bash-guard.py"],
    [interpreter, "-I", destination + "/base-readonly-guard.py"],
]
assert all(group["hooks"][0]["type"] == "command" and len(group["hooks"]) == 1 for group in groups)
assert not Path(destination).exists() and not Path(interpreter).exists()
assert "allow_managed_hooks_only" not in rendered and "SessionStart" not in rendered
extra = copy.deepcopy(source)
extra["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [
    {"type": "command", "command": "python3 ~/.claude/fleet/hooks/unreviewed.py"}]})
assert run(*arguments, table=extra) == rendered
default = tomllib.loads(run("--target", "codex-managed", "--managed-dir", destination))
assert shlex.split(default["hooks"]["PreToolUse"][0]["hooks"][0]["command"])[0] == "/usr/bin/python3"
for flags in (("--target", "codex-managed"),
              ("--target", "codex-managed", "--managed-dir"),
              ("--target", "codex-managed", "--managed-dir", ""),
              ("--target", "codex-managed", "--managed-dir", "/"),
              ("--target", "codex-managed", "--managed-dir", "relative"),
              ("--target", "codex-managed", "--managed-dir", "/tmp/../hooks"),
              ("--target", "codex-managed", "--managed-dir", "/tmp/line\nbreak"),
              (*arguments, "--python", "relative"), (*arguments, "--python"),
              (*arguments, "--event", "PreToolUse"), (*arguments, "--plugin-dir", "/optional/plugin"),
              (*arguments, "--root", "/different/install"),
              ("--target", "codex", "--managed-dir", destination),
              ("--target", "claude", "--python", interpreter)):
    run(*flags, expected=2)
for mutation in ("missing", "duplicate", "drop", "disabled", "wrong-event", "extra-field", "unmapped"):
    table, delta = copy.deepcopy(source), copy.deepcopy(mapping)
    if mutation == "missing":
        table["hooks"]["PreToolUse"].pop(1)
    elif mutation == "duplicate":
        table["hooks"]["PreToolUse"].append(copy.deepcopy(table["hooks"]["PreToolUse"][1]))
    elif mutation == "drop":
        delta["drop_commands"]["bash-guard.py"] = "fixture"
    elif mutation == "disabled":
        delta["matchers"]["Bash"] = None
    elif mutation == "wrong-event":
        table["hooks"]["Stop"].append(table["hooks"]["PreToolUse"].pop(1))
    elif mutation == "extra-field":
        table["hooks"]["PreToolUse"][1]["hooks"][0]["async"] = True
    else:
        delta.pop("managed_commands")
    run(*arguments, table=table, delta=delta, expected=3)
for invalid in ([], [mapping["managed_commands"][0]] * 2, [None], "all"):
    delta = copy.deepcopy(mapping)
    delta["managed_commands"] = invalid
    run(*arguments, delta=delta, expected=3)
print("native managed renderer: exact guards, import isolation, quoting, deterministic/no writes and 25 rejections passed")
PY
st_pass "native managed output derives only reviewed guards and rejects unsafe or incomplete input"

printf '\nfleet-hooks-emit-selftest: %d checks passed\n' "$pass"
